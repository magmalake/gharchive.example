"""The mojo_history pipeline: each Mojo repository's history.

Keyed by the `repo` column of `mojo.repos` (`owner/name`), 50 repositories
a run, and a sensor, so each snapshot mojo_repos commits starts runs for the
repositories it adds. The run's one step is a gather over
its keys: it sends every repository to a dista task (`read_history`: a
bare clone and one `git log`), then appends what comes back to
`mojo.commits` and `mojo.migrations` as one snapshot each.

A repository already in `mojo.commits` is skipped, so a rerun doesn't
duplicate rows. `MOJO_HISTORY_MAX_KB` skips repositories GitHub says are
bigger than that (for local runs; modular/modular is gigabytes).
"""

from std.os import getenv, setenv

from dista import ObjectRef, Seq, Task
from iceberg.batch import ColumnBuilder, batch_of
from iceberg.values import Datum
from orca import Ctx, Gather, Name, Pipeline, Step, Tasks, orca_main
from orca.keyed import Keyed
from orca.tables import append, ensure_table, scan, table

from cols import col, i64_at, str_at
from history import History, read_history
from lake import (
    COMMITS,
    MIGRATIONS,
    REPOS,
    commits_schema,
    migrations_schema,
    str_or_null,
    ts,
)


comptime ReadHistory = Task[String, History, read_history]
comptime HistoryTasks = Tasks[ReadHistory]


def _sizes(mut ctx: Ctx) raises -> Dict[String, Int64]:
    """`size_kb` of every repository in mojo.repos, at the step's pinned
    snapshot (a declared read, so lineage runs back to gharchive.events)."""
    var out = Dict[String, Int64]()
    var t = table(ctx, REPOS)
    for b in scan(ctx, t).select(["repo", "size_kb"]).to_batches():
        var ir = col(b, "repo")
        var isz = col(b, "size_kb")
        for r in range(b.num_rows):
            out[str_at(b.column(ir), r)] = i64_at(b.column(isz), r)
    return out^


def _done(mut ctx: Ctx) raises -> Dict[String, Bool]:
    """Repositories mojo.commits already has."""
    var out = Dict[String, Bool]()
    var t = table(ctx, COMMITS)
    if not t.metadata.has_current_snapshot:
        return out^
    for b in t.scan().select(["repo"]).to_batches():
        for r in range(b.num_rows):
            out[str_at(b.column(0), r)] = True
    return out^


def histories(mut ctx: Ctx, keys: Seq[Name]) raises -> Int:
    var commits_t = ensure_table(ctx, COMMITS, commits_schema())
    var migrations_t = ensure_table(ctx, MIGRATIONS, migrations_schema())
    var sizes = _sizes(ctx)
    var done = _done(ctx)
    var max_kb = Int64(Int(getenv("MOJO_HISTORY_MAX_KB", "0")))
    ref rt = ctx.runtime[HistoryTasks]()
    var names = List[String]()
    var refs = List[ObjectRef[History]]()
    for i in range(len(keys)):
        var repo = keys.items[i].text
        if repo in done:
            ctx.log(String(repo, ": already in mojo.commits, skipped"))
            continue
        var kb = sizes.get(repo, Int64(0))
        if max_kb > 0 and kb > max_kb:
            ctx.log(String(repo, ": ", kb, " KB is over MOJO_HISTORY_MAX_KB, skipped"))
            continue
        names.append(repo)
        refs.append(rt.remote[ReadHistory](repo))

    var cs = commits_schema()
    var ms = migrations_schema()
    var c_repo = ColumnBuilder.of(cs, 1)
    var c_sha = ColumnBuilder.of(cs, 2)
    var c_at = ColumnBuilder.of(cs, 3)
    var c_seq = ColumnBuilder.of(cs, 4)
    var c_lines = ColumnBuilder.of(cs, 5)
    var c_files = ColumnBuilder.of(cs, 6)
    var c_tool = ColumnBuilder.of(cs, 7)
    var c_ver = ColumnBuilder.of(cs, 8)
    var c_src = ColumnBuilder.of(cs, 9)
    var m_repo = ColumnBuilder.of(ms, 1)
    var m_sha = ColumnBuilder.of(ms, 2)
    var m_at = ColumnBuilder.of(ms, 3)
    var m_kind = ColumnBuilder.of(ms, 4)
    var m_from = ColumnBuilder.of(ms, 5)
    var m_to = ColumnBuilder.of(ms, 6)
    var failed = 0
    for i in range(len(refs)):
        var h = rt.get(refs[i])
        rt.release(refs[i])
        if h.error.byte_length() > 0:
            ctx.log(String(names[i], ": ", h.error))
            failed += 1
            continue
        var last_lines = Int64(0)
        if len(h.commits) > 0:
            last_lines = h.commits.items[len(h.commits) - 1].mojo_lines
        ctx.log(String(
            names[i], ": ", len(h.commits), " commits, ", len(h.migrations),
            " migrations, ", last_lines, " lines of Mojo now",
        ))
        for ref c in h.commits.items:
            c_repo.add(Datum.string_(c.repo))
            c_sha.add(Datum.string_(c.sha))
            c_at.add(ts(c.committed_at))
            c_seq.add(Datum.long_(c.seq))
            c_lines.add(Datum.long_(c.mojo_lines))
            c_files.add(Datum.long_(c.mojo_files))
            c_tool.add(Datum.string_(c.tooling))
            c_ver.add(str_or_null(c.mojo_version))
            c_src.add(str_or_null(c.version_source))
        for ref m in h.migrations.items:
            m_repo.add(Datum.string_(m.repo))
            m_sha.add(Datum.string_(m.sha))
            m_at.add(ts(m.committed_at))
            m_kind.add(Datum.string_(m.kind))
            m_from.add(str_or_null(m.from_value))
            m_to.add(str_or_null(m.to_value))
    var n = len(c_repo)
    if n > 0:
        _ = append(ctx, commits_t, [batch_of([c_repo^, c_sha^, c_at^, c_seq^, c_lines^, c_files^, c_tool^, c_ver^, c_src^])])
    if len(m_repo) > 0:
        _ = append(ctx, migrations_t, [batch_of([m_repo^, m_sha^, m_at^, m_kind^, m_from^, m_to^])])
    ctx.log(String(len(refs), " repositories read (", failed, " failed), ", n, " commits"))
    if failed > 0 and failed == len(refs):
        raise Error("every repository in this run failed")
    return n


comptime Histories = Step[
    "histories",
    Seq[Name],
    Int,
    histories,
    Gather,
    retries=1,
    reads=[REPOS],
    writes=[COMMITS, MIGRATIONS],
]
comptime MojoHistory = Pipeline[
    "mojo_history",
    Histories,
    tasks=HistoryTasks,
    partitions=Keyed[REPOS, "repo"],  # owner/name
    keys_per_run=50,
    sensor=True,
    workers=4,
]


def main() raises:
    if not getenv("ORCA_WAREHOUSE"):
        _ = setenv("ORCA_WAREHOUSE", "build/warehouse")
    orca_main[MojoHistory]()
