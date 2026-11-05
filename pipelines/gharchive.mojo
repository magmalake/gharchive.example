"""The gharchive pipeline: each day of GH Archive into `gharchive.events`.

Daily from 2023-01-01, at 03:00 UTC for the day before. A day's step fans
its hours out as dista tasks, at most `GHARCHIVE_PARALLEL` at a time. A
task streams its hour in on a reader thread while it gunzips and parses
what has arrived, a window at a time, and writes the Parquet data files
into the table itself; it sends back only
their entries, which the step commits, an hour as one append, in hour
order. An hour is one snapshot; a retried step finds the hours its earlier
attempt committed and skips them without downloading again.

    GHARCHIVE_HOURS=16-17 ./build/gharchive run --partitions 2025-09-15

`GHARCHIVE_HOURS` (`A-B` or `A,B,...`; default all 24) limits the hours, for
trying it locally.
"""

from std.os import getenv, setenv
from std.time import perf_counter_ns

from dista import ObjectRef, Task2
from iceberg.commit import FileChanges
from orca import Cron, Ctx, Daily, Day, Mapped, Pipeline, Step, Tasks, orca_main
from orca.tables import append, commit, ensure_table, find_commit, load_dataset
from parquet import RecordBatch

from datafiles import DataFiles
from events import fetch_hour, parse_hours
from lake import EVENTS, events_schema, events_spec


def hour_task(day: String, hour: Int) raises -> DataFiles:
    """On a worker: the hour, written into the table but not committed."""
    try:
        return fetch_hour(day, hour, load_dataset(EVENTS))
    except e:
        raise Error(day, " hour ", hour, ": ", e)


comptime Hour = Task2[String, Int, DataFiles, hour_task]
comptime GhTasks = Tasks[Hour]


def load_day(mut ctx: Ctx, d: Day) raises -> Int64:
    var day = String(d)
    var hours = parse_hours(getenv("GHARCHIVE_HOURS"))
    var table = ensure_table(ctx, EVENTS, events_schema(), events_spec())
    ref rt = ctx.runtime[GhTasks]()
    var window = max(1, Int(getenv("GHARCHIVE_PARALLEL", "4")))

    # Hours an earlier attempt of this step already committed come first in
    # its commit order; recognise them without fetching anything.
    var done = 0
    while done < len(hours) and find_commit(ctx, table) >= 0:
        _ = append(ctx, table, List[RecordBatch]())
        done += 1
    if done > 0:
        ctx.log(String(day, ": ", done, " hours already committed"))

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
            if len(got.files) == 0:
                id = append(ctx, table, List[RecordBatch]())
            else:
                var changes = FileChanges()
                changes.added_data = got.files.copy()
                id = commit(ctx, table, "append", changes^)
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
                got.parse_ms, " ms, write ", got.write_ms, " ms, waiting ",
                got.wait_ms, " ms; commit ", commit_ms, " ms)",
            )
        )
    ctx.log(String(day, ": ", rows, " events in ", len(hours) - done, " hours"))
    return rows


comptime LoadDay = Step[
    "load_day", Day, Int64, load_day, Mapped, retries=2, writes=[EVENTS]
]
comptime GhArchive = Pipeline[
    "gharchive",
    LoadDay,
    tasks=GhTasks,
    partitions=Daily["2023-01-01"],
    schedule=Cron["0 3 * * *"],  # 03:00 UTC, for the day before
    workers=4,
]


def main() raises:
    if not getenv("ORCA_WAREHOUSE"):
        _ = setenv("ORCA_WAREHOUSE", "build/warehouse")
    orca_main[GhArchive]()
