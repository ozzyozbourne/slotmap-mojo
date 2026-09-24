# EXPECT: get_disjoint_mut needs at least one key
from slotmap import DefaultKey, SlotMap


def main():
    var sm = SlotMap[Int]()
    var keys = Array[DefaultKey, 0](uninitialized=True)
    _ = sm.get_disjoint_mut[0](keys)
