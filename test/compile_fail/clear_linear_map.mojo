# EXPECT: invalid call to 'clear': violated constraint
# Operations that would drop values (clear, retain, drain, insert on a
# secondary map) are unavailable for linear values.
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
    sm.clear()
    sm^.deinit_with(close)
