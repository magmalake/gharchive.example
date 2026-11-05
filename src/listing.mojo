"""The Repos table's query: which column it sorts by, which filters it has,
and the repositories that pass, from plain arrays so the tests need no lake.

    /repos?sort=lines|files|stars&dir=asc|desc&version=1.x&active=1y

The default is the order the repositories come in (most lines of Mojo
first), which is `sort=lines&dir=desc`.
"""


@fieldwise_init
struct ListQuery(Copyable, Movable):
    var sort: String
    """`lines`, `files` or `stars`."""
    var asc: Bool
    var version: String
    """A version family (`1.x`) or `unknown`; empty for any."""
    var active: Bool
    """Only repositories with a commit in the last 12 months."""

    def is_default_order(self) -> Bool:
        return self.sort == "lines" and not self.asc

    def has_filter(self) -> Bool:
        return self.version.byte_length() > 0 or self.active


def parse_list_query(sort: String, dir: String, version: String, active: String) -> ListQuery:
    """The query from the raw parameters; what isn't recognised is the
    default."""
    var s = String("lines")
    if sort == "files" or sort == "stars":
        s = sort
    return ListQuery(s, dir == "asc", String(version.strip()), active == "1y")


def list_url(q: ListQuery, base: String = "/repos") -> String:
    """The URL of `q`, leaving out what is the default."""
    var parts = List[String]()
    if q.sort != "lines":
        parts.append(String("sort=", q.sort))
    if q.asc:
        parts.append(String("dir=asc"))
    if q.version.byte_length() > 0:
        parts.append(String("version=", q.version))
    if q.active:
        parts.append(String("active=1y"))
    if len(parts) == 0:
        return base
    var out = String(base, "?")
    for i in range(len(parts)):
        if i > 0:
            out += "&"
        out += parts[i]
    return out^


def sorted_by(q: ListQuery, column: String) -> ListQuery:
    """`q` after clicking `column`'s header: the same column flips the
    direction, another starts largest first."""
    if q.sort == column:
        return ListQuery(q.sort, not q.asc, q.version, q.active)
    return ListQuery(column, False, q.version, q.active)


def with_version(q: ListQuery, version: String) -> ListQuery:
    return ListQuery(q.sort, q.asc, version, q.active)


def with_active(q: ListQuery, active: Bool) -> ListQuery:
    return ListQuery(q.sort, q.asc, q.version, active)


def select_repos(
    q: ListQuery,
    lines: List[Int64],
    files: List[Int64],
    stars: List[Int64],
    families: List[String],
    active: List[Bool],
) -> List[Int]:
    """The indices of the repositories that pass `q`'s filters, in its
    order. The arrays are one entry per repository, in the default order;
    equal values stay in that order."""
    var idx = List[Int]()
    for i in range(len(lines)):
        if q.version.byte_length() > 0 and families[i] != q.version:
            continue
        if q.active and not active[i]:
            continue
        idx.append(i)
    if q.is_default_order():
        return idx^
    if q.sort == "files":
        return _merge_sort(idx^, files, q.asc)
    if q.sort == "stars":
        return _merge_sort(idx^, stars, q.asc)
    return _merge_sort(idx^, lines, q.asc)


def _before(a: Int, b: Int, keys: List[Int64], asc: Bool) -> Bool:
    """Whether `a` goes before `b`: the key decides, then the position."""
    if keys[a] != keys[b]:
        return keys[a] < keys[b] if asc else keys[a] > keys[b]
    return a < b


def _merge_sort(var idx: List[Int], keys: List[Int64], asc: Bool) -> List[Int]:
    var n = len(idx)
    var width = 1
    var tmp = List[Int](length=n, fill=0)
    while width < n:
        var lo = 0
        while lo < n:
            var mid = min(lo + width, n)
            var hi = min(lo + 2 * width, n)
            var i = lo
            var j = mid
            var k = lo
            while i < mid and j < hi:
                if _before(idx[j], idx[i], keys, asc):
                    tmp[k] = idx[j]
                    j += 1
                else:
                    tmp[k] = idx[i]
                    i += 1
                k += 1
            while i < mid:
                tmp[k] = idx[i]
                i += 1
                k += 1
            while j < hi:
                tmp[k] = idx[j]
                j += 1
                k += 1
            lo += 2 * width
        var t = idx^
        idx = tmp^
        tmp = t^
        width *= 2
    return idx^
