"""mojo_history's rows to and from the tables (`mojo_retool` rewrites them)."""

from iceberg.batch import ColumnBuilder, batch_of
from iceberg.values import Datum
from parquet import RecordBatch

from cols import bool_at, col, i64_at, str_at
from headversion import HeadVersion
from history import CommitRow, MigrationRow, TagRow
from lake import (
    commits_schema,
    migrations_schema,
    repo_versions_schema,
    str_or_null,
    tags_schema,
    ts,
    ts_or_null,
)


def commit_rows(b: RecordBatch) raises -> List[CommitRow]:
    var out = List[CommitRow]()
    var c = List[Int]()
    for name in [
        "repo", "sha", "committed_at", "seq", "mojo_lines", "mojo_files",
        "tooling", "mojo_version", "version_source",
    ]:
        c.append(col(b, name))
    for r in range(b.num_rows):
        out.append(
            CommitRow(
                str_at(b.column(c[0]), r),
                str_at(b.column(c[1]), r),
                i64_at(b.column(c[2]), r),
                i64_at(b.column(c[3]), r),
                i64_at(b.column(c[4]), r),
                i64_at(b.column(c[5]), r),
                str_at(b.column(c[6]), r),
                str_at(b.column(c[7]), r),
                str_at(b.column(c[8]), r),
            )
        )
    return out^


def commits_batch(rows: List[CommitRow]) raises -> RecordBatch:
    var s = commits_schema()
    var cs = List[ColumnBuilder]()
    for i in range(9):
        cs.append(ColumnBuilder.of(s, i + 1))
    for ref r in rows:
        cs[0].add(Datum.string_(r.repo))
        cs[1].add(Datum.string_(r.sha))
        cs[2].add(ts(r.committed_at))
        cs[3].add(Datum.long_(r.seq))
        cs[4].add(Datum.long_(r.mojo_lines))
        cs[5].add(Datum.long_(r.mojo_files))
        cs[6].add(Datum.string_(r.tooling))
        cs[7].add(str_or_null(r.mojo_version))
        cs[8].add(str_or_null(r.version_source))
    return batch_of(cs)


def migration_rows(b: RecordBatch) raises -> List[MigrationRow]:
    var out = List[MigrationRow]()
    var c = List[Int]()
    for name in ["repo", "sha", "committed_at", "kind", "from_value", "to_value"]:
        c.append(col(b, name))
    for r in range(b.num_rows):
        out.append(
            MigrationRow(
                str_at(b.column(c[0]), r),
                str_at(b.column(c[1]), r),
                i64_at(b.column(c[2]), r),
                str_at(b.column(c[3]), r),
                str_at(b.column(c[4]), r),
                str_at(b.column(c[5]), r),
            )
        )
    return out^


def migrations_batch(rows: List[MigrationRow]) raises -> RecordBatch:
    var s = migrations_schema()
    var cs = List[ColumnBuilder]()
    for i in range(6):
        cs.append(ColumnBuilder.of(s, i + 1))
    for ref r in rows:
        cs[0].add(Datum.string_(r.repo))
        cs[1].add(Datum.string_(r.sha))
        cs[2].add(ts(r.committed_at))
        cs[3].add(Datum.string_(r.kind))
        cs[4].add(str_or_null(r.from_value))
        cs[5].add(str_or_null(r.to_value))
    return batch_of(cs)


def tag_rows(b: RecordBatch) raises -> List[TagRow]:
    var out = List[TagRow]()
    var c = List[Int]()
    for name in [
        "repo", "tag", "commit", "annotated", "tagged_at", "tooling",
        "mojo_version",
    ]:
        c.append(col(b, name))
    for r in range(b.num_rows):
        out.append(
            TagRow(
                str_at(b.column(c[0]), r),
                str_at(b.column(c[1]), r),
                str_at(b.column(c[2]), r),
                bool_at(b.column(c[3]), r),
                i64_at(b.column(c[4]), r),
                str_at(b.column(c[5]), r),
                str_at(b.column(c[6]), r),
            )
        )
    return out^


def tags_batch(rows: List[TagRow]) raises -> RecordBatch:
    var s = tags_schema()
    var cs = List[ColumnBuilder]()
    for i in range(7):
        cs.append(ColumnBuilder.of(s, i + 1))
    for ref r in rows:
        cs[0].add(Datum.string_(r.repo))
        cs[1].add(Datum.string_(r.tag))
        cs[2].add(Datum.string_(r.commit))
        cs[3].add(Datum.bool_(r.annotated))
        cs[4].add(ts_or_null(r.tagged_at))
        cs[5].add(str_or_null(r.tooling))
        cs[6].add(str_or_null(r.mojo_version))
    return batch_of(cs)


def head_version_rows(b: RecordBatch) raises -> List[HeadVersion]:
    var out = List[HeadVersion]()
    var c = List[Int]()
    for name in [
        "repo", "read_at", "head_sha", "mojo_version", "version_source",
        "version_file", "version_estimate", "estimate_source", "last_mojo_commit",
    ]:
        c.append(col(b, name))
    for r in range(b.num_rows):
        out.append(
            HeadVersion(
                str_at(b.column(c[0]), r), String(), str_at(b.column(c[2]), r),
                str_at(b.column(c[3]), r), str_at(b.column(c[4]), r),
                str_at(b.column(c[5]), r), str_at(b.column(c[6]), r),
                str_at(b.column(c[7]), r), i64_at(b.column(c[8]), r),
                i64_at(b.column(c[1]), r),
            )
        )
    return out^


def head_versions_batch(rows: List[HeadVersion]) raises -> RecordBatch:
    var s = repo_versions_schema()
    var cs = List[ColumnBuilder]()
    for i in range(9):
        cs.append(ColumnBuilder.of(s, i + 1))
    for ref r in rows:
        cs[0].add(Datum.string_(r.repo))
        cs[1].add(ts(r.read_at))
        cs[2].add(str_or_null(r.head_sha))
        cs[3].add(str_or_null(r.version))
        cs[4].add(str_or_null(r.source))
        cs[5].add(str_or_null(r.file))
        cs[6].add(str_or_null(r.estimate))
        cs[7].add(str_or_null(r.estimate_source))
        cs[8].add(ts_or_null(r.last_mojo_commit))
    return batch_of(cs)
