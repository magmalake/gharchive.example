"""The Repos table's query: which column it sorts by, which filters it has,
and the repositories that pass, from plain arrays so the tests need no lake.

    /repos?sort=lines|files|stars|forks|used_by|commits30&dir=asc|desc&version=1.2&active=1y&new=month

The default is the order the repositories come in (most lines of Mojo
first), which is `sort=lines&dir=desc`.
"""


@fieldwise_init
struct ListQuery(Copyable, Movable):
    var sort: String
    """`lines`, `files`, `stars`, `forks`, `used_by` (census repos that
    depend on it) or `commits30` (commits in 30 days)."""
    var asc: Bool
    var version: String
    """A version bucket (`pre-1.0`, `1.2`, `no-manifest`, `unknown`, `other`) or an old
    family (`1.x`, `0.26.x`); empty for any."""
    var active: Bool
    """Only repositories with a commit in the last 12 months."""
    var new: String
    """When the first Mojo commit was: `month` (this UTC month),
    `last-month` or `30d`; empty for any."""
    var estimate: Bool
    """Count a repo with no detected version under the release its date
    estimates (`?estimate=1`); only the version filter looks at it."""

    def is_default_order(self) -> Bool:
        return self.sort == "lines" and not self.asc

    def has_filter(self) -> Bool:
        return self.version.byte_length() > 0 or self.active or self.new.byte_length() > 0


def parse_list_query(
    sort: String,
    dir: String,
    version: String,
    active: String,
    new: String = String(),
    estimate: String = String(),
) -> ListQuery:
    """The query from the raw parameters; what isn't recognised is the
    default."""
    var s = String("lines")
    if sort == "files" or sort == "stars" or sort == "forks" or sort == "used_by" or sort == "commits30":
        s = sort
    var n = String()
    if new == "month" or new == "last-month" or new == "30d":
        n = new
    return ListQuery(s, dir == "asc", String(version.strip()), active == "1y", n, estimate == "1")


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
    if q.new.byte_length() > 0:
        parts.append(String("new=", q.new))
    if q.estimate:
        parts.append(String("estimate=1"))
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
        return ListQuery(q.sort, not q.asc, q.version, q.active, q.new, q.estimate)
    return ListQuery(column, False, q.version, q.active, q.new, q.estimate)


def with_version(q: ListQuery, version: String) -> ListQuery:
    return ListQuery(q.sort, q.asc, version, q.active, q.new, q.estimate)


def with_estimate(q: ListQuery, estimate: Bool) -> ListQuery:
    return ListQuery(q.sort, q.asc, q.version, q.active, q.new, estimate)


def with_active(q: ListQuery, active: Bool) -> ListQuery:
    return ListQuery(q.sort, q.asc, q.version, active, q.new, q.estimate)


def with_new(q: ListQuery, new: String) -> ListQuery:
    return ListQuery(q.sort, q.asc, q.version, q.active, new, q.estimate)


comptime NEW_MONTH = 1
comptime NEW_LAST_MONTH = 2
comptime NEW_30D = 4


def new_bit(new: String) -> Int:
    """The bit of `new` in `select_repos`'s `news` masks."""
    if new == "month":
        return NEW_MONTH
    if new == "last-month":
        return NEW_LAST_MONTH
    return NEW_30D


def select_repos(
    q: ListQuery,
    lines: List[Int64],
    files: List[Int64],
    stars: List[Int64],
    families: List[String],
    active: List[Bool],
    legacy: List[String] = List[String](),
    news: List[Int] = List[Int](),
    commits30: List[Int64] = List[Int64](),
    forks: List[Int64] = List[Int64](),
    used_by: List[Int64] = List[Int64](),
) -> List[Int]:
    """The indices of the repositories that pass `q`'s filters, in its
    order. The arrays are one entry per repository, in the default order;
    equal values stay in that order."""
    var idx = List[Int]()
    for i in range(len(lines)):
        if q.version.byte_length() > 0 and families[i] != q.version:
            if len(legacy) == 0 or legacy[i] != q.version:
                continue
        if q.new.byte_length() > 0 and (len(news) == 0 or news[i] & new_bit(q.new) == 0):
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
    if q.sort == "commits30" and len(commits30) == len(lines):
        return _merge_sort(idx^, commits30, q.asc)
    if q.sort == "forks" and len(forks) == len(lines):
        return _merge_sort(idx^, forks, q.asc)
    if q.sort == "used_by" and len(used_by) == len(lines):
        return _merge_sort(idx^, used_by, q.asc)
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
