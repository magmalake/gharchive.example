"""The gharchive_index pipeline: `gharchive.candidates`, `gharchive.repo_hour`
and `gharchive.releases` for days whose events were loaded before gharchive
wrote them.

A one-off, run by hand (`orca backfill gharchive_index 2026-10-01..2026-11-04`).
For each day, a dista task per hour reads that hour of `gharchive.events` once
and builds the same three tables gharchive builds from the download
(`hourindex.HourIndex`); the step commits an hour as one snapshot of each
table, in order, and a first commit replaces what an earlier run left for the
day, exactly as gharchive does. `gharchive.events` isn't touched. Days with no
events are skipped.

    ./build/gharchive_index run --partitions 2026-11-03
"""

from std.os import getenv, setenv
from std.time import perf_counter_ns

from dista import ObjectRef, Task
from orca import Ctx, Daily, Day, Mapped, Pipeline, Step, Tasks, orca_main
from orca.tables import ensure_table, load_dataset, scan, table
from parquet import RecordBatch

from cols import col, i64_at, str_at, str_range
from days import day_text, days_of
from hourindex import HourIndex, IndexFiles, write_index
from indexing import commit_hour, committed_hours, day_files
from lake import (
    CANDIDATES,
    EVENTS,
    GH_RELEASES,
    REPO_HOUR,
    candidates_schema,
    candidates_spec,
    gh_releases_schema,
    gh_releases_spec,
    index_properties,
    repo_hour_schema,
    repo_hour_spec,
)


def _fold(mut index: HourIndex, b: RecordBatch, lo: Int64) raises:
    ref ty = b.column(col(b, "type"))
    ref rp = b.column(col(b, "repo"))
    ref ac = b.column(col(b, "actor"))
    ref at = b.column(col(b, "created_at"))
    ref pl = b.column(col(b, "payload"))
    var pv = Span(pl.values)
    for r in range(b.num_rows):
        var at_r = i64_at(at, r)
        if at_r < lo or at_r >= lo + 3_600_000_000:
            continue  # the filter keeps whole row groups
        var pr = str_range(pl, r)
        index.add(
            str_at(ty, r), str_at(rp, r), str_at(ac, r), at_r,
            pv[pr[0] : pr[1]],
        )


def index_hour(job: String) raises -> IndexFiles:
    """On a worker: one hour of `gharchive.events` (at the snapshot in `job`,
    `day\\nhour\\nsnapshot`) as index files, uncommitted."""
    var parts = job.split("\n")
    var day = String(parts[0])
    var hour = Int(parts[1])
    var snapshot = Int64(Int(parts[2]))
    var lo = days_of(day) * 86_400_000_000 + Int64(hour) * 3_600_000_000
    var index = HourIndex(lo)
    try:
        var events = load_dataset(EVENTS)
        var filter = String(
            '["and",[">=","created_at",', lo, '],["<","created_at",',
            lo + 3_600_000_000, "]]",
        )
        var reader = (
            events.scan()
            .use_snapshot(snapshot)
            .filter(filter)
            .select(["type", "repo", "actor", "created_at", "payload"])
            .to_batch_reader()
        )
        while True:
            var next = reader.next_batch()
            if not next:
                break
            _fold(index, next.take(), lo)
        return write_index(
            index,
            load_dataset(CANDIDATES),
            load_dataset(REPO_HOUR),
            load_dataset(GH_RELEASES),
        )
    except e:
        raise Error(day, " hour ", hour, ": ", e)


comptime IndexHour = Task[String, IndexFiles, index_hour]
comptime IndexTasks = Tasks[IndexHour]


def index_day(mut ctx: Ctx, d: Day) raises -> Int64:
    var day = String(d)
    var events = table(ctx, EVENTS)
    if len(day_files(events, day, "created_at")) == 0:
        ctx.log(String(day, ": no events loaded, nothing to index"))
        return 0
    var pinned = scan(ctx, events).snapshot().snapshot_id
    var props = index_properties()
    var cand_t = ensure_table(
        ctx, CANDIDATES, candidates_schema(), candidates_spec(), props
    )
    var hour_t = ensure_table(
        ctx, REPO_HOUR, repo_hour_schema(), repo_hour_spec(), props
    )
    var rel_t = ensure_table(
        ctx, GH_RELEASES, gh_releases_schema(), gh_releases_spec(), props
    )
    ref rt = ctx.runtime[IndexTasks]()
    var window = max(1, Int(getenv("GHARCHIVE_PARALLEL", "4")))
    var n = 24
    var d_cand = committed_hours(ctx, cand_t, n)
    var d_hour = committed_hours(ctx, hour_t, n)
    var d_rel = committed_hours(ctx, rel_t, n)
    var done = min(d_cand, min(d_hour, d_rel))
    var old_cand = List[String]()
    var old_hour = List[String]()
    var old_rel = List[String]()
    if d_cand == 0:
        old_cand = day_files(cand_t, day, "hour")
    if d_hour == 0:
        old_hour = day_files(hour_t, day, "hour")
    if d_rel == 0:
        old_rel = day_files(rel_t, day, "created_at")
    var refs = List[ObjectRef[IndexFiles]]()
    var next = done
    while next < n and next - done < window:
        refs.append(rt.remote[IndexHour](String(day, "\n", next, "\n", pinned)))
        next += 1
    var rows = Int64(0)
    for i in range(done, n):
        var got = rt.get(refs[i - done])
        rt.release(refs[i - done])
        if next < n:
            refs.append(rt.remote[IndexHour](String(day, "\n", next, "\n", pinned)))
            next += 1
        try:
            _ = commit_hour(ctx, cand_t, i, d_cand, old_cand, got.candidates.files)
            _ = commit_hour(ctx, hour_t, i, d_hour, old_hour, got.repo_hour.files)
            _ = commit_hour(ctx, rel_t, i, d_rel, old_rel, got.releases.files)
        except e:
            raise Error(day, " hour ", i, ": committing: ", e)
        rows += Int64(got.repo_hour_rows)
        ctx.log(String(
            day, " hour ", i, ": ", got.candidate_rows, " candidates, ",
            got.repo_hour_rows, " repo-hours, ", got.release_rows,
            " releases (write ", got.write_ms, " ms)",
        ))
    ctx.log(String(day, ": ", rows, " repo-hour rows in ", n - done, " hours"))
    return rows


comptime IndexDay = Step[
    "index_day",
    Day,
    Int64,
    index_day,
    Mapped,
    retries=2,
    reads=[EVENTS],
    writes=[CANDIDATES, REPO_HOUR, GH_RELEASES],
]
comptime GhArchiveIndex = Pipeline[
    "gharchive_index",
    IndexDay,
    tasks=IndexTasks,
    partitions=Daily["2023-01-01"],
    workers=4,
]


def main() raises:
    if not getenv("ORCA_WAREHOUSE"):
        _ = setenv("ORCA_WAREHOUSE", "build/warehouse")
    orca_main[GhArchiveIndex]()
