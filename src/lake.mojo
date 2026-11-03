"""The lake's tables, shared by the pipelines and the console."""

from std.os import getenv

from iceberg.append import prepare_append
from iceberg.batch import ColumnBuilder, batch_of
from iceberg.catalog.filesystem import FilesystemCatalog, Table
from iceberg.io import FileIO
from iceberg.schema import Schema
from iceberg.transforms import PartitionField, PartitionSpec, parse_transform
from iceberg.types import P_TIMESTAMPTZ
from iceberg.values import Datum
from iceberg.write import WriteOptions, write_data_files

comptime EVENTS = "gharchive.events"
comptime REPOS = "mojo.repos"
comptime COMMITS = "mojo.commits"
comptime MIGRATIONS = "mojo.migrations"
comptime CHECKED = "mojo.checked"
comptime REPO_KEYS = "mojo.repo_keys"
"""mojo_history's keys: one row per repository, `key` = `owner:name`.

Written by mojo_repos straight through iceberg, *not* through
`orca.tables`, and not declared in its `writes=`: orca refuses to register
a keyed sensor (mojo_history) over a dataset that a daily pipeline
(mojo_repos) declares it writes. Written this way, the scheduler sees the
snapshots by polling `mojo_history sense` and queues the new keys. A
retried mojo_repos may write a key twice; keys are distinct values, so
that is harmless. See GAPS.md."""

comptime EVENTS_SCHEMA = (
    '{"schema-id":0,"type":"struct","fields":['
    '{"id":1,"name":"id","required":true,"type":"long"},'
    '{"id":2,"name":"type","required":true,"type":"string"},'
    '{"id":3,"name":"created_at","required":true,"type":"timestamptz"},'
    '{"id":4,"name":"repo","required":true,"type":"string"},'
    '{"id":5,"name":"actor","required":false,"type":"string"},'
    '{"id":6,"name":"payload","required":false,"type":"string"}]}'
)

comptime REPOS_SCHEMA = (
    '{"schema-id":0,"type":"struct","fields":['
    '{"id":1,"name":"repo","required":true,"type":"string"},'
    '{"id":2,"name":"created_at","required":false,"type":"timestamptz"},'
    '{"id":3,"name":"first_seen","required":true,"type":"timestamptz"},'
    '{"id":4,"name":"found_by","required":true,"type":"string"},'
    '{"id":5,"name":"stars","required":false,"type":"long"},'
    '{"id":6,"name":"forks","required":false,"type":"long"},'
    '{"id":7,"name":"license","required":false,"type":"string"},'
    '{"id":8,"name":"default_branch","required":false,"type":"string"},'
    '{"id":9,"name":"description","required":false,"type":"string"},'
    '{"id":10,"name":"size_kb","required":false,"type":"long"},'
    '{"id":11,"name":"language","required":false,"type":"string"},'
    '{"id":12,"name":"key","required":true,"type":"string"},'
    '{"id":13,"name":"fork","required":false,"type":"boolean"}]}'
)
"""`key` is `repo` as an orca key: `owner:name`, because orca's `Name`
keys can't hold a `/`. mojo_history is keyed on it."""

comptime COMMITS_SCHEMA = (
    '{"schema-id":0,"type":"struct","fields":['
    '{"id":1,"name":"repo","required":true,"type":"string"},'
    '{"id":2,"name":"sha","required":true,"type":"string"},'
    '{"id":3,"name":"committed_at","required":true,"type":"timestamptz"},'
    '{"id":4,"name":"seq","required":true,"type":"long"},'
    '{"id":5,"name":"mojo_lines","required":true,"type":"long"},'
    '{"id":6,"name":"mojo_files","required":true,"type":"long"},'
    '{"id":7,"name":"tooling","required":true,"type":"string"},'
    '{"id":8,"name":"mojo_version","required":false,"type":"string"},'
    '{"id":9,"name":"version_source","required":false,"type":"string"}]}'
)

comptime MIGRATIONS_SCHEMA = (
    '{"schema-id":0,"type":"struct","fields":['
    '{"id":1,"name":"repo","required":true,"type":"string"},'
    '{"id":2,"name":"sha","required":true,"type":"string"},'
    '{"id":3,"name":"committed_at","required":true,"type":"timestamptz"},'
    '{"id":4,"name":"kind","required":true,"type":"string"},'
    '{"id":5,"name":"from_value","required":false,"type":"string"},'
    '{"id":6,"name":"to_value","required":false,"type":"string"}]}'
)


comptime CHECKED_SCHEMA = (
    '{"schema-id":0,"type":"struct","fields":['
    '{"id":1,"name":"repo","required":true,"type":"string"},'
    '{"id":2,"name":"checked_at","required":true,"type":"timestamptz"},'
    '{"id":3,"name":"outcome","required":true,"type":"string"},'
    '{"id":4,"name":"signals","required":false,"type":"string"},'
    '{"id":5,"name":"how","required":false,"type":"string"},'
    '{"id":6,"name":"first_seen","required":false,"type":"timestamptz"},'
    '{"id":7,"name":"sha","required":false,"type":"string"}]}'
)
"""Every candidate mojo_repos asked GitHub about, so it asks once."""


comptime REPO_KEYS_SCHEMA = (
    '{"schema-id":0,"type":"struct","fields":['
    '{"id":1,"name":"key","required":true,"type":"string"},'
    '{"id":2,"name":"repo","required":true,"type":"string"}]}'
)


def events_schema() raises -> Schema:
    return Schema.parse(EVENTS_SCHEMA)


def events_spec() raises -> PartitionSpec:
    """gharchive.events is partitioned by the day of `created_at`."""
    return PartitionSpec(
        0,
        [PartitionField.single(3, 1000, "created_day", parse_transform("day"))],
    )


def checked_schema() raises -> Schema:
    return Schema.parse(CHECKED_SCHEMA)


def repos_schema() raises -> Schema:
    return Schema.parse(REPOS_SCHEMA)


def commits_schema() raises -> Schema:
    return Schema.parse(COMMITS_SCHEMA)


def migrations_schema() raises -> Schema:
    return Schema.parse(MIGRATIONS_SCHEMA)


def ts(micros: Int64) -> Datum:
    """A `timestamptz` value."""
    return Datum.integral(P_TIMESTAMPTZ, micros)


def str_or_null(s: String) -> Datum:
    if s.byte_length() == 0:
        return Datum.none()
    return Datum.string_(s)


def repo_key(repo: String) -> String:
    """`owner/name` as an orca key, `owner:name`."""
    return repo.replace("/", ":")


def key_repo(key: String) -> String:
    """An orca key, `owner:name`, back to `owner/name`."""
    return key.replace(":", "/")


def append_keys(repos: List[String]) raises -> Int64:
    """Appends `repos` to mojo.repo_keys, creating it if needed; returns the
    snapshot ID, or -1 when there was nothing to write."""
    if len(repos) == 0:
        return -1
    var schema = Schema.parse(REPO_KEYS_SCHEMA)
    var cat = _catalog()
    if not cat.table_exists("mojo", "repo_keys"):
        try:
            _ = cat.create_table(
                "mojo", "repo_keys", schema.copy(), PartitionSpec.unpartitioned()
            )
        except e:
            if not cat.table_exists("mojo", "repo_keys"):
                raise e^
    var t = cat.load_table("mojo", "repo_keys")
    var keys = ColumnBuilder.of(schema, 1)
    var names = ColumnBuilder.of(schema, 2)
    for r in repos:
        keys.add(Datum.string_(repo_key(r)))
        names.add(Datum.string_(r))
    var files = write_data_files(
        t.io,
        t.metadata.location,
        [batch_of([keys^, names^])],
        t.metadata.schema(),
        t.metadata.spec(),
        t.metadata.default_sort_order_id,
        WriteOptions.from_properties(t.metadata.properties),
    )
    var result = prepare_append(t.io, t.metadata, files^, Dict[String, String]())
    t.commit(result)
    return result.snapshot_id


def _catalog() raises -> FilesystemCatalog:
    var root = warehouse()
    if "://" in root and not root.startswith("file://"):
        return FilesystemCatalog(String(root.rstrip("/")), FileIO())
    return FilesystemCatalog.local(root)


def warehouse() -> String:
    """The lake: ORCA_WAREHOUSE (on AWS, the public bucket), else a directory."""
    return getenv("ORCA_WAREHOUSE", "build/warehouse")


def load(namespace: String, name: String) raises -> Table:
    var root = warehouse()
    if "://" in root and not root.startswith("file://"):
        return FilesystemCatalog(String(root.rstrip("/")), FileIO()).load_table(
            namespace, name
        )
    return FilesystemCatalog.local(root).load_table(namespace, name)


def exists(namespace: String, name: String) raises -> Bool:
    var root = warehouse()
    if "://" in root and not root.startswith("file://"):
        return FilesystemCatalog(
            String(root.rstrip("/")), FileIO()
        ).table_exists(namespace, name)
    return FilesystemCatalog.local(root).table_exists(namespace, name)
