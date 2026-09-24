def is_older_version(a: UInt32, b: UInt32) -> Bool:
    """Returns whether `a` is an older version than `b`, accounting for
    wrapping of versions."""
    return (a - b) >= (UInt32(1) << 31)
