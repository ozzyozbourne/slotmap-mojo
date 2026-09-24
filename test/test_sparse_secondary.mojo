from std.testing import (
    assert_equal,
    assert_false,
    assert_true,
    TestSuite,
)

from std.hashlib._ahash import AHasher
from slotmap import DefaultKey, SparseSecondaryMap, SlotMap
from helpers import DropCounter, MoveOnly, Rng, sorted_ints


def test_crate_example() raises:
    var sm = SlotMap[String]()
    var foo = sm.insert("foo")
    var bar = sm.insert("bar")
    _ = sm.remove(bar)
    var reuse = sm.insert("reuse")
    var sec = SparseSecondaryMap[String]()
    _ = sec.insert(foo, "noun")
    _ = sec.insert(reuse, "verb")
    for item in sm:
        assert_true(item.key in sec)
    assert_equal(sec[foo], "noun")
    assert_equal(sec[reuse], "verb")


def test_basic_ops() raises:
    var sm = SlotMap[Int]()
    var sec = SparseSecondaryMap[Int]()
    var k = sm.insert(1)
    assert_false(sec.insert(k, 10))
    assert_equal(len(sec), 1)
    assert_equal(sec.insert(k, 11).value(), 10)
    assert_equal(len(sec), 1)
    sec[k] += 1
    assert_equal(sec.get(k).value(), 12)
    assert_equal(sec.remove(k).value(), 12)
    assert_false(sec.remove(k))
    assert_equal(len(sec), 0)
    # Null keys are ignored.
    assert_false(sec.insert(DefaultKey.null(), 5))
    assert_equal(len(sec), 0)
    assert_false(DefaultKey.null() in sec)


def test_versions() raises:
    var sm = SlotMap[Int]()
    var sec = SparseSecondaryMap[Int]()
    var old = sm.insert(1)
    _ = sm.remove(old)
    var new = sm.insert(2)
    assert_equal(old.data().idx, new.data().idx)

    _ = sec.insert(new, 20)
    # An older key never overwrites a newer value.
    assert_false(sec.insert(old, 10))
    assert_equal(sec[new], 20)
    assert_false(old in sec)
    assert_false(sec.entry(old))

    # A newer key replaces an outdated value without changing the length.
    var sec2 = SparseSecondaryMap[Int]()
    _ = sec2.insert(old, 10)
    _ = sec2.insert(new, 20)
    assert_equal(len(sec2), 1)
    assert_false(old in sec2)
    assert_equal(sec2[new], 20)


def test_sparse_keys() raises:
    var sm = SlotMap[Int]()
    var keys = List[DefaultKey]()
    for i in range(100):
        keys.append(sm.insert(i))
    var sec = SparseSecondaryMap[Int]()
    _ = sec.insert(keys[99], 99)
    assert_equal(len(sec), 1)
    assert_equal(sec[keys[99]], 99)
    assert_false(keys[50] in sec)
    sec.reserve(1000)
    assert_true(sec.capacity() >= 1000)
    assert_equal(sec[keys[99]], 99)


def _add_one(mut v: Int):
    v += 1


def test_entry() raises:
    var sm = SlotMap[Int]()
    var a = sm.insert(0)
    var b = sm.insert(0)
    var sec = SparseSecondaryMap[Int]()

    var e = sec.entry(a).value()
    assert_false(e.is_occupied())
    assert_equal(e.key(), a)
    e.or_insert(1) += 10
    assert_equal(sec[a], 11)
    sec.entry(a).value().or_default() += 1
    assert_equal(sec[a], 12)
    _ = sec.entry(a).value().and_modify(_add_one)
    _ = sec.entry(b).value().and_modify(_add_one)
    assert_equal(sec[a], 13)
    assert_false(b in sec)
    sec.entry(b).value().or_default() += 5
    assert_equal(sec[b], 5)
    assert_equal(len(sec), 2)

    var occ = sec.entry(a).value()
    assert_true(occ.is_occupied())
    assert_equal(occ.get(), 13)
    assert_equal(occ.insert(7).value(), 13)
    assert_equal(sec[a], 7)
    var kv = sec.entry(a).value().remove_entry()
    assert_equal(kv[0], a)
    assert_equal(kv[1], 7)
    assert_equal(len(sec), 1)
    assert_false(sec.entry(DefaultKey.null()))

    # A vacant entry over an outdated value replaces it.
    _ = sm.remove(b)
    var b2 = sm.insert(0)
    var e2 = sec.entry(b2).value()
    assert_false(e2.is_occupied())
    assert_false(e2.insert(9))
    assert_equal(len(sec), 1)
    assert_equal(sec[b2], 9)


def test_retain_drain_clear() raises:
    var sm = SlotMap[Int]()
    var sec = SparseSecondaryMap[Int]()
    for i in range(10):
        _ = sec.insert(sm.insert(i), i)

    def odd(k: DefaultKey, mut v: Int) -> Bool:
        return v % 2 == 1

    sec.retain(odd)
    assert_equal(len(sec), 5)
    var got = List[Int]()
    for kv in sec.drain():
        got.append(kv[1])
    assert_equal(sorted_ints(got^), [1, 3, 5, 7, 9])
    assert_equal(len(sec), 0)

    for item in sm:
        _ = sec.insert(item.key, item.value())
    var d = sec.drain()
    _ = d.__next__()
    _ = d^
    assert_equal(len(sec), 0)

    for item in sm:
        _ = sec.insert(item.key, item.value())
    sec.clear()
    assert_equal(len(sec), 0)
    for k in sm.keys():
        assert_false(k in sec)


def test_iteration() raises:
    var sm = SlotMap[Int]()
    var sec = SparseSecondaryMap[Int]()
    for i in range(10):
        _ = sec.insert(sm.insert(i), i)
    for item in sec:
        item.value() *= 2
    var total = 0
    for v in sec.values():
        total += v
    assert_equal(total, 90)
    var nk = 0
    for k in sec.keys():
        assert_equal(sec[k], sm[k] * 2)
        nk += 1
    assert_equal(nk, 10)
    var n = 0
    for kv in sec^:
        assert_equal(kv[1], sm[kv[0]] * 2)
        n += 1
    assert_equal(n, 10)


def test_equality() raises:
    var sm = SlotMap[Int]()
    var a = SparseSecondaryMap[Int]()
    var b = SparseSecondaryMap[Int]()
    var k1 = sm.insert(1)
    var k2 = sm.insert(2)
    _ = a.insert(k1, 1)
    _ = a.insert(k2, 2)
    _ = b.insert(k2, 2)
    assert_false(a == b)
    _ = b.insert(k1, 1)
    assert_true(a == b)
    b[k1] = 5
    assert_false(a == b)
    assert_true(a == a.copy())


def test_drops() raises:
    var drops = 0
    var ptr = Pointer(to=drops).unsafe_origin_cast[MutUntrackedOrigin]()
    var sm = SlotMap[Int]()
    var sec = SparseSecondaryMap[DropCounter]()
    var keys = List[DefaultKey]()
    for i in range(100):
        keys.append(sm.insert(i))
        _ = sec.insert(keys[i], DropCounter(ptr))
    assert_equal(drops, 0)
    # Replacing a value drops the old one.
    _ = sec.insert(keys[0], DropCounter(ptr))
    assert_equal(drops, 1)
    # A newer key drops the outdated value.
    _ = sm.remove(keys[1])
    _ = sec.insert(sm.insert(0), DropCounter(ptr))
    assert_equal(drops, 2)
    # An older key's value is dropped without being stored.
    _ = sec.insert(keys[1], DropCounter(ptr))
    assert_equal(drops, 3)
    for i in range(2, 52):
        _ = sec.remove(keys[i])
    assert_equal(drops, 53)
    var copy = sec.copy()
    _ = sec^
    assert_equal(drops, 103)
    _ = copy^
    assert_equal(drops, 153)


def test_disjoint() raises:
    var sm = SlotMap[Int]()
    var sec = SparseSecondaryMap[Int]()
    for i in range(20):
        _ = sec.insert(sm.insert(i), i)

    def even(k: DefaultKey, mut v: Int) -> Bool:
        return v % 2 == 0

    sec.retain(even)
    var keys = List[DefaultKey]()
    for k in sec.keys():
        keys.append(k)
    for i in range(len(keys)):
        for j in range(len(keys)):
            var r = sec.get_disjoint_mut[2]([keys[i], keys[j]])
            if r:
                ref ps = r.value()
                ps[0][] ^= ps[1][]
                ps[1][] += ps[0][]
            else:
                assert_equal(i, j)
    for i in range(len(keys)):
        for j in range(len(keys)):
            for k in range(len(keys)):
                var r = sec.get_disjoint_mut[3]([keys[i], keys[j], keys[k]])
                if not r:
                    assert_true(i == j or j == k or i == k)
    for k in keys:
        assert_true(k in sec)


def test_move_only_values() raises:
    var sm = SlotMap[Int]()
    var sec = SparseSecondaryMap[MoveOnly]()
    var k = sm.insert(0)
    _ = sec.insert(k, MoveOnly(5))
    for item in sec:
        item.value().data += 1
    assert_equal(sec.remove(k).value().data, 6)


def test_equiv_dict() raises:
    """Port of the `qc_secmap_equiv_hashmap` quickcheck test."""
    for seed in range(200):
        var rng = Rng(UInt64(seed))
        var hm = Dict[Int, Int]()
        var hm_keys = List[Int]()
        var unique = 0
        var sm = SlotMap[Int]()
        var sec = SparseSecondaryMap[Int]()
        var sm_keys = List[DefaultKey]()
        for _ in range(rng.below(200)):
            var op = rng.below(4)
            var val = rng.below(1000)
            if op == 0:
                hm[unique] = val
                hm_keys.append(unique)
                unique += 1
                var k = sm.insert(val)
                _ = sec.insert(k, val)
                sm_keys.append(k)
            elif op == 1:
                if len(hm_keys) == 0:
                    continue
                var idx = val % len(hm_keys)
                _ = sm.remove(sm_keys[idx])
                var a = hm.pop(hm_keys[idx], -1)
                var b = sec.remove(sm_keys[idx])
                assert_equal(a, b.or_else(-1))
            elif op == 2:
                if len(hm_keys) == 0:
                    continue
                var idx = val % len(hm_keys)
                assert_equal(hm_keys[idx] in hm, sm_keys[idx] in sec)
                assert_equal(
                    hm.get(hm_keys[idx], -1), sec.get(sm_keys[idx]).or_else(-1)
                )
            else:
                sec = sec.copy()
            assert_equal(len(hm), len(sec))
        var hv = List[Int]()
        for e in hm.items():
            hv.append(e.value)
        var sv = List[Int]()
        for v in sec.values():
            sv.append(v)
        assert_equal(sorted_ints(hv^), sorted_ints(sv^))


def test_custom_hasher() raises:
    comptime FastMap = SparseSecondaryMap[Int, DefaultKey, AHasher[0]]
    var sm = SlotMap[Int]()
    var sec = FastMap()
    var key1 = sm.insert(42)
    _ = sec.insert(key1, 1234)
    assert_equal(sec[key1], 1234)
    assert_equal(len(sec), 1)
    var sec2 = FastMap()
    for item in sec:
        _ = sec2.insert(item.key, item.value())
    assert_true(sec == sec2)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
