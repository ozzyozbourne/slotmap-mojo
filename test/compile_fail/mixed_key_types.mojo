# EXPECT: cannot be converted from 'TypedKey[A]' to 'TypedKey[B]'
# Keys of one map type can't be used with a map of another key type.
from slotmap import SlotMap, TypedKey


struct A:
    pass


struct B:
    pass


def main():
    var users = SlotMap[String, TypedKey[A]]()
    var rockets = SlotMap[String, TypedKey[B]]()
    var bob = users.insert("bobby")
    _ = rockets.get(bob)
