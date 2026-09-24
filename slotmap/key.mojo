"""Keys for slot maps."""

from std.hashlib import Hasher

comptime _NULL_IDX = UInt32.MAX


@fieldwise_init
struct KeyData(Comparable, Defaultable, Equatable, Hashable, ImplicitlyCopyable, Writable):
    """The actual data stored in a `Key`.

    Keys are ordered so they can be sorted, but the order is unspecified.
    """

    var idx: UInt32
    var version: UInt32
    """Always odd."""

    def __init__(out self):
        """Creates the null key data."""
        self = Self.null()

    @staticmethod
    def new(idx: UInt32, version: UInt32) -> Self:
        return Self(idx, version | 1)

    @staticmethod
    def null() -> Self:
        return Self(_NULL_IDX, 1)

    def is_null(self) -> Bool:
        return self.idx == _NULL_IDX

    def as_ffi(self) -> UInt64:
        """Returns the key data as a 64-bit integer. Passing it to `from_ffi`
        returns a key equal to the original."""
        return (UInt64(self.version) << 32) | UInt64(self.idx)

    @staticmethod
    def from_ffi(value: UInt64) -> Self:
        """Iff `value` came from `k.as_ffi()`, returns a key equal to `k`.
        Otherwise the result is safe but unspecified."""
        return Self.new(UInt32(value & 0xFFFF_FFFF), UInt32(value >> 32))

    def __eq__(self, other: Self) -> Bool:
        return self.idx == other.idx and self.version == other.version

    def __lt__(self, other: Self) -> Bool:
        return self.as_ffi() < other.as_ffi()

    def __hash__(self, mut hasher: Some[Hasher]):
        # One u64 rather than two u32 writes, like the Rust crate.
        self.as_ffi().__hash__(hasher)

    def write_to(self, mut writer: Some[Writer]):
        if self.is_null():
            writer.write("null")
        else:
            writer.write(self.idx, "v", self.version)


trait Key(Comparable, Defaultable, Deinitable, Equatable, Hashable, ImplicitlyCopyable, Writable):
    """Key used to access stored values in a slot map.

    Do not use a key from one slot map in another. Use a distinct key type per
    map (see `TypedKey`) to prevent that at compile time.

    Implementations must behave exactly as if operating on a `KeyData`
    directly: `Self(data=d).data() == d`, and `Self()` is the null key.
    """

    def __init__(out self, *, data: KeyData):
        ...

    def data(self) -> KeyData:
        ...

    @staticmethod
    def null() -> Self:
        """Creates a key that is always invalid and distinct from any non-null
        key. A null key is safe to use with any slot map."""
        return Self(data=KeyData.null())

    def is_null(self) -> Bool:
        """Checks if a key is null. There is only a single null key."""
        return self.data().is_null()


struct TypedKey[Tag: AnyType](Key):
    """A key type made distinct by its `Tag`.

    This replaces Rust's `new_key_type!` macro:

    ```mojo
    struct PlayerTag: pass
    comptime PlayerKey = TypedKey[PlayerTag]
    ```
    """

    var _data: KeyData

    def __init__(out self):
        """Creates a null key."""
        self._data = KeyData.null()

    def __init__(out self, *, data: KeyData):
        self._data = data

    def data(self) -> KeyData:
        return self._data

    def __eq__(self, other: Self) -> Bool:
        return self._data == other._data

    def __lt__(self, other: Self) -> Bool:
        return self._data < other._data

    def __hash__(self, mut hasher: Some[Hasher]):
        self._data.__hash__(hasher)

    def write_to(self, mut writer: Some[Writer]):
        self._data.write_to(writer)


struct _DefaultTag:
    pass


comptime DefaultKey = TypedKey[_DefaultTag]
"""The default slot map key type."""
