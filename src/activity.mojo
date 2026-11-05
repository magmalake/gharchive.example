"""Activity over time from GH Archive, with no API calls: per repository and
day, the stars (WatchEvent), forks, published releases, issues and pull
requests opened, pushes and distinct actors, and each published release.

`day_activity` reads one day of `gharchive.events` for a set of
repositories (a dista task in mojo_activity); `add_event` is what it does
with each event, and `parse_release` reads a ReleaseEvent's payload.
"""

from std.time import perf_counter_ns

from dista import Seq
from iceberg.batch import ColumnBuilder, batch_of
from iceberg.values import Datum
from orca.tables import load_dataset
from parquet import RecordBatch

from cols import bool_at, col, i32_at, i64_at, str_at, str_range
from days import day_text, days_of
from jscan import Range, field, text, timestamp_micros
from lake import (
    EVENTS,
    activity_schema,
    date,
    releases_schema,
    str_or_null,
    ts_or_null,
)


@fieldwise_init
struct ActivityRow(Copyable, Movable):
    var repo: String
    var day: Int64
    """Days since 1970-01-01."""
    var events: Int64
    var stars: Int64
    var forks: Int64
    var releases: Int64
    var issues_opened: Int64
    var prs_opened: Int64
    var pushes: Int64
    var actors: Int64


@fieldwise_init
struct ReleaseRow(Copyable, Movable):
    var repo: String
    var day: Int64
    var tag: String
    var name: String
    var published_at: Int64
    var prerelease: Bool
    var actor: String


@fieldwise_init
struct DayActivity(Copyable, Movable):
    """What a day's task sends back."""

    var day: Int64
    var rows: Seq[ActivityRow]
    var releases: Seq[ReleaseRow]
    var scanned: Int
    """Events read, of every repository."""
    var ms: Int


struct Acc(Copyable, Movable):
    """One repository's counts on one day so far."""

    var row: ActivityRow
    var actors: Dict[String, Bool]

    def __init__(out self, repo: String, day: Int64):
        self.row = ActivityRow(repo, day, 0, 0, 0, 0, 0, 0, 0, 0)
        self.actors = Dict[String, Bool]()


def _action(p: Span[UInt8, _]) -> String:
    return text(p, field(p, Range(0, len(p)), "action"))


def parse_release(
    repo: String, day: Int64, actor: String, p: Span[UInt8, _]
) -> Optional[ReleaseRow]:
    """The release a ReleaseEvent published, or None for another action
    (`created`, `edited`, ...) or a payload without a tag."""
    if _action(p) != "published":
        return None
    var r = field(p, Range(0, len(p)), "release")
    if not r.found():
        return None
    var tag = text(p, field(p, r, "tag_name"))
    if tag.byte_length() == 0:
        return None
    return ReleaseRow(
        repo,
        day,
        tag,
        text(p, field(p, r, "name")),
        timestamp_micros(p, field(p, r, "published_at")),
        text(p, field(p, r, "prerelease")) == "true",
        actor,
    )


def add_event(
    mut acc: Acc,
    mut releases: List[ReleaseRow],
    type: StringSlice,
    actor: String,
    payload: Span[UInt8, _],
):
    """Counts one event of the repository `acc` is for."""
    acc.row.events += 1
    if actor.byte_length() > 0:
        acc.actors[actor] = True
    if type == "WatchEvent":
        acc.row.stars += 1
    elif type == "ForkEvent":
        acc.row.forks += 1
    elif type == "PushEvent":
        acc.row.pushes += 1
    elif type == "IssuesEvent":
        if _action(payload) == "opened":
            acc.row.issues_opened += 1
    elif type == "PullRequestEvent":
        if _action(payload) == "opened":
            acc.row.prs_opened += 1
    elif type == "ReleaseEvent":
        var rel = parse_release(acc.row.repo, acc.row.day, actor, payload)
        if rel:
            acc.row.releases += 1
            releases.append(rel.take())


def finish(var accs: Dict[String, Acc]) -> List[ActivityRow]:
    """The rows, by repository name."""
    var out = List[ActivityRow]()
    for e in accs.items():
        var row = e.value.row.copy()
        row.actors = Int64(len(e.value.actors))
        out.append(row^)
    for i in range(1, len(out)):
        var j = i
        while j > 0 and out[j - 1].repo > out[j].repo:
            out.swap_elements(j - 1, j)
            j -= 1
    return out^


def fold_batch(
    b: RecordBatch,
    day: Int64,
    repos: Dict[String, Bool],
    mut accs: Dict[String, Acc],
    mut releases: List[ReleaseRow],
) raises:
    """Adds a batch's events of `repos` (columns type, repo, actor, payload)."""
    ref ty = b.column(col(b, "type"))
    ref rp = b.column(col(b, "repo"))
    ref ac = b.column(col(b, "actor"))
    ref pl = b.column(col(b, "payload"))
    var pv = Span(pl.values)
    for r in range(b.num_rows):
        var repo = str_at(rp, r)
        if repo not in repos:
            continue
        if repo not in accs:
            accs[repo] = Acc(repo, day)
        var pr = str_range(pl, r)
        var t = str_at(ty, r)
        add_event(accs[repo], releases, t, str_at(ac, r), pv[pr[0] : pr[1]])


def encode_job(day: String, snapshot: Int64, repos: List[String]) -> String:
    """A day's task argument: the day, the events snapshot, the repositories."""
    var s = String(day, "\n", snapshot)
    for r in repos:
        s += "\n"
        s += r
    return s^


def day_activity(job: String) raises -> DayActivity:
    """On a worker: one day of gharchive.events (at the step's pinned
    snapshot) for the repositories in `job` (`encode_job`)."""
    var t0 = perf_counter_ns()
    var lines = job.split("\n")
    var day = String(lines[0])
    var snapshot = Int64(Int(lines[1]))
    var repos = Dict[String, Bool]()
    for i in range(2, len(lines)):
        repos[String(lines[i])] = True
    var d = days_of(day)
    var accs = Dict[String, Acc]()
    var releases = List[ReleaseRow]()
    var scanned = 0
    try:
        var events = load_dataset(EVENTS)
        var filter = String(
            '["and",[">=","created_at","', day, 'T00:00:00Z"],',
            '["<","created_at","', day_text(d + 1), 'T00:00:00Z"]]',
        )
        var reader = (
            events.scan()
            .use_snapshot(snapshot)
            .filter(filter)
            .select(["type", "repo", "actor", "payload"])
            .to_batch_reader()
        )
        while True:
            var next = reader.next_batch()
            if not next:
                break
            var b = next.take()
            scanned += b.num_rows
            fold_batch(b, d, repos, accs, releases)
    except e:
        raise Error(day, ": reading ", EVENTS, ": ", e)
    var rows = Seq[ActivityRow]()
    for ref r in finish(accs^):
        rows.append(r.copy())
    var rels = Seq[ReleaseRow]()
    for ref r in releases:
        rels.append(r.copy())
    return DayActivity(
        d, rows^, rels^, scanned, Int(perf_counter_ns() - t0) // 1_000_000
    )


# ── rows to and from the tables ─────────────────────────────────────────────


def activity_rows(b: RecordBatch) raises -> List[ActivityRow]:
    var out = List[ActivityRow]()
    var c = List[Int]()
    for name in [
        "repo", "day", "events", "stars", "forks", "releases",
        "issues_opened", "prs_opened", "pushes", "actors",
    ]:
        c.append(col(b, name))
    for r in range(b.num_rows):
        out.append(
            ActivityRow(
                str_at(b.column(c[0]), r),
                i32_at(b.column(c[1]), r),
                i64_at(b.column(c[2]), r),
                i64_at(b.column(c[3]), r),
                i64_at(b.column(c[4]), r),
                i64_at(b.column(c[5]), r),
                i64_at(b.column(c[6]), r),
                i64_at(b.column(c[7]), r),
                i64_at(b.column(c[8]), r),
                i64_at(b.column(c[9]), r),
            )
        )
    return out^


def activity_batch(rows: List[ActivityRow]) raises -> RecordBatch:
    var s = activity_schema()
    var cs = List[ColumnBuilder]()
    for i in range(10):
        cs.append(ColumnBuilder.of(s, i + 1))
    for ref r in rows:
        cs[0].add(Datum.string_(r.repo))
        cs[1].add(date(r.day))
        cs[2].add(Datum.long_(r.events))
        cs[3].add(Datum.long_(r.stars))
        cs[4].add(Datum.long_(r.forks))
        cs[5].add(Datum.long_(r.releases))
        cs[6].add(Datum.long_(r.issues_opened))
        cs[7].add(Datum.long_(r.prs_opened))
        cs[8].add(Datum.long_(r.pushes))
        cs[9].add(Datum.long_(r.actors))
    return batch_of(cs)


def release_rows(b: RecordBatch) raises -> List[ReleaseRow]:
    var out = List[ReleaseRow]()
    var c = List[Int]()
    for name in ["repo", "day", "tag", "name", "published_at", "prerelease", "actor"]:
        c.append(col(b, name))
    for r in range(b.num_rows):
        out.append(
            ReleaseRow(
                str_at(b.column(c[0]), r),
                i32_at(b.column(c[1]), r),
                str_at(b.column(c[2]), r),
                str_at(b.column(c[3]), r),
                i64_at(b.column(c[4]), r),
                bool_at(b.column(c[5]), r),
                str_at(b.column(c[6]), r),
            )
        )
    return out^


def releases_batch(rows: List[ReleaseRow]) raises -> RecordBatch:
    var s = releases_schema()
    var cs = List[ColumnBuilder]()
    for i in range(7):
        cs.append(ColumnBuilder.of(s, i + 1))
    for ref r in rows:
        cs[0].add(Datum.string_(r.repo))
        cs[1].add(date(r.day))
        cs[2].add(Datum.string_(r.tag))
        cs[3].add(str_or_null(r.name))
        cs[4].add(ts_or_null(r.published_at))
        cs[5].add(Datum.bool_(r.prerelease))
        cs[6].add(str_or_null(r.actor))
    return batch_of(cs)
