"""The mojo_repos pipeline: Mojo repositories found in `gharchive.events`.

A sensor: each day gharchive commits starts a run for that day. The step
reads the day's events, collects candidates (`detect.scan_event`), asks
GitHub about the ones it hasn't asked about before (`detect.verify`), and
appends the Mojo ones to `mojo.repos` and every answer to `mojo.checked`.
It also appends the new repositories' keys to `mojo.repo_keys`, which
mojo_history is keyed on (see `lake.REPO_KEYS` for why that table is
written outside `orca.tables`).

GitHub allows 60 API requests an hour without a token, so a run checks at
most `MOJO_REPOS_BUDGET` candidates (default 25, or 1000 with
`GITHUB_TOKEN`), strongest signs first, and stops early when the rate limit
runs out. The rest go into `mojo.checked` as `unchecked`, and every later
run checks those first, whatever day it is for.
"""

from std.os import getenv, setenv

from iceberg.batch import ColumnBuilder, batch_of
from iceberg.values import Datum
from orca import Ctx, Daily, Day, Mapped, Pipeline, Step, orca_main
from orca.civil import now
from orca.tables import append, ensure_table, scan, table
from parquet import RecordBatch

from cols import col, i64_at, str_at, str_range
from detect import Candidate, Verdict, scan_event, verify
from jscan import days_from_civil
from lake import (
    CHECKED,
    append_keys,
    EVENTS,
    REPOS,
    checked_schema,
    repo_key,
    repos_schema,
    str_or_null,
    ts,
)


def _known(mut ctx: Ctx, dataset: String) raises -> Dict[String, Bool]:
    """The `repo` values already in one of this step's own tables."""
    var out = Dict[String, Bool]()
    var t = table(ctx, dataset)
    if not t.metadata.has_current_snapshot:
        return out^
    for b in t.scan().select(["repo"]).to_batches():
        ref a = b.column(0)
        for r in range(b.num_rows):
            out[str_at(a, r)] = True
    return out^


@fieldwise_init
struct _Asked(Copyable, Movable):
    var at: Int64
    var pending: Bool
    """The latest answer is `unchecked`: no API budget was left for it."""
    var candidate: Candidate


def _asked(mut ctx: Ctx) raises -> Dict[String, _Asked]:
    """The latest row of mojo.checked for each repository."""
    var out = Dict[String, _Asked]()
    var t = table(ctx, CHECKED)
    if not t.metadata.has_current_snapshot:
        return out^
    for b in t.scan().to_batches():
        var c_repo = col(b, "repo")
        var c_at = col(b, "checked_at")
        var c_out = col(b, "outcome")
        var c_sig = col(b, "signals")
        var c_first = col(b, "first_seen")
        var c_sha = col(b, "sha")
        for r in range(b.num_rows):
            var repo = str_at(b.column(c_repo), r)
            var at = i64_at(b.column(c_at), r)
            if repo in out and out[repo].at > at:
                continue
            out[repo] = _Asked(
                at,
                str_at(b.column(c_out), r) == "unchecked",
                Candidate(
                    repo,
                    str_at(b.column(c_sig), r),
                    i64_at(b.column(c_first), r),
                    str_at(b.column(c_sha), r),
                ),
            )
    return out^


def _now_micros() raises -> Int64:
    return now() * 1_000_000


def _scan_batch(b: RecordBatch, mut found: Dict[String, Candidate]) raises:
    ref ty = b.column(col(b, "type"))
    ref repo = b.column(col(b, "repo"))
    ref at = b.column(col(b, "created_at"))
    ref payload = b.column(col(b, "payload"))
    var pv = Span(payload.values)
    for r in range(b.num_rows):
        var pr = str_range(payload, r)
        scan_event(found, str_at(ty, r), str_at(repo, r), i64_at(at, r), pv[pr[0] : pr[1]])


def find_repos(mut ctx: Ctx, d: Day) raises -> Int:
    var lo = Int64(days_from_civil(d.year, d.month, d.day)) * 86_400_000_000
    var hi = lo + 86_400_000_000
    var events = table(ctx, EVENTS)
    var filter = String(
        '["and",[">=","created_at",', lo, '],["<","created_at",', hi, "]]"
    )
    var reader = (
        scan(ctx, events)
        .filter(filter)
        .select(["type", "repo", "created_at", "payload"])
        .to_batch_reader()
    )
    var found = Dict[String, Candidate]()
    var rows = 0
    while True:
        var next = reader.next_batch()
        if not next:
            break
        var b = next.take()
        _scan_batch(b, found)
        rows += b.num_rows
    ctx.log(String(String(d), ": ", rows, " events, ", len(found), " candidates"))

    # Leave out what an earlier day already settled.
    var repos_t = ensure_table(ctx, REPOS, repos_schema())
    var checked_t = ensure_table(ctx, CHECKED, checked_schema())
    var known = _known(ctx, REPOS)
    var asked = _asked(ctx)
    var todo = List[Candidate]()
    for e in found.items():
        if e.key in known:
            continue
        if e.key in asked and not asked[e.key].pending:
            continue
        todo.append(e.value.copy())
    # Candidates an earlier run had no API budget for, from any day.
    for e in asked.items():
        if e.value.pending and e.key not in found and e.key not in known:
            todo.append(e.value.candidate.copy())
    # Strongest signs first.
    for i in range(1, len(todo)):
        var j = i
        while j > 0 and todo[j - 1].rank() > todo[j].rank():
            todo.swap_elements(j - 1, j)
            j -= 1

    var budget = Int(getenv("MOJO_REPOS_BUDGET", "1000" if getenv("GITHUB_TOKEN") else "25"))
    var rs = repos_schema()
    var cs = checked_schema()
    var c_repo = ColumnBuilder.of(rs, 1)
    var c_created = ColumnBuilder.of(rs, 2)
    var c_first = ColumnBuilder.of(rs, 3)
    var c_found = ColumnBuilder.of(rs, 4)
    var c_stars = ColumnBuilder.of(rs, 5)
    var c_forks = ColumnBuilder.of(rs, 6)
    var c_license = ColumnBuilder.of(rs, 7)
    var c_branch = ColumnBuilder.of(rs, 8)
    var c_desc = ColumnBuilder.of(rs, 9)
    var c_size = ColumnBuilder.of(rs, 10)
    var c_lang = ColumnBuilder.of(rs, 11)
    var c_key = ColumnBuilder.of(rs, 12)
    var c_fork = ColumnBuilder.of(rs, 13)
    var k_repo = ColumnBuilder.of(cs, 1)
    var k_at = ColumnBuilder.of(cs, 2)
    var k_out = ColumnBuilder.of(cs, 3)
    var k_sig = ColumnBuilder.of(cs, 4)
    var k_how = ColumnBuilder.of(cs, 5)
    var k_first = ColumnBuilder.of(cs, 6)
    var k_sha = ColumnBuilder.of(cs, 7)
    var checked_now = _now_micros()
    var asked_n = 0
    var added = 0
    var added_names = Dict[String, Bool]()
    var stopped = False
    for ref c in todo:
        var outcome = String("unchecked")
        var how = String()
        if not stopped and asked_n >= budget:
            ctx.log(String("budget of ", budget, " checks used; ", len(todo) - asked_n, " candidates wait"))
            stopped = True
        if not stopped:
            var v = verify(c)
            asked_n += 1
            if v.outcome == "limited":
                ctx.log(String("GitHub rate limit reached after ", asked_n - 1, " checks"))
                stopped = True
            else:
                outcome = v.outcome
                how = v.how
                ctx.log(String(c.repo, " [", c.signals, "]: ", v.outcome, " ", v.how))
                if v.outcome == "mojo" and v.info.repo not in known and v.info.repo not in added_names:
                    added_names[v.info.repo] = True
                    c_repo.add(Datum.string_(v.info.repo))
                    c_created.add(ts(v.info.created_at))
                    c_first.add(ts(c.first_seen))
                    c_found.add(Datum.string_(String(c.signals, " / ", v.how)))
                    c_stars.add(Datum.long_(v.info.stars))
                    c_forks.add(Datum.long_(v.info.forks))
                    c_license.add(str_or_null(v.info.license))
                    c_branch.add(str_or_null(v.info.default_branch))
                    c_desc.add(str_or_null(v.info.description))
                    c_size.add(Datum.long_(v.info.size_kb))
                    c_lang.add(str_or_null(v.info.language))
                    c_key.add(Datum.string_(repo_key(v.info.repo)))
                    c_fork.add(Datum.bool_(v.info.fork))
                    added += 1
                if v.remaining == 0:
                    ctx.log("GitHub rate limit now 0; the rest wait for a later run")
                    stopped = True
        if outcome == "unchecked" and c.repo in asked and asked[c.repo].pending:
            continue  # already waiting
        k_repo.add(Datum.string_(c.repo))
        k_at.add(ts(checked_now))
        k_out.add(Datum.string_(outcome))
        k_sig.add(Datum.string_(c.signals))
        k_how.add(str_or_null(how))
        k_first.add(ts(c.first_seen))
        k_sha.add(str_or_null(c.sha))
    if added > 0:
        var id = append(ctx, repos_t, [batch_of([c_repo^, c_created^, c_first^, c_found^, c_stars^, c_forks^, c_license^, c_branch^, c_desc^, c_size^, c_lang^, c_key^, c_fork^])])
        ctx.log(String(added, " Mojo repositories added, snapshot ", id))
        # mojo_history's keys, written outside orca.tables (see lake.REPO_KEYS).
        var new_repos = List[String]()
        for e in added_names.items():
            new_repos.append(e.key)
        var kid = append_keys(new_repos)
        ctx.log(String(len(new_repos), " keys for mojo_history, mojo.repo_keys snapshot ", kid))
    if len(k_repo) > 0:
        _ = append(ctx, checked_t, [batch_of([k_repo^, k_at^, k_out^, k_sig^, k_how^, k_first^, k_sha^])])
    return added


comptime FindRepos = Step[
    "find_repos",
    Day,
    Int,
    find_repos,
    Mapped,
    retries=1,
    reads=[EVENTS],
    writes=[REPOS, CHECKED],
]
comptime MojoRepos = Pipeline[
    "mojo_repos",
    FindRepos,
    partitions=Daily["2023-01-01"],
    sensor=True,
]


def main() raises:
    if not getenv("ORCA_WAREHOUSE"):
        _ = setenv("ORCA_WAREHOUSE", "build/warehouse")
    orca_main[MojoRepos]()
