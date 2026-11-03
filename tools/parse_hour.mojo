"""Parses one local GH Archive hour and prints rows and timings.

    mojo build -I src tools/parse_hour.mojo -o build/parse_hour
    ./build/parse_hour 2025-09-15-16.json.gz
"""

from std.sys import argv
from std.time import perf_counter_ns

from events import parse_events
from gz import gunzip


def main() raises:
    var args = argv()
    var t0 = perf_counter_ns()
    var f = open(String(args[1]), "r")
    var gz = f.read_bytes()
    f.close()
    var t1 = perf_counter_ns()
    var data = gunzip(Span(gz))
    var t2 = perf_counter_ns()
    var batches = parse_events(Span(data))
    var t3 = perf_counter_ns()
    var rows = 0
    for b in batches:
        rows += b.num_rows
    print("bytes", len(gz), "->", len(data), "rows", rows, "batches", len(batches))
    print("read", (t1 - t0) // 1_000_000, "ms gunzip", (t2 - t1) // 1_000_000, "ms parse", (t3 - t2) // 1_000_000, "ms")
