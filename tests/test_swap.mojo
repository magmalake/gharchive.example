"""The console's cache swap and refresh rules, and a reader that keeps its
value while a writer swaps in new ones.

    pixi run test
"""

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from swap import Swap, check_due, needs_build
from threads import ThreadHandle, OpaquePtr, opaque_ptr


struct Doc(Movable):
    var n: Int
    var items: List[Int]

    def __init__(out self, n: Int):
        self.n = n
        self.items = List[Int]()
        for _ in range(100):
            self.items.append(n)


def test_get_put() raises:
    var s = Swap[Doc](Doc(1))
    var a = s.get()
    assert_equal(a[].n, 1)
    s.put(Doc(2))
    assert_equal(s.get()[].n, 2)
    # The reader that took the first one still sees it, unchanged.
    assert_equal(a[].n, 1)
    assert_equal(a[].items[99], 1)


def test_due() raises:
    # Not built yet: always.
    assert_true(check_due(False, 100, 100, 0, 5, 1800))
    # Built today, looked a minute ago: no.
    assert_false(check_due(True, 160, 100, 5, 5, 1800))
    # Looked 30 minutes ago: yes.
    assert_true(check_due(True, 1900, 100, 5, 5, 1800))
    # The day rolled over: yes, at once.
    assert_true(check_due(True, 160, 100, 5, 6, 1800))


def test_needs_build() raises:
    assert_true(needs_build(False, 0, 5, True))
    assert_false(needs_build(True, 5, 5, True))
    assert_true(needs_build(True, 5, 5, False))
    assert_true(needs_build(True, 5, 6, True))


def _writer(arg: OpaquePtr) -> OpaquePtr:
    var s = Pointer[Swap[Doc], MutUntrackedOrigin](unsafe_from_address=Int(arg))
    for i in range(2, 2000):
        s[].put(Doc(i))
    return arg


def test_concurrent() raises:
    var s = Swap[Doc](Doc(1))
    var h = ThreadHandle.spawn[_writer](opaque_ptr(Int(Pointer(to=s))))
    var last = 0
    for _ in range(20000):
        var a = s.get()
        # Every value a reader gets is whole, and values only move forward.
        assert_equal(a[].items[0], a[].n)
        assert_equal(a[].items[99], a[].n)
        assert_true(a[].n >= last)
        last = a[].n
    h.join()
    assert_equal(s.get()[].n, 1999)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
