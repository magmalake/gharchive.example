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
