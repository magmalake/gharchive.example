"""The lake's tables, shared by the pipelines and the console."""

from std.os import getenv

from iceberg.catalog.filesystem import FilesystemCatalog, Table
from iceberg.io import FileIO
from iceberg.schema import Schema
from iceberg.transforms import PartitionField, PartitionSpec, parse_transform
from iceberg.types import P_TIMESTAMPTZ
from iceberg.values import Datum

comptime EVENTS = "gharchive.events"
comptime REPOS = "mojo.repos"
comptime COMMITS = "mojo.commits"
comptime MIGRATIONS = "mojo.migrations"
comptime CHECKED = "mojo.checked"

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
    '{"id":12,"name":"fork","required":false,"type":"boolean"}]}'
)
"""mojo_history is keyed on `repo` (`owner/name`)."""

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
