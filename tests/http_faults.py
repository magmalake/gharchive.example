"""A local HTTP server that misbehaves on purpose, for tests/test_fetch.mojo.

    python3 tests/http_faults.py PORT_FILE

Binds 127.0.0.1 on a free port, writes the port to PORT_FILE and serves
until killed. Paths (N is the body's size, KEY names a counter of requests,
so each test uses its own):

    /ok/N                 200 with N bytes
    /stall/N              200, Content-Length N, half the body, then silence
    /stallhead            reads the request and never answers
    /flaky/K/KEY/N        503 (Retry-After: 1) or 500, alternately, for the
                          first K requests to KEY, then /ok/N
    /cut/KEY/N            the first request gets half the body and a closed
                          connection; later ones honour Range (206)
    /cutnorange/KEY/N     the same, but later ones ignore Range (200, all)
    /missing              404
    /count/KEY            how many requests KEY has had, as text

The body is byte i = (7 i + 3) mod 251, so a test can check every byte.
"""

import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

COUNTS = {}
LOCK = threading.Lock()


def body(n):
    return bytes((7 * i + 3) % 251 for i in range(n))


def bump(key):
    with LOCK:
        COUNTS[key] = COUNTS.get(key, 0) + 1
        return COUNTS[key]


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def send_body(self, data, status=200, extra=()):
        self.send_response(status)
        self.send_header("Content-Length", str(len(data)))
        for k, v in extra:
            self.send_header(k, v)
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(data)
        self.wfile.flush()

    def stall_forever(self):
        try:
            while True:
                time.sleep(3600)
        except Exception:
            pass

    def half_then(self, n, then):
        data = body(n)
        self.send_response(200)
        self.send_header("Content-Length", str(n))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(data[: n // 2])
        self.wfile.flush()
        then()

    def ranged(self, n, honour):
        data = body(n)
        rng = self.headers.get("Range", "")
        if honour and rng.startswith("bytes=") and rng.endswith("-"):
            start = int(rng[6:-1])
            self.send_body(
                data[start:], 206, [("Content-Range", f"bytes {start}-{n - 1}/{n}")]
            )
        else:
            self.send_body(data)

    def do_GET(self):
        parts = self.path.strip("/").split("/")
        kind = parts[0]
        if kind == "ok":
            self.send_body(body(int(parts[1])))
        elif kind == "stall":
            self.half_then(int(parts[1]), self.stall_forever)
        elif kind == "stallhead":
            bump("stallhead")
            self.stall_forever()
        elif kind == "flaky":
            k, key, n = int(parts[1]), parts[2], int(parts[3])
            seen = bump(key)
            if seen <= k:
                if seen % 2 == 1:
                    self.send_body(b"busy", 503, [("Retry-After", "1")])
                else:
                    self.send_body(b"oops", 500)
            else:
                self.send_body(body(n))
        elif kind in ("cut", "cutnorange"):
            key, n = parts[1], int(parts[2])
            if bump(key) == 1:
                self.half_then(n, lambda: self.connection.close())
            else:
                self.ranged(n, kind == "cut")
        elif kind == "missing":
            bump("missing")
            self.send_body(b"no such hour", 404)
        elif kind == "count":
            with LOCK:
                self.send_body(str(COUNTS.get(parts[1], 0)).encode())
        else:
            self.send_body(b"?", 400)


def main():
    srv = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    srv.daemon_threads = True
    with open(sys.argv[1] + ".tmp", "w") as f:
        f.write(str(srv.server_address[1]))
    import os

    os.replace(sys.argv[1] + ".tmp", sys.argv[1])
    srv.serve_forever()


if __name__ == "__main__":
    main()
