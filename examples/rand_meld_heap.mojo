# Randomized meldable heap.
# https://en.wikipedia.org/wiki/Randomized_meldable_heap

from slotmap import SlotMap, TypedKey


struct HeapTag:
    pass


comptime HeapKey = TypedKey[HeapTag]


@fieldwise_init
struct NodeHandle(ImplicitlyCopyable):
    var key: HeapKey


@fieldwise_init
struct Node[T: Copyable & Comparable & Deinitable](Copyable):
    var value: Self.T
    var children: Array[HeapKey, 2]
    var parent: HeapKey

    def into_value(deinit self) -> Self.T:
        return self.value^


struct RandMeldHeap[T: Copyable & Comparable & Deinitable](Sized):
    var sm: SlotMap[Node[Self.T], HeapKey]
    var rng: UInt32
    var root: HeapKey

    def __init__(out self):
        self.sm = SlotMap[Node[Self.T], HeapKey]()
        self.rng = 0xDEAD_BEEF
        self.root = HeapKey.null()

    def coinflip(mut self) -> Int:
        # Simple LCG for top speed - random quality barely matters.
        self.rng += (self.rng << 8) + 1
        return Int(self.rng >> 31)

    def insert(mut self, var value: Self.T) -> NodeHandle:
        var k = self.sm.insert(
            Node(value^, Array[HeapKey, 2](fill=HeapKey.null()), HeapKey.null())
        )
        self.root = self.meld(k, self.root)
        return NodeHandle(k)

    def pop(mut self) -> Optional[Self.T]:
        var removed = self.sm.remove(self.root)
        if not removed:
            return None
        var root = removed.take()
        self.root = self.meld(root.children[0], root.children[1])
        var new_root = self.sm.get_ptr(self.root)
        if new_root:
            new_root.value()[].parent = HeapKey.null()
        return root^.into_value()

    def remove_key(mut self, node: NodeHandle) -> Self.T:
        self.unlink_node(node.key)
        var removed = self.sm.remove(node.key)
        return removed.take().into_value()

    def update_key(mut self, node: NodeHandle, var value: Self.T):
        # Unlink and re-insert.
        self.unlink_node(node.key)
        self.sm[node.key] = Node(
            value^, Array[HeapKey, 2](fill=HeapKey.null()), HeapKey.null()
        )
        self.root = self.meld(node.key, self.root)

    def unlink_node(mut self, node: HeapKey):
        # Remove node from heap by merging children and placing them where
        # node used to be.
        var children = self.sm[node].children.copy()
        var parent_key = self.sm[node].parent

        var melded_children = self.meld(children[0], children[1])
        var mc = self.sm.get_ptr(melded_children)
        if mc:
            mc.value()[].parent = parent_key

        var parent = self.sm.get_ptr(parent_key)
        if parent:
            if parent.value()[].children[0] == node:
                parent.value()[].children[0] = melded_children
            else:
                parent.value()[].children[1] = melded_children
        else:
            self.root = melded_children

    def meld(mut self, var a: HeapKey, var b: HeapKey) -> HeapKey:
        if a.is_null():
            return b
        if b.is_null():
            return a
        if self.sm[a].value > self.sm[b].value:
            swap(a, b)

        # From this point parent and trickle are assumed to be valid keys.
        var parent = a
        var trickle = b
        while True:
            # If a child spot is free, put our trickle there.
            var children = self.sm[parent].children.copy()
            if children[0].is_null():
                self.sm[parent].children[0] = trickle
                self.sm[trickle].parent = parent
                break
            elif children[1].is_null():
                self.sm[parent].children[1] = trickle
                self.sm[trickle].parent = parent
                break

            # No spot free, choose a random child.
            var c = self.coinflip()
            var child = children[c]
            if self.sm[child].value > self.sm[trickle].value:
                self.sm[parent].children[c] = trickle
                self.sm[trickle].parent = parent
                parent = trickle
                trickle = child
            else:
                parent = child
        return a

    def __len__(self) -> Int:
        return len(self.sm)


def main() raises:
    var rhm = RandMeldHeap[Int]()
    var the_answer = rhm.insert(-2)
    var big = rhm.insert(999)
    for k in reversed(range(10)):
        _ = rhm.insert(k * k)

    rhm.update_key(the_answer, 42)
    _ = rhm.remove_key(big)

    while len(rhm) > 0:
        print(rhm.pop().value())
