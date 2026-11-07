"""Compressed input that may still be arriving, for deflate-mojo's
`GzipReader`: `have` says how much is there, `complete` whether that is
all of it, `view` the bytes, `wait` blocks for more, `release` says which
are done with. `Whole` is a buffer
that is all there already; `fetch.Download` is a body still downloading.
"""


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

    def release(self, upto: Int):
        """The reader is done with the first `upto` bytes: they may be
        freed, and `view` is not read below `upto` again."""
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

    def release(self, upto: Int):
        pass
