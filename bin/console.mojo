"""The console: a flare app over mojo.repos, mojo.commits and mojo.migrations.

    PORT=8080 pixi run ./build/console

Pages: `/` the libraries by size and age, `/versions` the Mojo versions they
moved to over time, `/repos/<owner>/<name>` one library. Each has JSON at
`/api/...`. Every request scans the tables again; they're small.

The look follows mlake.dev: its warm-ash neutrals, ember accent and lake
links, on the system font stack (no external fonts or scripts).
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
*{box-sizing:border-box}
:root{color-scheme:light;--bg:#fbf9f7;--bg-alt:#f4f0ec;--surface:#fff;--surface-2:#f8f5f2;--border:#e3dcd4;--border-strong:#cfc5ba;--text:#17151a;--muted:#6b645d;--faint:#948c84;--ember:#c33c10;--ember-wash:#fdefe7;--lake:#0d6a70;--shadow:0 1px 2px rgb(23 21 26 / .04),0 8px 24px -12px rgb(23 21 26 / .12);--radius:10px;--radius-sm:6px;--mono:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace}
@media (prefers-color-scheme:dark){:root{color-scheme:dark;--bg:#0e0d11;--bg-alt:#131218;--surface:#17161d;--surface-2:#1c1b23;--border:#2a2833;--border-strong:#3d3a48;--text:#eeeae4;--muted:#a49d95;--faint:#7b746d;--ember:#ff7a45;--ember-wash:#2a1710;--lake:#4ecdc4;--shadow:0 1px 2px rgb(0 0 0 / .4),0 8px 24px -12px rgb(0 0 0 / .6)}}
html{-webkit-text-size-adjust:100%}
body{margin:0;background:var(--bg);color:var(--text);font:15px/1.6 ui-sans-serif,system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;-webkit-font-smoothing:antialiased;min-height:100vh;display:flex;flex-direction:column}
a{color:var(--lake);text-decoration:none}a:hover{text-decoration:underline;text-underline-offset:.18em}
.wrap{width:100%;max-width:1172px;margin-inline:auto;padding-inline:16px}
.top{position:sticky;top:0;z-index:5;background:color-mix(in srgb,var(--bg) 86%,transparent);backdrop-filter:blur(12px) saturate(1.4);-webkit-backdrop-filter:blur(12px) saturate(1.4);border-bottom:1px solid var(--border)}
.top .wrap{display:flex;align-items:center;gap:20px;height:56px}
.brand{display:flex;align-items:center;gap:9px;color:var(--text);font-weight:700;font-size:17px;letter-spacing:-.02em;white-space:nowrap}
.brand:hover{text-decoration:none}.brand svg{display:block;flex-shrink:0}
.top nav{display:flex;align-items:center;gap:18px;margin-left:auto;font-size:14px}
.top nav a{color:var(--muted);padding:4px 0;border-bottom:1.5px solid transparent;white-space:nowrap}
.top nav a:hover{color:var(--text);text-decoration:none;border-bottom-color:var(--ember)}
.top nav a[aria-current=page]{color:var(--text);border-bottom-color:var(--ember)}
.top nav .sep{width:1px;height:16px;background:var(--border-strong)}
main{flex:1;padding:32px 0 48px}
h1{font-size:28px;font-weight:700;letter-spacing:-.02em;line-height:1.15;margin:0 0 8px;overflow-wrap:anywhere}
h2{font-size:18px;font-weight:600;letter-spacing:-.01em;margin:36px 0 12px}
.lead{color:var(--muted);max-width:72ch;margin:0 0 20px}
.sub{color:var(--muted);font-size:14px;margin:-4px 0 14px}
.tbl{background:var(--surface);border:1px solid var(--border);border-radius:var(--radius);box-shadow:var(--shadow)}
@media (max-width:1200px){.tbl{overflow-x:auto}.tbl th{position:static}}
table{border-collapse:separate;border-spacing:0;width:100%;font-size:14px}
th,td{text-align:left;padding:10px;border-bottom:1px solid var(--border);white-space:nowrap;vertical-align:top}
td.soft{white-space:normal;min-width:14ch;overflow-wrap:anywhere}
th{position:sticky;top:56px;z-index:1;background:var(--surface-2);color:var(--faint);font:500 11px/1.6 var(--mono);letter-spacing:.06em;text-transform:uppercase}
th:first-child{border-top-left-radius:var(--radius)}th:last-child{border-top-right-radius:var(--radius)}
tr:last-child td{border-bottom:0}
tbody tr:hover td{background:var(--surface-2)}
td.num,th.num{text-align:right;font-variant-numeric:tabular-nums}
td.month{font-weight:600;background:var(--surface)}
.repo{font-weight:600}
.mono{font-family:var(--mono);font-size:12.5px}
.mute{color:var(--muted)}
.empty{background:var(--surface);border:1px dashed var(--border-strong);border-radius:var(--radius);padding:44px 24px;text-align:center;color:var(--muted)}
.empty strong{display:block;color:var(--text);font-size:17px;margin-bottom:6px}
.empty p{margin:0 auto;max-width:54ch}
.bar{display:flex;align-items:center;gap:10px;min-width:260px}
.bar i{display:block;height:10px;border-radius:3px;background:var(--ember);min-width:2px}
.bar span{font-variant-numeric:tabular-nums;min-width:3ch;text-align:right}
.head{margin-bottom:24px}
.head .owner{color:var(--muted);font-weight:500}
.head .desc{font-size:16px;max-width:72ch;margin:0 0 10px}
.meta{color:var(--muted);font-size:14px;margin:0 0 18px}
.stats{display:grid;grid-template-columns:repeat(auto-fill,minmax(132px,1fr));gap:10px}
.stat{background:var(--surface);border:1px solid var(--border);border-radius:var(--radius-sm);padding:10px 12px;min-width:0}
.stat b{display:block;color:var(--faint);font:500 11.5px/1.5 var(--mono);letter-spacing:.08em;text-transform:uppercase}
.stat span{display:block;font-size:18px;font-weight:600;font-variant-numeric:tabular-nums;letter-spacing:-.01em;margin-top:2px;overflow-wrap:anywhere}
.stat small{display:block;color:var(--muted);font-size:12.5px}
.card{background:var(--surface);border:1px solid var(--border);border-radius:var(--radius);padding:16px 18px;box-shadow:var(--shadow)}
.card svg{display:block;width:100%;height:auto}
.card p{margin:8px 0 0;font-size:13px}
.tbl+p{margin:10px 2px 0;font-size:13px}
footer{border-top:1px solid var(--border);background:var(--bg-alt);padding:24px 0;font-size:13px;color:var(--faint)}
footer .wrap{display:flex;flex-wrap:wrap;gap:8px 24px;align-items:center}
footer p{margin:0;max-width:78ch}
footer nav{display:flex;gap:16px;margin-left:auto}
footer a{color:var(--muted)}footer a:hover{color:var(--text)}
@media (max-width:640px){.top .wrap{gap:12px}.top nav{gap:12px}.top nav .sep,.top nav .arrow{display:none}.brand{font-size:15px}h1{font-size:24px}th,td{padding:9px 10px}main{padding-top:24px}footer nav{margin-left:0}}
"""

comptime COMMITS_SHOWN = 50
"""How many of a repository's commits the page lists; the JSON has all."""

comptime MARK = (
    "<svg width=20 height=20 viewBox='0 0 24 24' fill=none aria-hidden=true>"
    "<path d='M12 1.9 22 20.2H2L12 1.9Z' stroke='var(--lake)' stroke-width='1.6' stroke-linejoin='round'/>"
    "<path d='M12 9.4 17.4 19H6.6L12 9.4Z' fill='var(--ember)'/></svg>"
)


def _nav(href: String, label: String, current: Bool) -> String:
    return String(
        "<a href='", href, "'", " aria-current=page" if current else "", ">", label, "</a>"
    )


comptime BRAND = "Mojo census"

comptime DESCRIPTION = (
    "Mojo libraries, versions and growth, counted from GH Archive by"
    " magmalake. An independent project, not affiliated with Modular."
)


def _page(title: String, var body: String, section: String) raises -> Response:
    """The page around `body`; `section` is `libraries` or `versions`, the
    nav entry to light up. An empty `title` is the home page, titled with
    the brand alone; others read "<title> · Mojo census"."""
    var full = String(BRAND) if title == "" else String(title, " · ", BRAND)
    var h = String(
        "<!doctype html><html lang=en><head><meta charset=utf-8>"
        "<link rel=icon href=\"data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 16 16'%3E%3Crect width='16' height='16' rx='3' fill='%23b45309'/%3E%3Crect x='3' y='8' width='2.5' height='5' fill='%23fff'/%3E%3Crect x='6.75' y='4' width='2.5' height='9' fill='%23fff'/%3E%3Crect x='10.5' y='6' width='2.5' height='7' fill='%23fff'/%3E%3C/svg%3E\">",
        "<meta name=viewport content='width=device-width,initial-scale=1'>",
        "<meta name=color-scheme content='light dark'>",
        "<meta name=description content='", html_escape(DESCRIPTION), "'>",
        "<title>", html_escape(full), "</title><style>", STYLE, "</style></head><body>",
        "<header class=top><div class=wrap><a class=brand href='/'>", MARK, BRAND, "</a>",
        "<nav>", _nav("/", "Libraries", section == "libraries"),
        _nav("/versions", "Versions", section == "versions"),
        "<span class=sep aria-hidden=true></span>",
        "<a href='https://orca.mlake.dev' rel=noopener title='The pipelines that build this census'>orca<span class=arrow> &#8599;</span></a><a href='https://mlake.dev' rel=noopener>mlake.dev<span class=arrow> &#8599;</span></a></nav></div></header>",
        "<main><div class=wrap>", body, "</div></main>",
        "<footer><div class=wrap><p>An independent project; Mojo is a trademark of Modular Inc.",
        " Data from <a href='https://www.gharchive.org' rel=noopener>GH Archive</a>, read by the",
        " mojo-census pipelines on <a href='https://orca.mlake.dev' rel=noopener>orca</a>: the hour's",
        " public GitHub events, the repositories with Mojo in them, and what their lock files",
        " say at each commit.</p>",
        "<nav><a href='https://mlake.dev' rel=noopener>mlake.dev</a>",
        "<a href='https://github.com/magmalake' rel=noopener>GitHub</a>",
        "<a href='/api/repos'>JSON</a></nav></div></footer></body></html>",
    )
    var resp = Response(status=200, reason="OK", body=List[UInt8](h.as_bytes()))
    resp.headers.set("Content-Type", "text/html; charset=utf-8")
    return resp^


def _empty(title: String, text: String) -> String:
    return String("<div class=empty><strong>", title, "</strong><p>", text, "</p></div>")


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


def _n(v: Int64) -> String:
    """`12,345`: a number with thousands separators."""
    if v < 0:
        return String("-", _n(-v))
    if v < 1000:
        return String(v)
    var rest = v % 1000
    var tail = String(rest)
    if rest < 10:
        tail = String("00", rest)
    elif rest < 100:
        tail = String("0", rest)
    return String(_n(v // 1000), ",", tail)


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


def _or_dash(s: String) -> String:
    """`s` escaped, or a muted dash when it's empty."""
    if s.byte_length() == 0:
        return String("<span class=mute>&ndash;</span>")
    return html_escape(s)


def index(req: Request) raises -> Response:
    try:
        var libs = libraries()
        var today = _now_days()
        var h = String(
            "<h1>Mojo libraries</h1><p class=sub>Mojo libraries, versions and growth, counted",
            " from GH Archive by magmalake. Not affiliated with Modular.</p><p class=lead>", len(libs),
            " repositories found in GH Archive, biggest first. Size is lines of",
            " Mojo at the last commit read; age is since GitHub created the",
            " repository.</p>",
        )
        if len(libs) == 0:
            h.write(
                _empty(
                    "No libraries yet",
                    "The lake is still filling. The pipelines read GH Archive an hour at a"
                    " time and write a row here for each repository they find Mojo in,"
                    " so this page fills in as they catch up.",
                )
            )
            return _page("", h^, "libraries")
        h.write(
            "<div class=tbl><table><thead><tr><th>Repository</th>",
            "<th class=num>Lines of Mojo</th><th class=num>Files</th>",
            "<th class=num>Commits</th><th>Age</th><th>Created</th>",
            "<th>Mojo version</th><th>Tooling</th><th class=num>Stars</th>",
            "<th>Found by</th></tr></thead><tbody>",
        )
        for ref l in libs:
            var lines = _n(l.mojo_lines) if l.commits > 0 else String("<span class=mute>not read</span>")
            h.write(
                "<tr><td><a class=repo href='/repos/", html_escape(l.repo), "'>", html_escape(l.repo),
                "</a></td><td class=num>", lines, "</td><td class=num>",
                _n(l.mojo_files), "</td><td class=num>", l.commits, "</td><td>",
                _age(l.created_at, today), "</td><td>", day(l.created_at),
                "</td><td class='mono soft'>", _or_dash(l.mojo_version), "</td><td>",
                _or_dash(l.tooling), "</td><td class=num>", _n(l.stars),
                "</td><td class='mute soft'>", html_escape(l.found_by), "</td></tr>",
            )
        h.write("</tbody></table></div>")
        return _page("", h^, "libraries")
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
            "<h1>Mojo versions over time</h1><p class=lead>Each month, how many",
            " libraries moved to each Mojo version (from their lock file, or",
            " their manifest when there's no lock), in Mojo's own order across",
            " the renumbering: 24.x, 25.x, 0.25.x, 0.26.x, 1.x.</p>",
        )
        if len(rows) == 0:
            h.write(
                _empty(
                    "No migrations yet",
                    "A version shows up here once a library's lock file has been read at"
                    " more than one commit and the Mojo version changed between them."
                    " The lake is still filling.",
                )
            )
            return _page("Versions", h^, "versions")
        # The month cell spans its rows; the bar is against the busiest row.
        var per_month = Dict[String, Int]()
        var top = 1
        for ref r in rows:
            per_month[r.month] = per_month.get(r.month, 0) + 1
            if r.repos > top:
                top = r.repos
        h.write(
            "<div class=tbl><table><thead><tr><th>Month</th><th>Version</th>",
            "<th>Libraries</th></tr></thead><tbody>",
        )
        var last_month = String()
        for ref r in rows:
            h.write("<tr>")
            if r.month != last_month:
                last_month = r.month
                h.write(
                    "<td class=month rowspan=", per_month[r.month], ">", html_escape(r.month), "</td>"
                )
            h.write(
                "<td class=mono>", html_escape(r.version), "</td><td><div class=bar><span>",
                r.repos, "</span><i style='width:", r.repos * 100 // top,
                "%' aria-hidden=true></i></div></td></tr>",
            )
        h.write("</tbody></table></div>")
        return _page("Versions", h^, "versions")
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
    """Lines of Mojo over time, as an SVG polyline with the area under it."""
    if len(points) < 2:
        return String(
            "<div class=card><p class=mute>Too few commits read to draw a line.</p></div>"
        )
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
        "<div class=card><svg viewBox='-4 -4 ", w + 8, " ", h + 8,
        "' role=img aria-label='lines of Mojo over time'>",
        "<polygon fill='var(--ember)' fill-opacity='.12' points='0,", h, " ", pts, w, ",", h, "'/>",
        "<polyline fill=none stroke='var(--ember)' stroke-width=2 stroke-linejoin=round points='", pts, "'/></svg>",
        "<p class=mute>", day(t0), " to ", day(t1), "; peak ", _n(top), " lines</p></div>",
    )


def _stat(label: String, value: String, note: String = "") -> String:
    """One tile of the title block; `value` and `note` are already escaped."""
    return String(
        "<div class=stat><b>", label, "</b><span>", value, "</span>",
        String("<small>", note, "</small>") if note.byte_length() > 0 else String(),
        "</div>",
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
        var today = _now_days()
        var gh = String("https://github.com/", html_escape(repo))
        var h = String(
            "<div class=head><h1><span class=owner>", html_escape(req.param("owner")),
            " /</span> ", html_escape(req.param("name")), "</h1>",
            "<p class=desc>", html_escape(l.description), "</p>",
            "<p class=meta><a href='", gh, "' rel=noopener>GitHub &#8599;</a> &middot; first seen in GH Archive ",
            day(l.first_seen), " (", html_escape(l.found_by), ")",
            " &middot; ", _n(l.mojo_lines), " lines of Mojo in ", _n(l.mojo_files), " files at the last of ",
            l.commits, " commits (", day(l.first_commit), " to ", day(l.last_commit), ")</p>",
            "<div class=stats>",
            _stat("Stars", _n(l.stars)), _stat("Forks", _n(l.forks)),
            _stat("Created", day(l.created_at), String(_age(l.created_at, today), " ago") if l.created_at else String()),
            _stat("Lines of Mojo", _n(l.mojo_lines), String(_n(l.mojo_files), " files")),
            _stat("Commits", _n(Int64(l.commits)), String(day(l.first_commit), " to ", day(l.last_commit)) if l.commits > 0 else String()),
            _stat("Mojo version", _or_dash(l.mojo_version)),
            _stat("Tooling", _or_dash(l.tooling)),
            _stat("License", _or_dash(l.license)),
            "</div></div>",
            "<h2>Lines of Mojo</h2>", _chart(pts),
            "<h2>Migrations</h2>",
        )
        if len(ms) == 0:
            h.write(_empty("No migrations recorded", "No change of Mojo version or tooling between the commits read so far."))
        else:
            h.write(
                "<div class=tbl><table><thead><tr><th>Date</th><th>What</th><th>From</th><th>To</th>",
                "<th>Commit</th></tr></thead><tbody>",
            )
            for ref m in ms:
                h.write(
                    "<tr><td>", day(m.at), "</td><td>", html_escape(m.kind), "</td><td class=mono>",
                    _or_dash(m.from_value), "</td><td class=mono>", _or_dash(m.to_value),
                    "</td><td><a class=mono href='", gh, "/commit/", html_escape(m.sha), "' rel=noopener>",
                    html_escape(String(m.sha[byte=:10])), "</a></td></tr>",
                )
            h.write("</tbody></table></div>")
        h.write("<h2>Commits</h2>")
        if len(pts) == 0:
            h.write(_empty("No commits read yet", "The history pipeline hasn't reached this repository."))
        else:
            h.write(
                "<div class=tbl><table><thead><tr><th>Date</th><th>Commit</th>",
                "<th class=num>Lines of Mojo</th><th>Tooling</th><th>Mojo version</th></tr></thead><tbody>",
            )
            var i = len(pts)
            var stop = max(i - COMMITS_SHOWN, 0)
            while i > stop:
                i -= 1
                ref p = pts[i]
                h.write(
                    "<tr><td>", day(p.at), "</td><td><a class=mono href='", gh, "/commit/",
                    html_escape(p.sha), "' rel=noopener>", html_escape(String(p.sha[byte=:10])),
                    "</a></td><td class=num>", _n(p.lines), "</td><td>", _or_dash(p.tooling),
                    "</td><td class=mono>", _or_dash(p.version), "</td></tr>",
                )
            h.write("</tbody></table></div>")
            if len(pts) > COMMITS_SHOWN:
                h.write(
                    "<p class=mute>The latest ", COMMITS_SHOWN, " of ", len(pts),
                    " commits; all of them are in <a href='/api/repos/", html_escape(repo), "'>the JSON</a>.</p>",
                )
        return _page(repo, h^, "libraries")
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
