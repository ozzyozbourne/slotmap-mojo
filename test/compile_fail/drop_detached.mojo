# EXPECT: 'd' abandoned without being explicitly destroyed
# A detached slot can't be leaked by forgetting the `Detached` value.
from slotmap import SlotMap


def main() raises:
    var sm = SlotMap[Int]()
    var k = sm.insert(1)
    var d = sm.detach(k)
    print(d.value)
