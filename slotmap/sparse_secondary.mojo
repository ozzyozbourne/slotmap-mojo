"""Contains the sparse secondary map implementation."""

from std.hashlib import Hasher, default_hasher
from std.builtin.rebind import downcast
from std.os import abort

from .key import DefaultKey, Key, KeyData
from ._common import Item, Value, _DropValue
from ._util import is_older_version
from .dense import _DenseIter


@explicit_destroy(
    "Use `deinit_with()` to destroy a map holding non-`Deinitable` values"
)
struct SparseSecondaryMap[
    V: Value, K: Key = DefaultKey, H: Hasher = default_hasher
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

    Like `SecondaryMap`, but backed by a hash map. Memory use is proportional
    to the number of stored elements, not the number of slots in the slot
    map. Use it to store data for a small part of a slot map. Outdated keys are
    handled like in `SecondaryMap`.

    `H` picks the hasher, replacing Rust's `BuildHasher` parameter.
    """

    comptime IteratorType[
        iterable_mut: Bool, //, iterable_origin: Origin[mut=iterable_mut]
    ]: Iterator = _DenseIter[Self.K, Self.V, iterable_origin]
    comptime IteratorOwnedType: Iterator where conforms_to(
        Self.V, Deinitable
    ) = _SparseIntoIter[Self.V, Self.K, Self.H]

    # Maps a slot index to the position of its key and value in the dense
    # `_keys` and `_values` lists. The stored key carries the version.
    var _index: Dict[UInt32, Int, Self.H]
    var _keys: List[Self.K]
    var _values: List[Self.V]

    def __init__(out self):
        """Constructs a new, empty sparse secondary map."""
        self._index = Dict[UInt32, Int, Self.H]()
        self._keys = List[Self.K]()
        self._values = List[Self.V]()

    def __init__(out self, *, capacity: Int):
        """Creates an empty map with room for `capacity` elements."""
        self._index = Dict[UInt32, Int, Self.H](capacity=capacity)
        self._keys = List[Self.K](capacity=capacity)
        self._values = List[Self.V](capacity=capacity)

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
        self._keys.reserve(len(self._keys) + additional)
        self._values.reserve(len(self._values) + additional)

    # ===------------------------------------------------------------------===#
    # Insertion and removal
    # ===------------------------------------------------------------------===#

    @inline(.always)
    def _pos(self, key: Self.K) -> Int:
        """Returns the dense position of `key`, or -1 if absent (any
        version)."""
        return self._index.find(key.data().idx).or_else(-1)

    @inline(.always)
    def _valid_pos(self, key: Self.K) -> Int:
        """Returns the dense position of exactly `key`, or -1."""
        var pos = self._pos(key)
        if pos >= 0 and self._keys.unsafe_get(pos).data() == key.data():
            return pos
        return -1

    def __contains__(self, key: Self.K) -> Bool:
        return self._valid_pos(key) >= 0

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
        var pos = self._pos(key)
        if pos < 0:
            self._index[kd.idx] = len(self._keys)
            self._keys.append(key)
            self._values.append(value^)
            return None

        var stored = self._keys.unsafe_get(pos).data().version
        if stored == kd.version:
            swap(self._values.unsafe_get(pos), value)
            return value^
        # Don't replace existing newer values.
        if is_older_version(kd.version, stored):
            return None
        self._keys.unsafe_get(pos) = key
        swap(self._values.unsafe_get(pos), value)
        return None  # `value` now holds the outdated value, dropped here.

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
        var pos = self._pos(key)
        if pos < 0:
            self._index[kd.idx] = len(self._keys)
            self._keys.append(key)
            self._values.append(value^)
            return None
        var stored = self._keys.unsafe_get(pos).data().version
        if stored != kd.version and is_older_version(kd.version, stored):
            return value^  # A newer key holds the slot.
        self._keys.unsafe_get(pos) = key
        swap(self._values.unsafe_get(pos), value)
        return value^

    def _remove_at(mut self, pos: Int) -> Self.V:
        """Removes the element at dense position `pos` by swapping the last
        element into its place."""
        var idx = self._keys.unsafe_get(pos).data().idx
        _ = self._index.pop(idx, -1)
        var last = len(self._keys) - 1
        if pos != last:
            self._keys.swap_elements(pos, last)
            self._values.swap_elements(pos, last)
            self._index[self._keys.unsafe_get(pos).data().idx] = pos
        _ = self._keys.pop()
        return self._values.pop()

    def remove(mut self, key: Self.K) -> Optional[Self.V]:
        """Removes a key, returning its value if it was present."""
        var pos = self._valid_pos(key)
        if pos < 0:
            return None
        return self._remove_at(pos)

    def retain(
        mut self, f: Some[def(Self.K, mut Self.V) -> Bool]
    ) where conforms_to(Self.V, Deinitable):
        """Keeps only the elements for which `f(key, value)` returns
        `True`."""
        var i = 0
        while i < len(self._keys):
            if f(self._keys.unsafe_get(i), self._values.unsafe_get(i)):
                i += 1
            else:
                # Don't advance: index `i` now holds the swapped-in element.
                _ = self._remove_at(i)

    def clear(mut self) where conforms_to(Self.V, Deinitable):
        """Removes all elements."""
        self._index.clear()
        self._keys.clear()
        self._values.clear()

    def _pop(mut self) -> Tuple[Self.K, Self.V]:
        var key = self._keys.pop()
        _ = self._index.pop(key.data().idx, -1)
        return (key, self._values.pop())

    def drain[
        origin: MutOrigin, //
    ](ref[origin] self) -> _SparseDrain[
        downcast[Self.V, _DropValue], Self.K, Self.H, origin
    ] where conforms_to(Self.V, Deinitable):
        """Removes all elements, yielding `(key, value)` tuples. Elements not
        consumed are removed when the iterator is destroyed."""
        return {
            rebind[
                Pointer[SparseSecondaryMap[downcast[Self.V, _DropValue], Self.K, Self.H], origin]
            ](Pointer(to=self))
        }

    # ===------------------------------------------------------------------===#
    # Access
    # ===------------------------------------------------------------------===#

    @inline(.always)
    def _values_ptr(ref self) -> Pointer[Self.V, origin_of(self)]:
        return self._values.unsafe_ptr().unsafe_mut_cast[
            origin_of(self).mut
        ]().unsafe_origin_cast[origin_of(self)]()

    def get(self, key: Self.K) -> Optional[Self.V] where conforms_to(
        Self.V, Copyable
    ):
        """Returns a copy of the value for `key`, if present."""
        var pos = self._valid_pos(key)
        if pos < 0:
            return None
        return self._values.unsafe_get(pos).copy()

    def get_ptr(
        ref self, key: Self.K
    ) -> OptionalPointer[Self.V, origin_of(self)]:
        """Returns a pointer to the value for `key`, or `None`."""
        var pos = self._valid_pos(key)
        if pos < 0:
            return None
        return self._values_ptr().unsafe_offset(pos)

    @__unsafe_nested_origins_read_only
    def unsafe_get(
        ref self, key: Self.K
    ) -> ref[origin_of(self)._get_owned_interior["value"]] Self.V:
        """Returns a reference to the value for `key` without checking that
        the version matches."""
        assert key in self, "invalid SparseSecondaryMap key used"
        return Pointer(
            to=self._values.unsafe_get(self._pos(key))
        )._get_ref_with_unsafe_interior_origin["value", origin_of(self)]()

    @__unsafe_nested_origins_read_only
    def __getitem__(
        ref self, key: Self.K
    ) -> ref[origin_of(self)._get_owned_interior["value"]] Self.V:
        """Returns a reference to the value for `key`. Aborts if the key is
        not present."""
        var pos = self._valid_pos(key)
        if pos < 0:
            abort("invalid SparseSecondaryMap key used")
        return Pointer(
            to=self._values.unsafe_get(pos)
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
            var pos = self._valid_pos(keys[i])
            if pos < 0:
                break
            positions[i] = pos
            # Make the stored version even so a duplicate key shows up as
            # invalid, since keys always have an odd version.
            ref stored = self._keys.unsafe_get(pos)
            stored = Self.K(
                data=KeyData(stored.data().idx, stored.data().version ^ 1)
            )
            i += 1
        for j in range(i):
            self._keys.unsafe_get(positions[j]) = keys[j]
        if i != N:
            return None
        var base = self._values_ptr().unsafe_origin_cast[origin]()
        var result = Array[Pointer[Self.V, origin], N](fill=base)
        for j in range(N):
            result[j] = base.unsafe_offset(positions[j])
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
        var pos = self._pos(key)
        if pos >= 0:
            var stored = self._keys.unsafe_get(pos).data().version
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

    def __iter__(var self) -> Self.IteratorOwnedType where conforms_to(Self.V, Deinitable):
        """Consumes the map, yielding `(key, value)` tuples."""
        return {
            rebind_var[SparseSecondaryMap[downcast[Self.V, _DropValue], Self.K, Self.H]](self^)
        }

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
        for i in range(len(self._keys)):
            if i:
                writer.write(", ")
            writer.write(
                self._keys.unsafe_get(i), ": ", self._values.unsafe_get(i)
            )
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
        return (
            map._values.unsafe_ptr()
            .unsafe_offset(map._pos(self._key))
            .unsafe_mut_cast[True]()
            .unsafe_origin_cast[Self.origin]()[]
        )

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
        return map._remove_at(map._pos(self._key))

    def remove_entry(var self) -> Tuple[Self.K, Self.V]:
        var key = self._key
        return (key, self^.remove())


@fieldwise_init
struct _SparseDrain[V: _DropValue, K: Key, H: Hasher, origin: MutOrigin](
    IterableOwned, Iterator
):
    comptime Element = Tuple[Self.K, Self.V]
    comptime IteratorOwnedType: Iterator = Self

    var _map: Pointer[SparseSecondaryMap[Self.V, Self.K, Self.H], Self.origin]

    def __iter__(var self) -> Self:
        return self^

    def __next__(mut self) raises StopIteration -> Self.Element:
        if len(self._map[]) == 0:
            raise StopIteration()
        return self._map[]._pop()

    def bounds(self) -> Tuple[Int, Optional[Int]]:
        return (len(self._map[]), {len(self._map[])})

    def __deinit__(deinit self):
        self._map[].clear()


@fieldwise_init
struct _SparseIntoIter[V: _DropValue, K: Key, H: Hasher](Iterator, Movable):
    comptime Element = Tuple[Self.K, Self.V]

    var _map: SparseSecondaryMap[Self.V, Self.K, Self.H]

    def __next__(mut self) raises StopIteration -> Self.Element:
        if len(self._map) == 0:
            raise StopIteration()
        return self._map._pop()

    def bounds(self) -> Tuple[Int, Optional[Int]]:
        return (len(self._map), {len(self._map)})
