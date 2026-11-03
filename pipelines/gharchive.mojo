"""The gharchive pipeline: each day of GH Archive into `gharchive.events`.

Daily from 2023-01-01, at 03:00 UTC for the day before. A day's step fans
its hours out as dista tasks (download, gunzip, parse), at most `workers`
at a time so a day never sits in memory whole, and appends each hour as it
comes back. An hour is one snapshot; a retried step finds the hours its
earlier attempt committed and skips them without downloading again.

    GHARCHIVE_HOURS=16-17 ./build/gharchive run --partitions 2025-09-15

`GHARCHIVE_HOURS` (`A-B` or `A,B,...`; default all 24) limits the hours, for
trying it locally.
"""

from std.os import getenv, setenv

from dista import ObjectRef, Seq, Task2
from orca import Cron, Ctx, Daily, Day, Mapped, Pipeline, Step, Tasks, orca_main
from orca.tables import append, ensure_table, find_commit
from parquet import RecordBatch

from events import fetch_hour, parse_hours
from lake import EVENTS, events_schema, events_spec


def hour_task(day: String, hour: Int) raises -> Seq[RecordBatch]:
    return Seq[RecordBatch](fetch_hour(day, hour))


comptime Hour = Task2[String, Int, Seq[RecordBatch], hour_task]
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

    var refs = List[ObjectRef[Seq[RecordBatch]]]()
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
        var n = 0
        for b in got.items:
            n += b.num_rows
        var id = append(ctx, table, got.items)
        rows += Int64(n)
        ctx.log(String(day, " hour ", hours[i], ": ", n, " events, snapshot ", id))
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
