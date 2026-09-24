"""Benchmarks for the Mojo port, mirroring `bench/rust/benches/slotmap.rs`
workload for workload. `bench/compare.py` joins the two result sets.

Every benchmark times one pass over `n` elements. Setup that must be fresh
for each pass (an empty map to insert into, a full map to remove from) is
excluded from the timing with `Bencher.iter_preproc`, like Criterion's
`iter_batched`.

Usage: bench_slotmap [-o results.csv]. Set SLOTMAP_BENCH_QUICK=1 for a short
smoke run.
"""

from std.benchmark import Bench, BenchConfig, Bencher, BenchId, keep
from std.os import getenv
from std.pathlib import Path

from slotmap import (
    DefaultKey,
    DenseSlotMap,
    HopSlotMap,
    Item,
    SecondaryMap,
    SlotMap,
    SlotMapLike,
    SparseSecondaryMap,
)


# ===-----------------------------------------------------------------------===#
# Workload helpers, identical to bench/rust/src/lib.rs.
# ===-----------------------------------------------------------------------===#

comptime SEED: UInt64 = 0x5EED


struct Rng(Movable):
    """The xorshift64* generator."""

    var state: UInt64

    def __init__(out self, seed: UInt64):
        self.state = seed * 0x9E3779B97F4A7C15 + 1

    def next(mut self) -> UInt64:
        self.state ^= self.state >> 12
        self.state ^= self.state << 25
        self.state ^= self.state >> 27
        return self.state * 0x2545F4914F6CDD1D


def shuffle[T: Copyable](mut v: List[T]):
    """Fisher-Yates shuffle, identical in both languages."""
    var rng = Rng(SEED)
    var i = len(v) - 1
    while i >= 1:
        var j = Int(rng.next() % UInt64(i + 1))
        v.swap_elements(i, j)
        i -= 1


# ===-----------------------------------------------------------------------===#
# SlotMap, HopSlotMap, DenseSlotMap: one generic function over `SlotMapLike`.
# ===-----------------------------------------------------------------------===#


def bench_primary[
    M: SlotMapLike & Copyable
](mut b: Bench, name: String, n: Int) raises where conforms_to(
    M.ValueType, Deinitable
):
    var full = M()
    var keys = List[M.KeyType](capacity=n)
    for i in range(n):
        keys.append(full.insert(rebind_var[M.ValueType](i)))
    shuffle(keys)

    # Half the elements removed in random order: iteration must skip holes.
    var half = full.copy()
    for i in range(n // 2):
        _ = half.remove(keys[i])

    # All elements removed: inserting reuses the free list.
    var emptied = full.copy()
    for k in keys:
        _ = emptied.remove(k)

    def fresh(mut m: M):
        m = M()

    def insert_n(mut m: M) {n}:
        for i in range(n):
            var k = m.insert(rebind_var[M.ValueType](i))
            keep(k)

    def bench_insert(mut bencher: Bencher) raises {insert_n}:
        var state = M()
        bencher.iter_preproc(state, insert_n, fresh)

    b.bench_function(bench_insert, BenchId(name + "/insert", String(n)))

    def get_all() {keys, full}:
        var sum = 0
        for k in keys:
            sum += rebind[Int](full.get_ptr(k).value()[])
        keep(sum)

    def bench_get(mut bencher: Bencher) raises {get_all}:
        bencher.iter(get_all)

    b.bench_function(bench_get, BenchId(name + "/get", String(n)))

    def refill(mut m: M) {full}:
        m = full.copy()

    def remove_all(mut m: M) {keys}:
        for k in keys:
            # The enclosing `where` clause doesn't reach into closures, so the
            # result is rebound to its concrete type to be droppable.
            var v = rebind_var[Optional[Int]](m.remove(k))
            keep(v)

    def bench_remove(mut bencher: Bencher) raises {refill, remove_all}:
        var state = M()
        bencher.iter_preproc(state, remove_all, refill)

    b.bench_function(bench_remove, BenchId(name + "/remove", String(n)))

    def iter_half() {half}:
        var sum = 0
        # Generic code can't drop an iterator element (its type is only known
        # to be `Movable`), so each one is moved into its concrete type.
        var it = half.__iter__()
        while True:
            try:
                var item = rebind_var[Item[M.KeyType, Int, origin_of(half)]](
                    it.__next__()
                )
                sum += item.value()
            except StopIteration:
                break
        keep(sum)

    def bench_iter_half(mut bencher: Bencher) raises {iter_half}:
        bencher.iter(iter_half)

    b.bench_function(bench_iter_half, BenchId(name + "/iter_half", String(n)))

    def reset_emptied(mut m: M) {emptied}:
        m = emptied.copy()

    def bench_reinsert(mut bencher: Bencher) raises {insert_n, reset_emptied}:
        var state = M()
        bencher.iter_preproc(state, insert_n, reset_emptied)

    b.bench_function(bench_reinsert, BenchId(name + "/reinsert", String(n)))


# ===-----------------------------------------------------------------------===#
# SecondaryMap and SparseSecondaryMap (no shared trait, so written out twice).
# ===-----------------------------------------------------------------------===#


def secondary_keys(n: Int) -> List[DefaultKey]:
    var sm = SlotMap[Int]()
    var keys = List[DefaultKey](capacity=n)
    for i in range(n):
        keys.append(sm.insert(i))
    shuffle(keys)
    return keys^


def bench_secondary(mut b: Bench, n: Int) raises:
    comptime S = SecondaryMap[Int]
    var name = String("SecondaryMap")
    var keys = secondary_keys(n)
    var full = S()
    for i in range(n):
        _ = full.insert(keys[i], i)

    def fresh(mut m: S):
        m = S()

    def insert_all(mut m: S) {keys}:
        for i in range(len(keys)):
            var old = m.insert(keys[i], i)
            keep(old)

    def bench_insert(mut bencher: Bencher) raises {insert_all}:
        var state = S()
        bencher.iter_preproc(state, insert_all, fresh)

    b.bench_function(bench_insert, BenchId(name + "/insert", String(n)))

    def get_all() {keys, full}:
        var sum = 0
        for k in keys:
            sum += full.get_ptr(k).value()[]
        keep(sum)

    def bench_get(mut bencher: Bencher) raises {get_all}:
        bencher.iter(get_all)

    b.bench_function(bench_get, BenchId(name + "/get", String(n)))

    def refill(mut m: S) {full}:
        m = full.copy()

    def remove_all(mut m: S) {keys}:
        for k in keys:
            var v = m.remove(k)
            keep(v)

    def bench_remove(mut bencher: Bencher) raises {refill, remove_all}:
        var state = S()
        bencher.iter_preproc(state, remove_all, refill)

    b.bench_function(bench_remove, BenchId(name + "/remove", String(n)))

    def iter_all() {full}:
        var sum = 0
        for item in full:
            sum += item.value()
        keep(sum)

    def bench_iter(mut bencher: Bencher) raises {iter_all}:
        bencher.iter(iter_all)

    b.bench_function(bench_iter, BenchId(name + "/iter", String(n)))


def bench_sparse_secondary(mut b: Bench, n: Int) raises:
    comptime S = SparseSecondaryMap[Int]  # Default hasher: AHasher.
    var name = String("SparseSecondaryMap")
    var keys = secondary_keys(n)
    var full = S()
    for i in range(n):
        _ = full.insert(keys[i], i)

    def fresh(mut m: S):
        m = S()

    def insert_all(mut m: S) {keys}:
        for i in range(len(keys)):
            var old = m.insert(keys[i], i)
            keep(old)

    def bench_insert(mut bencher: Bencher) raises {insert_all}:
        var state = S()
        bencher.iter_preproc(state, insert_all, fresh)

    b.bench_function(bench_insert, BenchId(name + "/insert", String(n)))

    def get_all() {keys, full}:
        var sum = 0
        for k in keys:
            sum += full.get_ptr(k).value()[]
        keep(sum)

    def bench_get(mut bencher: Bencher) raises {get_all}:
        bencher.iter(get_all)

    b.bench_function(bench_get, BenchId(name + "/get", String(n)))

    def refill(mut m: S) {full}:
        m = full.copy()

    def remove_all(mut m: S) {keys}:
        for k in keys:
            var v = m.remove(k)
            keep(v)

    def bench_remove(mut bencher: Bencher) raises {refill, remove_all}:
        var state = S()
        bencher.iter_preproc(state, remove_all, refill)

    b.bench_function(bench_remove, BenchId(name + "/remove", String(n)))

    def iter_all() {full}:
        var sum = 0
        for item in full:
            sum += item.value()
        keep(sum)

    def bench_iter(mut bencher: Bencher) raises {iter_all}:
        bencher.iter(iter_all)

    b.bench_function(bench_iter, BenchId(name + "/iter", String(n)))


def main() raises:
    var quick = getenv("SLOTMAP_BENCH_QUICK") == "1"
    # Thorough by default: at least 2 s and at most 5 s per benchmark, close
    # to Criterion's default 5 s measurement. -o sets the CSV output path.
    var config = BenchConfig(
        min_runtime_secs=0.0 if quick else 2.0,
        max_runtime_secs=0.1 if quick else 5.0,
        num_warmup_iters=2 if quick else 10,
        max_iters=10_000_000,
    )
    config.show_progress = False
    var b = Bench(config^)
    var sizes: List[Int] = [1_000, 100_000, 1_000_000]
    for n in sizes:
        bench_primary[SlotMap[Int]](b, "SlotMap", n)
        bench_primary[HopSlotMap[Int]](b, "HopSlotMap", n)
        bench_primary[DenseSlotMap[Int]](b, "DenseSlotMap", n)
        bench_secondary(b, n)
        bench_sparse_secondary(b, n)
    b.dump_report()
