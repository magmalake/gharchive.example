"""An hour's data files come back from a worker as they were written.

    pixi run test
"""

from std.os import getenv
from dista.codec import decode, encode
from std.testing import TestSuite, assert_equal, assert_true

from datafiles import DataFiles
from events import parse_events
from iceberg.io import FileIO
from iceberg.write import WriteOptions, write_data_files
from lake import events_schema, events_spec
from orca.tables import DataFiles as FileEntries


def _lines() -> List[UInt8]:
    var s = String()
    for i in range(300):
        s += String(
            '{"id":"', 1000 + i, '","type":"PushEvent","actor":{"login":"a',
            i % 7, '"},"repo":{"name":"o/r', i % 5, '"},"payload":{"n":', i,
            '},"created_at":"2025-01-0', 1 + i % 2, 'T0', i % 10, ':00:00Z"}\n',
        )
    return List[UInt8](s.as_bytes())


def test_round_trip() raises:
    var dir = String(getenv("TMPDIR", "/tmp"), "/census-test-datafiles")
    var io = FileIO.local()
    var files = write_data_files(
        io, dir, parse_events(Span(_lines())), events_schema(), events_spec(),
        0, WriteOptions(),
    )
    assert_equal(len(files), 2)  # two days, two partitions
    # The struct crosses by dista's reflection: its plain fields as they
    # are, `files` through orca's `DataFiles` Codec (iceberg's wire form).
    var sent = DataFiles()
    sent.files = FileEntries(files.copy())
    sent.rows = 300
    sent.parse_ms = 7
    # The hour's index files ride along, nested.
    sent.index.repo_hour = FileEntries(files.copy())
    sent.index.repo_hour_rows = 42
    sent.index_ms = 9
    var bytes = List[UInt8]()
    encode(sent, bytes)
    var pos = 0
    var back = decode[DataFiles](Span(bytes), pos)
    assert_equal(pos, len(bytes))
    assert_equal(back.rows, 300)
    assert_equal(back.parse_ms, 7)
    assert_equal(back.index.repo_hour_rows, 42)
    assert_equal(back.index_ms, 9)
    assert_equal(len(back.index.repo_hour), len(files))
    assert_equal(len(back.index.candidates), 0)
    assert_equal(back.index.repo_hour.files[0].file_path, files[0].file_path)
    ref got = back.files
    assert_equal(len(got), len(files))
    for k in range(len(files)):
        ref a = files[k]
        ref b = got.files[k]
        assert_equal(a.file_path, b.file_path)
        assert_equal(a.record_count, b.record_count)
        assert_equal(a.file_size_in_bytes, b.file_size_in_bytes)
        assert_equal(len(a.partition), len(b.partition))
        assert_equal(a.partition[0].i, b.partition[0].i)
        assert_equal(Int(a.partition[0].kind), Int(b.partition[0].kind))
        assert_equal(len(a.metrics), len(b.metrics))
        for m in range(len(a.metrics)):
            assert_equal(a.metrics[m].field_id, b.metrics[m].field_id)
            assert_equal(a.metrics[m].value_count, b.metrics[m].value_count)
            assert_true(a.metrics[m].lower_bound == b.metrics[m].lower_bound)
            assert_true(a.metrics[m].upper_bound == b.metrics[m].upper_bound)
        assert_equal(len(a.column_sizes), len(b.column_sizes))
        assert_true(a.split_offsets == b.split_offsets)
        assert_equal(a.sort_order_id, b.sort_order_id)
        assert_equal(a.has_sort_order_id, b.has_sort_order_id)
        io.delete(a.file_path)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
