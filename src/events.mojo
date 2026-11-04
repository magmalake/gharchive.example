"""GH Archive hours into `gharchive.events` record batches."""

from std.os import getenv

from iceberg.batch import ColumnBuilder, batch_of
from iceberg.values import Datum
from parquet import RecordBatch

from fetch import get_bytes
from deflate import gunzip
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


def parse_events(data: Span[UInt8, _]) raises -> List[RecordBatch]:
    """One NDJSON hour, decompressed, as batches of `ROWS_PER_BATCH`."""
    var out = List[RecordBatch]()
    var cols = _Cols()
    var n = len(data)
    var start = 0
    var rows = 0
    var bad = 0
    while start < n:
        var end = start
        while end < n and data[end] != 0x0A:
            end += 1
        if end > start:
            var line = Range(start, end)
            var id = field(data, line, "id")
            var created = field(data, line, "created_at")
            if id.found() and created.found():
                cols.id.add(Datum.long_(_int(text(data, id))))
                cols.type.add(Datum.string_(text(data, field(data, line, "type"))))
                cols.created.add(ts(timestamp_micros(data, created)))
                cols.repo.add(Datum.string_(text(data, path(data, line, "repo", "name"))))
                cols.actor.add(str_or_null(text(data, path(data, line, "actor", "login"))))
                var p = field(data, line, "payload")
                if p.found():
                    cols.payload.add(Datum.string_(raw(data, p)))
                else:
                    cols.payload.add_null()
                rows += 1
                if rows % ROWS_PER_BATCH == 0:
                    out.append(cols^.take())
                    cols = _Cols()
            else:
                bad += 1
        start = end + 1
    if rows % ROWS_PER_BATCH != 0:
        out.append(cols^.take())
    else:
        _ = cols^
    if bad > 0:
        print("gharchive: skipped", bad, "lines without id or created_at")
    return out^


def fetch_hour(day: String, hour: Int) raises -> List[RecordBatch]:
    """Downloads, decompresses and parses one hour of GH Archive."""
    var gz = get_bytes(hour_url(day, hour))
    var json = gunzip(Span(gz))
    _ = gz^
    return parse_events(Span(json))
