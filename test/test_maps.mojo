"""Tests for APIs outside `SlotMapLike` (so they can't be generic): indexing,
`get`, `values()`/`keys()`, printing, plain `for` loops and
`DenseSlotMap`'s slices. `detach`/`reattach` are in `test_linear.mojo`."""

from std.testing import assert_equal, assert_false, assert_true, TestSuite

from slotmap import DefaultKey, DenseSlotMap, HopSlotMap, SlotMap


def test_slotmap_api() raises:
    var sm = SlotMap[Int]()
    var a = sm.insert(1)
    var b = sm.insert(2)
    sm[a] += 10
    assert_equal(sm[a], 11)
    assert_equal(sm.get(b).value(), 2)
    assert_equal(sm.unsafe_get(b), 2)
    var total = 0
    for v in sm.values():
        total += v
    assert_equal(total, 13)
    for item in sm:
        item.value() *= 2
    var n = 0
    for k in sm.keys():
        assert_true(k in sm)
        n += 1
    assert_equal(n, 2)
    assert_equal(String(sm), "{1v1: 22, 2v1: 4}")
    assert_equal(String(SlotMap[Int]()), "{}")


def test_hopslotmap_api() raises:
    var sm = HopSlotMap[Int]()
    var a = sm.insert(1)
    var b = sm.insert(2)
    sm[a] += 10
    assert_equal(sm[a], 11)
    assert_equal(sm.get(b).value(), 2)
    assert_equal(sm.unsafe_get(b), 2)
    var total = 0
    for v in sm.values():
        total += v
    assert_equal(total, 13)
    for item in sm:
        item.value() *= 2
    var n = 0
    for k in sm.keys():
        assert_true(k in sm)
        n += 1
    assert_equal(n, 2)
    assert_equal(String(sm), "{1v1: 22, 2v1: 4}")


def test_denseslotmap_api() raises:
    var sm = DenseSlotMap[Int]()
    var a = sm.insert(1)
    var b = sm.insert(2)
    sm[a] += 10
    assert_equal(sm[a], 11)
    assert_equal(sm.get(b).value(), 2)
    assert_equal(sm.unsafe_get(b), 2)
    var total = 0
    for v in sm.values():
        total += v
    assert_equal(total, 13)
    for item in sm:
        item.value() *= 2
    var n = 0
    for k in sm.keys():
        assert_true(k in sm)
        n += 1
    assert_equal(n, 2)
    assert_equal(String(sm), "{1v1: 22, 2v1: 4}")


def test_denseslotmap_slices() raises:
    var sm = DenseSlotMap[Int]()
    var a = sm.insert(1)
    var b = sm.insert(2)
    var c = sm.insert(3)
    _ = sm.remove(a)  # Swaps c into a's place.
    var s = sm.as_slices()
    assert_equal(len(s[0]), 2)
    for i in range(2):
        assert_equal(sm[s[0][i]], s[1][i])
    s[1][0] = 30
    assert_equal(sm[c] + sm[b], 32)
    assert_equal(len(sm.keys_as_slice()), 2)
    assert_equal(len(sm.values_as_slice()), 2)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
