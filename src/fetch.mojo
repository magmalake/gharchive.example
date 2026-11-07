"""HTTP: GH Archive files, and GitHub's REST API and raw files.

Uses flare's blocking `HttpClient`. GitHub calls send `GITHUB_TOKEN` when it
is set (orca gives runs the secret registered with `--secret`); without it
the REST API allows 60 requests an hour, which is enough for a local run.
"""

from std.ffi import external_call
from std.memory import unsafe_memcpy
from std.memory.alloc import unsafe_alloc
from std.os import getenv
from std.os.path import exists
from std.sys.info import CompilationTarget
from std.time import perf_counter_ns, sleep

from flare.http import HttpClient, HttpStreamResponse, Request, Response
from flare.tls import TlsConfig
from gzstream import GzInput
from threads import AtomicCounter, OpaquePtr, ThreadHandle, opaque_ptr

comptime USER_AGENT = "mojo-census (magmalake)"


def _ca_bundle() -> String:
    """A CA bundle path for flare to load: `SSL_CERT_FILE`, else the first
    of the conda and Debian bundles that exists, else "" (OpenSSL's
    default). flare 0.13.2 passes an empty path to OpenSSL without its
    terminating NUL on Linux, so a concrete path avoids that."""
    var env = getenv("SSL_CERT_FILE")
    if env:
        return env
    var prefix = getenv("CONDA_PREFIX")
    var conda = String(prefix, "/ssl/cacert.pem")
    if prefix and exists(conda):
        return conda
    var debian = String("/etc/ssl/certs/ca-certificates.crt")
    if exists(debian):
        return debian
    return String()


def _client(timeout_ms: Int = 120_000) raises -> HttpClient:
    """A new blocking client for one call: each call makes its own, so none
    is shared between threads."""
    var ca = _ca_bundle()
    if ca:
        return HttpClient(TlsConfig(ca_bundle=ca), timeout_ms=timeout_ms)
    return HttpClient(timeout_ms=timeout_ms)


def get_bytes(url: String, timeout_ms: Int = 600_000) raises -> List[UInt8]:
    """The body of a GET, raising on any status but 200."""
    var c = _client(timeout_ms)
    var req = Request(method="GET", url=url)
    req.headers.set("User-Agent", USER_AGENT)
    var resp = c.send(req)
    if resp.status != 200:
        raise Error("GET ", url, ": HTTP ", resp.status)
    var body = List[UInt8]()
    swap(body, resp.body)
    return body^


comptime _AHEAD = 1 << 25
"""How far the reader thread may run ahead of what the decoder released:
32 MB of compressed input, a few seconds of decoding. Beyond it the thread
waits, and TCP holds the rest of the body back."""

comptime _RELEASE_STEP = 1 << 20
"""`Download.release` gives input back a megabyte at a time: a multiple of
any page size, so every boundary it unmaps at is page-aligned."""


def _map(size: Int) raises -> Int:
    """`size` bytes of fresh anonymous memory (`mmap`), by address."""
    comptime PROT_READ_WRITE: Int = 3
    comptime MAP_PRIVATE: Int = 2
    comptime MAP_ANON: Int = 0x1000 if CompilationTarget.is_macos() else 0x20
    # The signature memory-region declares, which the same program links.
    var p = external_call["mmap", Int](
        0, size, PROT_READ_WRITE, MAP_PRIVATE | MAP_ANON, -1, Int64(0)
    )
    if p == -1 or p == 0:
        raise Error("download: can't map ", size, " bytes")
    return p


def _unmap(addr: Int, size: Int):
    if size > 0:
        _ = external_call["munmap", Int32](addr, size)


struct _Shared(Movable):
    """What a download's reader thread and its consumer share. The reader
    writes the body, then publishes progress through `have` and `state` with
    atomic stores; the consumer reads only the first `have` bytes. With a
    `Content-Length` the body goes into `region`, mapped to its full size up
    front so it doesn't move while the reader runs, and the consumer unmaps
    what it is done with (`released`), so the body is never all resident at
    once (#37); without one, into `buf`."""

    var client: HttpClient
    var resp: HttpStreamResponse
    var size: Int
    """`Content-Length`, or -1."""
    var buf: List[UInt8]
    """The body when there was no `Content-Length`."""
    var region: Int
    """Otherwise the body is here: `size` bytes mapped for it (`_map`), of
    which the consumer has given the first `released` back (`release`;
    release-stored, as the reader thread reads it)."""
    var released: Int64
    var have: Int64
    """Bytes of the body that have arrived (release-stored by the reader)."""
    var state: Int64
    """0 while reading, 1 done, 2 failed (`err`), 3 asked to stop."""
    var err: String
    var ms: Int64

    def __init__(
        out self, var client: HttpClient, var resp: HttpStreamResponse, size: Int
    ):
        self.client = client^
        self.resp = resp^
        self.size = size
        self.buf = List[UInt8]()
        self.region = 0
        self.released = 0
        self.have = 0
        self.state = 0
        self.err = String()
        self.ms = 0


def _cell(ref v: Int64) -> AtomicCounter:
    """An atomic view of one of `_Shared`'s integers, for the cross-thread
    stores and loads."""
    return AtomicCounter.at(Int(Pointer(to=v)))


def _pull(arg: OpaquePtr) -> OpaquePtr:
    """The reader thread: the body into `region`, publishing `have` as it
    goes and staying within `_AHEAD` of what the consumer released. With no
    `Content-Length` it reads it all into `buf`, then publishes."""
    var sh = Pointer[_Shared, MutUntrackedOrigin](unsafe_from_address=Int(arg))
    var t0 = perf_counter_ns()
    try:
        # No `Content-Length` (chunked): the buffer can't be sized up front,
        # so the body is gathered and published all at once.
        if sh[].size < 0:
            var all = List[UInt8]()
            while True:
                var chunk = sh[].resp.read_chunk(1 << 20)
                if len(chunk) == 0:
                    break
                all.extend(Span(chunk))
            sh[].buf = all^
            sh[].size = len(sh[].buf)
            _cell(sh[].have).store(Int64(sh[].size))
        else:
            var at = 0
            var dst = UnsafePointer[UInt8, MutAnyOrigin](
                unsafe_from_address=sh[].region
            )
            while True:
                # Asked to stop: the `Download` was dropped before the body
                # ended, and its destructor is waiting to join this thread.
                if _cell(sh[].state).load() == 3:
                    return arg
                if at - Int(_cell(sh[].released).load()) >= _AHEAD:
                    sleep(0.001)
                    continue
                var chunk = sh[].resp.read_chunk(1 << 20)
                if len(chunk) == 0:
                    break
                if at + len(chunk) > sh[].size:
                    raise Error("the body is longer than its Content-Length")
                unsafe_memcpy(
                    dest=dst.unsafe_offset(at),
                    src=chunk.unsafe_ptr(),
                    count=len(chunk),
                )
                at += len(chunk)
                _cell(sh[].have).store(Int64(at))
            if at != sh[].size:
                raise Error(
                    "the body ended at ", at, " of its ", sh[].size, " bytes"
                )
        sh[].ms = Int64(Int(perf_counter_ns() - t0) // 1_000_000)
        _cell(sh[].state).store(1)
    except e:
        sh[].err = String(e)
        _cell(sh[].state).store(2)
    return arg


struct Download(GzInput, Movable):
    """A GET whose body arrives on its own thread while the caller uses
    what has come so far: `wait` for more, `view` the bytes in hand. This
    is what lets an hour task gunzip and parse while the hour is still
    downloading (about 100 MB of gzip), so its time is roughly the longer of
    the two, not their sum, while holding only the part not yet decoded
    (`release`)."""

    var addr: Int
    """The heap `_Shared`, by address: the reader thread holds it too."""
    var thread: ThreadHandle
    var url: String

    def __init__(out self, url: String, timeout_ms: Int = 600_000) raises:
        """Sends the request and starts the reader thread; raises on any
        status but 200. The body is not read yet."""
        var c = _client(timeout_ms)
        var req = Request(method="GET", url=url)
        req.headers.set("User-Agent", USER_AGENT)
        var resp = c.send_streaming(req^)
        if resp.status != 200:
            raise Error("GET ", url, ": HTTP ", resp.status)
        var size = -1
        var cl = resp.header("content-length")
        if cl:
            try:
                size = Int(cl)
            except:
                size = -1
        var p = unsafe_alloc[_Shared](1)
        p.unsafe_write(_Shared(c^, resp^, size))
        if size > 0:
            p[].region = _map(size)
        self.addr = Int(p)
        self.url = url
        self.thread = ThreadHandle.spawn[_pull](opaque_ptr(self.addr))

    @always_inline
    def _sh(self) -> Pointer[_Shared, MutUntrackedOrigin]:
        """The shared state, which lives on the heap so the reader thread can
        hold it while this struct moves."""
        return Pointer[_Shared, MutUntrackedOrigin](unsafe_from_address=self.addr)

    def __del__(deinit self):
        # Ask the reader to stop between chunks, wait for it, then free.
        var st = _cell(
            Pointer[_Shared, MutUntrackedOrigin](
                unsafe_from_address=self.addr
            )[].state
        )
        if st.load() == 0:
            st.store(3)
        try:
            self.thread.join()
        except:
            pass
        var p = Pointer[_Shared, MutUntrackedOrigin](unsafe_from_address=self.addr)
        if p[].region != 0:
            var gone = Int(p[].released)
            _unmap(p[].region + gone, p[].size - gone)
        p.unsafe_deinit_pointee()
        p.unsafe_free()

    def have(self) raises -> Int:
        """Bytes arrived so far; raises if the download failed."""
        var n = Int(_cell(self._sh()[].have).load())
        if _cell(self._sh()[].state).load() == 2:
            raise Error("GET ", self.url, ": ", self._sh()[].err)
        return n

    def complete(self) raises -> Bool:
        """Whether every byte has arrived."""
        var st = _cell(
            Pointer[_Shared, MutUntrackedOrigin](
                unsafe_from_address=self.addr
            )[].state
        ).load()
        if st == 2:
            raise Error("GET ", self.url, ": ", self._sh()[].err)
        return st == 1

    def view(self, n: Int) -> Span[UInt8, MutUntrackedOrigin]:
        """The first `n` bytes, `n` no more than `have()` returned."""
        if n == 0:
            return Span[UInt8, MutUntrackedOrigin]()
        var at = self._sh()[].region
        if at == 0:
            at = Int(self._sh()[].buf.unsafe_ptr())
        return Span[UInt8, MutUntrackedOrigin](
            unsafe_ptr=Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=at),
            length=n,
        )

    def release(self, upto: Int):
        """The decoder is done with the first `upto` bytes (which have
        arrived): give them back to the OS, a megabyte at a time, so an hour
        holds the compressed input not yet decoded rather than all of it
        (100-130 MB in 2023-2025). `view` must not be read below it again."""
        var sh = self._sh()
        if sh[].region == 0:
            return
        var to = min(upto, Int(_cell(sh[].have).load()))
        to -= to % _RELEASE_STEP
        var gone = Int(_cell(sh[].released).load())
        if to > gone:
            _unmap(sh[].region + gone, to - gone)
            _cell(sh[].released).store(Int64(to))

    def wait(self, want: Int) raises -> Int:
        """Blocks until `want` bytes have arrived or all of them have;
        returns how many there are."""
        while True:
            var done = self.complete()
            var n = self.have()
            if done or n >= want:
                return n
            sleep(0.0005)

    def ms(self) -> Int:
        """How long the body took to arrive (once complete)."""
        return Int(self._sh()[].ms)


@fieldwise_init
struct Reply(Movable):
    var status: Int
    var body: String
    var remaining: Int
    """`X-RateLimit-Remaining`: requests left in the current window, or -1
    when the reply didn't say. mojo_repos and mojo_stats use it, with the
    two below, to stop or wait before GitHub refuses a request."""
    var retry_after: Int
    """`Retry-After` in seconds, or -1."""
    var reset: Int
    """`X-RateLimit-Reset` (epoch seconds), or -1."""


def _header_int(resp: Response, name: String) -> Int:
    """A numeric response header, or -1 if it is absent or not a number."""
    var v = resp.headers.get(name)
    if v:
        try:
            return Int(v)
        except:
            pass
    return -1


def github(path: String) raises -> Reply:
    """GET `https://api.github.com<path>`, with the token if there is one.
    Any status comes back as a `Reply` (it does not raise on 403/404/429), so
    that callers can tell a missing repository from a rate limit."""
    var c = _client()
    var req = Request(method="GET", url=String("https://api.github.com", path))
    req.headers.set("User-Agent", USER_AGENT)
    req.headers.set("Accept", "application/vnd.github+json")
    req.headers.set("X-GitHub-Api-Version", "2022-11-28")
    var token = getenv("GITHUB_TOKEN")
    if token:
        req.headers.set("Authorization", String("Bearer ", token))
    var resp = c.send(req)
    return Reply(
        resp.status,
        resp.text(),
        _header_int(resp, "x-ratelimit-remaining"),
        _header_int(resp, "retry-after"),
        _header_int(resp, "x-ratelimit-reset"),
    )


def raw_file(repo: String, branch: String, file: String) raises -> String:
    """A file from raw.githubusercontent.com, or "" if it isn't there. These
    requests are not part of the REST API's rate limit and send no token."""
    var c = _client()
    var url = String(
        "https://raw.githubusercontent.com/", repo, "/", branch, "/", file
    )
    var req = Request(method="GET", url=url)
    req.headers.set("User-Agent", USER_AGENT)
    var resp = c.send(req)
    if resp.status != 200:
        return String()
    return resp.text()
