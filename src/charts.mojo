"""Small inline-SVG charts for the Overview: donuts and line charts that
scale with their `viewBox`, coloured by the page's CSS variables, each with
a `<title>`, an `aria-label` and a legend that carries the numbers."""

from flare.http import html_escape


def compact(v: Int64) -> String:
    """`950`, `1.2k`, `3M`: a number short enough for an axis."""
    if v < 0:
        return String("-", compact(-v))
    if v < 1000:
        return String(v)
    if v < 1_000_000:
        return _scaled(v, 1000, "k")
    return _scaled(v, 1_000_000, "M")


def _scaled(v: Int64, unit: Int64, suffix: String) -> String:
    var tenths = v * 10 // unit
    if tenths >= 100 or tenths % 10 == 0:
        return String(tenths // 10, suffix)
    return String(tenths // 10, ".", tenths % 10, suffix)


def nice_ceil(v: Int64) -> Int64:
    """The smallest of 1, 2, 5 times a power of ten that is at least `v`."""
    if v <= 1:
        return 1
    var p = Int64(1)
    while p * 10 < v:
        p *= 10
    for m in [1, 2, 5, 10]:
        if p * Int64(m) >= v:
            return p * Int64(m)
    return p * 10


def _f2(x: Float64) -> String:
    """`x` with two decimals."""
    var c = Int(x * 100.0 + 0.5)
    var frac = c % 100
    return String(c // 100, ".", "0" if frac < 10 else "", frac)


def donut(
    labels: List[String],
    values: List[Int],
    colors: List[String],
    hrefs: List[String],
    center: String,
    center_label: String,
    aria: String,
) -> String:
    """A donut of `values`, one linked slice each (a zero value is left
    out), with `center` big in the hole. Slices are circle strokes, so there
    is no trigonometry; the circle is drawn from twelve o'clock."""
    var total = 0
    for v in values:
        total += v
    var r = 70.0
    var circ = 6.283185307 * r
    var svg = String(
        "<svg class=donut viewBox='0 0 200 200' role=img aria-label='", html_escape(aria),
        "'><title>", html_escape(aria), "</title>",
    )
    if total == 0:
        svg.write(
            "<circle cx=100 cy=100 r=70 fill=none stroke='var(--border)' stroke-width=26 />"
        )
    var cum = 0.0
    for i in range(len(values)):
        if values[i] == 0 or total == 0:
            continue
        var frac = Float64(values[i]) / Float64(total)
        var dash = frac * circ
        svg.write(
            "<a href='", html_escape(hrefs[i]), "'><title>", html_escape(labels[i]), ": ",
            values[i], " of ", total, "</title><circle cx=100 cy=100 r=70 fill=none stroke='",
            colors[i], "' stroke-width=26 stroke-dasharray='", _f2(dash), " ", _f2(circ - dash),
            "' stroke-dashoffset='", "-" if cum > 0.0 else "", _f2(cum * circ),
            "' transform='rotate(-90 100 100)'/></a>",
        )
        cum += frac
    svg.write(
        "<text class=big x=100 y=104 text-anchor=middle>", html_escape(center),
        "</text><text class=small x=100 y=124 text-anchor=middle>", html_escape(center_label),
        "</text></svg>",
    )
    return svg^


def grid_line(x1: Int, x2: Int, y: Int) -> String:
    """A horizontal gridline. The last value is quoted: in HTML an unquoted
    `y2=202/>` reads as `y2="202/"`, which leaves the `<line>` open and
    swallows every later mark of the chart."""
    return String("<line class=grid x1=", x1, " x2=", x2, " y1=", y, " y2='", y, "'/>")


def line_chart(
    months: List[String],
    names: List[String],
    series: List[List[Int64]],
    colors: List[String],
    percent: Bool,
    aria: String,
    area: Bool = False,
) -> String:
    """One line per name over `months` as inline SVG. The vertical axis runs
    from 0 to a round number above the largest value (100 for `percent`).
    `area` fills under the first line. The legend is the caller's."""
    var w = 560
    var h = 230
    var left = 46
    var right = 10
    var up = 10
    var pw = w - left - right
    var ph = h - up - 28
    var n = len(months)
    var top = Int64(100) if percent else Int64(1)
    if not percent:
        var mx = Int64(1)
        for ref s in series:
            for v in s:
                mx = max(mx, v)
        top = nice_ceil(mx)
    var svg = String(
        "<svg viewBox='0 0 ", w, " ", h, "' role=img aria-label='", html_escape(aria),
        "'><title>", html_escape(aria), "</title>",
    )
    var ticks: List[Int64] = [0, top // 2, top]
    for t in ticks:
        var y = up + ph - Int(t * Int64(ph) // top)
        svg.write(
            grid_line(left, w - right, y),
            "<text x=", left - 6, " y=", y + 4, " text-anchor=end>", compact(t),
            "%" if percent else "", "</text>",
        )
    var every = (n + 5) // 6
    for i in range(n):
        if i % every == 0:
            var x = left + (pw // 2 if n == 1 else i * pw // (n - 1))
            svg.write("<text x=", x, " y=", h - 8, " text-anchor=middle>", months[i], "</text>")
    for si in range(len(series)):
        var pts = String()
        var first_x = 0
        var last_x = 0
        var last_y = 0
        for i in range(n):
            var x = left + (pw // 2 if n == 1 else i * pw // (n - 1))
            var y = up + ph - Int(series[si][i] * Int64(ph) // top)
            pts.write(x, ",", y, " ")
            if i == 0:
                first_x = x
            last_x = x
            last_y = y
        if area and si == 0 and n > 1:
            svg.write(
                "<polygon fill='", colors[si], "' fill-opacity='.12' points='", first_x, ",",
                up + ph, " ", pts, last_x, ",", up + ph, "'/>",
            )
        svg.write(
            "<polyline fill=none stroke='", colors[si],
            "' stroke-width=2 stroke-linejoin=round points='", pts, "'/>",
            "<circle cx=", last_x, " cy=", last_y, " r=3 fill='", colors[si], "'/>",
        )
    svg.write("</svg>")
    return svg^
