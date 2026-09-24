"""Slot map containers with persistent unique keys, ported from the Rust
`slotmap` crate."""

from .key import DefaultKey, Key, KeyData, TypedKey
from ._common import Detached, Item, SlotMapLike
from .basic import SlotMap
from .dense import DenseSlotMap
from .secondary import Entry, SecondaryMap
from .sparse_secondary import IdxHasher, SparseEntry, SparseSecondaryMap
from .hop import HopSlotMap
