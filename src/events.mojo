"""GH Archive hours into `gharchive.events` record batches."""

from std.os import getenv
from std.time import perf_counter_ns

from iceberg.batch import ColumnBuilder, batch_of
from iceberg.catalog.filesystem import Table
from iceberg.values import Datum
from parquet import RecordBatch

from datafiles import BatchSink, DataFiles, TableWriter
from fetch import get_bytes
from gzstream import FINISHED, GzipInflater
from jscan import Range, field, path, raw, text, timestamp_micros
from lake import events_schema, str_or_null, ts

comptime ROWS_PER_BATCH = 50_000


def hour_url(day: String, hour: Int) -> String:
    """`https://data.gharchive.org/2025-09-15-16.json.gz`: hours aren't
    zero-padded in GH Archive's names."""
    var base = getenv("GHARCHIVE_BASE", "https://data.gharchive.org")
    return String(base, "/", day, "-", hour, ".json.gz")


def parse_hours(spec: String) raises -> List[Int]:
    """`GHARCHIVE_HOURS`: empty for 0-23, else `A-B` or `A,B,C`."""
    var out = List[Int]()
    if spec.byte_length() == 0:
        for h in range(24):
            out.append(h)
        return out^
    for part in spec.split(","):
        var p = String(part.strip())
        if "-" in p:
            var ab = p.split("-")
            for h in range(Int(ab[0]), Int(ab[1]) + 1):
                out.append(h)
        elif p:
            out.append(Int(p))
    for h in out:
        if h < 0 or h > 23:
            raise Error("GHARCHIVE_HOURS: hour out of range: ", h)
    return out^


struct _Cols(Movable):
    var id: ColumnBuilder
    var type: ColumnBuilder
    var created: ColumnBuilder
    var repo: ColumnBuilder
    var actor: ColumnBuilder
    var payload: ColumnBuilder

    def __init__(out self) raises:
        var s = events_schema()
        self.id = ColumnBuilder.of(s, 1)
        self.type = ColumnBuilder.of(s, 2)
        self.created = ColumnBuilder.of(s, 3)
        self.repo = ColumnBuilder.of(s, 4)
        self.actor = ColumnBuilder.of(s, 5)
        self.payload = ColumnBuilder.of(s, 6)

    def take(deinit self) raises -> RecordBatch:
        var cols = List[ColumnBuilder]()
        cols.append(self.id^)
        cols.append(self.type^)
        cols.append(self.created^)
        cols.append(self.repo^)
        cols.append(self.actor^)
        cols.append(self.payload^)
        return batch_of(cols)


def _int(s: String) -> Int64:
    var v = Int64(0)
    for c in s.as_bytes():
        if c < 48 or c > 57:
            return v
        v = v * 10 + Int64(c - 48)
    return v


struct EventParser(Movable):
    """NDJSON lines of an hour, fed a chunk of whole lines at a time, into
    batches of `ROWS_PER_BATCH`."""

    var out: List[RecordBatch]
    var cols: _Cols
    var rows: Int
    var bad: Int

    def __init__(out self) raises:
        self.out = List[RecordBatch]()
        self.cols = _Cols()
        self.rows = 0
        self.bad = 0

    def feed(mut self, data: Span[UInt8, _], begin: Int, n: Int) raises:
        """The lines in `data[begin:n]`; a last line without its newline is
        parsed as a whole one."""
        var start = begin
        while start < n:
            var end = start
            while end < n and data[end] != 0x0A:
                end += 1
            if end > start:
                self._line(data, Range(start, end))
            start = end + 1

    def _line(mut self, data: Span[UInt8, _], line: Range) raises:
        var id = field(data, line, "id")
        var created = field(data, line, "created_at")
        if not (id.found() and created.found()):
            self.bad += 1
            return
        self.cols.id.add(Datum.long_(_int(text(data, id))))
        self.cols.type.add(Datum.string_(text(data, field(data, line, "type"))))
        self.cols.created.add(ts(timestamp_micros(data, created)))
        self.cols.repo.add(Datum.string_(text(data, path(data, line, "repo", "name"))))
        self.cols.actor.add(str_or_null(text(data, path(data, line, "actor", "login"))))
        var p = field(data, line, "payload")
        if p.found():
            self.cols.payload.add(Datum.string_(raw(data, p)))
        else:
            self.cols.payload.add_null()
        self.rows += 1
        if self.rows % ROWS_PER_BATCH == 0:
            var full = _Cols()
            swap(full, self.cols)
            self.out.append(full^.take())

    def finish(deinit self) raises -> List[RecordBatch]:
        var out = self.out^
        if self.rows % ROWS_PER_BATCH != 0:
            out.append(self.cols^.take())
        else:
            _ = self.cols^
        if self.bad > 0:
            print("gharchive: skipped", self.bad, "lines without id or created_at")
        return out^


def parse_events(data: Span[UInt8, _]) raises -> List[RecordBatch]:
    """One NDJSON hour, decompressed, as batches of `ROWS_PER_BATCH`."""
    var p = EventParser()
    p.feed(data, 0, len(data))
    return p^.finish()


comptime CHUNK = 1 << 23
"""JSON decoded per step: the window the parser reads lines from."""


struct Collect(BatchSink, Movable):
    """Keeps the batches."""

    var batches: List[RecordBatch]

    def __init__(out self):
        self.batches = List[RecordBatch]()

    def put(mut self, var batch: RecordBatch) raises:
        self.batches.append(batch^)


@fieldwise_init
struct Timing(Copyable, Movable):
    """Milliseconds in gunzip and in parsing (building columns included)."""

    var gunzip_ms: Int
    var parse_ms: Int


def _drain[S: BatchSink](mut p: EventParser, mut sink: S) raises -> Int:
    """Hands the parser's full batches to `sink`; the time it took, in ns."""
    if len(p.out) == 0:
        return 0
    var t0 = perf_counter_ns()
    var full = List[RecordBatch]()
    swap(full, p.out)
    for i in range(len(full)):
        var b = RecordBatch()
        swap(b, full[i])
        sink.put(b^)
    return Int(perf_counter_ns() - t0)


def parse_gz[S: BatchSink](gz: Span[UInt8, _], mut sink: S) raises -> Timing:
    """A whole `.json.gz` hour, gunzipped a window at a time into the
    parser, so the hour's JSON is never in memory at once. Each batch goes
    to `sink` as soon as it is full."""
    var t_start = perf_counter_ns()
    var inflate_ns = 0
    var sink_ns = 0
    var inf = GzipInflater(CHUNK * 2)
    var p = EventParser()
    var lo = 0
    while True:
        var t0 = perf_counter_ns()
        # At least a little more than is there, should a line outgrow CHUNK.
        var st = inf.run(gz, True, max(lo + CHUNK, inf.n + (1 << 20)))
        inflate_ns += Int(perf_counter_ns() - t0)
        if st == FINISHED:
            p.feed(Span(inf.buf), lo, inf.n)
            break
        var buf = Span(inf.buf)
        var nl = inf.n - 1
        while nl >= lo and buf[nl] != 0x0A:
            nl -= 1
        if nl >= lo:
            p.feed(buf, lo, nl + 1)
            lo = nl + 1
        lo -= inf.compact(lo)
        sink_ns += _drain(p, sink)
    var rest = p^.finish()
    var t1 = perf_counter_ns()
    for i in range(len(rest)):
        var b = RecordBatch()
        swap(b, rest[i])
        sink.put(b^)
    sink_ns += Int(perf_counter_ns() - t1)
    var total = Int(perf_counter_ns() - t_start)
    return Timing(inflate_ns // 1_000_000, (total - inflate_ns - sink_ns) // 1_000_000)


def fetch_hour(day: String, hour: Int, table: Table) raises -> DataFiles:
    """Downloads, decompresses and parses one hour of GH Archive, and writes
    it into `table`'s data files; returns them uncommitted."""
    var t0 = perf_counter_ns()
    var gz = get_bytes(hour_url(day, hour))
    var t1 = perf_counter_ns()
    var w = TableWriter(table)
    var timing = parse_gz(Span(gz), w)
    var out = w^.finish()
    out.download_ms = Int(t1 - t0) // 1_000_000
    out.gunzip_ms = timing.gunzip_ms
    out.parse_ms = timing.parse_ms
    return out^
