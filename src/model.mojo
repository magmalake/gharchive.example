"""What the console shows, read from the lake: one `Library` per row of
mojo.repos, with what mojo.commits and mojo.migrations say about it, and its
latest row of mojo.repo_stats; and per repository its activity by month
(mojo.activity), releases (mojo.releases) and tags (mojo.tags)."""

from cols import bool_at, col, has_col, i32_at, i64_at, is_valid, str_at, strs_at
from days import day_text
from jscan import micros_to_iso
from lake import exists, load, try_load
from overview import Builder, tool_code
from versions import compare_versions, usable


@fieldwise_init
struct Library(Copyable, Movable):
    var repo: String
    var description: String
    var created_at: Int64
    var first_seen: Int64
    var found_by: String
    var stars: Int64
    var forks: Int64
    var license: String
    var size_kb: Int64
    var commits: Int
    var first_commit: Int64
    var last_commit: Int64
    var mojo_lines: Int64
    var mojo_files: Int64
    var tooling: String
    var mojo_version: String
    var topics: List[String]
    var stats_as_of: Int64
    """The day (days since 1970) of the mojo.repo_stats row the stars,
    forks and topics come from; 0 when they are from discovery."""
    var open_issues: Int64
    var watchers: Int64
    var archived: Bool
    var state: String
    """mojo.repo_stats' `state` (`ok`, `renamed`, `gone`, ...), or ""."""
    var renamed_to: String
    var version_source: String
    """Where `mojo_version` was read: the lock file or manifest of the last
    commit (`pixi.lock`, `pixi.toml`, ...), or mojo.repo_versions' `ci`,
    `docker`, `readme`, `file`, `repo`; empty for no version."""
    var version_file: String
    """The file of mojo.repo_versions it came from, if it did."""
    var version_estimate: String
    """The release current at the last commit that touched a Mojo file, by
    date (mojo.repo_versions); a guess, kept apart from `mojo_version`."""


@fieldwise_init
struct RepoVersion(Copyable, Movable):
    """A row of mojo.repo_versions."""

    var version: String
    var source: String
    var file: String
    var estimate: String


@fieldwise_init
struct Point(Copyable, Movable):
    var at: Int64
    var lines: Int64
    var sha: String
    var tooling: String
    var version: String


@fieldwise_init
struct Migration(Copyable, Movable):
    var repo: String
    var sha: String
    var at: Int64
    var kind: String
    var from_value: String
    var to_value: String


def day(micros: Int64) -> String:
    """`YYYY-MM-DD`, or "" for no time."""
    if micros == 0:
        return String()
    var iso = micros_to_iso(micros)
    return String(iso[byte=:10])


def libraries(mut ob: Builder) raises -> List[Library]:
    """Every library, biggest (lines of Mojo now) first. Each commit row is
    also given to `ob` (the Overview's numbers), so the commits are scanned
    once for both."""
    var out = List[Library]()
    var repos_table = try_load("mojo", "repos")
    if not repos_table:
        return out^
    var index = Dict[String, Int]()
    var ids = List[Int]()
    for b in repos_table.value().scan().to_batches():
        var c_repo = col(b, "repo")
        var c_desc = col(b, "description")
        var c_created = col(b, "created_at")
        var c_first = col(b, "first_seen")
        var c_found = col(b, "found_by")
        var c_stars = col(b, "stars")
        var c_forks = col(b, "forks")
        var c_lic = col(b, "license")
        var c_size = col(b, "size_kb")
        var c_topics = col(b, "topics") if has_col(b, "topics") else -1
        for r in range(b.num_rows):
            var repo = str_at(b.column(c_repo), r)
            if repo in index:
                continue
            index[repo] = len(out)
            ids.append(ob.add_repo(repo))
            out.append(
                Library(
                    repo,
                    str_at(b.column(c_desc), r),
                    i64_at(b.column(c_created), r),
                    i64_at(b.column(c_first), r),
                    str_at(b.column(c_found), r),
                    i64_at(b.column(c_stars), r),
                    i64_at(b.column(c_forks), r),
                    str_at(b.column(c_lic), r),
                    i64_at(b.column(c_size), r),
                    0, 0, 0, 0, 0, String(), String(),
                    strs_at(b, c_topics, r) if c_topics >= 0 else List[String](),
                    0, 0, 0, False, String(), String(),
                    String(), String(), String(),
                )
            )
    _latest_stats(out, index)
    var commits_table = try_load("mojo", "commits")
    if commits_table:
        var last_seq = Dict[String, Int64]()
        for b in (
            commits_table.value()
            .scan()
            .select(["repo", "committed_at", "seq", "mojo_lines", "mojo_files", "tooling", "mojo_version", "version_source"])
            .to_batches()
        ):
            var c_repo = col(b, "repo")
            var c_at = col(b, "committed_at")
            var c_seq = col(b, "seq")
            var c_lines = col(b, "mojo_lines")
            var c_files = col(b, "mojo_files")
            var c_tool = col(b, "tooling")
            var c_ver = col(b, "mojo_version")
            var c_src = col(b, "version_source")
            for r in range(b.num_rows):
                var repo = str_at(b.column(c_repo), r)
                if repo not in index:
                    continue
                ref lib = out[index[repo]]
                var at = i64_at(b.column(c_at), r)
                var seq = i64_at(b.column(c_seq), r)
                ob.add_commit(
                    ids[index[repo]], at, seq, i64_at(b.column(c_lines), r),
                    tool_code(str_at(b.column(c_tool), r)), str_at(b.column(c_ver), r),
                )
                lib.commits += 1
                if lib.first_commit == 0 or at < lib.first_commit:
                    lib.first_commit = at
                if seq >= last_seq.get(repo, Int64(-1)):
                    last_seq[repo] = seq
                    lib.last_commit = at
                    lib.mojo_lines = i64_at(b.column(c_lines), r)
                    lib.mojo_files = i64_at(b.column(c_files), r)
                    lib.tooling = str_at(b.column(c_tool), r)
                    lib.mojo_version = str_at(b.column(c_ver), r)
                    lib.version_source = str_at(b.column(c_src), r)
    # Versions the history couldn't read (no manifest), from the files at HEAD,
    # and the estimate by date.
    var heads = repo_versions()
    for i in range(len(out)):
        ref lib = out[i]
        if lib.repo in heads:
            ref rv = heads[lib.repo]
            if not usable(lib.mojo_version) and usable(rv.version):
                lib.mojo_version = rv.version
                lib.version_source = rv.source
                lib.version_file = rv.file
            lib.version_estimate = rv.estimate
        ob.set_version(ids[i], lib.mojo_version, lib.version_estimate)
    # Biggest first.
    for i in range(1, len(out)):
        var j = i
        while j > 0 and out[j - 1].mojo_lines < out[j].mojo_lines:
            out.swap_elements(j - 1, j)
            j -= 1
    return out^


def repo_versions() raises -> Dict[String, RepoVersion]:
    """Each repository's row of mojo.repo_versions (the newest if there are
    several); empty if the table doesn't exist."""
    var out = Dict[String, RepoVersion]()
    var read = Dict[String, Int64]()
    var t = try_load("mojo", "repo_versions")
    if not t:
        return out^
    for b in t.value().scan().to_batches():
        var c_repo = col(b, "repo")
        var c_at = col(b, "read_at")
        var c_ver = col(b, "mojo_version")
        var c_src = col(b, "version_source")
        var c_file = col(b, "version_file")
        var c_est = col(b, "version_estimate")
        for r in range(b.num_rows):
            var repo = str_at(b.column(c_repo), r)
            var at = i64_at(b.column(c_at), r)
            if repo in read and read[repo] >= at:
                continue
            read[repo] = at
            out[repo] = RepoVersion(
                str_at(b.column(c_ver), r), str_at(b.column(c_src), r),
                str_at(b.column(c_file), r), str_at(b.column(c_est), r),
            )
    return out^


def _latest_stats(mut libs: List[Library], index: Dict[String, Int]) raises:
    """Each library's stars, forks and topics from its latest row of
    mojo.repo_stats, when it has one with numbers."""
    var stats_table = try_load("mojo", "repo_stats")
    if not stats_table:
        return
    for b in stats_table.value().scan().to_batches():
        var c_repo = col(b, "repo")
        var c_as_of = col(b, "as_of")
        var c_state = col(b, "state")
        var c_stars = col(b, "stars")
        var c_forks = col(b, "forks")
        var c_issues = col(b, "open_issues")
        var c_watch = col(b, "watchers")
        var c_topics = col(b, "topics")
        var c_arch = col(b, "archived")
        var c_desc = col(b, "description")
        var c_lic = col(b, "license")
        var c_new = col(b, "renamed_to")
        for r in range(b.num_rows):
            var repo = str_at(b.column(c_repo), r)
            if repo not in index:
                continue
            ref l = libs[index[repo]]
            var as_of = i32_at(b.column(c_as_of), r)
            if as_of < l.stats_as_of:
                continue
            l.state = str_at(b.column(c_state), r)
            l.renamed_to = str_at(b.column(c_new), r)
            if not is_valid(b.column(c_stars), r):
                continue  # gone, blocked: keep the numbers from before
            l.stats_as_of = as_of
            l.stars = i64_at(b.column(c_stars), r)
            l.forks = i64_at(b.column(c_forks), r)
            l.open_issues = i64_at(b.column(c_issues), r)
            l.watchers = i64_at(b.column(c_watch), r)
            l.topics = strs_at(b, c_topics, r)
            l.archived = bool_at(b.column(c_arch), r)
            var desc = str_at(b.column(c_desc), r)
            if desc.byte_length() > 0:
                l.description = desc
            var lic = str_at(b.column(c_lic), r)
            if lic.byte_length() > 0:
                l.license = lic


@fieldwise_init
struct MonthActivity(Copyable, Movable):
    var month: String
    """`YYYY-MM`."""
    var stars: Int64
    var forks: Int64
    var releases: Int64
    var issues_opened: Int64
    var prs_opened: Int64
    var pushes: Int64
    var days_active: Int


def activity_months() raises -> List[String]:
    """The months mojo.activity has rows in, oldest first: the months of GH
    Archive loaded so far (`YYYY-MM`)."""
    var seen = Dict[String, Bool]()
    var out = List[String]()
    if not exists("mojo", "activity"):
        return out^
    for b in load("mojo", "activity").scan().select(["day"]).to_batches():
        for r in range(b.num_rows):
            var m = String(day_text(i32_at(b.column(0), r))[byte=:7])
            if m not in seen:
                seen[m] = True
                out.append(m)
    for i in range(1, len(out)):
        var j = i
        while j > 0 and out[j - 1] > out[j]:
            out.swap_elements(j - 1, j)
            j -= 1
    return out^


def _repo_filter(repo: String) -> String:
    return String('["=","repo","', repo.replace('"', ""), '"]')


def activity_all(repo: String = "") raises -> Dict[String, List[MonthActivity]]:
    """GH Archive activity summed by month per repo (only `repo`'s when
    given), oldest month first; only the months with events."""
    var out = Dict[String, List[MonthActivity]]()
    if not exists("mojo", "activity"):
        return out^
    var at = Dict[String, Int]()  # repo|month -> index in the repo's list
    var scan = load("mojo", "activity").scan()
    if repo.byte_length() > 0:
        scan = scan.filter(_repo_filter(repo))
    for b in scan.to_batches():
        var c_repo = col(b, "repo")
        var c_day = col(b, "day")
        var c_stars = col(b, "stars")
        var c_forks = col(b, "forks")
        var c_rel = col(b, "releases")
        var c_iss = col(b, "issues_opened")
        var c_prs = col(b, "prs_opened")
        var c_push = col(b, "pushes")
        for r in range(b.num_rows):
            var name = str_at(b.column(c_repo), r)
            var m = String(day_text(i32_at(b.column(c_day), r))[byte=:7])
            var key = String(name, "|", m)
            if name not in out:
                out[name] = List[MonthActivity]()
            ref list = out[name]
            if key not in at:
                at[key] = len(list)
                list.append(MonthActivity(m, 0, 0, 0, 0, 0, 0, 0))
            ref a = list[at[key]]
            a.stars += i64_at(b.column(c_stars), r)
            a.forks += i64_at(b.column(c_forks), r)
            a.releases += i64_at(b.column(c_rel), r)
            a.issues_opened += i64_at(b.column(c_iss), r)
            a.prs_opened += i64_at(b.column(c_prs), r)
            a.pushes += i64_at(b.column(c_push), r)
            a.days_active += 1
    for e in out.items():
        ref list = out[e.key]
        for i in range(1, len(list)):
            var j = i
            while j > 0 and list[j - 1].month > list[j].month:
                list.swap_elements(j - 1, j)
                j -= 1
    return out^


def activity_by_month(repo: String) raises -> List[MonthActivity]:
    """`repo`'s GH Archive activity summed by month, oldest first."""
    var all = activity_all(repo)
    if repo in all:
        return all.pop(repo)
    return List[MonthActivity]()


@fieldwise_init
struct Release(Copyable, Movable):
    var tag: String
    var name: String
    var at: Int64
    """Published (microseconds), or the event's day when the payload had no
    date."""
    var prerelease: Bool
    var source: String
    """`release` (GH Archive's ReleaseEvent) or `tag` (git)."""
    var commit: String
    var mojo_version: String


def releases_all(repo: String = "") raises -> Dict[String, List[Release]]:
    """The published releases (mojo.releases) and git tags (mojo.tags) of
    every repo (only `repo`'s when given), newest first; a tag that is also a
    release is listed once, as the release, with the tag's commit and Mojo
    version."""
    var out = Dict[String, List[Release]]()
    var by_tag = Dict[String, Int]()  # repo|tag -> index in the repo's list
    if exists("mojo", "releases"):
        var scan = load("mojo", "releases").scan()
        if repo.byte_length() > 0:
            scan = scan.filter(_repo_filter(repo))
        for b in scan.to_batches():
            var c_repo = col(b, "repo")
            var c_tag = col(b, "tag")
            var c_name = col(b, "name")
            var c_pub = col(b, "published_at")
            var c_day = col(b, "day")
            var c_pre = col(b, "prerelease")
            for r in range(b.num_rows):
                var name = str_at(b.column(c_repo), r)
                var tag = str_at(b.column(c_tag), r)
                var key = String(name, "|", tag)
                if key in by_tag:
                    continue
                var at = i64_at(b.column(c_pub), r)
                if at == 0:
                    at = i32_at(b.column(c_day), r) * 86_400_000_000
                if name not in out:
                    out[name] = List[Release]()
                ref list = out[name]
                by_tag[key] = len(list)
                list.append(Release(
                    tag, str_at(b.column(c_name), r), at,
                    bool_at(b.column(c_pre), r), String("release"), String(), String(),
                ))
    if exists("mojo", "tags"):
        var scan = load("mojo", "tags").scan()
        if repo.byte_length() > 0:
            scan = scan.filter(_repo_filter(repo))
        for b in scan.to_batches():
            var c_repo = col(b, "repo")
            var c_tag = col(b, "tag")
            var c_commit = col(b, "commit")
            var c_at = col(b, "tagged_at")
            var c_ver = col(b, "mojo_version")
            for r in range(b.num_rows):
                var name = str_at(b.column(c_repo), r)
                var tag = str_at(b.column(c_tag), r)
                var commit = str_at(b.column(c_commit), r)
                var ver = str_at(b.column(c_ver), r)
                var key = String(name, "|", tag)
                if name not in out:
                    out[name] = List[Release]()
                ref list = out[name]
                if key in by_tag:
                    ref x = list[by_tag[key]]
                    x.commit = commit
                    x.mojo_version = ver
                    continue
                by_tag[key] = len(list)
                list.append(Release(
                    tag, String(), i64_at(b.column(c_at), r), False, String("tag"),
                    commit, ver,
                ))
    for e in out.items():
        ref list = out[e.key]
        for i in range(1, len(list)):
            var j = i
            while j > 0 and list[j - 1].at < list[j].at:
                list.swap_elements(j - 1, j)
                j -= 1
    return out^


def releases(repo: String) raises -> List[Release]:
    """`repo`'s releases and tags, newest first (`releases_all`)."""
    var all = releases_all(repo)
    if repo in all:
        return all.pop(repo)
    return List[Release]()


def histories(repo: String = "") raises -> Dict[String, List[Point]]:
    """One point per commit of every repo (only `repo`'s when given), oldest
    first."""
    var out = Dict[String, List[Point]]()
    if not exists("mojo", "commits"):
        return out^
    var seqs = Dict[String, List[Int64]]()
    var scan = load("mojo", "commits").scan()
    if repo.byte_length() > 0:
        scan = scan.filter(_repo_filter(repo))
    for b in scan.select(["repo", "committed_at", "seq", "mojo_lines", "sha", "tooling", "mojo_version"]).to_batches():
        var c_repo = col(b, "repo")
        var c_at = col(b, "committed_at")
        var c_seq = col(b, "seq")
        var c_lines = col(b, "mojo_lines")
        var c_sha = col(b, "sha")
        var c_tool = col(b, "tooling")
        var c_ver = col(b, "mojo_version")
        for r in range(b.num_rows):
            var name = str_at(b.column(c_repo), r)
            if name not in out:
                out[name] = List[Point]()
                seqs[name] = List[Int64]()
            seqs[name].append(i64_at(b.column(c_seq), r))
            out[name].append(
                Point(
                    i64_at(b.column(c_at), r),
                    i64_at(b.column(c_lines), r),
                    str_at(b.column(c_sha), r),
                    str_at(b.column(c_tool), r),
                    str_at(b.column(c_ver), r),
                )
            )
    # By seq (the scan's order is the files').
    for e in out.items():
        ref list = out[e.key]
        ref sq = seqs[e.key]
        for i in range(1, len(list)):
            var j = i
            while j > 0 and sq[j - 1] > sq[j]:
                sq.swap_elements(j - 1, j)
                list.swap_elements(j - 1, j)
                j -= 1
    return out^


def history(repo: String) raises -> List[Point]:
    """One point per commit of `repo`, oldest first."""
    var all = histories(repo)
    if repo in all:
        return all.pop(repo)
    return List[Point]()


def migrations(repo: String = "") raises -> List[Migration]:
    """Every migration (of `repo`, if given), oldest first."""
    var out = List[Migration]()
    if not exists("mojo", "migrations"):
        return out^
    var scan = load("mojo", "migrations").scan()
    if repo.byte_length() > 0:
        scan = scan.filter(String('["=","repo","', repo.replace('"', ""), '"]'))
    for b in scan.to_batches():
        var c_repo = col(b, "repo")
        var c_sha = col(b, "sha")
        var c_at = col(b, "committed_at")
        var c_kind = col(b, "kind")
        var c_from = col(b, "from_value")
        var c_to = col(b, "to_value")
        for r in range(b.num_rows):
            out.append(
                Migration(
                    str_at(b.column(c_repo), r),
                    str_at(b.column(c_sha), r),
                    i64_at(b.column(c_at), r),
                    str_at(b.column(c_kind), r),
                    str_at(b.column(c_from), r),
                    str_at(b.column(c_to), r),
                )
            )
    for i in range(1, len(out)):
        var j = i
        while j > 0 and out[j - 1].at > out[j].at:
            out.swap_elements(j - 1, j)
            j -= 1
    return out^


@fieldwise_init
struct VersionMonth(Copyable, Movable):
    var month: String
    var version: String
    var repos: Int


def versions_by_month() raises -> List[VersionMonth]:
    return versions_of(migrations())


def versions_of(ms: List[Migration]) -> List[VersionMonth]:
    """How many libraries moved to each Mojo version, by month, in version
    order within a month."""
    var counts = Dict[String, Int]()
    var seen = Dict[String, Bool]()
    for ref m in ms:
        if m.kind != "mojo_version" or m.to_value.byte_length() == 0:
            continue
        var month = String(day(m.at)[byte=:7])
        var k = String(month, "|", m.to_value)
        var once = String(k, "|", m.repo)
        if once in seen:
            continue
        seen[once] = True
        counts[k] = counts.get(k, 0) + 1
    var out = List[VersionMonth]()
    for e in counts.items():
        var parts = e.key.split("|")
        out.append(VersionMonth(String(parts[0]), String(parts[1]), e.value))
    for i in range(1, len(out)):
        var j = i
        while j > 0 and (
            out[j - 1].month > out[j].month
            or (
                out[j - 1].month == out[j].month
                and compare_versions(out[j - 1].version, out[j].version) > 0
            )
        ):
            out.swap_elements(j - 1, j)
            j -= 1
    return out^


struct Sources(Copyable, Movable):
    """Where the console's data stood when it was read: the current
    snapshot of each table it builds pages from, to tell when anything
    changed."""

    var ids: List[Int64]
    """The current snapshot id of each table `read_sources` looks at (repos,
    commits, repo_stats, activity), -1 for a table that doesn't exist or is
    empty."""
    var as_of_ms: Int64
    """The newest snapshot time of those tables."""
    var days: Int
    """GH Archive days loaded into gharchive.events (`read_days`)."""
    var first_day: String
    var last_day: String

    def __init__(out self):
        self.ids = List[Int64]()
        self.as_of_ms = 0
        self.days = 0
        self.first_day = String()
        self.last_day = String()

    def same_as(self, other: Sources) -> Bool:
        if len(self.ids) != len(other.ids):
            return False
        for i in range(len(self.ids)):
            if self.ids[i] != other.ids[i]:
                return False
        return True


def read_sources() raises -> Sources:
    """The snapshots the tables are at now (metadata only) and the time of
    the newest."""
    var out = Sources()
    var names: List[String] = [
        "repos", "commits", "repo_stats", "activity", "migrations", "releases", "tags",
    ]
    for name in names:
        var t = try_load("mojo", name)
        if not t or not t.value().metadata.has_current_snapshot:
            out.ids.append(-1)
            continue
        out.ids.append(t.value().metadata.current_snapshot_id)
        out.as_of_ms = max(out.as_of_ms, t.value().metadata.current_snapshot().timestamp_ms)
    return out^


def read_days(mut src: Sources) raises:
    """Count the GH Archive days gharchive.events holds into `src`: the days
    its snapshots' `orca.partitions` name."""
    var t = try_load("gharchive", "events")
    if not t:
        return
    var seen = Dict[String, Bool]()
    for ref s in t.value().metadata.snapshots:
        for key in s.summary.get("orca.partitions", String("")).split(","):
            var k = String(key.strip())
            # A day looks like 2026-10-13; other keys aren't counted.
            if k.byte_length() == 10 and k[byte=4] == "-" and k not in seen:
                seen[k] = True
                if src.first_day.byte_length() == 0 or k < src.first_day:
                    src.first_day = k
                if k > src.last_day:
                    src.last_day = k
    src.days = len(seen)


def star_gains(since_day: Int) raises -> Dict[String, Int64]:
    """Stars (WatchEvents) per repository on the days since `since_day`
    (days since 1970-01-01), from mojo.activity."""
    var out = Dict[String, Int64]()
    var activity_table = try_load("mojo", "activity")
    if not activity_table:
        return out^
    for b in activity_table.value().scan().select(["repo", "day", "stars"]).to_batches():
        var c_repo = col(b, "repo")
        var c_day = col(b, "day")
        var c_stars = col(b, "stars")
        for r in range(b.num_rows):
            if Int(i32_at(b.column(c_day), r)) < since_day:
                continue
            var n = i64_at(b.column(c_stars), r)
            if n > 0:
                var repo = str_at(b.column(c_repo), r)
                out[repo] = out.get(repo, Int64(0)) + n
    return out^
