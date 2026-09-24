# A simple doubly linked list example using slotmap.

from std.testing import assert_equal, assert_false

from slotmap import SlotMap, TypedKey


struct ListTag:
    pass


comptime ListKey = TypedKey[ListTag]


@fieldwise_init
struct Node[T: Movable & Deinitable](Movable):
    var value: Self.T
    var prev: ListKey
    var next: ListKey

    def into_value(deinit self) -> Self.T:
        return self.value^


struct LinkedList[T: Movable & Deinitable](Sized):
    var sm: SlotMap[Node[Self.T], ListKey]
    var head: ListKey
    var tail: ListKey

    def __init__(out self):
        self.sm = SlotMap[Node[Self.T], ListKey]()
        self.head = ListKey.null()
        self.tail = ListKey.null()

    def __len__(self) -> Int:
        return len(self.sm)

    def push_head(mut self, var value: Self.T) -> ListKey:
        var k = self.sm.insert(Node(value^, ListKey.null(), self.head))
        var old_head = self.sm.get_ptr(self.head)
        if old_head:
            old_head.value()[].prev = k
        else:
            self.tail = k
        self.head = k
        return k

    def push_tail(mut self, var value: Self.T) -> ListKey:
        var k = self.sm.insert(Node(value^, self.tail, ListKey.null()))
        var old_tail = self.sm.get_ptr(self.tail)
        if old_tail:
            old_tail.value()[].next = k
        else:
            self.head = k
        self.tail = k
        return k

    def pop_head(mut self) -> Optional[Self.T]:
        var old_head = self.sm.remove(self.head)
        if not old_head:
            return None
        var node = old_head.take()
        self.head = node.next
        return node^.into_value()

    def pop_tail(mut self) -> Optional[Self.T]:
        var old_tail = self.sm.remove(self.tail)
        if not old_tail:
            return None
        var node = old_tail.take()
        self.tail = node.prev
        return node^.into_value()

    def remove(mut self, key: ListKey) -> Optional[Self.T]:
        var removed = self.sm.remove(key)
        if not removed:
            return None
        var node = removed.take()
        var prev_node = self.sm.get_ptr(node.prev)
        if prev_node:
            prev_node.value()[].next = node.next
        else:
            self.head = node.next
        var next_node = self.sm.get_ptr(node.next)
        if next_node:
            next_node.value()[].prev = node.prev
        else:
            self.tail = node.prev
        return node^.into_value()


def main() raises:
    var dll = LinkedList[Int]()
    _ = dll.push_head(5)
    _ = dll.push_tail(6)
    var k = dll.push_head(3)
    _ = dll.push_tail(7)
    _ = dll.push_head(4)

    # The upstream Rust example asserts len 4 and pops 4 then 5 here, which
    # panics when run. The list really is [4, 3, 5, 6, 7].
    assert_equal(len(dll), 5)
    assert_equal(dll.pop_head().value(), 4)
    assert_equal(dll.head, k)
    _ = dll.push_head(10)
    assert_equal(dll.remove(k).value(), 3)
    assert_equal(dll.pop_tail().value(), 7)
    assert_equal(dll.pop_tail().value(), 6)
    assert_equal(dll.pop_head().value(), 10)
    assert_equal(dll.pop_head().value(), 5)
    assert_false(dll.pop_head())
    assert_false(dll.pop_tail())
    print("doubly_linked_list: ok")
