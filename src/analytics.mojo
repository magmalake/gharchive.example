"""PostHog product analytics for the console's pages, the way the
magmalake.org website and orca's UI load it.

`posthog_snippet(key, site)` is the `<head>` markup: PostHog's `array.js` and
its API through `/ph` on the page's own origin, a first-party proxy (the
mojourney-ph Worker in magmalake/magmalake.org; the console doesn't serve
it), so ad-blockers keep it. `persistence: 'memory'` sets no cookie and
writes no `localStorage`, so there is nothing to consent to, and `site` is
registered on every event to tell sites apart in a shared PostHog project.
The console passes `POSTHOG_KEY` from its environment.
"""


def is_project_key(key: String) -> Bool:
    """Whether `key` is a PostHog project key: `phc_` and then only letters,
    digits, `_` or `-`, so it can go in the script as it is."""
    if not key.startswith("phc_"):
        return False
    for byte in key.as_bytes():
        var b = Int(byte)
        if not (
            (b >= ord("a") and b <= ord("z"))
            or (b >= ord("A") and b <= ord("Z"))
            or (b >= ord("0") and b <= ord("9"))
            or b == ord("_")
            or b == ord("-")
        ):
            return False
    return True


def posthog_snippet(key: String, site: StaticString) -> String:
    """The two `<script>` tags for the page head, or "" when `key` is not a
    project key (unset, empty, or anything else)."""
    if not is_project_key(key):
        return ""
    return String(
        '<script defer src="/ph/static/array.js"></script>',
        '<script>window.addEventListener("DOMContentLoaded",function(){',
        'if(window.posthog){posthog.init("',
        key,
        "\",{api_host:location.origin+'/ph',",
        "ui_host:'https://us.posthog.com',defaults:'2025-05-24',",
        "persistence:'memory',capture_exceptions:true});",
        "posthog.register({site:'",
        site,
        "'});}});</script>",
    )
