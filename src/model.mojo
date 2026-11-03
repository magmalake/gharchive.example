"""What the console shows, read from the lake: one `Library` per row of
mojo.repos, with what mojo.commits and mojo.migrations say about it."""

from cols import col, i64_at, is_valid, str_at
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
                )
            )
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
