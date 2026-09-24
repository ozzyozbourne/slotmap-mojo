"""Tests shared by `SlotMap`, `HopSlotMap` and `DenseSlotMap`.

Each test body is written once against the `SlotMapLike` trait and
instantiated for all three maps at compile time. `rebind` converts between the
trait's abstract `KeyType`/`ValueType` and the concrete types a test uses;
it is checked when each instantiation is compiled.
"""

from std.testing import (
    assert_equal,
    assert_false,
    assert_true,
    TestSuite,
)

from slotmap import (
    DefaultKey,
    DenseSlotMap,
    HopSlotMap,
    Item,
    KeyData,
    SlotMap,
    SlotMapLike,
    TypedKey,
)
from helpers import (
    DropCounter,
    MoveOnly,
    Rng,
    drain_any,
    insert_with_key_any,
    into_iter_any,
    items_any,
    retain_any,
    sorted_ints,
    try_insert_with_key_any,
)


# ===-----------------------------------------------------------------------===#
# Helpers for moving between the abstract and concrete types.
# ===-----------------------------------------------------------------------===#


@inline(.always)
def val[M: SlotMapLike, T: Movable](var x: T) -> M.ValueType where conforms_to(M.ValueType, Deinitable):
    """Converts a concrete value to the map's value type."""
    return rebind_var[M.ValueType](x^)


@inline(.always)
def get[
    M: SlotMapLike, T: AnyType
](ref m: M, key: M.KeyType) -> ref[m] T where conforms_to(M.ValueType, Deinitable):
    """Returns the value for a key (which must be present) as a `T`."""
    return rebind[T](m.get_ptr(key).value().unsafe_origin_cast[origin_of(m)]()[])


def values_of[M: SlotMapLike](ref m: M) -> List[Int] where conforms_to(M.ValueType, Deinitable):
    """Collects the values of a map of `Int`s."""
    var out = List[Int]()
    for it in items_any[M, Int](m):
        out.append(it.value())
    return out^


def keys_of[M: SlotMapLike](ref m: M) -> List[M.KeyType] where conforms_to(M.ValueType, Deinitable):
    var out = List[M.KeyType]()
    for it in items_any[M, M.ValueType](m):
        out.append(it.key)
    return out^


# ===-----------------------------------------------------------------------===#
# Test bodies, generic over the map type.
# ===-----------------------------------------------------------------------===#


def _readme_example[M: SlotMapLike]() raises where conforms_to(M.ValueType, Deinitable):
    var sm = M()
    var foo = sm.insert(val[M](String("foo")))
    var bar = sm.insert(val[M](String("bar")))
    assert_equal(get[M, String](sm, foo), "foo")
    assert_equal(get[M, String](sm, bar), "bar")

    _ = sm.remove(bar)
    var reuse = sm.insert(val[M](String("reuse")))
    assert_false(bar in sm)
    assert_equal(reuse.data().idx, bar.data().idx)  # Space from bar reused.
    assert_equal(get[M, String](sm, reuse), "reuse")


def _basic_ops[M: SlotMapLike]() raises where conforms_to(M.ValueType, Deinitable):
    var sm = M(capacity=10)
    assert_true(sm.capacity() >= 10)
    assert_equal(len(sm), 0)
    var k = sm.insert(val[M](42))
    assert_equal(len(sm), 1)
    get[M, Int](sm, k) += 1
    assert_equal(get[M, Int](sm, k), 43)
    var removed = sm.remove(k)
    assert_equal(rebind[Int](removed.value()), 43)
    assert_false(sm.remove(k))
    assert_false(sm.get_ptr(k))
    assert_equal(len(sm), 0)


def _null_key[M: SlotMapLike]() raises where conforms_to(M.ValueType, Deinitable):
    var sm = M()
    var k = sm.insert(val[M](42))
    var nk = M.KeyType.null()
    assert_true(nk.is_null())
    assert_true(k != nk)
    assert_false(nk in sm)
    assert_false(sm.get_ptr(nk))


def _versions_bump[M: SlotMapLike]() raises where conforms_to(M.ValueType, Deinitable):
    var sm = M()
    var a = sm.insert(val[M](1))
    _ = sm.remove(a)
    var b = sm.insert(val[M](2))
    assert_equal(a.data().idx, b.data().idx)
    assert_equal(b.data().version, a.data().version + 2)
    assert_false(a in sm)
    assert_true(b in sm)


def _insert_with_key[M: SlotMapLike]() raises where conforms_to(M.ValueType, Deinitable):
    var sm = M()

    def self_key(k: M.KeyType) -> M.ValueType:
        return rebind_var[M.ValueType](k)

    var k = insert_with_key_any(sm, self_key)
    assert_equal(get[M, M.KeyType](sm, k), k)


def _try_insert_with_key[M: SlotMapLike]() raises where conforms_to(M.ValueType, Deinitable):
    var sm = M()
    var a = sm.insert(val[M](1))
    _ = sm.remove(a)

    def fail(k: M.KeyType) raises -> M.ValueType:
        raise Error("nope")

    def ok(k: M.KeyType) raises -> M.ValueType:
        return rebind_var[M.ValueType](Int(k.data().idx))

    try:
        _ = try_insert_with_key_any(sm, fail)
        assert_true(False)
    except:
        pass
    assert_equal(len(sm), 0)
    # The failed insert must not have consumed the free slot.
    var b = try_insert_with_key_any(sm, ok)
    assert_equal(b.data().idx, a.data().idx)
    assert_equal(get[M, Int](sm, b), Int(a.data().idx))


def _retain[M: SlotMapLike]() raises where conforms_to(M.ValueType, Deinitable):
    var sm = M()
    for i in range(20):
        _ = sm.insert(val[M](i))

    def keep_even(k: M.KeyType, mut v: M.ValueType) -> Bool:
        ref x = rebind[Int](v)
        x *= 10
        return x % 20 == 0

    retain_any(sm, keep_even)
    assert_equal(len(sm), 10)
    assert_equal(
        sorted_ints(values_of(sm)),
        [0, 20, 40, 60, 80, 100, 120, 140, 160, 180],
    )


def _iteration_and_mutation[M: SlotMapLike]() raises where conforms_to(M.ValueType, Deinitable):
    var sm = M()
    var keys = List[M.KeyType]()
    for i in range(10):
        keys.append(sm.insert(val[M](i)))
    _ = sm.remove(keys[3])
    for it in items_any[M, Int](sm):
        it.value() += 100
    var n = 0
    for it in items_any[M, Int](sm):
        assert_equal(get[M, Int](sm, it.key), it.value())
        assert_true(it.value() >= 100)
        n += 1
    assert_equal(n, 9)
    for k in keys_of(sm):
        assert_true(k in sm)


def _drain[M: SlotMapLike]() raises where conforms_to(M.ValueType, Deinitable):
    var sm = M()
    for i in range(10):
        _ = sm.insert(val[M](i))
    var got = List[Int]()
    for kv in drain_any[M, Int](sm):
        got.append(kv[1])
    assert_equal(sorted_ints(got^), [0, 1, 2, 3, 4, 5, 6, 7, 8, 9])
    assert_equal(len(sm), 0)

    # A partially consumed drain still removes everything.
    for i in range(10):
        _ = sm.insert(val[M](i))
    assert_equal(len(drain_any[M, Int](sm, limit=1)), 1)
    assert_equal(len(sm), 0)
    # All slots are reusable.
    for i in range(10):
        _ = sm.insert(val[M](i))
    assert_equal(len(sm), 10)


def _into_iter[M: SlotMapLike]() raises where conforms_to(M.ValueType, Deinitable):
    var sm = M()
    _ = sm.insert(val[M](String("a")))
    _ = sm.insert(val[M](String("b")))
    var got = into_iter_any[M, String](sm^)
    assert_equal(len(got), 2)
    for kv in got:
        assert_true(kv[1] == "a" or kv[1] == "b")


def _make_and_clone[
    M: SlotMapLike & Copyable
](ptr: Pointer[Int, MutUntrackedOrigin]) raises -> M where conforms_to(M.ValueType, Deinitable):
    # Insert 1000 items, remove the even ones.
    var sm = M()
    var keys = List[M.KeyType]()
    for _ in range(1000):
        keys.append(sm.insert(val[M](DropCounter(ptr))))
    for i in range(0, 1000, 2):
        _ = sm.remove(keys[i])
    assert_equal(ptr[], 500)
    return sm.copy()


def _check_drops[M: SlotMapLike & Copyable]() raises where conforms_to(M.ValueType, Deinitable):
    var drops = 0
    var ptr = Pointer(to=drops).unsafe_origin_cast[MutUntrackedOrigin]()
    var clone = _make_and_clone[M](ptr)
    # Now all original items should have been dropped exactly once.
    assert_equal(drops, 1000)
    for _ in range(250):
        _ = clone.insert(val[M](DropCounter(ptr)))
    _ = clone^
    # 1000 + 750 drops in total.
    assert_equal(drops, 1750)


def _disjoint[M: SlotMapLike]() raises where conforms_to(M.ValueType, Deinitable):
    var sm = M()
    for i in range(20):
        _ = sm.insert(val[M](i))

    def even(k: M.KeyType, mut v: M.ValueType) -> Bool:
        return rebind[Int](v) % 2 == 0

    retain_any(sm, even)
    var keys = keys_of(sm)
    for i in range(len(keys)):
        for j in range(len(keys)):
            var r = sm.get_disjoint_mut[2]([keys[i], keys[j]])
            if r:
                ref ps = r.value()
                ref a = rebind[Int](ps[0][])
                ref b = rebind[Int](ps[1][])
                a ^= b
                b += a
            else:
                assert_equal(i, j)
    for i in range(len(keys)):
        for j in range(len(keys)):
            for k in range(len(keys)):
                var r = sm.get_disjoint_mut[3]([keys[i], keys[j], keys[k]])
                if not r:
                    assert_true(i == j or j == k or i == k)
    # All versions were restored.
    for k in keys:
        assert_true(k in sm)


def _move_only_values[M: SlotMapLike]() raises where conforms_to(M.ValueType, Deinitable):
    var sm = M()
    var k = sm.insert(val[M](MoveOnly(5)))
    assert_equal(get[M, MoveOnly](sm, k).data, 5)
    for it in items_any[M, MoveOnly](sm):
        it.value().data += 1
    var removed = sm.remove(k)
    assert_equal(rebind[MoveOnly](removed.value()).data, 6)


def _equiv_dict[M: SlotMapLike & Copyable]() raises where conforms_to(M.ValueType, Deinitable):
    """Port of the `qc_slotmap_equiv_hashmap` quickcheck test."""
    for seed in range(200):
        var rng = Rng(UInt64(seed))
        var hm = Dict[Int, Int]()
        var hm_keys = List[Int]()
        var unique = 0
        var sm = M()
        var sm_keys = List[M.KeyType]()
        for _ in range(rng.below(200)):
            var op = rng.below(4)
            var v = rng.below(1000)
            if op == 0:
                hm[unique] = v
                hm_keys.append(unique)
                unique += 1
                sm_keys.append(sm.insert(val[M](v)))
            elif op == 1:
                if v % 10 == 0:
                    var hv = List[Int]()
                    for e in hm.items():
                        hv.append(e.value)
                    hm.clear()
                    var sv = List[Int]()
                    for kv in drain_any[M, Int](sm):
                        sv.append(kv[1])
                    assert_equal(sorted_ints(hv^), sorted_ints(sv^))
                if len(hm_keys) == 0:
                    continue
                var idx = v % len(hm_keys)
                var a = hm.pop(hm_keys[idx], -1)
                var b = sm.remove(sm_keys[idx])
                assert_equal(a, rebind[Int](b.value()) if b else -1)
            elif op == 2:
                if len(hm_keys) == 0:
                    continue
                var idx = v % len(hm_keys)
                assert_equal(hm_keys[idx] in hm, sm_keys[idx] in sm)
                var want = hm.get(hm_keys[idx], -1)
                var got = get[M, Int](sm, sm_keys[idx]) if sm_keys[
                    idx
                ] in sm else -1
                assert_equal(want, got)
            else:
                sm = sm.copy()
            assert_equal(len(hm), len(sm))
        var hv = List[Int]()
        for e in hm.items():
            hv.append(e.value)
        assert_equal(sorted_ints(hv^), sorted_ints(values_of(sm)))


struct _PlayerTag:
    pass


comptime PlayerKey = TypedKey[_PlayerTag]


def _custom_key[M: SlotMapLike]() raises where conforms_to(M.ValueType, Deinitable):
    var sm = M()
    var k = sm.insert(val[M](String("bob")))
    var pk: PlayerKey = rebind[PlayerKey](k)
    assert_equal(get[M, String](sm, k), "bob")
    assert_false(pk.is_null())


# ===-----------------------------------------------------------------------===#
# Instantiations: every test runs against all three maps.
# ===-----------------------------------------------------------------------===#


def test_readme_example() raises:
    _readme_example[SlotMap[String]]()
    _readme_example[HopSlotMap[String]]()
    _readme_example[DenseSlotMap[String]]()


def test_basic_ops() raises:
    _basic_ops[SlotMap[Int]]()
    _basic_ops[HopSlotMap[Int]]()
    _basic_ops[DenseSlotMap[Int]]()


def test_null_key() raises:
    _null_key[SlotMap[Int]]()
    _null_key[HopSlotMap[Int]]()
    _null_key[DenseSlotMap[Int]]()


def test_versions_bump() raises:
    _versions_bump[SlotMap[Int]]()
    _versions_bump[HopSlotMap[Int]]()
    _versions_bump[DenseSlotMap[Int]]()


def test_insert_with_key() raises:
    _insert_with_key[SlotMap[DefaultKey]]()
    _insert_with_key[HopSlotMap[DefaultKey]]()
    _insert_with_key[DenseSlotMap[DefaultKey]]()


def test_try_insert_with_key() raises:
    _try_insert_with_key[SlotMap[Int]]()
    _try_insert_with_key[HopSlotMap[Int]]()
    _try_insert_with_key[DenseSlotMap[Int]]()


def test_retain() raises:
    _retain[SlotMap[Int]]()
    _retain[HopSlotMap[Int]]()
    _retain[DenseSlotMap[Int]]()


def test_iteration_and_mutation() raises:
    _iteration_and_mutation[SlotMap[Int]]()
    _iteration_and_mutation[HopSlotMap[Int]]()
    _iteration_and_mutation[DenseSlotMap[Int]]()


def test_drain() raises:
    _drain[SlotMap[Int]]()
    _drain[HopSlotMap[Int]]()
    _drain[DenseSlotMap[Int]]()


def test_into_iter() raises:
    _into_iter[SlotMap[String]]()
    _into_iter[HopSlotMap[String]]()
    _into_iter[DenseSlotMap[String]]()


def test_check_drops() raises:
    _check_drops[SlotMap[DropCounter]]()
    _check_drops[HopSlotMap[DropCounter]]()
    _check_drops[DenseSlotMap[DropCounter]]()


def test_disjoint() raises:
    _disjoint[SlotMap[Int]]()
    _disjoint[HopSlotMap[Int]]()
    _disjoint[DenseSlotMap[Int]]()


def test_move_only_values() raises:
    _move_only_values[SlotMap[MoveOnly]]()
    _move_only_values[HopSlotMap[MoveOnly]]()
    _move_only_values[DenseSlotMap[MoveOnly]]()


def test_custom_key() raises:
    _custom_key[SlotMap[String, PlayerKey]]()
    _custom_key[HopSlotMap[String, PlayerKey]]()
    _custom_key[DenseSlotMap[String, PlayerKey]]()


def test_equiv_dict() raises:
    _equiv_dict[SlotMap[Int]]()
    _equiv_dict[HopSlotMap[Int]]()
    _equiv_dict[DenseSlotMap[Int]]()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
