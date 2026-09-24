"""Contains the sparse secondary map implementation."""

from std.bit import count_trailing_zeros
from std.builtin.rebind import downcast
from std.hashlib import Hasher, hash
from std.memory import (
    Allocation,
    Layout,
    dealloc,
    pack_bits,
    unsafe_memcpy,
    unsafe_memset,
)
from std.os import abort
from std.sys import size_of
from std.traits import IsTriviallyCopyable, IsTriviallyDeinitable

from .key import DefaultKey, Key, KeyData
from ._common import Item, Value, _DropValue
from ._util import is_older_version

# Control bytes, as in Swiss tables: an occupied slot stores the top 7 bits of
# its hash (0x00-0x7F), so a probe compares 16 fingerprints at once and only
# touches entries whose fingerprint matches.
comptime _CTRL_EMPTY: UInt8 = 0xFF
comptime _CTRL_DELETED: UInt8 = 0x80
comptime _GROUP = 16
comptime _MIN_CAPACITY = 16

comptime _Group = SIMD[.uint8, _GROUP]


struct IdxHasher(Defaultable, Hasher):
    """The default hasher for `SparseSecondaryMap`: a multiplicative hash
    that stays in integer registers.

    Keys are 32-bit slot indices, which need little mixing. The stdlib
    `AHasher` is a fine general hasher, but its 128-bit folded multiply goes
    through vector registers, and that latency lands on the critical path
    of every probe.
    """

    var _state: UInt64

    def __init__(out self):
        self._state = 0

    @inline(.always)
    def _mix(mut self, bits: UInt64):
        var h = (self._state ^ bits) * 0x9E3779B97F4A7C15
        self._state = h ^ (h >> 32)

    def _update_with_simd(mut self, new_data: SIMD[_, _]):
        comptime rounds = max(1, size_of[new_data.dtype]() // 8)
        comptime if rounds == 1:
            var u64 = new_data.to_bits[.uint64]()
            comptime for i in range(u64.length):
                self._mix(u64[i])
        else:
            comptime for i in range(new_data.length):
                var v = new_data[i]
                comptime assert size_of[v.dtype]() > 8 and v.dtype.is_integral()
                comptime for r in range(rounds):
                    self._mix(
                        (v >> Scalar[new_data.dtype](r * 64)).cast[.uint64]()
                    )

    def update(mut self, data: ImmSpan[Byte, _]):
        for b in data:
            self._mix(UInt64(b))

    @inline(.always)
    def finish(var self) -> UInt64:
        return self._state


struct _SparseEntry[V: Movable](not Deinitable):
    """One hash table entry: the slot index it holds data for, that slot's
    version, and the value. All three are initialized iff the entry's
    control byte marks it occupied, so entries are only handled through
    pointers, never as whole values."""

    var idx: UInt32
    var version: UInt32
    var value: Self.V


@inline(.always)
def _full_bits(group: _Group) -> UInt16:
    """A bitmask of the occupied slots in a group of control bytes."""
    return pack_bits(group.lt(_Group(_CTRL_DELETED)))


@inline(.always)
def _next_occupied(ctrl: Pointer[UInt8, _], cap: Int, start: Int) -> Int:
    """Returns the first occupied slot at or after `start`, or `cap`."""
    var base = start & ~(_GROUP - 1)
    var mask = UInt16(0)
    if base < cap:
        mask = _full_bits(ctrl.unsafe_offset(base).unsafe_load[width=_GROUP]())
        mask &= UInt16(0xFFFF) << UInt16(start - base)
    while mask == 0:
        base += _GROUP
        if base >= cap:
            return cap
        mask = _full_bits(ctrl.unsafe_offset(base).unsafe_load[width=_GROUP]())
    return base + Int(count_trailing_zeros(mask))


@explicit_destroy(
    "Use `deinit_with()` to destroy a map holding non-`Deinitable` values"
)
struct SparseSecondaryMap[
    V: Value, K: Key = DefaultKey, H: Hasher = IdxHasher
](
    Copyable where conforms_to(V, Copyable),
    Defaultable,
    Deinitable where conforms_to(V, Deinitable),
    Equatable where conforms_to(V, Equatable),
    Iterable,
    IterableOwned where conforms_to(V, Deinitable),
    Movable,
    Sized,
    Writable where conforms_to(V, Writable),
):
    """Sparse secondary map, associates data with previously stored elements
    in a slot map.

    Like `SecondaryMap`, but backed by a hash table, so memory use is
    proportional to the number of stored elements rather than the number of
    slots in the slot map. Use it to store data for a small part of a slot
    map. Outdated keys are handled like in `SecondaryMap`.

    The table is a Swiss table (control bytes probed 16 at a time, 7/8 load
    factor) over entries of `(slot index, version, value)`, keyed by slot
    index: the same design as Rust's `HashMap<u32, (u32, V)>`. `H` picks
    the hasher; the default `IdxHasher` is a cheap multiplicative hash
    suited to slot indices.
    """

    comptime Entry = _SparseEntry[Self.V]
    comptime IteratorType[
        iterable_mut: Bool, //, iterable_origin: Origin[mut=iterable_mut]
    ]: Iterator = _SparseIter[Self.K, Self.V, iterable_origin]
    comptime IteratorOwnedType: Iterator where conforms_to(
        Self.V, Deinitable
    ) = _SparseIntoIter[Self.V, Self.K, Self.H]

    var _ctrl: Allocation[UInt8]
    """`_cap + _GROUP` control bytes; the last 16 mirror the first 16 so a
    group load never runs past the end while probing wraps around."""
    var _entries: Allocation[Self.Entry]
    var _cap: Int
    """Number of slots in the table: zero or a power of two >= 16."""
    var _len: Int
    var _growth_left: Int
    """Inserts into EMPTY slots allowed before rehashing. Tombstones keep
    their share until the next rehash, which keeps probes terminating."""

    # ===------------------------------------------------------------------===#
    # Life cycle
    # ===------------------------------------------------------------------===#

    def __init__(out self):
        """Constructs a new, empty sparse secondary map."""
        self._ctrl = alloc(Layout[UInt8](count=0))
        self._entries = alloc(Layout[Self.Entry](count=0))
        self._cap = 0
        self._len = 0
        self._growth_left = 0

    def __init__(out self, *, capacity: Int):
        """Creates an empty map with room for `capacity` elements."""
        self = Self()
        self.reserve(capacity)

    def __init__(out self, *, copy: Self) where conforms_to(Self.V, Copyable):
        self._ctrl = alloc(Layout[UInt8](count=copy._ctrl_len()))
        self._entries = alloc(Layout[Self.Entry](count=copy._cap))
        self._cap = copy._cap
        self._len = copy._len
        self._growth_left = copy._growth_left
        unsafe_memcpy(
            dest=self._ctrl.unsafe_ptr(),
            src=copy._ctrl.unsafe_ptr(),
            count=copy._ctrl_len(),
        )
        comptime if IsTriviallyCopyable[Self.V]:
            unsafe_memcpy(
                dest=self._entries.unsafe_ptr(),
                src=copy._entries.unsafe_ptr(),
                count=self._cap,
            )
        else:
            var i = copy._next(0)
            while i < copy._cap:
                ref src = copy._entry(i)
                ref dst = self._entry(i)
                dst.idx = src.idx
                dst.version = src.version
                Pointer(to=dst.value).unsafe_write(copy=src.value)
                i = copy._next(i + 1)

    def __deinit__(deinit self) where conforms_to(Self.V, Deinitable):
        comptime if not IsTriviallyDeinitable[Self.V]:
            var i = self._next(0)
            while i < self._cap:
                self._value_ptr(i).unsafe_deinit_pointee()
                i = self._next(i + 1)
        dealloc(self._ctrl^)
        dealloc(self._entries^)

    def deinit_with(deinit self, deinit_func: Some[def(var Self.V)]):
        """Destroys the map, passing each value to `deinit_func`. Use it for
        values that are not `Deinitable`."""
        var i = self._next(0)
        while i < self._cap:
            deinit_func(self._value_ptr(i).unsafe_take_pointee())
            i = self._next(i + 1)
        dealloc(self._ctrl^)
        dealloc(self._entries^)

    # ===------------------------------------------------------------------===#
    # Table internals
    # ===------------------------------------------------------------------===#

    @inline(.always)
    def _ctrl_len(self) -> Int:
        return self._cap + _GROUP if self._cap > 0 else 0

    @inline(.always)
    def _ctrl_ptr(self) -> Pointer[UInt8, MutUntrackedOrigin]:
        return (
            self._ctrl.unsafe_ptr()
            .unsafe_mut_cast[True]()
            .unsafe_origin_cast[MutUntrackedOrigin]()
        )

    @inline(.always)
    def _entries_ptr(ref self) -> Pointer[Self.Entry, origin_of(self)]:
        return (
            self._entries.unsafe_ptr()
            .unsafe_mut_cast[origin_of(self).mut]()
            .unsafe_origin_cast[origin_of(self)]()
        )

    @inline(.always)
    def _entry(ref self, pos: Int) -> ref[origin_of(self)] Self.Entry:
        return self._entries_ptr()[unsafe_offset=pos]

    @inline(.always)
    def _value_ptr(self, pos: Int) -> Pointer[Self.V, MutUntrackedOrigin]:
        return (
            Pointer(to=self._entries.unsafe_ptr()[unsafe_offset=pos].value)
            .unsafe_mut_cast[True]()
            .unsafe_origin_cast[MutUntrackedOrigin]()
        )

    @inline(.always)
    def _group(self, pos: Int) -> _Group:
        return self._ctrl_ptr().unsafe_offset(pos).unsafe_load[width=_GROUP]()

    @inline(.always)
    def _set_ctrl(mut self, pos: Int, value: UInt8):
        var ctrl = self._ctrl_ptr()
        ctrl[unsafe_offset=pos] = value
        if pos < _GROUP:
            ctrl[unsafe_offset=self._cap + pos] = value

    @inline(.always)
    def _next(self, start: Int) -> Int:
        """The first occupied slot at or after `start`, or `_cap`."""
        return _next_occupied(self._ctrl_ptr(), self._cap, start)

    def _probe(self, idx: UInt32) -> Tuple[Bool, Int]:
        """Returns `(True, pos)` for the entry holding `idx`, or `(False,
        pos)` with the first free (empty or deleted) position on its probe
        sequence. The table must not be empty."""
        var h = hash[HasherType=Self.H](idx)
        var h2 = _Group(UInt8(h >> 57))
        var mask = self._cap - 1
        var pos = Int(h) & mask
        var first_deleted = -1
        while True:
            var group = self._group(pos)
            var matches = pack_bits(group.eq(h2))
            while matches != 0:
                var slot = (pos + Int(count_trailing_zeros(matches))) & mask
                if self._entry(slot).idx == idx:
                    return (True, slot)
                matches &= matches - 1
            var special = pack_bits(group.ge(_Group(_CTRL_DELETED)))
            var empty = pack_bits(group.eq(_Group(_CTRL_EMPTY)))
            if first_deleted < 0:
                var deleted = special & ~empty
                if deleted != 0:
                    first_deleted = (
                        pos + Int(count_trailing_zeros(deleted))
                    ) & mask
            if empty != 0:
                if first_deleted >= 0:
                    return (False, first_deleted)
                return (False, (pos + Int(count_trailing_zeros(empty))) & mask)
            pos = (pos + _GROUP) & mask

    @inline(.always)
    def _find(self, idx: UInt32) -> Int:
        """The position of the entry holding `idx`, any version, or -1."""
        if self._cap == 0:
            return -1
        var found, pos = self._probe(idx)
        return pos if found else -1

    @inline(.always)
    def _find_key(self, key: Self.K) -> Int:
        """The position of the entry holding exactly `key`, or -1."""
        var kd = key.data()
        var pos = self._find(kd.idx)
        if pos >= 0 and self._entry(pos).version == kd.version:
            return pos
        return -1

    def _rehash(mut self, new_cap: Int):
        """Moves every entry into a fresh table of `new_cap` slots, dropping
        tombstones."""
        var new_ctrl = alloc(Layout[UInt8](count=new_cap + _GROUP))
        unsafe_memset(new_ctrl.unsafe_ptr(), _CTRL_EMPTY, new_cap + _GROUP)
        var new_entries = alloc(Layout[Self.Entry](count=new_cap))
        var old_cap = self._cap
        swap(self._ctrl, new_ctrl)  # `new_ctrl` and `new_entries` now
        swap(self._entries, new_entries)  # hold the old table.
        self._cap = new_cap
        self._growth_left = new_cap * 7 // 8 - self._len
        var old_ctrl = new_ctrl.unsafe_ptr()
        var old_entries = new_entries.unsafe_ptr()
        var mask = new_cap - 1
        # Walk the old control bytes a group at a time.
        for base in range(0, old_cap, _GROUP):
            var full = _full_bits(
                old_ctrl.unsafe_offset(base).unsafe_load[width=_GROUP]()
            )
            while full != 0:
                var i = base + Int(count_trailing_zeros(full))
                full &= full - 1
                ref src = old_entries[unsafe_offset=i]
                var h = hash[HasherType=Self.H](src.idx)
                var pos = Int(h) & mask
                while True:
                    var empty = pack_bits(
                        self._group(pos).eq(_Group(_CTRL_EMPTY))
                    )
                    if empty != 0:
                        pos = (pos + Int(count_trailing_zeros(empty))) & mask
                        break
                    pos = (pos + _GROUP) & mask
                self._set_ctrl(pos, UInt8(h >> 57))
                ref dst = self._entry(pos)
                dst.idx = src.idx
                dst.version = src.version
                Pointer(to=dst.value).unsafe_write(
                    Pointer(to=src.value).unsafe_take_pointee()
                )
        dealloc(new_ctrl^)
        dealloc(new_entries^)

    def _grow_for(mut self, num_elems: Int):
        """Rehashes so that `num_elems` elements fit under the 7/8 load
        factor with no tombstones."""
        var new_cap = max(self._cap, _MIN_CAPACITY)
        while num_elems * 8 > new_cap * 7:
            new_cap *= 2
        self._rehash(new_cap)

    def _insert_new(mut self, kd: KeyData, var value: Self.V, free_pos: Int):
        """Inserts a slot index that is not in the table. `free_pos` is the
        free position a probe for it returned, or -1 if none was done."""
        var pos = free_pos
        if self._growth_left == 0:
            # Double when nearly full; otherwise the table is mostly
            # tombstones, so rebuild it at the same size.
            if (self._len + 1) * 8 > self._cap * 7:
                self._grow_for(self._len + 1)
            else:
                self._rehash(max(self._cap, _MIN_CAPACITY))
            pos = -1
        if pos < 0:
            var _found, p = self._probe(kd.idx)
            pos = p
        if self._ctrl_ptr()[unsafe_offset=pos] == _CTRL_EMPTY:
            self._growth_left -= 1
        var h = hash[HasherType=Self.H](kd.idx)
        self._set_ctrl(pos, UInt8(h >> 57))
        ref e = self._entry(pos)
        e.idx = kd.idx
        e.version = kd.version
        self._value_ptr(pos).unsafe_write(value^)
        self._len += 1

    @inline(.always)
    def _remove_at(mut self, pos: Int) -> Self.V:
        """Takes the value at `pos` and leaves a tombstone."""
        self._set_ctrl(pos, _CTRL_DELETED)
        self._len -= 1
        return self._value_ptr(pos).unsafe_take_pointee()

    # ===------------------------------------------------------------------===#
    # Size and capacity
    # ===------------------------------------------------------------------===#

    def __len__(self) -> Int:
        return self._len

    def __bool__(self) -> Bool:
        return self._len != 0

    def is_empty(self) -> Bool:
        return self._len == 0

    def capacity(self) -> Int:
        """Returns how many elements fit without rehashing."""
        return self._cap * 7 // 8

    def reserve(mut self, additional: Int):
        """Reserves capacity for at least `additional` more elements."""
        if additional > self._growth_left:
            self._grow_for(self._len + additional)

    # ===------------------------------------------------------------------===#
    # Insertion and removal
    # ===------------------------------------------------------------------===#

    def __contains__(self, key: Self.K) -> Bool:
        return self._find_key(key) >= 0

    def contains_key(self, key: Self.K) -> Bool:
        return key in self

    def insert(
        mut self, key: Self.K, var value: Self.V
    ) -> Optional[Self.V] where conforms_to(Self.V, Deinitable):
        """Inserts a value at `key`. Returns the previous value if the key
        was present. If a newer key for the same slot is present, nothing is
        inserted. Null keys are ignored."""
        if key.is_null():
            return None
        var kd = key.data()
        var free_pos = -1
        if self._cap > 0:
            var found, pos = self._probe(kd.idx)
            if found:
                ref e = self._entry(pos)
                if e.version == kd.version:
                    swap(e.value, value)
                    return value^
                # Don't replace existing newer values.
                if is_older_version(kd.version, e.version):
                    return None
                e.version = kd.version
                swap(e.value, value)
                return None  # `value` holds the outdated value, dropped here.
            free_pos = pos
        self._insert_new(kd, value^, free_pos)
        return None

    def insert_returning(
        mut self, key: Self.K, var value: Self.V
    ) -> Optional[Self.V]:
        """Like `insert`, but never destroys a value, so it works for values
        that are not `Deinitable`.

        Returns whichever value did not end up in the map: the previous value
        for the slot (for this key or an outdated one), or `value` itself if
        the key is null or a newer key holds the slot. Check `key in map`
        afterwards to tell these apart.
        """
        if key.is_null():
            return value^
        var kd = key.data()
        var free_pos = -1
        if self._cap > 0:
            var found, pos = self._probe(kd.idx)
            if found:
                ref e = self._entry(pos)
                if e.version != kd.version and is_older_version(
                    kd.version, e.version
                ):
                    return value^  # A newer key holds the slot.
                e.version = kd.version
                swap(e.value, value)
                return value^
            free_pos = pos
        self._insert_new(kd, value^, free_pos)
        return None

    def remove(mut self, key: Self.K) -> Optional[Self.V]:
        """Removes a key, returning its value if it was present."""
        var pos = self._find_key(key)
        if pos < 0:
            return None
        return self._remove_at(pos)

    def retain(
        mut self, f: Some[def(Self.K, mut Self.V) -> Bool]
    ) where conforms_to(Self.V, Deinitable):
        """Keeps only the elements for which `f(key, value)` returns
        `True`."""
        var i = self._next(0)
        while i < self._cap:
            ref e = self._entry(i)
            var key = Self.K(data=KeyData(e.idx, e.version))
            if not f(key, e.value):
                _ = self._remove_at(i)
            i = self._next(i + 1)

    def clear(mut self) where conforms_to(Self.V, Deinitable):
        """Removes all elements. Keeps the table for reuse."""
        comptime if not IsTriviallyDeinitable[Self.V]:
            var i = self._next(0)
            while i < self._cap:
                self._value_ptr(i).unsafe_deinit_pointee()
                i = self._next(i + 1)
        unsafe_memset(self._ctrl_ptr(), _CTRL_EMPTY, self._ctrl_len())
        self._len = 0
        self._growth_left = self._cap * 7 // 8

    def drain[
        origin: MutOrigin, //
    ](ref[origin] self) -> _SparseDrain[
        downcast[Self.V, _DropValue], Self.K, Self.H, origin
    ] where conforms_to(Self.V, Deinitable):
        """Removes all elements, yielding `(key, value)` tuples. Elements not
        consumed are removed when the iterator is destroyed."""
        return {
            rebind[
                Pointer[
                    SparseSecondaryMap[
                        downcast[Self.V, _DropValue], Self.K, Self.H
                    ],
                    origin,
                ]
            ](Pointer(to=self)),
            0,
        }

    # ===------------------------------------------------------------------===#
    # Access
    # ===------------------------------------------------------------------===#

    def get(self, key: Self.K) -> Optional[Self.V] where conforms_to(
        Self.V, Copyable
    ):
        """Returns a copy of the value for `key`, if present."""
        var pos = self._find_key(key)
        if pos < 0:
            return None
        return self._entry(pos).value.copy()

    def get_ptr(
        ref self, key: Self.K
    ) -> OptionalPointer[Self.V, origin_of(self)]:
        """Returns a pointer to the value for `key`, or `None`."""
        var pos = self._find_key(key)
        if pos < 0:
            return None
        return Pointer(to=self._entry(pos).value).unsafe_origin_cast[
            origin_of(self)
        ]()

    @__unsafe_nested_origins_read_only
    def unsafe_get(
        ref self, key: Self.K
    ) -> ref[origin_of(self)._get_owned_interior["value"]] Self.V:
        """Returns a reference to the value for `key` without checking that
        the version matches."""
        assert key in self, "invalid SparseSecondaryMap key used"
        return Pointer(
            to=self._entry(self._find(key.data().idx)).value
        )._get_ref_with_unsafe_interior_origin["value", origin_of(self)]()

    @__unsafe_nested_origins_read_only
    def __getitem__(
        ref self, key: Self.K
    ) -> ref[origin_of(self)._get_owned_interior["value"]] Self.V:
        """Returns a reference to the value for `key`. Aborts if the key is
        not present."""
        var pos = self._find_key(key)
        if pos < 0:
            abort("invalid SparseSecondaryMap key used")
        return Pointer(
            to=self._entry(pos).value
        )._get_ref_with_unsafe_interior_origin["value", origin_of(self)]()

    def get_disjoint_mut[
        origin: MutOrigin, //, N: Int
    ](ref[origin] self, keys: Array[Self.K, N]) -> Optional[
        Array[Pointer[Self.V, origin], N]
    ]:
        """Returns mutable pointers to the values of `N` keys, or `None` if
        any key is invalid or two keys are equal."""
        comptime assert N > 0, "get_disjoint_mut needs at least one key"
        var positions = Array[Int, N](fill=0)
        var i = 0
        while i < N:
            var pos = self._find_key(keys[i])
            if pos < 0:
                break
            positions[i] = pos
            # Keys always have odd versions, so an even version makes a
            # duplicate key show up as invalid.
            self._entry(pos).version ^= 1
            i += 1
        for j in range(i):
            self._entry(positions[j]).version ^= 1
        if i != N:
            return None
        var first = Pointer(to=self._entry(positions[0]).value).unsafe_origin_cast[
            origin
        ]()
        var result = Array[Pointer[Self.V, origin], N](fill=first)
        for j in range(1, N):
            result[j] = Pointer(
                to=self._entry(positions[j]).value
            ).unsafe_origin_cast[origin]()
        return result^

    def entry(
        mut self, key: Self.K
    ) -> Optional[SparseEntry[Self.V, Self.K, Self.H, origin_of(self)]]:
        """Gets the entry for `key` for in-place manipulation.

        Returns `None` if the key is null, or if a newer key for the same slot
        is present.
        """
        if key.is_null():
            return None
        var pos = self._find(key.data().idx)
        if pos >= 0:
            var stored = self._entry(pos).version
            if stored == key.data().version:
                return SparseEntry(Pointer(to=self), key, True)
            if is_older_version(key.data().version, stored):
                return None
        return SparseEntry(Pointer(to=self), key, False)

    # ===------------------------------------------------------------------===#
    # Iteration, equality, writing
    # ===------------------------------------------------------------------===#

    def __iter__(ref self) -> Self.IteratorType[origin_of(self)]:
        return self.items()

    def __iter__(var self) -> Self.IteratorOwnedType where conforms_to(
        Self.V, Deinitable
    ):
        """Consumes the map, yielding `(key, value)` tuples."""
        return {
            rebind_var[
                SparseSecondaryMap[downcast[Self.V, _DropValue], Self.K, Self.H]
            ](self^),
            0,
        }

    def items(ref self) -> _SparseIter[Self.K, Self.V, origin_of(self)]:
        """Iterates over `Item`s in arbitrary order. Values are mutable if
        `self` is."""
        var first_mask = _full_bits(self._group(0)) if self._cap > 0 else 0
        return {
            self._ctrl_ptr(),
            self._entries_ptr(),
            self._cap,
            0,
            first_mask,
            self._len,
        }

    def keys(ref self) -> _SparseKeysIter[Self.K, Self.V, origin_of(self)]:
        return {self.items()}

    def values(
        ref self,
    ) -> _SparseValuesIter[
        Self.K, downcast[Self.V, Copyable], origin_of(self)
    ] where conforms_to(Self.V, Copyable):
        """Iterates over references to the values. Requires `Copyable`
        values; use `items()` otherwise."""
        return {
            rebind[
                _SparseIter[
                    Self.K, downcast[Self.V, Copyable], origin_of(self)
                ]
            ](self.items())
        }

    def __eq__(self, other: Self) -> Bool where conforms_to(
        Self.V, Equatable
    ):
        if len(self) != len(other):
            return False
        for item in self:
            var p = other.get_ptr(item.key)
            if not p or not (p.value()[] == item.value()):
                return False
        return True

    def write_to(
        self, mut writer: Some[Writer]
    ) where conforms_to(Self.V, Writable):
        writer.write("{")
        var first = True
        for item in self:
            if not first:
                writer.write(", ")
            first = False
            writer.write(item.key, ": ", item.value())
        writer.write("}")


@fieldwise_init
struct SparseEntry[V: Value, K: Key, H: Hasher, origin: MutOrigin](
    ImplicitlyCopyable
):
    """A view into an occupied or vacant entry of a `SparseSecondaryMap`,
    from `SparseSecondaryMap.entry`."""

    var _map: Pointer[SparseSecondaryMap[Self.V, Self.K, Self.H], Self.origin]
    var _key: Self.K
    var _occupied: Bool

    def key(self) -> Self.K:
        return self._key

    def is_occupied(self) -> Bool:
        return self._occupied

    @inline(.always)
    def _value(self) -> ref[Self.origin] Self.V:
        ref map = self._map[]
        return map._value_ptr(
            map._find(self._key.data().idx)
        ).unsafe_origin_cast[Self.origin]()[]

    def get(self) -> ref[Self.origin] Self.V:
        """Returns the value. Aborts if the entry is vacant."""
        if not self._occupied:
            abort("SparseEntry.get() on a vacant entry")
        return self._value()

    def insert(
        mut self, var value: Self.V
    ) -> Optional[Self.V] where conforms_to(Self.V, Deinitable):
        """Sets the value, returning the previous one if the entry was
        occupied. The entry is occupied afterwards."""
        var old = self._map[].insert(self._key, value^)
        var was_occupied = self._occupied
        self._occupied = True
        if was_occupied:
            return old^
        return None

    def or_insert(
        var self, var default: Self.V
    ) -> ref[Self.origin] Self.V where conforms_to(Self.V, Deinitable):
        """Returns the value, inserting `default` first if vacant."""
        if not self._occupied:
            _ = self.insert(default^)
        return self._value()

    def or_insert_with(
        var self, default: Some[def() -> Self.V]
    ) -> ref[Self.origin] Self.V where conforms_to(Self.V, Deinitable):
        """Returns the value, inserting `default()` first if vacant."""
        if not self._occupied:
            _ = self.insert(default())
        return self._value()

    def or_default(var self) -> ref[Self.origin] Self.V where conforms_to(
        Self.V, Defaultable & Deinitable
    ):
        if not self._occupied:
            _ = self.insert(Self.V())
        return self._value()

    def and_modify(var self, f: Some[def(mut Self.V) -> None]) -> Self:
        """Calls `f` on the value if the entry is occupied."""
        if self._occupied:
            f(self._value())
        return self

    def remove(var self) -> Self.V:
        """Removes and returns the value. Aborts if the entry is vacant."""
        if not self._occupied:
            abort("SparseEntry.remove() on a vacant entry")
        ref map = self._map[]
        return map._remove_at(map._find(self._key.data().idx))

    def remove_entry(var self) -> Tuple[Self.K, Self.V]:
        var key = self._key
        return (key, self^.remove())


# ===-----------------------------------------------------------------------===#
# Iterators
# ===-----------------------------------------------------------------------===#


@fieldwise_init
struct _SparseIter[
    mut: Bool, //, K: Key, V: Movable, origin: Origin[mut=mut]
](ImplicitlyCopyable, Iterable, Iterator):
    """Walks the control bytes a group at a time: one branch per 16 slots
    rather than one per slot, which matters because occupancy is random."""

    comptime Element = Item[Self.K, Self.V, Self.origin]
    comptime IteratorType[
        iterable_mut: Bool, //, iterable_origin: Origin[mut=iterable_mut]
    ]: Iterator = Self

    var _ctrl: Pointer[UInt8, MutUntrackedOrigin]
    var _entries: Pointer[_SparseEntry[Self.V], Self.origin]
    var _cap: Int
    var _base: Int
    """Start of the current group."""
    var _mask: UInt16
    """Occupied slots of the current group not yet yielded."""
    var _num_left: Int

    def __iter__(ref self) -> Self.IteratorType[origin_of(self)]:
        return self.copy()

    def __next__(mut self) raises StopIteration -> Self.Element:
        var mask = self._mask
        var base = self._base
        while mask == 0:
            base += _GROUP
            if base >= self._cap:
                self._base = base
                self._mask = 0
                raise StopIteration()
            mask = _full_bits(
                self._ctrl.unsafe_offset(base).unsafe_load[width=_GROUP]()
            )
        var i = base + Int(count_trailing_zeros(mask))
        self._mask = mask & (mask - 1)
        self._base = base
        self._num_left -= 1
        ref e = self._entries[unsafe_offset=i]
        return Item(
            Self.K(data=KeyData(e.idx, e.version)),
            Pointer(to=e.value).unsafe_origin_cast[Self.origin](),
        )

    def bounds(self) -> Tuple[Int, Optional[Int]]:
        return (self._num_left, {self._num_left})


@fieldwise_init
struct _SparseKeysIter[
    mut: Bool, //, K: Key, V: Movable, origin: Origin[mut=mut]
](ImplicitlyCopyable, Iterable, Iterator):
    comptime Element = Self.K
    comptime IteratorType[
        iterable_mut: Bool, //, iterable_origin: Origin[mut=iterable_mut]
    ]: Iterator = Self

    var _inner: _SparseIter[Self.K, Self.V, Self.origin]

    def __iter__(ref self) -> Self.IteratorType[origin_of(self)]:
        return self.copy()

    def __next__(mut self) raises StopIteration -> Self.Element:
        return self._inner.__next__().key

    def bounds(self) -> Tuple[Int, Optional[Int]]:
        return self._inner.bounds()


@fieldwise_init
struct _SparseValuesIter[
    mut: Bool, //, K: Key, V: Copyable, origin: Origin[mut=mut]
](ImplicitlyCopyable, Iterable, Iterator):
    comptime Element = Self.V
    comptime IteratorType[
        iterable_mut: Bool, //, iterable_origin: Origin[mut=iterable_mut]
    ]: Iterator = Self

    var _inner: _SparseIter[Self.K, Self.V, Self.origin]

    def __iter__(ref self) -> Self.IteratorType[origin_of(self)]:
        return self.copy()

    def __next__(mut self) raises StopIteration -> ref[Self.origin] Self.Element:
        return self._inner.__next__()._ptr[]

    def bounds(self) -> Tuple[Int, Optional[Int]]:
        return self._inner.bounds()


@fieldwise_init
struct _SparseDrain[V: _DropValue, K: Key, H: Hasher, origin: MutOrigin](
    IterableOwned, Iterator
):
    comptime Element = Tuple[Self.K, Self.V]
    comptime IteratorOwnedType: Iterator = Self

    var _map: Pointer[SparseSecondaryMap[Self.V, Self.K, Self.H], Self.origin]
    var _cur: Int

    def __iter__(var self) -> Self:
        return self^

    def __next__(mut self) raises StopIteration -> Self.Element:
        ref map = self._map[]
        var pos = map._next(self._cur)
        if pos >= map._cap:
            raise StopIteration()
        self._cur = pos + 1
        ref e = map._entry(pos)
        var key = Self.K(data=KeyData(e.idx, e.version))
        return (key, map._remove_at(pos))

    def bounds(self) -> Tuple[Int, Optional[Int]]:
        return (len(self._map[]), {len(self._map[])})

    def __deinit__(deinit self):
        self._map[].clear()


@fieldwise_init
struct _SparseIntoIter[V: _DropValue, K: Key, H: Hasher](Iterator, Movable):
    comptime Element = Tuple[Self.K, Self.V]

    var _map: SparseSecondaryMap[Self.V, Self.K, Self.H]
    var _cur: Int

    def __next__(mut self) raises StopIteration -> Self.Element:
        var pos = self._map._next(self._cur)
        if pos >= self._map._cap:
            raise StopIteration()
        self._cur = pos + 1
        ref e = self._map._entry(pos)
        var key = Self.K(data=KeyData(e.idx, e.version))
        return (key, self._map._remove_at(pos))

    def bounds(self) -> Tuple[Int, Optional[Int]]:
        return (len(self._map), {len(self._map)})
