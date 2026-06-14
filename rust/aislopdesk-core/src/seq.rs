//! Wrap-aware sequence arithmetic — a port of Swift `UInt32.distanceWrapped(from:)`.
//!
//! `frame_id` / `stream_seq` / `channel_id` are monotonic `u32`s that wrap at 2³². To
//! compare two of them you cannot use plain `<`; instead take their wrapping difference
//! reinterpreted as a *signed* 32-bit value.

/// Signed wrap-aware distance `a - b` interpreted in 32-bit sequence space.
///
/// Positive ⇒ `a` is "ahead of" `b`. Equal ⇒ 0. The result is the two's-complement
/// reinterpretation of `a.wrapping_sub(b)`, so it stays correct across the 2³² wrap as
/// long as the two values are within 2³¹ of each other (always true for a live stream).
#[must_use]
pub const fn distance_wrapped(a: u32, b: u32) -> i32 {
    a.wrapping_sub(b) as i32
}

#[cfg(test)]
mod tests {
    use super::distance_wrapped;

    #[test]
    fn ahead_and_behind() {
        assert_eq!(distance_wrapped(10, 4), 6);
        assert_eq!(distance_wrapped(4, 10), -6);
        assert_eq!(distance_wrapped(7, 7), 0);
    }

    #[test]
    fn handles_wrap() {
        // 2 is ahead of 0xFFFF_FFFF by 3 across the wrap.
        assert_eq!(distance_wrapped(2, u32::MAX), 3);
        assert_eq!(distance_wrapped(u32::MAX, 2), -3);
    }
}
