"""Pieces shared by the slot map implementations."""

from std.memory import (
    Allocation,
    Layout,
    dealloc,
    unsafe_memcpy,
    unsafe_memset_zero,
)
from std.traits import (
    IsTriviallyCopyable,
    IsTriviallyDeinitable,
    IsTriviallyMovable,
)

from .key import Key, KeyData

comptime Value = Movable
"""The requirements on values stored in any slot map. Values may be linear
(not `Deinitable`); the operations that would destroy values are then
unavailable, and the map must be destroyed with `deinit_with()`."""

comptime _DropValue = Movable & Deinitable
"""Values that can be dropped: needed by drains and owned iterators."""

comptime _MAX_SLOTS: Int = 4294967295
"""`UInt32.MAX` as an `Int` (`Int(UInt32.MAX)` currently folds to -1)."""


trait SlotMapLike(Defaultable, Deinitable, Iterable, Movable, Sized):
    """The API shared by `SlotMap`, `HopSlotMap` and `DenseSlotMap`, for
    code that works with any of them.

    Only maps of `Deinitable` values conform. Iterating yields
    `Item[KeyType, ValueType, origin]`; traits can't state element types, so
    generic code `rebind`s the elements.

    Left out:
    - `insert_with_key`, `try_insert_with_key` and `retain`: the compiler
      can't yet match a trait method whose closure parameter type mentions
      the trait's associated types.
    - `drain` and owned iteration: they only exist for `Deinitable` values,
      and a trait can't require a conditional member.
    """

    comptime KeyType: Key
    comptime ValueType: Value

    def __init__(out self, *, capacity: Int):
        ...

    def __contains__(self, key: Self.KeyType) -> Bool:
        ...

    def capacity(self) -> Int:
        ...

    def reserve(mut self, additional: Int):
        ...

    def insert(mut self, var value: Self.ValueType) -> Self.KeyType:
        ...

    def remove(mut self, key: Self.KeyType) -> Optional[Self.ValueType]:
        ...

    def clear(mut self):
        ...

    def get_ptr(
        ref self, key: Self.KeyType
    ) -> OptionalPointer[Self.ValueType, origin_of(self)]:
        ...

    def get_disjoint_mut[
        origin: MutOrigin, //, N: Int
    ](ref[origin] self, keys: Array[Self.KeyType, N]) -> Optional[
        Array[Pointer[Self.ValueType, origin], N]
    ]:
        ...


@explicit_destroy(
    "A `Detached` value holds its slot out of the free list. Give it back with"
    " `map.reattach(d^)`, or free the slot and keep the value with"
    " `map.release(d^)`"
)
struct Detached[V: Value, K: Key](not Deinitable, Movable):
    """A value taken out of a slot map with `detach()`, together with its
    reserved slot.

    Its key stays invalid, and the slot is not reused, until the value is
    given back with `reattach()`. `Detached` is a linear type: the compiler
    rejects code that drops one, so a detached slot can't be leaked by
    accident. To keep the value but give up the slot, call `release()`.
    """

    var value: Self.V
    """The detached value. It may be modified before reattaching."""
    var _key: Self.K

    def __init__(out self, var value: Self.V, key: Self.K):
        self.value = value^
        self._key = key

    def key(self) -> Self.K:
        """The key the value had, which `reattach()` makes valid again."""
        return self._key

    def _into_value(deinit self) -> Self.V:
        return self.value^

    def unsafe_forget(deinit self) -> Self.V:
        """Returns the value and abandons the slot: it stays reserved forever
        and is never reused. Only for when the map itself is gone."""
        return self.value^


@fieldwise_init
struct _Meta(ImplicitlyCopyable, Writable):
    """Per-slot bookkeeping. An odd version means the slot is occupied.

    `next_free` is the next slot in the freelist when vacant (or
    `UInt32.MAX` when detached). `DenseSlotMap` reuses it as the index into
    its dense arrays when occupied.
    """

    var version: UInt32
    var next_free: UInt32

    @inline(.always)
    def occupied(self) -> Bool:
        return self.version & 1 == 1


@fieldwise_init
struct Item[mut: Bool, //, K: Key, V: AnyType, origin: Origin[mut=mut]](
    ImplicitlyCopyable
):
    """A key and a reference to its value, yielded when iterating a map.

    ```mojo
    for item in sm:
        print(item.key, item.value())
    for item in sm:          # a mutable map iterates mutably
        item.value() += 1
    ```
    """

    var key: Self.K
    var _ptr: Pointer[Self.V, Self.origin]

    @inline(.always)
    def value(self) -> ref[Self.origin] Self.V:
        return self._ptr[]


# ===-----------------------------------------------------------------------===#
# Iterators over "split" slot storage: a metadata array plus a value array in
# which only the slots with an odd version hold a value. Used by `SlotMap`
# and `SecondaryMap`.
# ===-----------------------------------------------------------------------===#


@fieldwise_init
struct _SlotIter[
    mut: Bool, //, K: Key, V: Movable, origin: Origin[mut=mut]
](ImplicitlyCopyable, Iterable, Iterator):
    comptime Element = Item[Self.K, Self.V, Self.origin]
    comptime IteratorType[
        iterable_mut: Bool, //, iterable_origin: Origin[mut=iterable_mut]
    ]: Iterator = Self

    var _slots: Pointer[_RawSlot[Self.V], Self.origin]
    var _num_slots: Int
    var _cur: Int
    var _num_left: Int

    def __iter__(ref self) -> Self.IteratorType[origin_of(self)]:
        return self.copy()

    def __next__(mut self) raises StopIteration -> Self.Element:
        # Fast path first: the common case (the next slot is occupied) is
        # straight-line code, so the consumer's loop body stays one tight
        # loop. Only a vacant slot enters the skip loop.
        var slots = self._slots
        var i = self._cur
        var n = self._num_slots
        if i >= n:
            raise StopIteration()
        var version = slots[unsafe_offset=i].meta.version
        if version & 1 == 0:
            i = _skip_vacant(slots, i + 1, n)
            if i >= n:
                self._cur = i
                raise StopIteration()
            version = slots[unsafe_offset=i].meta.version
        self._cur = i + 1
        self._num_left -= 1
        return Item(
            Self.K(data=KeyData.new(UInt32(i), version)),
            Pointer(to=slots[unsafe_offset=i].value).unsafe_origin_cast[
                Self.origin
            ](),
        )

    def bounds(self) -> Tuple[Int, Optional[Int]]:
        return (self._num_left, {self._num_left})


@inline(.never)
def _skip_vacant[
    V: Movable, origin: Origin
](slots: Pointer[_RawSlot[V], origin], start: Int, n: Int) -> Int:
    """Returns the index of the first occupied slot at or after `start`, or
    `n` if there is none."""
    var i = start
    while i < n and slots[unsafe_offset=i].meta.version & 1 == 0:
        i += 1
    return i


@fieldwise_init
struct _SlotKeysIter[
    mut: Bool, //, K: Key, V: Movable, origin: Origin[mut=mut]
](ImplicitlyCopyable, Iterable, Iterator):
    comptime Element = Self.K
    comptime IteratorType[
        iterable_mut: Bool, //, iterable_origin: Origin[mut=iterable_mut]
    ]: Iterator = Self

    var _inner: _SlotIter[Self.K, Self.V, Self.origin]

    def __iter__(ref self) -> Self.IteratorType[origin_of(self)]:
        return self.copy()

    def __next__(mut self) raises StopIteration -> Self.Element:
        return self._inner.__next__().key

    def bounds(self) -> Tuple[Int, Optional[Int]]:
        return self._inner.bounds()


@fieldwise_init
struct _SlotValuesIter[
    mut: Bool, //, K: Key, V: Copyable, origin: Origin[mut=mut]
](ImplicitlyCopyable, Iterable, Iterator):
    comptime Element = Self.V
    comptime IteratorType[
        iterable_mut: Bool, //, iterable_origin: Origin[mut=iterable_mut]
    ]: Iterator = Self

    var _inner: _SlotIter[Self.K, Self.V, Self.origin]

    def __iter__(ref self) -> Self.IteratorType[origin_of(self)]:
        return self.copy()

    def __next__(mut self) raises StopIteration -> ref[Self.origin] Self.Element:
        return self._inner.__next__()._ptr[]

    def bounds(self) -> Tuple[Int, Optional[Int]]:
        return self._inner.bounds()


# ===-----------------------------------------------------------------------===#
# Slot storage: metadata and value interleaved, like Rust's `Slot<T>`.
# ===-----------------------------------------------------------------------===#


struct _RawSlot[V: Movable](not Deinitable):
    """One slot: its metadata followed by its value storage. `value` is
    initialized iff `meta` is occupied (odd version), so a `_RawSlot` is only
    ever handled through pointers, never as a whole value.

    Keeping both in one struct means a lookup touches one cache line, as in
    Rust, where the slot is `(version, union { value, next_free })`.
    """

    var meta: _Meta
    var value: Self.V


@explicit_destroy(
    "Use `deinit_with()` to destroy slots holding non-`Deinitable` values"
)
struct _Slots[V: Value](
    Copyable where conforms_to(V, Copyable),
    Deinitable where conforms_to(V, Deinitable),
    Movable,
    Sized,
):
    """A growable array of `_RawSlot`s. Owners keep the occupancy bit in
    sync with the values they write and take.

    The storage is a linear `Allocation`, so the compiler checks that it is
    deallocated on every path. Trivially movable/copyable values are moved
    and copied with `memcpy`.
    """

    comptime Slot = _RawSlot[Self.V]

    var _alloc: Allocation[Self.Slot]
    var _len: Int

    def __init__(out self, *, capacity: Int):
        self._alloc = alloc(Layout[Self.Slot](count=capacity))
        self._len = 0

    def __init__(out self, *, copy: Self) where conforms_to(Self.V, Copyable):
        self._alloc = alloc(Layout[Self.Slot](count=copy.capacity()))
        self._len = copy._len
        comptime if IsTriviallyCopyable[Self.V]:
            unsafe_memcpy(
                dest=self._alloc.unsafe_ptr(),
                src=copy._alloc.unsafe_ptr(),
                count=self._len,
            )
        else:
            for i in range(self._len):
                ref src = copy._alloc.unsafe_ptr()[unsafe_offset=i]
                ref dst = self._alloc.unsafe_ptr()[unsafe_offset=i]
                dst.meta = src.meta
                if src.meta.occupied():
                    Pointer(to=dst.value).unsafe_write(copy=src.value)

    def __deinit__(deinit self) where conforms_to(Self.V, Deinitable):
        # Like Rust's `needs_drop`: values with no destructor (e.g. `Int`)
        # skip the walk over every slot.
        comptime if not IsTriviallyDeinitable[Self.V]:
            for i in range(self._len):
                if self.meta(i).occupied():
                    self.raw(i).unsafe_deinit_pointee()
        dealloc(self._alloc^)

    def deinit_with(deinit self, deinit_func: Some[def(var Self.V)]):
        """Destroys the slots, passing each stored value to `deinit_func`."""
        for i in range(self._len):
            if self.meta(i).occupied():
                deinit_func(self.raw(i).unsafe_take_pointee())
        dealloc(self._alloc^)

    @inline(.always)
    def __len__(self) -> Int:
        return self._len

    @inline(.always)
    def capacity(self) -> Int:
        return len(self._alloc.unsafe_span())

    @inline(.always)
    def meta(ref self, idx: Int) -> ref[origin_of(self)] _Meta:
        return Pointer(
            to=self.slots_ptr()[unsafe_offset=idx].meta
        ).unsafe_origin_cast[origin_of(self)]()[]

    @inline(.always)
    def version(self, idx: Int) -> UInt32:
        return self.meta(idx).version

    def reserve(mut self, new_capacity: Int):
        """Grows to hold at least `new_capacity` slots (exactly, if growing).
        """
        if new_capacity <= self.capacity():
            return
        var new_alloc = alloc(Layout[Self.Slot](count=new_capacity))
        comptime if IsTriviallyMovable[Self.V]:
            unsafe_memcpy(
                dest=new_alloc.unsafe_ptr(),
                src=self._alloc.unsafe_ptr(),
                count=self._len,
            )
        else:
            for i in range(self._len):
                ref src = self._alloc.unsafe_ptr()[unsafe_offset=i]
                ref dst = new_alloc.unsafe_ptr()[unsafe_offset=i]
                dst.meta = src.meta
                if src.meta.occupied():
                    Pointer(to=dst.value).unsafe_write(
                        Pointer(to=src.value).unsafe_take_pointee()
                    )
        swap(self._alloc, new_alloc)
        dealloc(new_alloc^)  # The old storage, now empty.

    @inline(.always)
    def _grow_amortized(mut self, min_capacity: Int):
        # Never grow by less than 16 slots: doubling from one slot costs a
        # dozen reallocations for the first thousand inserts.
        if min_capacity > self.capacity():
            # Nested two-argument max on purpose: the variadic max() nearly
            # doubled the cost of every insert, not just the growing ones.
            self.reserve(max(max(2 * self.capacity(), min_capacity), 16))

    def push_vacant(mut self, meta: _Meta):
        """Appends a slot, which must be vacant (even version)."""
        self._grow_amortized(self._len + 1)
        self.meta(self._len) = meta
        self._len += 1

    def push_occupied(mut self, meta: _Meta, var value: Self.V):
        """Appends an occupied slot (odd version) holding `value`."""
        self._grow_amortized(self._len + 1)
        self.raw(self._len).unsafe_write(value^)
        self.meta(self._len) = meta
        self._len += 1

    def extend_vacant(mut self, new_len: Int):
        """Appends vacant slots (version 0) until there are `new_len`."""
        if new_len <= self._len:
            return
        self._grow_amortized(new_len)
        # A vacant slot is all-zero metadata; the value bytes are don't-care,
        # so the whole range is one memset rather than a strided loop.
        unsafe_memset_zero(
            self._alloc.unsafe_ptr().unsafe_offset(self._len),
            new_len - self._len,
        )
        self._len = new_len

    @inline(.always)
    def write(mut self, idx: Int, var value: Self.V):
        """Initializes the value of a slot. The caller then marks it
        occupied."""
        self.raw(idx).unsafe_write(value^)

    @inline(.always)
    def take(mut self, idx: Int) -> Self.V:
        """Moves the value out of a slot. The caller then marks it vacant."""
        return self.raw(idx).unsafe_take_pointee()

    @inline(.always)
    def ptr(ref self, idx: Int) -> Pointer[Self.V, origin_of(self)]:
        return self.raw(idx).unsafe_mut_cast[
            origin_of(self).mut
        ]().unsafe_origin_cast[origin_of(self)]()

    @inline(.always)
    def slots_ptr(ref self) -> Pointer[Self.Slot, origin_of(self)]:
        """A pointer to the slot array with the caller's origin, for
        iterators."""
        return (
            self._alloc.unsafe_ptr()
            .unsafe_mut_cast[origin_of(self).mut]()
            .unsafe_origin_cast[origin_of(self)]()
        )

    @inline(.always)
    def raw(self, idx: Int) -> Pointer[Self.V, MutUntrackedOrigin]:
        """An untracked pointer to slot `idx`'s value storage."""
        return Pointer(to=self._alloc.unsafe_ptr()[unsafe_offset=idx].value)
            .unsafe_mut_cast[True]()
            .unsafe_origin_cast[MutUntrackedOrigin]()
