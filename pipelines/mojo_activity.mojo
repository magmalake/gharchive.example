"""The mojo_activity pipeline: each Mojo repository's activity per day, from
GH Archive, with no API calls.

Daily from 2023-01-01 and a sensor on `gharchive.events` and `mojo.repos`:
each day gharchive loads starts a run for that day, and so does each
snapshot mojo_repos adds repositories in. A run's one step reads the day's
events for every repository in `mojo.repos` and writes `mojo.activity`
(counts per repository and day) and `mojo.releases` (published releases).

**Repositories found later get their whole history.** A repository isn't
caught up until it is in `mojo.activity_repos`. A run that finds members
of `mojo.repos` that aren't also reads, for them, every other day
`gharchive.events` has (from the day each was created), and records them
there; from then on every day's run includes them as members. Each day's
scan is a dista task, so a run that catches up reads its days in parallel.

**Reruns don't duplicate rows.** A run replaces, in the month partitions it
touches, the rows of the (repository, day) pairs it computed and keeps the
others (`replace.replace_files`: one overwrite snapshot a table). The
pipeline runs one run at a time (`max_runs=1`), so no two runs replace the
same partition at once.

    ./build/mojo_activity run --partitions 2026-11-03
"""

from std.os import getenv, setenv
from std.time import perf_counter_ns

from dista import ObjectRef, Task
from iceberg.batch import ColumnBuilder, batch_of
from iceberg.catalog.filesystem import Table
from iceberg.values import Datum
from orca import Ctx, Daily, Day, Mapped, Pipeline, Step, Tasks, orca_main
from orca.civil import now
from orca.tables import append, ensure_table, scan, table
from parquet import RecordBatch

from activity import (
    ActivityRow,
    DayActivity,
    ReleaseRow,
    activity_batch,
    activity_rows,
    day_activity,
    encode_job,
    release_rows,
    releases_batch,
)
from cols import col, i64_at, str_at
from days import day_text, days_of, month_of
from lake import (
    ACTIVITY,
    ACTIVITY_REPOS,
    EVENTS,
    RELEASES,
    REPOS,
    activity_repos_schema,
    activity_schema,
    activity_spec,
    releases_schema,
    releases_spec,
    ts,
)
from replace import partition_files, replace_files


comptime DayTask = Task[String, DayActivity, day_activity]
comptime ActivityTasks = Tasks[DayTask]


def _members(mut ctx: Ctx) raises -> Dict[String, Int64]:
    """The repositories of mojo.repos at the step's pinned snapshot, with the
    day each was created (0 if GitHub didn't say)."""
    var out = Dict[String, Int64]()
    var t = table(ctx, REPOS)
    for b in scan(ctx, t).select(["repo", "created_at"]).to_batches():
        var ir = col(b, "repo")
        var ic = col(b, "created_at")
        for r in range(b.num_rows):
            var at = i64_at(b.column(ic), r)
            out[str_at(b.column(ir), r)] = at // 86_400_000_000 if at > 0 else 0
    return out^


def _caught_up(t: Table) -> Dict[String, Bool]:
    var out = Dict[String, Bool]()
    if not t.metadata.has_current_snapshot:
        return out^
    try:
        for b in t.scan().select(["repo"]).to_batches():
            for r in range(b.num_rows):
                out[str_at(b.column(0), r)] = True
    except:
        pass
    return out^


def _loaded_days(events: Table, pinned: Int64) raises -> List[String]:
    """The days gharchive.events holds at the pinned snapshot, from its data
    files' `created_day` partitions, sorted.

    This used to walk the table's snapshots for their `orca.partition`,
    which expiry takes away (the table keeps a week of them); the files a
    snapshot reads are what it holds whatever history is left."""
    var seen = Dict[Int64, Bool]()
    if pinned < 0:
        return List[String]()
    for task in events.scan().use_snapshot(pinned).plan_files():
        ref f = task.data_file
        if len(f.partition) > 0 and f.partition[0].valid:
            seen[f.partition[0].i] = True
    var days = List[Int64]()
    for e in seen.items():
        days.append(e.key)
    for i in range(1, len(days)):
        var j = i
        while j > 0 and days[j - 1] > days[j]:
            days.swap_elements(j - 1, j)
            j -= 1
    var out = List[String]()
    for d in days:
        out.append(day_text(d))
    return out^


def _pair(repo: String, day: Int64) -> String:
    return String(repo, "|", day)


def activity(mut ctx: Ctx, d: Day) raises -> Int:
    var day = String(d)
    var key_day = days_of(day)
    var members = _members(ctx)
    var events = table(ctx, EVENTS)
    var pinned = scan(ctx, events).snapshot().snapshot_id
    var act_t = ensure_table(ctx, ACTIVITY, activity_schema(), activity_spec())
    var rel_t = ensure_table(ctx, RELEASES, releases_schema(), releases_spec())
    var cau_t = ensure_table(ctx, ACTIVITY_REPOS, activity_repos_schema())
    var caught = _caught_up(cau_t)

    # Which repositories each day's task reads: every member on the run's
    # own day, and the members not caught up yet on every loaded day from
    # the day they were created.
    var jobs = Dict[String, List[String]]()
    var all = List[String]()
    for e in members.items():
        all.append(e.key)
    jobs[day] = all^
    var fresh = List[String]()
    for e in members.items():
        if e.key not in caught:
            fresh.append(e.key)
    var loaded = _loaded_days(events, pinned)
    if len(fresh) > 0:
        for ref ld in loaded:
            if ld == day:
                continue
            var ldd = days_of(ld)
            var want = List[String]()
            for ref r in fresh:
                if members[r] <= ldd:
                    want.append(r)
            if len(want) > 0:
                jobs[ld] = want^
        ctx.log(String(
            len(fresh), " repositories to catch up over ", len(loaded),
            " loaded days; ", len(jobs), " days to read",
        ))

    # One task a day, at most `MOJO_ACTIVITY_PARALLEL` at once.
    ref rt = ctx.runtime[ActivityTasks]()
    var window = max(1, Int(getenv("MOJO_ACTIVITY_PARALLEL", "8")))
    var order = List[String]()
    for e in jobs.items():
        order.append(e.key)
    var refs = List[ObjectRef[DayActivity]]()
    var next = 0
    while next < len(order) and next < window:
        refs.append(rt.remote[DayTask](encode_job(order[next], pinned, jobs[order[next]])))
        next += 1
    var new_rows = List[ActivityRow]()
    var new_rels = List[ReleaseRow]()
    var computed = Dict[String, Bool]()
    var months = Dict[Int, Bool]()
    var scanned = 0
    for i in range(len(order)):
        var got = rt.get(refs[i])
        rt.release(refs[i])
        if next < len(order):
            refs.append(rt.remote[DayTask](encode_job(order[next], pinned, jobs[order[next]])))
            next += 1
        var gd = days_of(order[i])
        months[month_of(gd)] = True
        for ref r in jobs[order[i]]:
            computed[_pair(r, gd)] = True
        var stars = Int64(0)
        for ref r in got.rows.items:
            stars += r.stars
            new_rows.append(r.copy())
        for ref r in got.releases.items:
            new_rels.append(r.copy())
        scanned += got.scanned
        ctx.log(String(
            order[i], ": ", got.scanned, " events, ", len(got.rows),
            " repositories active, ", stars, " stars, ", len(got.releases),
            " releases (", got.ms, " ms)",
        ))

    # Replace the computed pairs in the months they fall in.
    var kept_rows = List[ActivityRow]()
    var read_rows = Int64(0)
    var act_files = partition_files(act_t, months)
    if act_t.metadata.has_current_snapshot:
        for b in act_t.scan().to_batches():
            for ref r in activity_rows(b):
                if month_of(r.day) not in months:
                    continue
                read_rows += 1
                if _pair(r.repo, r.day) not in computed:
                    kept_rows.append(r.copy())
    if read_rows != act_files.rows:
        raise Error(
            ACTIVITY, ": read ", read_rows, " rows of the months replaced, but",
            " their files hold ", act_files.rows,
        )
    var kept_rels = List[ReleaseRow]()
    var rel_files = partition_files(rel_t, months)
    read_rows = 0
    if rel_t.metadata.has_current_snapshot:
        for b in rel_t.scan().to_batches():
            for ref r in release_rows(b):
                if month_of(r.day) not in months:
                    continue
                read_rows += 1
                if _pair(r.repo, r.day) not in computed:
                    kept_rels.append(r.copy())
    if read_rows != rel_files.rows:
        raise Error(
            RELEASES, ": read ", read_rows, " rows of the months replaced, but",
            " their files hold ", rel_files.rows,
        )
    var n_rows = len(new_rows)
    var n_rels = len(new_rels)
    for ref r in kept_rows:
        new_rows.append(r.copy())
    for ref r in kept_rels:
        new_rels.append(r.copy())
    var id = replace_files(ctx, act_t, act_files.paths, [activity_batch(new_rows)])
    _ = replace_files(ctx, rel_t, rel_files.paths, [releases_batch(new_rels)])

    if len(fresh) > 0:
        var s = activity_repos_schema()
        var c_repo = ColumnBuilder.of(s, 1)
        var c_at = ColumnBuilder.of(s, 2)
        var c_days = ColumnBuilder.of(s, 3)
        var at = now() * 1_000_000
        for ref r in fresh:
            c_repo.add(Datum.string_(r))
            c_at.add(ts(at))
            c_days.add(Datum.long_(Int64(len(loaded))))
        _ = append(ctx, cau_t, [batch_of([c_repo^, c_at^, c_days^])])
    ctx.log(String(
        day, ": ", scanned, " events read over ", len(order), " days; ",
        n_rows, " activity rows and ", n_rels, " releases written (",
        len(kept_rows), " and ", len(kept_rels), " kept), snapshot ", id,
    ))
    return n_rows


comptime Activity = Step[
    "activity",
    Day,
    Int,
    activity,
    Mapped,
    retries=1,
    reads=[EVENTS, REPOS],
    writes=[ACTIVITY, RELEASES, ACTIVITY_REPOS],
]
comptime MojoActivity = Pipeline[
    "mojo_activity",
    Activity,
    tasks=ActivityTasks,
    partitions=Daily["2023-01-01"],
    sensor=True,
    max_runs=1,
    workers=4,
]


def main() raises:
    if not getenv("ORCA_WAREHOUSE"):
        _ = setenv("ORCA_WAREHOUSE", "build/warehouse")
    orca_main[MojoActivity]()
