"""The console: a flare app over mojo.repos, mojo.commits and mojo.migrations.

    PORT=8080 pixi run ./build/console

Pages: `/` the libraries by size and age, `/versions` the Mojo versions they
moved to over time, `/repos/<owner>/<name>` one library. Each has JSON at
`/api/...`. Every request scans the tables again; they're small.
"""

from std.os import getenv

from flare.http import (
    HttpServer,
    Request,
    Response,
    Router,
    ServerConfig,
    html_escape,
    internal_error,
    not_found,
    ok_json,
)
from flare.net import SocketAddr
from orca.civil import now

from jscan import micros_to_iso
from model import (
    Library,
    Migration,
    Point,
    day,
    history,
    libraries,
    migrations,
    versions_by_month,
)

comptime STYLE = """
:root{--bg:#fff;--fg:#1d1d1f;--mute:#6e6e73;--line:#e5e5ea;--accent:#d9480f}
@media (prefers-color-scheme:dark){:root{--bg:#141416;--fg:#f2f2f7;--mute:#a1a1a6;--line:#2c2c30;--accent:#ff8a50}}
body{background:var(--bg);color:var(--fg);font:15px/1.45 system-ui,sans-serif;margin:0 auto;max-width:1100px;padding:16px}
a{color:var(--accent);text-decoration:none}a:hover{text-decoration:underline}
nav a{margin-right:16px}h1{font-size:22px}table{border-collapse:collapse;width:100%;overflow-x:auto;display:block}
th,td{text-align:left;padding:6px 10px;border-bottom:1px solid var(--line);white-space:nowrap}
th{color:var(--mute);font-weight:500}td.num,th.num{text-align:right;font-variant-numeric:tabular-nums}
.mute{color:var(--mute)}svg{max-width:100%;height:auto}
"""


def _page(title: String, var body: String) raises -> Response:
    var h = String(
        "<!doctype html><html><head><meta charset=utf-8>",
        "<meta name=viewport content='width=device-width,initial-scale=1'>",
        "<title>", html_escape(title), "</title><style>", STYLE, "</style></head><body>",
        "<nav><a href='/'>Libraries</a><a href='/versions'>Versions</a></nav>",
        body, "</body></html>",
    )
    var resp = Response(status=200, reason="OK", body=List[UInt8](h.as_bytes()))
    resp.headers.set("Content-Type", "text/html; charset=utf-8")
    return resp^


def _q(s: String) -> String:
    """A JSON string."""
    var out = String('"')
    for cp in s.codepoint_slices():
        if cp == '"':
            out += '\\"'
        elif cp == "\\":
            out += "\\\\"
        elif cp == "\n":
            out += "\\n"
        elif cp == "\t":
            out += "\\t"
        elif cp == "\r":
            out += "\\r"
        else:
            out += cp
    out += '"'
    return out^


def _age(micros: Int64, now_days: Int) -> String:
    """`3.2 years` / `5 months` / `12 days` since `micros`."""
    if micros == 0:
        return String()
    var d = now_days - Int(micros // 86_400_000_000)
    if d >= 365:
        var tenths = d * 10 // 365
        return String(tenths // 10, ".", tenths % 10, " years")
    if d >= 60:
        return String(d // 30, " months")
    return String(d, " days")


def _now_days() raises -> Int:
    return Int(now() // 86400)


def index(req: Request) raises -> Response:
    try:
        var libs = libraries()
        var today = _now_days()
        var h = String(
            "<h1>Mojo libraries</h1><p class=mute>", len(libs),
            " repositories found in GH Archive, biggest first. Size is lines of",
            " Mojo at the last commit read; age is since GitHub created the",
            " repository.</p><table><tr><th>Repository</th>",
            "<th class=num>Lines of Mojo</th><th class=num>Files</th>",
            "<th class=num>Commits</th><th>Age</th><th>Created</th>",
            "<th>Mojo version</th><th>Tooling</th><th class=num>Stars</th>",
            "<th>Found by</th></tr>",
        )
        for ref l in libs:
            var lines = String(l.mojo_lines) if l.commits > 0 else String("<span class=mute>not read</span>")
            h.write(
                "<tr><td><a href='/repos/", l.repo, "'>", html_escape(l.repo),
                "</a></td><td class=num>", lines, "</td><td class=num>",
                l.mojo_files, "</td><td class=num>", l.commits, "</td><td>",
                _age(l.created_at, today), "</td><td>", day(l.created_at),
                "</td><td>", html_escape(l.mojo_version), "</td><td>",
                html_escape(l.tooling), "</td><td class=num>", l.stars,
                "</td><td class=mute>", html_escape(l.found_by), "</td></tr>",
            )
        h.write("</table>")
        return _page("Mojo libraries", h^)
    except e:
        return internal_error(String(e))


def _lib_json(l: Library) -> String:
    return String(
        '{"repo":', _q(l.repo), ',"description":', _q(l.description),
        ',"created_at":', _q(micros_to_iso(l.created_at) if l.created_at else ""),
        ',"first_seen":', _q(micros_to_iso(l.first_seen)),
        ',"found_by":', _q(l.found_by), ',"stars":', l.stars,
        ',"forks":', l.forks, ',"license":', _q(l.license),
        ',"size_kb":', l.size_kb, ',"commits":', l.commits,
        ',"mojo_lines":', l.mojo_lines, ',"mojo_files":', l.mojo_files,
        ',"tooling":', _q(l.tooling), ',"mojo_version":', _q(l.mojo_version), "}",
    )


def index_json(req: Request) raises -> Response:
    try:
        var out = String("[")
        var first = True
        for ref l in libraries():
            if not first:
                out += ","
            first = False
            out += _lib_json(l)
        out += "]"
        return ok_json(out)
    except e:
        return internal_error(String(e))


def versions(req: Request) raises -> Response:
    try:
        var rows = versions_by_month()
        var h = String(
            "<h1>Mojo versions over time</h1><p class=mute>Each month, how many",
            " libraries moved to each Mojo version (from their lock file, or",
            " their manifest when there's no lock), in Mojo's own order across",
            " the renumbering: 24.x, 25.x, 0.25.x, 0.26.x, 1.x.</p>",
            "<table><tr><th>Month</th><th>Version</th><th class=num>Libraries</th></tr>",
        )
        for ref r in rows:
            h.write(
                "<tr><td>", r.month, "</td><td>", html_escape(r.version),
                "</td><td class=num>", r.repos, "</td></tr>",
            )
        h.write("</table>")
        return _page("Mojo versions", h^)
    except e:
        return internal_error(String(e))


def versions_json(req: Request) raises -> Response:
    try:
        var out = String("[")
        var first = True
        for ref r in versions_by_month():
            if not first:
                out += ","
            first = False
            out.write('{"month":', _q(r.month), ',"version":', _q(r.version), ',"libraries":', r.repos, "}")
        out += "]"
        return ok_json(out)
    except e:
        return internal_error(String(e))


def _chart(points: List[Point]) -> String:
    """Lines of Mojo over time, as an SVG polyline."""
    if len(points) < 2:
        return String()
    var w = 900
    var h = 180
    var t0 = points[0].at
    var t1 = points[len(points) - 1].at
    var top = Int64(1)
    for ref p in points:
        if p.lines > top:
            top = p.lines
    var span = max(t1 - t0, Int64(1))
    var pts = String()
    for ref p in points:
        var x = Int((p.at - t0) * Int64(w) // span)
        var y = h - Int(max(p.lines, Int64(0)) * Int64(h - 10) // top)
        pts.write(x, ",", y, " ")
    return String(
        "<svg viewBox='-4 -4 ", w + 8, " ", h + 8, "' role=img aria-label='lines of Mojo over time'>",
        "<polyline fill=none stroke='currentColor' stroke-width=2 points='", pts, "'/></svg>",
        "<p class=mute>", day(t0), " to ", day(t1), "; peak ", top, " lines</p>",
    )


def _find(repo: String) raises -> Optional[Library]:
    for ref l in libraries():
        if l.repo == repo:
            return l.copy()
    return None


def repo_page(req: Request) raises -> Response:
    try:
        var repo = String(req.param("owner"), "/", req.param("name"))
        var found = _find(repo)
        if not found:
            return not_found(req.url)
        var l = found.value().copy()
        var pts = history(repo)
        var ms = migrations(repo)
        var h = String(
            "<h1>", html_escape(repo), "</h1><p>", html_escape(l.description),
            "</p><p class=mute><a href='https://github.com/", repo, "'>GitHub</a> · created ",
            day(l.created_at), " · first seen in GH Archive ", day(l.first_seen),
            " (", html_escape(l.found_by), ") · ", l.stars, " stars · ", l.forks,
            " forks · ", html_escape(l.license), "</p>",
            "<p>", l.mojo_lines, " lines of Mojo in ", l.mojo_files, " files at the last of ",
            l.commits, " commits (", day(l.first_commit), " to ", day(l.last_commit),
            "); tooling ", html_escape(l.tooling), ", Mojo ", html_escape(l.mojo_version), "</p>",
            "<h2>Lines of Mojo</h2>", _chart(pts),
            "<h2>Migrations</h2><table><tr><th>Date</th><th>What</th><th>From</th><th>To</th><th>Commit</th></tr>",
        )
        for ref m in ms:
            h.write(
                "<tr><td>", day(m.at), "</td><td>", m.kind, "</td><td>",
                html_escape(m.from_value), "</td><td>", html_escape(m.to_value),
                "</td><td><a href='https://github.com/", repo, "/commit/", m.sha, "'>",
                String(m.sha[byte=:10]), "</a></td></tr>",
            )
        h.write("</table>")
        return _page(repo, h^)
    except e:
        return internal_error(String(e))


def repo_json(req: Request) raises -> Response:
    try:
        var repo = String(req.param("owner"), "/", req.param("name"))
        var found = _find(repo)
        if not found:
            return not_found(req.url)
        var out = String('{"library":', _lib_json(found.value()), ',"migrations":[')
        var first = True
        for ref m in migrations(repo):
            if not first:
                out += ","
            first = False
            out.write(
                '{"at":', _q(micros_to_iso(m.at)), ',"sha":', _q(m.sha), ',"kind":',
                _q(m.kind), ',"from":', _q(m.from_value), ',"to":', _q(m.to_value), "}",
            )
        out += '],"commits":['
        first = True
        for ref p in history(repo):
            if not first:
                out += ","
            first = False
            out.write(
                '{"at":', _q(micros_to_iso(p.at)), ',"sha":', _q(p.sha),
                ',"mojo_lines":', p.lines, ',"tooling":', _q(p.tooling),
                ',"mojo_version":', _q(p.version), "}",
            )
        out += "]}"
        return ok_json(out)
    except e:
        return internal_error(String(e))


def main() raises:
    var r = Router()
    r.get("/", index)
    r.get("/versions", versions)
    r.get("/repos/:owner/:name", repo_page)
    r.get("/api/repos", index_json)
    r.get("/api/versions", versions_json)
    r.get("/api/repos/:owner/:name", repo_json)
    var addr = String("0.0.0.0:", getenv("PORT", "8080"))
    var server = HttpServer.bind(SocketAddr.parse(addr), ServerConfig())
    print("console on http://", addr, sep="")
    server.serve(r^)
