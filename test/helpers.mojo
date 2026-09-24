"""Shared helpers for the slotmap tests."""


struct DropCounter(Copyable, Writable):
    """Increments a shared counter when destroyed. Like Rust's `CountDrop`."""

    var counter: Pointer[Int, MutUntrackedOrigin]

    def __init__(out self, counter: Pointer[Int, MutUntrackedOrigin]):
        self.counter = counter

    def __init__(out self, *, copy: Self):
        self.counter = copy.counter

    def __deinit__(deinit self):
        self.counter[] += 1

    def write_to(self, mut writer: Some[Writer]):
        writer.write("DropCounter")


struct MoveOnly(Movable, Writable):
    """A value that cannot be copied."""

    var data: Int

    def __init__(out self, data: Int):
        self.data = data


struct Rng(Movable):
    """xorshift64*: a small deterministic RNG for randomized tests."""

    var state: UInt64

    def __init__(out self, seed: UInt64):
        self.state = seed * 0x9E3779B97F4A7C15 + 1

    def next(mut self) -> UInt64:
        self.state ^= self.state >> 12
        self.state ^= self.state << 25
        self.state ^= self.state >> 27
        return self.state * 0x2545F4914F6CDD1D

    def below(mut self, n: Int) -> Int:
        return Int(self.next() % UInt64(n))


def sorted_ints(var xs: List[Int]) -> List[Int]:
    sort(xs)
    return xs^


# ===-----------------------------------------------------------------------===#
# Generic helpers for code written against `SlotMapLike`.
#
# The trait leaves out the closure-taking methods, so these dispatch at compile
# time on the concrete map type and `rebind` to it. The `comptime assert`s give
# the compiler evidence that the closure's types match. They name the closure
# type's `M` parameter, so the closure must be defined in a function whose map
# type parameter is called `M`.
# ===-----------------------------------------------------------------------===#

from slotmap import DenseSlotMap, HopSlotMap, Item, SlotMap, SlotMapLike


def retain_any[
    M: SlotMapLike, F: def(M.KeyType, mut M.ValueType) -> Bool
](mut m: M, f: F) where conforms_to(M.ValueType, Deinitable):
    comptime assert F.M.KeyType == M.KeyType
    comptime assert F.M.ValueType == M.ValueType
    comptime if M == SlotMap[M.ValueType, M.KeyType]:
        rebind[SlotMap[M.ValueType, M.KeyType]](m).retain(f)
    elif M == HopSlotMap[M.ValueType, M.KeyType]:
        rebind[HopSlotMap[M.ValueType, M.KeyType]](m).retain(f)
    elif M == DenseSlotMap[M.ValueType, M.KeyType]:
        rebind[DenseSlotMap[M.ValueType, M.KeyType]](m).retain(f)
    else:
        comptime assert False, "retain_any: unsupported map type"


def insert_with_key_any[
    M: SlotMapLike, F: def(M.KeyType) -> M.ValueType
](mut m: M, f: F) -> M.KeyType where conforms_to(M.ValueType, Deinitable):
    comptime assert F.M.KeyType == M.KeyType
    comptime assert F.M.ValueType == M.ValueType
    comptime if M == SlotMap[M.ValueType, M.KeyType]:
        return rebind[SlotMap[M.ValueType, M.KeyType]](m).insert_with_key(f)
    elif M == HopSlotMap[M.ValueType, M.KeyType]:
        return rebind[HopSlotMap[M.ValueType, M.KeyType]](m).insert_with_key(f)
    elif M == DenseSlotMap[M.ValueType, M.KeyType]:
        return rebind[DenseSlotMap[M.ValueType, M.KeyType]](m).insert_with_key(
            f
        )
    else:
        comptime assert False, "insert_with_key_any: unsupported map type"


def try_insert_with_key_any[
    M: SlotMapLike, F: def(M.KeyType) raises -> M.ValueType
](mut m: M, f: F) raises -> M.KeyType where conforms_to(M.ValueType, Deinitable):
    comptime assert F.M.KeyType == M.KeyType
    comptime assert F.M.ValueType == M.ValueType
    comptime if M == SlotMap[M.ValueType, M.KeyType]:
        return rebind[SlotMap[M.ValueType, M.KeyType]](m).try_insert_with_key(f)
    elif M == HopSlotMap[M.ValueType, M.KeyType]:
        return rebind[HopSlotMap[M.ValueType, M.KeyType]](
            m
        ).try_insert_with_key(f)
    elif M == DenseSlotMap[M.ValueType, M.KeyType]:
        return rebind[DenseSlotMap[M.ValueType, M.KeyType]](
            m
        ).try_insert_with_key(f)
    else:
        comptime assert False, "try_insert_with_key_any: unsupported map type"


def next_or_none[I: Iterator](mut it: I) -> Optional[I.Element]:
    try:
        return it.__next__()
    except StopIteration:
        return None


# Iteration through the trait: `Iterator.Element` is only known to be
# `Movable`, so generic code can't destroy loop elements. These helpers iterate
# the concrete map instead and return plain lists. `T` is the value type the
# caller expects (it must be `M.ValueType`).


def items_any[
    M: SlotMapLike, T: AnyType
](ref m: M) -> List[Item[M.KeyType, T, origin_of(m)]] where conforms_to(M.ValueType, Deinitable):
    """Returns every `Item` of the map."""
    var out = List[Item[M.KeyType, T, origin_of(m)]]()
    comptime if M == SlotMap[M.ValueType, M.KeyType]:
        for it in rebind[SlotMap[M.ValueType, M.KeyType]](m):
            out.append(rebind[Item[M.KeyType, T, origin_of(m)]](it))
    elif M == HopSlotMap[M.ValueType, M.KeyType]:
        for it in rebind[HopSlotMap[M.ValueType, M.KeyType]](m):
            out.append(rebind[Item[M.KeyType, T, origin_of(m)]](it))
    elif M == DenseSlotMap[M.ValueType, M.KeyType]:
        for it in rebind[DenseSlotMap[M.ValueType, M.KeyType]](m):
            out.append(rebind[Item[M.KeyType, T, origin_of(m)]](it))
    else:
        comptime assert False, "items_any: unsupported map type"
    return out^


def _take[
    I: Iterator, K: Movable, T: Movable
](mut it: I, limit: Int, mut out: List[Tuple[K, T]]):
    for _ in range(limit):
        try:
            out.append(rebind_var[Tuple[K, T]](it.__next__()))
        except StopIteration:
            return


def drain_any[
    M: SlotMapLike, T: Movable & Deinitable
](mut m: M, limit: Int = Int.MAX) -> List[Tuple[M.KeyType, T]] where conforms_to(M.ValueType, Deinitable):
    """Drains the map, returning up to `limit` of the drained elements. The
    drain iterator is then dropped, which removes the rest."""
    var out = List[Tuple[M.KeyType, T]]()
    comptime if M == SlotMap[M.ValueType, M.KeyType]:
        var d = rebind[SlotMap[M.ValueType, M.KeyType]](m).drain()
        _take(d, limit, out)
    elif M == HopSlotMap[M.ValueType, M.KeyType]:
        var d = rebind[HopSlotMap[M.ValueType, M.KeyType]](m).drain()
        _take(d, limit, out)
    elif M == DenseSlotMap[M.ValueType, M.KeyType]:
        var d = rebind[DenseSlotMap[M.ValueType, M.KeyType]](m).drain()
        _take(d, limit, out)
    else:
        comptime assert False, "drain_any: unsupported map type"
    return out^


def into_iter_any[
    M: SlotMapLike, T: Movable & Deinitable
](var m: M, limit: Int = Int.MAX) -> List[Tuple[M.KeyType, T]] where conforms_to(M.ValueType, Deinitable):
    """Consumes the map with its owned iterator, returning up to `limit`
    elements. The rest are destroyed with the iterator."""
    var out = List[Tuple[M.KeyType, T]]()
    comptime if M == SlotMap[M.ValueType, M.KeyType]:
        var it = rebind_var[SlotMap[M.ValueType, M.KeyType]](m^).__iter__()
        _take(it, limit, out)
    elif M == HopSlotMap[M.ValueType, M.KeyType]:
        var it = rebind_var[HopSlotMap[M.ValueType, M.KeyType]](m^).__iter__()
        _take(it, limit, out)
    elif M == DenseSlotMap[M.ValueType, M.KeyType]:
        var it = rebind_var[DenseSlotMap[M.ValueType, M.KeyType]](
            m^
        ).__iter__()
        _take(it, limit, out)
    else:
        comptime assert False, "into_iter_any: unsupported map type"
    return out^


# ===-----------------------------------------------------------------------===#
# A linear value type.
# ===-----------------------------------------------------------------------===#


@explicit_destroy("A `Resource` must be closed with `.close()`")
struct Resource(not Deinitable, Movable):
    """A value that can't be dropped implicitly, like a file handle. Closing
    it increments a shared counter."""

    var id: Int
    var _closed: Pointer[Int, MutUntrackedOrigin]

    def __init__(out self, id: Int, closed: Pointer[Int, MutUntrackedOrigin]):
        self.id = id
        self._closed = closed

    def close(deinit self):
        self._closed[] += 1


def close(var r: Resource):
    r^.close()


def close_opt(var o: Optional[Resource]) -> Int:
    """Closes the resource in `o`, if any. Returns its id, or -1."""
    if not o:
        o^.deinit_assert_empty()
        return -1
    var r = o.take()
    o^.deinit_assert_empty()
    var id = r.id
    r^.close()
    return id
