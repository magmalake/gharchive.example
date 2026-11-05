"""Reading `git log --numstat --summary` into commits and migrations.

    pixi run test
"""

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from history import History, _parse_log, _sh, is_mojo_file, safe_repo
from dista import Seq
from history import CommitRow, MigrationRow


def _log() -> String:
    # Three first-parent commits: two Mojo files, then one grows and a
    # .🔥 file appears, then one is deleted. No manifest is touched, so
    # nothing reads the (absent) clone.
    return String(
        "@@aaa 1700000000\n\n",
        "10\t0\tsrc/a.mojo\n5\t0\tb.mojo\n3\t0\tREADME.md\n",
        " create mode 100644 src/a.mojo\n create mode 100644 b.mojo\n",
        " create mode 100644 README.md\n",
        "@@bbb 1700000100\n\n",
        "4\t1\tsrc/a.mojo\n7\t0\tc.🔥\n-\t-\tlogo.png\n",
        " create mode 100644 c.🔥\n create mode 100644 logo.png\n",
        "@@ccc 1700000200\n\n",
        "0\t5\tb.mojo\n delete mode 100644 b.mojo\n",
    )


def test_lines_and_files() raises:
    var h = History("o/r", String(), Seq[CommitRow](), Seq[MigrationRow]())
    _parse_log("o/r", "/nonexistent", _log(), h)
    assert_equal(len(h.commits), 3)
    assert_equal(h.commits.items[0].mojo_lines, 15)
    assert_equal(h.commits.items[0].mojo_files, 2)
    assert_equal(h.commits.items[1].mojo_lines, 25)
    assert_equal(h.commits.items[1].mojo_files, 3)
    assert_equal(h.commits.items[2].mojo_lines, 20)
    assert_equal(h.commits.items[2].mojo_files, 2)
    assert_equal(h.commits.items[2].seq, 2)
    assert_equal(h.commits.items[1].committed_at, 1700000100 * 1_000_000)
    assert_equal(h.commits.items[0].tooling, "none")
    assert_equal(len(h.migrations), 0)


def test_mojo_files() raises:
    assert_true(is_mojo_file("a/b.mojo"))
    assert_true(is_mojo_file("x.🔥"))
    assert_false(is_mojo_file("a.mojom"))


def test_output_not_utf8() raises:
    # An old commit's Latin-1 author or path: the bytes that aren't UTF-8
    # are dropped instead of failing the whole run.
    var r = _sh("printf 'caf\\351 ok\\n'; (exit 3)")
    assert_equal(r[0], 3)
    assert_equal(r[1], "caf ok\n")


def test_safe_repo() raises:
    assert_true(safe_repo("modular/modular"))
    assert_true(safe_repo("mzaks/mojo-flx"))
    assert_false(safe_repo("a/b; rm -rf /"))
    assert_false(safe_repo("../etc"))
    assert_false(safe_repo("noslash"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
