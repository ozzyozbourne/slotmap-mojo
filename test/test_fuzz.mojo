"""Port of `fuzz/fuzz_targets`: random operation streams checked against a
model after every step. Written once against `SlotMapLike` and instantiated
for each primary map. Run with `-D ASSERT=all`."""

from std.testing import assert_equal, assert_false, assert_true, TestSuite

from slotmap import DenseSlotMap, HopSlotMap, SlotMap, SlotMapLike
from helpers import (
    Rng,
    drain_any,
    insert_with_key_any,
    into_iter_any,
    items_any,
    retain_any,
)


def fuzz[M: SlotMapLike](seed: Int) raises where conforms_to(M.ValueType, Deinitable):
    var rng = Rng(UInt64(seed))
    var map = M() if rng.below(2) == 0 else M(capacity=rng.below(256))
    var model = Dict[UInt64, Int]()
    var keys = List[M.KeyType]()

    def key_idx(k: M.KeyType) -> M.ValueType:
        return rebind_var[M.ValueType](Int(k.data().idx))

    for _ in range(rng.below(300)):
        var op = rng.below(9)
        if op == 0:
            map.reserve(rng.below(256))
        elif op == 1 or op == 2:
            var v = rng.below(1000)
            var k: M.KeyType
            if op == 1:
                k = map.insert(rebind_var[M.ValueType](v))
            else:
                k = insert_with_key_any(map, key_idx)
                v = Int(k.data().idx)
            assert_false(k.data().as_ffi() in model)
            model[k.data().as_ffi()] = v
            keys.append(k)
        elif op == 3:
            if len(keys) == 0:
                continue
            var k = keys[rng.below(len(keys))]
            var got = map.remove(k)
            var want = model.pop(k.data().as_ffi(), -1)
            assert_equal(rebind[Int](got.value()) if got else -1, want)
        elif op == 4:
            var mask = rng.next()

            def pred(k: M.KeyType, mut v: M.ValueType) {mut mask} -> Bool:
                var keep = mask & 1 == 1
                mask >>= 1
                return keep

            retain_any(map, pred)
            var rebuilt = Dict[UInt64, Int]()
            for it in items_any[M, Int](map):
                rebuilt[it.key.data().as_ffi()] = it.value()
            for e in rebuilt.items():
                assert_equal(model.get(e.key, -1), e.value)
            model = rebuilt^
        elif op == 5:
            map.clear()
            model.clear()
        elif op == 6:
            # A partial drain removes everything.
            for kv in drain_any[M, Int](map, limit=rng.below(8)):
                assert_equal(model.pop(kv[0].data().as_ffi(), -1), kv[1])
            model.clear()
        elif op == 7:
            var ct = rng.below(8)
            var items = items_any[M, Int](map)
            for i in range(min(ct, len(items))):
                items[i].value() += 1
                model[items[i].key.data().as_ffi()] += 1
        else:
            if len(keys) == 0:
                continue
            var a = keys[rng.below(len(keys))]
            var b = keys[rng.below(len(keys))]
            var c = keys[rng.below(len(keys))]
            var d = keys[rng.below(len(keys))]
            var r = map.get_disjoint_mut[4]([a, b, c, d])
            var all_valid = a in map and b in map and c in map and d in map
            var distinct = (
                a != b and a != c and a != d and b != c and b != d and c != d
            )
            assert_equal(Bool(r), all_valid and distinct)
            if r:
                ref ps = r.value()
                for p in ps:
                    rebind[Int](p[]) += 1
                for k in [a, b, c, d]:
                    model[k.data().as_ffi()] += 1

        # Invariants: contents match the model exactly.
        assert_equal(len(map), len(model))
        var items = items_any[M, Int](map)
        assert_equal(len(items), len(model))
        for it in items:
            assert_equal(model.get(it.key.data().as_ffi(), -1000000), it.value())
            assert_true(it.key in map)
        for k in keys:
            assert_equal(k in map, k.data().as_ffi() in model)

    # Destructor: drop, or consume partially through the owned iterator.
    if rng.below(2) == 1:
        for kv in into_iter_any[M, Int](map^, limit=rng.below(8)):
            assert_equal(model.pop(kv[0].data().as_ffi(), -1), kv[1])


def test_fuzz_slotmap() raises:
    for seed in range(300):
        fuzz[SlotMap[Int]](seed)


def test_fuzz_hopslotmap() raises:
    for seed in range(300):
        fuzz[HopSlotMap[Int]](seed)


def test_fuzz_denseslotmap() raises:
    for seed in range(300):
        fuzz[DenseSlotMap[Int]](seed)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
