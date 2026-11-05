"""The Overview page's numbers, computed once from the commit rows.

A `Builder` is fed every repository (`add_repo`) and every row of
mojo.commits (`add_commit`), in any order, and `finish` gives the cards, the
monthly curves, the repos per Mojo version family and the adoption of the
newest release. Nothing here reads the lake or the clock: the caller passes
today's day, so the tests run over a few in-memory rows.

Per commit the work is a few integer compares into flat arrays: one
`RepoAcc` per repository, and one cell per (repository, month) holding the
repository's last commit of that month. The curves are filled from the cells
at the end, carrying each repository's last state forward month by month.
"""

from search import sort_families, version_family
from versions import compare_versions, version_key

comptime DAY_US = Int64(86_400_000_000)
comptime BASE_MONTH = (2022 - 1970) * 12
"""The first month of the curves (months since 1970-01): Mojo's first public
code is from 2022, and an earlier commit counts in this month."""
comptime ACTIVE_DAYS = 365
"""A repository is active when its latest commit is this recent."""
comptime TOOL_NONE = UInt8(0)
comptime TOOL_MAGIC = UInt8(1)
comptime TOOL_PIXI = UInt8(2)


def month_of_days(days: Int) -> Int:
    """Months since 1970-01 of a day number (days since 1970-01-01)."""
    var z = days + 719468
    var era = z // 146097
    var doe = z - era * 146097
    var yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
    var y = yoe + era * 400
    var doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
    var mp = (5 * doy + 2) // 153
    var m = mp + 3 if mp < 10 else mp - 9
    if m <= 2:
        y += 1
    return (y - 1970) * 12 + m - 1


def month_label(index: Int) -> String:
    """`2025-07` for months-since-1970 `index`."""
    var m = index % 12 + 1
    return String(1970 + index // 12, "-", "0" if m < 10 else "", m)


def tool_code(tooling: String) -> UInt8:
    """`magic` is 1, `pixi` 2, anything else (`none`, empty) 0."""
    var b = tooling.as_bytes()
    if len(b) == 0:
        return TOOL_NONE
    if b[0] == UInt8(ord("m")):
        return TOOL_MAGIC
    if b[0] == UInt8(ord("p")):
        return TOOL_PIXI
    return TOOL_NONE


def family_of(version: String) -> String:
    """The Mojo version family of `version`, or `unknown` for no version."""
    if version.byte_length() == 0:
        return String("unknown")
    return version_family(version)


@fieldwise_init
struct RepoAcc(Copyable, Movable):
    """What one repository's commits add up to."""

    var name: String
    var commits: Int
    var first_at: Int64
    var last_seq: Int64
    var last_at: Int64
    var last_lines: Int64
    var version: String
    var cut_seq: Int64
    """The newest commit at or before 30 days ago, -1 for none."""
    var cut_lines: Int64
    var commits30: Int
    var commits60: Int
    """Commits 30 to 60 days ago."""


struct Overview(Movable):
    """The numbers of the Overview page."""

    var repos: Int
    """Repositories in mojo.repos."""
    var with_history: Int
    var commits: Int
    var commits_30: Int
    var commits_prev_30: Int
    var lines: Int64
    var lines_30_ago: Int64
    var repos_30_ago: Int
    """Repositories whose first commit is at least 30 days old."""
    var new_this_month: Int
    var new_last_month: Int
    var active: Int
    """Repositories with a commit in the last 12 months."""
    var families: List[String]
    """In Mojo's order, `other` after the versions, `unknown` last."""
    var family_repos: List[Int]
    var family_active: List[Int]
    var newest_family: String
    var newest_version: String
    var newest_active: Int
    """Active repositories on `newest_family`."""
    var known_active: Int
    """Active repositories with a Mojo version."""
    var months: List[String]
    var lines_series: List[Int64]
    var repos_series: List[Int64]
    var commits_series: List[Int64]
    var tool_none: List[Int64]
    var tool_magic: List[Int64]
    var tool_pixi: List[Int64]

    def __init__(out self):
        self.repos = 0
        self.with_history = 0
        self.commits = 0
        self.commits_30 = 0
        self.commits_prev_30 = 0
        self.lines = 0
        self.lines_30_ago = 0
        self.repos_30_ago = 0
        self.new_this_month = 0
        self.new_last_month = 0
        self.active = 0
        self.families = List[String]()
        self.family_repos = List[Int]()
        self.family_active = List[Int]()
        self.newest_family = String()
        self.newest_version = String()
        self.newest_active = 0
        self.known_active = 0
        self.months = List[String]()
        self.lines_series = List[Int64]()
        self.repos_series = List[Int64]()
        self.commits_series = List[Int64]()
        self.tool_none = List[Int64]()
        self.tool_magic = List[Int64]()
        self.tool_pixi = List[Int64]()


struct Builder(Movable):
    var now_days: Int
    var months: Int
    """How many months the cells cover, from `BASE_MONTH` to this month."""
    var accs: List[RepoAcc]
    var cell_seq: List[Int64]
    """`accs.len * months` cells: the newest commit's seq of the repository
    in the month, -1 for none."""
    var cell_lines: List[Int64]
    var cell_tool: List[UInt8]
    var commits_by_month: List[Int64]
    var cut30: Int64
    var cut60: Int64
    var cut_active: Int64

    def __init__(out self, now_days: Int):
        self.now_days = now_days
        self.months = max(month_of_days(now_days) - BASE_MONTH + 1, 1)
        self.accs = List[RepoAcc]()
        self.cell_seq = List[Int64]()
        self.cell_lines = List[Int64]()
        self.cell_tool = List[UInt8]()
        self.commits_by_month = List[Int64](length=self.months, fill=0)
        self.cut30 = Int64(now_days - 30) * DAY_US
        self.cut60 = Int64(now_days - 60) * DAY_US
        self.cut_active = Int64(now_days - ACTIVE_DAYS) * DAY_US

    def add_repo(mut self, name: String) -> Int:
        """A repository of mojo.repos; the id to give `add_commit`."""
        self.accs.append(RepoAcc(name, 0, 0, -1, 0, 0, String(), -1, 0, 0, 0))
        var n = len(self.cell_seq) + self.months
        self.cell_seq.resize(n, -1)
        self.cell_lines.resize(n, 0)
        self.cell_tool.resize(n, 0)
        return len(self.accs) - 1

    def add_commit(
        mut self,
        id: Int,
        at: Int64,
        seq: Int64,
        lines: Int64,
        tool: UInt8,
        version: String,
    ):
        var k = min(
            max(month_of_days(Int(at // DAY_US)) - BASE_MONTH, 0), self.months - 1
        )
        self.commits_by_month[k] += 1
        var cell = id * self.months + k
        if seq >= self.cell_seq.unsafe_ptr()[unsafe_offset=cell]:
            self.cell_seq.unsafe_ptr()[unsafe_offset=cell] = seq
            self.cell_lines.unsafe_ptr()[unsafe_offset=cell] = lines
            self.cell_tool.unsafe_ptr()[unsafe_offset=cell] = tool
        ref a = self.accs[id]
        a.commits += 1
        if a.first_at == 0 or at < a.first_at:
            a.first_at = at
        if seq >= a.last_seq:
            a.last_seq = seq
            a.last_at = at
            a.last_lines = lines
            a.version = version
        if at > self.cut30:
            a.commits30 += 1
        elif at > self.cut60:
            a.commits60 += 1
        if at <= self.cut30 and seq >= a.cut_seq:
            a.cut_seq = seq
            a.cut_lines = lines

    def finish(self, repos: Int) -> Overview:
        """The overview, for `repos` repositories in mojo.repos."""
        var o = Overview()
        o.repos = repos
        var now_month = month_of_days(self.now_days)
        var fam_index = Dict[String, Int]()
        var oldest = List[String]()
        var best = String()  # newest released version among active repos
        var best_any = String()
        for ref a in self.accs:
            if a.commits == 0:
                continue
            o.with_history += 1
            o.commits += a.commits
            o.commits_30 += a.commits30
            o.commits_prev_30 += a.commits60
            o.lines += a.last_lines
            if a.cut_seq >= 0:
                o.lines_30_ago += a.cut_lines
            if a.first_at <= self.cut30:
                o.repos_30_ago += 1
            var fm = month_of_days(Int(a.first_at // DAY_US))
            if fm == now_month:
                o.new_this_month += 1
            elif fm == now_month - 1:
                o.new_last_month += 1
            var active = a.last_at >= self.cut_active
            if active:
                o.active += 1
        # Families: every repository, including the ones not read (unknown).
        for ref a in self.accs:
            var f = family_of(a.version)
            if f not in fam_index:
                fam_index[f] = len(o.families)
                o.families.append(f)
                oldest.append(a.version)
                o.family_repos.append(0)
                o.family_active.append(0)
            var i = fam_index.get(f, 0)
            o.family_repos[i] += 1
            if len(version_key(a.version)) > 0 and compare_versions(a.version, oldest[i]) < 0:
                oldest[i] = a.version
            if a.commits > 0 and a.last_at >= self.cut_active:
                o.family_active[i] += 1
                if f != "unknown":
                    o.known_active += 1
                if len(version_key(a.version)) > 0:
                    if best_any.byte_length() == 0 or compare_versions(a.version, best_any) > 0:
                        best_any = a.version
                    var key = version_key(a.version)
                    if key[3] == 1 and (
                        best.byte_length() == 0 or compare_versions(a.version, best) > 0
                    ):
                        best = a.version
        _order_families(o, oldest)
        var newest = best if best.byte_length() > 0 else best_any
        if newest.byte_length() > 0:
            o.newest_version = newest
            o.newest_family = version_family(newest)
            for i in range(len(o.families)):
                if o.families[i] == o.newest_family:
                    o.newest_active = o.family_active[i]
        # The curves, from the first month with a commit.
        var m = self.months
        var lines = List[Int64](length=m, fill=0)
        var nrepos = List[Int64](length=m, fill=0)
        var none = List[Int64](length=m, fill=0)
        var magic = List[Int64](length=m, fill=0)
        var pixi = List[Int64](length=m, fill=0)
        var seq_p = self.cell_seq.unsafe_ptr()
        var lines_p = self.cell_lines.unsafe_ptr()
        var tool_p = self.cell_tool.unsafe_ptr()
        for r in range(len(self.accs)):
            var started = False
            var carry_lines = Int64(0)
            var carry_tool = TOOL_NONE
            for k in range(m):
                var cell = r * m + k
                if seq_p[unsafe_offset=cell] >= 0:
                    started = True
                    carry_lines = lines_p[unsafe_offset=cell]
                    carry_tool = tool_p[unsafe_offset=cell]
                if started:
                    lines[k] += carry_lines
                    nrepos[k] += 1
                    if carry_tool == TOOL_MAGIC:
                        magic[k] += 1
                    elif carry_tool == TOOL_PIXI:
                        pixi[k] += 1
                    else:
                        none[k] += 1
        var first = 0
        while first < m - 1 and nrepos[first] == 0:
            first += 1
        for k in range(first, m):
            o.months.append(month_label(BASE_MONTH + k))
            o.lines_series.append(lines[k])
            o.repos_series.append(nrepos[k])
            o.commits_series.append(self.commits_by_month[k])
            o.tool_none.append(none[k])
            o.tool_magic.append(magic[k])
            o.tool_pixi.append(pixi[k])
        return o^


def _order_families(mut o: Overview, oldest: List[String]):
    """`o.families` in Mojo's order: the versions oldest first, then `other`,
    then `unknown`; the counts follow."""
    var names = List[String]()
    var old = List[String]()
    var repos = List[Int]()
    var active = List[Int]()
    var unknown = -1
    for i in range(len(o.families)):
        if o.families[i] == "unknown":
            unknown = i
            continue
        names.append(o.families[i])
        old.append(oldest[i])
        repos.append(o.family_repos[i])
        active.append(o.family_active[i])
    var sorted_names = names.copy()
    var sorted_old = old.copy()
    sort_families(sorted_names, sorted_old)
    var out_names = List[String]()
    var out_repos = List[Int]()
    var out_active = List[Int]()
    for f in sorted_names:
        for i in range(len(names)):
            if names[i] == f:
                out_names.append(names[i])
                out_repos.append(repos[i])
                out_active.append(active[i])
                break
    if unknown >= 0:
        out_names.append(String("unknown"))
        out_repos.append(o.family_repos[unknown])
        out_active.append(o.family_active[unknown])
    o.families = out_names^
    o.family_repos = out_repos^
    o.family_active = out_active^


def family_color(family: String) -> String:
    """The CSS colour of a version family, the same on every chart: the five
    families Mojo has had, `other` and `unknown` in greys."""
    if family == "24.x":
        return String("var(--c0)")
    if family == "25.x":
        return String("var(--c1)")
    if family == "0.25.x":
        return String("var(--c2)")
    if family == "0.26.x":
        return String("var(--c3)")
    if family == "1.x":
        return String("var(--c4)")
    if family == "unknown":
        return String("var(--border-strong)")
    return String("var(--c5)")


def top_gains(gains: List[Int64], n: Int) -> List[Int]:
    """The indices of the `n` largest positive values of `gains`, largest
    first; ties keep the order they came in."""
    var out = List[Int]()
    for i in range(len(gains)):
        if gains[i] <= 0:
            continue
        var j = len(out)
        out.append(i)
        while j > 0 and gains[out[j - 1]] < gains[i]:
            out[j] = out[j - 1]
            j -= 1
        out[j] = i
        if len(out) > n:
            _ = out.pop()
    return out^
