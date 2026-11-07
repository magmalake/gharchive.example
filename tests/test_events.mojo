"""An hour decodes to the same rows however its download arrives.

    pixi run test
"""

from std.memory.alloc import unsafe_alloc
from std.testing import TestSuite, assert_equal, assert_true

from cols import i64_at, str_at
from deflate import gzip
from events import Collect, decode_gz, parse_events
from gzstream import GzInput, Whole


struct Trickle(GzInput, Movable):
    """`data`, of which `step` more bytes arrive each time it is waited on."""

    var data: Whole
    var step: Int
    var cell: Int
    """The address of the count arrived so far."""

    def __init__(out self, data: Span[UInt8, _], step: Int):
        self.data = Whole(data)
        self.step = step
        var p = unsafe_alloc[Int](1)
        p.unsafe_write(0)
        self.cell = Int(p)

    def _n(self) -> Pointer[Int, MutUntrackedOrigin]:
        return Pointer[Int, MutUntrackedOrigin](unsafe_from_address=self.cell)

    def have(self) raises -> Int:
        return self._n()[]

    def complete(self) raises -> Bool:
        return self._n()[] == self.data.n

    def view(self, n: Int) -> Span[UInt8, MutUntrackedOrigin]:
        return self.data.view(n)

    def wait(self, want: Int) raises -> Int:
        self._n()[] = min(self._n()[] + self.step, self.data.n)
        return self._n()[]

    def release(self, upto: Int):
        pass


def _lines(n: Int) -> List[UInt8]:
    var s = String()
    for i in range(n):
        s += String(
            '{"id":"', 5000 + i, '","type":"T', i % 3, '","actor":{"login":"u',
            i % 11, '"},"repo":{"name":"o/r', i % 13, '"},"payload":{"text":"',
            String('ab\\"c') * (i % 40), '"},"created_at":"2025-01-01T01:0',
            i % 10, ':00Z"}\n',
        )
    return List[UInt8](s.as_bytes())


def test_trickled_download_gives_the_same_rows() raises:
    var json = _lines(60_000)
    var want = parse_events(Span(json))
    var gz = gzip(Span(json))
    for step in [len(gz), 300_000, 70_001]:
        var sink = Collect()
        _ = decode_gz(Trickle(Span(gz), step), sink)
        assert_equal(len(sink.batches), len(want))
        for b in range(len(want)):
            ref x = want[b]
            ref y = sink.batches[b]
            assert_equal(x.num_rows, y.num_rows)
            for c in range(6):
                assert_true(x.column(c).values == y.column(c).values)
                assert_true(x.column(c).offsets == y.column(c).offsets)
                assert_true(x.column(c).validity == y.column(c).validity)
        assert_equal(i64_at(sink.batches[0].column(0), 7), 5007)
        assert_equal(str_at(sink.batches[0].column(4), 7), "u7")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
