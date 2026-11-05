"""The gharchive pipeline: each day of GH Archive into `gharchive.events`.

Daily from 2023-01-01, at 03:00 UTC for the day before. A day's step fans
its hours out as dista tasks, at most `GHARCHIVE_PARALLEL` (default 16: 4 instances of 4 worker processes) at a time. A
task streams its hour in on a reader thread while it gunzips and parses
what has arrived, a window at a time, and writes the Parquet data files
into the table itself; it sends back only
their entries, which the step commits, an hour as one append, in hour
order. An hour is one snapshot; a retried step finds the hours its earlier
attempt committed and skips them without downloading again.

A new run of a day that has rows already (`orca backfill --rerun`)
replaces them: its first hour's commit is an `overwrite` that also removes
every data file the day's partition had, so a day's rows always come from
one run.

    GHARCHIVE_HOURS=16-17 ./build/gharchive run --partitions 2025-09-15

`GHARCHIVE_HOURS` (`A-B` or `A,B,...`; default all 24) limits the hours, for
trying it locally.
"""

from std.os import getenv, setenv
from std.time import perf_counter_ns

from dista import ObjectRef, Task2
from orca import Cron, Ctx, Daily, Day, Mapped, Pipeline, Step, Tasks, orca_main
from orca.tables import ensure_table, load_dataset

from datafiles import DataFiles
from events import fetch_hour, parse_hours
from indexing import commit_hour, committed_hours, day_files
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
    repo_hour_schema,
    repo_hour_spec,
)


def hour_task(day: String, hour: Int) raises -> DataFiles:
    """On a worker: the hour, written into the tables but not committed."""
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


comptime Hour = Task2[String, Int, DataFiles, hour_task]
comptime GhTasks = Tasks[Hour]


def load_day(mut ctx: Ctx, d: Day) raises -> Int64:
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
        ctx, REPO_HOUR, repo_hour_schema(), repo_hour_spec(), props
    )
    var rel_t = ensure_table(
        ctx, GH_RELEASES, gh_releases_schema(), gh_releases_spec(), props
    )
    ref rt = ctx.runtime[GhTasks]()
    var window = max(1, Int(getenv("GHARCHIVE_PARALLEL", "16")))

    # Hours an earlier attempt of this step already committed come first in
    # its commit order; recognise them without fetching anything. Each
    # table counts its own, and the hours are fetched from the first one
    # that is missing from any of them.
    var d_ev = committed_hours(ctx, table, len(hours))
    var d_cand = committed_hours(ctx, cand_t, len(hours))
    var d_hour = committed_hours(ctx, hour_t, len(hours))
    var d_rel = committed_hours(ctx, rel_t, len(hours))
    var done = min(min(d_ev, d_cand), min(d_hour, d_rel))
    if d_ev > 0:
        ctx.log(String(day, ": ", d_ev, " hours already committed"))

    # Rows an earlier run left for this day, which this run's first commit
    # to each table replaces.
    var old = List[String]()
    var old_cand = List[String]()
    var old_hour = List[String]()
    var old_rel = List[String]()
    if d_ev == 0:
        old = day_files(table, day, "created_at")
        if len(old) > 0:
            ctx.log(String(
                day, ": replacing the ", len(old),
                " event files an earlier run committed",
            ))
    if d_cand == 0:
        old_cand = day_files(cand_t, day, "hour")
    if d_hour == 0:
        old_hour = day_files(hour_t, day, "hour")
    if d_rel == 0:
        old_rel = day_files(rel_t, day, "created_at")

    var refs = List[ObjectRef[DataFiles]]()
    var next = done
    while next < len(hours) and next - done < window:
        refs.append(rt.remote[Hour](day, hours[next]))
        next += 1
    var rows = Int64(0)
    for i in range(done, len(hours)):
        var got = rt.get(refs[i - done])
        rt.release(refs[i - done])
        if next < len(hours):
            refs.append(rt.remote[Hour](day, hours[next]))
            next += 1
        var t0 = perf_counter_ns()
        var id: Int64
        try:
            id = commit_hour(ctx, table, i, d_ev, old, got.files.files)
            _ = commit_hour(
                ctx, cand_t, i, d_cand, old_cand, got.index.candidates.files
            )
            _ = commit_hour(
                ctx, hour_t, i, d_hour, old_hour, got.index.repo_hour.files
            )
            _ = commit_hour(
                ctx, rel_t, i, d_rel, old_rel, got.index.releases.files
            )
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
                got.parse_ms, " ms, write ", got.write_ms, " ms, index ",
                got.index_ms, " ms: ", got.index.candidate_rows,
                " candidates, ", got.index.repo_hour_rows, " repo-hours, ",
                got.index.release_rows, " releases; waiting ", got.wait_ms,
                " ms; commit ", commit_ms, " ms)",
            )
        )
    ctx.log(String(day, ": ", rows, " events in ", len(hours) - done, " hours"))
    return rows


comptime LoadDay = Step[
    "load_day",
    Day,
    Int64,
    load_day,
    Mapped,
    retries=2,
    writes=[EVENTS, CANDIDATES, REPO_HOUR, GH_RELEASES],
]
comptime GhArchive = Pipeline[
    "gharchive",
    LoadDay,
    tasks=GhTasks,
    partitions=Daily["2023-01-01"],
    schedule=Cron["0 3 * * *"],  # 03:00 UTC, for the day before
    max_runs=2,  # two days at once: a day's commits (four tables an hour) are serial
    workers=8,
]


def main() raises:
    if not getenv("ORCA_WAREHOUSE"):
        _ = setenv("ORCA_WAREHOUSE", "build/warehouse")
    orca_main[GhArchive]()
