"""HTTP: GH Archive files, and GitHub's REST API and raw files.

Uses flare's blocking `HttpClient`. GitHub calls send `GITHUB_TOKEN` when it
is set (orca gives runs the secret registered with `--secret`); without it
the REST API allows 60 requests an hour, which is enough for a local run.
"""

from std.os import getenv
from std.os.path import exists

from flare.http import HttpClient, Request, Response
from flare.tls import TlsConfig

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


@fieldwise_init
struct Reply(Movable):
    var status: Int
    var body: String
    var remaining: Int
    """`X-RateLimit-Remaining`, or -1 when the reply didn't say."""


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
    var rem = resp.headers.get("x-ratelimit-remaining")
    var remaining = -1
    if rem:
        try:
            remaining = Int(rem)
        except:
            pass
    return Reply(resp.status, resp.text(), remaining)


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
