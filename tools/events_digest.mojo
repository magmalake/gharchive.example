"""A digest of each Parquet file of `gharchive.events`: its rows, row groups,
size and a hash of every row in order, one line a file, sorted by hash.

    mojo build -I src tools/events_digest.mojo -o build/events_digest
    ./build/events_digest $(find build/warehouse/gharchive/events/data -name '*.parquet')

Two runs of the same hours wrote the same rows in the same order, file for
file, when the `rows` and `hash` columns of their digests are the same (the
file names are random; row groups and sizes may differ).
"""

from std.sys import argv

from iceberg.io import FileIO
from parquet import ParquetReader
from parquet_full import AllCodecs

from cols import i64_at, is_valid, str_range


@always_inline
def _mix(mut h: UInt64, b: UInt8):
    h = (h ^ UInt64(b)) * 0x100000001B3


def _mix_i64(mut h: UInt64, v: Int64):
    for k in range(8):
        _mix(h, UInt8((v >> Int64(8 * k)) & 0xFF))


def main() raises:
    var args = argv()
    var io = FileIO.local()
    var lines = List[String]()
    for i in range(1, len(args)):
        var path = String(args[i])
        var data = io.read_all(path)
        var size = len(data)
        var reader = ParquetReader[AllCodecs](data^)
        var groups = reader.num_row_groups()
        var t = reader.read_table()
        var h: UInt64 = 0xCBF29CE484222325
        var rows = 0
        for ref b in t.batches:
            for r in range(b.num_rows):
                for c in range(b.num_columns()):
                    ref a = b.column(c)
                    if not is_valid(a, r):
                        _mix(h, 0xFF)
                        _mix(h, 0x00)
                    elif len(a.offsets) > 0 or len(a.large_offsets) > 0:
                        var s = str_range(a, r)
                        _mix_i64(h, Int64(s[1] - s[0]))
                        for k in range(s[0], s[1]):
                            _mix(h, a.values[k])
                    else:
                        _mix_i64(h, i64_at(a, r))
                rows += 1
        lines.append(
            String(
                "hash ",
                hex(h),
                " rows ",
                rows,
                " row_groups ",
                groups,
                " bytes ",
                size,
            )
        )
    sort(lines)
    for ref l in lines:
        print(l)
