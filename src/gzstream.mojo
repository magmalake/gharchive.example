"""Streaming gunzip: a `.gz` decoded a window at a time.

deflate-mojo 0.1.3's `gunzip` and `gunzip_at` return the whole output, and
an hour of GH Archive is one gzip member of ~500 MB of JSON. `GzipInflater`
decodes into a window the caller drains: `run` inflates DEFLATE blocks until
the window holds `want` bytes (or the input runs short, or the stream ends),
the caller parses what's there, and `compact` drops what it has used,
keeping the 32 KiB that back-references can still reach.

The input can arrive while decoding goes on (`run` takes how much of it is
there so far, and whether that is all of it): a block that runs past the
bytes available is rolled back to its start and decoded again when more
have come. So that this is rare, a block is only started with `MARGIN`
bytes in hand, more than any block zlib writes.

The Huffman decoding is deflate-mojo's (`deflate/raw.mojo`, Apache-2.0,
same authors), with the state kept between calls and an eight-byte
match copy. It belongs in deflate-mojo; see GAPS.md.
"""

from deflate.gzip import _Crc32

comptime _FAST_BITS: Int = 10
comptime _FAST_SIZE: Int = 1 << _FAST_BITS
comptime _WINDOW: Int = 32768
comptime MARGIN: Int = 1 << 18
"""Input a block may need. zlib ends a block at 16 Ki symbols (memLevel 8)
or 32 Ki (9), at most ~200 KB of input; a block that is longer is still
decoded right, by rolling back and waiting for more."""
comptime _SLACK: Int = 258 + 16
"""Room kept past the write position: the longest match, and the eight-byte
copy's overshoot."""

trait GzInput:
    """Compressed bytes that may still be arriving."""

    def have(self) raises -> Int:
        """How many bytes are there so far."""
        ...

    def complete(self) raises -> Bool:
        """Whether that is all of them."""
        ...

    def view(self, n: Int) -> Span[UInt8, MutUntrackedOrigin]:
        """The first `n` (at most `have()`) bytes."""
        ...

    def wait(self, want: Int) raises -> Int:
        """Blocks until `want` bytes are there or all are; returns `have()`."""
        ...


struct Whole(GzInput, Movable):
    """A buffer that is all there already."""

    var addr: Int
    var n: Int

    def __init__(out self, data: Span[UInt8, _]):
        """`data` must outlive this."""
        self.addr = Int(data.unsafe_ptr())
        self.n = len(data)

    def have(self) raises -> Int:
        return self.n

    def complete(self) raises -> Bool:
        return True

    def view(self, n: Int) -> Span[UInt8, MutUntrackedOrigin]:
        return Span[UInt8, MutUntrackedOrigin](
            unsafe_ptr=Pointer[UInt8, MutUntrackedOrigin](
                unsafe_from_address=self.addr
            ),
            length=n,
        )

    def wait(self, want: Int) raises -> Int:
        return self.n


comptime HEADER = 0
comptime BLOCKS = 1
comptime TRAILER = 2
comptime DONE = 3

comptime GOT_OUTPUT = 0
comptime NEED_INPUT = 1
comptime FINISHED = 2

comptime _LEN_BASE_S: StaticString = "3,4,5,6,7,8,9,10,11,13,15,17,19,23,27,31,35,43,51,59,67,83,99,115,131,163,195,227,258"
comptime _LEN_EXTRA_S: StaticString = "0,0,0,0,0,0,0,0,1,1,1,1,2,2,2,2,3,3,3,3,4,4,4,4,5,5,5,5,0"
comptime _DIST_BASE_S: StaticString = "1,2,3,4,5,7,9,13,17,25,33,49,65,97,129,193,257,385,513,769,1025,1537,2049,3073,4097,6145,8193,12289,16385,24577"
comptime _DIST_EXTRA_S: StaticString = "0,0,0,0,1,1,2,2,3,3,4,4,5,5,6,6,7,7,8,8,9,9,10,10,11,11,12,12,13,13"
comptime _CLEN_ORDER_S: StaticString = "16,17,18,0,8,7,9,6,10,5,11,4,12,3,13,2,14,1,15"


def _ints(text: StringSlice) raises -> List[Int]:
    var out = List[Int]()
    for part in text.split(","):
        out.append(Int(String(part)))
    return out^


@fieldwise_init
struct _Tables(Copyable, Movable):
    var len_base: List[Int]
    var len_extra: List[Int]
    var dist_base: List[Int]
    var dist_extra: List[Int]
    var clen_order: List[Int]

    def __init__(out self) raises:
        self.len_base = _ints(_LEN_BASE_S)
        self.len_extra = _ints(_LEN_EXTRA_S)
        self.dist_base = _ints(_DIST_BASE_S)
        self.dist_extra = _ints(_DIST_EXTRA_S)
        self.clen_order = _ints(_CLEN_ORDER_S)


def _reverse_bits(value: Int, count: Int) -> Int:
    var v = 0
    for k in range(count):
        v |= ((value >> (count - 1 - k)) & 1) << k
    return v


struct _Huffman(Copyable, Defaultable, Movable):
    var counts: List[Int]
    var symbols: List[Int]
    var fast: List[Int32]
    """`(length << 16) | symbol` by the next `_FAST_BITS` bits, -1 where the
    code is longer."""
    var offs: List[Int]

    def __init__(out self):
        self.counts = List[Int](length=16, fill=0)
        self.symbols = List[Int]()
        self.fast = List[Int32](length=_FAST_SIZE, fill=-1)
        self.offs = List[Int](length=16, fill=0)

    def __init__(out self, lengths: List[Int]) raises:
        self = Self()
        self.build(lengths, 0, len(lengths))

    def build(mut self, lengths: List[Int], start: Int, count: Int) raises:
        """The code for `lengths[start:start + count]`, in place: a dynamic
        block rebuilds its tables without allocating."""
        var c = self.counts.unsafe_ptr()
        for n in range(16):
            c[unsafe_offset=n] = 0
        for i in range(count):
            var l = lengths[start + i]
            if l < 0 or l > 15:
                raise Error("gunzip: bad code length")
            c[unsafe_offset=l] += 1
        var f = self.fast.unsafe_ptr()
        for k in range(_FAST_SIZE):
            f[unsafe_offset=k] = -1
        if c[unsafe_offset=0] == count:
            self.symbols.resize(0, 0)
            return
        var left = 1
        for n in range(1, 16):
            left <<= 1
            left -= c[unsafe_offset=n]
            if left < 0:
                raise Error("gunzip: over-subscribed Huffman code")
        var o = self.offs.unsafe_ptr()
        o[unsafe_offset=1] = 0
        for n in range(1, 15):
            o[unsafe_offset=n + 1] = o[unsafe_offset=n] + c[unsafe_offset=n]
        self.symbols.resize(count, 0)
        var sy = self.symbols.unsafe_ptr()
        for i in range(count):
            var l = lengths[start + i]
            if l:
                sy[unsafe_offset=o[unsafe_offset=l]] = i
                o[unsafe_offset=l] += 1
        var code = 0
        var idx = 0
        for n in range(1, 16):
            for _k in range(c[unsafe_offset=n]):
                var sym = sy[unsafe_offset=idx]
                idx += 1
                if n <= _FAST_BITS:
                    var entry = Int32((n << 16) | sym)
                    var step = 1 << n
                    var at = _reverse_bits(code, n)
                    while at < _FAST_SIZE:
                        f[unsafe_offset=at] = entry
                        at += step
                code += 1
            code <<= 1


struct _Bits[origin: ImmOrigin](Copyable, Movable):
    """deflate-mojo's 64-bit bit reader, over the input that has arrived."""

    var data: Span[UInt8, Self.origin]
    var pos: Int
    var bitbuf: UInt64
    var bitcnt: Int

    def __init__(
        out self, data: Span[UInt8, Self.origin], pos: Int, bitbuf: UInt64,
        bitcnt: Int,
    ):
        self.data = data
        self.pos = pos
        self.bitbuf = bitbuf
        self.bitcnt = bitcnt

    @always_inline
    def refill(mut self):
        if self.pos + 8 <= len(self.data):
            var chunk = (
                self.data.unsafe_ptr()
                .unsafe_offset(self.pos)
                .unsafe_bitcast[UInt64]()
                .unsafe_load[alignment=1]()
            )
            self.bitbuf |= chunk << UInt64(self.bitcnt)
            self.pos += (63 - self.bitcnt) >> 3
            self.bitcnt |= 56
            return
        while self.bitcnt <= 56 and self.pos < len(self.data):
            self.bitbuf |= UInt64(self.data[self.pos]) << UInt64(self.bitcnt)
            self.pos += 1
            self.bitcnt += 8

    @always_inline
    def bits(mut self, need: Int) raises -> Int:
        if self.bitcnt < need:
            self.refill()
            if self.bitcnt < need:
                raise Error("gunzip: truncated DEFLATE stream")
        var v = Int(self.bitbuf & ((UInt64(1) << UInt64(need)) - 1))
        self.bitbuf >>= UInt64(need)
        self.bitcnt -= need
        return v

    def align(mut self):
        """To the next byte boundary, giving back whole bytes read ahead."""
        self.pos -= self.bitcnt // 8
        self.bitbuf = 0
        self.bitcnt = 0

    @always_inline
    def decode(mut self, h: _Huffman) raises -> Int:
        if self.bitcnt < 15:
            self.refill()
        var e = Int(
            h.fast.unsafe_ptr()[
                unsafe_offset=Int(self.bitbuf & UInt64(_FAST_SIZE - 1))
            ]
        )
        if e >= 0:
            var n = e >> 16
            if n > self.bitcnt:
                raise Error("gunzip: truncated DEFLATE stream")
            self.bitbuf >>= UInt64(n)
            self.bitcnt -= n
            return e & 0xFFFF
        return self.decode_long(h)

    def decode_long(mut self, h: _Huffman) raises -> Int:
        var code = 0
        var first = 0
        var index = 0
        for length in range(1, 16):
            code |= self.bits(1)
            var count = h.counts[length]
            if code - first < count:
                return h.symbols[index + (code - first)]
            index += count
            first = (first + count) << 1
            code <<= 1
        raise Error("gunzip: invalid Huffman code")


def _fixed_literal_lengths() -> List[Int]:
    var l = List[Int](length=288, fill=8)
    for i in range(144, 256):
        l[i] = 9
    for i in range(256, 280):
        l[i] = 7
    return l^


def _u32le(data: Span[UInt8, _], at: Int) -> UInt32:
    return (
        UInt32(data[at])
        | (UInt32(data[at + 1]) << 8)
        | (UInt32(data[at + 2]) << 16)
        | (UInt32(data[at + 3]) << 24)
    )


struct GzipInflater(Movable):
    """A gzip stream (every member) decoded into a window, `buf[0:n]`."""

    var buf: List[UInt8]
    """Valid to its full length, so writes need no capacity check."""
    var n: Int
    var base: Int
    """Where the current member's output began; may be below 0 once the
    window has moved past it."""
    var crc_at: Int
    """`buf[crc_at:n]` isn't in `crc` yet."""
    var crc: UInt32
    var member_out: Int
    var member: Int
    var state: Int
    var pos: Int
    var bitbuf: UInt64
    var bitcnt: Int
    var fixed_lit: _Huffman
    var fixed_dist: _Huffman
    var dyn_lit: _Huffman
    var dyn_dist: _Huffman
    var dyn_clen: _Huffman
    var lengths: List[Int]
    var crc32: _Crc32
    var t: _Tables
    var total_out: Int
    var margin: Int
    """Input to have in hand before starting a block (`MARGIN`); 0
    makes every block that outruns the input roll back, for testing."""

    def __init__(out self, capacity: Int = 1 << 24) raises:
        self.buf = List[UInt8](length=capacity + _SLACK, fill=0)
        self.n = 0
        self.base = 0
        self.crc_at = 0
        self.crc = 0
        self.member_out = 0
        self.member = 0
        self.state = HEADER
        self.pos = 0
        self.bitbuf = 0
        self.bitcnt = 0
        self.fixed_lit = _Huffman(_fixed_literal_lengths())
        self.fixed_dist = _Huffman(List[Int](length=30, fill=5))
        self.dyn_lit = _Huffman()
        self.dyn_dist = _Huffman()
        self.dyn_clen = _Huffman()
        self.lengths = List[Int](length=320, fill=0)
        self.crc32 = _Crc32()
        self.t = _Tables()
        self.margin = MARGIN
        self.total_out = 0

    def compact(mut self, keep_from: Int) -> Int:
        """Drop `buf[0:keep_from]`, as far as back-references allow, and
        return how many bytes moved out (subtract it from caller offsets)."""
        var drop = min(keep_from, self.n - _WINDOW)
        if drop <= 0:
            return 0
        var p = self.buf.unsafe_ptr()
        var keep = self.n - drop
        # Overlapping moves to the front: memmove semantics, forward copy.
        for k in range(keep):
            p[unsafe_offset=k] = p[unsafe_offset=drop + k]
        self.n = keep
        self.base -= drop
        self.crc_at -= drop
        return drop

    def run(
        mut self, data: Span[UInt8, _], complete: Bool, want: Int
    ) raises -> Int:
        """Inflate from `data` (the input so far; all of it if `complete`)
        until `n >= want`, and say why it stopped: `GOT_OUTPUT`,
        `NEED_INPUT` or `FINISHED`."""
        var result = GOT_OUTPUT
        while self.n < want:
            if self.state == HEADER:
                var body = self._header(data, complete)
                if body < 0:
                    result = NEED_INPUT
                    break
                self.pos = body
                self.bitbuf = 0
                self.bitcnt = 0
                self.base = self.n
                self.member_out = 0
                self.crc = 0
                self.state = BLOCKS
            elif self.state == BLOCKS:
                if not complete and len(data) - self.pos < self.margin:
                    result = NEED_INPUT
                    break
                var s_pos = self.pos
                var s_buf = self.bitbuf
                var s_cnt = self.bitcnt
                var s_n = self.n
                var final: Bool
                try:
                    final = self._block(data)
                except e:
                    if complete:
                        raise Error(
                            "gunzip: member ", self.member, ": ", String(e)
                        )
                    self.pos = s_pos
                    self.bitbuf = s_buf
                    self.bitcnt = s_cnt
                    self.n = s_n
                    result = NEED_INPUT
                    break
                if final:
                    self.state = TRAILER
            elif self.state == TRAILER:
                if self.pos + 8 > len(data):
                    if complete:
                        raise Error("gunzip: truncated trailer")
                    result = NEED_INPUT
                    break
                self._sum()
                if self.crc != _u32le(data, self.pos):
                    raise Error("gunzip: member ", self.member, ": CRC-32 mismatch")
                if UInt32(self.member_out & 0xFFFFFFFF) != _u32le(
                    data, self.pos + 4
                ):
                    raise Error("gunzip: member ", self.member, ": ISIZE mismatch")
                self.pos += 8
                self.member += 1
                # Another member, or zero padding, or the end.
                var k = self.pos
                while k < len(data) and data[k] == 0:
                    k += 1
                if k < len(data):
                    self.pos = k
                    self.state = HEADER
                elif complete:
                    self.state = DONE
                else:
                    result = NEED_INPUT
                    break
            else:
                result = FINISHED
                break
        self._sum()
        if self.state == DONE:
            return FINISHED
        return result

    def _sum(mut self):
        if self.n > self.crc_at:
            var span = Span(self.buf)[self.crc_at : self.n]
            self.crc = self.crc32.update(self.crc, span)
            self.member_out += self.n - self.crc_at
            self.total_out += self.n - self.crc_at
            self.crc_at = self.n

    def _header(self, data: Span[UInt8, _], complete: Bool) raises -> Int:
        """Where the member at `pos` starts its DEFLATE body, or -1 if its
        header isn't all there yet."""
        var start = self.pos
        var n = len(data)
        if start + 10 > n:
            if complete:
                raise Error("gunzip: truncated header")
            return -1
        if data[start] != 0x1F or data[start + 1] != 0x8B:
            raise Error("gunzip: not a gzip stream (bad magic)")
        if data[start + 2] != 8:
            raise Error("gunzip: unknown compression method")
        var flg = Int(data[start + 3])
        if flg & 0xE0:
            raise Error("gunzip: reserved flag bits set")
        var i = start + 10
        if flg & 4:
            if i + 2 > n:
                return -1 if not complete else self._trunc()
            i += 2 + (Int(data[i]) | (Int(data[i + 1]) << 8))
        for f in [8, 16]:
            if flg & f:
                while i < n and data[i] != 0:
                    i += 1
                i += 1
        if flg & 2:
            i += 2
        if i > n:
            return -1 if not complete else self._trunc()
        return i

    def _trunc(self) raises -> Int:
        raise Error("gunzip: truncated header")

    @always_inline
    def _room(mut self):
        if self.n + _SLACK > len(self.buf):
            self.buf.resize(len(self.buf) * 2, 0)

    def _block(mut self, data: Span[UInt8, _]) raises -> Bool:
        """One DEFLATE block onto the window; whether it was the last."""
        var br = _Bits(data, self.pos, self.bitbuf, self.bitcnt)
        var final = br.bits(1) == 1
        var btype = br.bits(2)
        if btype == 0:
            br.align()
            if br.pos + 4 > len(br.data):
                raise Error("truncated stored block header")
            var length = Int(br.data[br.pos]) | (Int(br.data[br.pos + 1]) << 8)
            br.pos += 4
            if br.pos + length > len(br.data):
                raise Error("truncated stored block")
            while self.n + length + _SLACK > len(self.buf):
                self.buf.resize(len(self.buf) * 2, 0)
            var p = self.buf.unsafe_ptr()
            for k in range(length):
                p[unsafe_offset=self.n + k] = br.data[br.pos + k]
            self.n += length
            br.pos += length
        elif btype == 1:
            self.n = _codes(
                br, self.fixed_lit, self.fixed_dist, self.t, self.buf, self.n, self.base
            )
        elif btype == 2:
            var nlen = br.bits(5) + 257
            var ndist = br.bits(5) + 1
            var ncode = br.bits(4) + 4
            var lengths = self.lengths.unsafe_ptr()
            for k in range(19):
                lengths[unsafe_offset=k] = 0
            for i in range(ncode):
                lengths[unsafe_offset=self.t.clen_order[i]] = br.bits(3)
            self.dyn_clen.build(self.lengths, 0, 19)
            var total = nlen + ndist
            for k in range(total):
                lengths[unsafe_offset=k] = 0
            var i = 0
            while i < total:
                var sym = br.decode(self.dyn_clen)
                if sym < 16:
                    lengths[unsafe_offset=i] = sym
                    i += 1
                elif sym == 16:
                    if i == 0:
                        raise Error("repeat with no previous length")
                    var prev = lengths[unsafe_offset=i - 1]
                    var rep = 3 + br.bits(2)
                    if i + rep > total:
                        raise Error("code-length overflow")
                    for _k in range(rep):
                        lengths[unsafe_offset=i] = prev
                        i += 1
                elif sym == 17:
                    i += 3 + br.bits(3)
                else:
                    i += 11 + br.bits(7)
            if i > total:
                raise Error("code-length overflow")
            self.dyn_lit.build(self.lengths, 0, nlen)
            self.dyn_dist.build(self.lengths, nlen, ndist)
            self.n = _codes(
                br, self.dyn_lit, self.dyn_dist, self.t, self.buf, self.n,
                self.base,
            )
        else:
            raise Error("reserved block type 3")
        if final:
            br.align()
        self.pos = br.pos
        self.bitbuf = br.bitbuf
        self.bitcnt = br.bitcnt
        return final


def _codes(
    mut br: _Bits,
    lit: _Huffman,
    dist: _Huffman,
    t: _Tables,
    mut buf: List[UInt8],
    start: Int,
    base: Int,
) raises -> Int:
    """A block's codes onto `buf` from `start`; returns the new end.

    While eight bytes of input remain, one refill per symbol leaves at
    least 56 bits, enough for a length, its extra bits, a distance and its
    extra bits (48), so the bit buffer is used unchecked; the last bytes
    go through `_codes_checked`."""
    var n = start
    var limit = len(buf) - _SLACK
    var p = buf.unsafe_ptr()
    var ip = br.data.unsafe_ptr()
    var in_n = len(br.data)
    var bitbuf = br.bitbuf
    var bitcnt = br.bitcnt
    var pos = br.pos
    var litf = lit.fast.unsafe_ptr()
    var distf = dist.fast.unsafe_ptr()
    var lbase = t.len_base.unsafe_ptr()
    var lextra = t.len_extra.unsafe_ptr()
    var dbase = t.dist_base.unsafe_ptr()
    var dextra = t.dist_extra.unsafe_ptr()
    comptime MASK = UInt64(_FAST_SIZE - 1)
    while True:
        if pos + 8 > in_n:
            br.bitbuf = bitbuf
            br.bitcnt = bitcnt
            br.pos = pos
            return _codes_checked(br, lit, dist, t, buf, n, base)
        if n > limit:
            buf.resize(len(buf) * 2, 0)
            limit = len(buf) - _SLACK
            p = buf.unsafe_ptr()
        var chunk = (
            ip.unsafe_offset(pos).unsafe_bitcast[UInt64]().unsafe_load[
                alignment=1
            ]()
        )
        bitbuf |= chunk << UInt64(bitcnt)
        pos += (63 - bitcnt) >> 3
        bitcnt |= 56
        var e = Int(litf[unsafe_offset=Int(bitbuf & MASK)])
        var sym: Int
        if e >= 0:
            var used = e >> 16
            bitbuf >>= UInt64(used)
            bitcnt -= used
            sym = e & 0xFFFF
        else:
            br.bitbuf = bitbuf
            br.bitcnt = bitcnt
            br.pos = pos
            sym = br.decode_long(lit)
            bitbuf = br.bitbuf
            bitcnt = br.bitcnt
            pos = br.pos
        if sym < 256:
            p[unsafe_offset=n] = UInt8(sym)
            n += 1
            # A second literal from the same refill, if its code is short.
            if bitcnt >= _FAST_BITS:
                var e2 = Int(litf[unsafe_offset=Int(bitbuf & MASK)])
                if e2 >= 0 and (e2 & 0xFFFF) < 256:
                    var used2 = e2 >> 16
                    bitbuf >>= UInt64(used2)
                    bitcnt -= used2
                    p[unsafe_offset=n] = UInt8(e2 & 0xFFFF)
                    n += 1
            continue
        if sym == 256:
            break
        var lc = sym - 257
        if lc >= 29:
            raise Error("invalid length symbol")
        var le = lextra[unsafe_offset=lc]
        var length = lbase[unsafe_offset=lc] + Int(
            bitbuf & ((UInt64(1) << UInt64(le)) - 1)
        )
        bitbuf >>= UInt64(le)
        bitcnt -= le
        var ed = Int(distf[unsafe_offset=Int(bitbuf & MASK)])
        var dc: Int
        if ed >= 0:
            var used = ed >> 16
            bitbuf >>= UInt64(used)
            bitcnt -= used
            dc = ed & 0xFFFF
        else:
            br.bitbuf = bitbuf
            br.bitcnt = bitcnt
            br.pos = pos
            dc = br.decode_long(dist)
            bitbuf = br.bitbuf
            bitcnt = br.bitcnt
            pos = br.pos
        if dc >= 30:
            raise Error("invalid distance symbol")
        var de = dextra[unsafe_offset=dc]
        if bitcnt < de:
            raise Error("truncated DEFLATE stream")
        var d = dbase[unsafe_offset=dc] + Int(
            bitbuf & ((UInt64(1) << UInt64(de)) - 1)
        )
        bitbuf >>= UInt64(de)
        bitcnt -= de
        if d > n - base or d > n:
            raise Error("distance runs before the output start")
        var src = n - d
        if d >= 16:
            var k = 0
            while k < length:
                p.unsafe_offset(n + k).unsafe_store[width=16](
                    p.unsafe_offset(src + k).unsafe_load[width=16]()
                )
                k += 16
        elif d >= 8:
            var k = 0
            while k < length:
                var v = (
                    p.unsafe_offset(src + k)
                    .unsafe_bitcast[UInt64]()
                    .unsafe_load[alignment=1]()
                )
                p.unsafe_offset(n + k).unsafe_bitcast[UInt64]().unsafe_store[
                    alignment=1
                ](v)
                k += 8
        else:
            for k in range(length):
                p[unsafe_offset=n + k] = p[unsafe_offset=src + k]
        n += length
    br.bitbuf = bitbuf
    br.bitcnt = bitcnt
    br.pos = pos
    return n


def _codes_checked(
    mut br: _Bits,
    lit: _Huffman,
    dist: _Huffman,
    t: _Tables,
    mut buf: List[UInt8],
    start: Int,
    base: Int,
) raises -> Int:
    """`_codes` near the end of the input: every read checked."""
    var n = start
    var limit = len(buf) - _SLACK
    var p = buf.unsafe_ptr()
    while True:
        if n > limit:
            buf.resize(len(buf) * 2, 0)
            limit = len(buf) - _SLACK
            p = buf.unsafe_ptr()
        var sym = br.decode(lit)
        if sym < 256:
            p[unsafe_offset=n] = UInt8(sym)
            n += 1
            continue
        if sym == 256:
            break
        var lc = sym - 257
        if lc >= 29:
            raise Error("invalid length symbol")
        var length = t.len_base[lc] + br.bits(t.len_extra[lc])
        var dc = br.decode(dist)
        if dc >= 30:
            raise Error("invalid distance symbol")
        var d = t.dist_base[dc] + br.bits(t.dist_extra[dc])
        if d > n - base or d > n:
            raise Error("distance runs before the output start")
        var src = n - d
        if d >= 8:
            var k = 0
            while k < length:
                var v = (
                    p.unsafe_offset(src + k)
                    .unsafe_bitcast[UInt64]()
                    .unsafe_load[alignment=1]()
                )
                p.unsafe_offset(n + k).unsafe_bitcast[UInt64]().unsafe_store[
                    alignment=1
                ](v)
                k += 8
        else:
            for k in range(length):
                p[unsafe_offset=n + k] = p[unsafe_offset=src + k]
        n += length
    return n
