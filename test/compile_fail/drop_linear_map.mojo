# EXPECT: Use `deinit_with()` to destroy a map holding non-`Deinitable` values
# A map of linear values must be destroyed with `deinit_with()`.
from slotmap import SlotMap


@explicit_destroy("close it")
struct Handle(not Deinitable, Movable):
    var fd: Int

    def __init__(out self, fd: Int):
        self.fd = fd


def main():
    var sm = SlotMap[Handle]()
    _ = sm.insert(Handle(3))
