"""Contains the secondary map implementation."""

from std.builtin.rebind import downcast
from std.os import abort

from .key import DefaultKey, Key, KeyData
from ._common import (
    Item,
    Value,
    _DropValue,
    _Meta,
    _SlotIter,
    _SlotKeysIter,
    _SlotValuesIter,
    _Slots,
)
from ._util import is_older_version


@explicit_destroy(
    "Use `deinit_with()` to destroy a map holding non-`Deinitable` values"
)
struct SecondaryMap[V: Value, K: Key = DefaultKey](
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
    """Secondary map, associates data with previously stored elements in a
    slot map.

    A `SecondaryMap` lets you efficiently store extra information for each
    element in a slot map. It works with keys from any slot map with the same
    key type. It is a direct index into an array, so it is as fast as the slot
    map itself.

    Keys removed from the slot map may still be present here. Inserting a key
    whose slot was reused by the slot map removes the outdated entry. An
    outdated key never overwrites a newer one.

    ```mojo
    var players = SlotMap[String]()
    var health = SecondaryMap[Int]()
    var alice = players.insert("alice")
    _ = health.insert(alice, 100)
    ```
    """

    comptime IteratorType[
        iterable_mut: Bool, //, iterable_origin: Origin[mut=iterable_mut]
    ]: Iterator = _SlotIter[Self.K, Self.V, iterable_origin]
    comptime IteratorOwnedType: Iterator where conforms_to(
        Self.V, Deinitable
    ) = _SecIntoIter[Self.V, Self.K]

    # Vacant slots have version 0. Slot 0 is a sentinel so indices line up
    # with the slot maps.
    var _slots: _Slots[Self.V]
    var _num_elems: Int

    def __init__(out self):
        """Constructs a new, empty secondary map."""
        self = Self(capacity=0)

    def __init__(out self, *, capacity: Int):
        """Creates an empty secondary map with room for keys with indices
        below `capacity`."""
        self._slots = _Slots[Self.V](capacity=capacity + 1)
        self._slots.push_vacant(_Meta(0, 0))
        self._num_elems = 0

    def deinit_with(deinit self, deinit_func: Some[def(var Self.V)]):
        """Destroys the map, passing each value to `deinit_func`. Use it for
        values that are not `Deinitable`."""
        self._slots^.deinit_with(deinit_func)

    # ===------------------------------------------------------------------===#
    # Size and capacity
    # ===------------------------------------------------------------------===#

    def __len__(self) -> Int:
        return self._num_elems

    def __bool__(self) -> Bool:
        return self._num_elems != 0

    def is_empty(self) -> Bool:
        return self._num_elems == 0

    def capacity(self) -> Int:
        """Returns the number of slots the map can hold without
        reallocating."""
        return self._slots.capacity() - 1

    def set_capacity(mut self, new_capacity: Int):
        """Grows the storage so keys with indices below `new_capacity` fit
        without reallocating. Never shrinks."""
        self._slots.reserve(new_capacity + 1)

    # ===------------------------------------------------------------------===#
    # Insertion and removal
    # ===------------------------------------------------------------------===#

    def __contains__(self, key: Self.K) -> Bool:
        var kd = key.data()
        return (
            Int(kd.idx) < len(self._slots)
            and self._slots.version(Int(kd.idx)) == kd.version
        )

    def contains_key(self, key: Self.K) -> Bool:
        return key in self

    def _ensure_slot(mut self, idx: Int):
        """Extends the slots with vacant ones so `idx` is valid."""
        self._slots.extend_vacant(idx + 1)

    def insert(
        mut self, key: Self.K, var value: Self.V
    ) -> Optional[Self.V] where conforms_to(Self.V, Deinitable):
        """Inserts a value into the secondary map at the given key.

        Returns the previous value if the key was present. If a *newer* key
        for the same slot is present, nothing is inserted and `None` is
        returned. Null keys are ignored.
        """
        if key.is_null():
            return None
        var kd = key.data()
        var idx = Int(kd.idx)
        self._ensure_slot(idx)

        var version = self._slots.version(idx)
        if version == kd.version:
            var old = self._slots.take(idx)
            self._slots.write(idx, value^)
            return old^

        if version & 1 == 1:
            # Don't replace existing newer values.
            if is_older_version(kd.version, version):
                return None
            _ = self._slots.take(idx)  # Drop the outdated value.
        else:
            self._num_elems += 1

        self._slots.write(idx, value^)
        self._slots.meta(idx).version = kd.version
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
        var idx = Int(kd.idx)
        self._ensure_slot(idx)

        var version = self._slots.version(idx)
        if version & 1 == 1:
            if version != kd.version and is_older_version(kd.version, version):
                return value^  # A newer key holds the slot.
            var old = self._slots.take(idx)
            self._slots.write(idx, value^)
            self._slots.meta(idx).version = kd.version
            return old^
        self._num_elems += 1
        self._slots.write(idx, value^)
        self._slots.meta(idx).version = kd.version
        return None

    def _remove_from_slot(mut self, idx: Int) -> Self.V:
        self._num_elems -= 1
        self._slots.meta(idx).version = 0
        return self._slots.take(idx)

    def remove(mut self, key: Self.K) -> Optional[Self.V]:
        """Removes a key, returning its value if it was present."""
        if key not in self:
            return None
        return self._remove_from_slot(Int(key.data().idx))

    def retain(
        mut self, f: Some[def(Self.K, mut Self.V) -> Bool]
    ) where conforms_to(Self.V, Deinitable):
        """Keeps only the elements for which `f(key, value)` returns
        `True`."""
        for i in range(len(self._slots)):
            var version = self._slots.version(i)
            if version & 1 == 0:
                continue
            var key = Self.K(data=KeyData.new(UInt32(i), version))
            if not f(key, self._slots.raw(i)[]):
                _ = self._remove_from_slot(i)

    def clear(mut self) where conforms_to(Self.V, Deinitable):
        """Removes all elements. Keeps the allocated memory for reuse."""
        for i in range(len(self._slots)):
            if self._slots.meta(i).occupied():
                _ = self._remove_from_slot(i)

    def drain[
        origin: MutOrigin, //
    ](ref[origin] self) -> _SecDrain[
        downcast[Self.V, _DropValue], Self.K, origin
    ] where conforms_to(Self.V, Deinitable):
        """Removes all elements, yielding `(key, value)` tuples. Elements not
        consumed are removed when the iterator is destroyed."""
        return {
            rebind[Pointer[SecondaryMap[downcast[Self.V, _DropValue], Self.K], origin]](
                Pointer(to=self)
            ),
            1,
        }

    # ===------------------------------------------------------------------===#
    # Access
    # ===------------------------------------------------------------------===#

    @inline(.always)
    def _ptr(ref self, idx: Int) -> Pointer[Self.V, origin_of(self)]:
        return self._slots.ptr(idx).unsafe_origin_cast[origin_of(self)]()

    def get(self, key: Self.K) -> Optional[Self.V] where conforms_to(
        Self.V, Copyable
    ):
        """Returns a copy of the value for `key`, if present."""
        if key not in self:
            return None
        return self._slots.raw(Int(key.data().idx))[].copy()

    def get_ptr(
        ref self, key: Self.K
    ) -> OptionalPointer[Self.V, origin_of(self)]:
        """Returns a pointer to the value for `key`, or `None`."""
        if key not in self:
            return None
        return self._ptr(Int(key.data().idx))

    @__unsafe_nested_origins_read_only
    def unsafe_get(
        ref self, key: Self.K
    ) -> ref[origin_of(self)._get_owned_interior["value"]] Self.V:
        """Returns a reference to the value for `key` without checking the
        key."""
        assert key in self, "invalid SecondaryMap key used"
        return Pointer(
            to=self._slots.raw(Int(key.data().idx))[]
        )._get_ref_with_unsafe_interior_origin["value", origin_of(self)]()

    @__unsafe_nested_origins_read_only
    def __getitem__(
        ref self, key: Self.K
    ) -> ref[origin_of(self)._get_owned_interior["value"]] Self.V:
        """Returns a reference to the value for `key`. Aborts if the key is
        not present."""
        if key not in self:
            abort("invalid SecondaryMap key used")
        return Pointer(
            to=self._slots.raw(Int(key.data().idx))[]
        )._get_ref_with_unsafe_interior_origin["value", origin_of(self)]()

    def get_disjoint_mut[
        origin: MutOrigin, //, N: Int
    ](ref[origin] self, keys: Array[Self.K, N]) -> Optional[
        Array[Pointer[Self.V, origin], N]
    ]:
        """Returns mutable pointers to the values of `N` keys, or `None` if
        any key is invalid or two keys are equal."""
        comptime assert N > 0, "get_disjoint_mut needs at least one key"
        var versions = Array[UInt32, N](fill=0)
        var i = 0
        while i < N:
            if keys[i] not in self:
                break
            # Keys always have odd versions, so temporarily setting the
            # version to 2 makes a duplicate key show up as invalid.
            ref meta = self._slots.meta(Int(keys[i].data().idx))
            versions[i] = meta.version
            meta.version = 2
            i += 1
        for j in range(i):
            self._slots.meta(
                Int(keys[j].data().idx)
            ).version = versions[j]
        if i != N:
            return None
        # Slots interleave metadata and value, so each pointer is computed
        # per slot rather than by offsetting a base pointer.
        var result = Array[Pointer[Self.V, origin], N](
            fill=self._ptr(0).unsafe_origin_cast[origin]()
        )
        for j in range(N):
            result[j] = self._ptr(Int(keys[j].data().idx)).unsafe_origin_cast[
                origin
            ]()
        return result^

    def entry(
        mut self, key: Self.K
    ) -> Optional[Entry[Self.V, Self.K, origin_of(self)]]:
        """Gets the entry for `key` for in-place manipulation.

        Returns `None` if the key is null, or if a newer key for the same slot
        is present.
        """
        if key.is_null():
            return None
        var kd = key.data()
        # Ensure the slot exists so the entry can assume it does.
        self._ensure_slot(Int(kd.idx))
        var version = self._slots.version(Int(kd.idx))
        if kd.version == version:
            return Entry(Pointer(to=self), kd, True)
        if is_older_version(kd.version, version):
            return None
        return Entry(Pointer(to=self), kd, False)

    # ===------------------------------------------------------------------===#
    # Iteration, equality, writing
    # ===------------------------------------------------------------------===#

    def __iter__(ref self) -> Self.IteratorType[origin_of(self)]:
        return self.items()

    def __iter__(var self) -> Self.IteratorOwnedType where conforms_to(Self.V, Deinitable):
        """Consumes the map, yielding `(key, value)` tuples."""
        return {rebind_var[SecondaryMap[downcast[Self.V, _DropValue], Self.K]](self^), 1}

    def items(ref self) -> _SlotIter[Self.K, Self.V, origin_of(self)]:
        """Iterates over `Item`s in arbitrary order. Values are mutable if
        `self` is."""
        return {
            self._slots.slots_ptr().unsafe_origin_cast[origin_of(self)](),
            len(self._slots),
            1,
            len(self),
        }

    def keys(ref self) -> _SlotKeysIter[Self.K, Self.V, origin_of(self)]:
        return {self.items()}

    def values(
        ref self,
    ) -> _SlotValuesIter[
        Self.K, downcast[Self.V, Copyable], origin_of(self)
    ] where conforms_to(Self.V, Copyable):
        """Iterates over references to the values. Requires `Copyable`
        values; use `items()` otherwise."""
        return {
            rebind[
                _SlotIter[
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
struct Entry[V: Value, K: Key, origin: MutOrigin](ImplicitlyCopyable):
    """A view into an occupied or vacant slot of a `SecondaryMap`, from
    `SecondaryMap.entry`. Merges Rust's `Entry`, `OccupiedEntry` and
    `VacantEntry`."""

    var _map: Pointer[SecondaryMap[Self.V, Self.K], Self.origin]
    var _kd: KeyData
    var _occupied: Bool

    def key(self) -> Self.K:
        return Self.K(data=self._kd)

    def is_occupied(self) -> Bool:
        return self._occupied

    @inline(.always)
    def _value(self) -> ref[Self.origin] Self.V:
        return (
            self._map[]
            ._slots.raw(Int(self._kd.idx))
            .unsafe_origin_cast[Self.origin]()[]
        )

    def get(self) -> ref[Self.origin] Self.V:
        """Returns the value. Aborts if the entry is vacant."""
        if not self._occupied:
            abort("Entry.get() on a vacant entry")
        return self._value()

    def insert(
        mut self, var value: Self.V
    ) -> Optional[Self.V] where conforms_to(Self.V, Deinitable):
        """Sets the value, returning the previous one if the entry was
        occupied. The entry is occupied afterwards."""
        var idx = Int(self._kd.idx)
        ref map = self._map[]
        if self._occupied:
            var old = map._slots.take(idx)
            map._slots.write(idx, value^)
            return old^
        # The slot may still hold an outdated element.
        if map._slots.meta(idx).occupied():
            _ = map._slots.take(idx)
        else:
            map._num_elems += 1
        map._slots.write(idx, value^)
        map._slots.meta(idx).version = self._kd.version
        self._occupied = True
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
            abort("Entry.remove() on a vacant entry")
        return self._map[]._remove_from_slot(Int(self._kd.idx))

    def remove_entry(var self) -> Tuple[Self.K, Self.V]:
        var key = self.key()
        return (key, self^.remove())


@fieldwise_init
struct _SecDrain[V: _DropValue, K: Key, origin: MutOrigin](
    IterableOwned, Iterator
):
    comptime Element = Tuple[Self.K, Self.V]
    comptime IteratorOwnedType: Iterator = Self

    var _map: Pointer[SecondaryMap[Self.V, Self.K], Self.origin]
    var _cur: Int

    def __iter__(var self) -> Self:
        return self^

    def __next__(mut self) raises StopIteration -> Self.Element:
        ref map = self._map[]
        while self._cur < len(map._slots):
            var idx = self._cur
            self._cur += 1
            var version = map._slots.version(idx)
            if version & 1 == 1:
                var key = Self.K(data=KeyData.new(UInt32(idx), version))
                return (key, map._remove_from_slot(idx))
        raise StopIteration()

    def bounds(self) -> Tuple[Int, Optional[Int]]:
        return (len(self._map[]), {len(self._map[])})

    def __deinit__(deinit self):
        self._map[].clear()


@fieldwise_init
struct _SecIntoIter[V: _DropValue, K: Key](Iterator, Movable):
    comptime Element = Tuple[Self.K, Self.V]

    var _map: SecondaryMap[Self.V, Self.K]
    var _cur: Int

    def __next__(mut self) raises StopIteration -> Self.Element:
        while self._cur < len(self._map._slots):
            var idx = self._cur
            self._cur += 1
            var version = self._map._slots.version(idx)
            if version & 1 == 1:
                var key = Self.K(data=KeyData.new(UInt32(idx), version))
                return (key, self._map._remove_from_slot(idx))
        raise StopIteration()

    def bounds(self) -> Tuple[Int, Optional[Int]]:
        return (len(self._map), {len(self._map)})
