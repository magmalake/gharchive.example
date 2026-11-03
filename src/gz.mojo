"""gzip (RFC 1952) on top of deflate-mojo's raw `inflate_at`.

deflate-mojo deliberately has no framing, so the member header and trailer
are read here. Concatenated members are decoded one after another.
"""

from deflate import inflate_at


def gunzip(data: Span[UInt8, _]) raises -> List[UInt8]:
    var out = List[UInt8]()
    var pos = 0
    var n = len(data)
    while pos + 18 <= n:
        if data[pos] != 0x1F or data[pos + 1] != 0x8B:
            if len(out) > 0:
                break  # trailing garbage after a complete member
            raise Error("gunzip: not a gzip stream")
        if data[pos + 2] != 8:
            raise Error("gunzip: unknown compression method")
        var flg = Int(data[pos + 3])
        var i = pos + 10
        if flg & 4:  # FEXTRA
            var xlen = Int(data[i]) | (Int(data[i + 1]) << 8)
            i += 2 + xlen
        if flg & 8:  # FNAME
            while i < n and data[i] != 0:
                i += 1
            i += 1
        if flg & 16:  # FCOMMENT
            while i < n and data[i] != 0:
                i += 1
            i += 1
        if flg & 2:  # FHCRC
            i += 2
        var used = 0
        var part = inflate_at(data[i:], used)
        if len(out) == 0:
            out = part^
        else:
            out.extend(Span(part))
        pos = i + used + 8  # CRC32 and ISIZE
    return out^
