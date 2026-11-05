"""Mojo versions sort in one order across Modular's renumbering, and
manifests and lock files give the tooling and the version.

    pixi run test
"""

from std.testing import TestSuite, assert_equal, assert_true

from versions import (
    compare_versions,
    lock_version,
    manifest_version,
    sort_versions,
    tooling,
    version_key,
)


def test_eras_in_order() raises:
    var vs: List[String] = [
        "1.2.0", "24.1.0", "0.26.1", "25.4", "1.0.0", "24.6", "0.25.7",
        "25.1.0", "1.1.0", "0.25.6.1", "2.0.0",
    ]
    sort_versions(vs)
    var want: List[String] = [
        "24.1.0", "24.6", "25.1.0", "25.4", "0.25.6.1", "0.25.7", "0.26.1",
        "1.0.0", "1.1.0", "1.2.0", "2.0.0",
    ]
    assert_equal(len(vs), len(want))
    for i in range(len(vs)):
        assert_equal(vs[i], want[i])


def test_renumbering_meets_itself() raises:
    # MAX 25.6 shipped Mojo 0.25.6: the same release under both numbers.
    assert_equal(compare_versions("25.6", "0.25.6"), 0)
    assert_equal(compare_versions("25.6.0", "0.25.6"), 0)
    assert_true(compare_versions("25.5", "0.25.6") < 0)
    assert_true(compare_versions("0.25.7", "25.6") > 0)


def test_dev_builds_come_before_their_release() raises:
    assert_true(compare_versions("25.4.0.dev2025050605", "25.4.0") < 0)
    assert_true(compare_versions("25.4.0.dev2025050605", "25.4.0.dev2025060105") < 0)
    assert_true(compare_versions("25.3.0", "25.4.0.dev2025050605") < 0)
    assert_true(compare_versions("1.2.0.dev2026101905", "1.2.0") < 0)
    assert_true(compare_versions("1.1.0", "1.2.0.dev2026101905") < 0)


def test_not_a_version_sorts_first() raises:
    assert_equal(len(version_key("*")), 0)
    assert_true(compare_versions("*", "24.1") < 0)
    assert_equal(compare_versions("", ""), 0)


def test_lock_version() raises:
    var lock = String(
        "version: 6\n  packages:\n",
        "  - conda: https://conda.modular.com/max-nightly/osx-arm64/max-core-25.4.0.dev2025050605-release.conda\n",
        "  - conda: https://conda.modular.com/max-nightly/osx-arm64/max-25.4.0.dev2025050605-release.conda\n",
    )
    assert_equal(lock_version(lock), "25.4.0.dev2025050605")
    var newer = String(
        "  - conda: https://conda.modular.com/max/osx-arm64/mojo-compiler-1.2.0-release.conda\n",
        "  - conda: https://conda.modular.com/max/osx-arm64/mojo-0.25.6-release.conda\n",
    )
    assert_equal(lock_version(newer), "1.2.0")
    assert_equal(lock_version("nothing here"), "")


def test_manifest_version() raises:
    assert_equal(manifest_version('[dependencies]\nmax = ">=24.5.0,<25"\n'), "24.5.0")
    assert_equal(manifest_version('[dependencies]\nmojo = "==0.25.6"\n'), "0.25.6")
    assert_equal(manifest_version('mojo-compiler = "==1.2.0"\npython = "3.12"\n'), "1.2.0")
    assert_equal(manifest_version('[dependencies]\nmax = "*"\n'), "*")
    assert_equal(manifest_version('[dependencies]\npython = "3.12"\n'), "")


def test_tooling() raises:
    assert_equal(tooling(False, False, False, False), "none")
    assert_equal(tooling(False, False, True, True), "magic")
    assert_equal(tooling(True, False, False, True), "magic")
    assert_equal(tooling(True, True, False, False), "pixi")
    assert_equal(tooling(False, False, True, False), "magic")
    assert_equal(tooling(False, False, False, False, True), "bazel")
    # Bazel ranks above pixi, magic and none.
    assert_equal(tooling(True, True, False, False, True), "bazel")
    assert_equal(tooling(True, False, True, True, True), "bazel")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
