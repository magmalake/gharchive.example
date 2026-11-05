"""What gharchive learns from an hour's events while it parses them.

`HourIndex.add` sees every event once and keeps three small summaries, each
written as a table beside `gharchive.events` (same hour task, same snapshot
per hour):

- `gharchive.candidates`: the Mojo candidates `detect.scan_event` finds
  (the rules mojo_repos used to apply to the whole day),
- `gharchive.repo_hour`: counts per (repository, actor, hour) of every
  repository, which is what mojo_activity needs to give a repository found
  later its whole history without reading events again. Only a candidate can
  ever enter `mojo.repos` (`detect.verify` runs on candidates alone), but
  which repository that will be isn't known until a later day, so every
  repository is counted,
- `gharchive.releases`: the published ReleaseEvents.
"""

from std.time import perf_counter_ns

from iceberg.batch import ColumnBuilder, batch_of
from iceberg.catalog.filesystem import Table
from iceberg.values import Datum
from orca.tables import DataFiles as FileEntries
from orca.tables import FileWriter
from parquet import RecordBatch

from activity import parse_release
from cols import col, i64_at, str_at
from detect import Candidate, note, scan_event
from jscan import Range, field, text
from lake import (
    candidates_schema,
    gh_releases_schema,
    repo_hour_schema,
    str_or_null,
    ts,
    ts_or_null,
)

comptime HOUR_MICROS: Int64 = 3_600_000_000


@fieldwise_init
struct Cell(Copyable, Movable):
    """One (repository, actor, hour)'s counts."""

    var repo: String
    var actor: String
    var hour: Int64
    var events: Int64
    var stars: Int64
    var forks: Int64
    var releases: Int64
    var issues_opened: Int64
    var prs_opened: Int64
    var pushes: Int64


@fieldwise_init
struct ReleaseEvent(Copyable, Movable):
    var repo: String
    var at: Int64
    var actor: String
    var tag: String
    var name: String
    var published_at: Int64
    var prerelease: Bool


def _action_is(p: Span[UInt8, _], want: StringSlice) -> Bool:
    return text(p, field(p, Range(0, len(p)), "action")) == want


struct HourIndex(Movable):
    var found: Dict[String, Candidate]
    """Candidates by repository, in the order they were first noticed."""
    var at: Dict[String, Int]
    """Key of a cell -> its place in `cells`."""
    var cells: List[Cell]
    var releases: List[ReleaseEvent]
    var events: Int
    var marker: Int64
    """The hour's start, when the batches of an hour with nothing to put in
    a table carry one row for no repository (`repo` is empty) instead: a
    snapshot needs a data file, and one commit per table and hour keeps a
    retry's numbering aligned. Nothing matches that row."""

    def __init__(out self, marker: Int64 = 0):
        self.marker = marker
        self.found = Dict[String, Candidate]()
        self.at = Dict[String, Int]()
        self.cells = List[Cell]()
        self.releases = List[ReleaseEvent]()
        self.events = 0

    def add(
        mut self,
        type: String,
        repo: String,
        actor: String,
        at: Int64,
        payload: Span[UInt8, _],
    ) raises:
        """Counts one event and notes the candidates it points at."""
        self.events += 1
        scan_event(self.found, type, repo, at, payload)
        var hour = at - at % HOUR_MICROS
        var key = String(repo, "\x1f", actor, "\x1f", hour)
        var i: Int
        if key in self.at:
            i = self.at[key]
        else:
            i = len(self.cells)
            self.at[key^] = i
            self.cells.append(
                Cell(repo, actor, hour, 0, 0, 0, 0, 0, 0, 0)
            )
        ref c = self.cells[i]
        c.events += 1
        if type == "WatchEvent":
            c.stars += 1
        elif type == "ForkEvent":
            c.forks += 1
        elif type == "PushEvent":
            c.pushes += 1
        elif type == "IssuesEvent":
            if _action_is(payload, "opened"):
                c.issues_opened += 1
        elif type == "PullRequestEvent":
            if _action_is(payload, "opened"):
                c.prs_opened += 1
        elif type == "ReleaseEvent":
            var rel = parse_release(repo, 0, actor, payload)
            if rel:
                var r = rel.take()
                c.releases += 1
                self.releases.append(
                    ReleaseEvent(
                        repo, at, actor, r.tag, r.name, r.published_at,
                        r.prerelease,
                    )
                )

    def candidate_batch(self) raises -> RecordBatch:
        """One row per (repository, hour, reason)."""
        var s = candidates_schema()
        var c_repo = ColumnBuilder.of(s, 1)
        var c_hour = ColumnBuilder.of(s, 2)
        var c_reason = ColumnBuilder.of(s, 3)
        var c_seen = ColumnBuilder.of(s, 4)
        var c_sha = ColumnBuilder.of(s, 5)
        for e in self.found.items():
            ref c = e.value
            var hour = c.first_seen - c.first_seen % HOUR_MICROS
            for reason in c.signals.split(","):
                c_repo.add(Datum.string_(c.repo))
                c_hour.add(ts(hour))
                c_reason.add(Datum.string_(String(reason)))
                c_seen.add(ts(c.first_seen))
                c_sha.add(str_or_null(c.sha))
        if len(c_repo) == 0 and self.marker > 0:
            c_repo.add(Datum.string_(""))
            c_hour.add(ts(self.marker))
            c_reason.add(Datum.string_("hour"))
            c_seen.add(ts(self.marker))
            c_sha.add(Datum.none())
        return batch_of([c_repo^, c_hour^, c_reason^, c_seen^, c_sha^])

    def repo_hour_batch(self) raises -> RecordBatch:
        """The cells sorted by (repository, actor, hour)."""
        var keys = List[String]()
        for e in self.at.items():
            keys.append(e.key)
        sort(keys)
        var s = repo_hour_schema()
        var cs = List[ColumnBuilder]()
        for i in range(10):
            cs.append(ColumnBuilder.of(s, i + 1))
        for ref k in keys:
            ref c = self.cells[self.at[k]]
            cs[0].add(Datum.string_(c.repo))
            cs[1].add(ts(c.hour))
            cs[2].add(str_or_null(c.actor))
            cs[3].add(Datum.long_(c.events))
            cs[4].add(Datum.long_(c.stars))
            cs[5].add(Datum.long_(c.forks))
            cs[6].add(Datum.long_(c.releases))
            cs[7].add(Datum.long_(c.issues_opened))
            cs[8].add(Datum.long_(c.prs_opened))
            cs[9].add(Datum.long_(c.pushes))
        if len(keys) == 0 and self.marker > 0:
            cs[0].add(Datum.string_(""))
            cs[1].add(ts(self.marker))
            cs[2].add(Datum.none())
            for i in range(3, 10):
                cs[i].add(Datum.long_(0))
        return batch_of(cs)

    def releases_batch(self) raises -> RecordBatch:
        var s = gh_releases_schema()
        var cs = List[ColumnBuilder]()
        for i in range(7):
            cs.append(ColumnBuilder.of(s, i + 1))
        for ref r in self.releases:
            cs[0].add(Datum.string_(r.repo))
            cs[1].add(ts(r.at))
            cs[2].add(str_or_null(r.actor))
            cs[3].add(Datum.string_(r.tag))
            cs[4].add(str_or_null(r.name))
            cs[5].add(ts_or_null(r.published_at))
            cs[6].add(Datum.bool_(r.prerelease))
        if len(self.releases) == 0 and self.marker > 0:
            cs[0].add(Datum.string_(""))
            cs[1].add(ts(self.marker))
            cs[2].add(Datum.none())
            cs[3].add(Datum.string_(""))
            cs[4].add(Datum.none())
            cs[5].add(Datum.none())
            cs[6].add(Datum.bool_(False))
        return batch_of(cs)


struct IndexFiles(Copyable, Movable):
    """An hour's index files, written but not committed: a plain struct for
    dista's reflection, the `FileEntries` through their own `Codec`."""

    var candidates: FileEntries
    var repo_hour: FileEntries
    var releases: FileEntries
    var candidate_rows: Int
    var repo_hour_rows: Int
    var release_rows: Int
    var write_ms: Int

    def __init__(out self):
        self.candidates = FileEntries()
        self.repo_hour = FileEntries()
        self.releases = FileEntries()
        self.candidate_rows = 0
        self.repo_hour_rows = 0
        self.release_rows = 0
        self.write_ms = 0


def _write(table: Table, var batch: RecordBatch) raises -> FileEntries:
    """A batch into a table's data files, uncommitted."""
    var w = FileWriter(table)
    if batch.num_rows > 0:
        w.put(batch^)
    return w^.finish()


def write_index(
    index: HourIndex, candidates: Table, repo_hour: Table, releases: Table
) raises -> IndexFiles:
    """On a worker: the hour's three summaries into their tables."""
    var t0 = perf_counter_ns()
    var out = IndexFiles()
    var cb = index.candidate_batch()
    out.candidate_rows = cb.num_rows
    out.candidates = _write(candidates, cb^)
    var hb = index.repo_hour_batch()
    out.repo_hour_rows = hb.num_rows
    out.repo_hour = _write(repo_hour, hb^)
    var rb = index.releases_batch()
    out.release_rows = rb.num_rows
    out.releases = _write(releases, rb^)
    out.write_ms = Int(perf_counter_ns() - t0) // 1_000_000
    return out^


def candidates_from(batches: List[RecordBatch]) raises -> Dict[String, Candidate]:
    """Candidates from rows of `gharchive.candidates` (columns repo, reason,
    first_seen, sha), merged the way `detect.scan_event` merges them over a
    day's events: signals added in the order they were noticed, the earliest
    `first_seen`, the first `sha`."""
    var repos = List[String]()
    var reasons = List[String]()
    var seen = List[Int64]()
    var shas = List[String]()
    for ref b in batches:
        var c_repo = col(b, "repo")
        var c_reason = col(b, "reason")
        var c_seen = col(b, "first_seen")
        var c_sha = col(b, "sha")
        for r in range(b.num_rows):
            repos.append(str_at(b.column(c_repo), r))
            reasons.append(str_at(b.column(c_reason), r))
            seen.append(i64_at(b.column(c_seen), r))
            shas.append(str_at(b.column(c_sha), r))
    # Event order: by first_seen (ms), then as the rows were read.
    var keys = List[Int64]()
    for i in range(len(repos)):
        keys.append(((seen[i] // 1000) << 20) | Int64(i & 0xFFFFF))
    sort(keys)
    var found = Dict[String, Candidate]()
    for k in keys:
        var i = Int(k & 0xFFFFF)
        note(found, repos[i], reasons[i], seen[i], shas[i])
    return found^
