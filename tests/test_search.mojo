"""Search scoring and the version families of the versions chart.

    pixi run test
"""

from std.testing import TestSuite, assert_equal, assert_true

from search import search_score, sort_families, url_decode, version_family


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


def test_family_order() raises:
    var fs: List[String] = ["1.x", "other", "0.26.x", "24.x", "0.25.x", "25.x"]
    var old: List[String] = ["1.0", "x", "0.26.1", "24.1", "0.25.6.1", "25.1"]
    sort_families(fs, old)
    var want: List[String] = ["24.x", "25.x", "0.25.x", "0.26.x", "1.x", "other"]
    for i in range(len(want)):
        assert_equal(fs[i], want[i])


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
