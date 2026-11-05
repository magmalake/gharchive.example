"""What the console shows, read from the lake: one `Library` per row of
mojo.repos, with what mojo.commits and mojo.migrations say about it, and its
latest row of mojo.repo_stats; and per repository its activity by month
(mojo.activity), releases (mojo.releases) and tags (mojo.tags)."""

from cols import bool_at, col, has_col, i32_at, i64_at, is_valid, str_at, strs_at
from days import day_text
from jscan import micros_to_iso
from lake import exists, load
from versions import compare_versions


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


def libraries() raises -> List[Library]:
    """Every library, biggest (lines of Mojo now) first."""
    var out = List[Library]()
    if not exists("mojo", "repos"):
        return out^
    var index = Dict[String, Int]()
    for b in load("mojo", "repos").scan().to_batches():
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
                )
            )
    _latest_stats(out, index)
    if exists("mojo", "commits"):
        var last_seq = Dict[String, Int64]()
        for b in (
            load("mojo", "commits")
            .scan()
            .select(["repo", "committed_at", "seq", "mojo_lines", "mojo_files", "tooling", "mojo_version"])
            .to_batches()
        ):
            var c_repo = col(b, "repo")
            var c_at = col(b, "committed_at")
            var c_seq = col(b, "seq")
            var c_lines = col(b, "mojo_lines")
            var c_files = col(b, "mojo_files")
            var c_tool = col(b, "tooling")
            var c_ver = col(b, "mojo_version")
            for r in range(b.num_rows):
                var repo = str_at(b.column(c_repo), r)
                if repo not in index:
                    continue
                ref lib = out[index[repo]]
                var at = i64_at(b.column(c_at), r)
                var seq = i64_at(b.column(c_seq), r)
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
    # Biggest first.
    for i in range(1, len(out)):
        var j = i
        while j > 0 and out[j - 1].mojo_lines < out[j].mojo_lines:
            out.swap_elements(j - 1, j)
            j -= 1
    return out^


def _latest_stats(mut libs: List[Library], index: Dict[String, Int]) raises:
    """Each library's stars, forks and topics from its latest row of
    mojo.repo_stats, when it has one with numbers."""
    if not exists("mojo", "repo_stats"):
        return
    for b in load("mojo", "repo_stats").scan().to_batches():
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


def activity_by_month(repo: String) raises -> List[MonthActivity]:
    """`repo`'s GH Archive activity summed by month, oldest first; only the
    months it had events in."""
    var out = List[MonthActivity]()
    if not exists("mojo", "activity"):
        return out^
    var at = Dict[String, Int]()
    for b in load("mojo", "activity").scan().filter(_repo_filter(repo)).to_batches():
        var c_day = col(b, "day")
        var c_stars = col(b, "stars")
        var c_forks = col(b, "forks")
        var c_rel = col(b, "releases")
        var c_iss = col(b, "issues_opened")
        var c_prs = col(b, "prs_opened")
        var c_push = col(b, "pushes")
        for r in range(b.num_rows):
            var m = String(day_text(i32_at(b.column(c_day), r))[byte=:7])
            if m not in at:
                at[m] = len(out)
                out.append(MonthActivity(m, 0, 0, 0, 0, 0, 0, 0))
            ref a = out[at[m]]
            a.stars += i64_at(b.column(c_stars), r)
            a.forks += i64_at(b.column(c_forks), r)
            a.releases += i64_at(b.column(c_rel), r)
            a.issues_opened += i64_at(b.column(c_iss), r)
            a.prs_opened += i64_at(b.column(c_prs), r)
            a.pushes += i64_at(b.column(c_push), r)
            a.days_active += 1
    for i in range(1, len(out)):
        var j = i
        while j > 0 and out[j - 1].month > out[j].month:
            out.swap_elements(j - 1, j)
            j -= 1
    return out^


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


def releases(repo: String) raises -> List[Release]:
    """`repo`'s published releases (mojo.releases) and git tags (mojo.tags),
    newest first; a tag that is also a release is listed once, as the
    release, with the tag's commit and Mojo version."""
    var out = List[Release]()
    var by_tag = Dict[String, Int]()
    if exists("mojo", "releases"):
        for b in load("mojo", "releases").scan().filter(_repo_filter(repo)).to_batches():
            var c_tag = col(b, "tag")
            var c_name = col(b, "name")
            var c_pub = col(b, "published_at")
            var c_day = col(b, "day")
            var c_pre = col(b, "prerelease")
            for r in range(b.num_rows):
                var tag = str_at(b.column(c_tag), r)
                if tag in by_tag:
                    continue
                var at = i64_at(b.column(c_pub), r)
                if at == 0:
                    at = i32_at(b.column(c_day), r) * 86_400_000_000
                by_tag[tag] = len(out)
                out.append(Release(
                    tag, str_at(b.column(c_name), r), at,
                    bool_at(b.column(c_pre), r), String("release"), String(), String(),
                ))
    if exists("mojo", "tags"):
        for b in load("mojo", "tags").scan().filter(_repo_filter(repo)).to_batches():
            var c_tag = col(b, "tag")
            var c_commit = col(b, "commit")
            var c_at = col(b, "tagged_at")
            var c_ver = col(b, "mojo_version")
            for r in range(b.num_rows):
                var tag = str_at(b.column(c_tag), r)
                var commit = str_at(b.column(c_commit), r)
                var ver = str_at(b.column(c_ver), r)
                if tag in by_tag:
                    ref x = out[by_tag[tag]]
                    x.commit = commit
                    x.mojo_version = ver
                    continue
                by_tag[tag] = len(out)
                out.append(Release(
                    tag, String(), i64_at(b.column(c_at), r), False, String("tag"),
                    commit, ver,
                ))
    for i in range(1, len(out)):
        var j = i
        while j > 0 and out[j - 1].at < out[j].at:
            out.swap_elements(j - 1, j)
            j -= 1
    return out^


def history(repo: String) raises -> List[Point]:
    """One point per commit of `repo`, oldest first."""
    var out = List[Point]()
    if not exists("mojo", "commits"):
        return out^
    var seqs = List[Int64]()
    var filter = String('["=","repo","', repo.replace('"', ""), '"]')
    for b in load("mojo", "commits").scan().filter(filter).to_batches():
        var c_at = col(b, "committed_at")
        var c_seq = col(b, "seq")
        var c_lines = col(b, "mojo_lines")
        var c_sha = col(b, "sha")
        var c_tool = col(b, "tooling")
        var c_ver = col(b, "mojo_version")
        for r in range(b.num_rows):
            seqs.append(i64_at(b.column(c_seq), r))
            out.append(
                Point(
                    i64_at(b.column(c_at), r),
                    i64_at(b.column(c_lines), r),
                    str_at(b.column(c_sha), r),
                    str_at(b.column(c_tool), r),
                    str_at(b.column(c_ver), r),
                )
            )
    # By seq (the scan's order is the files').
    for i in range(1, len(out)):
        var j = i
        while j > 0 and seqs[j - 1] > seqs[j]:
            seqs.swap_elements(j - 1, j)
            out.swap_elements(j - 1, j)
            j -= 1
    return out^


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
    """How many libraries moved to each Mojo version, by month, in version
    order within a month."""
    var counts = Dict[String, Int]()
    var seen = Dict[String, Bool]()
    for m in migrations():
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
