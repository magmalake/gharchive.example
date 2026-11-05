"""Search scoring and the version families of the versions chart.

    pixi run test
"""

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from search import (
    search_score,
    sort_buckets,
    sort_families,
    url_decode,
    version_bucket,
    version_family,
    version_matches,
)


def test_ranking() raises:
    var exact = search_score("a/flare", "web", "flare")
    var prefix = search_score("a/flare_mlake", "web", "FLARE")
    var inside = search_score("a/my-flare", "web", "flare")
    var owner = search_score("flare-org/x", "web", "flare")
    var desc = search_score("a/http", "a flare-like thing", "flare")
    assert_true(exact > prefix and prefix > inside and inside > owner and owner > desc)
    assert_true(desc > 0)
    assert_equal(search_score("a/b", "c", "zzz"), 0)
    assert_equal(search_score("a/b", "c", "  "), 0)
    assert_equal(search_score("a/b", "c", ""), 0)
    assert_equal(search_score("a/b", "c", "a/b"), 100)


def test_topics() raises:
    var t: List[String] = ["mojo", "Linear-Algebra"]
    var topic = search_score("a/numbers", "fast", "linear-algebra", t)
    var topic_part = search_score("a/numbers", "fast", "algebra", t)
    var inside = search_score("a/my-algebra", "fast", "algebra")
    var owner = search_score("algebra-org/x", "web", "algebra")
    var desc = search_score("a/x", "algebra for all", "algebra")
    assert_true(inside > topic and topic > owner and owner > topic_part and topic_part > desc)
    assert_equal(search_score("a/numbers", "fast", "zzz", t), 0)


def test_url_decode() raises:
    assert_equal(url_decode("a+b%20c%2Fd"), "a b c/d")
    assert_equal(url_decode("100%"), "100%")
    assert_equal(url_decode("%zz"), "%zz")
    assert_equal(url_decode("%41"), "A")


def test_family() raises:
    assert_equal(version_family("24.6"), "24.x")
    assert_equal(version_family("25.4.0"), "25.x")
    assert_equal(version_family("0.25.7"), "0.25.x")
    assert_equal(version_family("0.26.1.dev2"), "0.26.x")
    assert_equal(version_family("26.1"), "0.26.x")
    assert_equal(version_family("1.0.0"), "1.x")
    assert_equal(version_family("nightly"), "other")


def test_bucket() raises:
    assert_equal(version_bucket("24.6"), "pre-1.0")
    assert_equal(version_bucket("25.1"), "pre-1.0")
    assert_equal(version_bucket("0.25.7"), "pre-1.0")
    assert_equal(version_bucket("0.26.1"), "pre-1.0")
    assert_equal(version_bucket("26.1"), "pre-1.0")
    assert_equal(version_bucket("1.0.0"), "1.0")
    assert_equal(version_bucket("1.1.3"), "1.1")
    assert_equal(version_bucket("1.2.0"), "1.2")
    assert_equal(version_bucket("1.2.0.dev2026101905"), "1.2")
    assert_equal(version_bucket("2.0.1"), "2.0")
    assert_equal(version_bucket("*"), "other")
    assert_equal(version_bucket(""), "other")


def test_bucket_order() raises:
    var bs: List[String] = ["1.10", "other", "1.2", "pre-1.0", "2.0", "1.0"]
    var old: List[String] = ["", "", "", "", "", ""]
    sort_buckets(bs, old)
    var want: List[String] = ["pre-1.0", "1.0", "1.2", "1.10", "2.0", "other"]
    for i in range(len(want)):
        assert_equal(bs[i], want[i])


def test_version_matches() raises:
    assert_true(version_matches("1.2", "1.2", "1.x"))
    assert_true(version_matches("1.x", "1.2", "1.x"))
    assert_true(version_matches("0.26.x", "pre-1.0", "0.26.x"))
    assert_false(version_matches("25.x", "pre-1.0", "0.26.x"))
    assert_true(version_matches("pre-1.0", "pre-1.0", "24.x"))
    assert_false(version_matches("1.x", "pre-1.0", "24.x"))
    assert_true(version_matches("unknown", "unknown", "unknown"))


def test_family_order() raises:
    var fs: List[String] = ["1.x", "other", "0.26.x", "24.x", "0.25.x", "25.x"]
    var old: List[String] = ["1.0", "x", "0.26.1", "24.1", "0.25.6.1", "25.1"]
    sort_families(fs, old)
    var want: List[String] = ["24.x", "25.x", "0.25.x", "0.26.x", "1.x", "other"]
    for i in range(len(want)):
        assert_equal(fs[i], want[i])


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
