"""The mojo_retool pipeline: read repositories' histories again and replace
their rows in `mojo.commits`, `mojo.migrations` and `mojo.tags`.

A one-off for when `history.read_history` learns something new about the
commits it already read (Bazel as a tooling, 2026-11): keyed by the `repo`
column of `mojo.repos` like mojo_history, 50 a run, and run by hand:

    orca backfill --rerun mojo_retool @all

A repository that mojo_history hasn't read yet is skipped (it will read it
the new way), and one whose clone fails keeps the rows it has. For the rest
the run clones it as mojo_history does (`read_history`) and, in one
`overwrite` snapshot a table, removes the files it read and adds the other
repositories' rows again together with the new ones, so no row is
duplicated: a repository's rows are exactly its new ones. A repository whose
tags came back empty keeps its old tags. The log says the rows of each table
before and after, and a rerun gives the same.
"""

from std.os import getenv, setenv

from dista import ObjectRef, Task
from orca import Ctx, Gather, Name, Pipeline, Step, Tasks, orca_main
from orca.keyed import Keyed
from orca.tables import scan, table
from dista import Seq
from parquet import RecordBatch

from history import CommitRow, History, MigrationRow, TagRow, read_history
from historyrows import (
    commit_rows,
    commits_batch,
    migration_rows,
    migrations_batch,
    tag_rows,
    tags_batch,
)
from lake import COMMITS, MIGRATIONS, REPOS, TAGS
from replace import replace_files
from cols import col, i64_at, str_at

comptime ReadHistory = Task[String, History, read_history]
comptime RetoolTasks = Tasks[ReadHistory]


struct _Files(Movable):
    var paths: List[String]
    var rows: Int64

    def __init__(out self):
        self.paths = List[String]()
        self.rows = 0


def _all_files(mut ctx: Ctx, dataset: String) raises -> _Files:
    """The data files of the table's current snapshot."""
    var out = _Files()
    var t = table(ctx, dataset)
    if not t.metadata.has_current_snapshot:
        return out^
    for task in scan(ctx, t).plan_files():
        out.paths.append(task.data_file.file_path)
        out.rows += task.data_file.record_count
    return out^


def retool(mut ctx: Ctx, keys: Seq[Name]) raises -> Int:
    var commits_t = table(ctx, COMMITS)
    var migrations_t = table(ctx, MIGRATIONS)
    var tags_t = table(ctx, TAGS)
    # Everything the tables hold now, by repository.
    var commits_files = _all_files(ctx, COMMITS)
    var migrations_files = _all_files(ctx, MIGRATIONS)
    var tags_files = _all_files(ctx, TAGS)
    var old_commits = List[CommitRow]()
    var old_migrations = List[MigrationRow]()
    var old_tags = List[TagRow]()
    if commits_t.metadata.has_current_snapshot:
        for b in scan(ctx, commits_t).to_batches():
            for ref r in commit_rows(b):
                old_commits.append(r.copy())
    if migrations_t.metadata.has_current_snapshot:
        for b in scan(ctx, migrations_t).to_batches():
            for ref r in migration_rows(b):
                old_migrations.append(r.copy())
    if tags_t.metadata.has_current_snapshot:
        for b in scan(ctx, tags_t).to_batches():
            for ref r in tag_rows(b):
                old_tags.append(r.copy())
    if Int64(len(old_commits)) != commits_files.rows:
        raise Error(COMMITS, ": read ", len(old_commits), " rows but its files hold ", commits_files.rows)
    if Int64(len(old_migrations)) != migrations_files.rows:
        raise Error(MIGRATIONS, ": read ", len(old_migrations), " rows but its files hold ", migrations_files.rows)
    if Int64(len(old_tags)) != tags_files.rows:
        raise Error(TAGS, ": read ", len(old_tags), " rows but its files hold ", tags_files.rows)
    var have = Dict[String, Bool]()
    for ref c in old_commits:
        have[c.repo] = True

    ref rt = ctx.runtime[RetoolTasks]()
    var sizes = Dict[String, Int64]()
    for b in scan(ctx, table(ctx, REPOS)).select(["repo", "size_kb"]).to_batches():
        var ir = col(b, "repo")
        var isz = col(b, "size_kb")
        for r in range(b.num_rows):
            sizes[str_at(b.column(ir), r)] = i64_at(b.column(isz), r)
    var max_kb = Int64(Int(getenv("MOJO_HISTORY_MAX_KB", "0")))
    var names = List[String]()
    var refs = List[ObjectRef[History]]()
    for i in range(len(keys)):
        var repo = keys.items[i].text
        if repo not in have:
            ctx.log(String(repo, ": no history read yet, left to mojo_history"))
            continue
        if max_kb > 0 and sizes.get(repo, Int64(0)) > max_kb:
            ctx.log(String(repo, ": over MOJO_HISTORY_MAX_KB, kept as it was"))
            continue
        names.append(repo)
        refs.append(rt.remote[ReadHistory](repo))
    var done = Dict[String, Bool]()
    var new_commits = List[CommitRow]()
    var new_migrations = List[MigrationRow]()
    var new_tags = List[TagRow]()
    var tagged = Dict[String, Bool]()
    var failed = 0
    for i in range(len(refs)):
        var h = rt.get(refs[i])
        rt.release(refs[i])
        if h.error.byte_length() > 0 or len(h.commits) == 0:
            ctx.log(String(names[i], ": kept as it was (", h.error if h.error else "no commits", ")"))
            failed += 1
            continue
        done[names[i]] = True
        for ref c in h.commits.items:
            new_commits.append(c.copy())
        for ref m in h.migrations.items:
            new_migrations.append(m.copy())
        if len(h.tags) > 0:
            tagged[names[i]] = True
        for ref t in h.tags.items:
            new_tags.append(t.copy())
    var before_c = Dict[String, Int]()
    var after_c = Dict[String, Int]()
    for ref c in old_commits:
        if c.repo in done:
            before_c[c.repo] = before_c.get(c.repo, 0) + 1
    for ref c in new_commits:
        after_c[c.repo] = after_c.get(c.repo, 0) + 1
    for e in before_c.items():
        var a = after_c.get(e.key, 0)
        if a != e.value:
            ctx.log(String(e.key, ": ", e.value, " commits before, ", a, " now"))

    var out_commits = List[CommitRow]()
    for ref c in old_commits:
        if c.repo not in done:
            out_commits.append(c.copy())
    var out_migrations = List[MigrationRow]()
    for ref m in old_migrations:
        if m.repo not in done:
            out_migrations.append(m.copy())
    var out_tags = List[TagRow]()
    for ref t in old_tags:
        if t.repo not in tagged:
            out_tags.append(t.copy())
    var kept = (len(out_commits), len(out_migrations), len(out_tags))
    for ref c in new_commits:
        out_commits.append(c.copy())
    for ref m in new_migrations:
        out_migrations.append(m.copy())
    for ref t in new_tags:
        out_tags.append(t.copy())
    var id = replace_files(ctx, commits_t, commits_files.paths, [commits_batch(out_commits)])
    _ = replace_files(ctx, migrations_t, migrations_files.paths, [migrations_batch(out_migrations)])
    _ = replace_files(ctx, tags_t, tags_files.paths, [tags_batch(out_tags)])
    ctx.log(String(
        len(done), " repositories re-read (", failed, " kept as they were); ",
        COMMITS, " ", len(old_commits), " -> ", len(out_commits), " rows, ",
        MIGRATIONS, " ", len(old_migrations), " -> ", len(out_migrations),
        ", ", TAGS, " ", len(old_tags), " -> ", len(out_tags),
        "; snapshot ", id,
    ))
    return len(done)


comptime Retool = Step[
    "retool",
    Seq[Name],
    Int,
    retool,
    Gather,
    retries=1,
    reads=[REPOS, COMMITS, MIGRATIONS, TAGS],
    writes=[COMMITS, MIGRATIONS, TAGS],
]
comptime MojoRetool = Pipeline[
    "mojo_retool",
    Retool,
    tasks=RetoolTasks,
    partitions=Keyed[REPOS, "repo"],
    keys_per_run=50,
    workers=4,
]


def main() raises:
    if not getenv("ORCA_WAREHOUSE"):
        _ = setenv("ORCA_WAREHOUSE", "build/warehouse")
    orca_main[MojoRetool]()
