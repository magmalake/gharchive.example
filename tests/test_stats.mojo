"""GitHub's repository JSON as a stats row, and waiting out its rate limit.

    pixi run test
"""

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from detect import parse_repo
from fetch import Reply
from stats import limited, parse_stats, state_of, wait_seconds


def _repo_json() -> String:
    return String(
        '{"id":1,"name":"NuMojo","full_name":"Mojo-Numerics-and-Algorithms-group/NuMojo",',
        '"owner":{"login":"x","topics":["not-these"]},"description":"Numbers \\"fast\\"",',
        '"fork":false,"homepage":"https://numojo.org","size":4321,',
        '"stargazers_count":321,"watchers_count":321,"language":"Mojo",',
        '"forks_count":40,"archived":true,"open_issues_count":12,',
        '"license":{"key":"apache-2.0","spdx_id":"Apache-2.0","name":"Apache License 2.0"},',
        '"topics":["mojo","numerics","\\u00e9t\\u00e9"],"default_branch":"main",',
        '"created_at":"2024-01-01T00:00:00Z","pushed_at":"2026-11-01T12:00:00Z",',
        '"subscribers_count":9}',
    )


def test_parse_stats() raises:
    var r = parse_stats("Mojo-Numerics-and-Algorithms-group/NuMojo", _repo_json())
    assert_equal(r.state, "ok")
    assert_equal(r.stars, 321)
    assert_equal(r.forks, 40)
    assert_equal(r.open_issues, 12)
    assert_equal(r.watchers, 9)
    assert_true(r.archived)
    assert_equal(r.license, "Apache-2.0")
    assert_equal(r.homepage, "https://numojo.org")
    assert_equal(r.description, 'Numbers "fast"')
    assert_equal(r.size_kb, 4321)
    assert_equal(r.default_branch, "main")
    assert_true(r.pushed_at > 0)
    assert_equal(len(r.topics), 3)
    assert_equal(r.topics[0], "mojo")
    assert_equal(r.topics[2], "été")


def test_renamed_and_case() raises:
    # GitHub follows a rename; the reply names the new repository.
    var r = parse_stats("old-owner/numojo", _repo_json())
    assert_equal(r.state, "renamed")
    assert_equal(r.renamed_to, "Mojo-Numerics-and-Algorithms-group/NuMojo")
    # Only the case differs: the same repository.
    var same = parse_stats("mojo-numerics-and-algorithms-group/numojo", _repo_json())
    assert_equal(same.state, "ok")


def test_no_topics() raises:
    var r = parse_stats("a/b", String('{"full_name":"a/b","stargazers_count":0,"license":null}'))
    assert_equal(len(r.topics), 0)
    assert_equal(r.license, "")
    assert_equal(r.stars, 0)


def test_discovery_topics() raises:
    var info = parse_repo(_repo_json())
    assert_equal(len(info.topics), 3)
    assert_equal(info.topics[1], "numerics")


def test_states_and_limits() raises:
    assert_equal(state_of(404), "gone")
    assert_equal(state_of(410), "gone")
    assert_equal(state_of(451), "blocked")
    assert_equal(state_of(500), "error HTTP 500")
    assert_true(limited(Reply(429, "", -1, -1, -1)))
    assert_true(limited(Reply(403, "", 0, -1, 1000)))
    assert_true(limited(Reply(403, "", 10, 30, -1)))
    # A 403 with requests left and no Retry-After is an answer (private,
    # say), not a rate limit.
    assert_false(limited(Reply(403, "", 10, -1, -1)))
    assert_false(limited(Reply(404, "", 0, -1, -1)))
    assert_equal(wait_seconds(Reply(429, "", -1, 30, 2000), 1000, 0), 30)
    assert_equal(wait_seconds(Reply(403, "", 0, -1, 1100), 1000, 0), 101)
    assert_equal(wait_seconds(Reply(403, "", 0, -1, 900), 1000, 0), 1)
    assert_equal(wait_seconds(Reply(429, "", -1, -1, -1), 1000, 2), 240)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
