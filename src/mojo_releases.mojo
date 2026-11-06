"""Which Mojo release was current on a date, for the census's estimate of the
version a repository with no manifest was written for.

The table is built in, so the estimate needs no lake and no network. From
24.6 on the dates are those of the tags in modular/modular (`mojo.tags`: the
`modular/v25.7.0`, `max/v25.2.0`, `mojo/v1.2.0` tags are all made on the day of
the release). Before that they come from Mojo's changelog and are good to a
few days. Versions are named as `versions.mojo` orders them: 24.x and 25.x
calendar releases, 26.x as `0.26.x` came to be called, then 1.0 and on.
Pre-releases (1.0 beta 1 and 2, nightlies) aren't releases here.

Add a row when Modular ships a release; an estimate is then the newest row
at or before a date.
"""

from days import days_of


def release_versions() -> List[String]:
    """The releases, oldest first."""
    return [
        "0.1", "0.2", "0.3", "0.4", "0.5", "0.6", "0.7",
        "24.1", "24.2", "24.3", "24.4", "24.5", "24.6",
        "25.1", "25.2", "25.3", "25.4", "25.5", "0.25.6", "0.25.7",
        "0.26.1", "0.26.2", "1.0", "1.1", "1.2",
    ]


def release_dates() -> List[String]:
    """The day (UTC) each of `release_versions` was published."""
    return [
        "2023-05-02",  # 0.1: the playground, Mojo's public launch
        "2023-08-24",  # 0.2.1: the first SDK
        "2023-09-21",  # 0.3
        "2023-10-05",  # 0.4
        "2023-11-02",  # 0.5
        "2023-12-04",  # 0.6
        "2024-01-25",  # 0.7
        "2024-02-29",  # 24.1
        "2024-03-28",  # 24.2
        "2024-05-02",  # 24.3
        "2024-06-07",  # 24.4
        "2024-09-13",  # 24.5 (tag mojo/v24.5.0)
        "2024-12-17",  # 24.6 (tag max/v24.6.0)
        "2025-02-13",  # 25.1
        "2025-03-25",  # 25.2
        "2025-05-07",  # 25.3
        "2025-06-18",  # 25.4
        "2025-08-05",  # 25.5
        "2025-09-22",  # 25.6, which is Mojo 0.25.6
        "2025-11-20",  # 25.7, Mojo 0.25.7
        "2026-01-29",  # 26.1, Mojo 0.26.1
        "2026-03-19",  # 26.2, Mojo 0.26.2
        "2026-08-11",  # mojo/v1.0.0
        "2026-09-17",  # mojo/v1.1.0
        "2026-10-22",  # mojo/v1.2.0
    ]


def estimate_version(micros: Int64) -> String:
    """The newest release published on or before the day of `micros` (a time
    in microseconds since the epoch). Empty for no time (0) or a time before
    Mojo's launch."""
    if micros <= 0:
        return String()
    var day = micros // 86_400_000_000
    var versions = release_versions()
    var dates = release_dates()
    var out = String()
    try:
        for i in range(len(versions)):
            if days_of(dates[i]) <= day:
                out = versions[i]
            else:
                break
    except:
        return String()
    return out^
