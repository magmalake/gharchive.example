"""A value that one thread replaces and many threads read, and the rules for
when the console's background refresher looks and rebuilds.

`Swap[T]` holds an `ArcPointer[T]` under a mutex. A reader takes a reference
under the lock and then reads without it, so a long page render never holds
the lock and a `put` never waits for one. The value a reader holds stays alive
(and unchanged) until it lets go, even after a newer one was swapped in. `T`
must not be changed once it is `put`.
"""

from std.memory import ArcPointer

from threads import Mutex


struct Swap[T: Deinitable & Movable]:
    var _lock: Mutex
    var _cur: ArcPointer[Self.T]

    def __init__(out self, var first: Self.T) raises:
        self._lock = Mutex()
        self._cur = ArcPointer(first^)

    def get(self) -> ArcPointer[Self.T]:
        """The current value, which stays as it is for as long as it's held."""
        self._lock.lock()
        var a = self._cur.copy()
        self._lock.unlock()
        return a^

    def put(mut self, var next: Self.T):
        """Make `next` the current value. The old one is freed when the last
        reader lets go of it."""
        var a = ArcPointer(next^)
        self._lock.lock()
        swap(self._cur, a)
        self._lock.unlock()
        # `a` (the old value) is released here, outside the lock.


def check_due(
    ready: Bool, now: Int64, checked_at: Int64, built_day: Int, today: Int, interval: Int
) -> Bool:
    """Whether the refresher should look at the tables now: nothing built yet,
    `interval` seconds since the last look, or the UTC day changed (the
    windows of 30 days and 12 months slide with it)."""
    if not ready:
        return True
    if built_day != today:
        return True
    return now - checked_at >= Int64(interval)


def needs_build(ready: Bool, built_day: Int, today: Int, same_sources: Bool) -> Bool:
    """Whether a look at the tables calls for a rebuild: nothing built yet, the
    day changed, or a table's snapshot moved."""
    return not ready or built_day != today or not same_sources
