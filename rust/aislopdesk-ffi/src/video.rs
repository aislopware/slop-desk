//! Video-path C ABI: the scalar realtime policies and small-buffer codecs from
//! `aislopdesk_core`'s video modules.
//!
//! Same memory / error contract as the crate root (see `lib.rs`): scalars cross by value;
//! any [`crate::AisdBytes`] returned owns a Rust allocation freed with [`crate::aisd_bytes_free`];
//! borrowed input buffers (`cap == 0`) are copied, never freed. The pure scalar functions here
//! take no pointers and cannot fail.

use aislopdesk_core::live_bitrate_policy;

// ---------------------------------------------------------------------------------------
// live_bitrate_policy — pure, scalar (called ~per resolution change, never per frame)
// ---------------------------------------------------------------------------------------

/// Resolution-aware target bitrate (bits/sec) for an encoder of `pixel_width × pixel_height`
/// at `fps`, never below `floor` or the minimum. Wraps
/// [`live_bitrate_policy::target_bitrate`].
///
/// The caller resolves the `bits_per_pixel` density (e.g. from `AISLOPDESK_BPP`) and passes it
/// in, so the core stays environment-free and the result is deterministic.
#[must_use]
#[no_mangle]
pub extern "C" fn aisd_live_bitrate_target(
    pixel_width: i64,
    pixel_height: i64,
    fps: i64,
    floor: i64,
    bits_per_pixel: f64,
) -> i64 {
    live_bitrate_policy::target_bitrate(pixel_width, pixel_height, fps, floor, bits_per_pixel)
}

/// The absolute minimum live bitrate (bits/sec) — a tiny window never starves the encoder.
/// Wraps [`live_bitrate_policy::MINIMUM_BITRATE`].
#[must_use]
#[no_mangle]
pub extern "C" fn aisd_live_bitrate_minimum() -> i64 {
    live_bitrate_policy::MINIMUM_BITRATE
}

#[cfg(test)]
mod tests {
    use super::*;

    const BPP: f64 = live_bitrate_policy::DEFAULT_BITS_PER_PIXEL_PER_FRAME;

    #[test]
    fn live_bitrate_target_matches_core() {
        assert_eq!(
            aisd_live_bitrate_target(1920, 1080, 60, 12_000_000, BPP),
            18_662_400
        );
        assert_eq!(
            aisd_live_bitrate_target(2816, 1778, 60, 12_000_000, BPP),
            45_061_632
        );
        assert_eq!(
            aisd_live_bitrate_target(320, 240, 60, 12_000_000, BPP),
            12_000_000
        );
        assert_eq!(
            aisd_live_bitrate_target(64, 64, 60, 0, BPP),
            aisd_live_bitrate_minimum()
        );
        assert_eq!(
            aisd_live_bitrate_target(0, -10, 0, 0, BPP),
            aisd_live_bitrate_minimum()
        );
    }

    #[test]
    fn live_bitrate_minimum_is_one_megabit() {
        assert_eq!(aisd_live_bitrate_minimum(), 1_000_000);
    }
}
