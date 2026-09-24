# Porting `slotmap` (Rust) to Mojo

This guide covers porting the Rust crate at `../slotmap` (v1.1.1, about 9.5k lines,
roughly 45% of them docs and tests) to Mojo. The API notes come from the Mojo standard
library source at `../modular/mojo/stdlib/std/` (repo HEAD 2026-09-23, nightly
1.2-dev). The syntax rules come from `../skills/mojo-syntax/SKILL.md`.

> **Status: the port is done.** See `README.md` for the result. This guide is the
> original plan. The implementation departs from it in these places:
> - Value-first parameters: `SlotMap[V, K = DefaultKey]`.
> - Shared `_Slots` storage (§4's split storage, used by three maps).
> - `SparseSecondaryMap` built from `Dict` + dense lists, not `Dict[UInt32, slot]`.
> - `null()` / `is_null()` are default methods on the `Key` trait.
> - Iteration yields `Item` (`.key`, `.value()`) rather than tuples.

---

## 0. What you are porting

| Rust module | Lines (code only, approx.) | What it is | Port difficulty |
|---|---|---|---|
| `lib.rs` | ~200 | `KeyData {idx: u32, version: NonZeroU32}`, `Key` trait, `new_key_type!` macro, `DefaultKey` | Easy. The macro needs a redesign (§3). |
| `util.rs` | 30 | `is_older_version`, `Never`, `PanicOnDrop` | Trivial. Only `is_older_version` survives. |
| `dense.rs` | ~550 | `DenseSlotMap`: `Vec<Slot{version, idx_or_free}>` + `Vec<K>` + `Vec<V>` | **Easiest.** It has no uninitialized memory. |
| `basic.rs` | ~650 | `SlotMap`: `Vec<Slot{union{value, next_free}, version}>` | Medium. The union needs manual memory. |
| `secondary.rs` | ~700 | `SecondaryMap`: `Vec<enum{Occupied{value, version}, Vacant}>` | Medium. |
| `sparse_secondary.rs` | ~650 | `SparseSecondaryMap`: `HashMap<u32, {version, value}>` | Easy on top of `Dict`. |
| `hop.rs` | ~650 | `HopSlotMap`: free list of *blocks* for fast iteration | **Deprecated upstream** (removed in 2.0). Port last or skip. |

### Core invariants to preserve exactly

- **Version parity is the occupancy tag.** An odd version means occupied, an even version
  means vacant. Keys always carry an odd version (`version | 1`). Removing a value
  bumps the version (`+1`, wrapping), which invalidates every old key.
- **Slot 0 is a sentinel.** It is never occupied, and the free-list head starts at 1.
  Keep it even in `SlotMap` and `DenseSlotMap`, so keys stay compatible across map
  kinds and with the Rust layout.
- **The null key** is `idx = UInt32.MAX, version = 1`. It is never valid in any map.
- **The free list**: `free_head` holds a slot index. A vacant slot stores the next free
  index. `free_head == len(slots)` means "push a new slot".
- **Detached slots** have `next_free == UInt32.MAX` and an even version. They sit
  outside the free list until `reattach`.
- **`is_older_version(a, b)`** is `(a - b) >= (1 << 31)` with wrapping `UInt32`
  subtraction. Secondary maps use it so they never overwrite a newer value with an
  older key.
- **Capacity limit.** `len(slots)` must stay below `UInt32.MAX`. When it is reached,
  abort with "SlotMap is full".

---

## 1. Project setup (in this folder)

`pixi` is at `~/.pixi/bin/pixi`. There is no `mojo` yet. Use the **nightly** channel so
the APIs match `../modular` HEAD.

```bash
cd port
pixi init . -c https://conda.modular.com/max-nightly/ -c conda-forge
pixi add mojo
pixi run mojo --version
```

Target layout:

```text
port/
├── pixi.toml
├── slotmap/                  # the package (a dir with __init__.mojo)
│   ├── __init__.mojo         # re-exports: from .key import ...; from .basic import SlotMap ...
│   ├── key.mojo              # KeyData, Key trait, DefaultKey, TypedKey
│   ├── _util.mojo            # is_older_version
│   ├── dense.mojo
│   ├── basic.mojo
│   ├── secondary.mojo
│   ├── sparse_secondary.mojo
│   └── hop.mojo              # optional, last
├── test/
│   ├── test_key.mojo
│   ├── test_dense.mojo
│   ├── test_basic.mojo       # includes the drop-counting + randomized differential tests
│   ├── test_secondary.mojo
│   └── test_sparse_secondary.mojo
└── examples/
    ├── doubly_linked_list.mojo
    └── rand_meld_heap.mojo
```

Run with `pixi run mojo run -I . test/test_basic.mojo`. `mojo test` no longer exists;
each test file has a `TestSuite` main. To build a precompiled package, use
`pixi run mojo precompile slotmap -o slotmap.mojoc`. That command replaces the old
`mojo package`.

---

## 2. Rust → Mojo translation table (for this crate)

| Rust in slotmap | Mojo |
|---|---|
| `u32`, `u64`, `usize` | `UInt32`, `UInt64`, `Int`. Conversions are explicit: `Int(x)`, `UInt32(i)`. |
| `x.wrapping_add(1)`, `wrapping_sub` | Plain `x + 1` / `x - 1`. Unsigned `SIMD` arithmetic wraps. |
| `NonZeroU32` | Plain `UInt32` plus the invariant "version is odd". There is no public `NonZero`. For `Optional[Key]` to be key-sized you would need the private `UnsafeSingleNicheable` trait; skip that. |
| `Vec<T>` | `List[T]` (`std/collections/list.mojo`): `append`, `reserve`, `capacity()`, `pop()`, `swap_elements`, `unsafe_get(i)`, `unsafe_ptr()` |
| `union { ManuallyDrop<T>, u32 }` | No unions. See §4 for the storage design. `MaybeUninit[T]` (`std/memory/maybe_uninit.mojo`) exists but is only generically Movable/Deinitable for trivial T. |
| `enum Slot { Occupied{..}, Vacant }` | Version 0 means vacant, plus the same raw storage as `SlotMap` (§6). `Optional[V]` works for a first version. |
| `HashMap<u32, Slot<V>, S>` | `Dict[UInt32, _SparseSlot[V], H]`. The hasher parameter `H: Hasher` replaces `BuildHasher`. |
| `Option<&V>` / `Option<&mut V>` | `OptionalPointer[V, origin_of(self)]`, or `get(key) -> Optional[V] where Copyable`, plus a `ref`-returning `__getitem__` |
| `Index` / `IndexMut` + panic | `def __getitem__(ref self, key: K) -> ref[...] Self.V` that aborts (Rust panics), or raises a typed `InvalidKeyError` like `Dict` does (pick one and be consistent) |
| `impl Drop` | `def __deinit__(deinit self)` |
| `Clone` / `clone_from` | `Copyable where conforms_to(V, Copyable)` + `__init__(out self, *, copy: Self)`. Drop `clone_from`. |
| `Debug` | `Writable` (`write_to`). Keys print as `"{idx}v{version}"` or `"null"`. |
| `Hash`, `Eq`, `Ord` on keys | `Hashable`, `Equatable`; add `Comparable` if you want ordering (compare `as_ffi()`) |
| `FnOnce(K) -> V` closures | `f: def(Self.K) -> Self.V` (unified closure). For the `try_` variant, use `def(Self.K) raises -> Self.V` and mark the method `raises`. |
| `FnMut(K, &mut V) -> bool` (`retain`) | A closure taking `(K, mut V)` returning `Bool`. **Verify the exact closure-type spelling for a `mut` arg with the compiler.** The fallback is to pass `Pointer[V, ...]`. |
| `Iterator`, `ExactSizeIterator`, `FusedIterator` | `Iterator` with `__next__(mut self) raises StopIteration -> Element` and `bounds()` returning `(n, Optional(n))` |
| `[K; N]` const generics (`get_disjoint_mut`) | `get_disjoint_mut[N: Int](mut self, keys: Array[K, N]) -> Optional[Array[Pointer[V, ...], N]]` |
| `panic!` | `abort("...")` from `std.os` |
| `debug_assert!` | `assert cond, "msg"` (active with `-D ASSERT=all`), or `debug_assert[...]` |
| `unsafe fn get_unchecked` | `unsafe_get` naming, following stdlib convention |
| `TryReserveError` / `try_reserve` | Drop it. Mojo has no fallible allocation API. |
| `shrink_to_fit` / `shrink_to` | Drop them for v1. `List` has no capacity-shrink API, so you would need a manual realloc. |
| `PhantomData<fn(K) -> K>` | Not needed. `K` is simply a struct parameter. |
| `serde` feature | Drop it for v1. Keep `as_ffi` / `from_ffi`. If you add serialization later, port the rules from `basic.rs` `mod serialize`: reject an odd slot 0, rebuild the free list, and force `version | 1` on keys. |
| `no_std`, `unstable` features | Not applicable |

---

## 3. Keys (`key.mojo`), the replacement for `new_key_type!`

Mojo has no macros. Rust uses `new_key_type!` to give each map its own nominal key type.
In Mojo, a **phantom type parameter** does the same job. `TypedKey[PlayerTag]` and
`TypedKey[RocketTag]` are distinct types, so you cannot mix them up.

```mojo
from std.hashlib import Hasher

comptime _NULL_IDX = UInt32.MAX

@fieldwise_init
struct KeyData(Equatable, Hashable, ImplicitlyCopyable, Writable):
    var idx: UInt32
    var version: UInt32      # invariant: always odd

    @staticmethod
    def new(idx: UInt32, version: UInt32) -> Self:
        return Self(idx, version | 1)

    @staticmethod
    def null() -> Self:
        return Self(_NULL_IDX, 1)

    def is_null(self) -> Bool:
        return self.idx == _NULL_IDX

    def as_ffi(self) -> UInt64:
        return (UInt64(self.version) << 32) | UInt64(self.idx)

    @staticmethod
    def from_ffi(value: UInt64) -> Self:
        return Self.new(UInt32(value & 0xFFFF_FFFF), UInt32(value >> 32))

    def __hash__(self, mut hasher: Some[Hasher]):
        self.as_ffi().__hash__(hasher)   # Rust hashes as one u64 too

    def write_to(self, mut writer: Some[Writer]):
        if self.is_null():
            writer.write("null")
        else:
            writer.write(self.idx, "v", self.version)


trait Key(Equatable, Hashable, ImplicitlyCopyable, Writable, Defaultable):
    def __init__(out self, *, data: KeyData): ...
    def data(self) -> KeyData: ...
    # Rust's default methods null()/is_null() become free helpers or
    # trait default impls if your compiler version supports them.


struct TypedKey[Tag: AnyType](Key):
    var _data: KeyData
    def __init__(out self):                   self._data = KeyData.null()
    def __init__(out self, *, data: KeyData): self._data = data
    def data(self) -> KeyData:                return self._data
    # __eq__/__hash__/write_to: delegate to _data

struct _DefaultTag: pass
comptime DefaultKey = TypedKey[_DefaultTag]
```

Usage looks like `struct PlayerTag: pass`, then `comptime PlayerKey = TypedKey[PlayerTag]`,
then `var sm = SlotMap[PlayerKey, Player]()`.

The Rust `Key` trait is `unsafe` because the map's unsafe code trusts `data()`. Keep
that contract in a doc comment: `data()` must return exactly what was passed in.

`util.rs` reduces to a single function:

```mojo
def is_older_version(a: UInt32, b: UInt32) -> Bool:
    return (a - b) >= (UInt32(1) << 31)
```

Port its test (`lib.rs::check_is_older_version`) verbatim.

---

## 4. The one real design decision: slot storage

Rust `SlotMap` stores `union SlotUnion { value: ManuallyDrop<T>, next_free: u32 }` next to
`version`. Mojo has no unions, and `List[T]` requires every element to be a fully
initialized, Movable value.

**Recommended approach: split the slots into two arrays (struct-of-arrays).** This is the
same "tag array plus raw storage" model that `Dict`'s SwissTable uses
(`std/collections/_swisstable.mojo`).

```mojo
@fieldwise_init
struct _Meta(ImplicitlyCopyable):
    var version: UInt32     # odd = occupied
    var next_free: UInt32   # meaningful only when vacant

struct SlotMap[K: Key, V: Movable](Sized, ...):
    var _meta: List[_Meta]                                # trivially copyable, so List handles it
    var _values: Pointer[Self.V, MutUntrackedOrigin]      # capacity == _meta.capacity()
    var _values_cap: Int
    var _free_head: UInt32
    var _num_elems: UInt32
```

- `_values[i]` is initialized **only if** `_meta[i].version` is odd. Nothing else
  (`Optional`, `Variant`) tracks that; the parity alone does.
- When `_meta` has to grow, allocate a new value buffer with
  `alloc(Layout[V](count=new_cap))`. Move only the occupied values with
  `p.unsafe_take_pointee()` and `q.unsafe_write(v^)`, then `dealloc` the old buffer.
  Copy the growth logic from `List._realloc` (`list.mojo`).
- In `__deinit__`, walk `_meta`. Call `unsafe_deinit_pointee()` on each odd slot, then
  `dealloc`. This is the same as SwissTable's `_delete_occupied_entries`.
- In the copy constructor (`where conforms_to(V, Copyable)`), copy `_meta`, allocate
  new storage, and `unsafe_write(copy=...)` each occupied value.
- Memory per slot is `8 + sizeof(V)`, versus Rust's `4 + max(sizeof V, 4)`. That is
  fine for v1, and iteration over metadata is more cache-friendly.

**Stepping stone if you want something running on day 1:** store
`_values: List[Optional[V]]` in place of the raw buffer. It is safe and simple, but
spends a tag byte plus padding per slot. Write the tests against it, then swap the
storage.

**Not recommended:** one `struct _Slot { version; next_free; value: MaybeUninit[V] }`
inside a `List`. `MaybeUninit` is not Movable/Deinitable for non-trivial `V`, so
you would need hand-written move/copy/deinit on `_Slot` that read `version`. That is
possible (see `_NichedOptionalStorage` in `std/utils/variant.mojo`), but it is more
fragile than the split-array approach.

---

## 5. `SlotMap` (`basic.mojo`): method-by-method

Port the logic from `basic.rs` exactly. The core methods, in sketch form:

```mojo
def __init__(out self, *, capacity: Int = 0):
    self._meta = List[_Meta](capacity=capacity + 1)
    self._meta.append(_Meta(version=0, next_free=0))   # sentinel slot 0
    # allocate _values with capacity + 1 ...
    self._free_head = 1
    self._num_elems = 0

def __contains__(self, key: Self.K) -> Bool:
    var kd = key.data()
    return Int(kd.idx) < len(self._meta) and self._meta[Int(kd.idx)].version == kd.version

def insert(mut self, var value: Self.V) -> Self.K:
    var head = Int(self._free_head)
    if head < len(self._meta):
        var ver = self._meta[head].version | 1
        self._free_head = self._meta[head].next_free
        self._values.unsafe_offset(head).unsafe_write(value^)
        self._meta[head].version = ver
        self._num_elems += 1
        return Self.K(data=KeyData.new(UInt32(head), ver))
    if len(self._meta) >= Int(UInt32.MAX):
        abort("SlotMap is full")
    # grow storage if needed, push _Meta(version=1, next_free=0), write value
    # self._free_head = UInt32(len(self._meta)); self._num_elems += 1
    ...

def _remove_from_slot(mut self, idx: Int) -> Self.V:   # caller guarantees occupied
    var v = self._values.unsafe_offset(idx).unsafe_take_pointee()
    self._meta[idx].next_free = self._free_head
    self._free_head = UInt32(idx)
    self._meta[idx].version += 1                      # wraps
    self._num_elems -= 1
    return v^

def remove(mut self, key: Self.K) -> Optional[Self.V]:
    if key not in self: return None
    return self._remove_from_slot(Int(key.data().idx))
```

Order matters in `insert_with_key` and `try_insert_with_key`. Call `f(key)` **before**
changing the free list or version. If `f` raises, the map must be unchanged (the Rust
code comments on this).

The rest of the API, with Mojo notes:

| Rust | Mojo notes |
|---|---|
| `new`, `with_capacity`, `with_key`, `with_capacity_and_key` | One `__init__(out self, *, capacity: Int = 0)`. The key type comes from the struct parameter, so there is no `with_key`. |
| `len`, `is_empty`, `capacity`, `reserve` | `__len__`, `__bool__`, `capacity()`, `reserve(additional)`. Keep the `-1` sentinel math. |
| `contains_key` | `__contains__` (`key in sm`) |
| `insert`, `insert_with_key`, `try_insert_with_key` | As above |
| `remove`, `detach`, `reattach` | `reattach` aborts with "key is not detached" when the slot's version is not `key.version + 1` or its `next_free` is not `UInt32.MAX` |
| `retain(f)` | Loop `i in range(1, len(_meta))` and call `_remove_from_slot(i)` when `f` returns False. Removal never shrinks the slot array. |
| `clear`, `drain` | For v1, implement `clear()` directly and have `drain()` return `List[Tuple[K, V]]`. A lazy `Drain` iterator must finish draining in its `__deinit__`, like the Rust `Drop`. |
| `get`, `get_mut` | `get_ptr(ref self, key) -> OptionalPointer[V, origin_of(self)]`, plus `get(key) -> Optional[V] where Copyable` |
| `get_unchecked(_mut)` | `unsafe_get(ref self, key) -> ref[...] V` with `assert key in self` |
| `Index`/`IndexMut` | `__getitem__(ref self, key) -> ref[...] V`. It aborts on an invalid key; that also covers `sm[k] = v`. To return a ref into the raw buffer with the right origin, copy `Dict._find_ref`'s `_get_ref_with_unsafe_interior_origin` trick. |
| `get_disjoint_mut[N]` | Same trick as Rust: XOR each valid slot's version with 1 so a duplicate key looks invalid, collect pointers, then XOR back. It returns pointers because Mojo can't return N `mut` refs. |
| `iter`, `iter_mut`, `keys`, `values`, `values_mut` | See §8 |
| `IntoIterator` for owned map | `IterableOwned`, the pattern of `_ListIterOwned` (`list.mojo:108`). Its `__deinit__` must destroy the values it has not yielded yet. |
| `Clone` | Conditional `Copyable` (§4) |
| `Default` | `Defaultable` |

---

## 6. `DenseSlotMap` (`dense.mojo`): port it first

It uses **no uninitialized memory**. The fields are three plain lists:

```mojo
struct DenseSlotMap[K: Key, V: Movable]:
    var _keys: List[Self.K]
    var _values: List[Self.V]
    var _slots: List[_Meta]        # _Meta.next_free doubles as "idx_or_free"
    var _free_head: UInt32
```

- `swap_remove(i)` becomes `swap_elements(i, len - 1)` followed by `pop()`, applied to
  both `_keys` and `_values`. After that, if an element moved into `i`, update its
  slot: `_slots[_keys[i].data().idx].idx_or_free = i`.
- `drain` just pops from the end (`dense.rs:537`).
- `keys_as_slice`, `values_as_slice` and `as_slices` become `Span(self._keys)` and
  `Span(self._values)`.
- Iteration zips the two lists, so it needs no hole skipping.

This map lets you settle the key trait, iterators, tests and closures before you touch
raw memory.

---

## 7. Secondary maps

### `SecondaryMap` (`secondary.mojo`)

- Rust uses `enum Slot { Occupied{value, version: NonZeroU32}, Vacant }`. In Mojo,
  version `0` means vacant, so reuse the §4 split storage (or `List[Optional[V]]` in
  step 1).
- `insert(key, value)`:
  1. Return `None` for a null key.
  2. Grow the slot array to `key.idx + 1` with vacant slots.
  3. If the versions are equal, replace the value and return the old one.
  4. If the slot is occupied and `is_older_version(key.version, slot.version)`, return
     `None` and do not overwrite.
  5. Otherwise store the value with the key's version. Increment `num_elems` only if
     the slot was vacant.
- In `get_disjoint_mut`, the temporary marker is version **2**, not XOR 1, because
  vacant means 0 here.
- `Entry` API: a Rust `Entry<'a>` is an enum holding `&'a mut map`. In Mojo, either
  - skip it and provide `get_or_insert(key, var default) -> ref V`,
    `get_or_insert_with(key, f)` and `and_modify`-style helpers, or
  - build `struct Entry[origin]` holding `Pointer[SecondaryMap, origin]`, the
    `KeyData` and an `occupied: Bool`.

  Start with the first option.
- `PartialEq` becomes `Equatable where conforms_to(V, Equatable)`. `FromIterator` and
  `Extend` become `__init__(out self, *, items: ...)` and `extend(...)`.

### `SparseSecondaryMap` (`sparse_secondary.mojo`)

```mojo
@fieldwise_init
struct _SparseSlot[V: Movable](Movable):
    var version: UInt32
    var value: Self.V

struct SparseSecondaryMap[K: Key, V: Movable, H: Hasher = default_hasher]:
    var _slots: Dict[UInt32, _SparseSlot[Self.V], Self.H]
```

This is almost a straight transliteration, using `Dict.insert` / `pop` / `_find_ref`-style
access. The one change is `retain`: `Dict` has no `retain`, so collect the indices to
remove first, then pop them.

---

## 8. Iterators

Mojo iterators raise `StopIteration` rather than returning `Option`.

```mojo
struct _Iter[mut: Bool, //, K: Key, V: Movable, origin: Origin[mut=mut]](Iterator, ...):
    comptime Element = Tuple[Self.K, Pointer[Self.V, Self.origin]]   # owned Element
    var _meta: Pointer[_Meta, Self.origin]
    var _values: Pointer[Self.V, Self.origin]
    var _len: Int
    var _cur: Int
    var _num_left: Int
    def __next__(mut self) raises StopIteration -> Self.Element:
        while self._cur < self._len:
            var i = self._cur
            self._cur += 1
            var ver = self._meta[unsafe_offset=i].version
            if ver & 1 == 1:
                self._num_left -= 1
                return (Self.K(data=KeyData.new(UInt32(i), ver)), self._values.unsafe_offset(i))
        raise StopIteration()
    def bounds(self) -> Tuple[Int, Optional[Int]]:
        return (self._num_left, Optional(self._num_left))
```

- Start at `_cur = 1` to skip the sentinel.
- The container builds the iterator by casting its untracked pointers to the caller's
  origin, like `List.__iter__` (`list.mojo:746`):
  `self._values.unsafe_mut_cast[origin_of(self).mut]().unsafe_origin_cast[origin_of(self)]()`.
  One struct then serves both `iter()` and `iter_mut()`. The origin's mutability decides
  which one you get.
- There are two ways to yield entries:
  - `Dict` yields `ref` to an internal entry struct with `.key` / `.value`, because
    Mojo tuples can't be destructured in `for`.
  - Yielding a small `@fieldwise_init struct Item(key, value_ptr)` gives the nicest call
    site: `for it in sm.items(): print(it.key, it.value[])`.
- `keys()` and `values()` wrap `_Iter`, like `_DictKeyIter` and `_DictValueIter`.
- `HopSlotMap` iteration skips a vacant block by jumping to `free.other_end + 1`
  (`hop.rs:751`).

---

## 9. `HopSlotMap` (optional)

Upstream deprecated it in 1.1.0, so do it last or skip it. If you port it, the vacant
payload is `FreeListEntry{next, prev, other_end}` (12 bytes). Store it in the metadata
array: `_HopMeta{version, next, prev, other_end}`. The four cases in
`remove_from_slot` (`hop.rs`, `match (left_vacant, right_vacant)`) and the two cases in
`insert` translate line for line. The sentinel at index 0 is the head of the free list
and is required here.

---

## 10. Tests: what to port and how

Unit tests become `def test_*() raises` in `test/`, with a main that calls
`TestSuite.discover_tests[__functions_in_module()]().run()`.

| Rust test | Mojo port |
|---|---|
| `check_is_older_version` | Verbatim |
| `check_drops` (`CountDrop` with `RefCell<usize>`) | A `DelCounter`-style struct holding a `Pointer[Int, ...]` to a counter, incremented in `__deinit__`. Copy it from `../modular/mojo/stdlib/test/test_utils/types.mojo`. Assert 500 drops after removing the even keys, 1000 after the original is destroyed, and 1750 at the end. **This is the key test for the raw-memory storage in §4.** |
| `disjoint` | Verbatim with `get_disjoint_mut[2]` / `[3]` |
| `qc_slotmap_equiv_hashmap` (quickcheck) | Randomized differential test against `Dict[UInt32, UInt32]`. Use `std.random` with a fixed seed and loop over many seeds. Operations: insert / remove (10% `drain`) / access / copy. Do the same for `DenseSlotMap`, `SecondaryMap` and `SparseSecondaryMap` (each Rust file has its own quickcheck). |
| `fuzz/fuzz_targets/target.rs` | The same randomized op stream (Reserve / Insert / InsertWithKey / Remove / Retain / Clear / Drain(n) / IterMut(n) / GetDisjointMut) run under `-D ASSERT=all`. It exercises partial drain and partial into-iteration, which are the risky `__deinit__` paths. |
| `iters_cloneable` (`NoClone` values) | Instantiate each map with `MoveOnly[Int]` from `test_utils`. That checks that `V: Movable` is enough and nothing silently requires `Copyable`. |
| serde tests | Skip |
| Doc examples (`///` blocks) | Turn the non-trivial ones into tests. The `lib.rs` crate example goes in `examples/`. |

---

## 11. Suggested order of work

1. **Setup.** Run `pixi init` (§1) and compile a hello-world.
2. **`key.mojo` + `_util.mojo` + `test_key.mojo`.** Check that `TypedKey[A]` and
   `TypedKey[B]` really are distinct types. This fixes the `Key` trait shape that
   everything else depends on.
3. **`DenseSlotMap`** with full tests. Plain lists only, so it proves out closures,
   iterators and the test harness.
4. **`SlotMap` using `List[Optional[V]]`** storage, plus the differential test and the
   drop test.
5. **`SlotMap` using split raw storage (§4).** Keep the same tests. Run them with
   `-D ASSERT=all`, and add the fuzz-style test.
6. **`SecondaryMap`** (same storage), then **`SparseSecondaryMap`** (`Dict`).
7. **Examples**: `doubly_linked_list`, `rand_meld_heap`.
8. Optional: `HopSlotMap`, a lazy `Drain` iterator, the `Entry` API and serialization.

## 12. Known gaps and risks

- **Mojo is changing fast.** Check each file against `../skills/mojo-syntax/SKILL.md`,
  and compile often.
- **Closure types with `mut` arguments** (`retain`) and **returning refs into raw
  buffers with the correct origin** are the two places you are most likely to fight
  the compiler. `Dict._find_ref` and `List.__iter__` are the reference
  implementations to copy.
- **No `NonZero` niche**, so `Optional[DefaultKey]` is 12 bytes instead of 8. Use the
  null key where Rust code would use `Option<Key>`, as the slotmap docs recommend.
- **No fallible allocation**, so there is no `try_reserve`.
- **Borrowed iteration of `List` requires `Copyable` elements** (MSTDL-2390). Your own
  iterators over raw pointers avoid this; don't build them on `List.__iter__`.
