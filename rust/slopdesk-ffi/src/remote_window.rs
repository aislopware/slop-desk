//! What a live video pane ADMITS, in C.
//!
//! The rules are `slopdesk_workspace::remote_window`; what is here is the marshalling.
//!
//! ## The sample crosses BY VALUE, both ways
//!
//! [`SlopDeskWsStreamSample`] is eight numbers arriving together twice a second and
//! [`SlopDeskWsStreamReading`] is the verdict on them. Both are `struct`s rather than pointers, for
//! `docs/55` §4b's reason and for a second one: the reading is ALL OR NOTHING, so a door that took
//! eight arguments would have been a door somebody could call with half a window. The near side
//! copies the answer into its `@Observable` writes and nothing is shared.
//!
//! Layouts are widest-first — the doubles, then the `int64_t`, then the flags — so the hand-written
//! header has no interior padding to transcribe. Every optional carries a FLAG: on the latency axes
//! a zero MEANS absent on the wire, so a sentinel here would have re-encoded the very ambiguity the
//! rules crate exists to remove.
//!
//! ## The refusal is a flag, not a zeroed struct
//!
//! [`SlopDeskWsStreamReading::admitted`] is false for a refused sample, and the near side writes
//! nothing at all when it sees that. A zeroed struct could not have said it: an all-zero sample is
//! a perfectly legal reading — an idle stream measures exactly that — so "the sample was rejected"
//! and "every axis read zero" had to be different answers.
//!
//! ## Two strings, and neither can be empty
//!
//! [`slopdesk_ws_stream_title`] and [`slopdesk_ws_stream_rejection`] deliver raw bytes with no
//! framing, because each answers ONE string. Neither has an empty arm — a titleless window is
//! called `window 7` and a nameless target is called `The stream target` — so §4's `0` never
//! collides with a real answer at either.

use core::ffi::c_uchar;

use slopdesk_workspace::remote_window::{self, NetworkSample};

use crate::{borrow, deliver, optional};

/// What one geometry push from the live pane is allowed to write.
///
/// Two verdicts rather than one: the two sizes arrive in the same push and are admitted apart,
/// because a host that has reported its window but not yet its display bounds sends a real current
/// size beside a zero max.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct SlopDeskWsStreamGeometry {
    /// The window's current width in points; meaningless when `has_current` is false.
    pub current_width: f64,
    /// The window's current height in points; meaningless when `has_current` is false.
    pub current_height: f64,
    /// The maximum resizable width in points; meaningless when `has_max` is false.
    pub max_width: f64,
    /// The maximum resizable height in points; meaningless when `has_max` is false.
    pub max_height: f64,
    /// Whether the push carried a usable current size.
    pub has_current: bool,
    /// Whether the push carried a usable maximum size.
    pub has_max: bool,
}

/// One raw ~2 Hz network sample, exactly as the live pane's telemetry windows hand it over.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct SlopDeskWsStreamSample {
    /// Frames per second received.
    pub fps: f64,
    /// Frames per second the error correction recovered.
    pub fec_per_sec: f64,
    /// Frames per second lost past recovery.
    pub unrecovered_per_sec: f64,
    /// The host's smoothed round-trip time in milliseconds; `0` means "not reported".
    pub rtt_ms: f64,
    /// The host's encode-wall EWMA in milliseconds; `0` means "not reported".
    pub encode_ms: f64,
    /// The client's decode-wall EWMA in milliseconds; `0` means "not reported".
    pub decode_ms: f64,
    /// How long the newest frame has been held, in milliseconds.
    pub hold_ms: i64,
    /// How many frames the presentation pacer is holding.
    pub pacer_depth: i64,
}

impl SlopDeskWsStreamSample {
    /// The record as the rules crate models it — the same eight numbers, one type over.
    const fn rules(self) -> NetworkSample {
        NetworkSample {
            fps: self.fps,
            fec_per_sec: self.fec_per_sec,
            unrecovered_per_sec: self.unrecovered_per_sec,
            rtt_ms: self.rtt_ms,
            encode_ms: self.encode_ms,
            decode_ms: self.decode_ms,
            hold_ms: self.hold_ms,
            pacer_depth: self.pacer_depth,
        }
    }
}

/// The verdict on one sample: the rate axes as measurements, the latency axes flagged.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct SlopDeskWsStreamReading {
    /// Frames per second received.
    pub fps: f64,
    /// Frames per second the error correction recovered.
    pub fec_per_sec: f64,
    /// Frames per second lost past recovery.
    pub unrecovered_per_sec: f64,
    /// Round-trip time in milliseconds; meaningless when `has_rtt_ms` is false.
    pub rtt_ms: f64,
    /// Encode wall time in milliseconds; meaningless when `has_encode_ms` is false.
    pub encode_ms: f64,
    /// Decode wall time in milliseconds; meaningless when `has_decode_ms` is false.
    pub decode_ms: f64,
    /// How long the newest frame has been held, in milliseconds.
    pub hold_ms: i64,
    /// How many frames the presentation pacer is holding.
    pub pacer_depth: i64,
    /// Whether the sample was a reading at all. False leaves every field above meaningless.
    pub admitted: bool,
    /// Whether [`rtt_ms`](Self::rtt_ms) carries a measurement.
    pub has_rtt_ms: bool,
    /// Whether [`encode_ms`](Self::encode_ms) carries a measurement.
    pub has_encode_ms: bool,
    /// Whether [`decode_ms`](Self::decode_ms) carries a measurement.
    pub has_decode_ms: bool,
}

/// What an immersive toggle commits.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SlopDeskWsStreamImmersive {
    /// The latched wish after the fold.
    pub desired: bool,
    /// The fullscreen auto-arm after the fold.
    pub fullscreen_override: bool,
    /// Whether the wish moved, and so whether the pane's spec should be rewritten.
    pub notifies: bool,
}

/// The two stream overrides a restored pane starts with, clamped.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SlopDeskWsStreamCaps {
    /// The fps cap; `0` is Auto.
    pub fps_cap: i64,
    /// The bitrate ceiling in bits per second; `0` is Auto.
    pub bitrate_ceiling_bps: i64,
}

/// What one geometry push writes: the current size if it is one, the max if it is one.
///
/// A `has_max` of false does NOT mean "no maximum" — it means this push did not carry one, and the
/// near side leaves the cap it already knows standing. The persistence is the caller's, because
/// this rule sees one push and has no memory.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_ws_stream_geometry(
    current_width: f64,
    current_height: f64,
    max_width: f64,
    max_height: f64,
) -> SlopDeskWsStreamGeometry {
    let update = remote_window::geometry_update(current_width, current_height, max_width, max_height);
    let (has_current, current) = match update.current {
        Some(size) => (true, size),
        None => {
            (false, remote_window::Size {
                width: 0.0,
                height: 0.0,
            })
        },
    };
    let (has_max, max) = match update.max {
        Some(size) => (true, size),
        None => {
            (false, remote_window::Size {
                width: 0.0,
                height: 0.0,
            })
        },
    };
    SlopDeskWsStreamGeometry {
        current_width: current.width,
        current_height: current.height,
        max_width: max.width,
        max_height: max.height,
        has_current,
        has_max,
    }
}

/// Whether a host-announced cadence is an announcement. Non-positive is not, and the last good one
/// stands.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_ws_stream_admits_fps(fps: i64) -> bool {
    remote_window::admits_stream_fps(fps)
}

/// Whether a measured payload bitrate is a measurement. Only a negative is not — a zero is what an
/// idle stream measures.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_ws_stream_admits_kbps(kbps: i64) -> bool {
    remote_window::admits_stream_kbps(kbps)
}

/// One ~2 Hz sample as a reading. `admitted` false means every axis is meaningless: a negative or a
/// `NaN` anywhere refuses the WHOLE window rather than mixing a good axis with garbage.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_ws_stream_network(
    sample: SlopDeskWsStreamSample,
) -> SlopDeskWsStreamReading {
    let Some(reading) = remote_window::network_reading(sample.rules()) else {
        return SlopDeskWsStreamReading {
            fps: 0.0,
            fec_per_sec: 0.0,
            unrecovered_per_sec: 0.0,
            rtt_ms: 0.0,
            encode_ms: 0.0,
            decode_ms: 0.0,
            hold_ms: 0,
            pacer_depth: 0,
            admitted: false,
            has_rtt_ms: false,
            has_encode_ms: false,
            has_decode_ms: false,
        };
    };
    let (has_rtt_ms, rtt_ms) = optional(reading.rtt_ms, 0.0);
    let (has_encode_ms, encode_ms) = optional(reading.encode_ms, 0.0);
    let (has_decode_ms, decode_ms) = optional(reading.decode_ms, 0.0);
    SlopDeskWsStreamReading {
        fps: reading.fps,
        fec_per_sec: reading.fec_per_sec,
        unrecovered_per_sec: reading.unrecovered_per_sec,
        rtt_ms,
        encode_ms,
        decode_ms,
        hold_ms: reading.hold_ms,
        pacer_depth: reading.pacer_depth,
        admitted: true,
        has_rtt_ms,
        has_encode_ms,
        has_decode_ms,
    }
}

/// The immersive toggle's fold: the wish becomes `on`, and an explicit OFF drops the fullscreen
/// auto-arm with it so the escape hatch always wins.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_ws_stream_immersive(
    on: bool,
    desired: bool,
    fullscreen_override: bool,
) -> SlopDeskWsStreamImmersive {
    let commit = remote_window::immersive_commit(on, desired, fullscreen_override);
    SlopDeskWsStreamImmersive {
        desired: commit.desired,
        fullscreen_override: commit.fullscreen_override,
        notifies: commit.notifies,
    }
}

/// A restored mode snapshot's two overrides, floored at `0`, which is Auto on both sides.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_ws_stream_seeded_caps(
    fps_cap: i64,
    bitrate_ceiling_bps: i64,
) -> SlopDeskWsStreamCaps {
    let caps = remote_window::seeded_caps(fps_cap, bitrate_ceiling_bps);
    SlopDeskWsStreamCaps {
        fps_cap: caps.fps_cap,
        bitrate_ceiling_bps: caps.bitrate_ceiling_bps,
    }
}

/// The window id an entry field holds, or false when what is in it is not one.
///
/// A flag beside an out-parameter rather than a sentinel: every `uint32_t` is a legal window id,
/// including `0`, so nothing was left over to mean "not a number". A null `out` asks only whether
/// there is an answer.
///
/// This is Swift's `UInt32(_:)` over Swift's `CharacterSet.whitespaces`, not Rust's `parse` over
/// Rust's `trim` — the two disagree on line breaks and on `-0`, both reachable by typing.
///
/// # Safety
/// `(entered, len)` must be readable for the call, and `out` null or writable for one `uint32_t`.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and both pointers are the caller's"
)]
pub unsafe extern "C" fn slopdesk_ws_stream_window_id(
    entered: *const c_uchar,
    len: usize,
    out: *mut u32,
) -> bool {
    // SAFETY: the caller's obligation, restated above; the borrow dies with this call.
    let lent = unsafe { borrow(entered, len) };
    let Ok(text) = core::str::from_utf8(lent) else {
        return false;
    };
    let Some(id) = remote_window::parse_window_id(text) else {
        return false;
    };
    if out.is_null() {
        return true;
    }
    // SAFETY: `out` is non-null and writable for one `u32` by the caller's obligation.
    unsafe { out.write(id) };
    true
}

/// What the opened descriptor is CALLED: the bound title, or `window <id>` when it has none.
///
/// The id crosses as DISPLAY DATA, the way `slopdesk_ws_gui_activation_key`'s pane hash does. It is
/// not compared, resolved or handed back — a window with no title has nothing else to be called.
///
/// # Safety
/// `(title, len)` must be readable for the call, and `(out, cap)` writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and both pointers are the caller's"
)]
pub unsafe extern "C" fn slopdesk_ws_stream_title(
    title: *const c_uchar,
    len: usize,
    window_id: u32,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, restated above; the borrow dies with this call.
    let lent = unsafe { borrow(title, len) };
    let bound = String::from_utf8_lossy(lent);
    let answer = remote_window::descriptor_title(&bound, window_id);
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe { deliver(answer.as_bytes(), out, cap) }
}

/// What the placeholder says when the host REFUSES the session — the target is gone on the host, or
/// the two halves disagree about the protocol.
///
/// # Safety
/// `(title, len)` must be readable for the call, and `(out, cap)` writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and both pointers are the caller's"
)]
pub unsafe extern "C" fn slopdesk_ws_stream_rejection(
    title: *const c_uchar,
    len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, restated above; the borrow dies with this call.
    let lent = unsafe { borrow(title, len) };
    let named = String::from_utf8_lossy(lent);
    let answer = remote_window::rejection_message(&named);
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe { deliver(answer.as_bytes(), out, cap) }
}

#[cfg(test)]
mod tests {
    #![expect(unsafe_code, reason = "calling the door is the only way to test the door")]

    use slopdesk_workspace::remote_window;

    use super::{
        SlopDeskWsStreamSample, slopdesk_ws_stream_admits_fps, slopdesk_ws_stream_admits_kbps,
        slopdesk_ws_stream_geometry, slopdesk_ws_stream_immersive, slopdesk_ws_stream_network,
        slopdesk_ws_stream_rejection, slopdesk_ws_stream_seeded_caps, slopdesk_ws_stream_title,
        slopdesk_ws_stream_window_id,
    };
    use crate::testing::delivered;

    /// Asks the parse door for one entered string, the way the near side does.
    fn window_id(entered: &str) -> Option<u32> {
        let bytes = entered.as_bytes();
        let mut parsed = 0_u32;
        // SAFETY: `bytes` is a live slice and `parsed` a live local for the call.
        let found = unsafe { slopdesk_ws_stream_window_id(bytes.as_ptr(), bytes.len(), &raw mut parsed) };
        found.then_some(parsed)
    }

    /// The parse crosses verbatim, including both halves of the Swift dialect the rule spells out.
    #[test]
    fn the_entry_field_crosses_with_swifts_dialect_intact() {
        for entered in [
            "42",
            " 42 ",
            "\u{00A0}42\u{3000}",
            "42\n",
            "+42",
            "-0",
            "-1",
            "",
            "  ",
            "4294967295",
            "4294967296",
            "0x2a",
        ] {
            assert_eq!(
                window_id(entered),
                remote_window::parse_window_id(entered),
                "{entered:?}"
            );
        }
    }

    /// A null `out` asks only whether there is an answer, and a null input is the empty string,
    /// which is not a window id.
    #[test]
    fn a_null_out_asks_only_whether_there_is_one() {
        let bytes = b"7";
        // SAFETY: `bytes` is a live slice; a null `out` is the documented sizing call.
        let found =
            unsafe { slopdesk_ws_stream_window_id(bytes.as_ptr(), bytes.len(), core::ptr::null_mut()) };
        assert!(found);
        // SAFETY: a null input with a zero length is the documented empty lend.
        let empty = unsafe { slopdesk_ws_stream_window_id(core::ptr::null(), 0, core::ptr::null_mut()) };
        assert!(!empty);
    }

    /// A `0` is a real window id, which is why the refusal is a flag and not a sentinel.
    #[test]
    fn zero_is_an_answer_and_not_a_refusal() {
        assert_eq!(window_id("0"), Some(0));
        assert_eq!(window_id("nope"), None);
    }

    /// The two geometry verdicts cross apart — the case a host that knows its window but not its
    /// display bounds produces on every open.
    #[expect(
        clippy::float_cmp,
        reason = "the point of the assertion is that the door hands BACK the caller's own bits — an epsilon \
                  here would pass on a value the boundary had rounded"
    )]
    #[test]
    fn the_two_sizes_cross_apart() {
        let crossed = slopdesk_ws_stream_geometry(800.0, 600.0, 0.0, 0.0);
        assert!(crossed.has_current);
        assert!(!crossed.has_max);
        assert_eq!(crossed.current_width, 800.0);
        assert_eq!(crossed.current_height, 600.0);
        let both = slopdesk_ws_stream_geometry(800.0, 600.0, 3840.0, 2160.0);
        assert!(both.has_current && both.has_max);
        assert_eq!(both.max_width, 3840.0);
        let neither = slopdesk_ws_stream_geometry(0.0, -1.0, f64::NAN, 2160.0);
        assert!(!neither.has_current && !neither.has_max);
        assert_eq!(neither.current_width, 0.0, "a refused axis reads as zero");
    }

    /// Both admission gates cross, and they disagree about zero on purpose.
    #[test]
    fn the_two_gates_disagree_about_zero() {
        assert!(!slopdesk_ws_stream_admits_fps(0));
        assert!(slopdesk_ws_stream_admits_fps(60));
        assert!(!slopdesk_ws_stream_admits_fps(-1));
        assert!(slopdesk_ws_stream_admits_kbps(0));
        assert!(slopdesk_ws_stream_admits_kbps(12500));
        assert!(!slopdesk_ws_stream_admits_kbps(-1));
    }

    /// A measured sample crosses with every axis, and its latency flags follow the rule and not the
    /// number beside them.
    #[expect(
        clippy::float_cmp,
        reason = "same reason as `the_two_sizes_cross_apart`: an axis that crossed unchanged is the claim, \
                  so exact equality IS the test"
    )]
    #[test]
    fn a_measured_sample_crosses_with_its_flags() {
        let crossed = slopdesk_ws_stream_network(SlopDeskWsStreamSample {
            fps: 59.6,
            fec_per_sec: 1.25,
            unrecovered_per_sec: 0.0,
            rtt_ms: 8.0,
            encode_ms: 0.0,
            decode_ms: 1.5,
            hold_ms: 16,
            pacer_depth: 3,
        });
        assert!(crossed.admitted);
        assert_eq!(crossed.fps, 59.6);
        assert!(crossed.has_rtt_ms);
        assert!(!crossed.has_encode_ms, "a zero latency is no reading");
        assert_eq!(crossed.encode_ms, 0.0);
        assert!(crossed.has_decode_ms);
        assert_eq!(crossed.hold_ms, 16);
        assert_eq!(crossed.pacer_depth, 3);
    }

    /// An all-zero sample is ADMITTED with no latencies — which is why the refusal needed its own
    /// flag rather than a zeroed struct.
    #[test]
    fn an_all_zero_sample_is_a_reading_and_a_refusal_is_not() {
        let idle = slopdesk_ws_stream_network(SlopDeskWsStreamSample::default());
        assert!(idle.admitted, "an idle stream measures exactly this");
        assert!(!idle.has_rtt_ms && !idle.has_encode_ms && !idle.has_decode_ms);
        let refused = slopdesk_ws_stream_network(SlopDeskWsStreamSample {
            unrecovered_per_sec: -1.0,
            ..SlopDeskWsStreamSample::default()
        });
        assert!(!refused.admitted);
        let nan = slopdesk_ws_stream_network(SlopDeskWsStreamSample {
            fps: f64::NAN,
            ..SlopDeskWsStreamSample::default()
        });
        assert!(!nan.admitted);
    }

    /// The immersive fold crosses over its whole domain, field for field with the rule.
    #[test]
    fn the_immersive_fold_crosses_over_its_whole_domain() {
        for on in [false, true] {
            for desired in [false, true] {
                for armed in [false, true] {
                    let crossed = slopdesk_ws_stream_immersive(on, desired, armed);
                    let native = remote_window::immersive_commit(on, desired, armed);
                    assert_eq!(crossed.desired, native.desired);
                    assert_eq!(crossed.fullscreen_override, native.fullscreen_override);
                    assert_eq!(crossed.notifies, native.notifies);
                }
            }
        }
    }

    /// The restore clamp crosses, including the end a hand-edited file can reach.
    #[test]
    fn the_restore_clamp_crosses() {
        let clean = slopdesk_ws_stream_seeded_caps(30, 10_000_000);
        assert_eq!(clean.fps_cap, 30);
        assert_eq!(clean.bitrate_ceiling_bps, 10_000_000);
        let floored = slopdesk_ws_stream_seeded_caps(i64::MIN, -1);
        assert_eq!(floored.fps_cap, 0);
        assert_eq!(floored.bitrate_ceiling_bps, 0);
    }

    /// Both sentences cross verbatim, in both of their arms.
    #[test]
    fn both_sentences_cross_verbatim() {
        for title in ["", "Xcode", "Untitled 2"] {
            let bytes = title.as_bytes();
            let named = delivered(|out, cap| {
                // SAFETY: both pointers are live locals for the call.
                unsafe { slopdesk_ws_stream_title(bytes.as_ptr(), bytes.len(), 7, out, cap) }
            });
            assert_eq!(
                String::from_utf8_lossy(&named),
                remote_window::descriptor_title(title, 7),
                "{title:?}"
            );
            let refused = delivered(|out, cap| {
                // SAFETY: both pointers are live locals for the call.
                unsafe { slopdesk_ws_stream_rejection(bytes.as_ptr(), bytes.len(), out, cap) }
            });
            assert_eq!(
                String::from_utf8_lossy(&refused),
                remote_window::rejection_message(title),
                "{title:?}"
            );
        }
    }

    /// A short buffer is told the length and written nothing, which is §4's retry contract.
    #[test]
    fn a_short_buffer_is_told_the_length_and_left_untouched() {
        let mut out = [0xAA_u8; 4];
        // SAFETY: a null input is the empty lend, and `out` is a live local for the call.
        let needed =
            unsafe { slopdesk_ws_stream_rejection(core::ptr::null(), 0, out.as_mut_ptr(), out.len()) };
        assert!(needed > out.len());
        assert_eq!(out, [0xAA; 4], "nothing was written");
        // SAFETY: a null `out` with a zero cap is the documented way to ask for the length.
        let sizing = unsafe { slopdesk_ws_stream_rejection(core::ptr::null(), 0, core::ptr::null_mut(), 0) };
        assert_eq!(sizing, needed, "sizing and retrying agree");
    }
}
