"""The Overview's numbers over a few in-memory commits, the Repos table's
sorting and filtering, and the charts' text.

    pixi run test
"""

from std.testing import TestSuite, assert_equal, assert_true

from charts import compact, donut, line_chart, nice_ceil
from jscan import days_from_civil
from listing import (
    NEW_30D,
    NEW_LAST_MONTH,
    NEW_MONTH,
    ListQuery,
    list_url,
    parse_list_query,
    select_repos,
    sorted_by,
    with_version,
)
from overview import (
    DAY_US,
    Builder,
    bucket_color,
    month_label,
    month_of_days,
    tool_code,
    top_gains,
)


def _us(y: Int, m: Int, d: Int) -> Int64:
    return Int64(days_from_civil(y, m, d)) * DAY_US


def test_months() raises:
    assert_equal(month_of_days(0), 0)
    assert_equal(month_label(0), "1970-01")
    assert_equal(month_label(month_of_days(days_from_civil(2026, 11, 5))), "2026-11")
    assert_equal(month_label(month_of_days(days_from_civil(2024, 2, 29))), "2024-02")
    assert_equal(month_of_days(days_from_civil(2024, 12, 31)) + 1, month_of_days(days_from_civil(2025, 1, 1)))


def test_tool_code() raises:
    assert_equal(tool_code("magic"), 1)
    assert_equal(tool_code("pixi"), 2)
    assert_equal(tool_code("none"), 0)
    assert_equal(tool_code(""), 0)


def _small() raises -> Builder:
    """Today is 2026-11-15. `a` has two commits and moves 1.0.0 to 1.1.0,
    `b` is old (2024) with a magic lock then one commit this month, `c` has
    no commits, `d` is stale."""
    var b = Builder(days_from_civil(2026, 11, 15))
    var a = b.add_repo("o/a")
    var bb = b.add_repo("o/b")
    _ = b.add_repo("o/c")
    var d = b.add_repo("o/d")
    # a: Dec 2025 (100 lines, pixi 1.0.0), then 20 Oct 2026 (150 lines, 1.1.0).
    b.add_commit(a, _us(2025, 12, 3), 0, 100, 2, "1.0.0")
    b.add_commit(a, _us(2026, 10, 20), 1, 150, 2, "1.1.0")
    # b: May 2024 (40 lines, magic, 0.26.1), 10 Nov 2026 (60 lines, magic).
    b.add_commit(bb, _us(2024, 5, 2), 0, 40, 1, "0.26.1")
    b.add_commit(bb, _us(2026, 11, 10), 1, 60, 1, "0.26.1")
    # d: one commit in 2023, no version.
    b.add_commit(d, _us(2023, 6, 1), 0, 10, 0, "")
    return b^


def test_totals() raises:
    var ov = _small().finish(4)
    assert_equal(ov.repos, 4)
    assert_equal(ov.with_history, 3)
    assert_equal(ov.commits, 5)
    assert_equal(ov.lines, 150 + 60 + 10)
    # Within 30 days of 2026-11-15 (after 2026-10-16): a's 20 Oct and b's 10 Nov.
    assert_equal(ov.commits_30, 2)
    assert_equal(ov.commits_prev_30, 0)
    # 30 days ago: a had 100 lines (Dec 2025), b 40, d 10.
    assert_equal(ov.lines_30_ago, 150)
    assert_equal(ov.repos_30_ago, 3)
    assert_equal(ov.active, 2)
    assert_equal(ov.new_this_month, 0)
    assert_equal(ov.new_last_month, 0)


def test_buckets() raises:
    var ov = _small().finish(4)
    # a is on 1.1, b on 0.26.x (pre-1.0), d and c have no version.
    var want: List[String] = ["pre-1.0", "1.1", "unknown"]
    assert_equal(len(ov.buckets), 3)
    for i in range(3):
        assert_equal(ov.buckets[i], want[i])
    assert_equal(ov.bucket_repos[0], 1)
    assert_equal(ov.bucket_repos[1], 1)
    assert_equal(ov.bucket_repos[2], 2)
    # Active: a and b; d's commit is from 2023.
    assert_equal(ov.bucket_active[0], 1)
    assert_equal(ov.bucket_active[1], 1)
    assert_equal(ov.bucket_active[2], 0)
    # The old families are still counted.
    var fams: List[String] = ["0.26.x", "1.x", "unknown"]
    for i in range(3):
        assert_equal(ov.families[i], fams[i])
    assert_equal(ov.family_repos[1], 1)


def test_bucket_colors() raises:
    assert_equal(bucket_color("pre-1.0"), "var(--c0)")
    assert_equal(bucket_color("1.0"), "var(--c1)")
    assert_equal(bucket_color("1.3"), "var(--c4)")
    assert_equal(bucket_color("1.4"), "var(--c6)")
    assert_equal(bucket_color("1.7"), "var(--c9)")
    assert_equal(bucket_color("1.8"), "var(--c1)")
    assert_equal(bucket_color("other"), "var(--c5)")
    assert_true(bucket_color("unknown") != bucket_color("other"))
    # Distinct minors get distinct colours until the palette wraps.
    for i in range(7):
        assert_true(bucket_color(String("1.", i)) != bucket_color(String("1.", i + 1)))


def test_listing_query() raises:
    var nq = parse_list_query("commits30", "", "", "", "30d")
    assert_equal(nq.sort, "commits30")
    assert_equal(nq.new, "30d")
    assert_equal(list_url(nq), "/repos?sort=commits30&new=30d")
    assert_equal(parse_list_query("", "", "", "", "yesterday").new, "")

    var q = parse_list_query("stars", "asc", "1.x", "1y")
    assert_equal(q.sort, "stars")
    assert_true(q.asc)
    assert_equal(q.version, "1.x")
    assert_true(q.active)
    assert_equal(list_url(q), "/repos?sort=stars&dir=asc&version=1.x&active=1y")
    var d = parse_list_query("", "", "", "")
    assert_equal(list_url(d), "/repos")
    assert_true(d.is_default_order())
    assert_true(not d.has_filter())
    # Unknown values are the defaults.
    var bad = parse_list_query("nonsense", "up", "", "forever")
    assert_equal(list_url(bad), "/repos")
    # A header click: the same column flips, another starts largest first.
    assert_equal(list_url(sorted_by(d, "lines")), "/repos?dir=asc")
    assert_equal(list_url(sorted_by(d, "stars")), "/repos?sort=stars")
    assert_equal(list_url(sorted_by(sorted_by(d, "stars"), "stars")), "/repos?sort=stars&dir=asc")
    assert_equal(list_url(with_version(q, "")), "/repos?sort=stars&dir=asc&active=1y")


def test_select_new_and_commits30() raises:
    var lines: List[Int64] = [900, 500, 100]
    var files: List[Int64] = [1, 1, 1]
    var stars: List[Int64] = [0, 0, 0]
    var buckets: List[String] = ["1.2", "pre-1.0", "1.2"]
    var legacy: List[String] = ["1.x", "0.26.x", "1.x"]
    var active: List[Bool] = [True, True, True]
    var news: List[Int] = [NEW_MONTH | NEW_30D, NEW_LAST_MONTH, 0]
    var c30: List[Int64] = [3, 9, 5]
    var month = select_repos(parse_list_query("", "", "", "", "month"), lines, files, stars, buckets, active, legacy, news, c30)
    assert_equal(len(month), 1)
    assert_equal(month[0], 0)
    var last = select_repos(parse_list_query("", "", "", "", "last-month"), lines, files, stars, buckets, active, legacy, news, c30)
    assert_equal(len(last), 1)
    assert_equal(last[0], 1)
    assert_equal(len(select_repos(parse_list_query("", "", "", "", "30d"), lines, files, stars, buckets, active, legacy, news, c30)), 1)
    # Combined with the version filters, new and old.
    assert_equal(len(select_repos(parse_list_query("", "", "pre-1.0", "", "month"), lines, files, stars, buckets, active, legacy, news, c30)), 0)
    assert_equal(len(select_repos(parse_list_query("", "", "0.26.x", "", "last-month"), lines, files, stars, buckets, active, legacy, news, c30)), 1)
    assert_equal(len(select_repos(parse_list_query("", "", "1.x", "", ""), lines, files, stars, buckets, active, legacy, news, c30)), 2)
    var by = select_repos(parse_list_query("commits30", "", "", ""), lines, files, stars, buckets, active, legacy, news, c30)
    var want: List[Int] = [1, 2, 0]
    for i in range(3):
        assert_equal(by[i], want[i])


def test_select() raises:
    # Five repos in the default order (lines descending).
    var lines: List[Int64] = [900, 500, 500, 100, 50]
    var files: List[Int64] = [9, 20, 5, 1, 1]
    var stars: List[Int64] = [3, 40, 40, 0, 7]
    var fams: List[String] = ["1.x", "0.26.x", "1.x", "unknown", "1.x"]
    var active: List[Bool] = [True, True, False, False, True]
    var d = parse_list_query("", "", "", "")
    var all = select_repos(d, lines, files, stars, fams, active)
    assert_equal(len(all), 5)
    for i in range(5):
        assert_equal(all[i], i)
    var by_stars = select_repos(parse_list_query("stars", "", "", ""), lines, files, stars, fams, active)
    var want: List[Int] = [1, 2, 4, 0, 3]  # the 40-star tie keeps its order
    for i in range(5):
        assert_equal(by_stars[i], want[i])
    var by_files_asc = select_repos(parse_list_query("files", "asc", "", ""), lines, files, stars, fams, active)
    var want2: List[Int] = [3, 4, 2, 0, 1]
    for i in range(5):
        assert_equal(by_files_asc[i], want2[i])
    var lines_asc = select_repos(parse_list_query("lines", "asc", "", ""), lines, files, stars, fams, active)
    var want3: List[Int] = [4, 3, 1, 2, 0]
    for i in range(5):
        assert_equal(lines_asc[i], want3[i])
    var v1 = select_repos(parse_list_query("", "", "1.x", ""), lines, files, stars, fams, active)
    assert_equal(len(v1), 3)
    assert_equal(v1[0], 0)
    assert_equal(v1[2], 4)
    var both = select_repos(parse_list_query("stars", "", "1.x", "1y"), lines, files, stars, fams, active)
    assert_equal(len(both), 2)
    assert_equal(both[0], 4)
    assert_equal(both[1], 0)
    var unknown = select_repos(parse_list_query("", "", "unknown", ""), lines, files, stars, fams, active)
    assert_equal(len(unknown), 1)
    assert_equal(unknown[0], 3)
    assert_equal(len(select_repos(parse_list_query("", "", "9.x", ""), lines, files, stars, fams, active)), 0)


def test_compact() raises:
    assert_equal(compact(0), "0")
    assert_equal(compact(950), "950")
    assert_equal(compact(1000), "1k")
    assert_equal(compact(1234), "1.2k")
    assert_equal(compact(15_000), "15k")
    assert_equal(compact(8_365_141), "8.3M")
    assert_equal(compact(2_000_000), "2M")
    assert_equal(nice_ceil(1), 1)
    assert_equal(nice_ceil(7), 10)
    assert_equal(nice_ceil(130), 200)
    assert_equal(nice_ceil(8_365_141), 10_000_000)
    assert_equal(nice_ceil(2000), 2000)


def test_donut_and_line() raises:
    var labels: List[String] = ["1.x", "unknown"]
    var values: List[Int] = [3, 1]
    var colors: List[String] = ["var(--c4)", "var(--border-strong)"]
    var hrefs: List[String] = ["/repos?version=1.x", "/repos?version=unknown"]
    var svg = donut(labels, values, colors, hrefs, "4", "repos", "Donut chart: 4 repos")
    assert_true("viewBox='0 0 200 200'" in svg)
    assert_true("<title>Donut chart: 4 repos</title>" in svg)
    assert_true("href='/repos?version=unknown'" in svg)
    assert_true("1.x: 3 of 4" in svg)
    # 75% of the circumference of r=70 is 329.87.
    assert_true("stroke-dasharray='329.87 109.96'" in svg)
    var months: List[String] = ["2025-01", "2025-02", "2025-03"]
    var names: List[String] = ["repos"]
    var series = List[List[Int64]]()
    series.append([1, 5, 8])
    var cs: List[String] = ["var(--ember)"]
    var line = line_chart(months, names, series, cs, False, "Line chart: repos", True)
    assert_true("role=img" in line)
    assert_true("<polyline" in line)
    assert_true("<polygon" in line)
    assert_true(">10</text>" in line)
    assert_true("2025-01" in line)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
