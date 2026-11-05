"""HTTP: GH Archive files, and GitHub's REST API and raw files.

Uses flare's blocking `HttpClient`. GitHub calls send `GITHUB_TOKEN` when it
is set (orca gives runs the secret registered with `--secret`); without it
the REST API allows 60 requests an hour, which is enough for a local run.
"""

from std.memory import unsafe_memcpy
from std.memory.alloc import unsafe_alloc
from std.os import getenv
from std.os.path import exists
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


struct _Shared(Movable):
    """What a download's reader thread and its consumer share."""

    var client: HttpClient
    var resp: HttpStreamResponse
    var size: Int
    """`Content-Length`, or -1."""
    var buf: List[UInt8]
    var have: Int64
    """Bytes of `buf` that have arrived (release-stored by the reader)."""
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
        self.buf = List[UInt8](length=max(size, 0), fill=0)
        self.have = 0
        self.state = 0
        self.err = String()
        self.ms = 0


def _cell(ref v: Int64) -> AtomicCounter:
    return AtomicCounter.at(Int(Pointer(to=v)))


def _pull(arg: OpaquePtr) -> OpaquePtr:
    """The reader thread: the body into `buf`, publishing `have` as it
    goes. With no `Content-Length` it reads it all, then publishes."""
    var sh = Pointer[_Shared, MutUntrackedOrigin](unsafe_from_address=Int(arg))
    var t0 = perf_counter_ns()
    try:
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
            var dst = sh[].buf.unsafe_ptr()
            while True:
                if _cell(sh[].state).load() == 3:
                    return arg
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
    what has come so far: `wait` for more, `view` the bytes in hand."""

    var addr: Int
    """The heap `_Shared`, by address: the reader thread holds it too."""
    var thread: ThreadHandle
    var url: String

    def __init__(out self, url: String, timeout_ms: Int = 600_000) raises:
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
        self.addr = Int(p)
        self.url = url
        self.thread = ThreadHandle.spawn[_pull](opaque_ptr(self.addr))

    @always_inline
    def _sh(self) -> Pointer[_Shared, MutUntrackedOrigin]:
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
        var at = Int(self._sh()[].buf.unsafe_ptr())
        return Span[UInt8, MutUntrackedOrigin](
            unsafe_ptr=Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=at),
            length=n,
        )

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
    """`X-RateLimit-Remaining`, or -1 when the reply didn't say."""
    var retry_after: Int
    """`Retry-After` in seconds, or -1."""
    var reset: Int
    """`X-RateLimit-Reset` (epoch seconds), or -1."""


def _header_int(resp: Response, name: String) -> Int:
    var v = resp.headers.get(name)
    if v:
        try:
            return Int(v)
        except:
            pass
    return -1


def github(path: String) raises -> Reply:
    """GET `https://api.github.com<path>`, with the token if there is one."""
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
    """A file from raw.githubusercontent.com, or "" if it isn't there."""
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
