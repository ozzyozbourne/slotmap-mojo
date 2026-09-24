"""Contains the slot map implementation."""

from std.builtin.rebind import downcast
from std.os import abort

from .key import DefaultKey, Key, KeyData
from ._common import (
    _DropValue,
    Detached,
    Item,
    Value,
    SlotMapLike,
    _MAX_SLOTS,
    _Meta,
    _SlotIter,
    _SlotKeysIter,
    _SlotValuesIter,
    _Slots,
)


@explicit_destroy(
    "Use `deinit_with()` to destroy a map holding non-`Deinitable` values"
)
struct SlotMap[V: Value, K: Key = DefaultKey](
    Copyable where conforms_to(V, Copyable),
    Defaultable,
    Deinitable where conforms_to(V, Deinitable),
    Iterable,
    IterableOwned where conforms_to(V, Deinitable),
    Movable,
    Sized,
    Writable where conforms_to(V, Writable),
    SlotMapLike where conforms_to(V, Deinitable),
):
    """Slot map, storage with stable unique keys.

    Insertion, access and removal are all O(1). A key stays valid until its
    value is removed, even if the storage slot is reused for a new value.

    ```mojo
    var sm = SlotMap[String]()
    var foo = sm.insert("foo")
    var bar = sm.insert("bar")
    _ = sm.remove(bar)
    var reuse = sm.insert("reuse")  # Space from bar reused.
    assert_false(bar in sm)         # After deletion a key stays invalid.
    ```

    Note: the value type comes first so the key type can default to
    `DefaultKey`, i.e. Rust's `SlotMap<K, V>` is `SlotMap[V, K]`.
    """

    comptime IteratorType[
        iterable_mut: Bool, //, iterable_origin: Origin[mut=iterable_mut]
    ]: Iterator = _SlotIter[Self.K, Self.V, iterable_origin]
    comptime IteratorOwnedType: Iterator where conforms_to(
        Self.V, Deinitable
    ) = _IntoIter[Self.V, Self.K]
    comptime DrainType[origin: MutOrigin]: Iterator & IterableOwned where conforms_to(
        Self.V, Deinitable
    ) = _Drain[Self.V, Self.K, origin]
    comptime KeyType = Self.K
    comptime ValueType = Self.V

    # Slot 0 is a sentinel that is never occupied.
    var _slots: _Slots[Self.V]
    var _free_head: UInt32
    var _num_elems: UInt32

    # ===------------------------------------------------------------------===#
    # Life cycle
    # ===------------------------------------------------------------------===#

    def __init__(out self):
        """Constructs a new, empty slot map."""
        self = Self(capacity=0)

    def __init__(out self, *, capacity: Int):
        """Creates an empty slot map with room for `capacity` elements."""
        self._slots = _Slots[Self.V](capacity=capacity + 1)
        self._slots.push_vacant(_Meta(0, 0))
        self._free_head = 1
        self._num_elems = 0

    def deinit_with(deinit self, deinit_func: Some[def(var Self.V)]):
        """Destroys the map, passing each value to `deinit_func`. Use it for
        values that are not `Deinitable`."""
        self._slots^.deinit_with(deinit_func)

    # ===------------------------------------------------------------------===#
    # Size and capacity
    # ===------------------------------------------------------------------===#

    def __len__(self) -> Int:
        """Returns the number of elements in the slot map."""
        return Int(self._num_elems)

    def __bool__(self) -> Bool:
        return self._num_elems != 0

    def is_empty(self) -> Bool:
        return self._num_elems == 0

    def capacity(self) -> Int:
        """Returns the number of elements the slot map can hold without
        reallocating."""
        return self._slots.capacity() - 1  # One slot is the sentinel.

    def reserve(mut self, additional: Int):
        """Reserves capacity for at least `additional` more elements."""
        var needed = len(self) + additional - (len(self._slots) - 1)
        if needed > 0:
            self._slots.reserve(len(self._slots) + needed)

    # ===------------------------------------------------------------------===#
    # Insertion and removal
    # ===------------------------------------------------------------------===#

    def __contains__(self, key: Self.K) -> Bool:
        """Returns whether the key is present in the slot map."""
        var kd = key.data()
        return (
            Int(kd.idx) < len(self._slots)
            and self._slots.meta.unsafe_get(Int(kd.idx)).version == kd.version
        )

    def contains_key(self, key: Self.K) -> Bool:
        return key in self

    def _next_key(self) -> Self.K:
        """Returns the key the next inserted value will get."""
        var head = Int(self._free_head)
        if head < len(self._slots):
            var version = self._slots.meta.unsafe_get(head).version | 1
            return Self.K(data=KeyData.new(UInt32(head), version))
        if len(self._slots) >= _MAX_SLOTS:
            abort("SlotMap is full")
        return Self.K(data=KeyData.new(UInt32(len(self._slots)), 1))

    def _commit(mut self, key: Self.K, var value: Self.V):
        """Stores `value` at the slot `_next_key()` returned."""
        var kd = key.data()
        var idx = Int(kd.idx)
        if idx < len(self._slots):
            self._free_head = self._slots.meta.unsafe_get(idx).next_free
        else:
            self._slots.push_vacant(_Meta(0, 0))
            self._free_head = kd.idx + 1
        self._slots.write(idx, value^)
        self._slots.meta.unsafe_get(idx).version = kd.version
        self._num_elems += 1

    def insert(mut self, var value: Self.V) -> Self.K:
        """Inserts a value, returning its unique key.

        Aborts if the number of elements would exceed 2^32 - 2.
        """
        var key = self._next_key()
        self._commit(key, value^)
        return key

    def insert_with_key(mut self, f: Some[def(Self.K) -> Self.V]) -> Self.K:
        """Inserts the value `f(key)`, where `key` is the key the value will
        get. Useful for self-referential values."""
        var key = self._next_key()
        self._commit(key, f(key))
        return key

    def try_insert_with_key(
        mut self, f: Some[def(Self.K) raises -> Self.V]
    ) raises -> Self.K:
        """Like `insert_with_key`, but `f` may raise, in which case the error
        is propagated and the slot map is unchanged."""
        var key = self._next_key()
        self._commit(key, f(key))
        return key

    def _remove_from_slot(mut self, idx: Int) -> Self.V:
        """Removes and returns the value of a slot that must be occupied."""
        var value = self._slots.take(idx)
        ref slot = self._slots.meta.unsafe_get(idx)
        slot.next_free = self._free_head
        slot.version += 1
        self._free_head = UInt32(idx)
        self._num_elems -= 1
        return value^

    def remove(mut self, key: Self.K) -> Optional[Self.V]:
        """Removes a key from the slot map, returning its value if the key was
        present."""
        if key not in self:
            return None
        return self._remove_from_slot(Int(key.data().idx))

    def detach(mut self, key: Self.K) raises -> Detached[Self.V, Self.K]:
        """Temporarily removes a key, returning its value wrapped in a
        `Detached`. The slot is not reused until the value is given back with
        `reattach()` or the slot is freed with `release()`.

        Raises if the key is not present.
        """
        if key not in self:
            raise Error("detach: key is not present")
        var idx = Int(key.data().idx)
        var value = self._slots.take(idx)
        ref slot = self._slots.meta.unsafe_get(idx)
        slot.next_free = UInt32.MAX
        slot.version += 1
        self._num_elems -= 1
        return Detached(value^, key)

    def _check_detached(self, key: Self.K) -> Int:
        """Returns the slot index of a detached key, aborting if the slot is
        not detached (for example, a key from another map)."""
        var kd = key.data()
        var idx = Int(kd.idx)
        if (
            idx >= len(self._slots)
            or self._slots.meta.unsafe_get(idx).version != kd.version + 1
            or self._slots.meta.unsafe_get(idx).next_free != UInt32.MAX
        ):
            abort("key is not detached")
        return idx

    def reattach(mut self, var detached: Detached[Self.V, Self.K]):
        """Gives a detached value back under its original key. Aborts if the
        slot is not detached in this map."""
        var key = detached.key()
        var idx = self._check_detached(key)
        self._slots.write(idx, detached^._into_value())
        self._slots.meta.unsafe_get(idx).version = key.data().version
        self._num_elems += 1

    def release(mut self, var detached: Detached[Self.V, Self.K]) -> Self.V:
        """Returns a detached value and frees its slot for reuse. The key
        stays invalid. Aborts if the slot is not detached in this map."""
        var idx = self._check_detached(detached.key())
        ref slot = self._slots.meta.unsafe_get(idx)
        slot.next_free = self._free_head
        self._free_head = UInt32(idx)
        return detached^._into_value()

    def retain(
        mut self, f: Some[def(Self.K, mut Self.V) -> Bool]
    ) where conforms_to(Self.V, Deinitable):
        """Keeps only the elements for which `f(key, value)` returns `True`.
        """
        for i in range(1, len(self._slots)):
            var version = self._slots.meta.unsafe_get(i).version
            if version & 1 == 0:
                continue
            var key = Self.K(data=KeyData.new(UInt32(i), version))
            if not f(key, self._slots.raw(i)[]):
                _ = self._remove_from_slot(i)

    def clear(mut self) where conforms_to(Self.V, Deinitable):
        """Removes all elements. Keeps the allocated memory for reuse."""
        for i in range(1, len(self._slots)):
            if self._slots.meta.unsafe_get(i).occupied():
                _ = self._remove_from_slot(i)

    def drain[
        origin: MutOrigin, //
    ](ref[origin] self) -> Self.DrainType[origin] where conforms_to(Self.V, Deinitable):
        """Removes all elements, yielding `(key, value)` tuples. Elements not
        consumed are removed when the iterator is destroyed."""
        return {
            rebind[Pointer[SlotMap[downcast[Self.V, _DropValue], Self.K], origin]](
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
        """Returns a pointer to the value for `key`, or `None` if the key is
        not present. Mutable if `self` is."""
        if key not in self:
            return None
        return self._ptr(Int(key.data().idx))

    @__unsafe_nested_origins_read_only
    def unsafe_get(
        ref self, key: Self.K
    ) -> ref[origin_of(self)._get_owned_interior["value"]] Self.V:
        """Returns a reference to the value for `key` without checking that
        the key is valid. Undefined behavior if it is not."""
        assert key in self, "invalid SlotMap key used"
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
            abort("invalid SlotMap key used")
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
        var i = 0
        while i < N:
            var kd = keys[i].data()
            if keys[i] not in self:
                break
            # Temporarily mark the slot vacant so a duplicate key shows up as
            # invalid. This gives a linear time disjointness check.
            self._slots.meta.unsafe_get(Int(kd.idx)).version ^= 1
            i += 1

        for j in range(i):
            self._slots.meta.unsafe_get(Int(keys[j].data().idx)).version ^= 1

        if i != N:
            return None
        var base = self._ptr(0).unsafe_origin_cast[origin]()
        var result = Array[Pointer[Self.V, origin], N](fill=base)
        for j in range(N):
            result[j] = base.unsafe_offset(Int(keys[j].data().idx))
        return result^

    # ===------------------------------------------------------------------===#
    # Iteration
    # ===------------------------------------------------------------------===#

    def __iter__(ref self) -> Self.IteratorType[origin_of(self)]:
        """Iterates over `Item`s (key plus value reference) in arbitrary
        order. Values are mutable if `self` is."""
        return self.items()

    def __iter__(var self) -> Self.IteratorOwnedType where conforms_to(Self.V, Deinitable):
        """Consumes the map, yielding `(key, value)` tuples."""
        return {rebind_var[SlotMap[downcast[Self.V, _DropValue], Self.K]](self^), 1}

    def items(ref self) -> _SlotIter[Self.K, Self.V, origin_of(self)]:
        return {
            self._slots.meta_ptr(),
            self._ptr(0),
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
        """Iterates over references to the values. Requires `Copyable` values
        (like `List` iteration); use `items()` otherwise."""
        return {rebind[_SlotIter[Self.K, downcast[Self.V, Copyable], origin_of(self)]](self.items())}

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
struct _Drain[
    V: _DropValue, K: Key, origin: MutOrigin
](IterableOwned, Iterator):
    comptime Element = Tuple[Self.K, Self.V]
    comptime IteratorOwnedType: Iterator = Self

    var _sm: Pointer[SlotMap[Self.V, Self.K], Self.origin]
    var _cur: Int

    def __iter__(var self) -> Self:
        return self^

    def __next__(mut self) raises StopIteration -> Self.Element:
        ref sm = self._sm[]
        while self._cur < len(sm._slots):
            var idx = self._cur
            self._cur += 1
            var version = sm._slots.meta.unsafe_get(idx).version
            if version & 1 == 1:
                var key = Self.K(data=KeyData.new(UInt32(idx), version))
                return (key, sm._remove_from_slot(idx))
        raise StopIteration()

    def bounds(self) -> Tuple[Int, Optional[Int]]:
        return (len(self._sm[]), {len(self._sm[])})

    def __deinit__(deinit self):
        self._sm[].clear()


@fieldwise_init
struct _IntoIter[V: _DropValue, K: Key](Iterator, Movable):
    comptime Element = Tuple[Self.K, Self.V]

    var _sm: SlotMap[Self.V, Self.K]
    var _cur: Int

    def __next__(mut self) raises StopIteration -> Self.Element:
        while self._cur < len(self._sm._slots):
            var idx = self._cur
            self._cur += 1
            var version = self._sm._slots.meta.unsafe_get(idx).version
            if version & 1 == 1:
                var key = Self.K(data=KeyData.new(UInt32(idx), version))
                return (key, self._sm._remove_from_slot(idx))
        raise StopIteration()

    def bounds(self) -> Tuple[Int, Optional[Int]]:
        return (len(self._sm), {len(self._sm)})
