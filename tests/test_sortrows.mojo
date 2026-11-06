"""Sorting a batch's rows changes their order and nothing else.

    pixi run test
"""

from parquet import RecordBatch
from std.testing import TestSuite, assert_equal, assert_true

from cols import col, i64_at, is_valid, str_at
from events import parse_events
from daymerge import merged_rows
from sortrows import order_by_text, sorted_by_text, take_rows


def _lines(n: Int) -> List[UInt8]:
    var s = String()
    for i in range(n):
        s += String(
            '{"id":"', 9000 + i, '","type":"T', (i * 7) % 5, '","actor":{"login":"',
            "" if i % 6 == 0 else String("u", i % 11),
            '"},"repo":{"name":"o/r', (i * 5) % 13, '"},"payload":{"text":"',
            String("x") * (i % 23), '"},"created_at":"2025-01-01T01:0',
            i % 10, ':00Z"}\n',
        )
    return List[UInt8](s.as_bytes())


def _row(b: RecordBatch, r: Int) -> String:
    """Every column of row `r` in one string; a null actor shows as `<null>`."""
    var out = String()
    for c in range(b.num_columns()):
        ref a = b.column(c)
        if not is_valid(a, r):
            out += "<null>|"
        elif len(a.offsets) > 0:
            out += str_at(a, r) + "|"
        else:
            out += String(i64_at(a, r), "|")
    return out^


def test_rows_come_out_ordered_and_all_there() raises:
    var json = _lines(5_000)
    var batches = parse_events(Span(json))
    assert_equal(len(batches), 1)
    ref b = batches[0]
    var s = sorted_by_text(b, "type", "repo")
    assert_equal(s.num_rows, b.num_rows)
    var t = col(b, "type")
    var r = col(b, "repo")
    for k in range(1, s.num_rows):
        var t0 = str_at(s.column(t), k - 1)
        var t1 = str_at(s.column(t), k)
        assert_true(t0 <= t1)
        if t0 == t1:
            assert_true(str_at(s.column(r), k - 1) <= str_at(s.column(r), k))
    var want = List[String]()
    var got = List[String]()
    for k in range(b.num_rows):
        want.append(_row(b, k))
        got.append(_row(s, k))
    sort(want)
    sort(got)
    assert_true(want == got)
    var nulls = 0
    for k in range(s.num_rows):
        if not is_valid(s.column(col(s, "actor")), k):
            nulls += 1
    assert_equal(nulls, s.column(col(s, "actor")).null_count)
    assert_equal(nulls, b.column(col(b, "actor")).null_count)
    assert_true(nulls > 0)


def test_equal_keys_keep_their_order() raises:
    var json = _lines(2_000)
    var b = parse_events(Span(json))[0].copy()
    var order = order_by_text(b, "type", "repo")
    for k in range(1, len(order)):
        var x = Int(order[k - 1])
        var y = Int(order[k])
        if str_at(b.column(col(b, "type")), x) == str_at(
            b.column(col(b, "type")), y
        ) and str_at(b.column(col(b, "repo")), x) == str_at(
            b.column(col(b, "repo")), y
        ):
            assert_true(x < y)


def test_no_rows_take_no_rows() raises:
    var json = _lines(3)
    var b = parse_events(Span(json))[0].copy()
    var s = take_rows(b, List[Int32]())
    assert_equal(s.num_rows, 0)
    assert_equal(s.num_columns(), 6)
    assert_equal(len(s.column(3).offsets), 1)


def test_merged_hours_sort_like_one_batch() raises:
    """The day's repo_hour file: two hours' batches joined in order, then
    sorted, are the rows of both in (repo, actor) order, ties in hour order."""
    var one = parse_events(Span(_lines(700)))[0].copy()
    var two = parse_events(Span(_lines(500)))[0].copy()
    var both = List[RecordBatch]()
    both.append(one.copy())
    both.append(two.copy())
    var m = merged_rows(both)
    assert_equal(m.num_rows, 1200)
    for k in range(700):
        assert_equal(_row(m, k), _row(one, k))
    for k in range(500):
        assert_equal(_row(m, 700 + k), _row(two, k))
    var order = order_by_text(m, "repo", "actor")
    var s = take_rows(m, order)
    var r = col(s, "repo")
    var a = col(s, "actor")
    for k in range(1, s.num_rows):
        var r0 = str_at(s.column(r), k - 1)
        var r1 = str_at(s.column(r), k)
        assert_true(r0 <= r1)
        if r0 == r1:
            assert_true(str_at(s.column(a), k - 1) <= str_at(s.column(a), k))
            if str_at(s.column(a), k - 1) == str_at(s.column(a), k):
                assert_true(order[k - 1] < order[k])


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
