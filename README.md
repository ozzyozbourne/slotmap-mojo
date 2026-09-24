# slotmap for Mojo

[![Test](https://github.com/ozzyozbourne/slotmap-mojo/actions/workflows/test.yml/badge.svg)](https://github.com/ozzyozbourne/slotmap-mojo/actions/workflows/test.yml)

A port of the Rust [`slotmap`](https://github.com/orlp/slotmap) crate (v1.1.1) to Mojo
(nightly `1.2.0.dev2026092305`). It provides containers with persistent unique
keys: insertion, access and removal are O(1), and a removed key stays invalid
even after its storage slot is reused.

| Container | Use it for |
|---|---|
| `SlotMap` | The default. Fastest insert, access and removal. |
| `DenseSlotMap` | Iteration as fast as a `List`. Access costs one extra indirection. |
| `HopSlotMap` | Iteration that skips blocks of empty slots. Deprecated upstream. |
| `SecondaryMap` | Extra data for most keys of a slot map. Direct indexing. |
| `SparseSecondaryMap` | Extra data for a few keys of a slot map. Hash based. |

```mojo
from slotmap import SlotMap, SecondaryMap

def main():
    var sm = SlotMap[String]()
    var foo = sm.insert("foo")  # Key generated on insert.
    var bar = sm.insert("bar")
    _ = sm.remove(bar)
    var reuse = sm.insert("reuse")  # Space from bar reused.
    print(bar in sm)                # False: after deletion a key stays invalid.

    var sec = SecondaryMap[String]()
    _ = sec.insert(foo, "noun")
    _ = sec.insert(reuse, "verb")
    for item in sm:
        print(item.value(), "is a", sec[item.key])
```

## Running

```bash
pixi run test           # every test and example, with -D ASSERT=all
pixi run test-release   # the same, with default assertions
pixi run mojo run -I . examples/rand_meld_heap.mojo
```

To use the package from another project, add this directory to the import path
(`mojo run -I path/to/port ...`), or run `mojo precompile slotmap -o slotmap.mojoc`.

## Benchmarks

`bench/` runs the same workloads against the Rust crate (Criterion) and this
port (`std.benchmark`), then prints a side-by-side table of mean time per
element. The workloads are insert, shuffled get, shuffled remove, iterating a
half-empty map and re-inserting into freed slots, at 1K, 100K and 1M elements.

```bash
pixi run bench        # thorough, about 25 minutes
pixi run bench-quick  # about 1 minute, rough numbers
```

The `Benchmark` workflow runs the thorough suite on a GitHub macOS runner,
on demand and weekly. It posts the table to the run summary and uploads the
raw results. Shared runners are noisy, so differences under about 15% are
not meaningful there. `bench/history/` keeps the results of each CI run, and
`bench/compare.py --baseline` shows how the Mojo/Rust ratio moved.

The optimization work itself is written up in `docs/optimization-log.html`
(generated from `bench/history/log.json` by `bench/build_log.py`): every CI
round with its ratio charts, every technique tried and whether it stayed,
the issues hit, and what was learned.

Two measurement details matter more than they look:
- Both benchmarks fold each operation's result into a sum and black-box
  the sum once per pass. Mojo's `keep()` is an inline-asm barrier with a
  memory clobber; calling it per element forces the compiler to reload
  the map's state every iteration and roughly triples the measured cost
  of an insert.
- The Rust side uses `BatchSize::PerIteration`, so setup (cloning a full
  map) runs right before each timed pass, as Mojo's `iter_preproc` does.
  With larger batches the clones evict each other from cache and the
  Rust numbers for insert/remove/reinsert come out 2-5x worse.

## API differences from Rust

| Rust | Mojo |
|---|---|
| `SlotMap<K, V>` | `SlotMap[V, K = DefaultKey]`. The value comes first so the key can have a default. The same applies to every map. |
| `new_key_type! { struct PlayerKey; }` | `struct PlayerTag: pass` then `comptime PlayerKey = TypedKey[PlayerTag]`. Distinct tags give distinct types, so mixing up keys is a compile error. |
| `with_capacity(n)`, `with_key()` | `SlotMap[V](capacity=n)`. The key type comes from the struct parameter. |
| `contains_key(k)` | `k in sm` (`contains_key` also exists) |
| `get(k) -> Option<&V>` | `get(k) -> Optional[V]` returns a copy and needs `Copyable` values. `get_ptr(k) -> OptionalPointer` works for any value and is mutable if the map is. |
| `sm[k]`, `sm[k] = v` | Same. Aborts on an invalid key, where Rust panics. |
| `get_unchecked(_mut)` | `unsafe_get(k)` |
| `get_disjoint_mut([a, b])` | `get_disjoint_mut[2]([a, b]) -> Optional[Array[Pointer[V], 2]]`. `N == 0` is a compile error; Rust returns `Some([])`. |
| `iter()`, `iter_mut()` | `for item in sm:` yields an `Item` with `.key` and `.value()`. It is mutable when the map is. |
| `keys()`, `values()`, `values_mut()` | `keys()`, `values()`. Looping over `values()` needs `Copyable` values, the same limit as `List` and `Span` iteration; use `for item in sm` otherwise. |
| `detach(k) -> Option<V>`, `reattach(k, v)` | `detach(k) raises -> Detached[V, K]`, `reattach(d^)`, plus `release(d^) -> V`, which frees the slot and keeps the value. `Detached` is linear, so a detached slot can't be leaked (see below). |
| `into_iter()`, `drain()` | `for kv in sm^:` and `for kv in sm.drain():` yield `(key, value)` tuples. A partly consumed drain still empties the map. |
| `retain(\|k, v\| ...)`, `insert_with_key(\|k\| ...)` | Pass a nested `def f(k: K, mut v: V) -> Bool`, or a `lambda`. `try_insert_with_key` takes a raising function. |
| `Entry` / `OccupiedEntry` / `VacantEntry` | One `Entry` (and `SparseEntry`) struct: `or_insert`, `or_insert_with`, `or_default`, `and_modify`, `get`, `insert`, `remove`, `remove_entry`, `is_occupied` |
| `SparseSecondaryMap<K, V, S: BuildHasher>` | `SparseSecondaryMap[V, K, H: Hasher]` |
| `Debug` | `Writable`: `print(sm)` shows `{1v1: foo, 2v3: bar}`. Keys print as `idx v version`, or `null`. |
| `KeyData::as_ffi` / `from_ffi` | Same |
| (none) | `SlotMapLike`: a trait implemented by `SlotMap`, `HopSlotMap` and `DenseSlotMap` when their values are `Deinitable`, for code generic over the three. It leaves out `insert_with_key`, `try_insert_with_key` and `retain`, because the compiler can't yet match trait methods whose closure parameter types mention associated types. It also leaves out `drain` and owned iteration, because a trait can't require members that exist only conditionally. Iterator elements are only known to be `Movable`, so generic code has to `rebind` them. Functions over it need `where conforms_to(M.ValueType, Deinitable)`. |
| (none) | `SecondaryMap.insert_returning(k, v)` and `SparseSecondaryMap.insert_returning(k, v)`: like `insert`, but they never destroy a value. They return whichever value didn't end up in the map. |
| (none) | `deinit_with(f)` on every map: destroys it, passing each value to `f`. It is required for linear values. |

## Linear values and detached slots

Mojo has *linear* types (`@explicit_destroy`, `not Deinitable`): values the
compiler never destroys implicitly, such as file handles or GPU buffers that
must be closed. Rust has no equivalent. Its types can be dropped anywhere.

**Maps can hold linear values.** Each map is `Deinitable` only when its values
are. A map of linear values must be destroyed with `deinit_with(f)`:

```mojo
var files = SlotMap[File]()
var k = files.insert(open_file("a.txt"))
var f = files.remove(k)          # Optional[File]: must be consumed too
...
files^.deinit_with(close_file)   # dropping `files` would be a compile error
```

The operations that would drop values are unavailable for linear values:
`clear`, `retain`, `drain`, owned iteration, and on secondary maps `insert` and
most of the entry API. Use `remove`, `deinit_with` and `insert_returning`
instead.

**Detached slots can't leak.** In Rust, a slot whose value is `detach`ed and
never `reattach`ed is lost forever. Here `detach` returns a linear
`Detached[V, K]`: the value (`d.value`) plus a claim on its slot. The compiler
requires every path to consume it:
- `sm.reattach(d^)` puts the value back under the same key.
- `sm.release(d^)` returns the value and frees the slot.
- `d^.unsafe_forget()` gives up the slot on purpose.

**Raising.** The compiler rejects code that could raise while a linear value
is alive, because the error path would abandon it. Consume or clean up linear
values before a raising call, or catch the error.

`test/compile_fail/` holds programs that must *not* compile, each with the
expected error. They cover:
- dropping a `Detached`;
- dropping a map of linear values;
- dropping a removed linear value;
- calling `clear` on such a map;
- mixing key types;
- `get_disjoint_mut[0]`.

**Not ported:**
- serde support, `try_reserve`, `shrink_to_fit` / `shrink_to`: Mojo has no serde and no fallible allocation.
- `clone_from`.
- The `no_std` and `unstable` features.

## Implementation notes

- **Slot storage.** Rust stores `union { value, next_free }` per slot. Mojo has
  no unions, so `SlotMap`, `SecondaryMap` and `HopSlotMap` share `_Slots`
  (`slotmap/_common.mojo`): one array of `(version, next_free, value)` slots,
  where the value is initialized only while the slot's version is odd. That
  puts a slot's metadata and value on the same cache line, as in Rust. The
  same version-parity trick drives destruction, copying and growth; trivially
  movable values are moved with `memcpy`. The buffer is held as a linear
  `Allocation`, so the compiler checks that every path frees it.
- **`SparseSecondaryMap`** is a Swiss table (control bytes probed 16 at a
  time, 7/8 load factor, tombstones) over `(slot index, version, value)`
  entries, the same design as Rust's `HashMap<u32, (u32, V)>` with hashbrown.
  The default hasher, `IdxHasher`, is a multiplicative hash that stays in
  integer registers; the stdlib `AHasher` moves its 128-bit multiply through
  vector registers, and that latency sits on the critical path of every
  probe. Pass `H=` to use another `Hasher`.
- **`HopSlotMap`** keeps its free-list block metadata (`next`, `prev`,
  `other_end`) in a parallel list rather than inside the vacant slot.
- **Compile-time specialization.** Maps whose values need no destructor
  (`IsTriviallyDeinitable`, the Mojo counterpart of Rust's `needs_drop`)
  skip the per-slot destructor loop, and trivially copyable/movable values
  are copied and grown with `memcpy`. Both are `comptime if`s in `_Slots`.
- **Iteration.** Mojo's `for` calls `__next__` per element, and the compiler
  does not merge the iterator's skip loop with the consumer's loop. The
  iterators therefore take a straight-line fast path when the next slot is
  occupied and only enter a loop to skip vacant ones. Mojo also does not
  auto-vectorize reductions (even a plain pointer loop summing `Int`s
  compiles to scalar code, at any `-O` level), so summing over a
  `DenseSlotMap` stays several times slower than Rust's vectorized loop.
- **Testing.** Every Rust unit test was ported: drop counting, `disjoint`, the
  quickcheck HashMap-equivalence tests (200 seeds each), and the fuzz target
  (300 seeds per map, checked against a model after every operation).
  `test/test_primary.mojo` and `test/test_fuzz.mojo` are each written once
  against `SlotMapLike` and instantiated for all three primary maps.
  - The closure-taking methods and iteration go through helpers in
    `test/helpers.mojo`. They pick the concrete map with
    `comptime if M == SlotMap[...]` and `rebind` to it.
  - `test_maps.mojo` covers the APIs outside the trait. `test_linear.mojo`
    covers linear values in every map and `detach`/`reattach`/`release`. The
    secondary maps have their own tests. `run_tests.sh` also checks every file
    in `test/compile_fail/`.
  - A planted bug in the `HopSlotMap` free-list merge is caught by
    `test_fuzz.mojo`.
- **Upstream bug.** The upstream `examples/doubly_linked_list.rs` panics when
  run (it asserts `len() == 4` after 5 pushes). The Mojo example asserts the
  real behavior. `rand_meld_heap` prints the same output as the Rust original.
- **Mojo quirk.** `Int(UInt32.MAX)` currently folds to `-1`, so the code uses
  the `_MAX_SLOTS` constant instead.

## License

Zlib, like the original crate. See `LICENSE` and `NOTICE`: this is an altered
version of Orson Peters' `slotmap`, not the original.
