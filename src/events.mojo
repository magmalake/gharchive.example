"""GH Archive hours into `gharchive.events` record batches."""

from std.os import getenv
from std.time import perf_counter_ns

from iceberg.catalog.filesystem import Table
from parquet import RecordBatch

from datafiles import BatchSink, DataFiles, TableWriter
from eventrows import EventRows, TextColumn
from fetch import Download
from deflate import MARGIN, GzipReader, InflateStatus
from gzstream import GzInput, Whole
from hourindex import HourIndex, write_index
from jscan import Range, find_newline, scan_event, text, timestamp_micros

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


def _add_text(mut c: TextColumn, data: Span[UInt8, _], r: Range, null_if_empty: Bool) raises:
    """`text(data, r)` into `c`: an escaped string is decoded, a plain one
    copied as it is; "" (absent, null, empty) is null if `null_if_empty`."""
    var s = r.start + 1
    var e = r.end - 1
    if r.found() and r.end - r.start >= 2 and data[r.start] == 0x22:
        var plain = True
        for k in range(s, e):
            if data[k] == 0x5C:
                plain = False
                break
        if plain:
            if e > s or not null_if_empty:
                c.add_bytes(data[s:e])
            else:
                c.add_null()
            return
    var t = text(data, r)
    if t.byte_length() == 0 and null_if_empty:
        c.add_null()
    else:
        c.add_bytes(t.as_bytes())


def _int(s: String) -> Int64:
    var v = Int64(0)
    for c in s.as_bytes():
        if c < 48 or c > 57:
            return v
        v = v * 10 + Int64(c - 48)
    return v


struct EventsAndIndex(Movable):
    var rows: List[EventRows]
    var index: HourIndex

    def __init__(out self, var rows: List[EventRows], var index: HourIndex):
        self.rows = rows^
        self.index = index^

    def take_rows(deinit self) -> List[EventRows]:
        return self.rows^

    def take_batches(deinit self) raises -> List[RecordBatch]:
        """The rows as record batches, in arrival order."""
        var out = List[RecordBatch]()
        for i in range(len(self.rows)):
            out.append(self.rows[i].to_batch())
        return out^

    def take_index(deinit self) -> HourIndex:
        return self.index^


struct EventParser(Movable):
    """NDJSON lines of an hour, fed a chunk of whole lines at a time, into
    `EventRows` of `ROWS_PER_BATCH` (each a file of `gharchive.events`)."""

    var out: List[EventRows]
    var cols: EventRows
    var rows: Int
    var bad: Int
    var index: HourIndex
    var indexing: Bool
    """Whether `index` takes every event (candidates, counts, releases)."""

    def __init__(out self, indexing: Bool = False) raises:
        self.out = List[EventRows]()
        self.cols = EventRows()
        self.rows = 0
        self.bad = 0
        self.index = HourIndex()
        self.indexing = indexing

    def feed(mut self, data: Span[UInt8, _], begin: Int, n: Int) raises:
        """The lines in `data[begin:n]`; a last line without its newline is
        parsed as a whole one."""
        var start = begin
        while start < n:
            var end = find_newline(data, start, n)
            if end > start:
                self._line(data, Range(start, end))
            start = end + 1

    def _line(mut self, data: Span[UInt8, _], line: Range) raises:
        var f = scan_event(data, line)
        if not (f.id.found() and f.created_at.found()):
            self.bad += 1
            return
        self.cols.id.add(_int(text(data, f.id)))
        _add_text(self.cols.type, data, f.type, False)
        var at = timestamp_micros(data, f.created_at)
        self.cols.created.add(at)
        _add_text(self.cols.repo, data, f.repo_name, False)
        _add_text(self.cols.actor, data, f.actor_login, True)
        var p = f.payload
        if self.indexing:
            self.index.add(
                text(data, f.type),
                text(data, f.repo_name),
                text(data, f.actor_login),
                at,
                data[p.start : p.end] if p.found() else data[0:0],
            )
        if p.found():
            self.cols.payload.add_bytes(data[p.start : p.end])
        else:
            self.cols.payload.add_null()
        self.rows += 1
        if self.rows % ROWS_PER_BATCH == 0:
            var full = EventRows()
            swap(full, self.cols)
            self.out.append(full^)

    def finish(deinit self) raises -> List[RecordBatch]:
        var both = self^.finish_index()
        return both^.take_batches()

    def finish_index(deinit self) raises -> EventsAndIndex:
        """The last batches, and what `index` collected."""
        var out = self.out^
        if self.rows % ROWS_PER_BATCH != 0:
            out.append(self.cols^)
        else:
            _ = self.cols^
        if self.bad > 0:
            print("gharchive: skipped", self.bad, "lines without id or created_at")
        return EventsAndIndex(out^, self.index^)


def parse_events(data: Span[UInt8, _]) raises -> List[RecordBatch]:
    """One NDJSON hour, decompressed, as batches of `ROWS_PER_BATCH`."""
    var p = EventParser()
    p.feed(data, 0, len(data))
    return p^.finish()


comptime CHUNK = 1 << 23
"""JSON decoded per step: the window the parser reads lines from."""


struct Collect(BatchSink, Movable):
    """Keeps the rows, as record batches in arrival order."""

    var batches: List[RecordBatch]

    def __init__(out self):
        self.batches = List[RecordBatch]()

    def put(mut self, var rows: EventRows) raises:
        self.batches.append(rows.to_batch())


@fieldwise_init
struct Timing(Copyable, Movable):
    """Milliseconds in gunzip, in parsing (building columns included), and
    waiting for input still downloading."""

    var gunzip_ms: Int
    var parse_ms: Int
    var wait_ms: Int


def _drain[S: BatchSink](mut p: EventParser, mut sink: S) raises -> Int:
    """Hands the parser's full batches to `sink`; the time it took, in ns."""
    if len(p.out) == 0:
        return 0
    var t0 = perf_counter_ns()
    var full = List[EventRows]()
    swap(full, p.out)
    for i in range(len(full)):
        var b = EventRows()
        swap(b, full[i])
        sink.put(b^)
    return Int(perf_counter_ns() - t0)


def parse_gz[S: BatchSink](gz: Span[UInt8, _], mut sink: S) raises -> Timing:
    """A whole `.json.gz` hour into `sink` (see `decode_gz`)."""
    return decode_gz(Whole(gz), sink)


def decode_gz[
    I: GzInput, S: BatchSink
](input: I, mut sink: S) raises -> Timing:
    """`decode_index` without the index."""
    var none = HourIndex()
    return decode_index(input, sink, none, False)


def decode_index[
    I: GzInput, S: BatchSink
](input: I, mut sink: S, mut index: HourIndex, indexing: Bool) raises -> Timing:
    """A `.json.gz` hour, gunzipped a window at a time into the parser, so
    the hour's JSON is never in memory at once; each batch goes to `sink`
    as soon as it is full. The input may still be arriving: what is there
    is decoded, and the wait is only for what the inflater needs next."""
    var t_start = perf_counter_ns()
    var inflate_ns = 0
    var sink_ns = 0
    var wait_ns = 0
    var gz = GzipReader(CHUNK * 2)
    var p = EventParser(indexing)
    var lo = 0
    while True:
        var complete = input.complete()
        var have = input.have()
        var t0 = perf_counter_ns()
        # At least a little more than is there, should a line outgrow CHUNK.
        var st = gz.run(
            input.view(have), complete, max(lo + CHUNK, len(gz) + (1 << 20))
        )
        inflate_ns += Int(perf_counter_ns() - t0)
        input.release(gz.input_used())
        if st == InflateStatus.FINISHED:
            p.feed(gz.output(), lo, len(gz))
            break
        var nl = len(gz) - 1
        while nl >= lo and gz.output()[nl] != 0x0A:
            nl -= 1
        if nl >= lo:
            p.feed(gz.output(), lo, nl + 1)
            lo = nl + 1
        lo -= gz.compact(lo)
        sink_ns += _drain(p, sink)
        if st == InflateStatus.NEED_INPUT:
            var t1 = perf_counter_ns()
            _ = input.wait(gz.input_used() + MARGIN)
            wait_ns += Int(perf_counter_ns() - t1)
    var marker = index.marker
    var done = p^.finish_index()
    swap(index, done.index)
    index.marker = marker
    var rest = done^.take_rows()
    var t1 = perf_counter_ns()
    for i in range(len(rest)):
        var b = EventRows()
        swap(b, rest[i])
        sink.put(b^)
    sink_ns += Int(perf_counter_ns() - t1)
    var total = Int(perf_counter_ns() - t_start)
    return Timing(
        inflate_ns // 1_000_000,
        (total - inflate_ns - sink_ns - wait_ns) // 1_000_000,
        wait_ns // 1_000_000,
    )


def fetch_hour(
    day: String,
    hour: Int,
    table: Table,
    candidates: Table,
    repo_hour: Table,
    releases: Table,
) raises -> DataFiles:
    """Downloads one hour of GH Archive and, as it arrives, decompresses
    and parses it and writes it into `table`'s data files; returns them
    uncommitted."""
    var t0 = perf_counter_ns()
    var dl = Download(hour_url(day, hour))
    # Each 50,000-row file is in (repo, type) order: a repository's events
    # repeat its URLs, and rows that resemble each other share a page. On
    # real files that is 7% smaller than (type, repo), 18% than arrival order.
    var w = TableWriter(table)
    # No marker rows: the step commits the index a day at a time.
    var index = HourIndex()
    var timing = decode_index(dl, w, index, True)
    var out = w^.finish()
    var t_index = perf_counter_ns()
    out.index = write_index(index, candidates, repo_hour, releases)
    out.index_ms = Int(perf_counter_ns() - t_index) // 1_000_000
    out.download_ms = dl.ms()
    out.gunzip_ms = timing.gunzip_ms
    out.parse_ms = timing.parse_ms
    out.wait_ms = timing.wait_ms
    out.total_ms = Int(perf_counter_ns() - t0) // 1_000_000
    return out^
