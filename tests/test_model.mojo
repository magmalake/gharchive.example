"""`model.libraries` over a small local lake: the version a lock file or
manifest gave, else the one the files at HEAD gave (mojo.repo_versions) with
its source, the estimate by date kept apart, and the buckets.

    pixi run test
"""

from std.os import getenv, setenv
from std.subprocess import run
from std.testing import TestSuite, assert_equal, assert_true
from std.time import perf_counter_ns

from iceberg.batch import ColumnBuilder, batch_of
from iceberg.catalog.filesystem import FilesystemCatalog
from iceberg.schema import Schema
from iceberg.values import Datum

from days import days_of
from lake import (
    commits_schema,
    repo_versions_schema,
    str_or_null,
    ts,
    ts_or_null,
)
from model import libraries
from overview import Builder

comptime REPOS_NO_TOPICS = (
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


def _us(day: String) raises -> Int64:
    return days_of(day) * 86_400_000_000


def _repos(names: List[String]) raises -> List[ColumnBuilder]:
    var s = Schema.parse(REPOS_NO_TOPICS)
    var cs = List[ColumnBuilder]()
    for i in range(12):
        cs.append(ColumnBuilder.of(s, i + 1))
    for n in names:
        cs[0].add(Datum.string_(n))
        cs[1].add(ts(_us("2023-06-01")))
        cs[2].add(ts(_us("2025-01-01")))
        cs[3].add(Datum.string_("test"))
        cs[4].add(Datum.long_(1))
        cs[5].add(Datum.long_(0))
        cs[6].add(Datum.none())
        cs[7].add(Datum.none())
        cs[8].add(Datum.none())
        cs[9].add(Datum.long_(10))
        cs[10].add(Datum.string_("Mojo"))
        cs[11].add(Datum.bool_(False))
    return cs^


def test_libraries_with_head_versions() raises:
    var dir = String(getenv("TMPDIR", "/tmp"), "/census-test-model-", perf_counter_ns())
    var cat = FilesystemCatalog.local(dir)
    var repos_t = cat.create_table("mojo", "repos", Schema.parse(REPOS_NO_TOPICS))
    var commits_t = cat.create_table("mojo", "commits", commits_schema())
    var rv_t = cat.create_table("mojo", "repo_versions", repo_versions_schema())
    var names: List[String] = ["o/locked", "o/old", "o/guess", "o/unread", "o/unpinned"]
    _ = repos_t.append([batch_of(_repos(names))])

    # One commit each for the first four: o/locked has a pixi lock (1.1.0);
    # o/old and o/guess have no manifest; o/unpinned has pixi with no version.
    var cs = commits_schema()
    var c = List[ColumnBuilder]()
    for i in range(9):
        c.append(ColumnBuilder.of(cs, i + 1))
    var rows: List[Tuple[String, String, String, String]] = [
        ("o/locked", "pixi", "1.1.0", "pixi.lock"),
        ("o/old", "none", "", ""),
        ("o/guess", "none", "", ""),
        ("o/unpinned", "pixi", "", ""),
    ]
    for r in rows:
        c[0].add(Datum.string_(r[0]))
        c[1].add(Datum.string_("0123456789abcdef0123456789abcdef01234567"))
        c[2].add(ts(_us("2024-03-01")))
        c[3].add(Datum.long_(0))
        c[4].add(Datum.long_(100))
        c[5].add(Datum.long_(2))
        c[6].add(Datum.string_(r[1]))
        c[7].add(str_or_null(r[2]))
        c[8].add(str_or_null(r[3]))
    _ = commits_t.append([batch_of(c)])

    # mojo.repo_versions: o/locked says 1.0 in its README (the lock file wins),
    # o/old has a CI version, o/guess only an estimate.
    var vs = repo_versions_schema()
    var v = List[ColumnBuilder]()
    for i in range(9):
        v.append(ColumnBuilder.of(vs, i + 1))
    var vrows: List[Tuple[String, String, String, String, String]] = [
        ("o/locked", "1.0", "readme", "README.md", "24.2"),
        ("o/old", "24.4.0", "ci", ".github/workflows/ci.yml", "24.2"),
        ("o/guess", "", "", "", "0.4"),
        ("o/unpinned", "24.1", "readme", "README.md", "24.2"),
    ]
    for r in vrows:
        v[0].add(Datum.string_(r[0]))
        v[1].add(ts(_us("2026-11-05")))
        v[2].add(Datum.none())
        v[3].add(str_or_null(r[1]))
        v[4].add(str_or_null(r[2]))
        v[5].add(str_or_null(r[3]))
        v[6].add(str_or_null(r[4]))
        v[7].add(Datum.string_("date"))
        v[8].add(ts_or_null(_us("2024-03-01")))
    _ = rv_t.append([batch_of(v)])

    _ = setenv("ORCA_WAREHOUSE", dir)
    var b = Builder(Int(days_of("2026-11-05")))
    var libs = libraries(b)
    assert_equal(len(libs), 5)
    var seen = 0
    for ref l in libs:
        if l.repo == "o/locked":
            assert_equal(l.mojo_version, "1.1.0")
            assert_equal(l.version_source, "pixi.lock")
            assert_equal(l.version_estimate, "24.2")
            seen += 1
        elif l.repo == "o/old":
            assert_equal(l.mojo_version, "24.4.0")
            assert_equal(l.version_source, "ci")
            assert_equal(l.version_file, ".github/workflows/ci.yml")
            assert_equal(l.tooling, "none")
            seen += 1
        elif l.repo == "o/guess":
            assert_equal(l.mojo_version, "")
            assert_equal(l.version_source, "")
            assert_equal(l.version_estimate, "0.4")
            seen += 1
        elif l.repo == "o/unread":
            assert_equal(l.mojo_version, "")
            assert_equal(l.version_estimate, "")
            seen += 1
        elif l.repo == "o/unpinned":
            # A pixi manifest that names no version: the README's is used.
            assert_equal(l.mojo_version, "24.1")
            seen += 1
    assert_equal(seen, 5)
    var ov = b.finish(len(libs))
    # Detected: 1.1 (locked); pre-1.0 (old, unpinned); no-manifest (guess);
    # unknown (unread).
    var want: List[String] = ["pre-1.0", "1.1", "no-manifest", "unknown"]
    assert_equal(len(ov.buckets), 4)
    for i in range(4):
        assert_equal(ov.buckets[i], want[i])
    assert_equal(ov.bucket_repos[0], 2)
    # With the estimate o/guess joins pre-1.0.
    assert_equal(ov.est_buckets[0], "pre-1.0")
    assert_equal(ov.est_bucket_repos[0], 3)
    assert_equal(len(ov.est_buckets), 3)
    _ = run(String("rm -rf '", dir, "'"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
