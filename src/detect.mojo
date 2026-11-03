"""Finding Mojo repositories in GH Archive events, and checking them.

GH Archive's push events carry commit messages, not file lists, so finding
Mojo repositories takes two passes. `scan_event` looks at one event for
cheap signs (the repository's name, the `language` of repository objects
that pull-request and fork payloads embed, commit messages naming `.mojo`
or `.🔥` files or a `mojoproject.toml`); `verify` asks GitHub about each
candidate: its `language`, its `pixi.toml` or `mojoproject.toml` naming a
Mojo package, and for a push, whether the pushed commit touched `.mojo`
files.
"""

from fetch import Reply, github, raw_file
from jscan import Range, each, field, path, text, timestamp_micros
from versions import names_mojo


@fieldwise_init
struct Candidate(Copyable, Movable):
    var repo: String
    var signals: String
    """Comma-separated: `language`, `push`, `manifest`, `description`, `name`."""
    var first_seen: Int64
    var sha: String
    """A pushed commit that may touch `.mojo` files, for `verify`."""

    def add(mut self, signal: String):
        for s in self.signals.split(","):
            if s == signal:
                return
        if self.signals.byte_length() > 0:
            self.signals += ","
        self.signals += signal

    def has(self, signal: String) -> Bool:
        for s in self.signals.split(","):
            if s == signal:
                return True
        return False

    def rank(self) -> Int:
        """Lower is checked first: the strongest signs, and the cheapest."""
        if self.has("language"):
            return 0
        if self.has("push"):
            return 1
        if self.has("manifest"):
            return 2
        if self.has("description"):
            return 3
        return 4


@always_inline
def _lower(c: UInt8) -> UInt8:
    if c >= 65 and c <= 90:
        return c + 32
    return c


def contains_ci(b: Span[UInt8, _], s: Int, e: Int, needle: StringSlice) -> Bool:
    """Whether `b[s:e]` contains `needle` (lowercase ASCII), ignoring case."""
    var nb = needle.as_bytes()
    var m = len(nb)
    if m == 0:
        return True
    var first = nb[0]
    var i = s
    while i + m <= e:
        if _lower(b[i]) == first:
            var hit = True
            for k in range(1, m):
                if _lower(b[i + k]) != nb[k]:
                    hit = False
                    break
            if hit:
                return True
        i += 1
    return False


def _word(c: UInt8) -> Bool:
    return (
        (c >= 48 and c <= 57)
        or (c >= 65 and c <= 90)
        or (c >= 97 and c <= 122)
        or c == UInt8(ord("_"))
        or c == UInt8(ord("-"))
    )


def names_mojo_file(b: Span[UInt8, _], s: Int, e: Int) -> Bool:
    """Whether the text names a file ending in `.mojo` or `.🔥`: a word
    character, the extension, then not a letter (so `foo.mojo` and
    `foo.🔥`, but not `x.mojom` or `maven.mojo.plugin`)."""
    var i = s + 1
    while i + 5 <= e:
        if b[i] == UInt8(ord(".")) and _word(b[i - 1]):
            # ".mojo"
            if (
                i + 5 <= e
                and _lower(b[i + 1]) == UInt8(ord("m"))
                and _lower(b[i + 2]) == UInt8(ord("o"))
                and _lower(b[i + 3]) == UInt8(ord("j"))
                and _lower(b[i + 4]) == UInt8(ord("o"))
                and (i + 5 == e or not _word(b[i + 5]))
                and (i + 5 == e or b[i + 5] != UInt8(ord(".")))
            ):
                return True
            # ".🔥" is F0 9F 94 A5 in UTF-8; JSON may also escape it.
            if (
                i + 5 <= e
                and b[i + 1] == 0xF0
                and b[i + 2] == 0x9F
                and b[i + 3] == 0x94
                and b[i + 4] == 0xA5
            ):
                return True
        i += 1
    return False


def _note(
    mut found: Dict[String, Candidate],
    repo: String,
    signal: String,
    at: Int64,
    sha: String = "",
) raises:
    if repo.byte_length() == 0 or "/" not in repo:
        return
    if repo in found:
        ref c = found[repo]
        c.add(signal)
        if at < c.first_seen:
            c.first_seen = at
        if sha.byte_length() > 0 and c.sha.byte_length() == 0:
            c.sha = sha
    else:
        found[repo] = Candidate(repo, signal, at, sha)


def scan_event(
    mut found: Dict[String, Candidate],
    type: String,
    repo: String,
    at: Int64,
    payload: Span[UInt8, _],
) raises:
    """Adds the candidates one event points at to `found`."""
    var rb = repo.as_bytes()
    if contains_ci(rb, 0, len(rb), "mojo"):
        _note(found, repo, "name", at)
    var n = len(payload)
    if n == 0:
        return
    var all = Range(0, n)
    # Repository objects with a language: pull requests' base and head
    # repositories, a fork's new repository.
    if contains_ci(payload, 0, n, '"language":"mojo"'):
        if type.startswith("PullRequest"):
            for side in ["base", "head"]:
                var r = path(payload, field(payload, all, "pull_request"), side, "repo")
                if text(payload, field(payload, r, "language")) == "Mojo":
                    _note(found, text(payload, field(payload, r, "full_name")), "language", at)
        elif type == "ForkEvent":
            var f = field(payload, all, "forkee")
            if text(payload, field(payload, f, "language")) == "Mojo":
                _note(found, text(payload, field(payload, f, "full_name")), "language", at)
            _note(found, repo, "language", at)
        else:
            _note(found, repo, "language", at)
    if type == "PushEvent":
        if not contains_ci(payload, 0, n, ".mojo") and not contains_ci(
            payload, 0, n, "🔥"
        ) and not contains_ci(payload, 0, n, "mojoproject"):
            return
        for c in each(payload, field(payload, all, "commits")):
            var msg = field(payload, c, "message")
            if not msg.found():
                continue
            if names_mojo_file(payload, msg.start, msg.end):
                _note(found, repo, "push", at, text(payload, field(payload, c, "sha")))
            if contains_ci(payload, msg.start, msg.end, "mojoproject.toml"):
                _note(found, repo, "manifest", at)
    elif type == "CreateEvent":
        var d = field(payload, all, "description")
        if d.found() and contains_ci(payload, d.start, d.end, "mojo"):
            _note(found, repo, "description", at)


@fieldwise_init
struct RepoInfo(Copyable, Movable):
    var repo: String
    var created_at: Int64
    var stars: Int64
    var forks: Int64
    var license: String
    var default_branch: String
    var description: String
    var size_kb: Int64
    var language: String
    var fork: Bool


def _long(s: String) -> Int64:
    var v = Int64(0)
    for c in s.as_bytes():
        if c < 48 or c > 57:
            break
        v = v * 10 + Int64(c - 48)
    return v


def parse_repo(body: String) -> RepoInfo:
    """The fields of mojo.repos from a `GET /repos/{owner}/{repo}` reply."""
    var b = body.as_bytes()
    var all = Range(0, len(b))
    var lic = field(b, all, "license")
    var license = text(b, field(b, lic, "spdx_id"))
    if license.byte_length() == 0 or license == "NOASSERTION":
        var name = text(b, field(b, lic, "name"))
        if name.byte_length() > 0:
            license = name
    return RepoInfo(
        text(b, field(b, all, "full_name")),
        timestamp_micros(b, field(b, all, "created_at")),
        _long(text(b, field(b, all, "stargazers_count"))),
        _long(text(b, field(b, all, "forks_count"))),
        license,
        text(b, field(b, all, "default_branch")),
        text(b, field(b, all, "description")),
        _long(text(b, field(b, all, "size"))),
        text(b, field(b, all, "language")),
        text(b, field(b, all, "fork")) == "true",
    )


@fieldwise_init
struct Verdict(Copyable, Movable):
    var outcome: String
    """`mojo`, `not mojo`, `fork`, `gone`, or `limited` (try again later)."""
    var how: String
    """For `mojo`: the check that settled it, e.g. `language`."""
    var info: RepoInfo
    var remaining: Int


def _commit_touches_mojo(repo: String, sha: String, mut remaining: Int) raises -> Bool:
    var r = github(String("/repos/", repo, "/commits/", sha))
    remaining = r.remaining
    if r.status != 200:
        return False
    var b = r.body.as_bytes()
    for f in each(b, field(b, Range(0, len(b)), "files")):
        var name = text(b, field(b, f, "filename"))
        if name.endswith(".mojo") or name.endswith(".🔥"):
            return True
    return False


def verify(c: Candidate) raises -> Verdict:
    """Asks GitHub whether `c` is a Mojo repository."""
    var empty = RepoInfo(c.repo, 0, 0, 0, "", "", "", 0, "", False)
    var r = github(String("/repos/", c.repo))
    if r.status == 403 or r.status == 429:
        return Verdict("limited", "", empty^, r.remaining)
    if r.status != 200:
        return Verdict("gone", String("HTTP ", r.status), empty^, r.remaining)
    var info = parse_repo(r.body)
    var remaining = r.remaining
    if info.fork:
        # Forks of modular/mojo are most "Mojo" repositories in the events;
        # they aren't libraries.
        return Verdict("fork", "", info^, remaining)
    if info.language == "Mojo":
        return Verdict("mojo", "language", info^, remaining)
    for f in ["pixi.toml", "mojoproject.toml"]:
        var manifest = raw_file(info.repo, info.default_branch, f)
        if names_mojo(manifest):
            return Verdict("mojo", String("manifest ", f), info^, remaining)
    if c.sha.byte_length() > 0 and remaining != 0:
        if _commit_touches_mojo(info.repo, c.sha, remaining):
            return Verdict("mojo", "push", info^, remaining)
    return Verdict("not mojo", "", info^, remaining)
