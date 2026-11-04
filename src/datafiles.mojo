"""Data files written on a dista worker, sent back to the step to commit.

An hour's task writes its Parquet files into the table's `data/` itself and
returns only their `DataFile` entries, which the step commits as one
append. iceberg-mojo's `DataFile` holds `List`s, which dista's reflection
codec can't encode, so `DataFiles` encodes them by hand (GAPS.md).
"""

from dista import Codec
from dista.codec import decode, encode, get_scalar, put_scalar
from std.time import perf_counter_ns

from iceberg.catalog.filesystem import Table
from iceberg.expressions import ColumnMetrics
from iceberg.io import FileIO
from iceberg.schema import Schema
from iceberg.transforms import PartitionSpec
from iceberg.write import WriteOptions, write_data_files
from parquet import RecordBatch
from iceberg.manifest import DataFile
from iceberg.values import Datum


def _put_int(mut out: List[UInt8], v: Int):
    put_scalar[DType.int64](out, Int64(v))


def _get_int(buf: Span[UInt8, _], mut pos: Int) raises -> Int:
    return Int(get_scalar[DType.int64](buf, pos))


def _put_bool(mut out: List[UInt8], v: Bool):
    out.append(UInt8(1) if v else UInt8(0))


def _get_bool(buf: Span[UInt8, _], mut pos: Int) raises -> Bool:
    var v = get_scalar[DType.uint8](buf, pos)
    return v != 0


def _put_bytes(mut out: List[UInt8], b: List[UInt8]):
    _put_int(out, len(b))
    out.extend(Span(b))


def _get_bytes(buf: Span[UInt8, _], mut pos: Int) raises -> List[UInt8]:
    var n = _get_int(buf, pos)
    if n < 0 or n > len(buf) - pos:
        raise Error("decode: bad byte-string length ", n)
    var out = List[UInt8](Span(buf)[pos : pos + n])
    pos += n
    return out^


def _put_datum(mut out: List[UInt8], d: Datum):
    out.append(d.kind)
    put_scalar[DType.int64](out, d.i)
    put_scalar[DType.float64](out, d.f)
    encode(d.s, out)
    _put_bytes(out, d.b)
    _put_int(out, d.precision)
    _put_int(out, d.scale)
    _put_int(out, d.length)
    _put_bool(out, d.valid)


def _get_datum(buf: Span[UInt8, _], mut pos: Int) raises -> Datum:
    var kind = get_scalar[DType.uint8](buf, pos)
    var i = get_scalar[DType.int64](buf, pos)
    var f = get_scalar[DType.float64](buf, pos)
    var s = decode[String](buf, pos)
    var b = _get_bytes(buf, pos)
    var precision = _get_int(buf, pos)
    var scale = _get_int(buf, pos)
    var length = _get_int(buf, pos)
    var valid = _get_bool(buf, pos)
    return Datum(kind, i, f, s^, b^, precision, scale, length, valid)


def _put_metrics(mut out: List[UInt8], ms: List[ColumnMetrics]):
    _put_int(out, len(ms))
    for m in ms:
        _put_int(out, m.field_id)
        put_scalar[DType.int64](out, m.value_count)
        _put_bool(out, m.has_value_count)
        put_scalar[DType.int64](out, m.null_value_count)
        _put_bool(out, m.has_null_value_count)
        put_scalar[DType.int64](out, m.nan_value_count)
        _put_bool(out, m.has_nan_value_count)
        _put_bytes(out, m.lower_bound)
        _put_bool(out, m.has_lower)
        _put_bytes(out, m.upper_bound)
        _put_bool(out, m.has_upper)


def _get_metrics(
    buf: Span[UInt8, _], mut pos: Int
) raises -> List[ColumnMetrics]:
    var n = _get_int(buf, pos)
    var out = List[ColumnMetrics]()
    for _ in range(n):
        var field_id = _get_int(buf, pos)
        var vc = get_scalar[DType.int64](buf, pos)
        var has_vc = _get_bool(buf, pos)
        var nc = get_scalar[DType.int64](buf, pos)
        var has_nc = _get_bool(buf, pos)
        var nanc = get_scalar[DType.int64](buf, pos)
        var has_nanc = _get_bool(buf, pos)
        var lo = _get_bytes(buf, pos)
        var has_lo = _get_bool(buf, pos)
        var hi = _get_bytes(buf, pos)
        var has_hi = _get_bool(buf, pos)
        out.append(
            ColumnMetrics(
                field_id, vc, has_vc, nc, has_nc, nanc, has_nanc, lo^, has_lo,
                hi^, has_hi,
            )
        )
    return out^


def encode_data_file(mut out: List[UInt8], f: DataFile):
    _put_int(out, f.content)
    encode(f.file_path, out)
    encode(f.file_format, out)
    _put_int(out, len(f.partition))
    for d in f.partition:
        _put_datum(out, d)
    put_scalar[DType.int64](out, f.record_count)
    put_scalar[DType.int64](out, f.file_size_in_bytes)
    _put_metrics(out, f.column_sizes)
    _put_metrics(out, f.metrics)
    _put_bytes(out, f.key_metadata)
    _put_bool(out, f.has_key_metadata)
    _put_int(out, len(f.split_offsets))
    for o in f.split_offsets:
        put_scalar[DType.int64](out, o)
    _put_int(out, len(f.equality_ids))
    for e in f.equality_ids:
        _put_int(out, e)
    _put_int(out, f.sort_order_id)
    _put_bool(out, f.has_sort_order_id)
    put_scalar[DType.int64](out, f.first_row_id)
    _put_bool(out, f.has_first_row_id)
    encode(f.referenced_data_file, out)
    _put_bool(out, f.has_referenced_data_file)
    put_scalar[DType.int64](out, f.content_offset)
    _put_bool(out, f.has_content_offset)
    put_scalar[DType.int64](out, f.content_size_in_bytes)
    _put_bool(out, f.has_content_size_in_bytes)


def decode_data_file(buf: Span[UInt8, _], mut pos: Int) raises -> DataFile:
    var content = _get_int(buf, pos)
    var file_path = decode[String](buf, pos)
    var file_format = decode[String](buf, pos)
    var np = _get_int(buf, pos)
    var partition = List[Datum]()
    for _ in range(np):
        partition.append(_get_datum(buf, pos))
    var record_count = get_scalar[DType.int64](buf, pos)
    var size = get_scalar[DType.int64](buf, pos)
    var column_sizes = _get_metrics(buf, pos)
    var metrics = _get_metrics(buf, pos)
    var key_metadata = _get_bytes(buf, pos)
    var has_key_metadata = _get_bool(buf, pos)
    var ns = _get_int(buf, pos)
    var split_offsets = List[Int64]()
    for _ in range(ns):
        split_offsets.append(get_scalar[DType.int64](buf, pos))
    var ne = _get_int(buf, pos)
    var equality_ids = List[Int]()
    for _ in range(ne):
        equality_ids.append(_get_int(buf, pos))
    var sort_order_id = _get_int(buf, pos)
    var has_sort_order_id = _get_bool(buf, pos)
    var first_row_id = get_scalar[DType.int64](buf, pos)
    var has_first_row_id = _get_bool(buf, pos)
    var referenced = decode[String](buf, pos)
    var has_referenced = _get_bool(buf, pos)
    var content_offset = get_scalar[DType.int64](buf, pos)
    var has_content_offset = _get_bool(buf, pos)
    var content_size = get_scalar[DType.int64](buf, pos)
    var has_content_size = _get_bool(buf, pos)
    return DataFile(
        content,
        file_path^,
        file_format^,
        partition^,
        record_count,
        size,
        column_sizes^,
        metrics^,
        key_metadata^,
        has_key_metadata,
        split_offsets^,
        equality_ids^,
        sort_order_id,
        has_sort_order_id,
        first_row_id,
        has_first_row_id,
        referenced^,
        has_referenced,
        content_offset,
        has_content_offset,
        content_size,
        has_content_size,
    )


struct DataFiles(Codec, Copyable, Movable):
    """An hour's data files, its row count, and where its time went (ms)."""

    var files: List[DataFile]
    var rows: Int
    var download_ms: Int
    var gunzip_ms: Int
    var parse_ms: Int
    var write_ms: Int
    var wait_ms: Int
    """Decoding waiting for the download."""
    var total_ms: Int

    def __init__(out self):
        self.files = List[DataFile]()
        self.rows = 0
        self.download_ms = 0
        self.gunzip_ms = 0
        self.parse_ms = 0
        self.write_ms = 0
        self.wait_ms = 0
        self.total_ms = 0

    def encode(self, mut out: List[UInt8]):
        _put_int(out, len(self.files))
        for f in self.files:
            encode_data_file(out, f)
        _put_int(out, self.rows)
        _put_int(out, self.download_ms)
        _put_int(out, self.gunzip_ms)
        _put_int(out, self.parse_ms)
        _put_int(out, self.write_ms)
        _put_int(out, self.wait_ms)
        _put_int(out, self.total_ms)

    @staticmethod
    def decode(buf: Span[UInt8, _], mut pos: Int) raises -> Self:
        var out = Self()
        var n = _get_int(buf, pos)
        if n < 0 or n > len(buf) - pos:
            raise Error("decode: bad DataFiles count ", n)
        for _ in range(n):
            out.files.append(decode_data_file(buf, pos))
        out.rows = _get_int(buf, pos)
        out.download_ms = _get_int(buf, pos)
        out.gunzip_ms = _get_int(buf, pos)
        out.parse_ms = _get_int(buf, pos)
        out.write_ms = _get_int(buf, pos)
        out.wait_ms = _get_int(buf, pos)
        out.total_ms = _get_int(buf, pos)
        return out^


trait BatchSink:
    """Where `parse_gz` puts each batch as it fills."""

    def put(mut self, var batch: RecordBatch) raises:
        ...


struct TableWriter(BatchSink, Movable):
    """Writes batches into a table's data files as they come, uncommitted,
    and keeps their entries."""

    var io: FileIO
    var location: String
    var schema: Schema
    var spec: PartitionSpec
    var sort_order_id: Int
    var options: WriteOptions
    var out: DataFiles
    var write_ns: Int

    def __init__(out self, table: Table) raises:
        self.io = table.io.copy()
        self.location = table.metadata.location
        self.schema = table.metadata.schema()
        self.spec = table.metadata.spec()
        self.sort_order_id = table.metadata.default_sort_order_id
        self.options = WriteOptions.from_properties(table.metadata.properties)
        self.out = DataFiles()
        self.write_ns = 0

    def put(mut self, var batch: RecordBatch) raises:
        var t0 = perf_counter_ns()
        self.out.rows += batch.num_rows
        var one = List[RecordBatch]()
        one.append(batch^)
        var files = write_data_files(
            self.io,
            self.location,
            one,
            self.schema,
            self.spec,
            self.sort_order_id,
            self.options,
        )
        for i in range(len(files)):
            self.out.files.append(files[i].copy())
        self.write_ns += Int(perf_counter_ns() - t0)

    def finish(deinit self) -> DataFiles:
        var out = self.out^
        out.write_ms = self.write_ns // 1_000_000
        return out^
