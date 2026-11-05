"""Committing an hour's files to the tables of a day, one snapshot a table
and hour, and replacing the day's earlier files with the first commit.

gharchive and gharchive_index both write `gharchive.events`'s companions
(`candidates`, `repo_hour`, `releases`) this way. Each table counts its own
commits (`orca.tables.find_commit`), so a retried step finds, per table, the
hours it already committed.
"""

from iceberg.catalog.filesystem import Table
from iceberg.commit import FileChanges
from iceberg.manifest import DataFile
from orca import Ctx
from orca.tables import append, append_files, commit, find_commit
from parquet import RecordBatch

from days import day_text, days_of
from replace import partition_files


def committed_hours(mut ctx: Ctx, mut t: Table, n_hours: Int) raises -> Int:
    """How many of the step's first hours `t` already has a commit for;
    their ids are recorded again."""
    var done = 0
    while done < n_hours and find_commit(ctx, t) >= 0:
        _ = append(ctx, t, List[RecordBatch]())
        done += 1
    return done


def day_files(t: Table, day: String, column: String) raises -> List[String]:
    """The paths of the files `t` holds for `day` (a day partition of the
    timestamp column `column`)."""
    var dd = days_of(day)
    var parts = Dict[Int, Bool]()
    parts[Int(dd)] = True
    var f = partition_files(
        t,
        parts,
        String(
            '["and",[">=","', column, '","', day, 'T00:00:00Z"],',
            '["<","', column, '","', day_text(dd + 1), 'T00:00:00Z"]]',
        ),
    )
    return f.paths.copy()


def commit_hour(
    mut ctx: Ctx,
    mut t: Table,
    i: Int,
    done: Int,
    old: List[String],
    files: List[DataFile],
) raises -> Int64:
    """Hour `i`'s files as `t`'s next snapshot: found again if an earlier
    attempt made it (`i < done`), an `overwrite` that also removes `old` if
    it is the first (`old` is only given when nothing was committed yet),
    else an append. Every hour has a file, empty if need be: a snapshot
    needs one, and one per hour keeps each table's numbering aligned."""
    if i < done:
        return append(ctx, t, List[RecordBatch]())
    if i == done and len(old) > 0:
        var change = FileChanges()
        change.added_data = files.copy()
        change.removed = old.copy()
        return commit(ctx, t, "overwrite", change^)
    return append_files(ctx, t, files)
