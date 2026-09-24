from std.collections import Set
from std.testing import assert_equal, assert_false, assert_true, TestSuite

from slotmap import DefaultKey, Key, KeyData, TypedKey
from slotmap._util import is_older_version


struct _ATag:
    pass


comptime AKey = TypedKey[_ATag]


def test_is_older_version() raises:
    assert_false(is_older_version(42, 42))
    assert_true(is_older_version(0, 1))
    assert_true(is_older_version(0, UInt32(1) << 31))
    assert_false(is_older_version(0, (UInt32(1) << 31) + 1))
    assert_true(is_older_version(UInt32.MAX, 0))


def test_null() raises:
    var a = AKey.null()
    var b = AKey()
    assert_equal(a, b)
    assert_true(a.is_null())
    assert_equal(DefaultKey.null().data(), a.data())
    assert_equal(String(a), "null")


def test_ffi_roundtrip() raises:
    var k = DefaultKey(data=KeyData.new(7, 3))
    assert_equal(String(k), "7v3")
    assert_equal(KeyData.from_ffi(k.data().as_ffi()), k.data())
    # Even versions are forced odd.
    assert_equal(KeyData.from_ffi((UInt64(4) << 32) | 0).version, 5)


def test_hash_eq() raises:
    var s = Set[DefaultKey]()
    s.add(DefaultKey(data=KeyData.new(1, 1)))
    s.add(DefaultKey(data=KeyData.new(1, 1)))
    s.add(DefaultKey(data=KeyData.new(1, 3)))
    assert_equal(len(s), 2)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
