"""Finding libraries: a query's match score against a repository, and the
families the versions chart draws one line for."""

from versions import compare_versions, version_key


def _hex(c: UInt8) -> Int:
    if c >= 48 and c <= 57:
        return Int(c) - 48
    if c >= 97 and c <= 102:
        return Int(c) - 87
    if c >= 65 and c <= 70:
        return Int(c) - 55
    return -1


def url_decode(s: String) -> String:
    """A query-string value with `+` and `%XX` decoded (flare leaves it raw)."""
    var out = List[UInt8]()
    var b = s.as_bytes()
    var i = 0
    while i < len(b):
        var c = b[i]
        if c == UInt8(ord("+")):
            out.append(32)
        elif c == UInt8(ord("%")) and i + 2 < len(b) and _hex(b[i + 1]) >= 0 and _hex(b[i + 2]) >= 0:
            out.append(UInt8(_hex(b[i + 1]) * 16 + _hex(b[i + 2])))
            i += 2
        else:
            out.append(c)
        i += 1
    return String(from_utf8_lossy=out)


def search_score(
    repo: String,
    description: String,
    query: String,
    topics: List[String] = List[String](),
) -> Int:
    """0 for no match, else higher for better: the name (the part after
    `owner/`) equal to the query, then starting with it, then containing it,
    then a GitHub topic equal to it, then `owner/name` containing it, then a
    topic containing it, then the description. Case-insensitive; an empty
    query matches nothing."""
    var q = String(query.strip()).lower()
    if q.byte_length() == 0:
        return 0
    var full = repo.lower()
    var name = full
    var slash = full.find("/")
    if slash >= 0:
        name = String(full[byte = slash + 1 :])
    if name == q or full == q:
        return 100
    if name.startswith(q):
        return 80
    if q in name:
        return 60
    for t in topics:
        if t.lower() == q:
            return 50
    if q in full:
        return 40
    for t in topics:
        if q in t.lower():
            return 30
    if q in description.lower():
        return 20
    return 0


def version_family(v: String) -> String:
    """`24.x`, `25.x`, `0.25.x`, `0.26.x`, `1.x`: the line of releases `v` is
    on (a calendar 26.1 is 0.26.x); a string that isn't a version is its own family, `other`."""
    if len(version_key(v)) == 0:
        return String("other")
    var parts = v.strip().split(".")
    if len(parts) > 1 and String(parts[0]) == "0":
        return String("0.", parts[1], ".x")
    var era = version_key(v)[0]
    if era >= 26 and era < 100:
        # 26.1 is the 0.26.1 release under its calendar name.
        return String("0.", era, ".x")
    return String(parts[0], ".x")


def sort_families(mut fs: List[String], mut oldest: List[String]):
    """`fs` in Mojo's order; `oldest[i]` is the earliest version seen in
    `fs[i]`, which orders them (`other` last)."""
    for i in range(1, len(fs)):
        var j = i
        while j > 0 and (
            (fs[j - 1] == "other" and fs[j] != "other")
            or (
                fs[j] != "other"
                and fs[j - 1] != "other"
                and compare_versions(oldest[j - 1], oldest[j]) > 0
            )
        ):
            fs.swap_elements(j - 1, j)
            oldest.swap_elements(j - 1, j)
            j -= 1
