"""The gharchive pipeline: each day of GH Archive into `gharchive.events`.

Daily from 2023-01-01, at 03:00 UTC for the day before. A day's step fans
its hours out as dista tasks, at most `GHARCHIVE_PARALLEL` (default 16: 4 instances of 4 worker processes) at a time. A
task streams its hour in on a reader thread while it gunzips and parses
what has arrived, a window at a time, and writes the Parquet data files
into the table itself; it sends back only
their entries, which the step commits to `gharchive.events`, an hour as one
append, in hour order. An hour is one snapshot; a retried step finds the
hours its earlier attempt committed and skips them without downloading again.

The same tasks build the hour's rows of `gharchive.candidates`,
`gharchive.repo_hour` and `gharchive.releases`; the step keeps their files and
commits each of those tables once, at the end, with all the day's hours (one
snapshot a table and day, not an hour). The files of an hour a retry skips
died with the failed attempt, so the retry builds their rows again from
`gharchive.events` (`reindex.index_hour`, as gharchive_index does), and finds
the day's index commits, if the attempt got as far as making them.

A new run of a day that has rows already (`orca backfill --rerun`)
replaces them: its first hour's commit to the events, and the day commit to
each index table, is an `overwrite` that also removes every data file the
day's partition had, so a day's rows always come from one run.

    GHARCHIVE_HOURS=16-17 ./build/gharchive run --partitions 2025-09-15

An hour in flight takes about `eventrows.HOUR_MEMORY_MB` (450 MB on the
busiest hours, 2023-2025) and the run about 300 MB more, so a run's memory is
about 300 + 450 * `GHARCHIVE_PARALLEL` MB (magmalake/mojo-census#37): the
rows of one 50,000-row file at a time, written a 16 MB row group at a time,
and the compressed hour only as far as it is decoded.

`GHARCHIVE_HOURS` (`A-B` or `A,B,...`; default all 24) limits the hours, for
trying it locally. `GHARCHIVE_FAIL_AFTER=k` (or `end`, after the index
commits) makes the first attempt of a step fail after it committed k hours of
events, to try a retry (`scripts/test-daily.sh`).
"""

from std.os import getenv, setenv
from std.time import perf_counter_ns

from dista import ObjectRef, Task, Task2
from orca import Cron, Ctx, Daily, Day, Mapped, Pipeline, Step, Tasks, orca_main
from iceberg.catalog.filesystem import Table
from iceberg.manifest import DataFile
from orca.tables import ensure_table, find_commit, load_dataset

from datafiles import DataFiles
from daymerge import merge_job, merge_repo_hour
from days import days_of
from eventrows import HOUR_MEMORY_MB
from events import fetch_hour, parse_hours
from hourindex import IndexFiles, write_marker
from indexing import commit_day, commit_hour, committed_hours, day_files
from lake import (
    CANDIDATES,
    EVENTS,
    GH_RELEASES,
    REPO_HOUR,
    candidates_schema,
    candidates_spec,
    events_properties,
    events_schema,
    events_spec,
    gh_releases_schema,
    gh_releases_spec,
    index_properties,
    repo_hour_properties,
    repo_hour_schema,
    repo_hour_spec,
)
from reindex import index_hour, index_job


def hour_task(day: String, hour: Int) raises -> DataFiles:
    """On a worker: the hour, written into the tables but not committed.
    The event files and the hour's three index files come back as entries
    (`DataFiles`), which the step commits; nothing else crosses back."""
    try:
        return fetch_hour(
            day,
            hour,
            load_dataset(EVENTS),
            load_dataset(CANDIDATES),
            load_dataset(REPO_HOUR),
            load_dataset(GH_RELEASES),
        )
    except e:
        raise Error(day, " hour ", hour, ": ", e)


# A dista `Task` is a function that runs on a worker process (`Task2` takes
# two arguments). The step starts them with `rt.remote[...]`, which returns an
# `ObjectRef`: a future for the result, read with `rt.get`. `Hour` is the
# main one, a download and parse of one hour; `IndexHour` rebuilds an hour's
# index files from `gharchive.events` when a retry skipped it; `MergeHours`
# writes a day's `repo_hour` files as one. `Tasks[...]` lists them all, and
# orca starts one dista runtime for the run before its first step, which the
# step reaches through `ctx.runtime`.
comptime IndexHour = Task[String, IndexFiles, index_hour]
comptime Hour = Task2[String, Int, DataFiles, hour_task]
comptime MergeHours = Task[String, IndexFiles, merge_repo_hour]
comptime GhTasks = Tasks[Hour, IndexHour, MergeHours]


def _marker_if_empty(
    mut files: List[DataFile], day: String, which: Int, t: Table
) raises:
    """A day with no rows for `t` at all: its commit needs a file, since a
    snapshot needs one, so it gets the marker row `hourindex.HourIndex`
    describes."""
    if len(files) == 0:
        files = write_marker(days_of(day) * 86_400_000_000, which, t).files.copy()


def load_day(mut ctx: Ctx, d: Day) raises -> Int64:
    """The step: one day of GH Archive into the four tables. Hours are read
    on workers, `window` at a time, and committed here in hour order.
    Returns the number of events committed by this attempt (a retry that
    skipped hours counts only the rest)."""
    var day = String(d)
    var hours = parse_hours(getenv("GHARCHIVE_HOURS"))
    var props = index_properties()
    var table = ensure_table(
        ctx, EVENTS, events_schema(), events_spec(), events_properties()
    )
    var cand_t = ensure_table(
        ctx, CANDIDATES, candidates_schema(), candidates_spec(), props
    )
    var hour_t = ensure_table(
        ctx,
        REPO_HOUR,
        repo_hour_schema(),
        repo_hour_spec(),
        repo_hour_properties(),
    )
    var rel_t = ensure_table(
        ctx, GH_RELEASES, gh_releases_schema(), gh_releases_spec(), props
    )
    ref rt = ctx.runtime[GhTasks]()
    # Hours in flight at once. Memory is what limits it: an hour in flight
    # takes about 2 GB (magmalake/mojo-census#37, not yet explained or
    # bounded), so the default of 16 is sized for several machines; orca.toml
    # sets 2 for the 8 GB Hetzner server.
    var window = max(1, Int(getenv("GHARCHIVE_PARALLEL", "16")))
    var in_flight = min(window, len(hours))
    ctx.log(String(
        day, ": ", in_flight, " hours in flight, about ",
        300 + in_flight * HOUR_MEMORY_MB, " MB",
    ))

    # Hours an earlier attempt of this step already committed to the events
    # come first in its commit order; recognise them without fetching
    # anything. The three index tables get one commit a day, at the end: an
    # attempt that got that far has made commit 0 to each (`find_commit`).
    var d_ev = committed_hours(ctx, table, len(hours))
    var indexed = (
        find_commit(ctx, cand_t) >= 0
        and find_commit(ctx, hour_t) >= 0
        and find_commit(ctx, rel_t) >= 0
    )
    if d_ev > 0:
        ctx.log(String(day, ": ", d_ev, " hours already committed"))

    # Rows an earlier run left for this day, which this run's first commit
    # to the events replaces (the index tables' day commit does the same).
    var old = List[String]()
    if d_ev == 0:
        old = day_files(table, day, "created_at")
        if len(old) > 0:
            ctx.log(String(
                day, ": replacing the ", len(old),
                " event files an earlier run committed",
            ))

    # The index files of every hour, in hour order, committed together at
    # the end. An hour whose events an earlier attempt committed lost its
    # index files with that attempt: build them again from the events, as
    # gharchive_index does, unless the index was committed too.
    var idx = List[IndexFiles]()
    for _ in range(len(hours)):
        idx.append(IndexFiles())
    if d_ev > 0 and not indexed:
        var pinned = table.metadata.current_snapshot_id
        ctx.log(String(
            day, ": rebuilding the index of the ", d_ev,
            " committed hours from the events (snapshot ", pinned, ")",
        ))
        var t_re = perf_counter_ns()
        var back = List[ObjectRef[IndexFiles]]()
        var sent = 0
        while sent < d_ev and sent < window:
            back.append(
                rt.remote[IndexHour](index_job(day, hours[sent], pinned, False))
            )
            sent += 1
        for i in range(d_ev):
            var got = rt.get(back[i])
            rt.release(back[i])
            if sent < d_ev:
                back.append(
                    rt.remote[IndexHour](
                        index_job(day, hours[sent], pinned, False)
                    )
                )
                sent += 1
            idx[i] = got^
        ctx.log(String(
            day, ": rebuilt ", d_ev, " hours of the index in ",
            Int(perf_counter_ns() - t_re) // 1_000_000, " ms",
        ))

    # A sliding window of futures: start `window` hours, then each time the
    # oldest finishes (`rt.get`) and is released (`rt.release` frees its
    # result on the worker), start the next one. Results are consumed in hour
    # order because the commits must be, so a slow hour holds up the commit of
    # the later ones (their tasks keep running meanwhile).
    var refs = List[ObjectRef[DataFiles]]()
    var next = d_ev
    while next < len(hours) and next - d_ev < window:
        refs.append(rt.remote[Hour](day, hours[next]))
        next += 1
    var rows = Int64(0)
    var fail = getenv("GHARCHIVE_FAIL_AFTER")
    var fail_after = Int(fail) if fail and fail != "end" else 0
    for i in range(d_ev, len(hours)):
        var got = rt.get(refs[i - d_ev])
        rt.release(refs[i - d_ev])
        if next < len(hours):
            refs.append(rt.remote[Hour](day, hours[next]))
            next += 1
        # One snapshot of the events per hour: the first one of a rerun
        # replaces the day's old files, a retry's recommit is recognised.
        var t0 = perf_counter_ns()
        var id: Int64
        try:
            id = commit_hour(ctx, table, i, d_ev, old, got.files.files)
        except e:
            raise Error(day, " hour ", hours[i], ": committing: ", e)
        var commit_ms = Int(perf_counter_ns() - t0) // 1_000_000
        rows += Int64(got.rows)
        ctx.log(
            String(
                day, " hour ", hours[i], ": ", got.rows, " events in ",
                len(got.files), " files, snapshot ", id, " (task ",
                got.total_ms, " ms: download ", got.download_ms,
                " ms overlapping gunzip ", got.gunzip_ms, " ms, parse ",
                got.parse_ms, " ms, sort ", got.sort_ms, " ms, write ",
                got.write_ms, " ms, index ",
                got.index_ms, " ms: ", got.index.candidate_rows,
                " candidates, ", got.index.repo_hour_rows, " repo-hours, ",
                got.index.release_rows, " releases; waiting ", got.wait_ms,
                " ms; commit ", commit_ms, " ms)",
            )
        )
        idx[i] = got.index.copy()
        # A test hook: the first attempt fails after this many hours.
        if fail_after > 0 and ctx.attempt <= 1 and i + 1 == fail_after:
            raise Error(day, ": GHARCHIVE_FAIL_AFTER=", fail_after)

    # One commit a day to each index table, all 24 hours' files in hour order.
    var t1 = perf_counter_ns()
    var cand = List[DataFile]()
    var per_hour = List[DataFile]()
    var rel = List[DataFile]()
    for ref f in idx:
        cand.extend(f.candidates.files.copy())
        per_hour.extend(f.repo_hour.files.copy())
        rel.extend(f.releases.files.copy())
    if not indexed and len(per_hour) > 1:
        # The day's repo_hour rows as one file: a dictionary needs more rows
        # than an hour has to pay for itself.
        var paths = List[String]()
        for ref f in per_hour:
            paths.append(f.file_path)
        var merging = rt.remote[MergeHours](merge_job(paths))
        var merged = rt.get(merging)
        rt.release(merging)
        per_hour = merged.repo_hour.files.copy()
        ctx.log(String(
            day, ": repo_hour merged from ", len(paths), " files to ",
            len(per_hour), " (", merged.repo_hour_rows, " rows, ",
            merged.write_ms, " ms)",
        ))
    if not indexed:
        _marker_if_empty(cand, day, 0, cand_t)
        _marker_if_empty(per_hour, day, 1, hour_t)
        _marker_if_empty(rel, day, 2, rel_t)
    try:
        _ = commit_day(ctx, cand_t, day, "hour", cand)
        _ = commit_day(ctx, hour_t, day, "hour", per_hour)
        _ = commit_day(ctx, rel_t, day, "created_at", rel)
    except e:
        raise Error(day, ": committing the index: ", e)
    ctx.log(String(
        day, ": index committed in ",
        Int(perf_counter_ns() - t1) // 1_000_000, " ms (",
        len(cand), " + ", len(per_hour), " + ", len(rel), " files)",
    ))
    if fail == "end" and ctx.attempt <= 1:
        raise Error(day, ": GHARCHIVE_FAIL_AFTER=end")
    ctx.log(String(day, ": ", rows, " events in ", len(hours) - d_ev, " hours"))
    return rows


# A `Step` wraps `load_day` with its name, input and output types and kind.
# `Mapped` runs it once per partition of a run, here a `Day`. `writes` lists
# the datasets it commits to (a commit to any other is refused, and the
# lineage in the UI is drawn from it); the replace-the-day logic is done by
# hand in `indexing.commit_hour` rather than by orca's `replaces=`. `retries=2`
# re-runs a failed attempt in the same run, which the commit recognition
# above makes cheap.
comptime LoadDay = Step[
    "load_day",
    Day,
    Int64,
    load_day,
    Mapped,
    retries=2,
    writes=[EVENTS, CANDIDATES, REPO_HOUR, GH_RELEASES],
]
# `Daily["2023-01-01"]` makes the partitions days from that date; the `Cron`
# schedule fires the day's run, and the pipeline is not a sensor, so it is the
# root of the chain: mojo_repos and mojo_activity are sensors on what it
# commits.
comptime GhArchive = Pipeline[
    "gharchive",
    LoadDay,
    tasks=GhTasks,
    partitions=Daily["2023-01-01"],
    schedule=Cron["0 3 * * *"],  # 03:00 UTC, for the day before
    max_runs=2,  # two days at once: a day's commits (the events an hour) are serial
    workers=8,
]


def main() raises:
    if not getenv("ORCA_WAREHOUSE"):
        _ = setenv("ORCA_WAREHOUSE", "build/warehouse")
    orca_main[GhArchive]()
