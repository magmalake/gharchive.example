"""Data checks: invariants a console build must hold before it is served.

The console's refresher runs them on each new build, on the lists the build
already read (no table is read again), and swaps the build in only when they
pass (`publish`). A build that fails is dropped: the previous one stays, the
failing checks are logged, and the pages say so in the footer (`notice`).
The first build is served even when it fails, since there is nothing else.

`mojo.commits` has no column with a repo's `git log --first-parent` count;
the history pipeline numbers the commits it reads along that history (`seq`
from 0), so the last `seq` + 1 is the count it recorded, and the checks use
that.
"""

from jscan import micros_to_iso
from model import Point
from overview import rising_score
from swap import Swap

comptime ROWS_SHOWN = 5
"""How many offending rows a failed check keeps."""


struct Check(Copyable, Movable):
    """One invariant and the rows that broke it."""

    var name: String
    var about: String
    var failures: Int
    var rows: List[String]
    """The first `ROWS_SHOWN` offending rows."""

    def __init__(out self, name: String, about: String):
        self.name = name
        self.about = about
        self.failures = 0
        self.rows = List[String]()

    def fail(mut self, row: String):
        self.failures += 1
        if len(self.rows) < ROWS_SHOWN:
            self.rows.append(row)

    def ok(self) -> Bool:
        return self.failures == 0


@fieldwise_init
struct PageFacts(Copyable, Movable):
    """What a repo's own page shows, worked out from its commit list."""

    var commits: Int
    var commits30: Int64
    """Commits after the 30-day cut."""
    var lines_delta: Int64
    """The newest commit's lines less those of the newest at or before the
    cut (0 for none), as `Builder.recent` counts them."""
    var last_lines: Int64
    """The newest commit's lines of Mojo; 0 for none."""


def page_facts(pts: List[Point], cut30: Int64) -> PageFacts:
    """`PageFacts` of a repo's commits, oldest first (by seq), with the
    30-day cut `cut30` in microseconds."""
    var n30 = Int64(0)
    var cut_lines = Int64(0)
    for ref p in pts:
        if p.at > cut30:
            n30 += 1
        else:
            cut_lines = p.lines
    var last = pts[len(pts) - 1].lines if len(pts) > 0 else Int64(0)
    return PageFacts(len(pts), n30, last - cut_lines, last)


@fieldwise_init
struct RepoFacts(Copyable, Movable):
    """One repo as a build shows it in the Repos table and the top tables,
    and what its own page shows."""

    var repo: String
    var commits: Int
    """Rows of mojo.commits."""
    var commits30: Int64
    """The Repos table's commits in the last 30 days."""
    var history: Int64
    """The first-parent commits mojo_history recorded: its last seq + 1."""
    var lines: Int64
    var stars: Int64
    var used_by: Int64
    var page: PageFacts


struct Tops(Movable):
    """The overview's top tables, each row's name and numbers."""

    var active: List[String]
    var active_commits: List[Int64]
    var active_lines: List[Int64]
    var rising: List[String]
    var rising_gain: List[Int64]
    var rising_forks: List[Int64]
    var rising_used_by: List[Int64]
    var rising_score: List[Int64]
    var rising_stars: List[Int64]
    var depended: List[String]
    var depended_used_by: List[Int64]

    def __init__(out self):
        self.active = List[String]()
        self.active_commits = List[Int64]()
        self.active_lines = List[Int64]()
        self.rising = List[String]()
        self.rising_gain = List[Int64]()
        self.rising_forks = List[Int64]()
        self.rising_used_by = List[Int64]()
        self.rising_score = List[Int64]()
        self.rising_stars = List[Int64]()
        self.depended = List[String]()
        self.depended_used_by = List[Int64]()


def _differs(name: String, what: String, shown: Int64, own: Int64) -> String:
    return String(name, ": ", what, " ", shown, ", its own ", own)


def run_checks(
    repo_rows: Int, repos: List[RepoFacts], tops: Tops
) -> List[Check]:
    """Every check, on one build: `repo_rows` rows read from mojo.repos and
    `repos` one per name."""
    var unique = Check(
        "repos_unique", "rows in mojo.repos = distinct repo names"
    )
    if repo_rows != len(repos):
        unique.fail(
            String(
                "mojo.repos: ",
                repo_rows,
                " rows, ",
                len(repos),
                " distinct names",
            )
        )
    var within = Check(
        "commits_within_history",
        (
            "per repo, rows in mojo.commits <= the first-parent commits"
            " mojo_history recorded (last seq + 1)"
        ),
    )
    var within30 = Check(
        "commits30_within_commits",
        "per repo, commits in the last 30 days <= all its commits",
    )
    var table = Check(
        "repos_table_matches_pages",
        (
            "per repo, the Repos table's commits and 30-day commits = its"
            " page's commit list"
        ),
    )
    var lines = Check(
        "lines_match_last_commit",
        "per repo, lines of Mojo = its last commit row's",
    )
    var at = Dict[String, Int]()
    for i in range(len(repos)):
        ref r = repos[i]
        at[r.repo] = i
        if Int64(r.commits) > r.history:
            within.fail(
                String(
                    r.repo,
                    ": ",
                    r.commits,
                    " rows in mojo.commits, ",
                    r.history,
                    " recorded",
                )
            )
        if r.commits30 > Int64(r.commits):
            within30.fail(
                String(r.repo, ": ", r.commits30, " in 30 days of ", r.commits)
            )
        if r.commits != r.page.commits:
            table.fail(
                _differs(
                    r.repo, "commits", Int64(r.commits), Int64(r.page.commits)
                )
            )
        if r.commits30 != r.page.commits30:
            table.fail(
                _differs(
                    r.repo, "commits in 30 days", r.commits30, r.page.commits30
                )
            )
        if r.lines != r.page.last_lines:
            lines.fail(
                String(
                    r.repo,
                    ": ",
                    r.lines,
                    " lines, last commit ",
                    r.page.last_lines,
                )
            )
    var names = Check(
        "top_names_in_repos",
        (
            "every name in Rising, Most active and Most depended on is in"
            " mojo.repos"
        ),
    )
    var nums = Check(
        "top_numbers_match_pages",
        "the top tables' numbers = the ones on each repo's page",
    )
    for i in range(len(tops.active)):
        var n = tops.active[i]
        var k = at.get(n, -1)
        if k < 0:
            names.fail(String("Most active: ", n))
            continue
        ref p = repos[k].page
        if tops.active_commits[i] != p.commits30:
            nums.fail(
                _differs(
                    n,
                    "Most active commits",
                    tops.active_commits[i],
                    p.commits30,
                )
            )
        if tops.active_lines[i] != p.lines_delta:
            nums.fail(
                _differs(
                    n, "Most active lines", tops.active_lines[i], p.lines_delta
                )
            )
    for i in range(len(tops.rising)):
        var n = tops.rising[i]
        var k = at.get(n, -1)
        if k < 0:
            names.fail(String("Rising: ", n))
            continue
        ref r = repos[k]
        if tops.rising_stars[i] != r.stars:
            nums.fail(
                _differs(n, "Rising stars", tops.rising_stars[i], r.stars)
            )
        if tops.rising_used_by[i] != r.used_by:
            nums.fail(
                _differs(n, "Rising used by", tops.rising_used_by[i], r.used_by)
            )
        var score = rising_score(
            tops.rising_gain[i], tops.rising_forks[i], r.used_by
        )
        if tops.rising_score[i] != score:
            nums.fail(_differs(n, "Rising score", tops.rising_score[i], score))
    for i in range(len(tops.depended)):
        var n = tops.depended[i]
        var k = at.get(n, -1)
        if k < 0:
            names.fail(String("Most depended on: ", n))
            continue
        if tops.depended_used_by[i] != repos[k].used_by:
            nums.fail(
                _differs(
                    n,
                    "Most depended on used by",
                    tops.depended_used_by[i],
                    repos[k].used_by,
                )
            )
    return [unique^, within^, within30^, names^, nums^, table^, lines^]


def when(secs: Int64) -> String:
    """`2026-11-07 10:30 UTC` for a time in seconds since the epoch."""
    var iso = micros_to_iso(secs * 1_000_000)
    return String(iso[byte=:10], " ", iso[byte=11:16], " UTC")


struct CheckRun(Copyable, Movable):
    """The last time the checks ran, and which build that left in place."""

    var at: Int64
    """When they ran, in seconds since the epoch; 0 for never."""
    var built_at: Int64
    """The build they ran on."""
    var serving: Int64
    """The build served after them: `built_at` when it went in, else the
    previous one's."""
    var checks: List[Check]

    def __init__(out self):
        self.at = 0
        self.built_at = 0
        self.serving = 0
        self.checks = List[Check]()

    def __init__(out self, at: Int64, built_at: Int64, var checks: List[Check]):
        self.at = at
        self.built_at = built_at
        self.serving = 0
        self.checks = checks^

    def passed(self) -> Bool:
        for ref c in self.checks:
            if not c.ok():
                return False
        return True

    def failed(self) -> String:
        """Each failing check and its first rows, a line each."""
        var out = String()
        for ref c in self.checks:
            if c.ok():
                continue
            out.write(c.name, ": ", c.failures, " failing (", c.about, ")\n")
            for ref r in c.rows:
                out.write("    ", r, "\n")
        return out^

    def text(self) -> String:
        """The `/checks` page."""
        if self.at == 0:
            return String("data checks: not run yet (no build so far)\n")
        var out = String(
            "data checks: ",
            "passed" if self.passed() else "FAILED",
            "\n",
            "ran at ",
            when(self.at),
            " on the build from ",
            when(self.built_at),
            "\n",
            "serving the build from ",
            when(self.serving),
            "\n\n",
        )
        for ref c in self.checks:
            out.write("ok    " if c.ok() else "FAIL  ", c.name, ": ", c.about)
            if not c.ok():
                out.write(" (", c.failures, ")")
            out.write("\n")
            for ref r in c.rows:
                out.write("      ", r, "\n")
        return out^


def notice(run: CheckRun) -> String:
    """The line the pages show while the last checks failed; empty when they
    passed or never ran."""
    if run.at == 0 or run.passed():
        return String()
    return String(
        "Data checks failed at ",
        when(run.at),
        ", showing the build from ",
        when(run.serving),
        ".",
    )


def publish[
    T: Deinitable & Movable
](
    mut builds: Swap[T],
    var next: T,
    mut runs: Swap[CheckRun],
    var run: CheckRun,
    previous_built_at: Int64,
) -> Bool:
    """Swap `next` in when its checks passed or nothing was built before
    (`previous_built_at` 0); else keep the previous build. Either way `run`
    becomes the last run. Returns whether `next` went in."""
    var take = run.passed() or previous_built_at == 0
    run.serving = run.built_at if take else previous_built_at
    if take:
        builds.put(next^)
    runs.put(run^)
    return take
