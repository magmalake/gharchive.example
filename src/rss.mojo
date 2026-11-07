"""The process's peak resident set (`getrusage`), for gharchive's memory
checks (`tests/test_hourmemory.mojo`, `tools/hour_memory.mojo`)."""

from std.ffi import c_int, external_call
from std.sys.info import CompilationTarget


def peak_rss_bytes() -> Int:
    """The largest the process's resident set has been, in bytes:
    `ru_maxrss`, which macOS gives in bytes and Linux in KB."""
    var buf = List[Int64](length=32, fill=0)
    _ = external_call["getrusage", c_int](c_int(0), buf.unsafe_ptr())
    var maxrss = Int(buf[4])  # after two `struct timeval`s
    comptime if CompilationTarget.is_macos():
        return maxrss
    else:
        return maxrss * 1024
