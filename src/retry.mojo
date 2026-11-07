"""Timeouts and retries for the network: settings read from the environment,
exponential backoff with jitter, and one log line per retry.

GH Archive downloads (`fetch.Download`) and git clones (`history`,
`headversion`) share this. The settings, with their defaults:

| Variable                     | Default | What it bounds                                   |
|------------------------------|---------|--------------------------------------------------|
| `GHARCHIVE_CONNECT_SECONDS`  | 20      | TCP connect and TLS handshake of one request     |
| `GHARCHIVE_IDLE_SECONDS`     | 30      | silence while reading (a stalled connection)     |
| `GHARCHIVE_TIMEOUT_SECONDS`  | 900     | an hour's download, all its tries together       |
| `GHARCHIVE_RETRIES`          | 4       | retries after the first try (5 tries)            |
| `GIT_TIMEOUT_SECONDS`        | 600     | one git clone (the process is killed after it)   |
| `GIT_RETRIES`                | 3       | retries of a clone after the first try           |
| `GIT_LOW_SPEED_LIMIT`        | 1000    | git aborts a transfer slower than this, in B/s, |
| `GIT_LOW_SPEED_SECONDS`      | 60      | ... for this long (`http.lowSpeedLimit`/`Time`)  |

A retry waits `min(cap, base * 2^k)`, of which the second half is random
(1 s, 2 s, 4 s ... up to 30 s, each between half and all of that), or what a
429's or 503's `Retry-After` asks for.
"""

from std.os import getenv
from std.time import perf_counter_ns, sleep

comptime BACKOFF_BASE_MS = 1_000
comptime BACKOFF_CAP_MS = 30_000


def env_int(name: String, default: Int) -> Int:
    """A non-negative integer setting from the environment, else `default`
    (also when it isn't a number)."""
    var v = getenv(name)
    if not v:
        return default
    try:
        var n = Int(v)
        if n >= 0:
            return n
    except:
        pass
    return default


def _mix(x: UInt64) -> UInt64:
    """splitmix64's finalizer: a well-spread hash of `x`."""
    var z = x + 0x9E3779B97F4A7C15
    z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9
    z = (z ^ (z >> 27)) * 0x94D049BB133111EB
    return z ^ (z >> 31)


def backoff_ms(
    retry: Int, base_ms: Int = BACKOFF_BASE_MS, cap_ms: Int = BACKOFF_CAP_MS
) -> Int:
    """How long to wait before retry number `retry` (0 for the first):
    `min(cap, base * 2^retry)`, its second half random, so workers that
    failed together don't all come back at once."""
    var d = cap_ms
    if retry < 30:
        d = min(cap_ms, base_ms * (1 << retry))
    var half = d // 2
    if half <= 0:
        return d
    var r = _mix(UInt64(perf_counter_ns()) ^ UInt64(retry))
    return half + Int(r % UInt64(half + 1))


def retryable_status(status: Int) -> Bool:
    """HTTP statuses worth trying again: 408, 429 and every 5xx. 404 (an
    hour GH Archive hasn't published) and the other 4xx are final."""
    return status == 408 or status == 429 or (status >= 500 and status < 600)


def log_retry(op: String, attempt: Int, tries: Int, wait_ms: Int, err: String):
    """One line per retry, in the worker's log (the run page's cluster
    logs), so a slow run says why."""
    print(
        "retry: ",
        op,
        ": try ",
        attempt,
        " of ",
        tries,
        " failed (",
        err,
        "); trying again in ",
        wait_ms,
        " ms",
        sep="",
    )


def now_ms() -> Int:
    return Int(perf_counter_ns() // 1_000_000)


def nap_ms(ms: Int):
    if ms > 0:
        sleep(Float64(ms) / 1000.0)
