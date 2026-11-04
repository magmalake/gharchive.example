"""The streaming gunzip gives deflate-mojo's `gunzip` bytes, however the
input arrives and however small the window.

    pixi run test
"""

from std.testing import TestSuite, assert_equal, assert_raises, assert_true

from deflate import gunzip, gzip
from gzstream import FINISHED, NEED_INPUT, GzipInflater


def _lines(n: Int, salt: Int) -> List[UInt8]:
    var s = String()
    for i in range(n):
        s += String(
            '{"id":"', i * 7 + salt, '","type":"PushEvent","payload":{"n":',
            (i * 31 + salt) % 977, ',"msg":"line \\"', i, '\\" of many"}}\n',
        )
    return List[UInt8](s.as_bytes())


def _stream(
    gz: List[UInt8], step: Int, window: Int, margin: Int = -1
) raises -> List[UInt8]:
    """Inflate `gz` handing over `step` more input bytes each time it asks,
    draining a `window` at a time; every byte drained is collected."""
    var inf = GzipInflater(window)
    if margin >= 0:
        inf.margin = margin
    var out = List[UInt8]()
    var have = min(step, len(gz))
    var lo = 0
    while True:
        var complete = have == len(gz)
        var st = inf.run(Span(gz)[:have], complete, lo + window)
        for k in range(lo, inf.n):
            out.append(inf.buf[k])
        lo = inf.n
        if st == FINISHED:
            break
        if st == NEED_INPUT:
            assert_true(not complete)
            have = min(have + step, len(gz))
        lo -= inf.compact(lo)
    return out^


def test_matches_gunzip_in_any_steps() raises:
    var a = _lines(1500, 1)
    var b = _lines(900, 2)
    var gz = gzip(Span(a))
    gz.extend(Span(gzip(Span(b), level=0)))  # stored blocks too
    gz.extend(Span(gzip(Span(a))))
    var want = gunzip(Span(gz))
    for step in [len(gz), 20_011, 3_001]:
        for window in [40_000, 1 << 22]:
            for margin in [-1, 0]:
                # deflate-mojo's gzip writes a member as one block, which a
                # margin of 0 decodes again for every step that falls short.
                if margin == 0 and step < 20_000:
                    continue
                var got = _stream(gz, step, window, margin)
                assert_equal(len(got), len(want))
                for k in range(len(want)):
                    if got[k] != want[k]:
                        assert_equal(k, -1)


def test_corruption_is_caught() raises:
    var gz = gzip(Span(_lines(500, 3)))
    gz[len(gz) - 6] ^= 0xFF  # the CRC-32
    with assert_raises():
        _ = _stream(gz, len(gz), 1 << 16)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
