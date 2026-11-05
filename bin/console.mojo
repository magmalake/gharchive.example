"""The console: a flare app over mojo.repos, mojo.commits, mojo.migrations,
mojo.repo_stats, mojo.activity, mojo.releases and mojo.tags.

    PORT=8080 pixi run ./build/console

Pages: `/` the libraries by size and age (`?sort=stars` for the most starred
first), `/search?q=` finds libraries by name, GitHub topic or description, `/versions` the
migrations to each Mojo version over time, `/how` and `/how/optimizations`
how the census is built, `/repos/<owner>/<name>` one library. The data pages
have JSON at `/api/...`. Every request scans the tables again; they're small.

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
    MonthActivity,
    Point,
    Release,
    VersionMonth,
    activity_by_month,
    activity_months,
    day,
    history,
    libraries,
    migrations,
    releases,
    versions_by_month,
)
from days import day_text
from search import search_score, sort_families, url_decode, version_family
from versions import sort_versions

comptime STYLE = """
.prose{max-width:72ch}.prose p,.prose li{line-height:1.6}.prose ul{padding-left:1.2em}.prose li{margin:6px 0}
*{box-sizing:border-box}
:root{color-scheme:light;--bg:#fbf9f7;--bg-alt:#f4f0ec;--surface:#fff;--surface-2:#f8f5f2;--border:#e3dcd4;--border-strong:#cfc5ba;--text:#17151a;--muted:#6b645d;--faint:#948c84;--ember:#c33c10;--ember-wash:#fdefe7;--lake:#0d6a70;--c0:#2b6cb0;--c1:#c33c10;--c2:#0d8a5a;--c3:#8e44ad;--c4:#a16207;--c5:#5b6770;--shadow:0 1px 2px rgb(23 21 26 / .04),0 8px 24px -12px rgb(23 21 26 / .12);--radius:10px;--radius-sm:6px;--mono:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace}
@media (prefers-color-scheme:dark){:root{color-scheme:dark;--bg:#0e0d11;--bg-alt:#131218;--surface:#17161d;--surface-2:#1c1b23;--border:#2a2833;--border-strong:#3d3a48;--text:#eeeae4;--muted:#a49d95;--faint:#7b746d;--ember:#ff7a45;--ember-wash:#2a1710;--lake:#4ecdc4;--c0:#6aa9ff;--c1:#ff7a45;--c2:#4ecdc4;--c3:#c39bf0;--c4:#e3b341;--c5:#a9b4bd;--shadow:0 1px 2px rgb(0 0 0 / .4),0 8px 24px -12px rgb(0 0 0 / .6)}}
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
.search{flex:1;max-width:300px;min-width:0}
.search input{width:100%;font:inherit;font-size:14px;color:var(--text);background:var(--surface);border:1px solid var(--border-strong);border-radius:var(--radius-sm);padding:5px 10px}
.search input:focus{outline:2px solid var(--lake);outline-offset:1px}
.tabs{display:flex;gap:4px;border-bottom:1px solid var(--border);margin:0 0 24px;overflow-x:auto}
.tabs a{color:var(--muted);padding:8px 14px;border-bottom:2px solid transparent;margin-bottom:-1px;white-space:nowrap}
.tabs a:hover{color:var(--text);text-decoration:none}
.tabs a[aria-current=page]{color:var(--text);border-bottom-color:var(--ember);font-weight:600}
td.what{white-space:normal;min-width:30ch}
.card text{fill:var(--muted);font:11px var(--mono)}
.card .grid{stroke:var(--border);stroke-width:1}
.legend{display:flex;flex-wrap:wrap;gap:4px 18px;list-style:none;padding:0;margin:12px 0 0;font-size:13px}
.legend i{display:inline-block;width:14px;height:3px;border-radius:2px;margin-right:6px;vertical-align:middle}
.sort{margin:-8px 0 14px;font-size:13px}
.note{max-width:72ch}
.chips{display:flex;flex-wrap:wrap;gap:4px;margin-top:4px;white-space:normal;max-width:46ch}
.chip{display:inline-block;font:500 11.5px/1.5 var(--mono);color:var(--muted);background:var(--surface-2);border:1px solid var(--border);border-radius:999px;padding:0 8px}
a.chip:hover{color:var(--text);border-color:var(--border-strong);text-decoration:none}
.head .chips{margin:0 0 14px;max-width:none}
@media (max-width:640px){.top .wrap{gap:12px;flex-wrap:wrap;height:auto;padding-block:8px}.search{order:3;flex-basis:100%;max-width:none}.top nav{gap:12px}.top nav .sep,.top nav .arrow{display:none}.brand{font-size:15px}h1{font-size:24px}th,td{padding:9px 10px}main{padding-top:24px}footer nav{margin-left:0}}
"""

comptime COMMITS_SHOWN = 50
"""How many of a repository's commits the page lists; the JSON has all."""

comptime MARK = (
    "<svg width=20 height=20 viewBox='0 0 16 16' fill=none aria-hidden=true>"
    "<rect width=16 height=16 rx=3 fill='#b45309'/>"
    "<rect x=3 y=8 width=2.5 height=5 fill='#fff'/>"
    "<rect x=6.75 y=4 width=2.5 height=9 fill='#fff'/>"
    "<rect x=10.5 y=6 width=2.5 height=7 fill='#fff'/></svg>"
)
"""The tab icon's amber square with three white bars: reads on both themes."""


def _nav(href: String, label: String, current: Bool) -> String:
    return String(
        "<a href='", href, "'", " aria-current=page" if current else "", ">", label, "</a>"
    )


comptime BRAND = "Mojo census"

comptime DESCRIPTION = (
    "Mojo libraries, versions and growth, counted from GH Archive by"
    " magmalake. An independent project, not affiliated with Modular."
)


def _page(
    title: String, var body: String, section: String, q: String = ""
) raises -> Response:
    """The page around `body`; `section` is `libraries`, `versions` or `how`, the
    nav entry to light up (none for search); `q` fills the search box. An empty `title` is the home page, titled with
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
        "<form class=search action='/search' role=search><input type=search name=q value='",
        html_escape(q), "' placeholder='Search libraries' aria-label='Search libraries'",
        " autocomplete=off></form>",
        "<nav>", _nav("/", "Libraries", section == "libraries"),
        _nav("/versions", "Versions", section == "versions"),
        _nav("/how", "How it works", section == "how"),
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


def _chips(topics: List[String], limit: Int = 6) -> String:
    """GitHub topics as chips, each a search for it."""
    if len(topics) == 0:
        return String()
    var h = String("<div class=chips>")
    for i in range(min(len(topics), limit)):
        h.write(
            "<a class=chip href='/search?q=", html_escape(topics[i]), "'>",
            html_escape(topics[i]), "</a>",
        )
    if len(topics) > limit:
        h.write("<span class=chip>+", len(topics) - limit, "</span>")
    h.write("</div>")
    return h^


def _libs_table(libs: List[Library], today: Int) -> String:
    """The Libraries table, in the order of `libs`; the home page and the
    search results both draw it."""
    var h = String(
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
            "</a>", _chips(l.topics), "</td><td class=num>", lines, "</td><td class=num>",
            _n(l.mojo_files), "</td><td class=num>", l.commits, "</td><td>",
            _age(l.created_at, today), "</td><td>", day(l.created_at),
            "</td><td class='mono soft'>", _or_dash(l.mojo_version), "</td><td>",
            _or_dash(l.tooling), "</td><td class=num>", _n(l.stars),
            "</td><td class='mute soft'>", html_escape(l.found_by), "</td></tr>",
        )
    h.write("</tbody></table></div>")
    return h^


def _by_stars(var libs: List[Library]) -> List[Library]:
    """Most starred first; ties stay in the order they came (biggest first)."""
    for i in range(1, len(libs)):
        var j = i
        while j > 0 and libs[j - 1].stars < libs[j].stars:
            libs.swap_elements(j - 1, j)
            j -= 1
    return libs^


def index(req: Request) raises -> Response:
    try:
        var libs = libraries()
        var by_stars = req.query_param("sort") == "stars"
        if by_stars:
            libs = _by_stars(libs^)
        var today = _now_days()
        var h = String(
            "<h1>Mojo libraries</h1><p class=sub>Mojo libraries, versions and growth, counted",
            " from GH Archive by magmalake. Not affiliated with Modular.</p><p class=lead>", len(libs),
            " repositories found in GH Archive, ",
            "most starred first" if by_stars else "biggest first",
            ". Size is lines of Mojo at the last commit read; age is since GitHub",
            " created the repository.</p>",
        )
        if len(libs) > 1:
            h.write(
                "<p class=sort>Sorted by ",
                "stars &middot; <a href='/'>sort by size</a>" if by_stars
                else "size &middot; <a href='/?sort=stars'>sort by stars</a>",
                "</p>",
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
        h.write(_libs_table(libs, today))
        return _page("", h^, "libraries")
    except e:
        return internal_error(String(e))


def _matches(query: String) raises -> List[Library]:
    """The libraries matching `query`, best match first; equal matches keep
    the Libraries order (biggest first)."""
    var hits = List[Library]()
    var scores = List[Int]()
    for ref l in libraries():
        var sc = search_score(l.repo, l.description, query, l.topics)
        if sc > 0:
            hits.append(l.copy())
            scores.append(sc)
    for i in range(1, len(hits)):
        var j = i
        while j > 0 and scores[j - 1] < scores[j]:
            scores.swap_elements(j - 1, j)
            hits.swap_elements(j - 1, j)
            j -= 1
    return hits^


def search(req: Request) raises -> Response:
    try:
        var q = String(url_decode(req.query_param("q")).strip())
        var h = String("<h1>Search</h1>")
        if q.byte_length() == 0:
            h.write(
                _empty(
                    "Search the libraries",
                    "Type part of a repository name, topic or description in the box above,"
                    " for example flare or http. Names that match best come first.",
                )
            )
            return _page("Search", h^, "search")
        var hits = _matches(q)
        h.write(
            "<p class=lead>", len(hits), " ", "library" if len(hits) == 1 else "libraries",
            " matching &ldquo;", html_escape(q), "&rdquo; in the repository name, GitHub topics or description.</p>",
        )
        if len(hits) == 0:
            h.write(_empty("No libraries match", "Try a shorter word, or part of the owner or the name."))
        else:
            h.write(_libs_table(hits, _now_days()))
        return _page(String("Search: ", q), h^, "search", q)
    except e:
        return internal_error(String(e))


def search_json(req: Request) raises -> Response:
    try:
        var q = String(url_decode(req.query_param("q")).strip())
        var out = String("[")
        if q.byte_length() > 0:
            var first = True
            for ref l in _matches(q):
                if not first:
                    out += ","
                first = False
                out += _lib_json(l)
        out += "]"
        return ok_json(out)
    except e:
        return internal_error(String(e))


def _strs_json(items: List[String]) -> String:
    var out = String("[")
    for i in range(len(items)):
        if i > 0:
            out += ","
        out += _q(items[i])
    out += "]"
    return out^


def _lib_json(l: Library) -> String:
    return String(
        '{"repo":', _q(l.repo), ',"description":', _q(l.description),
        ',"created_at":', _q(micros_to_iso(l.created_at) if l.created_at else ""),
        ',"first_seen":', _q(micros_to_iso(l.first_seen)),
        ',"found_by":', _q(l.found_by), ',"stars":', l.stars,
        ',"forks":', l.forks, ',"license":', _q(l.license),
        ',"size_kb":', l.size_kb, ',"commits":', l.commits,
        ',"mojo_lines":', l.mojo_lines, ',"mojo_files":', l.mojo_files,
        ',"tooling":', _q(l.tooling), ',"mojo_version":', _q(l.mojo_version),
        ',"topics":', _strs_json(l.topics),
        ',"stats_as_of":', _q(day_text(l.stats_as_of) if l.stats_as_of > 0 else ""),
        ',"open_issues":', l.open_issues, ',"watchers":', l.watchers,
        ',"archived":', "true" if l.archived else "false",
        ',"state":', _q(l.state), ',"renamed_to":', _q(l.renamed_to), "}",
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


def _next_month(m: String) raises -> String:
    """`2025-12` -> `2026-01`."""
    var y = Int(m[byte=:4])
    var mo = Int(m[byte=5:7])
    if mo == 12:
        return String(y + 1, "-01")
    return String(y, "-", "0" if mo < 9 else "", mo + 1)


def _series_key(v: String, by_family: Bool) -> String:
    return version_family(v) if by_family else v


def _versions_chart(rows: List[VersionMonth]) raises -> String:
    """Libraries migrating each month as one line per Mojo version family (or
    per version when there are at most six), as inline SVG with a legend."""
    var versions = List[String]()
    for ref r in rows:
        if r.version not in versions:
            versions.append(r.version)
    sort_versions(versions)
    var by_family = len(versions) > 6
    var names = List[String]()
    var oldest = List[String]()
    for ref v in versions:
        var k = _series_key(v, by_family)
        if k not in names:
            names.append(k)
            oldest.append(v)
    if by_family:
        sort_families(names, oldest)
    var months = List[String]()
    var m = rows[0].month
    var last = rows[len(rows) - 1].month
    months.append(m)
    while m < last:
        m = _next_month(m)
        months.append(m)
    var counts = Dict[String, Int]()
    var top = 1
    for ref r in rows:
        var k = String(_series_key(r.version, by_family), "|", r.month)
        var c = counts.get(k, 0) + r.repos
        counts[k] = c
        if c > top:
            top = c
    return _line_chart(
        months, names, counts, top,
        String("Line chart: libraries migrating to each Mojo version family"),
        String(
            "Libraries migrating to each Mojo ", "version family" if by_family else "version",
            " per month, ", months[0], " to ", last,
        ),
        String("Libraries per month; a library that moved twice in a month counts for each version."),
    )


def _line_chart(
    months: List[String],
    names: List[String],
    counts: Dict[String, Int],
    top: Int,
    aria: String,
    title: String,
    note: String,
) raises -> String:
    """One line per name over `months`, from `counts` (`name|month`), as
    inline SVG with a legend; the versions and the stars charts draw it."""
    var last = months[len(months) - 1]
    var left = 36
    var right = 12
    var up = 10
    var w = 900
    var h = 240
    var pw = w - left - right
    var ph = h - up - 30
    var n = len(months)
    var svg = String(
        "<svg viewBox='0 0 ", w, " ", h, "' role=img aria-label='", html_escape(aria),
        "'><title>", html_escape(title), "</title>",
    )
    # Gridlines and the Y axis: 0, the middle if there's room, the top.
    var ticks = List[Int]()
    ticks.append(0)
    if top >= 4:
        ticks.append(top // 2)
    ticks.append(top)
    for t in ticks:
        var y = up + ph - t * ph // top
        svg.write(
            "<line class=grid x1=", left, " x2=", w - right, " y1=", y, " y2=", y, "/>",
            "<text x=", left - 6, " y=", y + 4, " text-anchor=end>", t, "</text>",
        )
    # X labels, thinned to about twelve.
    var every = (n + 11) // 12
    for i in range(n):
        var x = left + (pw // 2 if n == 1 else i * pw // (n - 1))
        if i % every == 0:
            svg.write("<text x=", x, " y=", h - 8, " text-anchor=middle>", months[i], "</text>")
    var legend = String("<ul class=legend>")
    for si in range(len(names)):
        var color = String("var(--c", si % 6, ")")
        var pts = String()
        var dots = String()
        for i in range(n):
            var c = counts.get(String(names[si], "|", months[i]), 0)
            var x = left + (pw // 2 if n == 1 else i * pw // (n - 1))
            var y = up + ph - c * ph // top
            pts.write(x, ",", y, " ")
            if c > 0:
                dots.write("<circle cx=", x, " cy=", y, " r=3 fill='", color, "'/>")
        svg.write(
            "<polyline fill=none stroke='", color, "' stroke-width=2 stroke-linejoin=round points='", pts, "'/>", dots,
        )
        legend.write("<li><i style='background:", color, "'></i>", html_escape(names[si]), "</li>")
    svg.write("</svg>")
    legend.write("</ul>")
    return String(
        "<div class=card>", svg, legend,
        "<p class=mute>", note, "</p></div>",
    )


def versions(req: Request) raises -> Response:
    try:
        var rows = versions_by_month()
        var h = String(
            "<h1>Mojo version migrations</h1><p class=lead>A migration is a library's lock",
            " file (or its manifest, when there's no lock) moving to a Mojo version between",
            " two of its commits. Each number is the libraries whose lock file moved to that",
            " version that month. Versions are in Mojo's own order across the renumbering:",
            " 24.x, 25.x, 0.25.x, 0.26.x, 1.x.</p>",
        )
        if len(rows) == 0:
            h.write(
                _empty(
                    "No migrations yet",
                    "A migration shows up here once a library's lock file has been read at"
                    " more than one commit and the Mojo version changed between them."
                    " The lake is still filling.",
                )
            )
            return _page("Versions", h^, "versions")
        h.write(_versions_chart(rows))
        # The month cell spans its rows; the bar is against the busiest row.
        var per_month = Dict[String, Int]()
        var top = 1
        for ref r in rows:
            per_month[r.month] = per_month.get(r.month, 0) + 1
            if r.repos > top:
                top = r.repos
        h.write(
            "<h2>By month and version</h2>",
            "<div class=tbl><table><thead><tr><th>Month</th><th>Version</th>",
            "<th>Libraries migrating</th></tr></thead><tbody>",
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
            out.write('{"month":', _q(r.month), ',"version":', _q(r.version), ',"family":', _q(version_family(r.version)), ',"libraries":', r.repos, "}")
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


comptime RELEASES_SHOWN = 30


def _stars_chart(repo_months: List[MonthActivity], loaded: List[String]) raises -> String:
    """Stars and forks per month from GH Archive, over the months loaded."""
    var counts = Dict[String, Int]()
    var top = 1
    var total = Int64(0)
    for ref a in repo_months:
        counts[String("stars|", a.month)] = Int(a.stars)
        counts[String("forks|", a.month)] = Int(a.forks)
        top = max(top, Int(a.stars), Int(a.forks))
        total += a.stars
    var names: List[String] = ["stars", "forks"]
    return _line_chart(
        loaded, names, counts, top,
        String("Line chart: stars and forks per month"),
        String("Stars (WatchEvents) and forks per month in GH Archive, ", loaded[0], " to ", loaded[len(loaded) - 1]),
        String(
            _n(total), " stars over the months of GH Archive loaded so far (",
            len(loaded), "; months in between aren't loaded yet), counted from its events.",
        ),
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
            _chips(l.topics, 100),
            "<p class=meta><a href='", gh, "' rel=noopener>GitHub &#8599;</a> &middot; first seen in GH Archive ",
            day(l.first_seen), " (", html_escape(l.found_by), ")",
            " &middot; ", _n(l.mojo_lines), " lines of Mojo in ", _n(l.mojo_files), " files at the last of ",
            l.commits, " commits (", day(l.first_commit), " to ", day(l.last_commit), ")",
            String(" &middot; <strong>archived</strong>") if l.archived else String(),
            String(" &middot; now <a href='https://github.com/", html_escape(l.renamed_to), "' rel=noopener>",
                html_escape(l.renamed_to), "</a>") if l.renamed_to.byte_length() > 0 else String(),
            String(" &middot; GitHub says <strong>", html_escape(l.state), "</strong>")
                if l.state.byte_length() > 0 and l.state != "ok" and l.state != "renamed" else String(),
            "</p><div class=stats>",
            _stat("Stars", _n(l.stars), String("as of ", day_text(l.stats_as_of)) if l.stats_as_of > 0 else String("when found")),
            _stat("Forks", _n(l.forks)),
            _stat("Open issues", _n(l.open_issues)) if l.stats_as_of > 0 else String(),
            _stat("Watchers", _n(l.watchers)) if l.stats_as_of > 0 else String(),
            _stat("Created", day(l.created_at), String(_age(l.created_at, today), " ago") if l.created_at else String()),
            _stat("Lines of Mojo", _n(l.mojo_lines), String(_n(l.mojo_files), " files")),
            _stat("Commits", _n(Int64(l.commits)), String(day(l.first_commit), " to ", day(l.last_commit)) if l.commits > 0 else String()),
            _stat("Mojo version", _or_dash(l.mojo_version)),
            _stat("Tooling", _or_dash(l.tooling)),
            _stat("License", _or_dash(l.license)),
            "</div></div>",
            "<h2>Lines of Mojo</h2>", _chart(pts),
            "<h2>Stars per month</h2>",
        )
        var loaded = activity_months()
        if len(loaded) == 0:
            h.write(_empty("No activity yet", "The activity pipeline hasn't counted this repository's GH Archive events yet."))
        else:
            h.write(_stars_chart(activity_by_month(repo), loaded))
        h.write("<h2>Releases and tags</h2>")
        var rels = releases(repo)
        if len(rels) == 0:
            h.write(_empty("No releases or tags", "No published release in the GH Archive days loaded, and no git tag in the clone."))
        else:
            h.write(
                "<div class=tbl><table><thead><tr><th>Date</th><th>Tag</th><th>Name</th>",
                "<th>From</th><th>Mojo version</th><th>Commit</th></tr></thead><tbody>",
            )
            for i in range(min(len(rels), RELEASES_SHOWN)):
                ref x = rels[i]
                var commit = String("<span class=mute>&ndash;</span>")
                if x.commit.byte_length() > 0:
                    commit = String(
                        "<a class=mono href='", gh, "/commit/", html_escape(x.commit), "' rel=noopener>",
                        html_escape(String(x.commit[byte=:10])), "</a>",
                    )
                h.write(
                    "<tr><td>", day(x.at), "</td><td class='mono soft'><a href='", gh, "/releases/tag/",
                    html_escape(x.tag), "' rel=noopener>", html_escape(x.tag), "</a>",
                    " <span class=chip>pre-release</span>" if x.prerelease else "",
                    "</td><td class=soft>", _or_dash(x.name), "</td><td>",
                    "GitHub release" if x.source == "release" else "git tag",
                    "</td><td class=mono>", _or_dash(x.mojo_version), "</td><td>", commit, "</td></tr>",
                )
            h.write("</tbody></table></div>")
            if len(rels) > RELEASES_SHOWN:
                h.write(
                    "<p class=mute>The latest ", RELEASES_SHOWN, " of ", len(rels),
                    "; all of them are in <a href='/api/repos/", html_escape(repo), "'>the JSON</a>.</p>",
                )
        h.write("<h2>Migrations</h2>")
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
        out += '],"activity":['
        first = True
        for ref a in activity_by_month(repo):
            if not first:
                out += ","
            first = False
            out.write(
                '{"month":', _q(a.month), ',"stars":', a.stars, ',"forks":', a.forks,
                ',"releases":', a.releases, ',"issues_opened":', a.issues_opened,
                ',"prs_opened":', a.prs_opened, ',"pushes":', a.pushes,
                ',"days_active":', a.days_active, "}",
            )
        out += '],"releases":['
        first = True
        for ref x in releases(repo):
            if not first:
                out += ","
            first = False
            out.write(
                '{"tag":', _q(x.tag), ',"name":', _q(x.name), ',"at":',
                _q(micros_to_iso(x.at) if x.at else ""), ',"prerelease":',
                "true" if x.prerelease else "false", ',"source":', _q(x.source),
                ',"commit":', _q(x.commit), ',"mojo_version":', _q(x.mojo_version), "}",
            )
        out += "]}"
        return ok_json(out)
    except e:
        return internal_error(String(e))


comptime ORCA_DOCS = "https://mlake.dev/s/orca/docs"
comptime ORCA_UI = "https://orca.mlake.dev"
comptime GH = "https://github.com/magmalake"

comptime HOW = (
    "<div class=prose><p class=lead>The census is five"
    " pipelines and this page, all Mojo. The pipelines run on <a href='"
    + ORCA_DOCS
    + "' rel=noopener>orca</a>, magmalake's pipeline orchestrator, on AWS; they"
    " write Iceberg tables to S3, and this site reads them.</p>"
    "<ul><li><a href='"
    + ORCA_UI
    + "/pipelines/gharchive' rel=noopener>gharchive</a> loads each day of"
    " <a href='https://www.gharchive.org' rel=noopener>GH Archive</a>, every"
    " public GitHub event, into <code>gharchive.events</code> at 03:00 UTC for"
    " the day before. Each hour is a <a href='https://mlake.dev/s/dista/docs'"
    " rel=noopener>dista</a> task on a worker instance, which downloads, gunzips,"
    " parses and writes its Parquet files; the step commits the hours in order.</li>"
    "<li><a href='"
    + ORCA_UI
    + "/pipelines/mojo_repos' rel=noopener>mojo_repos</a> is a sensor on that"
    " table. For each new day it finds the repositories that might hold Mojo,"
    " checks them with GitHub, and keeps the Mojo ones in <code>mojo.repos</code>.</li>"
    "<li><a href='"
    + ORCA_UI
    + "/pipelines/mojo_history' rel=noopener>mojo_history</a> is keyed by"
    " repository: each new one is cloned and its history read, the Mojo files"
    " and lines at each commit into <code>mojo.commits</code> and each change of"
    " Mojo version in its lock file into <code>mojo.migrations</code>, and its"
    " git tags into <code>mojo.tags</code>.</li>"
    "<li><a href='"
    + ORCA_UI
    + "/pipelines/mojo_activity' rel=noopener>mojo_activity</a> counts each"
    " library's GH Archive events per day, with no API calls: stars, forks,"
    " releases, issues and pull requests opened, pushes and people, into"
    " <code>mojo.activity</code> and <code>mojo.releases</code>. A library found"
    " today is read back over every day already loaded, so its history is"
    " complete.</li>"
    "<li><a href='"
    + ORCA_UI
    + "/pipelines/mojo_stats' rel=noopener>mojo_stats</a> asks GitHub about every"
    " library each Monday (one request each) and keeps the stars, forks, issues"
    " and topics week by week in <code>mojo.repo_stats</code>.</li></ul>"
    "<p>Every run, with its steps, logs, machines and the tables it wrote, is on"
    " <a href='"
    + ORCA_UI
    + "/runs' rel=noopener>orca.mlake.dev</a>. The orca docs cover <a href='"
    + ORCA_DOCS
    + "/build' rel=noopener>writing a pipeline</a>, <a href='"
    + ORCA_DOCS
    + "/run' rel=noopener>running it</a>, <a href='"
    + ORCA_DOCS
    + "/ui' rel=noopener>the web UI</a> and <a href='"
    + ORCA_DOCS
    + "/debug' rel=noopener>debugging a failed run</a>; the census's own code"
    " is <a href='"
    + GH
    + "/mojo-census' rel=noopener>magmalake/mojo-census</a>, and the <a"
    " href='https://mlake.dev/getting-started/' rel=noopener>getting-started"
    " guide</a> builds it from scratch.</p>"
    "<p>How the pipelines got faster, with the measurements, is on the <a"
    " href='/how/optimizations'>Optimizations</a> tab.</p></div>"
)


def _how_head(current: String) -> String:
    """The title and the tabs shared by the two How it works pages."""
    return String(
        "<h1>How it works</h1><nav class=tabs aria-label='How it works'>",
        _nav("/how", "Overview", current == "overview"),
        _nav("/how/optimizations", "Optimizations", current == "optimizations"),
        "</nav>",
    )


def _link(href: String, text: String) -> String:
    return String("<a href='", href, "' rel=noopener>", text, "</a>")


def _change(
    what: String, did: String, measured: String, prs: String
) -> String:
    """A row of the changes table; every cell is HTML."""
    return String(
        "<tr><td class=what>", what, "</td><td class='what'>", did,
        "</td><td class=soft>", measured, "</td><td>", prs, "</td></tr>",
    )


def _stage(name: String, before: String, after: String) -> String:
    return String(
        "<tr><td>", name, "</td><td class=num>", before, "</td><td class=num>", after, "</td></tr>"
    )


def how(req: Request) raises -> Response:
    return _page("How it works", _how_head("overview") + String(HOW), "how")


def optimizations(req: Request) raises -> Response:
    var pr_census = String(GH, "/mojo-census/pull/4")
    var pr_parquet = String(GH, "/parquet.mojo/pull/59")
    var pr_ice71 = String(GH, "/iceberg.mojo/pull/71")
    var h = _how_head("optimizations")
    h.write(
        "<p class=lead>The first runs on AWS showed each hour's task bound to one of the worker's",
        " four cores, with the Parquet write its largest stage. These changes spread the work",
        " over the cores and stopped copying it; each row links its pull request and the",
        " measurement table in its description.</p>",
        "<h2>One gharchive hour on AWS</h2>",
        "<p class=sub>c7g.xlarge workers, about 85,000 events an hour, median of 24 hours.</p>",
        "<div class=tbl><table><thead><tr><th>Stage</th><th class=num>Before (",
        _link(String(ORCA_UI, "/runs/36"), "run 36"), ")</th><th class=num>After (",
        _link(String(ORCA_UI, "/runs/48"), "run 48"), ")</th></tr></thead><tbody>",
        _stage("task", "1,094 ms", "680 ms"),
        _stage("download", "172 ms", "130 ms"),
        _stage("gunzip", "210 ms", "154 ms"),
        _stage("parse", "160 ms", "134 ms"),
        _stage("write", "570 ms", "256 ms"),
        _stage("commit", "486 ms", "683 ms"),
        "</tbody></table></div>",
        "<p class='mute note'>Commit time grows with the table's snapshot count: ",
        _link(String(ORCA_UI, "/runs/133"), "run 133"),
        ", after the latest release, measured 1,207 ms for the commit with the other stages",
        " unchanged. Under investigation.</p>",
        "<h2>The changes</h2><div class=tbl><table><thead><tr><th>Change</th><th>What it did</th>",
        "<th>Measured (Apple M4)</th><th>PR</th></tr></thead><tbody>",
        _change(
            "mojo-census #4",
            "Streams each hour through gunzip and parsing as it downloads, and writes Parquet on the workers.",
            _link(pr_census + "#six-hours-local-server", "Six hours locally, 10.3 s to 4.5 s with 4 tasks"),
            _link(pr_census, "#4"),
        ),
        _change(
            "parquet #59",
            "Streams row groups, splits string pages by size, encodes pages on threads.",
            _link(
                pr_parquet + "#measurements-apple-m4-mojo-120",
                "50,000-row batch encode 198 to 81 ms (4 threads), peak 828 to 463 MB",
            ),
            _link(pr_parquet, "#59"),
        ),
        _change(
            "iceberg #71",
            "Writes a batch without copying it.",
            _link(
                pr_ice71 + "#measurements-apple-m4-mojo-120",
                "One hour 838&ndash;855 to 783&ndash;804 ms, peak 1.30&ndash;1.51 to 0.96&ndash;0.97 GB",
            ),
            _link(pr_ice71, "#71"),
        ),
        _change(
            "iceberg #72",
            "Writes through the streaming writer on every core.",
            "One hour to 375 ms, peak about 0.5 GB (with #59, 4 threads)",
            _link(String(GH, "/iceberg.mojo/pull/72"), "#72"),
        ),
        _change(
            "deflate #10, #12",
            "Streaming inflate, and a faster decode loop.",
            _link(
                String(GH, "/deflate.mojo/pull/12#numbers-apple-m4"),
                "Gunzip of an hour 553 to 336 ms (1.46 GB/s)",
            ),
            String(
                _link(String(GH, "/deflate.mojo/pull/10"), "#10"), ", ",
                _link(String(GH, "/deflate.mojo/pull/12"), "#12"),
            ),
        ),
        _change(
            "iceberg #70 + orca #114",
            "Workers hand their data files to the step to commit (<code>append_files</code>), which removes the census's own DataFile codec.",
            "<span class=mute>&ndash;</span>",
            String(
                _link(String(GH, "/iceberg.mojo/pull/70"), "iceberg #70"), ", ",
                _link(String(GH, "/orca.mojo/pull/114"), "orca #114"),
            ),
        ),
        "</tbody></table></div>",
    )
    return _page("Optimizations", h^, "how")


def main() raises:
    var r = Router()
    r.get("/", index)
    r.get("/versions", versions)
    r.get("/how", how)
    r.get("/how/optimizations", optimizations)
    r.get("/search", search)
    r.get("/repos/:owner/:name", repo_page)
    r.get("/api/repos", index_json)
    r.get("/api/versions", versions_json)
    r.get("/api/search", search_json)
    r.get("/api/repos/:owner/:name", repo_json)
    var addr = String("0.0.0.0:", getenv("PORT", "8080"))
    var server = HttpServer.bind(SocketAddr.parse(addr), ServerConfig())
    print("console on http://", addr, sep="")
    server.serve(r^)
