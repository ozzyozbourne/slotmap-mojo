"""Contains the dense slot map implementation."""

from std.builtin.rebind import downcast
from std.os import abort

from .key import DefaultKey, Key, KeyData
from ._common import Detached, Item, SlotMapLike, Value, _DropValue, _MAX_SLOTS, _Meta


@explicit_destroy(
    "Use `deinit_with()` to destroy a map holding non-`Deinitable` values"
)
struct DenseSlotMap[V: Value, K: Key = DefaultKey](
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
    """Dense slot map, storage with stable unique keys.

    Values are stored contiguously, so iteration is as fast as iterating a
    `List`. Random access costs one extra indirection compared to `SlotMap`.
    """

    comptime IteratorType[
        iterable_mut: Bool, //, iterable_origin: Origin[mut=iterable_mut]
    ]: Iterator = _DenseIter[Self.K, Self.V, iterable_origin]
    comptime IteratorOwnedType: Iterator where conforms_to(
        Self.V, Deinitable
    ) = _DenseDrainOwned[Self.V, Self.K]
    comptime DrainType[origin: MutOrigin]: Iterator & IterableOwned where conforms_to(
        Self.V, Deinitable
    ) = _DenseDrain[Self.V, Self.K, origin]
    comptime KeyType = Self.K
    comptime ValueType = Self.V

    var _keys: List[Self.K]
    var _values: List[Self.V]
    # `next_free` holds the index into `_keys`/`_values` when occupied, or
    # the next free slot when vacant. Slot 0 is a sentinel.
    var _slots: List[_Meta]
    var _free_head: UInt32

    def __init__(out self):
        """Constructs a new, empty dense slot map."""
        self = Self(capacity=0)

    def __init__(out self, *, capacity: Int):
        """Creates an empty dense slot map with room for `capacity`
        elements."""
        self._keys = List[Self.K](capacity=capacity)
        self._values = List[Self.V](capacity=capacity)
        self._slots = List[_Meta](capacity=capacity + 1)
        self._slots.append(_Meta(0, 0))
        self._free_head = 1

    def __init__(out self, *, copy: Self) where conforms_to(Self.V, Copyable):
        self._keys = copy._keys.copy()
        self._values = copy._values.copy()
        self._slots = copy._slots.copy()
        self._free_head = copy._free_head

    def deinit_with(deinit self, deinit_func: Some[def(var Self.V)]):
        """Destroys the map, passing each value to `deinit_func`. Use it for
        values that are not `Deinitable`."""
        self._values^.deinit_with(deinit_func)

    # ===------------------------------------------------------------------===#
    # Size and capacity
    # ===------------------------------------------------------------------===#

    def __len__(self) -> Int:
        return len(self._keys)

    def __bool__(self) -> Bool:
        return len(self._keys) != 0

    def is_empty(self) -> Bool:
        return len(self._keys) == 0

    def capacity(self) -> Int:
        return self._keys.capacity()

    def reserve(mut self, additional: Int):
        """Reserves capacity for at least `additional` more elements."""
        self._keys.reserve(len(self._keys) + additional)
        self._values.reserve(len(self._values) + additional)
        var needed = len(self) + additional - (len(self._slots) - 1)
        if needed > 0:
            self._slots.reserve(len(self._slots) + needed)

    # ===------------------------------------------------------------------===#
    # Insertion and removal
    # ===------------------------------------------------------------------===#

    def __contains__(self, key: Self.K) -> Bool:
        var kd = key.data()
        return (
            Int(kd.idx) < len(self._slots)
            and self._slots.unsafe_get(Int(kd.idx)).version == kd.version
        )

    def contains_key(self, key: Self.K) -> Bool:
        return key in self

    def _next_key(self) -> Self.K:
        var head = Int(self._free_head)
        if head < len(self._slots):
            var version = self._slots.unsafe_get(head).version | 1
            return Self.K(data=KeyData.new(UInt32(head), version))
        if len(self._slots) >= _MAX_SLOTS:
            abort("DenseSlotMap is full")
        return Self.K(data=KeyData.new(UInt32(len(self._slots)), 1))

    def _commit(mut self, key: Self.K, var value: Self.V):
        var kd = key.data()
        var idx = Int(kd.idx)
        self._values.append(value^)
        self._keys.append(key)
        var dense_idx = UInt32(len(self._keys) - 1)
        if idx < len(self._slots):
            ref slot = self._slots.unsafe_get(idx)
            self._free_head = slot.next_free
            slot.next_free = dense_idx
            slot.version = kd.version
        else:
            self._slots.append(_Meta(kd.version, dense_idx))
            self._free_head = UInt32(len(self._slots))

    def insert(mut self, var value: Self.V) -> Self.K:
        """Inserts a value, returning its unique key."""
        var key = self._next_key()
        self._commit(key, value^)
        return key

    def insert_with_key(mut self, f: Some[def(Self.K) -> Self.V]) -> Self.K:
        """Inserts the value `f(key)`, where `key` is the key the value will
        get."""
        var key = self._next_key()
        self._commit(key, f(key))
        return key

    def try_insert_with_key(
        mut self, f: Some[def(Self.K) raises -> Self.V]
    ) raises -> Self.K:
        """Like `insert_with_key`, but `f` may raise, in which case the map
        is unchanged."""
        var key = self._next_key()
        self._commit(key, f(key))
        return key

    def _free_slot(mut self, slot_idx: Int) -> Int:
        """Adds a slot to the freelist, returning the dense index it held."""
        ref slot = self._slots.unsafe_get(slot_idx)
        var dense_idx = Int(slot.next_free)
        slot.version += 1
        slot.next_free = self._free_head
        self._free_head = UInt32(slot_idx)
        return dense_idx

    def _swap_remove(mut self, dense_idx: Int) -> Self.V:
        """Removes the dense element at `dense_idx` by moving the last one
        into its place (Rust's `Vec::swap_remove`).

        Written with raw pointers rather than `List.pop()`: `pop` runs a
        bounds check whose abort-message setup the compiler hoists into the
        hot loop, which cost about 30% on every removal.
        """
        var last = len(self._keys) - 1
        var keys = self._keys.unsafe_ptr()
        var values = self._values.unsafe_ptr()
        var value = values.unsafe_offset(dense_idx).unsafe_take_pointee()
        if dense_idx != last:
            values.unsafe_offset(dense_idx).unsafe_write(
                values.unsafe_offset(last).unsafe_take_pointee()
            )
            var moved = keys[unsafe_offset=last]
            keys[unsafe_offset=dense_idx] = moved
            # The moved element's slot must point at its new position.
            self._slots.unsafe_get(Int(moved.data().idx)).next_free = UInt32(
                dense_idx
            )
        # Both lists shrink by one; their last element has been moved out
        # (keys are trivially destructible).
        self._keys._len = last
        self._values._len = last
        return value^

    def _remove_from_slot(mut self, slot_idx: Int) -> Self.V:
        return self._swap_remove(self._free_slot(slot_idx))

    def remove(mut self, key: Self.K) -> Optional[Self.V]:
        """Removes a key, returning its value if it was present."""
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
        ref slot = self._slots.unsafe_get(Int(key.data().idx))
        var dense_idx = Int(slot.next_free)
        slot.version += 1
        slot.next_free = UInt32.MAX
        return Detached(self._swap_remove(dense_idx), key)

    def _check_detached(self, key: Self.K) -> Int:
        """Returns the slot index of a detached key, aborting if the slot is
        not detached (for example, a key from another map)."""
        var kd = key.data()
        var idx = Int(kd.idx)
        if (
            idx >= len(self._slots)
            or self._slots.unsafe_get(idx).version != kd.version + 1
            or self._slots.unsafe_get(idx).next_free != UInt32.MAX
        ):
            abort("key is not detached")
        return idx

    def reattach(mut self, var detached: Detached[Self.V, Self.K]):
        """Gives a detached value back under its original key. Aborts if the
        slot is not detached in this map."""
        var key = detached.key()
        var idx = self._check_detached(key)
        self._keys.append(key)
        self._values.append(detached^._into_value())
        ref slot = self._slots.unsafe_get(idx)
        slot.next_free = UInt32(len(self._keys) - 1)
        slot.version = key.data().version

    def release(mut self, var detached: Detached[Self.V, Self.K]) -> Self.V:
        """Returns a detached value and frees its slot for reuse. The key
        stays invalid. Aborts if the slot is not detached in this map."""
        var idx = self._check_detached(detached.key())
        self._slots.unsafe_get(idx).next_free = self._free_head
        self._free_head = UInt32(idx)
        return detached^._into_value()

    def retain(
        mut self, f: Some[def(Self.K, mut Self.V) -> Bool]
    ) where conforms_to(Self.V, Deinitable):
        """Keeps only the elements for which `f(key, value)` returns
        `True`."""
        var i = 0
        while i < len(self._keys):
            var key = self._keys.unsafe_get(i)
            if f(key, self._values.unsafe_get(i)):
                i += 1
            else:
                # Don't advance: index `i` now holds the swapped-in element.
                _ = self._remove_from_slot(Int(key.data().idx))

    def clear(mut self) where conforms_to(Self.V, Deinitable):
        """Removes all elements. Keeps the allocated memory for reuse."""
        while len(self._keys) > 0:
            _ = self._pop()

    def _pop(mut self) -> Tuple[Self.K, Self.V]:
        var key = self._keys.pop()
        var value = self._values.pop()
        _ = self._free_slot(Int(key.data().idx))
        return (key, value^)

    def drain[
        origin: MutOrigin, //
    ](ref[origin] self) -> Self.DrainType[origin] where conforms_to(Self.V, Deinitable):
        """Removes all elements, yielding `(key, value)` tuples. Elements not
        consumed are removed when the iterator is destroyed."""
        return {
            rebind[Pointer[DenseSlotMap[downcast[Self.V, _DropValue], Self.K], origin]](
                Pointer(to=self)
            )
        }

    # ===------------------------------------------------------------------===#
    # Access
    # ===------------------------------------------------------------------===#

    @inline(.always)
    def _dense_idx(self, key: Self.K) -> Int:
        return Int(self._slots.unsafe_get(Int(key.data().idx)).next_free)

    def get(self, key: Self.K) -> Optional[Self.V] where conforms_to(
        Self.V, Copyable
    ):
        """Returns a copy of the value for `key`, if present."""
        if key not in self:
            return None
        return self._values.unsafe_get(self._dense_idx(key)).copy()

    def get_ptr(
        ref self, key: Self.K
    ) -> OptionalPointer[Self.V, origin_of(self)]:
        """Returns a pointer to the value for `key`, or `None`."""
        if key not in self:
            return None
        return self._values_ptr().unsafe_offset(self._dense_idx(key))

    @__unsafe_nested_origins_read_only
    def unsafe_get(
        ref self, key: Self.K
    ) -> ref[origin_of(self)._get_owned_interior["value"]] Self.V:
        """Returns a reference to the value for `key` without checking the
        key."""
        assert key in self, "invalid DenseSlotMap key used"
        return Pointer(
            to=self._values.unsafe_get(self._dense_idx(key))
        )._get_ref_with_unsafe_interior_origin["value", origin_of(self)]()

    @__unsafe_nested_origins_read_only
    def __getitem__(
        ref self, key: Self.K
    ) -> ref[origin_of(self)._get_owned_interior["value"]] Self.V:
        """Returns a reference to the value for `key`. Aborts if the key is
        not present."""
        if key not in self:
            abort("invalid DenseSlotMap key used")
        return Pointer(
            to=self._values.unsafe_get(self._dense_idx(key))
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
            if keys[i] not in self:
                break
            self._slots.unsafe_get(Int(keys[i].data().idx)).version ^= 1
            i += 1
        for j in range(i):
            self._slots.unsafe_get(Int(keys[j].data().idx)).version ^= 1
        if i != N:
            return None
        var base = self._values_ptr().unsafe_origin_cast[origin]()
        var result = Array[Pointer[Self.V, origin], N](fill=base)
        for j in range(N):
            result[j] = base.unsafe_offset(self._dense_idx(keys[j]))
        return result^

    # ===------------------------------------------------------------------===#
    # Iteration and slices
    # ===------------------------------------------------------------------===#

    @inline(.always)
    def _values_ptr(ref self) -> Pointer[Self.V, origin_of(self)]:
        return self._values.unsafe_ptr().unsafe_mut_cast[
            origin_of(self).mut
        ]().unsafe_origin_cast[origin_of(self)]()

    def __iter__(ref self) -> Self.IteratorType[origin_of(self)]:
        return self.items()

    def __iter__(var self) -> Self.IteratorOwnedType where conforms_to(Self.V, Deinitable):
        return {rebind_var[DenseSlotMap[downcast[Self.V, _DropValue], Self.K]](self^)}

    def items(ref self) -> _DenseIter[Self.K, Self.V, origin_of(self)]:
        """Iterates over `Item`s in arbitrary order. Values are mutable if
        `self` is."""
        return {
            self._keys.unsafe_ptr()
            .unsafe_mut_cast[False]()
            .unsafe_origin_cast[ImmUntrackedOrigin](),
            self._values_ptr(),
            len(self._keys),
            0,
        }

    def keys(self) -> Span[Self.K, origin_of(self._keys)]:
        """Returns the keys, in the same order as `values()`."""
        return Span(self._keys)

    def values(ref self) -> Span[Self.V, origin_of(self._values)]:
        """Returns the values as a contiguous span, mutable if `self` is."""
        return Span(self._values)

    def keys_as_slice(self) -> Span[Self.K, origin_of(self._keys)]:
        return Span(self._keys)

    def values_as_slice(ref self) -> Span[Self.V, origin_of(self._values)]:
        return Span(self._values)

    def as_slices(
        ref self,
    ) -> Tuple[
        Span[Self.K, ImmUntrackedOrigin],
        Span[Self.V, origin_of(self._values)],
    ]:
        """Returns the keys and values as parallel spans. Only the values are
        mutable."""
        var keys = Span[Self.K, ImmUntrackedOrigin](
            unsafe_ptr=self._keys.unsafe_ptr()
            .unsafe_mut_cast[False]()
            .unsafe_origin_cast[ImmUntrackedOrigin](),
            length=len(self._keys),
        )
        return (keys, Span(self._values))

    def write_to(
        self, mut writer: Some[Writer]
    ) where conforms_to(Self.V, Writable):
        writer.write("{")
        for i in range(len(self._keys)):
            if i:
                writer.write(", ")
            writer.write(self._keys.unsafe_get(i), ": ", self._values.unsafe_get(i))
        writer.write("}")


@fieldwise_init
struct _DenseIter[
    mut: Bool, //, K: Key, V: AnyType, origin: Origin[mut=mut]
](ImplicitlyCopyable, Iterable, Iterator):
    comptime Element = Item[Self.K, Self.V, Self.origin]
    comptime IteratorType[
        iterable_mut: Bool, //, iterable_origin: Origin[mut=iterable_mut]
    ]: Iterator = Self

    var _keys: Pointer[Self.K, ImmUntrackedOrigin]
    var _values: Pointer[Self.V, Self.origin]
    var _len: Int
    var _cur: Int

    def __iter__(ref self) -> Self.IteratorType[origin_of(self)]:
        return self.copy()

    def __next__(mut self) raises StopIteration -> Self.Element:
        if self._cur >= self._len:
            raise StopIteration()
        var i = self._cur
        self._cur += 1
        return Item(self._keys[unsafe_offset=i], self._values.unsafe_offset(i))

    def bounds(self) -> Tuple[Int, Optional[Int]]:
        return (self._len - self._cur, {self._len - self._cur})


@fieldwise_init
struct _DenseDrain[V: _DropValue, K: Key, origin: MutOrigin](
    IterableOwned, Iterator
):
    comptime Element = Tuple[Self.K, Self.V]
    comptime IteratorOwnedType: Iterator = Self

    var _sm: Pointer[DenseSlotMap[Self.V, Self.K], Self.origin]

    def __iter__(var self) -> Self:
        return self^

    def __next__(mut self) raises StopIteration -> Self.Element:
        # No iteration order is guaranteed, so just pop repeatedly.
        if len(self._sm[]) == 0:
            raise StopIteration()
        return self._sm[]._pop()

    def bounds(self) -> Tuple[Int, Optional[Int]]:
        return (len(self._sm[]), {len(self._sm[])})

    def __deinit__(deinit self):
        self._sm[].clear()


@fieldwise_init
struct _DenseDrainOwned[V: _DropValue, K: Key](Iterator, Movable):
    comptime Element = Tuple[Self.K, Self.V]

    var _sm: DenseSlotMap[Self.V, Self.K]

    def __next__(mut self) raises StopIteration -> Self.Element:
        if len(self._sm) == 0:
            raise StopIteration()
        return self._sm._pop()

    def bounds(self) -> Tuple[Int, Optional[Int]]:
        return (len(self._sm), {len(self._sm)})
