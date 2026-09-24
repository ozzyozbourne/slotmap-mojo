"""Pieces shared by the slot map implementations."""

from std.memory import Allocation, Layout, dealloc
from std.traits import IsTriviallyDeinitable

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
    mut: Bool, //, K: Key, V: AnyType, origin: Origin[mut=mut]
](ImplicitlyCopyable, Iterable, Iterator):
    comptime Element = Item[Self.K, Self.V, Self.origin]
    comptime IteratorType[
        iterable_mut: Bool, //, iterable_origin: Origin[mut=iterable_mut]
    ]: Iterator = Self

    var _meta: Pointer[_Meta, ImmUntrackedOrigin]
    """Untracked: `_values` already carries the borrow of the map."""
    var _values: Pointer[Self.V, Self.origin]
    var _num_slots: Int
    var _cur: Int
    var _num_left: Int

    def __iter__(ref self) -> Self.IteratorType[origin_of(self)]:
        return self.copy()

    def __next__(mut self) raises StopIteration -> Self.Element:
        while self._cur < self._num_slots:
            var idx = self._cur
            self._cur += 1
            var version = self._meta[unsafe_offset=idx].version
            if version & 1 == 1:
                self._num_left -= 1
                return Item(
                    Self.K(data=KeyData.new(UInt32(idx), version)),
                    self._values.unsafe_offset(idx),
                )
        raise StopIteration()

    def bounds(self) -> Tuple[Int, Optional[Int]]:
        return (self._num_left, {self._num_left})


@fieldwise_init
struct _SlotKeysIter[
    mut: Bool, //, K: Key, V: AnyType, origin: Origin[mut=mut]
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
# Split slot storage.
# ===-----------------------------------------------------------------------===#


@explicit_destroy(
    "Use `deinit_with()` to destroy slots holding non-`Deinitable` values"
)
struct _Slots[V: Value](
    Copyable where conforms_to(V, Copyable),
    Deinitable where conforms_to(V, Deinitable),
    Movable,
    Sized,
):
    """A metadata array plus a value array of the same capacity. The value
    of slot `i` is initialized iff `meta[i]` is occupied (odd version).

    This replaces Rust's `union { value: ManuallyDrop<T>, next_free: u32 }`.
    Owners must keep the occupancy bit in sync with the values they write
    and take.

    The value array is a linear `Allocation`, so the compiler checks that it
    is deallocated on every path.
    """

    var meta: List[_Meta]
    var _alloc: Allocation[Self.V]

    def __init__(out self, *, capacity: Int):
        self.meta = List[_Meta](capacity=capacity)
        self._alloc = alloc(Layout[Self.V](count=capacity))

    def __init__(out self, *, copy: Self) where conforms_to(Self.V, Copyable):
        self.meta = copy.meta.copy()
        self._alloc = alloc(Layout[Self.V](count=copy.capacity()))
        for i in range(len(self.meta)):
            if self.meta.unsafe_get(i).occupied():
                self.raw(i).unsafe_write(copy=copy.raw(i)[])

    def __deinit__(deinit self) where conforms_to(Self.V, Deinitable):
        # Like Rust's `needs_drop`: values with no destructor (e.g. `Int`)
        # skip the walk over every slot.
        comptime if not IsTriviallyDeinitable[Self.V]:
            for i in range(len(self.meta)):
                if self.meta.unsafe_get(i).occupied():
                    self.raw(i).unsafe_deinit_pointee()
        dealloc(self._alloc^)

    def deinit_with(deinit self, deinit_func: Some[def(var Self.V)]):
        """Destroys the slots, passing each stored value to `deinit_func`."""
        for i in range(len(self.meta)):
            if self.meta.unsafe_get(i).occupied():
                deinit_func(self.raw(i).unsafe_take_pointee())
        dealloc(self._alloc^)

    @inline(.always)
    def __len__(self) -> Int:
        return len(self.meta)

    @inline(.always)
    def capacity(self) -> Int:
        return len(self._alloc.unsafe_span())

    @inline(.always)
    def version(self, idx: Int) -> UInt32:
        return self.meta.unsafe_get(idx).version

    def reserve(mut self, new_capacity: Int):
        """Grows to hold at least `new_capacity` slots (exactly, if growing).
        """
        if new_capacity <= self.capacity():
            return
        self.meta.reserve(new_capacity)
        var new_alloc = alloc(Layout[Self.V](count=new_capacity))
        var dest = new_alloc.unsafe_ptr()
        for i in range(len(self.meta)):
            if self.meta.unsafe_get(i).occupied():
                dest.unsafe_offset(i).unsafe_write(
                    self.raw(i).unsafe_take_pointee()
                )
        swap(self._alloc, new_alloc)
        dealloc(new_alloc^)  # The old storage, now empty.

    def push_vacant(mut self, meta: _Meta):
        """Appends a slot, which must be vacant (even version)."""
        if len(self.meta) == self.capacity():
            self.reserve(max(2 * self.capacity(), len(self.meta) + 1))
        self.meta.append(meta)

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
    def meta_ptr(self) -> Pointer[_Meta, ImmUntrackedOrigin]:
        return (
            self.meta.unsafe_ptr()
            .unsafe_mut_cast[False]()
            .unsafe_origin_cast[ImmUntrackedOrigin]()
        )

    @inline(.always)
    def raw(self, idx: Int) -> Pointer[Self.V, MutUntrackedOrigin]:
        """An untracked pointer to slot `idx`'s value storage."""
        return (
            self._alloc.unsafe_ptr()
            .unsafe_mut_cast[True]()
            .unsafe_origin_cast[MutUntrackedOrigin]()
            .unsafe_offset(idx)
        )
