"""The mojo_versions pipeline: the Mojo version each repository states at its
HEAD, for the ones whose lock file and manifest name none, and an estimate by
date.

Keyed by the `repo` column of `mojo.repos` like mojo_history, 50 repositories
a run, and a sensor, so each snapshot mojo_repos commits starts runs for the
repositories it adds. A repository that mojo_history hasn't read is read here
all the same (this step clones it without file contents). Run for the
repositories already in the lake by hand:

    orca backfill --rerun mojo_versions @all

Each repository goes to a dista task (`read_head_version`: a blobless clone,
the few files at HEAD that can state a version, the date of the last commit
that touched a Mojo file). The step then replaces the repositories' rows of
`mojo.repo_versions` in one `overwrite` snapshot, as mojo_retool does: it
keeps the other repositories' rows and adds the new ones, so no row is
duplicated and a rerun gives the same. A repository whose clone fails keeps
the row it had.
"""

from std.os import getenv, setenv

from dista import ObjectRef, Seq, Task
from orca.civil import now
from orca import Ctx, Gather, Name, Pipeline, Step, Tasks, orca_main
from orca.keyed import Keyed
from orca.tables import ensure_table, scan, table

from headversion import HeadVersion, read_head_version
from historyrows import head_version_rows, head_versions_batch
from lake import REPOS, REPO_VERSIONS, repo_versions_schema
from replace import replace_files

comptime ReadHead = Task[String, HeadVersion, read_head_version]
comptime VersionTasks = Tasks[ReadHead]


def versions(mut ctx: Ctx, keys: Seq[Name]) raises -> Int:
    var t = ensure_table(ctx, REPO_VERSIONS, repo_versions_schema())
    var old = List[HeadVersion]()
    var files = List[String]()
    var file_rows = Int64(0)
    if t.metadata.has_current_snapshot:
        for task in scan(ctx, t).plan_files():
            files.append(task.data_file.file_path)
            file_rows += task.data_file.record_count
        for b in scan(ctx, t).to_batches():
            for ref r in head_version_rows(b):
                old.append(r.copy())
        if Int64(len(old)) != file_rows:
            raise Error(
                REPO_VERSIONS, ": read ", len(old), " rows but its files hold ", file_rows,
            )
    ref rt = ctx.runtime[VersionTasks]()
    var names = List[String]()
    var refs = List[ObjectRef[HeadVersion]]()
    for i in range(len(keys)):
        var repo = keys.items[i].text
        names.append(repo)
        refs.append(rt.remote[ReadHead](repo))
    var fresh = Dict[String, HeadVersion]()
    var failed = 0
    var found = 0
    var now = now() * 1_000_000
    for i in range(len(refs)):
        var h = rt.get(refs[i])
        rt.release(refs[i])
        if h.error.byte_length() > 0:
            ctx.log(String(names[i], ": kept as it was (", h.error, ")"))
            failed += 1
            continue
        h.read_at = now
        if h.version.byte_length() > 0:
            found += 1
        ctx.log(String(
            names[i], ": ", h.version if h.version else "no version",
            " (", h.source if h.source else "-", ") estimate ",
            h.estimate if h.estimate else "-",
        ))
        fresh[names[i]] = h^
    var out = List[HeadVersion]()
    for ref r in old:
        if r.repo not in fresh:
            out.append(r.copy())
    for e in fresh.items():
        out.append(e.value.copy())
    var id = replace_files(ctx, t, files, [head_versions_batch(out)])
    ctx.log(String(
        len(fresh), " repositories read (", failed, " kept as they were), ",
        found, " with a version; ", REPO_VERSIONS, " ", len(old), " -> ", len(out),
        " rows; snapshot ", id,
    ))
    if failed > 0 and failed == len(refs):
        raise Error("every repository in this run failed (", failed, ")")
    return len(fresh)


comptime Versions = Step[
    "versions",
    Seq[Name],
    Int,
    versions,
    Gather,
    retries=1,
    reads=[REPOS, REPO_VERSIONS],
    writes=[REPO_VERSIONS],
]
comptime MojoVersions = Pipeline[
    "mojo_versions",
    Versions,
    tasks=VersionTasks,
    partitions=Keyed[REPOS, "repo"],  # owner/name
    keys_per_run=50,
    sensor=True,
    workers=4,
]


def main() raises:
    if not getenv("ORCA_WAREHOUSE"):
        _ = setenv("ORCA_WAREHOUSE", "build/warehouse")
    orca_main[MojoVersions]()
