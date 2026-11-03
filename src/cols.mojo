"""Reading columns of a `RecordBatch` in place, by name."""

from parquet import RecordBatch
from parquet.arrow import ArrayData


def col(batch: RecordBatch, name: String) raises -> Int:
    """The index of the column called `name`."""
    for i in range(len(batch.roots)):
        if batch.column(i).name == name:
            return i
    raise Error("no column ", name)


@always_inline
def is_valid(a: ArrayData, row: Int) -> Bool:
    if a.null_count == 0 or len(a.validity) == 0:
        return True
    return Bool((a.validity[row >> 3] >> UInt8(row & 7)) & 1)


@always_inline
def str_range(a: ArrayData, row: Int) -> Tuple[Int, Int]:
    """Where row `row` of a string column sits in `a.values`."""
    if len(a.large_offsets) > 0:
        return (Int(a.large_offsets[row]), Int(a.large_offsets[row + 1]))
    return (Int(a.offsets[row]), Int(a.offsets[row + 1]))


def str_at(a: ArrayData, row: Int) -> String:
    """Row `row` of a string column, or "" for a null."""
    if not is_valid(a, row):
        return String()
    var r = str_range(a, row)
    return String(StringSlice(unsafe_from_utf8=Span(a.values)[r[0] : r[1]]))


def i64_at(a: ArrayData, row: Int) -> Int64:
    """Row `row` of a long or timestamp column, or 0 for a null."""
    if not is_valid(a, row):
        return 0
    var p = a.values.unsafe_ptr().unsafe_bitcast[Int64]()
    return p[unsafe_offset=row]
