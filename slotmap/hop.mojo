"""Contains the faster iteration, slower insertion/removal slot map
implementation.

Deprecated upstream: the Rust crate plans to remove `HopSlotMap` in 2.0.
Prefer `SlotMap` or `DenseSlotMap`.
"""

from std.builtin.rebind import downcast
from std.os import abort

from .key import DefaultKey, Key, KeyData
from ._common import Item, SlotMapLike, Value, _DropValue, _Meta, _Slots


@fieldwise_init
struct _FreeListEntry(ImplicitlyCopyable, Writable):
    """Freelist metadata of a vacant slot.

    Vacant slots form contiguous blocks. The two ends of a block point at
    each other with `other_end`, and the front slot of each block is in a
    doubly linked list of blocks (`next`/`prev`) headed by the sentinel slot
    0. Only these endpoint fields are kept up to date.
    """

    var next: UInt32
    var prev: UInt32
    var other_end: UInt32


@explicit_destroy(
    "Use `deinit_with()` to destroy a map holding non-`Deinitable` values"
)
struct HopSlotMap[V: Value, K: Key = DefaultKey](
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
    """Hop slot map, storage with stable unique keys.

    Like `SlotMap`, but iteration skips over whole blocks of vacant slots, at
    the cost of roughly twice as slow insertion and removal.

    Deprecated upstream; prefer `SlotMap` or `DenseSlotMap`.
    """

    comptime IteratorType[
        iterable_mut: Bool, //, iterable_origin: Origin[mut=iterable_mut]
    ]: Iterator = _HopIter[Self.K, Self.V, iterable_origin]
    comptime IteratorOwnedType: Iterator where conforms_to(
        Self.V, Deinitable
    ) = _HopIntoIter[Self.V, Self.K]
    comptime DrainType[origin: MutOrigin]: Iterator & IterableOwned where conforms_to(
        Self.V, Deinitable
    ) = _HopDrain[Self.V, Self.K, origin]
    comptime KeyType = Self.K
    comptime ValueType = Self.V

    # Only `version` of the slot metadata is used. `_free[i]` is the freelist
    # entry of slot `i`, meaningful only while the slot is vacant.
    var _slots: _Slots[Self.V]
    var _free: List[_FreeListEntry]
    var _num_elems: UInt32

    def __init__(out self):
        """Constructs a new, empty hop slot map."""
        self = Self(capacity=0)

    def __init__(out self, *, capacity: Int):
        """Creates an empty hop slot map with room for `capacity`
        elements."""
        # Sentinel at index 0.
        self._slots = _Slots[Self.V](capacity=capacity + 1)
        self._slots.push_vacant(_Meta(0, 0))
        self._free = List[_FreeListEntry](capacity=capacity + 1)
        self._free.append(_FreeListEntry(0, 0, 0))
        self._num_elems = 0

    def deinit_with(deinit self, deinit_func: Some[def(var Self.V)]):
        """Destroys the map, passing each value to `deinit_func`. Use it for
        values that are not `Deinitable`."""
        self._slots^.deinit_with(deinit_func)

    # ===------------------------------------------------------------------===#
    # Size and capacity
    # ===------------------------------------------------------------------===#

    def __len__(self) -> Int:
        return Int(self._num_elems)

    def __bool__(self) -> Bool:
        return self._num_elems != 0

    def is_empty(self) -> Bool:
        return self._num_elems == 0

    def capacity(self) -> Int:
        return self._slots.capacity() - 1  # One slot is the sentinel.

    def reserve(mut self, additional: Int):
        """Reserves capacity for at least `additional` more elements."""
        var needed = len(self) + additional - (len(self._slots) - 1)
        if needed > 0:
            self._slots.reserve(len(self._slots) + needed)
            self._free.reserve(len(self._slots) + needed)

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

    @inline(.always)
    def _fl(
        ref self, idx: UInt32
    ) -> ref[origin_of(self._free)._get_owned_interior["element"]] _FreeListEntry:
        """The freelist entry of a slot, which must be vacant."""
        return self._free.unsafe_get(Int(idx))

    @inline(.always)
    def _occupied(self, idx: Int) -> Bool:
        return self._slots.meta.unsafe_get(idx).occupied()

    def _next_key(self) -> Self.K:
        if self._num_elems + 1 == UInt32.MAX:
            abort("HopSlotMap number of elements overflow")
        # We have a contiguous block of vacant slots starting at head. The
        # new element goes into its back slot.
        var back = self._fl(self._fl(0).next).other_end
        if back == 0:
            # Freelist is empty.
            return Self.K(data=KeyData.new(UInt32(len(self._slots)), 1))
        var version = self._slots.version(Int(back)) | 1
        return Self.K(data=KeyData.new(back, version))

    def _commit(mut self, key: Self.K, var value: Self.V):
        var kd = key.data()
        var idx = Int(kd.idx)
        if idx == len(self._slots):
            self._slots.push_vacant(_Meta(0, 0))
            self._free.append(_FreeListEntry(0, 0, 0))
        else:
            var front = self._fl(0).next
            var back = kd.idx
            if front == back:
                # Used the last slot in this block, move the next one to head.
                var new_head = self._fl(front).next
                self._fl(0).next = new_head
                self._fl(new_head).prev = 0
            else:
                # Keep using this block, only the other_ends change.
                var new_back = back - 1
                self._fl(new_back).other_end = front
                self._fl(front).other_end = new_back
        self._slots.write(idx, value^)
        self._slots.meta.unsafe_get(idx).version = kd.version
        self._num_elems += 1

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

    def _remove_from_slot(mut self, idx: Int) -> Self.V:
        """Removes and returns the value of a slot that must be occupied,
        merging the slot into the neighboring vacant blocks."""
        self._slots.meta.unsafe_get(idx).version += 1
        var value = self._slots.take(idx)

        # Can't underflow thanks to the sentinel at index 0.
        var left_vacant = not self._occupied(idx - 1)
        var right_vacant = idx + 1 < len(self._slots) and not self._occupied(
            idx + 1
        )

        var i = UInt32(idx)
        if not left_vacant and not right_vacant:
            # New block, insert it at the tail.
            var old_tail = self._fl(0).prev
            self._fl(0).prev = i
            self._fl(old_tail).next = i
            self._fl(i) = _FreeListEntry(0, old_tail, i)
        elif not left_vacant and right_vacant:
            # Prepend to the vacant block on the right. Since the start of
            # that block moved, update the pointers to it.
            var front_data = self._fl(i + 1)
            self._fl(front_data.other_end).other_end = i
            self._fl(front_data.prev).next = i
            self._fl(front_data.next).prev = i
            self._fl(i) = front_data
        elif left_vacant and not right_vacant:
            # Append to the vacant block on the left.
            var front = self._fl(i - 1).other_end
            self._fl(front).other_end = i
            self._fl(i) = _FreeListEntry(0, 0, front)
        else:
            # Merge the blocks on the left and right. First snip the right
            # block out of the freelist.
            var right = self._fl(i + 1)
            self._fl(right.prev).next = right.next
            self._fl(right.next).prev = right.prev
            # Then update the endpoints.
            var front = self._fl(i - 1).other_end
            var back = right.other_end
            self._fl(front).other_end = back
            self._fl(back).other_end = front
            self._fl(i) = _FreeListEntry(0, 0, 0)

        self._num_elems -= 1
        return value^

    def remove(mut self, key: Self.K) -> Optional[Self.V]:
        """Removes a key, returning its value if it was present."""
        if key not in self:
            return None
        return self._remove_from_slot(Int(key.data().idx))

    def _after(self, idx: Int) -> Int:
        """Returns the next occupied slot after `idx`, or 0 if none."""
        if idx + 1 >= len(self._slots):
            return 0
        if self._occupied(idx + 1):
            return idx + 1
        return Int(self._fl(UInt32(idx + 1)).other_end) + 1

    def _first(self) -> Int:
        return Int(self._fl(0).other_end) + 1

    def retain(
        mut self, f: Some[def(Self.K, mut Self.V) -> Bool]
    ) where conforms_to(Self.V, Deinitable):
        """Keeps only the elements for which `f(key, value)` returns
        `True`."""
        var left = len(self)
        var cur = self._first()
        while left > 0:
            var idx = cur
            var key = Self.K(
                data=KeyData.new(UInt32(idx), self._slots.version(idx))
            )
            var keep = f(key, self._slots.raw(idx)[])
            # Must find the next element before removing.
            cur = self._after(idx)
            if not keep:
                _ = self._remove_from_slot(idx)
            left -= 1

    def clear(mut self) where conforms_to(Self.V, Deinitable):
        """Removes all elements. Keeps the allocated memory for reuse."""
        var cur = self._first()
        while len(self) > 0:
            var idx = cur
            cur = self._after(idx)
            _ = self._remove_from_slot(idx)

    def drain[
        origin: MutOrigin, //
    ](ref[origin] self) -> Self.DrainType[origin] where conforms_to(Self.V, Deinitable):
        """Removes all elements, yielding `(key, value)` tuples. Elements not
        consumed are removed when the iterator is destroyed."""
        var first = self._first()
        return {
            rebind[Pointer[HopSlotMap[downcast[Self.V, _DropValue], Self.K], origin]](
                Pointer(to=self)
            ),
            first,
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
        assert key in self, "invalid HopSlotMap key used"
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
            abort("invalid HopSlotMap key used")
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
            if keys[i] not in self:
                break
            self._slots.meta.unsafe_get(Int(keys[i].data().idx)).version ^= 1
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
        return self.items()

    def __iter__(var self) -> Self.IteratorOwnedType where conforms_to(Self.V, Deinitable):
        """Consumes the map, yielding `(key, value)` tuples."""
        var first = self._first()
        return {rebind_var[HopSlotMap[downcast[Self.V, _DropValue], Self.K]](self^), first}

    def items(ref self) -> _HopIter[Self.K, Self.V, origin_of(self)]:
        """Iterates over `Item`s in arbitrary order, hopping over blocks of
        vacant slots. Values are mutable if `self` is."""
        return {
            self._slots.meta_ptr(),
            self._free.unsafe_ptr()
            .unsafe_mut_cast[False]()
            .unsafe_origin_cast[ImmUntrackedOrigin](),
            self._ptr(0),
            self._first(),
            len(self),
        }

    def keys(ref self) -> _HopKeysIter[Self.K, Self.V, origin_of(self)]:
        return {self.items()}

    def values(
        ref self,
    ) -> _HopValuesIter[
        Self.K, downcast[Self.V, Copyable], origin_of(self)
    ] where conforms_to(Self.V, Copyable):
        """Iterates over references to the values. Requires `Copyable`
        values; use `items()` otherwise."""
        return {
            rebind[
                _HopIter[Self.K, downcast[Self.V, Copyable], origin_of(self)]
            ](self.items())
        }

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
struct _HopIter[
    mut: Bool, //, K: Key, V: AnyType, origin: Origin[mut=mut]
](ImplicitlyCopyable, Iterable, Iterator):
    comptime Element = Item[Self.K, Self.V, Self.origin]
    comptime IteratorType[
        iterable_mut: Bool, //, iterable_origin: Origin[mut=iterable_mut]
    ]: Iterator = Self

    var _meta: Pointer[_Meta, ImmUntrackedOrigin]
    var _free: Pointer[_FreeListEntry, ImmUntrackedOrigin]
    var _values: Pointer[Self.V, Self.origin]
    var _cur: Int
    var _num_left: Int

    def __iter__(ref self) -> Self.IteratorType[origin_of(self)]:
        return self.copy()

    def __next__(mut self) raises StopIteration -> Self.Element:
        # `_num_left` guarantees there is another element.
        if self._num_left == 0:
            raise StopIteration()
        self._num_left -= 1
        var idx = self._cur
        if not self._meta[unsafe_offset=idx].occupied():
            idx = Int(self._free[unsafe_offset=idx].other_end) + 1
        self._cur = idx + 1
        var version = self._meta[unsafe_offset=idx].version
        return Item(
            Self.K(data=KeyData.new(UInt32(idx), version)),
            self._values.unsafe_offset(idx),
        )

    def bounds(self) -> Tuple[Int, Optional[Int]]:
        return (self._num_left, {self._num_left})


@fieldwise_init
struct _HopKeysIter[
    mut: Bool, //, K: Key, V: AnyType, origin: Origin[mut=mut]
](ImplicitlyCopyable, Iterable, Iterator):
    comptime Element = Self.K
    comptime IteratorType[
        iterable_mut: Bool, //, iterable_origin: Origin[mut=iterable_mut]
    ]: Iterator = Self

    var _inner: _HopIter[Self.K, Self.V, Self.origin]

    def __iter__(ref self) -> Self.IteratorType[origin_of(self)]:
        return self.copy()

    def __next__(mut self) raises StopIteration -> Self.Element:
        return self._inner.__next__().key

    def bounds(self) -> Tuple[Int, Optional[Int]]:
        return self._inner.bounds()


@fieldwise_init
struct _HopValuesIter[
    mut: Bool, //, K: Key, V: Copyable, origin: Origin[mut=mut]
](ImplicitlyCopyable, Iterable, Iterator):
    comptime Element = Self.V
    comptime IteratorType[
        iterable_mut: Bool, //, iterable_origin: Origin[mut=iterable_mut]
    ]: Iterator = Self

    var _inner: _HopIter[Self.K, Self.V, Self.origin]

    def __iter__(ref self) -> Self.IteratorType[origin_of(self)]:
        return self.copy()

    def __next__(mut self) raises StopIteration -> ref[Self.origin] Self.Element:
        return self._inner.__next__()._ptr[]

    def bounds(self) -> Tuple[Int, Optional[Int]]:
        return self._inner.bounds()


@fieldwise_init
struct _HopDrain[
    V: _DropValue, K: Key, origin: MutOrigin](
    IterableOwned, Iterator
):
    comptime Element = Tuple[Self.K, Self.V]
    comptime IteratorOwnedType: Iterator = Self

    var _sm: Pointer[HopSlotMap[Self.V, Self.K], Self.origin]
    var _cur: Int

    def __iter__(var self) -> Self:
        return self^

    def __next__(mut self) raises StopIteration -> Self.Element:
        ref sm = self._sm[]
        if len(sm) == 0:
            raise StopIteration()
        # Skip ahead to the next element. Must happen before removing.
        var idx = self._cur
        self._cur = sm._after(idx)
        var key = Self.K(data=KeyData.new(UInt32(idx), sm._slots.version(idx)))
        return (key, sm._remove_from_slot(idx))

    def bounds(self) -> Tuple[Int, Optional[Int]]:
        return (len(self._sm[]), {len(self._sm[])})

    def __deinit__(deinit self):
        self._sm[].clear()


@fieldwise_init
struct _HopIntoIter[V: _DropValue, K: Key](Iterator, Movable):
    comptime Element = Tuple[Self.K, Self.V]

    var _sm: HopSlotMap[Self.V, Self.K]
    var _cur: Int

    def __next__(mut self) raises StopIteration -> Self.Element:
        if len(self._sm) == 0:
            raise StopIteration()
        var idx = self._cur
        self._cur = self._sm._after(idx)
        var key = Self.K(
            data=KeyData.new(UInt32(idx), self._sm._slots.version(idx))
        )
        return (key, self._sm._remove_from_slot(idx))

    def bounds(self) -> Tuple[Int, Optional[Int]]:
        return (len(self._sm), {len(self._sm)})
