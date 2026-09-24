"""Linear (non-`Deinitable`) values in every map, and the linear `Detached`
token. What must *not* compile is in `test/compile_fail/`.

The compiler rejects raising while a linear value is alive (the error path
would abandon it), so each scenario runs in a non-raising function that
records what it observes, and the test asserts on the record afterwards.
"""

from std.testing import assert_equal, assert_false, assert_true, TestSuite

from slotmap import (
    DefaultKey,
    DenseSlotMap,
    HopSlotMap,
    SecondaryMap,
    SlotMap,
    SparseSecondaryMap,
)
from helpers import Resource, close, close_opt


def _counter(mut n: Int) -> Pointer[Int, MutUntrackedOrigin]:
    return Pointer(to=n).unsafe_origin_cast[MutUntrackedOrigin]()


# ===-----------------------------------------------------------------------===#
# Linear values
# ===-----------------------------------------------------------------------===#


def _slotmap_linear() -> List[Int]:
    var seen = List[Int]()
    var closed = 0
    var c = _counter(closed)
    var sm = SlotMap[Resource]()
    var keys = List[DefaultKey]()
    for i in range(100):  # Forces the storage to grow, moving values.
        keys.append(sm.insert(Resource(i, c)))
    for item in sm:
        item.value().id += 1000
    seen.append(sm[keys[7]].id)
    seen.append(close_opt(sm.remove(keys[7])))
    seen.append(close_opt(sm.remove(keys[7])))
    seen.append(closed)
    sm^.deinit_with(close)
    seen.append(closed)
    return seen^


def test_slotmap_linear() raises:
    assert_equal(_slotmap_linear(), [1007, 1007, -1, 1, 100])


def _hopslotmap_linear() -> List[Int]:
    var seen = List[Int]()
    var closed = 0
    var c = _counter(closed)
    var sm = HopSlotMap[Resource]()
    var keys = List[DefaultKey]()
    for i in range(100):
        keys.append(sm.insert(Resource(i, c)))
    var removed_ok = 0
    for i in range(0, 100, 3):
        if close_opt(sm.remove(keys[i])) == i:
            removed_ok += 1
    seen.append(removed_ok)
    var n = 0
    for item in sm:  # Hops over the vacant blocks.
        item.value().id += 1
        n += 1
    seen.append(n)
    seen.append(len(sm))
    sm^.deinit_with(close)
    seen.append(closed)
    return seen^


def test_hopslotmap_linear() raises:
    assert_equal(_hopslotmap_linear(), [34, 66, 66, 100])


def _denseslotmap_linear() -> List[Int]:
    var seen = List[Int]()
    var closed = 0
    var c = _counter(closed)
    var sm = DenseSlotMap[Resource]()
    var keys = List[DefaultKey]()
    for i in range(100):
        keys.append(sm.insert(Resource(i, c)))
    seen.append(close_opt(sm.remove(keys[0])))  # Swap-removes.
    seen.append(sm[keys[99]].id)
    # `for ... in sm.values()` needs `Copyable` elements (a `Span` limit);
    # iterate the items instead.
    for item in sm:
        item.value().id *= 2
    seen.append(sm[keys[50]].id)
    sm^.deinit_with(close)
    seen.append(closed)
    return seen^


def test_denseslotmap_linear() raises:
    assert_equal(_denseslotmap_linear(), [0, 99, 100, 100])


def _secondary_linear() -> List[Int]:
    var seen = List[Int]()
    var closed = 0
    var c = _counter(closed)
    var sm = SlotMap[Int]()
    var old = sm.insert(0)
    _ = sm.remove(old)
    var new = sm.insert(0)  # Same slot, newer version.
    var other = sm.insert(0)

    var sec = SecondaryMap[Resource]()
    # Fresh insert: nothing displaced.
    seen.append(close_opt(sec.insert_returning(other, Resource(1, c))))
    # Same key: the previous value comes back.
    seen.append(close_opt(sec.insert_returning(other, Resource(2, c))))
    # An outdated value is displaced by a newer key...
    seen.append(close_opt(sec.insert_returning(old, Resource(3, c))))
    seen.append(close_opt(sec.insert_returning(new, Resource(4, c))))
    # ...and an older or null key is rejected, handing its value back.
    seen.append(close_opt(sec.insert_returning(old, Resource(5, c))))
    seen.append(
        close_opt(sec.insert_returning(DefaultKey.null(), Resource(6, c)))
    )
    seen.append(len(sec))
    seen.append(sec[new].id)
    seen.append(close_opt(sec.remove(other)))
    sec^.deinit_with(close)
    seen.append(closed)
    return seen^


def _sparse_secondary_linear() -> List[Int]:
    var seen = List[Int]()
    var closed = 0
    var c = _counter(closed)
    var sm = SlotMap[Int]()
    var old = sm.insert(0)
    _ = sm.remove(old)
    var new = sm.insert(0)  # Same slot, newer version.
    var other = sm.insert(0)

    var sec = SparseSecondaryMap[Resource]()
    # Fresh insert: nothing displaced.
    seen.append(close_opt(sec.insert_returning(other, Resource(1, c))))
    # Same key: the previous value comes back.
    seen.append(close_opt(sec.insert_returning(other, Resource(2, c))))
    # An outdated value is displaced by a newer key...
    seen.append(close_opt(sec.insert_returning(old, Resource(3, c))))
    seen.append(close_opt(sec.insert_returning(new, Resource(4, c))))
    # ...and an older or null key is rejected, handing its value back.
    seen.append(close_opt(sec.insert_returning(old, Resource(5, c))))
    seen.append(
        close_opt(sec.insert_returning(DefaultKey.null(), Resource(6, c)))
    )
    seen.append(len(sec))
    seen.append(sec[new].id)
    seen.append(close_opt(sec.remove(other)))
    sec^.deinit_with(close)
    seen.append(closed)
    return seen^


def test_secondary_linear() raises:
    assert_equal(_secondary_linear(), [-1, 1, -1, 3, 5, 6, 2, 4, 2, 6])


def test_sparse_secondary_linear() raises:
    assert_equal(_sparse_secondary_linear(), [-1, 1, -1, 3, 5, 6, 2, 4, 2, 6])


def test_insert_returning_matches_insert() raises:
    """For droppable values, `insert_returning` stores the same things as
    `insert`."""
    var sm = SlotMap[Int]()
    var old = sm.insert(0)
    _ = sm.remove(old)
    var new = sm.insert(0)
    var a = SecondaryMap[Int]()
    var b = SecondaryMap[Int]()
    var sa = SparseSecondaryMap[Int]()
    var sb = SparseSecondaryMap[Int]()
    for k in [old, new, old, new]:
        _ = a.insert(k, Int(k.data().version))
        _ = b.insert_returning(k, Int(k.data().version))
        _ = sa.insert(k, Int(k.data().version))
        _ = sb.insert_returning(k, Int(k.data().version))
    assert_true(a == b)
    assert_true(sa == sb)


# ===-----------------------------------------------------------------------===#
# Detach / reattach / release
# ===-----------------------------------------------------------------------===#


def _detach_reattach() raises -> List[String]:
    var seen = List[String]()
    var sm = SlotMap[String]()
    var foo = sm.insert("foo")
    var bar = sm.insert("bar")
    var d = sm.detach(foo)
    seen.append(String(d.key() == foo))
    seen.append(String(len(sm)))
    seen.append(String(foo in sm))
    d.value += "!"
    # A detached slot is not reused.
    var baz = sm.insert("baz")
    seen.append(String(baz.data().idx != foo.data().idx))
    sm.reattach(d^)
    seen.append(sm[foo])
    seen.append(sm[bar])
    seen.append(String(len(sm)))
    return seen^


def test_detach_reattach() raises:
    assert_equal(
        _detach_reattach(), ["True", "1", "False", "True", "foo!", "bar", "3"]
    )


def test_detach_release() raises:
    var sm = SlotMap[String]()
    var foo = sm.insert("foo")
    _ = sm.insert("bar")
    var v = sm.release(sm.detach(foo))
    assert_equal(v, "foo")
    assert_false(foo in sm)
    # The released slot is reused, with a newer version.
    var again = sm.insert("again")
    assert_equal(again.data().idx, foo.data().idx)
    assert_true(again.data().version > foo.data().version)


def test_detach_invalid_key_raises() raises:
    var sm = SlotMap[Int]()
    var k = sm.insert(1)
    _ = sm.remove(k)
    var raised = False
    try:
        sm.reattach(sm.detach(k))
    except:
        raised = True
    assert_true(raised)
    assert_equal(len(sm), 0)


def _dense_detach() -> List[Int]:
    var seen = List[Int]()
    var closed = 0
    var c = _counter(closed)
    var sm = DenseSlotMap[Resource]()
    var a = sm.insert(Resource(1, c))
    var b = sm.insert(Resource(2, c))
    # `detach` raises on an invalid key; the map must be destroyed on that
    # path too, so the detaching happens inside `try`.
    try:
        var d = sm.detach(a)
        seen.append(len(sm))
        seen.append(sm[b].id)  # Swapped into a's dense position.
        d.value.id = 10
        sm.reattach(d^)
        seen.append(sm[a].id)
        var r = sm.release(sm.detach(b))
        seen.append(r.id)
        r^.close()
        var n = sm.insert(Resource(3, c))
        seen.append(Int(n.data().idx == b.data().idx))  # b's slot was freed.
    except:
        seen.append(-1)
    sm^.deinit_with(close)
    seen.append(closed)
    return seen^


def test_dense_detach() raises:
    assert_equal(_dense_detach(), [1, 2, 10, 2, 1, 3])


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
