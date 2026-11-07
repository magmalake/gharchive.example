"""The Mojo version a repository states at its HEAD, from files that
`history.read_history` doesn't read, and an estimate by date.

`read_head_version` clones the repository bare without file contents
(`--filter=blob:none`: every commit and tree, no blobs), lists HEAD's files
and reads the few that can name a version: lock file and manifest (as the
history does), a version file, CI workflows, Dockerfiles and dev container
files, READMEs. `versions.pick_version` chooses by precedence and
`mojo_releases.estimate_version` turns the date of the last commit that touched
a Mojo file into the release current then, kept apart as the estimate.
`modular/modular` is cloned shallow (it is gigabytes) and states its own
version in `Mojo/pixi.lock`, source `repo`.
"""

from std.os import getenv

from history import _sh, _workdir, safe_repo
from mojo_releases import estimate_version
from versions import (
    SOURCE_DATE,
    SOURCE_REPO,
    file_version,
    lock_version,
    manifest_version,
    pick_version,
    pin_version,
    readme_version,
    script_version,
    usable,
)

comptime MAX_FILES = 12
"""Files read per kind (workflows, Dockerfiles, ...)."""
comptime MAX_BYTES = 262144
"""Bytes read of a file."""


@fieldwise_init
struct HeadVersion(Copyable, Movable):
    """One row of `mojo.repo_versions`, and what the `read_head_version`
    task returns. A plain struct so dista can send it by reflection."""

    var repo: String
    var error: String
    """Empty when HEAD was read."""
    var head_sha: String
    var version: String
    """Detected, by precedence; empty for none."""
    var source: String
    var file: String
    """The file the version was read from."""
    var estimate: String
    """The release current at `last_mojo_commit` (microseconds), by date."""
    var estimate_source: String
    var last_mojo_commit: Int64
    var read_at: Int64

    @staticmethod
    def empty(repo: String) -> Self:
        """A row with nothing found and no error."""
        return Self(
            repo, String(), String(), String(), String(), String(), String(),
            String(), 0, 0,
        )


def _base(path: String) -> String:
    """The last component of `path`."""
    var slash = path.rfind("/")
    if slash < 0:
        return path
    return String(path[byte = slash + 1 :])


struct Candidates(Copyable, Movable):
    """HEAD's files that can name a version, by kind."""

    var lock: List[String]
    var manifest: List[String]
    var file: List[String]
    var ci: List[String]
    var docker: List[String]
    var readme: List[String]

    def __init__(out self):
        self.lock = List[String]()
        self.manifest = List[String]()
        self.file = List[String]()
        self.ci = List[String]()
        self.docker = List[String]()
        self.readme = List[String]()


def classify(paths: List[String]) -> Candidates:
    """Sorts a repository's file list into the kinds `read_head_version`
    reads. A kind keeps `MAX_FILES` files, shortest paths first."""
    # Lock files, manifests and version files count only at the repository
    # root (`root`): a nested `pixi.lock` belongs to some example or
    # dependency, not to the project. CI and Docker files can live deeper.
    var c = Candidates()
    for p in paths:
        var base = _base(p)
        var low = base.lower()
        var root = base == p
        if root and (p == "magic.lock" or p == "pixi.lock"):
            c.lock.append(p)
        elif root and (
            p == "pixi.toml" or p == "mojoproject.toml" or p == "pyproject.toml"
            or p == "requirements.txt" or p == "requirements-dev.txt"
        ):
            c.manifest.append(p)
        elif root and (
            p == ".mojoversion" or p == ".mojo-version" or p == ".tool-versions"
            or p == "mojo-version" or p == "MOJO_VERSION" or p == "mojo_version.txt"
        ):
            c.file.append(p)
        elif (p.startswith(".github/workflows/") and (p.endswith(".yml") or p.endswith(".yaml"))) \
            or p == ".gitlab-ci.yml" or p == ".circleci/config.yml" \
            or p == "azure-pipelines.yml" or p == "Makefile" or p == "makefile" or p == "justfile":
            c.ci.append(p)
        elif low.startswith("dockerfile") or low.endswith(".dockerfile") \
            or p.startswith(".devcontainer/") and (low.endswith(".json") or low.startswith("dockerfile")) \
            or root and low.startswith("docker-compose") and (low.endswith(".yml") or low.endswith(".yaml")) \
            or p == ".devcontainer.json":
            c.docker.append(p)
        elif root and low.startswith("readme"):
            c.readme.append(p)
    _trim(c.ci)
    _trim(c.docker)
    _trim(c.readme)
    return c^


def _trim(mut paths: List[String]):
    """The first `MAX_FILES` by length, then name: the shortest paths are
    the top-level files, which are the most likely to state the project's
    own version."""
    for i in range(1, len(paths)):
        var j = i
        while j > 0 and (
            paths[j - 1].byte_length() > paths[j].byte_length()
            or (paths[j - 1].byte_length() == paths[j].byte_length() and paths[j - 1] > paths[j])
        ):
            paths.swap_elements(j - 1, j)
            j -= 1
    while len(paths) > MAX_FILES:
        _ = paths.pop()


def _show(dir: String, rev: String, path: String) raises -> String:
    """`path` at `rev`, cut to `MAX_BYTES`, or "" if there isn't one. In a
    blobless clone this is what fetches the blob, one file at a time."""
    var r = _sh(String(
        "git -C '", dir, "' show '", rev, ":", path, "' 2>/dev/null | head -c ", MAX_BYTES,
    ))
    if r[0] != 0:
        return String()
    return r[1]


def _quoted(path: String) -> Bool:
    """Whether `path` is safe inside the single quotes of a shell command."""
    return "'" not in path


def _first(
    dir: String, paths: List[String], kind: String, mut file: String
) raises -> String:
    """The first version `kind` ('lock', 'manifest', 'file', 'script' or
    'readme') reads from `paths`; `file` is set to its path."""
    for p in paths:
        if not _quoted(p):
            continue
        var text = _show(dir, "HEAD", p)
        if text.byte_length() == 0:
            continue
        # `pyproject.toml` and `requirements.txt` are in the manifest kind
        # too, and they aren't pixi manifests: when `manifest_version` finds
        # nothing, `pin_version` reads their `mojo==...` pins.
        var v: String
        if kind == "lock":
            v = lock_version(text)
        elif kind == "manifest":
            v = manifest_version(text)
            if not usable(v):
                v = pin_version(text)
        elif kind == "file":
            v = file_version(text)
        elif kind == "readme":
            v = readme_version(text)
        else:
            v = script_version(text)
        if usable(v):
            file = p
            return v^
    return String()


def pick_head(
    lock: String, manifest: String, file: String, ci: String, docker: String,
    readme: String,
) -> Tuple[String, String]:
    """`versions.pick_version` (the order of precedence is kept there)."""
    return pick_version(lock, manifest, file, ci, docker, readme)


def read_head_version(repo: String) raises -> HeadVersion:
    """Clones `repo` from GitHub and reads its HEAD. Errors (a repository
    gone, a failed clone) come back in `error`, so one bad repository doesn't
    fail the rest of its run."""
    var out = HeadVersion.empty(repo)
    var dir: String = ""
    try:
        if not safe_repo(repo):
            out.error = String("not a repository name: ", repo)
            return out^
        dir = String(_workdir(), "/", repo.replace("/", "__"), ".head.git")
        _read(repo, dir, out)
    except e:
        var keep = out.repo
        out = HeadVersion.empty(keep)
        out.error = String("reading its HEAD: ", e)
    if dir.byte_length() > 0:
        try:
            _ = _sh(String("rm -rf '", dir, "'"))
        except:
            pass
    return out^


def _read(repo: String, dir: String, mut out: HeadVersion) raises:
    """Fills `out` from a fresh bare clone in `dir`; git failures go in
    `out.error`. The caller removes the clone."""
    var shallow = repo == "modular/modular"
    _ = _sh(String("mkdir -p '", _workdir(), "' && rm -rf '", dir, "'"))
    var clone = _sh(String(
        "GIT_TERMINAL_PROMPT=0 git clone --quiet --bare --no-tags --filter=blob:none",
        " --depth 1" if shallow else "",
        " https://github.com/", repo, ".git '", dir, "' 2>&1",
    ))
    if clone[0] != 0:
        out.error = String("git clone failed: ", clone[1].strip())
        return
    var sha = _sh(String("git -C '", dir, "' rev-parse HEAD"))
    out.head_sha = String(sha[1].strip())
    var tree = _sh(String("git -C '", dir, "' -c core.quotepath=off ls-tree -r --name-only HEAD"))
    if tree[0] != 0:
        out.error = String("git ls-tree failed: ", tree[1].strip())
        return
    var paths = List[String]()
    for line in tree[1].split("\n"):
        if line.byte_length() > 0:
            paths.append(String(line))
    var c = classify(paths)
    # Each kind is read on its own, first file that names a version wins
    # (`_first`), and `pick_head` then chooses between the kinds.
    var f_lock = String()
    var f_manifest = String()
    var f_file = String()
    var f_ci = String()
    var f_docker = String()
    var f_readme = String()
    var lock = _first(dir, c.lock, "lock", f_lock)
    var manifest = _first(dir, c.manifest, "manifest", f_manifest)
    var vfile = _first(dir, c.file, "file", f_file)
    var ci = _first(dir, c.ci, "script", f_ci)
    var docker = _first(dir, c.docker, "script", f_docker)
    var readme = _first(dir, c.readme, "readme", f_readme)
    var picked = pick_head(lock, manifest, vfile, ci, docker, readme)
    out.version = picked[0]
    out.source = picked[1]
    if picked[1] == "lock":
        out.file = f_lock
    elif picked[1] == "manifest":
        out.file = f_manifest
    elif picked[1] == "file":
        out.file = f_file
    elif picked[1] == "ci":
        out.file = f_ci
    elif picked[1] == "docker":
        out.file = f_docker
    elif picked[1] == "readme":
        out.file = f_readme
    if repo == "modular/modular":
        # The repository states its own version in the lock file of Mojo/.
        var own = lock_version(_show(dir, "HEAD", "Mojo/pixi.lock"))
        if usable(own):
            out.version = own^
            out.source = String(SOURCE_REPO)
            out.file = String("Mojo/pixi.lock")
    # The estimate by date uses the last commit that touched a Mojo file,
    # not HEAD: a project that stopped writing Mojo in 2024 was built with
    # that year's release even if its README was edited since. (A shallow
    # clone has only HEAD, so modular/modular falls back to HEAD's date.)
    var last = _sh(String(
        "git -C '", dir, "' log -1 --format=%ct HEAD -- '*.mojo' '*.🔥' 2>/dev/null",
    ))
    var secs: Int64
    try:
        secs = Int64(Int(String(last[1].strip())))
    except:
        secs = 0
    if secs == 0 and shallow:
        var head = _sh(String("git -C '", dir, "' log -1 --format=%ct HEAD"))
        try:
            secs = Int64(Int(String(head[1].strip())))
        except:
            secs = 0
    out.last_mojo_commit = secs * 1_000_000
    out.estimate = estimate_version(out.last_mojo_commit)
    if out.estimate.byte_length() > 0:
        out.estimate_source = String(SOURCE_DATE)
