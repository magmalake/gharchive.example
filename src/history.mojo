"""A repository's history: lines of Mojo, tooling and Mojo version at each
commit, and the commits where the tooling or the version changed.

`read_history` clones the repository (bare, into `MOJO_HISTORY_WORKDIR`,
default `$TMPDIR/mojo_history`), walks its first-parent history once with
`git log --numstat --summary`, and reads a manifest or lock file only at the
commits that touch one. It needs `git` on the PATH.
"""

from std.os import getenv
from std.subprocess import run

from dista import Seq

from versions import lock_version, manifest_version, tooling


@fieldwise_init
struct CommitRow(Copyable, Movable):
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
    var repo: String
    var sha: String
    var committed_at: Int64
    var kind: String
    """`tooling` or `mojo_version`."""
    var from_value: String
    var to_value: String


@fieldwise_init
struct History(Copyable, Movable):
    var repo: String
    var error: String
    """Empty when the history was read."""
    var commits: Seq[CommitRow]
    var migrations: Seq[MigrationRow]


def safe_repo(repo: String) -> Bool:
    """`owner/name` with GitHub's characters only, safe to put in a shell
    command."""
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


def is_mojo_file(path: StringSlice) -> Bool:
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
    var r = _sh(String("git -C '", dir, "' show '", sha, ":", file, "' 2>/dev/null"))
    if r[0] != 0:
        return String()
    return r[1]


struct _State:
    var pixi_toml: Bool
    var pixi_lock: Bool
    var mojoproject: Bool
    var magic_lock: Bool
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
        self.touched = False
        self.lines = 0
        self.files = 0

    def mark(mut self, path: String, exists: Bool):
        if path == "pixi.toml":
            self.pixi_toml = exists
        elif path == "pixi.lock":
            self.pixi_lock = exists
        elif path == "mojoproject.toml":
            self.mojoproject = exists
        elif path == "magic.lock":
            self.magic_lock = exists
        else:
            return
        self.touched = True


def _version(dir: String, sha: String, st: _State) raises -> Tuple[String, String]:
    """The Mojo version at `sha` and where it came from."""
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
    var new_tool = tooling(st.pixi_toml, st.pixi_lock, st.mojoproject, st.magic_lock)
    if st.touched:
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
    var st = _State()
    for line in log.split("\n"):
        if line.startswith("@@"):
            _finish(repo, dir, st, out)
            var parts = String(line[byte=2:]).split(" ")
            st.sha = String(parts[0])
            st.at = Int64(Int(parts[1])) * 1_000_000 if len(parts) > 1 else 0
            continue
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
            if is_mojo_file(p) and String(cols[0]) != "-":
                st.lines += Int64(Int(cols[0])) - Int64(Int(cols[1]))
            if p == "pixi.toml" or p == "pixi.lock" or p == "mojoproject.toml" or p == "magic.lock":
                st.touched = True
    _finish(repo, dir, st, out)


def read_history(repo: String) raises -> History:
    """Clones `repo` from GitHub and reads its history. Errors (a repository
    gone, a clone that failed, history that doesn't parse) come back in
    `error`, so one bad repository doesn't fail the rest of its run."""
    var out = History(repo, String(), Seq[CommitRow](), Seq[MigrationRow]())
    try:
        _read_history(repo, out)
    except e:
        if safe_repo(repo):
            try:
                _ = _sh(String("rm -rf '", _clone_dir(repo), "'"))
            except:
                pass
        out = History(
            repo, String("reading its history: ", e), Seq[CommitRow](), Seq[MigrationRow]()
        )
    return out^


def _workdir() -> String:
    return getenv("MOJO_HISTORY_WORKDIR", String(getenv("TMPDIR", "/tmp"), "/mojo_history"))


def _clone_dir(repo: String) -> String:
    return String(_workdir(), "/", repo.replace("/", "__"), ".git")


def _read_history(repo: String, mut out: History) raises:
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
        except e:
            out.error = String("reading its git log: ", e)
    _ = _sh(String("rm -rf '", dir, "'"))
