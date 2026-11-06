"""Putting a batch's rows in order, for a smaller file.

Parquet compresses a page, so rows that resemble each other have to sit in the
same page. `gharchive.events` rows sorted by (repository, type) put a
repository's own events, which repeat its `*_url` strings, next to each other:
on three real 50,000-row files at zstd 9 that is 7% smaller than (type,
repository) and 18% smaller than the order the events arrive in
(magmalake/mojo-census#28). The rows are the same rows; only their order in
the file changes, and nothing reads that order.
"""

from std.memory import unsafe_memcpy

from parquet import RecordBatch
from parquet.arrow import ArrayData

from cols import col


comptime _Bytes = UnsafePointer[UInt8, ImmUntrackedOrigin]
comptime _Offsets = UnsafePointer[Int32, ImmUntrackedOrigin]


@always_inline
def _compare(
    av: _Bytes, ao: _Offsets, i: Int, bv: _Bytes, bo: _Offsets, j: Int
) -> Int:
    """Row `i` of the string column (`av`, `ao`) against row `j` of the
    column (`bv`, `bo`), bytewise: negative, zero or positive."""
    var ilo = Int(ao[unsafe_offset=i])
    var ihi = Int(ao[unsafe_offset=i + 1])
    var jlo = Int(bo[unsafe_offset=j])
    var jhi = Int(bo[unsafe_offset=j + 1])
    var n = min(ihi - ilo, jhi - jlo)
    for k in range(n):
        var x = av[unsafe_offset=ilo + k]
        var y = bv[unsafe_offset=jlo + k]
        if x != y:
            return -1 if x < y else 1
    return (ihi - ilo) - (jhi - jlo)


def order_by_text(
    batch: RecordBatch, first: String, second: String
) raises -> List[Int32]:
    """The row numbers of `batch` in the order of the string columns `first`
    and then `second`, bytewise. Rows with equal keys stay in their original
    order, so the same batch always gives the same file."""
    var n = batch.num_rows
    var order = List[Int32](capacity=n)
    for i in range(n):
        order.append(Int32(i))
    ref a = batch.column(col(batch, first))
    ref b = batch.column(col(batch, second))
    if len(a.large_offsets) > 0 or len(b.large_offsets) > 0:
        raise Error("sortrows: ", first, " and ", second, " must be 32-bit strings")
    var av = _Bytes(unsafe_from_address=Int(a.values.unsafe_ptr()))
    var ao = _Offsets(unsafe_from_address=Int(a.offsets.unsafe_ptr()))
    var bv = _Bytes(unsafe_from_address=Int(b.values.unsafe_ptr()))
    var bo = _Offsets(unsafe_from_address=Int(b.offsets.unsafe_ptr()))

    def before(x: Int32, y: Int32) {imm av, imm ao, imm bv, imm bo} -> Bool:
        var i = Int(x)
        var j = Int(y)
        var c = _compare(av, ao, i, av, ao, j)
        if c != 0:
            return c < 0
        c = _compare(bv, bo, i, bv, bo, j)
        if c != 0:
            return c < 0
        return x < y

    sort[stable=True](Span(order), before)
    return order^


def _taken(a: ArrayData, order: Span[Int32, _]) raises -> ArrayData:
    """Column `a` with row `k` being its row `order[k]`."""
    var n = len(order)
    var out = ArrayData(a.type.copy(), a.name.copy())
    out.nullable = a.nullable
    out.field_id = a.field_id
    out.length = n
    if n == 0:
        if len(a.offsets) > 0:
            out.offsets.append(0)
        return out^
    if len(a.large_offsets) > 0 or len(a.children) > 0:
        raise Error("sortrows: column ", a.name, " is not a flat column")
    var has_validity = a.null_count > 0 and len(a.validity) > 0
    out.validity.resize((n + 7) >> 3, 0)
    var nulls = 0
    for k in range(n):
        var src = Int(order[k])
        if has_validity and not a.is_valid(src):
            nulls += 1
        else:
            out.validity[k >> 3] |= UInt8(1) << UInt8(k & 7)
    out.null_count = nulls
    if len(a.offsets) > 0:
        # Strings: the same bytes, rows moved.
        out.offsets.resize(n + 1, 0)
        out.values.resize(unsafe_uninit_length=len(a.values))
        var at = 0
        var src_values = a.values.unsafe_ptr()
        var dst_values = out.values.unsafe_ptr()
        for k in range(n):
            var src = Int(order[k])
            var lo = Int(a.offsets[src])
            var len_ = Int(a.offsets[src + 1]) - lo
            if len_ > 0:
                unsafe_memcpy(
                    dest=dst_values.unsafe_offset(at),
                    src=src_values.unsafe_offset(lo),
                    count=len_,
                )
            at += len_
            out.offsets[k + 1] = Int32(at)
        out.values.resize(unsafe_uninit_length=at)
    else:
        if len(a.values) % a.length != 0 or a.length != n:
            raise Error("sortrows: column ", a.name, " is not fixed-width bytes")
        var width = len(a.values) // a.length
        out.values.resize(unsafe_uninit_length=len(a.values))
        var src_values = a.values.unsafe_ptr()
        var dst_values = out.values.unsafe_ptr()
        for k in range(n):
            unsafe_memcpy(
                dest=dst_values.unsafe_offset(k * width),
                src=src_values.unsafe_offset(Int(order[k]) * width),
                count=width,
            )
    return out^


def take_rows(batch: RecordBatch, order: List[Int32]) raises -> RecordBatch:
    """A new batch of the flat columns of `batch` whose row `k` is row
    `order[k]` of `batch`. Fixed-width columns must be whole bytes wide."""
    var out = RecordBatch()
    out.num_rows = len(order)
    for c in range(len(batch.roots)):
        out.roots.append(out.arena.add(_taken(batch.column(c), Span(order))))
    return out^


def sorted_by_text(
    batch: RecordBatch, first: String, second: String
) raises -> RecordBatch:
    """`batch` with its rows ordered by the string columns `first`, `second`."""
    return take_rows(batch, order_by_text(batch, first, second))
