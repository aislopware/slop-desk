//! What a video pane SAYS, in C.
//!
//! The rules are `slopdesk_workspace::gui_readout`; what is here is the marshalling.
//!
//! ## The sample crosses BY VALUE
//!
//! [`SlopDeskWsGuiTelemetry`] is ten optional numbers and it is an argument, not a handle: the near
//! side holds it as a `struct` it copies into its chrome model, so a pointer would give two owners
//! one allocation for a value the type system says is separate — `docs/55` §4b's rule, at the size
//! the rate law already crosses at. By value also means there is no null case and no `# Safety`
//! obligation on the input; the only pointer in this module is the caller's own `(out, cap)`.
//!
//! Its layout is widest-first — six `double`, four `int64_t`, then the ten presence flags — so the
//! hand-written header has no interior padding to transcribe. Every optional carries a FLAG rather
//! than a sentinel, which is the whole law the rules crate is written around: a measured zero and a
//! stream nothing has sampled yet are different facts, and no number could have meant "absent".
//!
//! ## One string per door, framed only where there are five
//!
//! Eight of these answer ONE string and deliver its bytes raw — there is nothing to cut apart. Only
//! [`slopdesk_ws_gui_stat_rows`] frames, because five rows in one crossing need a splitter; a door
//! per row would be five `(out, cap)` calls and five near-side allocations to draw one readout.
//!
//! None of the eight can answer the empty string, so §4's `0` never collides with a real answer
//! here — every formatter has at least the em dash to say, and every table has a word for the byte
//! it could not name.

use core::ffi::c_uchar;

use slopdesk_workspace::gui_readout::{self, Display, Telemetry, UploadPhase};

use crate::{deliver, optional_of, push_text};

/// One sample of everything the five stat rows print.
///
/// Field order is widest-first and the presence flags follow the values in the SAME order, so a
/// reader checking a pair only has to count once. `has_*` false leaves its value at zero, which is
/// a debugger's convenience and nothing else — the rules crate never reads it.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct SlopDeskWsGuiTelemetry {
    /// The ~2 Hz mirror's received frame rate.
    pub stats_fps: f64,
    /// Frames per second the error correction recovered.
    pub stats_fec_per_sec: f64,
    /// Frames per second lost past recovery.
    pub stats_unrecovered_per_sec: f64,
    /// Round-trip time, in milliseconds.
    pub stats_rtt_ms: f64,
    /// Host-side encode time, in milliseconds.
    pub stats_encode_ms: f64,
    /// Client-side decode time, in milliseconds.
    pub stats_decode_ms: f64,
    /// Host-announced stream cadence, in frames per second.
    pub stream_fps: i64,
    /// Client-measured payload bitrate, in kilobits per second.
    pub stream_kbps: i64,
    /// How many frames the presentation pacer is holding.
    pub stats_pacer_depth: i64,
    /// How long the newest frame has been held, in milliseconds.
    pub stats_hold_ms: i64,
    /// Whether [`stats_fps`](Self::stats_fps) carries a measurement.
    pub has_stats_fps: bool,
    /// Whether [`stats_fec_per_sec`](Self::stats_fec_per_sec) carries a measurement.
    pub has_stats_fec_per_sec: bool,
    /// Whether [`stats_unrecovered_per_sec`](Self::stats_unrecovered_per_sec) carries one.
    pub has_stats_unrecovered_per_sec: bool,
    /// Whether [`stats_rtt_ms`](Self::stats_rtt_ms) carries a measurement.
    pub has_stats_rtt_ms: bool,
    /// Whether [`stats_encode_ms`](Self::stats_encode_ms) carries a measurement.
    pub has_stats_encode_ms: bool,
    /// Whether [`stats_decode_ms`](Self::stats_decode_ms) carries a measurement.
    pub has_stats_decode_ms: bool,
    /// Whether [`stream_fps`](Self::stream_fps) carries an announcement.
    pub has_stream_fps: bool,
    /// Whether [`stream_kbps`](Self::stream_kbps) carries a measurement.
    pub has_stream_kbps: bool,
    /// Whether [`stats_pacer_depth`](Self::stats_pacer_depth) carries a reading.
    pub has_stats_pacer_depth: bool,
    /// Whether [`stats_hold_ms`](Self::stats_hold_ms) carries a reading.
    pub has_stats_hold_ms: bool,
}

impl SlopDeskWsGuiTelemetry {
    /// The sample as the rules crate models it — ten flag/value pairs becoming ten `Option`s.
    const fn rules(self) -> Telemetry {
        Telemetry {
            stream_fps: optional_of(self.has_stream_fps, self.stream_fps),
            stream_kbps: optional_of(self.has_stream_kbps, self.stream_kbps),
            stats_fps: optional_of(self.has_stats_fps, self.stats_fps),
            stats_pacer_depth: optional_of(self.has_stats_pacer_depth, self.stats_pacer_depth),
            stats_fec_per_sec: optional_of(self.has_stats_fec_per_sec, self.stats_fec_per_sec),
            stats_unrecovered_per_sec: optional_of(
                self.has_stats_unrecovered_per_sec,
                self.stats_unrecovered_per_sec,
            ),
            stats_rtt_ms: optional_of(self.has_stats_rtt_ms, self.stats_rtt_ms),
            stats_encode_ms: optional_of(self.has_stats_encode_ms, self.stats_encode_ms),
            stats_decode_ms: optional_of(self.has_stats_decode_ms, self.stats_decode_ms),
            stats_hold_ms: optional_of(self.has_stats_hold_ms, self.stats_hold_ms),
        }
    }
}

/// The five telemetry rows, top-down, as five `[u32 length][UTF-8 bytes]` runs in one delivery.
///
/// One crossing rather than five: the readout draws all five together or not at all, and the near
/// side already owns the splitter every group-delivery door here uses.
///
/// # Safety
/// `(out, cap)` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and `(out, cap)` is the caller's buffer"
)]
pub unsafe extern "C" fn slopdesk_ws_gui_stat_rows(
    stats: SlopDeskWsGuiTelemetry,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    let mut blob = Vec::new();
    for row in gui_readout::stat_rows(&stats.rules()) {
        push_text(&mut blob, &row);
    }
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe { deliver(&blob, out, cap) }
}

/// Mbps at the surface from kbps on the wire, one decimal — or the em dash until the first
/// measurement lands.
///
/// # Safety
/// `(out, cap)` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and `(out, cap)` is the caller's buffer"
)]
pub unsafe extern "C" fn slopdesk_ws_gui_mbps_label(
    has_kbps: bool,
    kbps: i64,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    let answer = gui_readout::mbps_label(optional_of(has_kbps, kbps));
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe { deliver(answer.as_bytes(), out, cap) }
}

/// A per-second rate, one decimal, with its unit attached — so an absent one still reads as a rate.
///
/// # Safety
/// `(out, cap)` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and `(out, cap)` is the caller's buffer"
)]
pub unsafe extern "C" fn slopdesk_ws_gui_per_sec_label(
    has_value: bool,
    value: f64,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    let answer = gui_readout::per_sec_label(optional_of(has_value, value));
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe { deliver(answer.as_bytes(), out, cap) }
}

/// A millisecond duration, one decimal. The unit lives in the row label, not in the answer.
///
/// # Safety
/// `(out, cap)` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and `(out, cap)` is the caller's buffer"
)]
pub unsafe extern "C" fn slopdesk_ws_gui_ms_label(
    has_value: bool,
    value: f64,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    let answer = gui_readout::ms_label(optional_of(has_value, value));
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe { deliver(answer.as_bytes(), out, cap) }
}

/// The stall caption: `RECONNECTING`, plus a floored age once the stall's epoch is known.
///
/// `elapsed` is SECONDS, not an instant. The caller owns the clock and does the subtraction, so the
/// rule can be asked about a chosen moment — the same split `slopdesk_ws_pane_settle_due` takes.
///
/// # Safety
/// `(out, cap)` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and `(out, cap)` is the caller's buffer"
)]
pub unsafe extern "C" fn slopdesk_ws_gui_stall_caption(
    has_since: bool,
    elapsed: f64,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    let answer = gui_readout::stall_caption(optional_of(has_since, elapsed));
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe { deliver(answer.as_bytes(), out, cap) }
}

/// What the non-live placeholder says, for a display code of `0` live, `1` entry form, `2` gated.
///
/// A code this build cannot name answers the neutral word rather than the cap's accusation.
///
/// # Safety
/// `(out, cap)` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and `(out, cap)` is the caller's buffer"
)]
pub const unsafe extern "C" fn slopdesk_ws_gui_placeholder_label(
    display: c_uchar,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    let answer = gui_readout::placeholder_label(Display::from_code(display));
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe { deliver(answer.as_bytes(), out, cap) }
}

/// An fps choice's label. `0` is the absence of a cap, not a cadence of zero.
///
/// # Safety
/// `(out, cap)` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and `(out, cap)` is the caller's buffer"
)]
pub unsafe extern "C" fn slopdesk_ws_gui_fps_choice_label(fps: i64, out: *mut c_uchar, cap: usize) -> usize {
    let answer = gui_readout::fps_choice_label(fps);
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe { deliver(answer.as_bytes(), out, cap) }
}

/// A bitrate choice's label, with its unit. Same `0 → Auto` rule as the axis beside it.
///
/// # Safety
/// `(out, cap)` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and `(out, cap)` is the caller's buffer"
)]
pub unsafe extern "C" fn slopdesk_ws_gui_mbps_choice_label(
    mbps: i64,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    let answer = gui_readout::mbps_choice_label(mbps);
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe { deliver(answer.as_bytes(), out, cap) }
}

/// Mbps at the surface, bps on the model and the wire. Truncates, because the picker has no
/// fractional row to land on.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_ws_gui_mbps_from_bps(bps: i64) -> i64 {
    gui_readout::mbps_from_bps(bps)
}

/// The inverse, SATURATING: a panic crossing this boundary aborts the process, so a corrupt Mbps
/// lands on a legal number. `0` stays `0`, which is Auto on both sides.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_ws_gui_bps_from_mbps(mbps: i64) -> i64 {
    gui_readout::bps_from_mbps(mbps)
}

/// Whether any LATCHED pane mode is engaged — what the control bar tints and the collapsed chip
/// inherits.
///
/// Five arguments rather than a packed byte: two of them are CAPS and not flags, so there is no
/// word this could ride in that would not need the numbers beside it anyway.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_ws_gui_has_latched_mode(
    immersive: bool,
    viewport_locked: bool,
    audio_enabled: bool,
    stream_fps_cap: i64,
    stream_bitrate_ceiling_bps: i64,
) -> bool {
    gui_readout::has_latched_mode(
        immersive,
        viewport_locked,
        audio_enabled,
        stream_fps_cap,
        stream_bitrate_ceiling_bps,
    )
}

/// The video activation task's identity, as `hash:generation:visible`.
///
/// # Safety
/// `(out, cap)` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and `(out, cap)` is the caller's buffer"
)]
pub unsafe extern "C" fn slopdesk_ws_gui_activation_key(
    pane_hash: i64,
    promotion_generation: i64,
    is_visible: bool,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    let answer = gui_readout::activation_key(pane_hash, promotion_generation, is_visible);
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe { deliver(answer.as_bytes(), out, cap) }
}

/// The upload row's SF Symbol name, for a phase code of `0` sending, `1` completed, `2` failed.
///
/// A code this build cannot name reads as still-sending: the other two claim the transfer settled,
/// and a glyph that says "done" for a byte nobody defined would report a completion that never
/// happened.
///
/// # Safety
/// `(out, cap)` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and `(out, cap)` is the caller's buffer"
)]
pub const unsafe extern "C" fn slopdesk_ws_gui_upload_glyph(
    phase: c_uchar,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    let answer = gui_readout::upload_glyph(UploadPhase::from_code(phase));
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe { deliver(answer.as_bytes(), out, cap) }
}

/// The upload row's TONE: `0` the resting icon tone, `1` the accent.
///
/// A semantic, never a colour — this crate is one floor under the design token tables, and each
/// framework looks its own up. Only the branch crosses, which is the part that could be wrong.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_ws_gui_upload_tint(phase: c_uchar) -> c_uchar {
    gui_readout::upload_tint(UploadPhase::from_code(phase)).code()
}

#[cfg(test)]
mod tests {
    #![expect(unsafe_code, reason = "calling the boundary IS what these tests are for")]

    use slopdesk_workspace::gui_readout::{self, Display, Telemetry, UploadPhase, UploadTint};

    use super::{
        SlopDeskWsGuiTelemetry, slopdesk_ws_gui_activation_key, slopdesk_ws_gui_bps_from_mbps,
        slopdesk_ws_gui_fps_choice_label, slopdesk_ws_gui_has_latched_mode,
        slopdesk_ws_gui_mbps_choice_label, slopdesk_ws_gui_mbps_from_bps, slopdesk_ws_gui_mbps_label,
        slopdesk_ws_gui_ms_label, slopdesk_ws_gui_per_sec_label, slopdesk_ws_gui_placeholder_label,
        slopdesk_ws_gui_stall_caption, slopdesk_ws_gui_stat_rows, slopdesk_ws_gui_upload_glyph,
        slopdesk_ws_gui_upload_tint,
    };
    use crate::testing::{delivered, runs};

    /// The sample the deleted Swift suite measured, as the record the near side hands over.
    fn measured() -> SlopDeskWsGuiTelemetry {
        SlopDeskWsGuiTelemetry {
            stats_fps: 59.6,
            stats_fec_per_sec: 1.24,
            stats_unrecovered_per_sec: 0.0,
            stats_rtt_ms: 8.04,
            stats_encode_ms: 2.5,
            stats_decode_ms: 1.1,
            stream_fps: 60,
            stream_kbps: 12500,
            stats_pacer_depth: 3,
            stats_hold_ms: 16,
            has_stats_fps: true,
            has_stats_fec_per_sec: true,
            has_stats_unrecovered_per_sec: true,
            has_stats_rtt_ms: true,
            has_stats_encode_ms: true,
            has_stats_decode_ms: true,
            has_stream_fps: true,
            has_stream_kbps: true,
            has_stats_pacer_depth: true,
            has_stats_hold_ms: true,
        }
    }

    /// The five rows the door delivers are the five rows the rule gives directly — the differential
    /// the boundary exists to keep true, asserted over a measured sample and an unmeasured one.
    #[test]
    fn the_rows_cross_verbatim_measured_and_unmeasured() {
        for record in [measured(), SlopDeskWsGuiTelemetry::default()] {
            let blob = delivered(|out, cap| {
                // SAFETY: `out` is a live local for the call.
                unsafe { slopdesk_ws_gui_stat_rows(record, out, cap) }
            });
            let crossed = runs(&blob, 5);
            let native = gui_readout::stat_rows(&record.rules());
            for (index, row) in native.iter().enumerate() {
                assert_eq!(crossed.get(index).map(String::as_str), Some(row.as_str()));
            }
        }
    }

    /// A default record is TEN absences and not ten zeroes — the flag is what says which, and a
    /// door that dropped one would print a measured zero for a stream nobody has sampled.
    #[test]
    fn a_zeroed_record_reads_as_absent_everywhere() {
        let blob = delivered(|out, cap| {
            // SAFETY: `out` is a live local for the call.
            unsafe { slopdesk_ws_gui_stat_rows(SlopDeskWsGuiTelemetry::default(), out, cap) }
        });
        assert_eq!(runs(&blob, 5), vec![
            "— FPS · — MBPS",
            "RX — FPS · DEPTH —",
            "FEC —/S · LOST —/S",
            "RTT — · ENC — · DEC —",
            "HOLD — MS",
        ]);
    }

    /// Turns on ONE presence flag, so a case can name the flag it is about and nothing else.
    type Lights = fn(&mut SlopDeskWsGuiTelemetry);

    /// Every flag is read, and each one on its own: a record with ONE measurement set prints that
    /// slot and no other, which is what a swapped or dropped flag would break.
    #[test]
    fn each_presence_flag_lights_exactly_its_own_slot() {
        let cases: [(Lights, &str); 10] = [
            (|record| record.has_stream_fps = true, "9 FPS"),
            (|record| record.has_stream_kbps = true, "9.0 MBPS"),
            (|record| record.has_stats_fps = true, "RX 9 FPS"),
            (|record| record.has_stats_pacer_depth = true, "DEPTH 9"),
            (|record| record.has_stats_fec_per_sec = true, "FEC 9.0/S"),
            (|record| record.has_stats_unrecovered_per_sec = true, "LOST 9.0/S"),
            (|record| record.has_stats_rtt_ms = true, "RTT 9.0"),
            (|record| record.has_stats_encode_ms = true, "ENC 9.0"),
            (|record| record.has_stats_decode_ms = true, "DEC 9.0"),
            (|record| record.has_stats_hold_ms = true, "HOLD 9 MS"),
        ];
        for (set, needle) in cases {
            let mut record = SlopDeskWsGuiTelemetry {
                stats_fps: 9.0,
                stats_fec_per_sec: 9.0,
                stats_unrecovered_per_sec: 9.0,
                stats_rtt_ms: 9.0,
                stats_encode_ms: 9.0,
                stats_decode_ms: 9.0,
                stream_fps: 9,
                stream_kbps: 9000,
                stats_pacer_depth: 9,
                stats_hold_ms: 9,
                ..SlopDeskWsGuiTelemetry::default()
            };
            set(&mut record);
            let blob = delivered(|out, cap| {
                // SAFETY: `out` is a live local for the call.
                unsafe { slopdesk_ws_gui_stat_rows(record, out, cap) }
            });
            let joined = runs(&blob, 5).join("\n");
            assert!(joined.contains(needle), "{needle} missing from\n{joined}");
            assert_eq!(
                joined.matches('9').count(),
                needle.matches('9').count(),
                "exactly one slot may light\n{joined}"
            );
        }
    }

    /// A short buffer is told the length and written nothing, which is §4's retry contract — the
    /// half that matters, because a partial delivery would desynchronise the near side's splitter.
    #[test]
    fn a_short_buffer_is_told_the_length_and_left_untouched() {
        let mut out = [0xAA_u8; 8];
        // SAFETY: `out` is a live local for the call.
        let needed = unsafe { slopdesk_ws_gui_stat_rows(measured(), out.as_mut_ptr(), out.len()) };
        assert!(needed > out.len());
        assert_eq!(out, [0xAA; 8], "nothing was written");
        // SAFETY: a null `out` with a zero cap is the documented way to ask for the length.
        let sizing = unsafe { slopdesk_ws_gui_stat_rows(measured(), core::ptr::null_mut(), 0) };
        assert_eq!(sizing, needed, "sizing and retrying agree");
    }

    /// Every formatter crosses with the exact string the rule gives, including its absent arm.
    #[test]
    fn the_three_formatters_cross_verbatim() {
        for kbps in [0_i64, 999, 12500, 20000] {
            let crossed = delivered(|out, cap| {
                // SAFETY: `out` is a live local for the call.
                unsafe { slopdesk_ws_gui_mbps_label(true, kbps, out, cap) }
            });
            assert_eq!(
                String::from_utf8_lossy(&crossed),
                gui_readout::mbps_label(Some(kbps))
            );
        }
        for value in [0.0_f64, 1.24, 8.04, -0.04] {
            let rate = delivered(|out, cap| {
                // SAFETY: `out` is a live local for the call.
                unsafe { slopdesk_ws_gui_per_sec_label(true, value, out, cap) }
            });
            assert_eq!(
                String::from_utf8_lossy(&rate),
                gui_readout::per_sec_label(Some(value))
            );
            let millis = delivered(|out, cap| {
                // SAFETY: `out` is a live local for the call.
                unsafe { slopdesk_ws_gui_ms_label(true, value, out, cap) }
            });
            assert_eq!(
                String::from_utf8_lossy(&millis),
                gui_readout::ms_label(Some(value))
            );
        }
    }

    /// The absent arm is the FLAG's, not the value's: a `false` flag beside a live number still
    /// prints the em dash, which is the one thing a sentinel convention could not have said.
    #[test]
    fn a_false_flag_beats_the_number_beside_it() {
        let crossed = delivered(|out, cap| {
            // SAFETY: `out` is a live local for the call.
            unsafe { slopdesk_ws_gui_mbps_label(false, 99999, out, cap) }
        });
        assert_eq!(String::from_utf8_lossy(&crossed), gui_readout::mbps_label(None));
        let rate = delivered(|out, cap| {
            // SAFETY: `out` is a live local for the call.
            unsafe { slopdesk_ws_gui_per_sec_label(false, 7.5, out, cap) }
        });
        assert_eq!(String::from_utf8_lossy(&rate), "—/S");
        let millis = delivered(|out, cap| {
            // SAFETY: `out` is a live local for the call.
            unsafe { slopdesk_ws_gui_ms_label(false, 7.5, out, cap) }
        });
        assert_eq!(String::from_utf8_lossy(&millis), "—");
    }

    /// The caption crosses with its age floored and clamped, and its epoch-less arm is the flag's.
    #[test]
    fn the_stall_caption_crosses_with_its_age() {
        for elapsed in [0.0_f64, 12.7, -5.0, 59.999] {
            let crossed = delivered(|out, cap| {
                // SAFETY: `out` is a live local for the call.
                unsafe { slopdesk_ws_gui_stall_caption(true, elapsed, out, cap) }
            });
            assert_eq!(
                String::from_utf8_lossy(&crossed),
                gui_readout::stall_caption(Some(elapsed))
            );
        }
        let epochless = delivered(|out, cap| {
            // SAFETY: `out` is a live local for the call.
            unsafe { slopdesk_ws_gui_stall_caption(false, 99.0, out, cap) }
        });
        assert_eq!(String::from_utf8_lossy(&epochless), "RECONNECTING");
    }

    /// Every display code crosses to its own word, and an unnamed one is not the cap's accusation.
    #[test]
    fn every_display_code_crosses_and_an_unnamed_one_is_neutral() {
        for display in Display::ALL {
            let crossed = delivered(|out, cap| {
                // SAFETY: `out` is a live local for the call.
                unsafe { slopdesk_ws_gui_placeholder_label(display.code(), out, cap) }
            });
            assert_eq!(
                String::from_utf8_lossy(&crossed),
                gui_readout::placeholder_label(display),
                "{display:?}"
            );
        }
        let unnamed = delivered(|out, cap| {
            // SAFETY: `out` is a live local for the call.
            unsafe { slopdesk_ws_gui_placeholder_label(200, out, cap) }
        });
        assert_eq!(String::from_utf8_lossy(&unnamed), "desktop");
    }

    /// Both choice labels cross verbatim, including the `0 → Auto` rule they share.
    #[test]
    fn both_choice_labels_cross_verbatim() {
        for fps in [0_i64, 15, 30, 60] {
            let crossed = delivered(|out, cap| {
                // SAFETY: `out` is a live local for the call.
                unsafe { slopdesk_ws_gui_fps_choice_label(fps, out, cap) }
            });
            assert_eq!(
                String::from_utf8_lossy(&crossed),
                gui_readout::fps_choice_label(fps)
            );
        }
        for mbps in [0_i64, 5, 10, 20, 50] {
            let crossed = delivered(|out, cap| {
                // SAFETY: `out` is a live local for the call.
                unsafe { slopdesk_ws_gui_mbps_choice_label(mbps, out, cap) }
            });
            assert_eq!(
                String::from_utf8_lossy(&crossed),
                gui_readout::mbps_choice_label(mbps)
            );
        }
    }

    /// The unit conversion round-trips through the door for every offered choice, and saturates
    /// rather than aborting the process on a value no picker can produce.
    #[test]
    fn the_unit_conversion_crosses_both_ways() {
        for mbps in [0_i64, 5, 10, 20, 50] {
            assert_eq!(
                slopdesk_ws_gui_mbps_from_bps(slopdesk_ws_gui_bps_from_mbps(mbps)),
                mbps
            );
        }
        assert_eq!(slopdesk_ws_gui_mbps_from_bps(12_500_000), 12);
        assert_eq!(slopdesk_ws_gui_bps_from_mbps(i64::MAX), i64::MAX);
    }

    /// Each latched clause crosses on its own — a dropped one is invisible in a combined case.
    #[test]
    fn each_latched_clause_crosses_on_its_own() {
        assert!(!slopdesk_ws_gui_has_latched_mode(false, false, false, 0, 0));
        assert!(slopdesk_ws_gui_has_latched_mode(true, false, false, 0, 0));
        assert!(slopdesk_ws_gui_has_latched_mode(false, true, false, 0, 0));
        assert!(slopdesk_ws_gui_has_latched_mode(false, false, true, 0, 0));
        assert!(slopdesk_ws_gui_has_latched_mode(false, false, false, 30, 0));
        assert!(slopdesk_ws_gui_has_latched_mode(
            false, false, false, 0, 10_000_000
        ));
    }

    /// The activation key crosses verbatim and moves on all three of its edges.
    #[test]
    fn the_activation_key_crosses_verbatim() {
        let key = |hash: i64, generation: i64, visible: bool| {
            let blob = delivered(|out, cap| {
                // SAFETY: `out` is a live local for the call.
                unsafe { slopdesk_ws_gui_activation_key(hash, generation, visible, out, cap) }
            });
            String::from_utf8_lossy(&blob).into_owned()
        };
        assert_eq!(key(7, 1, true), gui_readout::activation_key(7, 1, true));
        assert_eq!(key(7, 1, true), "7:1:1");
        assert_ne!(key(7, 1, true), key(8, 1, true));
        assert_ne!(key(7, 1, true), key(7, 2, true));
        assert_ne!(key(7, 1, true), key(7, 1, false));
    }

    /// Every phase crosses to its own glyph and tone, and an unnamed byte has not settled.
    #[test]
    fn every_phase_crosses_to_its_mark_and_an_unnamed_one_is_still_in_flight() {
        for phase in UploadPhase::ALL {
            let glyph = delivered(|out, cap| {
                // SAFETY: `out` is a live local for the call.
                unsafe { slopdesk_ws_gui_upload_glyph(phase.code(), out, cap) }
            });
            assert_eq!(
                String::from_utf8_lossy(&glyph),
                gui_readout::upload_glyph(phase),
                "{phase:?}"
            );
            assert_eq!(
                slopdesk_ws_gui_upload_tint(phase.code()),
                gui_readout::upload_tint(phase).code(),
                "{phase:?}"
            );
        }
        let unnamed = delivered(|out, cap| {
            // SAFETY: `out` is a live local for the call.
            unsafe { slopdesk_ws_gui_upload_glyph(9, out, cap) }
        });
        assert_eq!(String::from_utf8_lossy(&unnamed), "arrow.up.circle");
        assert_eq!(slopdesk_ws_gui_upload_tint(9), UploadTint::Icon.code());
    }

    /// The record's flag/value pairs rebuild the rule's ten `Option`s in the right order — the one
    /// mistake a twenty-field struct invites, and the one no formatter test could localise.
    #[test]
    fn the_record_rebuilds_the_rules_sample_field_for_field() {
        let record = measured();
        assert_eq!(record.rules(), Telemetry {
            stream_fps: Some(60),
            stream_kbps: Some(12500),
            stats_fps: Some(59.6),
            stats_pacer_depth: Some(3),
            stats_fec_per_sec: Some(1.24),
            stats_unrecovered_per_sec: Some(0.0),
            stats_rtt_ms: Some(8.04),
            stats_encode_ms: Some(2.5),
            stats_decode_ms: Some(1.1),
            stats_hold_ms: Some(16),
        });
        assert_eq!(SlopDeskWsGuiTelemetry::default().rules(), Telemetry::default());
    }
}
