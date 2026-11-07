"""A repository's history: lines of Mojo, tooling and Mojo version at each
commit, and the commits where the tooling or the version changed.

`read_history` clones the repository (bare, into `MOJO_HISTORY_WORKDIR`,
default `$TMPDIR/mojo_history`), walks its first-parent history once with
`git log --numstat --summary`, and reads a manifest or lock file only at the
commits that touch one. It also reads the clone's tags (`git
for-each-ref refs/tags`). `read_tags` reads only the tags, from a clone
without file contents, for a repository whose history mojo.commits already
has. It needs `git` on the PATH.
"""

from std.os import getenv
from std.subprocess import run

from dista import Seq

from versions import lock_version, manifest_version, tooling


@fieldwise_init
struct CommitRow(Copyable, Movable):
    """One commit of the first-parent history, as a row of `mojo.commits`:
    the totals of Mojo lines and files *after* it, and the tooling and Mojo
    version in force at it (carried forward from earlier commits when this
    one touched no manifest)."""

    var repo: String
    var sha: String
    var committed_at: Int64
    """Microseconds since the epoch, the committer's time."""
    var seq: Int64
    var mojo_lines: Int64
    var mojo_files: Int64
    var tooling: String
    var mojo_version: String
    var version_source: String


@fieldwise_init
struct MigrationRow(Copyable, Movable):
    """One change of tooling or of Mojo version, as a row of
    `mojo.migrations`, recorded at the commit that made it."""

    var repo: String
    var sha: String
    var committed_at: Int64
    var kind: String
    """`tooling` or `mojo_version`."""
    var from_value: String
    var to_value: String


@fieldwise_init
struct TagRow(Copyable, Movable):
    """One git tag, as a row of `mojo.tags`."""

    var repo: String
    var tag: String
    """The name under `refs/tags/`."""
    var commit: String
    """What the tag points at, peeled once for an annotated tag."""
    var annotated: Bool
    var tagged_at: Int64
    """The tagger's date (annotated) or the commit's (lightweight), in
    microseconds; 0 if git had none."""
    var tooling: String
    var mojo_version: String
    """At `commit`, when it is on the first-parent history; else empty."""


@fieldwise_init
struct History(Copyable, Movable):
    """What a dista task returns for one repository. A plain struct of
    `Seq`s so dista can send it by reflection. Failures travel in `error`
    rather than as an exception, so one bad repository doesn't fail the
    other 49 of its run."""

    var repo: String
    var error: String
    """Empty when the history was read."""
    var commits: Seq[CommitRow]
    var migrations: Seq[MigrationRow]
    var tags: Seq[TagRow]

    @staticmethod
    def empty(repo: String) -> Self:
        """A history with no rows and no error."""
        return Self(
            repo, String(), Seq[CommitRow](), Seq[MigrationRow](), Seq[TagRow]()
        )


comptime TAG_FORMAT = (
    "%(refname)%09%(objecttype)%09%(objectname)%09%(*objectname)%09%(creatordate:unix)"
)
"""`git for-each-ref --format`: tab-separated, as git refuses tabs in ref
names."""


def parse_tags(repo: String, output: String) -> List[TagRow]:
    """`git for-each-ref --format=TAG_FORMAT refs/tags` output as rows, by
    name. Lines that don't have the five fields are skipped."""
    var rows = List[TagRow]()
    for line in output.split("\n"):
        # An annotated tag is its own object (`tag`) that points at a commit
        # (`%(*objectname)`); a lightweight tag is the commit itself.
        var f = line.split("\t")
        if len(f) != 5:
            continue
        var name = String(f[0])
        if not name.startswith("refs/tags/"):
            continue
        var tag = String(name[byte=10:])
        if tag.byte_length() == 0:
            continue
        var annotated = String(f[1]) == "tag"
        var target = String(f[3]) if annotated and f[3].byte_length() > 0 else String(f[2])
        var at = Int64(0)
        try:
            at = Int64(Int(String(f[4]).strip())) * 1_000_000
        except:
            at = 0
        rows.append(TagRow(repo, tag, target, annotated, at, String(), String()))
    # An insertion sort by name, so a repository's tags always come out in
    # the same order whatever order git listed them in.
    for i in range(1, len(rows)):
        var j = i
        while j > 0 and rows[j - 1].tag > rows[j].tag:
            rows.swap_elements(j - 1, j)
            j -= 1
    return rows^


def join_tags(mut tags: List[TagRow], commits: Dict[String, Tuple[String, String]]):
    """Fills each tag's tooling and Mojo version from the commit it points
    at (sha -> (tooling, version))."""
    for ref t in tags:
        if t.commit in commits:
            var v = commits.get(t.commit, (String(), String()))
            t.tooling = v[0]
            t.mojo_version = v[1]


def _read_tags(repo: String, dir: String, mut out: History) raises:
    """Appends the clone's tags to `out.tags`, each with the tooling and
    Mojo version of the commit it points at when `out.commits` has it."""
    var r = _sh(String(
        "git -C '", dir, "' for-each-ref --format='", TAG_FORMAT, "' refs/tags",
    ))
    if r[0] != 0:
        raise Error("git for-each-ref failed: ", r[1].strip())
    var tags = parse_tags(repo, r[1])
    var by_sha = Dict[String, Tuple[String, String]]()
    for ref c in out.commits.items:
        by_sha[c.sha] = (c.tooling, c.mojo_version)
    join_tags(tags, by_sha)
    for ref t in tags:
        out.tags.append(t.copy())


def safe_repo(repo: String) -> Bool:
    """`owner/name` with GitHub's characters only, safe to put in a shell
    command (repository names reach `sh -c` in `_sh`, so nothing else may
    pass)."""
    var slashes = 0
    for c in repo.as_bytes():
        if c == UInt8(ord("/")):
            slashes += 1
        elif not (
            (c >= 48 and c <= 57)
            or (c >= 65 and c <= 90)
            or (c >= 97 and c <= 122)
            or c == UInt8(ord("-"))
            or c == UInt8(ord("_"))
            or c == UInt8(ord("."))
        ):
            return False
    return slashes == 1 and not repo.startswith(".") and ".." not in repo


def is_bazel_file(path: StringSlice) -> Bool:
    """The files that make a repository a Bazel one, at its root."""
    return (
        path == "MODULE.bazel"
        or path == "WORKSPACE"
        or path == "WORKSPACE.bazel"
        or path == "BUILD.bazel"
    )


def is_mojo_file(path: StringSlice) -> Bool:
    """Whether `path` is Mojo source, in either extension."""
    return path.endswith(".mojo") or path.endswith(".🔥")


def _sh(cmd: String) raises -> Tuple[Int, String]:
    """Runs `cmd` with `sh`, and returns its exit status and its output, any
    bytes that aren't UTF-8 dropped: an old commit's author or path can be
    Latin-1, and `run` refuses output that isn't UTF-8."""
    var out = run(
        String("{ ", cmd, '; echo "@@exit $?"; } | iconv -c -f UTF-8 -t UTF-8; true')
    )
    var at = out.rfind("@@exit ")
    if at < 0:
        return (-1, out^)
    var status = Int(String(out[byte = at + 7 :]).strip())
    return (status, String(out[byte=:at]))


def _show(dir: String, sha: String, file: String) raises -> String:
    """The contents of `file` at `sha`, or "" if it isn't there."""
    var r = _sh(String("git -C '", dir, "' show '", sha, ":", file, "' 2>/dev/null"))
    if r[0] != 0:
        return String()
    return r[1]


struct _State:
    """The commit being read, and what is true after it: which manifest
    and lock files exist (`pixi_toml` ... `bazel`), the running totals of
    Mojo `lines` and `files`, and the `tool`, `version` and `source` in
    force. Totals and files are carried from commit to commit; `_finish`
    turns the state into a row. `touched` is whether this commit added,
    removed or changed a manifest or lock file, which is the only time
    the version is read again."""

    var pixi_toml: Bool
    var pixi_lock: Bool
    var mojoproject: Bool
    var magic_lock: Bool
    var bazel: Bool
    var touched: Bool
    var lines: Int64
    var files: Int64
    var sha: String
    var at: Int64
    var seq: Int64
    var tool: String
    var version: String
    var source: String

    def __init__(out self):
        self.sha = String()
        self.at = 0
        self.seq = 0
        self.tool = String("none")
        self.version = String()
        self.source = String()
        self.pixi_toml = False
        self.pixi_lock = False
        self.mojoproject = False
        self.magic_lock = False
        self.bazel = False
        self.touched = False
        self.lines = 0
        self.files = 0

    def mark(mut self, path: String, exists: Bool):
        """Records that `path` now exists (or no longer does), if it is a
        file that decides the tooling or the version."""
        if path == "pixi.toml":
            self.pixi_toml = exists
        elif path == "pixi.lock":
            self.pixi_lock = exists
        elif path == "mojoproject.toml":
            self.mojoproject = exists
        elif path == "magic.lock":
            self.magic_lock = exists
        elif is_bazel_file(path):
            self.bazel = exists
            return  # the tooling changes, the Mojo version doesn't
        else:
            return
        self.touched = True


def _version(dir: String, sha: String, st: _State) raises -> Tuple[String, String]:
    """The Mojo version at `sha` and the file it came from, or two empty
    strings. Lock files win over manifests: a lock names the version that
    was actually resolved, a manifest only the range asked for."""
    for lock in ["magic.lock", "pixi.lock"]:
        if (lock == "magic.lock" and st.magic_lock) or (
            lock == "pixi.lock" and st.pixi_lock
        ):
            var v = lock_version(_show(dir, sha, lock))
            if v.byte_length() > 0:
                return (v^, String(lock))
    for m in ["pixi.toml", "mojoproject.toml"]:
        if (m == "pixi.toml" and st.pixi_toml) or (
            m == "mojoproject.toml" and st.mojoproject
        ):
            var v = manifest_version(_show(dir, sha, m))
            if v.byte_length() > 0:
                return (v^, String(m))
    return (String(), String())


def _finish(repo: String, dir: String, mut st: _State, mut out: History) raises:
    """Closes the commit `st` is at: one row, and any migrations."""
    if st.sha.byte_length() == 0:
        return
    var new_tool = tooling(
        st.pixi_toml, st.pixi_lock, st.mojoproject, st.magic_lock, st.bazel
    )
    if st.touched:
        # Only a commit that touches a manifest costs `git show`s. A manifest
        # that names no version (yet) leaves the earlier version standing; the
        # version is cleared only when no manifest or lock file is left.
        var v = _version(dir, st.sha, st)
        var any_file = st.pixi_toml or st.pixi_lock or st.mojoproject or st.magic_lock
        if v[0].byte_length() > 0 or not any_file:
            if v[0] != st.version:
                out.migrations.append(
                    MigrationRow(repo, st.sha, st.at, "mojo_version", st.version, v[0])
                )
            st.version = v[0]
            st.source = v[1]
    if new_tool != st.tool:
        out.migrations.append(
            MigrationRow(repo, st.sha, st.at, "tooling", st.tool, new_tool)
        )
        st.tool = new_tool
    out.commits.append(
        CommitRow(
            repo, st.sha, st.at, st.seq, st.lines, st.files, st.tool,
            st.version, st.source,
        )
    )
    st.seq += 1
    st.touched = False


def _path_of(line: StringSlice) -> String:
    """The path in a `--summary` line: ` create mode 100644 <path>`."""
    var s = String(line)
    var at = 0
    var spaces = 0
    var b = s.as_bytes()
    for i in range(len(b)):
        if b[i] == UInt8(ord(" ")):
            spaces += 1
            if spaces == 4:
                at = i + 1
                break
    return String(s[byte=at:])


def _parse_log(repo: String, dir: String, log: String, mut out: History) raises:
    """Turns the `git log` of `_read_history` into `out.commits` and
    `out.migrations`. Per commit git prints the `@@sha time` header, then
    its `--numstat` lines (`added<TAB>deleted<TAB>path`), then its
    `--summary` lines (` create mode ...` / ` delete mode ...`). A commit is
    therefore complete only when the next header (or the end) arrives, which
    is when `_finish` writes its row."""
    var st = _State()
    for line in log.split("\n"):
        if line.startswith("@@"):
            _finish(repo, dir, st, out)
            var parts = String(line[byte=2:]).split(" ")
            st.sha = String(parts[0])
            st.at = Int64(Int(parts[1])) * 1_000_000 if len(parts) > 1 else 0
            continue
        # Files are counted from the summary (with `--no-renames` a rename is
        # a delete plus a create) and lines from numstat, so both follow the
        # running totals without ever listing a tree.
        if line.startswith(" create mode "):
            var p = _path_of(line)
            if is_mojo_file(p):
                st.files += 1
            st.mark(p, True)
            continue
        if line.startswith(" delete mode "):
            var p = _path_of(line)
            if is_mojo_file(p):
                st.files -= 1
            st.mark(p, False)
            continue
        var cols = line.split("\t")
        if len(cols) == 3:
            var p = String(cols[2])
            # Binary files print "-" for both counts.
            if is_mojo_file(p) and String(cols[0]) != "-":
                st.lines += Int64(Int(cols[0])) - Int64(Int(cols[1]))
            if p == "pixi.toml" or p == "pixi.lock" or p == "mojoproject.toml" or p == "magic.lock":
                st.touched = True
    _finish(repo, dir, st, out)


def read_history(repo: String) raises -> History:
    """Clones `repo` from GitHub and reads its history. Errors (a repository
    gone, a clone that failed, history that doesn't parse) come back in
    `error`, so one bad repository doesn't fail the rest of its run."""
    var out = History.empty(repo)
    try:
        _read_history(repo, out)
    except e:
        if safe_repo(repo):
            try:
                _ = _sh(String("rm -rf '", _clone_dir(repo), "'"))
            except:
                pass
        out = History.empty(repo)
        out.error = String("reading its history: ", e)
    return out^


def read_tags(repo: String) raises -> History:
    """Only `repo`'s tags (no commits), from a bare clone without file
    contents (`--filter=blob:none`); errors come back in `error`."""
    var out = History.empty(repo)
    if not safe_repo(repo):
        out.error = String("not a repository name: ", repo)
        return out^
    var dir = _clone_dir(repo)
    try:
        _ = _sh(String("mkdir -p '", _workdir(), "' && rm -rf '", dir, "'"))
        var clone = _sh(String(
            "GIT_TERMINAL_PROMPT=0 git clone --quiet --bare --filter=blob:none",
            " https://github.com/", repo, ".git '", dir, "' 2>&1",
        ))
        if clone[0] != 0:
            out.error = String("git clone failed: ", clone[1].strip())
        else:
            _read_tags(repo, dir, out)
    except e:
        out = History.empty(repo)
        out.error = String("reading its tags: ", e)
    try:
        _ = _sh(String("rm -rf '", dir, "'"))
    except:
        pass
    return out^


def _workdir() -> String:
    """Where clones go: each is deleted after it is read."""
    return getenv("MOJO_HISTORY_WORKDIR", String(getenv("TMPDIR", "/tmp"), "/mojo_history"))


def _clone_dir(repo: String) -> String:
    """`owner/name` as one directory name, `owner__name.git`."""
    return String(_workdir(), "/", repo.replace("/", "__"), ".git")


def _read_history(repo: String, mut out: History) raises:
    """`read_history` without the error handling: failures that git reports
    are put in `out.error`. The clone is bare (no checkout: manifests are read
    with `git show`) and is removed before returning."""
    if not safe_repo(repo):
        out.error = String("not a repository name: ", repo)
        return
    var base = _workdir()
    var dir = _clone_dir(repo)
    _ = _sh(String("mkdir -p '", base, "' && rm -rf '", dir, "'"))
    var clone = _sh(
        String(
            "GIT_TERMINAL_PROMPT=0 git clone --quiet --bare https://github.com/",
            repo, ".git '", dir, "' 2>&1",
        )
    )
    if clone[0] != 0:
        out.error = String("git clone failed: ", clone[1].strip())
        _ = _sh(String("rm -rf '", dir, "'"))
        return
    # `--first-parent --diff-merges=first-parent` follows the default branch
    # only, with a merge shown as its diff against the first parent: a pull
    # request counts once, and the lines add up to the branch's real size.
    # `--reverse` puts the oldest commit first so the totals accumulate.
    var log = _sh(
        String(
            "git -C '", dir, "' -c core.quotepath=off log --first-parent",
            " --reverse --no-renames --diff-merges=first-parent",
            " --format='@@%H %ct' --numstat --summary HEAD",
        )
    )
    if log[0] != 0:
        out.error = String("git log failed: ", log[1].strip())
    else:
        try:
            _parse_log(repo, dir, log[1], out)
            try:
                _read_tags(repo, dir, out)
            except:
                pass  # the history stands without its tags
        except e:
            out.error = String("reading its git log: ", e)
    _ = _sh(String("rm -rf '", dir, "'"))
