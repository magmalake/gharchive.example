"""The mojo_stats pipeline: every Mojo repository's numbers, each week.

Daily partitions from 2026-11-01, of which the schedule fills one a week:
Mondays at 06:00 UTC, for that day (`fills=Current`). The step asks GitHub
about each repository in `mojo.repos` (`GET /repos/{owner}/{repo}`, one
request each) and writes one row per repository to `mojo.repo_stats`,
`as_of` the run's day, partitioned by month. A repository that is gone,
blocked or renamed is a row with that `state`. A rate limit (403/429) is
waited out by `Retry-After` or `X-RateLimit-Reset`, for at most
`MOJO_STATS_MAX_WAIT` seconds (default 3900) in all.

A rerun of a day replaces that day's rows (`replace.replace_files`), so a
day has one row per repository however often it runs.

    GITHUB_TOKEN=... ./build/mojo_stats run --partitions 2026-11-05
"""

from std.os import getenv, setenv

from iceberg.batch import ColumnBuilder, NestedBuilder, batch_of_columns
from iceberg.nested import ColumnTree
from iceberg.values import Datum
from orca import Cron, Ctx, Current, Daily, Day, Mapped, Pipeline, Step, orca_main
from orca.civil import now
from orca.tables import ensure_table, scan, table
from parquet import RecordBatch

from cols import bool_at, col, i32_at, i64_at, str_at, strs_at
from days import days_of, month_of
from lake import (
    REPOS,
    REPO_STATS,
    date,
    json_strings,
    repo_stats_schema,
    repo_stats_spec,
    str_or_null,
    ts,
    ts_or_null,
)
from replace import partition_files, replace_files
from stats import StatsRow, stats_of


@fieldwise_init
struct _Stored(Copyable, Movable):
    """A row of `mojo.repo_stats` as stored: the GitHub numbers (`row`), the
    day they are for (`as_of`, days since the epoch) and when they were
    fetched (microseconds)."""

    var as_of: Int64
    var fetched_at: Int64
    var row: StatsRow


def _repos(mut ctx: Ctx) raises -> List[String]:
    """Every repository of `mojo.repos` (at the step's pinned snapshot), once,
    sorted by name so a run asks about them in a stable order."""
    var seen = Dict[String, Bool]()
    var out = List[String]()
    var t = table(ctx, REPOS)
    for b in scan(ctx, t).select(["repo"]).to_batches():
        for r in range(b.num_rows):
            var repo = str_at(b.column(0), r)
            if repo not in seen:
                seen[repo] = True
                out.append(repo)
    for i in range(1, len(out)):
        var j = i
        while j > 0 and out[j - 1] > out[j]:
            out.swap_elements(j - 1, j)
            j -= 1
    return out^


def stored_rows(b: RecordBatch) raises -> List[_Stored]:
    """The rows of a scanned `mojo.repo_stats` batch. The names are read once
    and the columns are looked up by position below, so the order of the
    list must match the constructor calls."""
    var out = List[_Stored]()
    var c = List[Int]()
    for name in [
        "repo", "as_of", "fetched_at", "state", "stars", "forks",
        "open_issues", "watchers", "topics", "archived", "pushed_at",
        "homepage", "license", "description", "size_kb", "default_branch",
        "renamed_to",
    ]:
        c.append(col(b, name))
    for r in range(b.num_rows):
        out.append(
            _Stored(
                i32_at(b.column(c[1]), r),
                i64_at(b.column(c[2]), r),
                StatsRow(
                    str_at(b.column(c[0]), r),
                    str_at(b.column(c[3]), r),
                    i64_at(b.column(c[4]), r),
                    i64_at(b.column(c[5]), r),
                    i64_at(b.column(c[6]), r),
                    i64_at(b.column(c[7]), r),
                    strs_at(b, c[8], r),
                    bool_at(b.column(c[9]), r),
                    i64_at(b.column(c[10]), r),
                    str_at(b.column(c[11]), r),
                    str_at(b.column(c[12]), r),
                    str_at(b.column(c[13]), r),
                    i64_at(b.column(c[14]), r),
                    str_at(b.column(c[15]), r),
                    str_at(b.column(c[16]), r),
                ),
            )
        )
    return out^


def _num(v: Int64, ok: Bool) -> Datum:
    """`v`, or null when GitHub gave no numbers for the repository (gone or
    blocked), so a missing repository isn't plotted as zero stars."""
    return Datum.long_(v) if ok else Datum.none()


def stats_batch(rows: List[_Stored]) raises -> RecordBatch:
    """`rows` as a batch of `mojo.repo_stats`. `topics` is a list column, so
    the batch is built from column trees, with the columns in schema order
    (field ids 1-8, the topics, then 11-18; ids 9 and 10 are the topics'
    list and element)."""
    var s = repo_stats_schema()
    var cs = List[ColumnBuilder]()
    for id in [1, 2, 3, 4, 5, 6, 7, 8]:
        cs.append(ColumnBuilder.of(s, id))
    var topics = NestedBuilder.of(s, 9)
    var rest = List[ColumnBuilder]()
    for id in [11, 12, 13, 14, 15, 16, 17, 18]:
        rest.append(ColumnBuilder.of(s, id))
    for ref st in rows:
        ref r = st.row
        var ok = r.has_numbers()
        cs[0].add(Datum.string_(r.repo))
        cs[1].add(date(st.as_of))
        cs[2].add(ts(st.fetched_at))
        cs[3].add(Datum.string_(r.state))
        cs[4].add(_num(r.stars, ok))
        cs[5].add(_num(r.forks, ok))
        cs[6].add(_num(r.open_issues, ok))
        cs[7].add(_num(r.watchers, ok))
        if ok:
            topics.add(json_strings(r.topics))
            rest[0].add(Datum.bool_(r.archived))
            rest[6].add(Datum.long_(r.size_kb))
        else:
            topics.add_null()
            rest[0].add(Datum.none())
            rest[6].add(Datum.none())
        rest[1].add(ts_or_null(r.pushed_at))
        rest[2].add(str_or_null(r.homepage))
        rest[3].add(str_or_null(r.license))
        rest[4].add(str_or_null(r.description))
        rest[5].add(str_or_null(r.default_branch))
        rest[7].add(str_or_null(r.renamed_to))
    var trees = List[ColumnTree]()
    for ref c in cs:
        trees.append(c.build_tree())
    trees.append(topics.build())
    for ref c in rest:
        trees.append(c.build_tree())
    return batch_of_columns(trees^)


def refresh(mut ctx: Ctx, d: Day) raises -> Int:
    """The step: asks GitHub about every repository in `mojo.repos` and
    replaces the day's rows in `mojo.repo_stats` with the answers, keeping
    the other days of the month. Returns the number of repositories."""
    var day = String(d)
    var as_of = days_of(day)
    var repos = _repos(ctx)
    var t = ensure_table(ctx, REPO_STATS, repo_stats_schema(), repo_stats_spec())
    # The most this whole step waits on GitHub's rate limit: a window is an
    # hour, so 3900 s (65 minutes) is one window and a margin. Each repository
    # gets what is left of it (`max_wait - waited`); the step fails when a
    # wait would exceed it, rather than sleeping on indefinitely.
    var max_wait = Int(getenv("MOJO_STATS_MAX_WAIT", "3900"))
    var fetched = now() * 1_000_000
    var rows = List[_Stored]()
    var calls = 0
    var waited = 0
    var remaining = -1
    var states = Dict[String, Int]()
    for ref repo in repos:
        var a = stats_of(repo, max_wait - waited)
        calls += a.calls
        waited += a.waited_s
        remaining = a.remaining
        states[a.row.state] = states.get(a.row.state, 0) + 1
        # Every non-ok state (gone, blocked, renamed, error) is a row too, so
        # the time series records the repository's disappearance instead of
        # silently stopping.
        if a.row.state != "ok":
            ctx.log(String(repo, ": ", a.row.state, " ", a.row.renamed_to))
        rows.append(_Stored(as_of, fetched, a.row.copy()))
    var summary = String()
    for e in states.items():
        summary += String(" ", e.key, "=", e.value)
    ctx.log(String(
        day, ": ", len(repos), " repositories in ", calls, " requests (",
        waited, " s waiting on the rate limit; ", remaining, " left):", summary,
    ))

    # Replace this day's rows; keep the month's other days. The table is
    # partitioned by month of `as_of`, so a day's rows live in a file shared
    # with the month's other days: read the month, keep the rows of other
    # days, and commit them with the new rows as one `overwrite` that removes
    # the month's old files. Rerunning a day therefore gives one row per
    # repository, not two.
    var months = Dict[Int, Bool]()
    months[month_of(as_of)] = True
    var files = partition_files(t, months)
    var read_rows = Int64(0)
    var kept = 0
    if t.metadata.has_current_snapshot:
        for b in t.scan().to_batches():
            for ref st in stored_rows(b):
                if month_of(st.as_of) != month_of(as_of):
                    continue
                read_rows += 1
                if st.as_of != as_of:
                    rows.append(st.copy())
                    kept += 1
    # The rows read must equal the rows in the files about to be removed;
    # otherwise the overwrite below would silently lose some.
    if read_rows != files.rows:
        raise Error(
            REPO_STATS, ": read ", read_rows, " rows of the month, but its",
            " files hold ", files.rows,
        )
    var id = replace_files(ctx, t, files.paths, [stats_batch(rows)])
    ctx.log(String(len(repos), " rows as of ", day, " (", kept, " of other days kept), snapshot ", id))
    return len(repos)


# `Mapped`: the step runs once per partition of a run, here a `Day`. There is
# no dista task: the requests are made one at a time by the step itself, which
# is what keeps them within GitHub's rate limit.
comptime Refresh = Step[
    "refresh",
    Day,
    Int,
    refresh,
    Mapped,
    retries=1,
    reads=[REPOS],
    writes=[REPO_STATS],
]
# A `Cron` schedule fires on its own. `fills=Current` makes a fire fill the
# partition its time falls in (Monday itself, not the day before, which is
# the default), and `catchup=False` starts only the latest fire if the
# scheduler was down for several: GitHub only gives the current numbers, so a
# late run can't recover a missed week's anyway.
comptime MojoStats = Pipeline[
    "mojo_stats",
    Refresh,
    partitions=Daily["2026-11-01"],
    schedule=Cron["0 6 * * 1"],  # Mondays 06:00 UTC, for that day
    fills=Current,
    catchup=False,
]


def main() raises:
    if not getenv("ORCA_WAREHOUSE"):
        _ = setenv("ORCA_WAREHOUSE", "build/warehouse")
    orca_main[MojoStats]()
