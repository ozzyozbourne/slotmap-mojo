# EXPECT: abandoned without being explicitly destroyed
# A linear value removed from a map must still be consumed.
from slotmap import SlotMap


@explicit_destroy("close it")
struct Handle(not Deinitable, Movable):
    var fd: Int

    def __init__(out self, fd: Int):
        self.fd = fd

    def close(deinit self):
        pass


def close(var h: Handle):
    h^.close()


def main():
    var sm = SlotMap[Handle]()
    var k = sm.insert(Handle(3))
    _ = sm.remove(k)
    sm^.deinit_with(close)
