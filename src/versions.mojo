"""Mojo versions in one order across Modular's renumbering, and the
tooling and version a project's manifest or lock file names.

Modular numbered releases 24.1 ... 24.6, 25.1 ... 25.6 (the `max` package,
with `mojo` inside), then gave `mojo` its own package as 0.25.6, 0.25.7,
0.26.1 ..., and then 1.0, 1.1, 1.2. `version_key` puts all of them on one
line: an *era* (24, 25, 26, then 101 for 1.x, 102 for 2.x), then the minor
and patch numbers, then released after its own dev builds. 25.6 and 0.25.6
are the same release and compare equal.
"""


def _num(s: StringSlice) -> Int:
    """The leading digits of `s` as a number, or -1 if there are none."""
    var v = 0
    var any = False
    for c in s.as_bytes():
        if c < 48 or c > 57:
            break
        v = v * 10 + Int(c) - 48
        any = True
    return v if any else -1


def version_key(v: String) -> List[Int]:
    """`[era, minor, patch, released, dev]` for a version string; an empty
    list if it isn't one."""
    var parts = v.strip().split(".")
    var nums = List[Int]()
    var dev = 0
    var released = 1
    for p in parts:
        if p.startswith("dev"):
            released = 0
            dev = _num(p[byte=3:])
            break
        var n = _num(p)
        if n < 0:
            break
        nums.append(n)
        # "25.4.0rc1" style suffixes: a pre-release of its numbers.
        if String(n).byte_length() != p.byte_length():
            released = 0
            break
    if len(nums) == 0:
        return List[Int]()
    while len(nums) < 4:
        nums.append(0)
    var era: Int
    var minor: Int
    var patch: Int
    if nums[0] == 0:
        # 0.25.6, 0.26.1: the era is the second number.
        era = nums[1]
        minor = nums[2]
        patch = nums[3]
    elif nums[0] >= 24:
        # 24.6, 25.4.0: calendar numbers.
        era = nums[0]
        minor = nums[1]
        patch = nums[2]
    else:
        # 1.0, 1.2.0: semantic versions, after every calendar one.
        era = 100 + nums[0]
        minor = nums[1]
        patch = nums[2]
    return [era, minor, patch, released, dev]


def compare_versions(a: String, b: String) -> Int:
    """-1, 0 or 1. Strings that aren't versions sort first."""
    var ka = version_key(a)
    var kb = version_key(b)
    if len(ka) == 0 or len(kb) == 0:
        return (0 if len(kb) == 0 else -1) if len(ka) == 0 else 1
    for i in range(len(ka)):
        if ka[i] < kb[i]:
            return -1
        if ka[i] > kb[i]:
            return 1
    return 0


def sort_versions(mut vs: List[String]):
    """In place, oldest first (insertion sort: these lists are short)."""
    for i in range(1, len(vs)):
        var j = i
        while j > 0 and compare_versions(vs[j - 1], vs[j]) > 0:
            vs.swap_elements(j - 1, j)
            j -= 1


def _is_digit(c: UInt8) -> Bool:
    return c >= 48 and c <= 57


def _version_at(b: Span[UInt8, _], var i: Int) -> String:
    """The version starting at `i`: digits, dots, and a `devNNN` part."""
    var s = i
    while i < len(b):
        var c = b[i]
        if _is_digit(c) or c == UInt8(ord(".")):
            i += 1
        elif c == UInt8(ord("d")) and i + 3 <= len(b) and b[i + 1] == UInt8(
            ord("e")
        ) and b[i + 2] == UInt8(ord("v")):
            i += 3
        else:
            break
    var out = String(StringSlice(unsafe_from_utf8=b[s:i]))
    while out.endswith("."):
        var cut = String(out[byte = : out.byte_length() - 1])
        out = cut^
    return out^


def packages() -> List[String]:
    """The packages that carry Mojo, most specific first."""
    return ["mojo-compiler", "mojo", "max-core", "max", "modular"]


def lock_version(text: String) -> String:
    """The Mojo version a `pixi.lock` or `magic.lock` installs: from a
    conda URL `.../<package>-<version>-<build>.conda`, trying the packages
    in `packages()` order. Empty if none is there."""
    var b = text.as_bytes()
    for pkg in packages():
        var needle = String("/", pkg, "-")
        var nb = needle.as_bytes()
        var i = 0
        var n = len(b)
        var m = len(nb)
        while i + m < n:
            var hit = True
            for k in range(m):
                if b[i + k] != nb[k]:
                    hit = False
                    break
            if hit and _is_digit(b[i + m]):
                var v = _version_at(b, i + m)
                if v.byte_length() > 0:
                    return v^
            i += 1
    return String()


def manifest_version(text: String) -> String:
    """The Mojo version a `pixi.toml` or `mojoproject.toml` asks for: the
    first version number in the spec of the first of `packages()` it lists
    as a dependency (`max = ">=24.5,<25"` gives 24.5). Empty if none."""
    for pkg in packages():
        for line in text.split("\n"):
            var l = String(line.strip())
            if not l.startswith(pkg):
                continue
            var rest = String(l[byte = pkg.byte_length() :]).strip()
            if not rest.startswith("="):
                continue
            var b = rest.as_bytes()
            for i in range(len(b)):
                if _is_digit(b[i]):
                    var v = _version_at(b, i)
                    if v.byte_length() > 0:
                        return v^
            return String("*")
    return String()


def names_mojo(text: String) -> Bool:
    """Whether a manifest depends on a Mojo package."""
    return manifest_version(text).byte_length() > 0


def tooling(
    pixi_toml: Bool,
    pixi_lock: Bool,
    mojoproject: Bool,
    magic_lock: Bool,
    bazel: Bool = False,
) -> String:
    """`none`, `magic`, `pixi` or `bazel`, from which files a commit has.

    A repository built with Bazel (`bazel`: a root `MODULE.bazel`,
    `WORKSPACE`, `WORKSPACE.bazel` or `BUILD.bazel`) is `bazel` even if it
    has pixi files too.

    magic read both `mojoproject.toml` and `pixi.toml` and wrote
    `magic.lock`; pixi writes `pixi.lock`. A lock file decides; without one
    the manifest does."""
    if bazel:
        return "bazel"
    if magic_lock:
        return "magic"
    if pixi_lock:
        return "pixi"
    if mojoproject:
        return "magic"
    if pixi_toml:
        return "pixi"
    return "none"


# ---------------------------------------------------------------------------
# Versions from files that aren't package manifests: CI, Docker, READMEs.
#
# Early Mojo projects (2023, `modular install mojo`, before magic and pixi)
# have no manifest; what is left to read is the commands and sentences that
# say which Mojo they were built with. These readers are conservative: a
# number counts only if it is a plausible Mojo version (`plausible_version`)
# and sits where a person would state one.
# ---------------------------------------------------------------------------

comptime SOURCE_LOCK = "lock"
comptime SOURCE_MANIFEST = "manifest"
comptime SOURCE_FILE = "file"
comptime SOURCE_CI = "ci"
comptime SOURCE_DOCKER = "docker"
comptime SOURCE_README = "readme"
comptime SOURCE_REPO = "repo"
comptime SOURCE_DATE = "date"


def source_label(source: String) -> String:
    """How the console says where a version came from. Also accepts the file
    names mojo.commits keeps in `version_source` (`pixi.lock`, `pixi.toml`)."""
    if source == "lock" or source.endswith(".lock"):
        return String("lock file")
    if source == "manifest" or source.endswith(".toml"):
        return String("manifest")
    if source == "ci":
        return String("CI")
    if source == "docker":
        return String("Docker")
    if source == "readme":
        return String("README")
    if source == "file":
        return String("version file")
    if source == "repo":
        return String("the repo itself")
    if source == "date":
        return String("date")
    return source


def _is_alnum(c: UInt8) -> Bool:
    return _is_digit(c) or (c >= 97 and c <= 122) or (c >= 65 and c <= 90)


def _digits(s: String, from_byte: Int) -> Tuple[Int, Int]:
    """The number at `from_byte` of `s` and the byte after it; (-1, from) if
    there are no digits."""
    var b = s.as_bytes()
    var i = from_byte
    var v = 0
    while i < len(b) and _is_digit(b[i]) and i - from_byte < 6:
        v = v * 10 + Int(b[i]) - 48
        i += 1
    if i == from_byte:
        return (-1, from_byte)
    return (v, i)


def plausible_version(v: String) -> Bool:
    """Whether `v` can be a Mojo version: at least two numbers, the first
    24 or 25 (calendar, minor 1 to 7), 26 (minor 1 to 9), 0 (minor 1 to 7
    for the early SDK, or 25 and 26 as the package numbered them) or 1
    (minor 0 to 9). It leaves out dates, IPs and other software's versions."""
    var a = _digits(v, 0)
    if a[0] < 0 or a[1] >= v.byte_length() or v.as_bytes()[a[1]] != UInt8(ord(".")):
        return False
    var b = _digits(v, a[1] + 1)
    if b[0] < 0:
        return False
    if a[0] == 24 or a[0] == 25:
        return b[0] >= 1 and b[0] <= 7
    if a[0] == 26:
        return b[0] >= 1 and b[0] <= 9
    if a[0] == 0:
        return (b[0] >= 1 and b[0] <= 7) or b[0] == 25 or b[0] == 26
    if a[0] == 1:
        return b[0] >= 0 and b[0] <= 9
    return False


def _clean_version(raw: String) -> String:
    """`raw` if it is a plausible version, else empty. Pre-release suffixes
    (`1.0.0b1`) are left off; `dev` builds stay."""
    if plausible_version(raw):
        return raw
    return String()


def _scan_version(b: Span[UInt8, _], var i: Int) -> String:
    """The plausible version at `i` (after optional quotes and a `v`), or
    empty."""
    while i < len(b) and (
        b[i] == UInt8(ord('"')) or b[i] == UInt8(ord("'")) or b[i] == UInt8(ord("`"))
    ):
        i += 1
    if i < len(b) and (b[i] == UInt8(ord("v")) or b[i] == UInt8(ord("V"))):
        i += 1
    if i >= len(b) or not _is_digit(b[i]):
        return String()
    return _clean_version(_version_at(b, i))


def _find_from(hay: String, needle: String, start: Int) -> Int:
    var b = hay.as_bytes()
    var nb = needle.as_bytes()
    var m = len(nb)
    var i = start
    while i + m <= len(b):
        var hit = True
        for k in range(m):
            if b[i + k] != nb[k]:
                hit = False
                break
        if hit:
            return i
        i += 1
    return -1


def _line_start(b: Span[UInt8, _], i: Int) -> Int:
    """The byte where the line holding byte `i` starts."""
    var k = i
    while k > 0 and b[k - 1] != UInt8(10):
        k -= 1
    return k


def _skip_spaces(b: Span[UInt8, _], var i: Int) -> Int:
    while i < len(b) and (b[i] == UInt8(32) or b[i] == UInt8(9)):
        i += 1
    return i


def _is_pkg_name(pkg: String) -> Bool:
    return pkg == "mojo" or pkg == "mojo-compiler" or pkg == "max" or pkg == "modular"


def pin_version(text: String) -> String:
    """The first Mojo version a pip, pixi, magic or modular command or a
    requirements file pins: `mojo==24.4.0`, `max>=24.5`, `mojo-compiler~=1.0`,
    `modular install mojo==24.4`. The package name must stand alone. A single
    `=` counts on a line that says `add` or `install`. Empty if none."""
    var low = text.lower()
    var b = low.as_bytes()
    var best = String()
    var best_at = len(b) + 1
    for pkg in ["mojo-compiler", "mojo", "max", "modular"]:
        var at = 0
        while True:
            var i = _find_from(low, pkg, at)
            if i < 0 or i >= best_at:
                break
            at = i + 1
            var before_ok = i == 0 or not (
                _is_alnum(b[i - 1]) or b[i - 1] == UInt8(ord("_"))
                or b[i - 1] == UInt8(ord("-")) or b[i - 1] == UInt8(ord("/"))
                or b[i - 1] == UInt8(ord("."))
            )
            if not before_ok:
                continue
            var j = i + pkg.byte_length()
            if j < len(b) and (_is_alnum(b[j]) or b[j] == UInt8(ord("_"))):
                continue
            if j < len(b) and b[j] == UInt8(ord("-")) and pkg != "mojo-compiler":
                continue  # max-parallel, mojo-stdlib, ...
            j = _skip_spaces(b, j)
            var op = 0
            if j + 1 < len(b) and b[j + 1] == UInt8(ord("=")) and (
                b[j] == UInt8(ord("=")) or b[j] == UInt8(ord(">")) or b[j] == UInt8(ord("~"))
            ):
                op = 2
            elif j < len(b) and b[j] == UInt8(ord("=")):
                # A line that adds or installs a package.
                var line = String(low[byte = _line_start(b, i) : i])
                if "add " in line or "install " in line:
                    op = 1
            if op == 0:
                continue
            var v = _scan_version(b, _skip_spaces(b, j + op))
            if v.byte_length() > 0 and i < best_at:
                best = v^
                best_at = i
                break
    return best^


def _key_value(low: String, key: String, start: Int) -> Tuple[String, Int]:
    """A value after `key` (`mojo_version: 24.4`, `MOJO_VERSION=24.4`,
    `mojo-version: "24.4"`), searching `low` from `start`: (version, byte of
    the key), or ("", -1)."""
    var b = low.as_bytes()
    var at = start
    while True:
        var i = _find_from(low, key, at)
        if i < 0:
            return (String(), -1)
        at = i + 1
        if i > 0 and (_is_alnum(b[i - 1]) or b[i - 1] == UInt8(ord("_"))):
            continue
        var j = i + key.byte_length()
        if j < len(b) and (b[j] == UInt8(ord('"')) or b[j] == UInt8(ord("'"))):
            j += 1
        j = _skip_spaces(b, j)
        if j < len(b) and (b[j] == UInt8(ord("=")) or b[j] == UInt8(ord(":"))):
            var v = _scan_version(b, _skip_spaces(b, j + 1))
            if v.byte_length() > 0:
                return (v^, i)


def _env_version(text: String) -> String:
    """The first `MOJO_VERSION`-style assignment (also `-` for `_`, and the
    `max` and `modular` spellings): shell, Dockerfile `ARG`/`ENV`, workflow
    `env:` and action inputs."""
    var low = text.lower()
    var best = String()
    var best_at = -1
    for key in [
        "mojo_version", "mojo-version", "mojoversion", "max_version",
        "max-version", "modular_version", "modular-version",
    ]:
        var r = _key_value(low, key, 0)
        if r[1] >= 0 and (best_at < 0 or r[1] < best_at):
            best = r[0]
            best_at = r[1]
    return best^


def _action_version(text: String) -> String:
    """A setup action for Mojo (`uses: ...setup-mojo@v1`) followed within a
    few lines by `with: version: 24.4`."""
    var lines = text.lower().split("\n")
    for i in range(len(lines)):
        var l = String(lines[i])
        if "uses:" not in l or "mojo" not in l:
            continue
        for k in range(i + 1, min(i + 7, len(lines))):
            var n = String(lines[k]).strip()
            if n.startswith("- "):
                break
            if n.startswith("version:") or n.startswith("mojo-version:"):
                var b = n.as_bytes()
                var colon = n.find(":")
                var v = _scan_version(b, _skip_spaces(b, colon + 1))
                if v.byte_length() > 0:
                    return v^
    return String()


def _image_version(text: String) -> String:
    """A Modular container image's tag: `FROM modular/max-nvidia-full:25.4.0`,
    `image: modularml/mojo:24.1`, `docker.modular.com/modular/max-openai-api:25.1`."""
    var low = text.lower()
    var b = low.as_bytes()
    var at = 0
    while True:
        var i = _find_from(low, "modular", at)
        if i < 0:
            return String()
        at = i + 7
        # The image name runs over name characters; the tag follows a colon.
        var j = i
        while j < len(b) and (
            _is_alnum(b[j]) or b[j] == UInt8(ord("/")) or b[j] == UInt8(ord("-"))
            or b[j] == UInt8(ord("_")) or b[j] == UInt8(ord("."))
        ):
            j += 1
        if j < len(b) and b[j] == UInt8(ord(":")) and j + 1 < len(b) and _is_digit(b[j + 1]):
            # Not a URL with a port or a path: the name must hold no scheme.
            var before = String(low[byte = _line_start(b, i) : i])
            if "://" in before and not ("docker://" in before):
                continue
            var v = _clean_version(_version_at(b, j + 1))
            if v.byte_length() > 0:
                return v^
        at = max(at, j)


def script_version(text: String) -> String:
    """The Mojo version a CI workflow, Dockerfile or dev container file
    names, by command (`modular install mojo==24.4.0`, `pip install
    max==25.1`), `MOJO_VERSION=` setting, setup action input or image tag:
    whichever comes first in the file. Empty if none."""
    var p = pin_version(text)
    var e = _env_version(text)
    var a = _action_version(text)
    var im = _image_version(text)
    # The order of the checks is the order of preference.
    if p.byte_length() > 0:
        return p^
    if e.byte_length() > 0:
        return e^
    if a.byte_length() > 0:
        return a^
    return im^


def _has_cue(before: String) -> Bool:
    """Whether the words before a `Mojo 24.4` in a README line say it is a
    requirement or what the project was tested on."""
    for cue in [
        "require", "tested", "works with", "work with", "compatible",
        "compatibility", "built with", "built on", "supports", "support ",
        "needs", "need ", "minimum", "install", "using", "runs on", "run with",
        "developed", "written for", "written in", "based on", "as of",
        "up to date with", "targets", "target ", "for the", "version of",
    ]:
        if cue in before:
            return True
    return False


def readme_version(text: String) -> String:
    """The Mojo version a README states: a pinned package or command
    (`pin_version`, `MOJO_VERSION=`), `Mojo >= 24.1`, `Mojo v0.7`, `Mojo
    version 24.4`, a `Mojo-24.4-orange` badge, or a plain `Mojo 24.4` in a
    line that says it is required, tested, installed or used. Other numbers
    (`Mojo 2023`, a URL's path) are not versions. Empty if none."""
    var p = pin_version(text)
    if p.byte_length() > 0:
        return p^
    var e = _env_version(text)
    if e.byte_length() > 0:
        return e^
    for raw in text.split("\n"):
        var line = String(raw)
        if line.byte_length() > 1000:
            continue
        var low = line.lower()
        var b = low.as_bytes()
        var badge = "shields.io" in low or "badge" in low
        var at = 0
        while True:
            var i = _find_from(low, "mojo", at)
            if i < 0:
                break
            at = i + 4
            var j = i + 4
            if badge and j + 1 < len(b) and b[j] == UInt8(ord("-")) and _is_digit(b[j + 1]):
                var v = _clean_version(_version_at(b, j + 1))
                if v.byte_length() > 0:
                    return v^
                continue
            if i > 0 and (
                _is_alnum(b[i - 1]) or b[i - 1] == UInt8(ord("/"))
                or b[i - 1] == UInt8(ord("_")) or b[i - 1] == UInt8(ord("-"))
                or b[i - 1] == UInt8(ord("."))
            ):
                continue
            if j < len(b) and _is_alnum(b[j]):
                continue
            var strong = False
            # Words between "Mojo" and the number.
            var steps = 0
            while j < len(b) and steps < 40:
                steps += 1
                var c = b[j]
                if c == UInt8(32) or c == UInt8(9) or c == UInt8(ord("`")) or c == UInt8(ord("*")) \
                    or c == UInt8(ord("_")) or c == UInt8(ord("(")) or c == UInt8(ord("'")) \
                    or c == UInt8(ord('"')) or c == UInt8(ord("[")):
                    j += 1
                elif c == UInt8(ord(":")):
                    strong = True
                    j += 1
                elif c == UInt8(ord(">")) or c == UInt8(ord("<")) or c == UInt8(ord("=")) \
                    or c == UInt8(ord("~")) or c == UInt8(ord("^")):
                    strong = True
                    j += 1
                elif c == UInt8(ord("v")) and j + 1 < len(b) and _is_digit(b[j + 1]):
                    strong = True
                    j += 1
                else:
                    var word_end = j
                    while word_end < len(b) and _is_alnum(b[word_end]):
                        word_end += 1
                    var w = String(low[byte = j : word_end])
                    if w == "version" or w == "release" or w == "sdk" or w == "compiler" or w == "nightly" or w == "language":
                        strong = strong or w == "version"
                        j = word_end
                    else:
                        break
            if j >= len(b) or not _is_digit(b[j]):
                continue
            var v = _clean_version(_version_at(b, j))
            if v.byte_length() == 0:
                continue
            var after = j + v.byte_length()
            if after < len(b) and (b[after] == UInt8(ord("/"))):
                continue
            if strong or _has_cue(String(low[byte=:i])):
                return v^
    return String()


def file_version(text: String) -> String:
    """A version file: `.mojoversion` or `.mojo-version` holding `24.4`, or
    a `.tool-versions` line `mojo 24.4.0`. Empty if none."""
    for raw in text.split("\n"):
        var line = String(String(raw).strip())
        if line.byte_length() == 0 or line.startswith("#"):
            continue
        var parts = line.split()
        if len(parts) >= 2 and _is_pkg_name(String(parts[0]).lower()):
            var v = _scan_version(String(parts[1]).as_bytes(), 0)
            if v.byte_length() > 0:
                return v^
            continue
        if len(parts) == 1:
            var v = _scan_version(String(parts[0]).as_bytes(), 0)
            if v.byte_length() > 0:
                return v^
    return String()


def usable(v: String) -> Bool:
    """Whether `v` names a version (`*` and empty don't)."""
    return v.byte_length() > 0 and v != "*"


def pick_version(
    lock: String,
    manifest: String,
    file: String,
    ci: String,
    docker: String,
    readme: String,
) -> Tuple[String, String]:
    """The version and its source by precedence: lock file, manifest, a
    version file, CI, Docker, README. ("", "") if none names one."""
    if usable(lock):
        return (lock, String(SOURCE_LOCK))
    if usable(manifest):
        return (manifest, String(SOURCE_MANIFEST))
    if usable(file):
        return (file, String(SOURCE_FILE))
    if usable(ci):
        return (ci, String(SOURCE_CI))
    if usable(docker):
        return (docker, String(SOURCE_DOCKER))
    if usable(readme):
        return (readme, String(SOURCE_README))
    return (String(), String())
