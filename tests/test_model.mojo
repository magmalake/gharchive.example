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
from deps import Dep, RepoDep
from historyrows import repo_deps_batch
from lake import (
    commits_schema,
    repo_deps_schema,
    repo_versions_schema,
    str_or_null,
    ts,
    ts_or_null,
)
from model import libraries
from overview import Builder, top_gains

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


def _repos(
    names: List[String], first_seen: String = "2025-01-01", description: String = ""
) raises -> List[ColumnBuilder]:
    var s = Schema.parse(REPOS_NO_TOPICS)
    var cs = List[ColumnBuilder]()
    for i in range(12):
        cs.append(ColumnBuilder.of(s, i + 1))
    for n in names:
        cs[0].add(Datum.string_(n))
        cs[1].add(ts(_us("2023-06-01")))
        cs[2].add(ts(_us(first_seen)))
        cs[3].add(Datum.string_("test"))
        cs[4].add(Datum.long_(1))
        cs[5].add(Datum.long_(0))
        cs[6].add(Datum.none())
        cs[7].add(Datum.none())
        cs[8].add(str_or_null(description))
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
    for i in range(10):
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
        # o/unpinned was read before dependencies were: null.
        v[9].add(Datum.none() if r[0] == "o/unpinned" else Datum.long_(Int64(1) if r[0] != "o/locked" else Int64(0)))
    _ = rv_t.append([batch_of(v)])
    # mojo.repo_deps: o/old names o/locked by URL (another case), o/guess by
    # the name o/locked publishes; the toolchain and a repo's own name don't
    # count.
    var deps_t = cat.create_table("mojo", "repo_deps", repo_deps_schema())
    var at = _us("2026-11-05")
    var drows: List[RepoDep] = [
        RepoDep("o/locked", at, Dep("provides", "package", "locked-lib", "", "package", "pixi.toml")),
        RepoDep("o/locked", at, Dep("depends", "conda", "mojo", "", "dependencies", "pixi.toml")),
        RepoDep("o/old", at, Dep("depends", "git", "lockedlib", "O/Locked", "dependencies", "pixi.toml")),
        RepoDep("o/guess", at, Dep("depends", "conda", "locked_lib", "", "requirements.run", "recipe.yaml")),
        RepoDep("o/guess", at, Dep("depends", "conda", "guess", "", "dependencies", "pixi.toml")),
    ]
    _ = deps_t.append([repo_deps_batch(drows)])

    _ = setenv("ORCA_WAREHOUSE", dir)
    var b = Builder(Int(days_of("2026-11-05")))
    var libs = libraries(b)
    assert_equal(len(libs), 5)
    var seen = 0
    for ref l in libs:
        if l.repo == "o/locked":
            assert_equal(len(l.used_by), 2)
            assert_equal(l.used_by[0], "o/guess")
            assert_equal(l.declared_deps, 0)
            assert_equal(len(l.depends_on), 0)
            assert_equal(l.mojo_version, "1.1.0")
            assert_equal(l.version_source, "pixi.lock")
            assert_equal(l.version_estimate, "24.2")
            seen += 1
        elif l.repo == "o/old":
            assert_equal(len(l.depends_on), 1)
            assert_equal(l.depends_on[0], "o/locked")
            assert_equal(l.declared_deps, 1)
            assert_equal(l.mojo_version, "24.4.0")
            assert_equal(l.version_source, "ci")
            assert_equal(l.version_file, ".github/workflows/ci.yml")
            assert_equal(l.tooling, "none")
            seen += 1
        elif l.repo == "o/guess":
            assert_equal(len(l.depends_on), 1)
            assert_equal(len(l.declared), 2)
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
            assert_equal(l.declared_deps, -1)
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


def _commit(mut c: List[ColumnBuilder], repo: String, day: String, seq: Int, lines: Int) raises:
    c[0].add(Datum.string_(repo))
    c[1].add(Datum.string_(String(repo, "-", seq)))
    c[2].add(ts(_us(day)))
    c[3].add(Datum.long_(Int64(seq)))
    c[4].add(Datum.long_(Int64(lines)))
    c[5].add(Datum.long_(1))
    c[6].add(Datum.string_("pixi"))
    c[7].add(Datum.none())
    c[8].add(Datum.none())


def test_duplicate_repo_rows_keep_numbers_with_names() raises:
    """The table mojo.repos names o/small twice (a second run appended it
    again) and lists the repos in another order than the console's biggest
    first: each repo's commits and lines in the last 30 days stay with its
    name."""
    var dir = String(getenv("TMPDIR", "/tmp"), "/census-test-dups-", perf_counter_ns())
    var cat = FilesystemCatalog.local(dir)
    var repos_t = cat.create_table("mojo", "repos", Schema.parse(REPOS_NO_TOPICS))
    var commits_t = cat.create_table("mojo", "commits", commits_schema())
    var first: List[String] = ["o/small", "o/big"]
    _ = repos_t.append([batch_of(_repos(first, "2025-01-01", "the first row"))])
    var again: List[String] = ["o/small", "o/mid"]
    _ = repos_t.append([batch_of(_repos(again, "2025-06-01", "a later row"))])

    var cs = commits_schema()
    var c = List[ColumnBuilder]()
    for i in range(9):
        c.append(ColumnBuilder.of(cs, i + 1))
    # Today is 2026-11-05; 30 days ago is 2026-10-06.
    # o/small: three commits this month, 10 lines now.
    _commit(c, "o/small", "2026-10-20", 0, 4)
    _commit(c, "o/small", "2026-10-25", 1, 8)
    _commit(c, "o/small", "2026-11-01", 2, 10)
    # o/big: 500 lines in 2024, 1000 now after one commit this month.
    _commit(c, "o/big", "2024-03-01", 0, 500)
    _commit(c, "o/big", "2026-11-02", 1, 1000)
    # o/mid: nothing recent, 100 lines.
    _commit(c, "o/mid", "2025-07-01", 0, 100)
    _ = commits_t.append([batch_of(c)])

    _ = setenv("ORCA_WAREHOUSE", dir)
    var b = Builder(Int(days_of("2026-11-05")))
    var libs = libraries(b)
    # One library and one accumulator per name.
    assert_equal(len(libs), 3)
    assert_equal(len(b.accs), 3)
    # The data checks' repos_unique compares these: four rows, three names.
    assert_equal(b.repo_rows, 4)
    # Biggest first, unlike mojo.repos' order (small, big, mid).
    assert_equal(libs[0].repo, "o/big")
    assert_equal(libs[1].repo, "o/mid")
    assert_equal(libs[2].repo, "o/small")
    # o/small keeps its earliest row, and its commits are counted once.
    assert_equal(libs[2].description, "the first row")
    assert_equal(libs[2].first_seen, _us("2025-01-01"))
    assert_equal(libs[2].commits, 3)
    assert_equal(libs[2].mojo_lines, 10)

    # What the console's Most active and the Repos table's commits30 use.
    var names = List[String]()
    for ref l in libs:
        names.append(l.repo)
    var r = b.recent(names)
    assert_equal(r.commits30[0], 1)  # o/big
    assert_equal(r.lines_delta[0], 500)
    assert_equal(r.commits30[1], 0)  # o/mid
    assert_equal(r.lines_delta[1], 0)
    assert_equal(r.commits30[2], 3)  # o/small
    assert_equal(r.lines_delta[2], 10)
    var top = top_gains(r.commits30, 10)
    assert_equal(len(top), 2)
    assert_equal(libs[top[0]].repo, "o/small")
    assert_equal(libs[top[1]].repo, "o/big")

    var ov = b.finish(len(libs))
    assert_equal(ov.with_history, 3)
    assert_equal(ov.commits, 6)
    assert_equal(ov.commits_30, 4)
    assert_equal(ov.lines, 1110)
    _ = run(String("rm -rf '", dir, "'"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
