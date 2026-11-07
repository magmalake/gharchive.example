"""The console's PostHog snippet: there with a project key, with the key,
memory persistence and the site, and absent for anything else.

    pixi run test
"""

from std.testing import TestSuite, assert_equal, assert_true

from analytics import is_project_key, posthog_snippet


def test_snippet_with_a_project_key() raises:
    var s = posthog_snippet("phc_TestKey_123-x", "mojourney")
    assert_true(
        s.startswith('<script defer src="/ph/static/array.js"></script>')
    )
    assert_true(
        "posthog.init(\"phc_TestKey_123-x\",{api_host:location.origin+'/ph',"
        in s
    )
    assert_true("ui_host:'https://us.posthog.com'" in s)
    assert_true("defaults:'2025-05-24'" in s)
    assert_true("persistence:'memory'" in s)
    assert_true("capture_exceptions:true" in s)
    assert_true("posthog.register({site:'mojourney'})" in s)
    assert_true(s.endswith("</script>"))


def test_no_snippet_without_one() raises:
    assert_equal(posthog_snippet("", "mojourney"), "")
    assert_equal(posthog_snippet("phx_abc", "mojourney"), "")
    assert_equal(posthog_snippet("not_a_key", "mojourney"), "")
    # A key that would close the string and run its own code.
    assert_equal(posthog_snippet('phc_x");alert(1);//', "mojourney"), "")
    assert_equal(posthog_snippet("phc_x</script>", "mojourney"), "")
    assert_true(is_project_key("phc_abcDEF012_-"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
