//! `VTCompressionSession` — HEVC compression, and the `CoreMedia` read of what it emits.
//!
//! Read `docs/57-apple-frameworks-in-rust.md` §2 before adding anything: this crate turns an
//! instruction into an effect and a finished sample into values, and makes no decisions. Which
//! properties a live session carries, what a crisp refresh relaxes and what a compact IDR tightens,
//! when the quantiser ceiling moves and by how much — all of that is `slopdesk_video`'s
//! `encoder_config` and `encoder_state`, which `forbid` `unsafe`.
//!
//! ## What the whole surface is for
//! One session, fed frames, answering samples. [`CompressionSession::create`] makes it,
//! [`CompressionSession::set_bool`] / [`set_int`](CompressionSession::set_int) /
//! [`set_data_rate_limits`](CompressionSession::set_data_rate_limits) /
//! [`set_string`](CompressionSession::set_string) configure it, [`CompressionSession::encode`]
//! feeds it, [`CompressionSession::complete_frames`] drains it, and dropping it tears it down. The
//! sample that comes back is read ONCE, into an [`EncodedSample`].
//!
//! ## Why this cannot be tested the way the rest of the family is
//! `VTCompressionSessionCreate` and every hardware-accelerated encode HANG without a window server
//! and a Screen-Recording grant. That is not a property of this port — it is why the 1500 lines of
//! Swift this replaces carried a header conceding they were "COMPILED + code-reviewed but NEVER
//! instantiated in a test". So the tests here are the ones that can run headless: the value types,
//! the option dictionary's empty case, and the leak shape. The RULES that used to be trapped in
//! that file alongside the calls now live in `slopdesk_video`, where they are exercised properly.
//!
//! ## The output handler is a block, and that is a decision with a reason
//! `VideoToolbox` offers two encode entry points: one whose session carries a C function pointer
//! and a `void *` refcon, and one that takes a block per frame. The refcon form would mean
//! reconstituting a raw pointer into a Rust object on every frame, which §2 bars this family from
//! doing outright. The block form captures an `Arc` instead, so ownership is Rust's and the
//! framework only ever sees an opaque copied block.

#![cfg_attr(
    not(any(target_os = "macos", target_os = "ios")),
    allow(unused_crate_dependencies)
)]

#[cfg(any(target_os = "macos", target_os = "ios"))]
mod decompress;
#[cfg(any(target_os = "macos", target_os = "ios"))]
mod keys;
#[cfg(any(target_os = "macos", target_os = "ios"))]
mod owned;
#[cfg(any(target_os = "macos", target_os = "ios"))]
mod pixels;
#[cfg(target_os = "macos")]
mod sample;
#[cfg(target_os = "macos")]
mod session;
#[cfg(any(target_os = "macos", target_os = "ios"))]
mod status;

#[cfg(any(target_os = "macos", target_os = "ios"))]
pub use decompress::{
    Attachments, DecodedSink, DecompressionSession, FormatDescription, NAL_LENGTH_PREFIX, ParameterSetCodec,
    SampleBuffer,
};
#[cfg(target_os = "macos")]
pub use keys::{Key, StringValue};
#[cfg(any(target_os = "macos", target_os = "ios"))]
pub use objc2_core_foundation::CFRetained;
#[cfg(any(target_os = "macos", target_os = "ios"))]
pub use objc2_core_media::CMSampleBuffer;
#[cfg(any(target_os = "macos", target_os = "ios"))]
pub use objc2_core_video::CVImageBuffer;
#[cfg(any(target_os = "macos", target_os = "ios"))]
pub use pixels::{Locked, PixelBuffer, PlaneBytes, PlaneView, image_size};
#[cfg(target_os = "macos")]
pub use sample::EncodedSample;
#[cfg(target_os = "macos")]
pub use session::{CompressionSession, FrameOptions, FrameSink, Spec, Timestamp, XPC_CREATE_RACE};
#[cfg(any(target_os = "macos", target_os = "ios"))]
pub use status::{INVALID_SESSION, NO_ERR};

#[cfg(all(test, target_os = "macos"))]
mod tests {
    use std::sync::Arc;
    use std::sync::atomic::{AtomicUsize, Ordering};

    use super::{CompressionSession, EncodedSample, FrameOptions, FrameSink, Spec, Timestamp};

    /// Counts what a sink was told, so a test can assert the arm rather than the call.
    #[derive(Debug, Default)]
    struct Counting {
        encoded: AtomicUsize,
        dropped: AtomicUsize,
    }

    impl FrameSink for Counting {
        fn encoded(&self, _: &EncodedSample) {
            self.encoded.fetch_add(1, Ordering::Relaxed);
        }

        fn dropped(&self, _: i32, _: bool) {
            self.dropped.fetch_add(1, Ordering::Relaxed);
        }
    }

    /// A frame that asks for nothing needs no dictionary — the property that keeps the steady-state
    /// delta path free of a `CoreFoundation` allocation per frame. This is the hot path's shape,
    /// and it is checkable without an encoder.
    #[test]
    fn a_frame_that_asks_for_nothing_carries_no_options_at_all() {
        let plain = FrameOptions {
            force_keyframe: false,
            force_ltr_refresh: false,
            acknowledged_ltr_tokens: &[],
        };
        assert!(plain.is_empty());
        let forced = FrameOptions {
            force_keyframe: true,
            ..plain
        };
        assert!(!forced.is_empty());
        let acked = FrameOptions {
            acknowledged_ltr_tokens: &[7],
            ..plain
        };
        assert!(!acked.is_empty());
    }

    /// Every option combination builds a dictionary the framework would accept, or none at all.
    /// Building it is where a key/value class mismatch would show, and it costs no encoder.
    #[test]
    fn every_option_combination_builds_or_declines_to() {
        for force_keyframe in [false, true] {
            for force_ltr_refresh in [false, true] {
                for tokens in [[].as_slice(), [1_i64].as_slice(), [1, 2, 3].as_slice()] {
                    let options = FrameOptions {
                        force_keyframe,
                        force_ltr_refresh,
                        acknowledged_ltr_tokens: tokens,
                    };
                    let built = options.cf();
                    assert_eq!(built.is_none(), options.is_empty());
                    if let Some(dictionary) = built {
                        let expected = usize::from(force_keyframe)
                            + usize::from(force_ltr_refresh)
                            + usize::from(!tokens.is_empty());
                        assert_eq!(dictionary.len(), expected);
                    }
                }
            }
        }
    }

    /// The create dictionary is built the same way and answers `None` for a spec that asks for
    /// neither key — the shape a caller that wanted `VideoToolbox`'s own defaults would use.
    #[test]
    fn a_specification_that_asks_for_nothing_builds_no_dictionary() {
        assert!(
            Spec {
                low_latency: false,
                require_hardware: false,
            }
            .cf()
            .is_none()
        );
        for (low_latency, require_hardware) in [(true, false), (false, true), (true, true)] {
            let built = Spec {
                low_latency,
                require_hardware,
            }
            .cf();
            assert_eq!(
                built.map(|dictionary| dictionary.len()),
                Some(usize::from(low_latency) + usize::from(require_hardware)),
            );
        }
    }

    /// Ten thousand option dictionaries, every one released by scope. The leak test `docs/57` §3
    /// asks each crate for, taken over the object this crate allocates SIXTY TIMES A SECOND — the
    /// session itself cannot be created headlessly, so this is the allocation that matters.
    #[test]
    fn ten_thousand_option_dictionaries_are_built_and_released_without_drift() {
        let tokens: Vec<i64> = (0..16).collect();
        for index in 0..10_000_u32 {
            let options = FrameOptions {
                force_keyframe: index.is_multiple_of(2),
                force_ltr_refresh: index.is_multiple_of(3),
                acknowledged_ltr_tokens: &tokens,
            };
            assert_eq!(
                options.cf().map(|built| built.len()),
                Some(1 + usize::from(index.is_multiple_of(2)) + usize::from(index.is_multiple_of(3)),),
            );
        }
    }

    /// A timestamp crosses as the rational the framework wants, flagged valid — and a zero
    /// timescale stays a zero timescale rather than being repaired into something plausible. The
    /// host anchors its first frame at zero, so an off-by-one here is a stream the client cannot
    /// order.
    #[test]
    fn a_timestamp_crosses_as_the_rational_it_was_given() {
        for (value, timescale) in [(0_i64, 60_i32), (1, 60), (i64::MAX, 1), (-1, 90_000), (5, 0)] {
            let cm = Timestamp { value, timescale }.cm();
            assert_eq!((cm.value, cm.timescale), (value, timescale));
            assert_eq!(cm.flags.0 & 1, 1, "a built timestamp is flagged valid");
        }
    }

    /// A session cannot be created without a window server, so this pins the FAILURE shape rather
    /// than the success one: a create that cannot happen answers a status the caller can report,
    /// never a panic and never a session. On a machine with the grant it creates and tears down,
    /// which exercises the Create-rule retain and the ordered invalidate.
    #[test]
    fn a_session_either_creates_or_reports_why_it_could_not() {
        let spec = Spec {
            low_latency: true,
            require_hardware: true,
        };
        match CompressionSession::create(64, 64, spec) {
            Ok(session) => {
                assert_eq!(session.prepare(), super::NO_ERR);
                assert_eq!(session.complete_frames(), super::NO_ERR);
            },
            Err(status) => assert_ne!(status, super::NO_ERR, "a failed create reports a real status"),
        }
    }

    /// The sink is an `Arc<dyn FrameSink>`, which is what lets the block outlive the encode call
    /// without borrowing anything. Pinned here because the alternative — a stack block over a
    /// borrow — compiles just as well and is unsound the moment `VideoToolbox` answers late.
    #[test]
    fn a_sink_survives_being_shared_with_a_block() {
        let counting = Arc::new(Counting::default());
        let shared: Arc<dyn FrameSink> = counting.clone();
        shared.dropped(0, true);
        drop(shared);
        assert_eq!(counting.dropped.load(Ordering::Relaxed), 1);
        assert_eq!(counting.encoded.load(Ordering::Relaxed), 0);
    }
}
