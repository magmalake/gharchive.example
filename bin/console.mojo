"""The console: a flare app over mojo.repos, mojo.commits, mojo.migrations,
mojo.repo_stats, mojo.activity, mojo.releases and mojo.tags.

    PORT=8080 pixi run ./build/console

Pages: `/` the overview (cards, repos per Mojo version, growth curves),
`/repos` the repos by size and age (`?sort=lines|files|stars&dir=asc|desc`,
`?version=1.x`, `?active=1y`), `/search?q=` finds repos by name, GitHub topic
or description, `/migrations` the migrations to each Mojo version over time,
`/how` and `/how/optimizations` how the census is built,
`/repos/<owner>/<name>` one repo. The data pages have JSON at `/api/...`.

The repos and the overview are computed and kept (`Cache`), and a background
thread keeps them fresh: every `CONSOLE_REFRESH_SECONDS` (default 1800) it
looks at the tables' current snapshots and, only when one moved or the UTC day
changed, builds a new `Cache` beside the old one and swaps it in. Requests
always read the current one and never wait for a build; until the first build
finishes they get a "warming up" page (503).
The per-repo data (commits, migrations, releases, activity) and the
Migrations page are read and rendered at the same time.

The look follows mlake.dev: its warm-ash neutrals, ember accent and lake
links, on the system font stack (no external fonts or scripts).
"""

from std.memory.alloc import unsafe_alloc
from std.os import getenv
from std.memory import ArcPointer
from std.time import sleep

from flare.http import (
    Handler,
    HttpServer,
    Request,
    Response,
    Router,
    ServerConfig,
    html_escape,
    internal_error,
    not_found,
    ok_json,
    redirect,
)
from flare.net import SocketAddr
from orca.civil import now
from threads import OpaquePtr, ThreadHandle

from charts import compact, donut, line_chart
from jscan import micros_to_iso
from listing import (
    NEW_30D,
    NEW_LAST_MONTH,
    NEW_MONTH,
    ListQuery,
    list_url,
    new_bit,
    parse_list_query,
    select_repos,
    sorted_by,
    with_active,
    with_new,
    with_version,
)
from model import (
    Library,
    Migration,
    MonthActivity,
    Point,
    Release,
    Sources,
    VersionMonth,
    activity_all,
    activity_months,
    day,
    histories,
    libraries,
    migrations,
    read_days,
    read_sources,
    releases_all,
    star_gains,
    versions_of,
)
from days import day_text
from overview import ACTIVE_DAYS, Builder, Overview, bucket_color, bucket_of, family_of, month_of_days, top_gains
from swap import Swap, check_due, needs_build
from search import search_score, sort_buckets, url_decode, version_bucket, version_family
from versions import sort_versions

comptime STYLE = """
.prose{max-width:72ch}.prose p,.prose li{line-height:1.6}.prose ul{padding-left:1.2em}.prose li{margin:6px 0}
*{box-sizing:border-box}
:root{color-scheme:light;--bg:#fbf9f7;--bg-alt:#f4f0ec;--surface:#fff;--surface-2:#f8f5f2;--border:#e3dcd4;--border-strong:#cfc5ba;--text:#17151a;--muted:#6b645d;--faint:#948c84;--ember:#c33c10;--ember-wash:#fdefe7;--lake:#0d6a70;--c0:#2b6cb0;--c1:#c33c10;--c2:#0d8a5a;--c3:#8e44ad;--c4:#a16207;--c5:#5b6770;--c6:#0e7490;--c7:#be185d;--c8:#4d7c0f;--c9:#0369a1;--shadow:0 1px 2px rgb(23 21 26 / .04),0 8px 24px -12px rgb(23 21 26 / .12);--radius:10px;--radius-sm:6px;--mono:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace}
@media (prefers-color-scheme:dark){:root{color-scheme:dark;--bg:#0e0d11;--bg-alt:#131218;--surface:#17161d;--surface-2:#1c1b23;--border:#2a2833;--border-strong:#3d3a48;--text:#eeeae4;--muted:#a49d95;--faint:#7b746d;--ember:#ff7a45;--ember-wash:#2a1710;--lake:#4ecdc4;--c0:#6aa9ff;--c1:#ff7a45;--c2:#4ecdc4;--c3:#c39bf0;--c4:#e3b341;--c5:#a9b4bd;--c6:#5ad1e6;--c7:#f472b6;--c8:#a3d95f;--c9:#7dd3fc;--shadow:0 1px 2px rgb(0 0 0 / .4),0 8px 24px -12px rgb(0 0 0 / .6)}}
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
.early{margin-top:28px}.early>summary{cursor:pointer;font-weight:600;margin-bottom:14px}
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
.kpis{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:10px}
.kpi{display:block;background:var(--surface);border:1px solid var(--border);border-radius:var(--radius);padding:12px 14px;min-width:0;color:var(--text);box-shadow:var(--shadow)}
a.kpi:hover{border-color:var(--border-strong);text-decoration:none}
.kpi b{display:block;color:var(--faint);font:500 11.5px/1.5 var(--mono);letter-spacing:.08em;text-transform:uppercase}
.kpi span{display:block;font-size:26px;font-weight:700;font-variant-numeric:tabular-nums;letter-spacing:-.02em;line-height:1.2;margin-top:2px}
.kpi small{display:block;color:var(--muted);font-size:12.5px}.kpi span a{color:inherit}.kpi small a{color:var(--lake)}
.kpi .up{color:var(--c2)}.kpi .down{color:var(--ember)}
.cols{display:grid;grid-template-columns:repeat(auto-fit,minmax(min(100%,330px),1fr));gap:16px}
.card h3{margin:0 0 4px;font-size:15px;font-weight:600}
.card .donut{max-width:240px;margin:4px auto}
.donut text{fill:var(--muted);font:11px var(--mono)}
.donut text.big{fill:var(--text);font:700 30px ui-sans-serif,system-ui,sans-serif}
.donut a:hover circle{stroke-opacity:.75}
.card svg.lc text{font-size:12.5px}
.legend .sw{display:inline-block;width:10px;height:10px;border-radius:3px;margin-right:6px;vertical-align:baseline}
.legend b{font-variant-numeric:tabular-nums;font-weight:600}
.legend a{color:var(--text)}
.big-stat{font-size:20px;font-weight:600;margin:0 0 4px}
.filters{display:flex;flex-wrap:wrap;gap:6px 14px;align-items:center;margin:0 0 12px;font-size:13px}
.filters .chip{font-size:12.5px;padding:1px 10px}
.filters .on{color:var(--text);background:var(--ember-wash);border-color:var(--ember)}
.filters .label{color:var(--muted)}
th a{color:inherit;display:inline-block}th a:hover{color:var(--text);text-decoration:none}
th[aria-sort] a{color:var(--text)}
.asof{color:var(--muted);font-size:13px;max-width:78ch;margin-top:28px}
@media (max-width:640px){.kpi span{font-size:22px}.top .wrap{gap:12px;flex-wrap:wrap;height:auto;padding-block:8px}.search{order:3;flex-basis:100%;max-width:none}.top nav{gap:12px}.top nav .sep,.top nav .arrow{display:none}.brand{font-size:15px}h1{font-size:24px}th,td{padding:9px 10px}main{padding-top:24px}footer nav{margin-left:0}}
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
    "Mojo repos, versions and growth, counted from GH Archive by"
    " magmalake. An independent project, not affiliated with Modular."
)


def _page(
    title: String, var body: String, section: String, q: String = ""
) raises -> Response:
    """The page around `body`; `section` is `repos`, `migrations` or `how`, the
    nav entry to light up (none for the overview and search); `q` fills the search box. An empty `title` is the
    home page, titled with the brand alone; others read "<title> · Mojo census"."""
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
        html_escape(q), "' placeholder='Search repos' aria-label='Search repos'",
        " autocomplete=off></form>",
        "<nav>", _nav("/repos", "Repos", section == "repos"),
        _nav("/migrations", "Migrations", section == "migrations"),
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


comptime REFRESH_SECS = 1800
"""How often the tables' current snapshots are looked at, unless
`CONSOLE_REFRESH_SECONDS` says otherwise."""
comptime RETRY_SECS = 30
"""How soon to look again after a failed build or while nothing is built."""
comptime RISING_SHOWN = 10
comptime ACTIVE_SHOWN = 10


struct RepoData(Copyable, Movable):
    """What a repo's page lists, read with every other repo's when the cache
    is built."""

    var pts: List[Point]
    """Its commits, oldest first."""
    var ms: List[Migration]
    var rels: List[Release]
    var acts: List[MonthActivity]

    def __init__(out self):
        self.pts = List[Point]()
        self.ms = List[Migration]()
        self.rels = List[Release]()
        self.acts = List[MonthActivity]()


struct Cache(Movable):
    """The repos and the overview, as of one build. A `Cache` is never changed
    once it is in the `Swap`: the refresher thread builds the next one beside
    it, so any number of requests can read it without a lock."""

    var ready: Bool
    var libs: List[Library]
    """Biggest (lines of Mojo now) first."""
    var lines: List[Int64]
    var files: List[Int64]
    var stars: List[Int64]
    var buckets: List[String]
    """`bucket_of` each repo's current Mojo version."""
    var families: List[String]
    """`family_of` each repo's current Mojo version (old `?version=` links)."""
    var news: List[Int]
    """Bits of `listing.new_bit` for when each repo's first Mojo commit was."""
    var active: List[Bool]
    var ov: Overview
    var details: Dict[String, RepoData]
    """Per repo: the lists its page shows, all read at once at each build."""
    var loaded: List[String]
    """The months of GH Archive in mojo.activity."""
    var version_rows: List[VersionMonth]
    var migrations_body: String
    """The Migrations page's HTML, rendered at each build."""
    var commits30: List[Int64]
    """Commits in the last 30 days, per repo."""
    var active_repos: List[String]
    """The `ACTIVE_SHOWN` repos with the most commits in the last 30 days."""
    var active_commits: List[Int64]
    var active_lines: List[Int64]
    """Their net change in lines of Mojo over the 30 days."""
    var rising: List[String]
    var rising_gain: List[Int64]
    var rising_stars: List[Int64]
    var sources: Sources
    var built_day: Int
    var built_at: Int64
    """When it was built, in seconds since the epoch."""

    def __init__(out self):
        self.ready = False
        self.libs = List[Library]()
        self.lines = List[Int64]()
        self.files = List[Int64]()
        self.stars = List[Int64]()
        self.buckets = List[String]()
        self.families = List[String]()
        self.news = List[Int]()
        self.active = List[Bool]()
        self.ov = Overview()
        self.details = Dict[String, RepoData]()
        self.loaded = List[String]()
        self.version_rows = List[VersionMonth]()
        self.migrations_body = String()
        self.commits30 = List[Int64]()
        self.active_repos = List[String]()
        self.active_commits = List[Int64]()
        self.active_lines = List[Int64]()
        self.rising = List[String]()
        self.rising_gain = List[Int64]()
        self.rising_stars = List[Int64]()
        self.sources = Sources()
        self.built_day = 0
        self.built_at = 0

    def _build(mut self, today: Int, var src: Sources) raises:
        var b = Builder(today)
        var libs = libraries(b)
        var ov = b.finish(len(libs))
        var commits30 = List[Int64]()
        var lines_delta = List[Int64]()
        for ref a in b.accs:
            commits30.append(Int64(a.commits30))
            lines_delta.append(a.last_lines - (a.cut_lines if a.cut_seq >= 0 else 0))
        var gains = star_gains(today - 30)
        var cutoff = Int64(today - ACTIVE_DAYS) * 86_400_000_000
        var lines = List[Int64]()
        var files = List[Int64]()
        var stars = List[Int64]()
        var buckets = List[String]()
        var families = List[String]()
        var news = List[Int]()
        var now_month = month_of_days(today)
        var cut30 = Int64(today - 30) * 86_400_000_000
        var active = List[Bool]()
        var gain_list = List[Int64]()
        for ref l in libs:
            lines.append(l.mojo_lines)
            files.append(l.mojo_files)
            stars.append(l.stars)
            buckets.append(bucket_of(l.mojo_version))
            families.append(family_of(l.mojo_version))
            # As the Overview counts new repos: by the first Mojo commit.
            var bits = 0
            if l.commits > 0:
                var fm = month_of_days(Int(l.first_commit // 86_400_000_000))
                if fm == now_month:
                    bits |= NEW_MONTH
                elif fm == now_month - 1:
                    bits |= NEW_LAST_MONTH
                if l.first_commit > cut30:
                    bits |= NEW_30D
            news.append(bits)
            active.append(l.commits > 0 and l.last_commit >= cutoff)
            gain_list.append(gains.get(l.repo, Int64(0)))
        self.rising = List[String]()
        self.rising_gain = List[Int64]()
        self.rising_stars = List[Int64]()
        for i in top_gains(gain_list, RISING_SHOWN):
            self.rising.append(libs[i].repo)
            self.rising_gain.append(gain_list[i])
            self.rising_stars.append(libs[i].stars)
        var details = Dict[String, RepoData]()
        for e in histories().items():
            details[e.key] = RepoData()
            details[e.key].pts = e.value.copy()
        var all_ms = migrations()
        var rows = versions_of(all_ms)
        for ref m in all_ms:
            if m.repo not in details:
                details[m.repo] = RepoData()
            details[m.repo].ms.append(m.copy())
        for e in releases_all().items():
            if e.key not in details:
                details[e.key] = RepoData()
            details[e.key].rels = e.value.copy()
        for e in activity_all().items():
            if e.key not in details:
                details[e.key] = RepoData()
            details[e.key].acts = e.value.copy()
        self.loaded = activity_months()
        self.migrations_body = _migrations_body(rows) if len(rows) > 0 else String()
        self.version_rows = rows^
        self.details = details^
        self.commits30 = commits30.copy()
        self.active_repos = List[String]()
        self.active_commits = List[Int64]()
        self.active_lines = List[Int64]()
        for i in top_gains(commits30, ACTIVE_SHOWN):
            self.active_repos.append(libs[i].repo)
            self.active_commits.append(commits30[i])
            self.active_lines.append(lines_delta[i])
        self.ov = ov^
        self.lines = lines^
        self.files = files^
        self.stars = stars^
        self.buckets = buckets^
        self.families = families^
        self.news = news^
        self.active = active^
        self.libs = libs^
        self.sources = src^
        self.built_day = today
        self.ready = True

    def data(self, repo: String) -> RepoData:
        return self.details.get(repo, RepoData())

    def find(self, repo: String) -> Optional[Library]:
        for ref l in self.libs:
            if l.repo == repo:
                return l.copy()
        return None


def _th(label: String, key: String, q: ListQuery, sortable: Bool, num: Bool = True) -> String:
    """A column header; a sortable one links to the table sorted by it (the
    same column again flips the direction) and shows the current order."""
    var cls = String(" class=num") if num else String()
    if not sortable:
        return String("<th", cls, ">", label, "</th>")
    var cur = q.sort == key
    var aria = String()
    var arrow = String()
    if cur:
        aria = String(" aria-sort=ascending") if q.asc else String(" aria-sort=descending")
        arrow = String(" &#9650;") if q.asc else String(" &#9660;")
    return String(
        "<th", cls, aria, "><a href='", html_escape(list_url(sorted_by(q, key))), "'>", label, arrow, "</a></th>"
    )


def _libs_table(
    libs: List[Library], idx: List[Int], today: Int, q: ListQuery, sortable: Bool,
    c30: List[Int64] = List[Int64](),
) -> String:
    """The Repos table: the repos `idx` of `libs`, in that order. The Repos
    page sorts it by its column headers; search results are in rank order."""
    var h = String(
        "<div class=tbl><table><thead><tr><th>Repository</th>",
        _th("Lines of Mojo", "lines", q, sortable), _th("Files", "files", q, sortable),
        "<th class=num>Commits</th>", _th("Commits, 30 days", "commits30", q, sortable) if len(c30) > 0 else String(),
        "<th>Age</th><th>Created</th>",
        "<th>Mojo version</th><th>Tooling</th>", _th("Stars", "stars", q, sortable),
        "</tr></thead><tbody>",
    )
    for i in idx:
        ref l = libs[i]
        var lines = _n(l.mojo_lines) if l.commits > 0 else String("<span class=mute>not read</span>")
        h.write(
            "<tr><td><a class=repo href='/repos/", html_escape(l.repo), "'>", html_escape(l.repo),
            "</a>", _chips(l.topics), "</td><td class=num>", lines, "</td><td class=num>",
            _n(l.mojo_files), "</td><td class=num>", l.commits, "</td>",
            String("<td class=num>", c30[i], "</td>") if len(c30) > 0 else String(), "<td>",
            _age(l.created_at, today), "</td><td>", day(l.created_at),
            "</td><td class='mono soft'>", _or_dash(l.mojo_version), "</td><td>",
            _or_dash(l.tooling), "</td><td class=num>", _n(l.stars), "</td></tr>",
        )
    h.write("</tbody></table></div>")
    return h^


def _list_query(req: Request) -> ListQuery:
    return parse_list_query(
        req.query_param("sort"), req.query_param("dir"),
        url_decode(req.query_param("version")), req.query_param("active"),
        req.query_param("new"),
    )


def _raw_query(req: Request) -> String:
    """The part of the URL after `?`, before any `#`; empty for none."""
    var q = req.url.find("?")
    if q < 0:
        return String()
    var s = String(req.url[byte = q + 1 :])
    var hash = s.find("#")
    if hash >= 0:
        var cut = String(s[byte=:hash])
        s = cut^
    return s^


def _filter_options(q: ListQuery, c: Cache) -> String:
    """The version families and the activity filter as links, with how many
    repos each has under the other filter; the ones in use are marked."""
    var per = Dict[String, Int]()
    var total = 0
    for i in range(len(c.libs)):
        if q.active and not c.active[i]:
            continue
        if q.new.byte_length() > 0 and c.news[i] & new_bit(q.new) == 0:
            continue
        per[c.buckets[i]] = per.get(c.buckets[i], 0) + 1
        total += 1
    var h = String("<div class=filters><span class=label>Mojo version</span>")
    h.write(
        "<a class='chip", " on" if q.version.byte_length() == 0 else "", "' href='",
        html_escape(list_url(with_version(q, String()))), "'>any (", total, ")</a>",
    )
    for ref f in c.ov.buckets:
        var n = per.get(f, 0)
        if n == 0 and q.version != f:
            continue
        h.write(
            "<a class='chip", " on" if q.version == f else "", "' href='",
            html_escape(list_url(with_version(q, f))), "'>", html_escape(f), " (", n, ")</a>",
        )
    h.write("<span class=label>Activity</span>")
    h.write(
        "<a class='chip", " on" if not q.active else "", "' href='",
        html_escape(list_url(with_active(q, False))), "'>any</a>",
        "<a class='chip", " on" if q.active else "", "' href='",
        html_escape(list_url(with_active(q, True))), "'>active in the last year</a>",
    )
    h.write("<span class=label>First commit</span>")
    var news: List[String] = ["", "month", "last-month", "30d"]
    var titles: List[String] = ["any", "this month", "last month", "last 30 days"]
    for k in range(4):
        h.write(
            "<a class='chip", " on" if q.new == news[k] else "", "' href='",
            html_escape(list_url(with_new(q, news[k]))), "'>", titles[k], "</a>",
        )
    h.write("</div>")
    return h^


def _filter_chips(q: ListQuery) -> String:
    """The filters in use, each a chip that removes it."""
    if not q.has_filter():
        return String()
    var h = String("<div class=filters><span class=label>Filters</span>")
    if q.version.byte_length() > 0:
        h.write(
            "<a class='chip on' href='", html_escape(list_url(with_version(q, String()))),
            "' aria-label='Remove the version filter'>version ",
            html_escape(q.version), " &times;</a>",
        )
    if q.active:
        h.write(
            "<a class='chip on' href='", html_escape(list_url(with_active(q, False))),
            "' aria-label='Remove the activity filter'>active in the last year &times;</a>",
        )
    if q.new.byte_length() > 0:
        var what = String("new this month")
        if q.new == "last-month":
            what = String("new last month")
        elif q.new == "30d":
            what = String("new in the last 30 days")
        h.write(
            "<a class='chip on' href='", html_escape(list_url(with_new(q, String()))),
            "' aria-label='Remove the new repos filter'>", what, " &times;</a>",
        )
    h.write("</div>")
    return h^


def repos_page(req: Request, c: Cache) raises -> Response:
    try:
        var q = _list_query(req)
        var idx = select_repos(q, c.lines, c.files, c.stars, c.buckets, c.active, c.families, c.news, c.commits30)
        var h = String(
            "<h1>Mojo repos</h1><p class=sub>Mojo repos, versions and growth, counted",
            " from GH Archive by magmalake. Not affiliated with Modular.</p>",
        )
        if len(c.libs) == 0:
            h.write(
                _empty(
                    "No repos yet",
                    "The lake is still filling. The pipelines read GH Archive an hour at a"
                    " time and write a row here for each repository they find Mojo in,"
                    " so this page fills in as they catch up.",
                )
            )
            return _page("Repos", h^, "repos")
        h.write(
            "<p class=lead><strong>", len(idx), " repo" if len(idx) == 1 else " repos",
            "</strong>", " of " if q.has_filter() else "", String(len(c.libs)) if q.has_filter() else "",
            " found in GH Archive. Size is lines of Mojo at the last commit read; age is since GitHub",
            " created the repository. Click a column to sort.</p>",
            _filter_chips(q), _filter_options(q, c),
        )
        if len(idx) == 0:
            h.write(_empty("No repos match", "No repo has all of these filters. Remove one with the chips above."))
        else:
            h.write(_libs_table(c.libs, idx, _now_days(), q, True, c.commits30))
        return _page("Repos", h^, "repos")
    except e:
        return internal_error(String(e))


def _signed(v: Int64) -> String:
    """`+1,234` or `-12`, in the colour of its direction."""
    if v > 0:
        return String("<span class=up>+", _n(v), "</span>")
    if v < 0:
        return String("<span class=down>&minus;", _n(-v), "</span>")
    return String("no change")


def _kpi(label: String, value: String, note: String, href: String = "") -> String:
    """One headline card; a link when `href` is given. `note` is HTML."""
    var inner = String("<b>", label, "</b><span>", value, "</span><small>", note, "</small>")
    if href.byte_length() > 0:
        return String("<a class=kpi href='", html_escape(href), "'>", inner, "</a>")
    return String("<div class=kpi>", inner, "</div>")


def _pct(part: Int, whole: Int) -> String:
    """`37%`, or `37.5%` below ten; `0%` for no whole."""
    if whole <= 0:
        return String("0%")
    var tenths = part * 1000 // whole
    if tenths >= 100 or tenths % 10 == 0:
        return String(tenths // 10, "%")
    return String(tenths // 10, ".", tenths % 10, "%")


def _family_url(f: String, active: Bool) -> String:
    return list_url(ListQuery(String("lines"), False, f, active, String()))


def _family_donut(c: Cache, active: Bool) -> String:
    """A donut of the repos per Mojo version family (the ones active in the
    last year when `active`), each slice a link to the filtered Repos table,
    and a legend with the numbers."""
    ref ov = c.ov
    var labels = List[String]()
    var values = List[Int]()
    var colors = List[String]()
    var hrefs = List[String]()
    var total = 0
    for i in range(len(ov.buckets)):
        var n = ov.bucket_active[i] if active else ov.bucket_repos[i]
        total += n
        labels.append(ov.buckets[i])
        values.append(n)
        colors.append(bucket_color(ov.buckets[i]))
        hrefs.append(_family_url(ov.buckets[i], active))
    var what = String("active in the last year") if active else String("all")
    var svg = donut(
        labels, values, colors, hrefs, String(total), String("repos"),
        String("Donut chart: ", total, " repos (", what, ") by Mojo version"),
    )
    var legend = String("<ul class=legend>")
    for i in range(len(labels)):
        if values[i] == 0:
            continue
        legend.write(
            "<li><a href='", html_escape(hrefs[i]), "'><i class=sw style='background:", colors[i],
            "'></i>", html_escape(labels[i]), " <b>", values[i], "</b> <span class=mute>",
            _pct(values[i], total), "</span></a></li>",
        )
    legend.write("</ul>")
    return String(
        "<div class=card><h3>", "Active in the last year" if active else "All repos", "</h3>", svg, legend, "</div>"
    )


def _legend(names: List[String], colors: List[String], values: List[String]) -> String:
    var h = String("<ul class=legend>")
    for i in range(len(names)):
        h.write(
            "<li><i style='background:", colors[i], "'></i>", html_escape(names[i]), " <b>",
            values[i], "</b></li>",
        )
    h.write("</ul>")
    return h^


def _curve_card(
    title: String,
    months: List[String],
    names: List[String],
    series: List[List[Int64]],
    colors: List[String],
    percent: Bool,
    note: String,
    area: Bool = False,
) -> String:
    var last = months[len(months) - 1]
    var aria = String("Line chart: ", title, ", ", months[0], " to ", last)
    var now_vals = List[String]()
    for ref s in series:
        now_vals.append(String(s[len(s) - 1], "%") if percent else _n(s[len(s) - 1]))
    var svg = line_chart(months, names, series, colors, percent, aria, area)
    # The class lets the chart's text be sized for small screens.
    svg = svg.replace("<svg viewBox", "<svg class=lc viewBox", )
    return String(
        "<div class=card><h3>", html_escape(title), "</h3>", svg,
        _legend(names, colors, now_vals), "<p class=mute>", note, "</p></div>",
    )


def _as_of(ms: Int64) -> String:
    """`2026-11-05 03:12 UTC` for a time in milliseconds."""
    var iso = micros_to_iso(ms * 1000)
    return String(iso[byte=:10], " ", iso[byte=11:16], " UTC")


def _span(secs: Int) -> String:
    """`45 s`, `12 min`, `3 h 5 min`."""
    if secs < 90:
        return String(max(secs, 0), " s")
    var mins = (secs + 30) // 60
    if mins < 120:
        return String(mins, " min")
    return String(mins // 60, " h ", mins % 60, " min") if mins % 60 > 0 else String(mins // 60, " h")


def overview(req: Request, c: Cache) raises -> Response:
    if _raw_query(req).byte_length() > 0 and (
        req.query_param("sort").byte_length() > 0
        or req.query_param("dir").byte_length() > 0
        or req.query_param("version").byte_length() > 0
        or req.query_param("active").byte_length() > 0
        or req.query_param("new").byte_length() > 0
    ):
        # The Repos table used to be the home page: keep its links working.
        return redirect(String("/repos?", _raw_query(req)), 301)
    try:
        ref ov = c.ov
        var h = String(
            "<h1>Mojo census</h1><p class=lead>How the Mojo language is being used on GitHub:",
            " the repos that contain Mojo, found in GH Archive, with their whole git history",
            " read. An independent project, not affiliated with Modular.</p>",
        )
        if ov.repos == 0:
            h.write(
                _empty(
                    "No repos yet",
                    "The lake is still filling. The pipelines read GH Archive an hour at a"
                    " time, so this page fills in as they catch up.",
                )
            )
            return _page("", h^, "overview")
        var dc = ov.commits_30 - ov.commits_prev_30
        h.write(
            "<div class=kpis>",
            _kpi(
                "Repos", String("<a href='/repos'>", _n(Int64(ov.repos)), "</a>"),
                String(
                    "<a href='", html_escape(list_url(with_new(ListQuery(String("lines"), False, String(), False, String()), String("30d")))), "'>",
                    _signed(Int64(ov.with_history - ov.repos_30_ago)), " in 30 days</a>",
                ),
            ),
            _kpi(
                "Commits", _n(Int64(ov.commits)),
                String(_signed(Int64(ov.commits_30)), " in 30 days"),
            ),
            _kpi(
                "Lines of Mojo", compact(ov.lines),
                String(_signed(ov.lines - ov.lines_30_ago), " in 30 days"),
                list_url(ListQuery(String("lines"), False, String(), False, String())),
            ),
            _kpi(
                "Active repos", _n(Int64(ov.active)),
                String(_pct(ov.active, ov.with_history), " of ", ov.with_history, " read; a commit in the last year"),
                String("/repos?active=1y"),
            ),
            _kpi(
                "Commits, 30 days", _n(Int64(ov.commits_30)),
                String(_signed(Int64(dc)), " vs the 30 days before"),
            ),
            _kpi(
                "New repos this month",
                String("<a href='/repos?new=month'>", _n(Int64(ov.new_this_month)), "</a>"),
                String(
                    "<a href='/repos?new=last-month'>", ov.new_last_month,
                    " last month</a> (first Mojo commit)",
                ),
            ),
            "</div>",
        )
        # Repos per Mojo version family.
        h.write(
            "<h2>Repos by Mojo version</h2><p class=sub>The version a repo's latest lock file (or manifest)",
            " names; <em>unknown</em> when it has none. Click a slice for its repos.</p>",
            "<div class=cols>", _family_donut(c, False), _family_donut(c, True), "</div>",
        )
        # Growth.
        if len(ov.months) >= 2:
            var m = ov.months.copy()
            var single_color: List[String] = ["var(--ember)"]
            var lines_names: List[String] = ["Lines of Mojo"]
            var lines_series = List[List[Int64]]()
            lines_series.append(ov.lines_series.copy())
            var repos_names: List[String] = ["Repos"]
            var repos_series = List[List[Int64]]()
            repos_series.append(ov.repos_series.copy())
            var commits_names: List[String] = ["Commits"]
            var commits_series = List[List[Int64]]()
            commits_series.append(ov.commits_series.copy())
            h.write(
                "<h2>Growth</h2><p class=sub>Monthly, from each repo's full git history, so the",
                " curves reach back before the census found the repos.</p><div class=cols>",
                _curve_card(
                    "Lines of Mojo", m, lines_names, lines_series, single_color, False,
                    "Lines of Mojo at the end of each month, summed over every repo.", True,
                ),
                _curve_card(
                    "Repos", m, repos_names, repos_series, single_color, False,
                    "A repo counts from its first Mojo commit.", True,
                ),
                _curve_card(
                    "Commits per month", m, commits_names, commits_series, single_color, False,
                    "Commits in the repos' first-parent histories.", True,
                ),
            )
            # Tooling share, in percent of the repos that exist that month.
            var none = List[Int64]()
            var magic = List[Int64]()
            var pixi = List[Int64]()
            var bazel = List[Int64]()
            for k in range(len(m)):
                var tot = ov.tool_none[k] + ov.tool_magic[k] + ov.tool_pixi[k] + ov.tool_bazel[k]
                var t = tot if tot > 0 else Int64(1)
                none.append(ov.tool_none[k] * 100 // t)
                magic.append(ov.tool_magic[k] * 100 // t)
                pixi.append(ov.tool_pixi[k] * 100 // t)
                bazel.append(ov.tool_bazel[k] * 100 // t)
            var tool_names: List[String] = ["none", "magic", "pixi", "bazel"]
            var tool_colors: List[String] = ["var(--c5)", "var(--c1)", "var(--c2)", "var(--c3)"]
            var tool_series = List[List[Int64]]()
            tool_series.append(none^)
            tool_series.append(magic^)
            tool_series.append(pixi^)
            tool_series.append(bazel^)
            h.write(
                _curve_card(
                    "Tooling", m, tool_names, tool_series, tool_colors, True,
                    "Share of repos by how they manage Mojo: no lock file or manifest, magic, pixi, or bazel.",
                ),
                "</div>",
            )
        # Rising and the most active repos, side by side.
        h.write("<div class=cols><div>")
        h.write(
            "<h2>Rising</h2><p class=sub>The repos that gained the most stars in the last 30 days,",
            " counted from GH Archive's WatchEvents on the days loaded so far.</p>",
        )
        if len(c.rising) > 0:
            h.write(
                "<div class=tbl><table><thead><tr>",
                "<th>Repository</th><th class=num>Stars, 30 days</th><th class=num>Stars</th></tr></thead><tbody>",
            )
            for i in range(len(c.rising)):
                h.write(
                    "<tr><td><a class=repo href='/repos/", html_escape(c.rising[i]), "'>",
                    html_escape(c.rising[i]), "</a></td><td class=num>", _signed(c.rising_gain[i]),
                    "</td><td class=num>", _n(c.rising_stars[i]), "</td></tr>",
                )
            h.write("</tbody></table></div>")
        h.write(
            "</div><div><h2><a href='",
            html_escape(list_url(ListQuery(String("commits30"), False, String(), False, String()))),
            "'>Most active</a></h2><p class=sub>The repos with the most commits in the last 30 days,",
            " and how many lines of Mojo they grew by.</p>",
        )
        if len(c.active_repos) > 0:
            h.write(
                "<div class=tbl><table><thead><tr><th>Repository</th><th class=num>Commits, 30 days</th>",
                "<th class=num>Lines of Mojo</th></tr></thead><tbody>",
            )
            for i in range(len(c.active_repos)):
                h.write(
                    "<tr><td><a class=repo href='/repos/", html_escape(c.active_repos[i]), "'>",
                    html_escape(c.active_repos[i]), "</a></td><td class=num>", _n(c.active_commits[i]),
                    "</td><td class=num>", _signed(c.active_lines[i]), "</td></tr>",
                )
            h.write("</tbody></table></div>")
        h.write("</div></div>")
        # As of.
        h.write(
            "<p class=asof>Data as of ", _as_of(c.sources.as_of_ms), " (the latest snapshot of the tables",
            " behind this page; every run is on <a href='", ORCA_UI, "/runs' rel=noopener>orca.mlake.dev/runs</a>).",
            " Refreshed every ", _span(refresh_secs()), "; built ", _span(Int(now() - c.built_at)), " ago.",
            " Repos are discovered from the GH Archive days loaded so far",
        )
        if c.sources.days > 0:
            h.write(
                ": ", c.sources.days, " days, ", c.sources.first_day, " to ", c.sources.last_day,
                ". A repo is found only when an event of it falls on a loaded day, so the repo count is a lower bound",
            )
        h.write(".</p>")
        return _page("", h^, "overview")
    except e:
        return internal_error(String(e))


def overview_json(req: Request, c: Cache) raises -> Response:
    ref ov = c.ov
    var out = String(
        '{"as_of":', _q(micros_to_iso(c.sources.as_of_ms * 1000)),
        ',"days_loaded":', c.sources.days, ',"first_day":', _q(c.sources.first_day),
        ',"last_day":', _q(c.sources.last_day), ',"repos":', ov.repos,
        ',"repos_with_history":', ov.with_history, ',"repos_30d_ago":', ov.repos_30_ago,
        ',"commits":', ov.commits, ',"commits_30d":', ov.commits_30,
        ',"commits_prev_30d":', ov.commits_prev_30, ',"mojo_lines":', ov.lines,
        ',"mojo_lines_30d_ago":', ov.lines_30_ago, ',"new_repos_this_month":', ov.new_this_month,
        ',"new_repos_last_month":', ov.new_last_month, ',"active_repos":', ov.active,
        ',"buckets":[',
    )
    for i in range(len(ov.buckets)):
        if i > 0:
            out += ","
        out.write(
            '{"bucket":', _q(ov.buckets[i]), ',"repos":', ov.bucket_repos[i],
            ',"active_repos":', ov.bucket_active[i], "}",
        )
    out += '],"families":['
    for i in range(len(ov.families)):
        if i > 0:
            out += ","
        out.write(
            '{"family":', _q(ov.families[i]), ',"repos":', ov.family_repos[i],
            ',"active_repos":', ov.family_active[i], "}",
        )
    out.write(
        '],"months":[',
    )
    for k in range(len(ov.months)):
        if k > 0:
            out += ","
        out.write(
            '{"month":', _q(ov.months[k]), ',"mojo_lines":', ov.lines_series[k],
            ',"repos":', ov.repos_series[k], ',"commits":', ov.commits_series[k],
            ',"tooling":{"none":', ov.tool_none[k], ',"magic":', ov.tool_magic[k],
            ',"pixi":', ov.tool_pixi[k],
            ',"bazel":', ov.tool_bazel[k], "}}",
        )
    out += '],"rising":['
    for i in range(len(c.rising)):
        if i > 0:
            out += ","
        out.write(
            '{"repo":', _q(c.rising[i]), ',"stars_30d":', c.rising_gain[i],
            ',"stars":', c.rising_stars[i], "}",
        )
    out += '],"most_active":['
    for i in range(len(c.active_repos)):
        if i > 0:
            out += ","
        out.write(
            '{"repo":', _q(c.active_repos[i]), ',"commits_30d":', c.active_commits[i],
            ',"mojo_lines_30d":', c.active_lines[i], "}",
        )
    out += "]}"
    return ok_json(out)


def _matches(query: String, c: Cache) raises -> List[Int]:
    """The indices into `c.libs` of the repos matching `query`, best match
    first; equal matches keep the Repos order (biggest first)."""
    var hits = List[Int]()
    var scores = List[Int]()
    for i in range(len(c.libs)):
        ref l = c.libs[i]
        var sc = search_score(l.repo, l.description, query, l.topics)
        if sc > 0:
            hits.append(i)
            scores.append(sc)
    for i in range(1, len(hits)):
        var j = i
        while j > 0 and scores[j - 1] < scores[j]:
            scores.swap_elements(j - 1, j)
            hits.swap_elements(j - 1, j)
            j -= 1
    return hits^


def search(req: Request, c: Cache) raises -> Response:
    try:
        var q = String(url_decode(req.query_param("q")).strip())
        var h = String("<h1>Search</h1>")
        if q.byte_length() == 0:
            h.write(
                _empty(
                    "Search the repos",
                    "Type part of a repository name, topic or description in the box above,"
                    " for example flare or http. Names that match best come first.",
                )
            )
            return _page("Search", h^, "search")
        var hits = _matches(q, c)
        h.write(
            "<p class=lead>", len(hits), " ", "repo" if len(hits) == 1 else "repos",
            " matching &ldquo;", html_escape(q), "&rdquo; in the repository name, GitHub topics or description.</p>",
        )
        if len(hits) == 0:
            h.write(_empty("No repos match", "Try a shorter word, or part of the owner or the name."))
        else:
            h.write(_libs_table(c.libs, hits, _now_days(), _list_query(req), False))
        return _page(String("Search: ", q), h^, "search", q)
    except e:
        return internal_error(String(e))


def search_json(req: Request, c: Cache) raises -> Response:
    try:
        var q = String(url_decode(req.query_param("q")).strip())
        var out = String("[")
        if q.byte_length() > 0:
            var first = True
            for i in _matches(q, c):
                if not first:
                    out += ","
                first = False
                out += _lib_json(c.libs[i])
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


def index_json(req: Request, c: Cache) raises -> Response:
    var out = String("[")
    var first = True
    for ref l in c.libs:
        if not first:
            out += ","
        first = False
        out += _lib_json(l)
    out += "]"
    return ok_json(out)


def _next_month(m: String) raises -> String:
    """`2025-12` -> `2026-01`."""
    var y = Int(m[byte=:4])
    var mo = Int(m[byte=5:7])
    if mo == 12:
        return String(y + 1, "-01")
    return String(y, "-", "0" if mo < 9 else "", mo + 1)


def _versions_chart(rows: List[VersionMonth]) raises -> String:
    """Repos migrating each month as one line per Mojo version bucket
    (`pre-1.0`, then each 1.x minor), as inline SVG with a legend."""
    var names = List[String]()
    var oldest = List[String]()
    for ref r in rows:
        var k = version_bucket(r.version)
        if k not in names:
            names.append(k)
            oldest.append(r.version)
    sort_buckets(names, oldest)
    # Buckets keep their colour across the site (the overview's donuts too).
    var colors = List[String]()
    for ref f in names:
        colors.append(bucket_color(f))
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
        var k = String(version_bucket(r.version), "|", r.month)
        var c = counts.get(k, 0) + r.repos
        counts[k] = c
        if c > top:
            top = c
    return _line_chart(
        months, names, counts, top,
        String("Line chart: repos migrating to each Mojo version"),
        String(
            "Repos migrating to each Mojo version per month, ", months[0], " to ", last,
        ),
        String("Repos per month; a repo that moved twice in a month counts for each version."),
        colors,
    )


def _line_chart(
    months: List[String],
    names: List[String],
    counts: Dict[String, Int],
    top: Int,
    aria: String,
    title: String,
    note: String,
    colors: List[String] = List[String](),
) raises -> String:
    """One line per name over `months`, from `counts` (`name|month`), as
    inline SVG with a legend; the versions and the stars charts draw it.
    `colors` gives each name's colour (by default the palette in order)."""
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
        var color = colors[si] if si < len(colors) else String("var(--c", si % 6, ")")
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


def _migrations_body(rows: List[VersionMonth]) raises -> String:
    """The Migrations page's HTML for `rows` (at least one), rendered once
    per cache build."""
    var h = String(
        "<h1>Mojo version migrations</h1><p class=lead>A migration is a repo's lock",
        " file (or its manifest, when there's no lock) moving to a Mojo version between",
        " two of its commits. Each number is the repos whose lock file moved to that",
        " version that month. Versions are in Mojo's own order across the renumbering:",
        " pre-1.0 (24.x to 0.26.x, one line), then each 1.x minor.</p>",
    )
    h.write(_versions_chart(rows))
    var late = List[VersionMonth]()
    var early = List[VersionMonth]()
    for ref r in rows:
        if version_bucket(r.version) == "pre-1.0":
            early.append(r.copy())
        else:
            late.append(r.copy())
    if len(late) > 0:
        h.write("<h2>Mojo 1.x and later</h2>", _versions_table(late))
    if len(early) > 0:
        # Collapsed: the renumbering's old versions are history.
        h.write(
            "<details class=early><summary>Before 1.0 &mdash; ", len(early), " rows</summary>",
            _versions_table(early), "</details>",
        )
    return h^


def _versions_table(rows: List[VersionMonth]) raises -> String:
    """The month, version and repos table for `rows`: the month cell spans its
    rows, and the bars are against this table's busiest row."""
    var per_month = Dict[String, Int]()
    var top = 1
    for ref r in rows:
        per_month[r.month] = per_month.get(r.month, 0) + 1
        if r.repos > top:
            top = r.repos
    var h = String(
        "<div class=tbl><table><thead><tr><th>Month</th><th>Version</th>",
        "<th>Repos migrating</th></tr></thead><tbody>",
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
    return h^


def migrations_page(req: Request, c: Cache) raises -> Response:
    try:
        var h = String(
            "<h1>Mojo version migrations</h1><p class=lead>A migration is a repo's lock",
            " file (or its manifest, when there's no lock) moving to a Mojo version between",
            " two of its commits. Each number is the repos whose lock file moved to that",
            " version that month. Versions are in Mojo's own order across the renumbering:",
            " pre-1.0 (24.x to 0.26.x, one line), then each 1.x minor.</p>",
        )
        if len(c.version_rows) == 0:
            h.write(
                _empty(
                    "No migrations yet",
                    "A migration shows up here once a repo's lock file has been read at"
                    " more than one commit and the Mojo version changed between them."
                    " The lake is still filling.",
                )
            )
            return _page("Migrations", h^, "migrations")
        return _page("Migrations", c.migrations_body.copy(), "migrations")
    except e:
        return internal_error(String(e))


def versions_json(req: Request, c: Cache) raises -> Response:
    var out = String("[")
    var first = True
    for ref r in c.version_rows:
        if not first:
            out += ","
        first = False
        out.write(
            '{"month":', _q(r.month), ',"version":', _q(r.version), ',"bucket":',
            _q(version_bucket(r.version)), ',"family":', _q(version_family(r.version)),
            ',"libraries":', r.repos, "}",
        )
    out += "]"
    return ok_json(out)


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


def repo_page(req: Request, c: Cache) raises -> Response:
    try:
        var repo = String(req.param("owner"), "/", req.param("name"))
        var found = c.find(repo)
        if not found:
            return not_found(req.url)
        var l = found.value().copy()
        var data = c.data(repo)
        ref pts = data.pts
        ref ms = data.ms
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
        ref loaded = c.loaded
        if len(loaded) == 0:
            h.write(_empty("No activity yet", "The activity pipeline hasn't counted this repository's GH Archive events yet."))
        else:
            h.write(_stars_chart(data.acts, loaded))
        h.write("<h2>Releases and tags</h2>")
        ref rels = data.rels
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
        return _page(repo, h^, "repos")
    except e:
        return internal_error(String(e))


def repo_json(req: Request, c: Cache) raises -> Response:
    try:
        var repo = String(req.param("owner"), "/", req.param("name"))
        var found = c.find(repo)
        if not found:
            return not_found(req.url)
        var data = c.data(repo)
        var out = String('{"library":', _lib_json(found.value()), ',"migrations":[')
        var first = True
        for ref m in data.ms:
            if not first:
                out += ","
            first = False
            out.write(
                '{"at":', _q(micros_to_iso(m.at)), ',"sha":', _q(m.sha), ',"kind":',
                _q(m.kind), ',"from":', _q(m.from_value), ',"to":', _q(m.to_value), "}",
            )
        out += '],"commits":['
        first = True
        for ref p in data.pts:
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
        for ref a in data.acts:
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
        for ref x in data.rels:
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
    " repo's GH Archive events per day, with no API calls: stars, forks,"
    " releases, issues and pull requests opened, pushes and people, into"
    " <code>mojo.activity</code> and <code>mojo.releases</code>. A repo found"
    " today is read back over every day already loaded, so its history is"
    " complete.</li>"
    "<li><a href='"
    + ORCA_UI
    + "/pipelines/mojo_stats' rel=noopener>mojo_stats</a> asks GitHub about every"
    " repo each Monday (one request each) and keeps the stars, forks, issues"
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


def refresh_secs() -> Int:
    """`CONSOLE_REFRESH_SECONDS`, else `REFRESH_SECS`."""
    var v = getenv("CONSOLE_REFRESH_SECONDS")
    if v.byte_length() > 0:
        try:
            var n = Int(v)
            if n > 0:
                return n
        except:
            pass
    return REFRESH_SECS


def _look(mut sw: Swap[Cache], cur: Cache, t: Int64) raises:
    """Look at the tables' snapshots and, if one moved or the day changed,
    build a new `Cache` and swap it in. Raises with the old one still in place."""
    var src = read_sources()
    var today = Int(t // 86400)
    if not needs_build(cur.ready, cur.built_day, today, src.same_as(cur.sources)):
        return
    read_days(src)
    var next = Cache()
    next._build(today, src^)
    next.built_at = t
    sw.put(next^)


def _refresher(arg: OpaquePtr) -> OpaquePtr:
    """The refresher thread: the only one that reads the lake or builds a
    `Cache`, one build at a time. It uses nothing a request handler holds: each
    read opens its own catalog and S3 client, and the only thing shared with
    the handlers is the `Swap`."""
    ref sw = Pointer[Swap[Cache], MutUntrackedOrigin](unsafe_from_address=Int(arg))[]
    var interval = refresh_secs()
    var checked = Int64(0)
    while True:
        try:
            var t = now()
            var cur = sw.get()
            if check_due(cur[].ready, t, checked, cur[].built_day, Int(t // 86400), interval):
                checked = t
                var started = t
                try:
                    _look(sw, cur[], t)
                    if not cur[].ready:
                        print("console: first build in", now() - started, "s")
                    else:
                        print("console: looked at the tables;", now() - started, "s")
                except e:
                    # Keep serving what there is; look again soon.
                    print("console: refresh failed:", e)
                    checked = t - Int64(interval) + Int64(min(interval, RETRY_SECS))
        except e:
            print("console: refresher:", e)
        sleep(1.0)


def _warming_up() raises -> Response:
    var resp = _page(
        "Warming up",
        _empty("Warming up", "The census is reading the lake for the first time; this page reloads itself."),
        "",
    )
    resp.status = 503
    resp.reason = "Service Unavailable"
    resp.headers.set("Retry-After", "5")
    resp.headers.set("Refresh", "5")
    return resp^


@fieldwise_init
struct Site(Handler, Copyable):
    """One route of the console, with the shared `Swap` of `Cache`s."""

    var page: Int
    var cache: Int
    """The address of the `Swap[Cache]`, which lives as long as the process."""

    def serve(self, req: Request) raises -> Response:
        ref sw = Pointer[Swap[Cache], MutUntrackedOrigin](unsafe_from_address=self.cache)[]
        # One reference for the whole request: a rebuild that finishes meanwhile
        # doesn't change what this page reads.
        var held = sw.get()
        ref c = held[]
        if not c.ready:
            return _warming_up()
        if self.page == 0:
            return overview(req, c)
        if self.page == 1:
            return repos_page(req, c)
        if self.page == 2:
            return search(req, c)
        if self.page == 3:
            return repo_page(req, c)
        if self.page == 4:
            return overview_json(req, c)
        if self.page == 5:
            return index_json(req, c)
        if self.page == 6:
            return search_json(req, c)
        if self.page == 8:
            return migrations_page(req, c)
        if self.page == 9:
            return versions_json(req, c)
        return repo_json(req, c)


def _moved_to_migrations(req: Request) raises -> Response:
    return redirect("/migrations", 301)


def main() raises:
    var p = unsafe_alloc[Swap[Cache]](1)
    p.unsafe_write(Swap[Cache](Cache()))
    var cache = Int(p)
    var refresher = ThreadHandle.spawn[_refresher](OpaquePtr(unsafe_from_address=cache))
    refresher.detach()
    var r = Router()
    r.get("/", Site(0, cache))
    r.get("/repos", Site(1, cache))
    r.get("/migrations", Site(8, cache))
    r.get("/versions", _moved_to_migrations)
    r.get("/how", how)
    r.get("/how/optimizations", optimizations)
    r.get("/search", Site(2, cache))
    r.get("/repos/:owner/:name", Site(3, cache))
    r.get("/api/overview", Site(4, cache))
    r.get("/api/repos", Site(5, cache))
    r.get("/api/versions", Site(9, cache))
    r.get("/api/search", Site(6, cache))
    r.get("/api/repos/:owner/:name", Site(7, cache))
    var addr = String("0.0.0.0:", getenv("PORT", "8080"))
    var server = HttpServer.bind(SocketAddr.parse(addr), ServerConfig())
    print("console on http://", addr, sep="")
    server.serve(r^)
