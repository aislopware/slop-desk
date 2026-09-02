//! What a live video (PATH 2) pane ADMITS, and the two sentences it puts in front of somebody.
//!
//! [`crate::gui_readout`] is the other half of this pane and they do not overlap: that module
//! RENDERS a reading — five stat rows, three formatters, a stall caption — and this one decides
//! whether the reading is a reading at all. A number arrives from a decoder, a governor or an entry
//! field, and everything below answers the same question about it: is that a fact, or is it the
//! absence of one wearing a fact's clothes?
//!
//! All of it was `RemoteWindowModel`, a Swift `@Observable` class where each rule sat inside the
//! property write it guarded. The writes stay in Swift — that is what `@Observable` is — and the
//! guards came here, because none of them names a view, a session or a socket.
//!
//! ## A ZERO IS NOT ONE THING
//!
//! The law the whole module turns on, and it is deliberately NOT uniform:
//!
//! * A cadence of `0` frames per second is nonsense — no encoder announces it — so
//!   [`admits_stream_fps`] drops it and the last good announcement stands. A spurious zero must
//!   never blank a row that was right a moment ago.
//! * A payload bitrate of `0` kbps is a MEASUREMENT: an idle stream skips frames and nothing flows.
//!   [`admits_stream_kbps`] keeps it and refuses only a negative.
//! * A latency of `0` ms is the absence of a reading — an old host, telemetry off, or the first
//!   window still filling — so [`network_reading`] maps it to `None` and the readout draws a dash
//!   rather than a link with no delay on it.
//!
//! Three different answers to "what does zero mean" in one sample, which is exactly why they are
//! written down once rather than re-derived at each call site.
//!
//! ## THE READING IS ALL OR NOTHING
//!
//! [`network_reading`] refuses the WHOLE sample when any axis is negative rather than keeping the
//! good axes. Rates and depths are non-negative by construction, so a negative one means the
//! telemetry window itself is wrong, and mixing a trustworthy frame rate with a garbage loss count
//! produces a readout that is confidently incorrect on half its rows. A `NaN` fails every `>=`
//! comparison here, in Rust and in the Swift this replaces, so it is refused by the same clause.
//!
//! ## THE ENTRY FIELD IS SWIFT'S PARSER, SPELLED OUT
//!
//! [`parse_window_id`] is not `str::parse`. It reproduces `UInt32(text.trimmingCharacters(in:
//! .whitespaces))` on two points where the standard libraries disagree, both reachable by typing
//! into the pane's window-id field:
//!
//! * Swift's `CharacterSet.whitespaces` is the Unicode `Zs` category plus U+0009 and NOTHING else.
//!   Rust's [`str::trim`] also eats `\n`, `\r`, U+000B, U+000C, U+0085, U+2028 and U+2029, so a
//!   pasted `"42\n"` would become an OPEN here where Swift refused it.
//! * Swift accepts a leading `-` and succeeds when the digits are all zero — `UInt32("-0")` is `0`
//!   — where Rust's `"-0".parse::<u32>()` is an error. Both accept a leading `+`.
//!
//! Both were measured against the Swift runtime rather than remembered, and the tests below pin
//! each character of the trim set.

/// Two point dimensions of a host window, as the resize popover pre-fills them.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Size {
    /// The width, in points.
    pub width: f64,
    /// The height, in points.
    pub height: f64,
}

/// What one geometry push from the live pane is allowed to write.
///
/// Two independent verdicts rather than one, because the two sizes arrive together and are admitted
/// apart: a host that has reported its window but not yet its display bounds pushes a real current
/// size beside a zero max, and the popover must take the first and leave its fields uncapped.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct GeometryUpdate {
    /// The window's current point size, or `None` when the push carried no usable one.
    pub current: Option<Size>,
    /// The maximum resizable point size, or `None` when the push carried no usable one.
    pub max: Option<Size>,
}

/// One raw ~2 Hz network sample, exactly as the live pane's telemetry windows hand it over.
///
/// A struct rather than eight arguments because it is ONE sample: a caller that can pass half of it
/// is a caller that can mix two windows, and the all-or-nothing rule below would then be deciding
/// about a reading that never existed.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct NetworkSample {
    /// Frames per second received.
    pub fps: f64,
    /// Frames per second the error correction recovered.
    pub fec_per_sec: f64,
    /// Frames per second lost past recovery.
    pub unrecovered_per_sec: f64,
    /// The host's smoothed round-trip time, in milliseconds. `0` means "not reported".
    pub rtt_ms: f64,
    /// The host's encode-wall EWMA, in milliseconds. `0` means "not reported".
    pub encode_ms: f64,
    /// The client's decode-wall EWMA, in milliseconds. `0` means "not reported".
    pub decode_ms: f64,
    /// How long the newest frame has been held, in milliseconds.
    pub hold_ms: i64,
    /// How many frames the presentation pacer is holding.
    pub pacer_depth: i64,
}

/// One ADMITTED network sample: the rate axes as measurements, the latency axes as `Option`s.
///
/// The type difference is the rule. A rate that measured zero is a `f64` here because zero is what
/// it measured; a latency that read zero is a `None` because zero is what "nobody measured" was
/// spelled as on the wire.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct NetworkReading {
    /// Frames per second received.
    pub fps: f64,
    /// Frames per second the error correction recovered.
    pub fec_per_sec: f64,
    /// Frames per second lost past recovery.
    pub unrecovered_per_sec: f64,
    /// Round-trip time in milliseconds, or `None` when the host reported none.
    pub rtt_ms: Option<f64>,
    /// Encode wall time in milliseconds, or `None` when the host reported none.
    pub encode_ms: Option<f64>,
    /// Decode wall time in milliseconds, or `None` when nothing has decoded yet.
    pub decode_ms: Option<f64>,
    /// How long the newest frame has been held, in milliseconds.
    pub hold_ms: i64,
    /// How many frames the presentation pacer is holding.
    pub pacer_depth: i64,
}

/// What an immersive toggle commits: the two flags after the fold, and whether it is worth telling
/// the persistence sink about.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ImmersiveCommit {
    /// The latched wish after the fold — always the requested value.
    pub desired: bool,
    /// The fullscreen auto-arm after the fold, which an explicit OFF always clears.
    pub fullscreen_override: bool,
    /// Whether the latched wish actually moved, and so whether the spec should be rewritten.
    pub notifies: bool,
}

/// The two stream overrides a restored pane starts with, clamped.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct SeededCaps {
    /// The fps cap; `0` is Auto.
    pub fps_cap: i64,
    /// The bitrate ceiling in bits per second; `0` is Auto.
    pub bitrate_ceiling_bps: i64,
}

/// Whether one pushed point size is a size at all — both axes strictly positive.
///
/// A zero on either axis is what a host sends before it knows the answer, and a negative one cannot
/// be drawn, so the two collapse to the same refusal.
#[must_use]
pub const fn admits_size(width: f64, height: f64) -> bool {
    width > 0.0 && height > 0.0
}

/// What one geometry push writes: the current size if it is one, the max if it is one.
///
/// The MAX PERSISTS on the near side — a later zero-max push answers `None` here and the caller
/// leaves the cap it already knows standing. That asymmetry is the caller's, deliberately: this
/// rule sees one push and has no memory to consult.
#[must_use]
pub const fn geometry_update(
    current_width: f64,
    current_height: f64,
    max_width: f64,
    max_height: f64,
) -> GeometryUpdate {
    GeometryUpdate {
        current: if admits_size(current_width, current_height) {
            Some(Size {
                width: current_width,
                height: current_height,
            })
        } else {
            None
        },
        max: if admits_size(max_width, max_height) {
            Some(Size {
                width: max_width,
                height: max_height,
            })
        } else {
            None
        },
    }
}

/// Whether a host-announced cadence is an announcement. Non-positive is not.
///
/// The last good cadence stands when this refuses: a governor that momentarily reports nothing has
/// not changed the stream's rate to zero, and blanking the row would say it had.
#[must_use]
pub const fn admits_stream_fps(fps: i64) -> bool {
    fps > 0
}

/// Whether a measured payload bitrate is a measurement. Only a negative is not.
///
/// The one axis where zero is kept: an idle stream skips frames, nothing flows, and `0 MBPS` is the
/// honest reading rather than a gap.
#[must_use]
pub const fn admits_stream_kbps(kbps: i64) -> bool {
    kbps >= 0
}

/// One ~2 Hz sample as a reading, or `None` when any axis is negative.
///
/// A `NaN` on any float axis fails its `>=` and takes the whole sample with it, which is what the
/// Swift comparison did and what the arithmetic below would otherwise propagate into a row.
#[must_use]
pub const fn network_reading(sample: NetworkSample) -> Option<NetworkReading> {
    let admitted = sample.fps >= 0.0
        && sample.fec_per_sec >= 0.0
        && sample.unrecovered_per_sec >= 0.0
        && sample.hold_ms >= 0
        && sample.pacer_depth >= 0
        && sample.rtt_ms >= 0.0
        && sample.encode_ms >= 0.0
        && sample.decode_ms >= 0.0;
    if !admitted {
        return None;
    }
    Some(NetworkReading {
        fps: sample.fps,
        fec_per_sec: sample.fec_per_sec,
        unrecovered_per_sec: sample.unrecovered_per_sec,
        rtt_ms: if sample.rtt_ms > 0.0 {
            Some(sample.rtt_ms)
        } else {
            None
        },
        encode_ms: if sample.encode_ms > 0.0 {
            Some(sample.encode_ms)
        } else {
            None
        },
        decode_ms: if sample.decode_ms > 0.0 {
            Some(sample.decode_ms)
        } else {
            None
        },
        hold_ms: sample.hold_ms,
        pacer_depth: sample.pacer_depth,
    })
}

/// The immersive toggle's fold: the wish moves to `on`, and an explicit OFF drops the fullscreen
/// auto-arm with it.
///
/// The escape hatch has to win. Fullscreen arms system-key capture on its own, so without this
/// clause a user in fullscreen who turns immersive OFF — from the footer chip or the ⌃⌥⌘E chord —
/// would watch the keyboard stay captured with no in-stream way out, which is the failure mode
/// `docs/DECISIONS.md` records as the Moonlight lesson.
///
/// [`ImmersiveCommit::notifies`] is false for a redundant set so a mirror-sync cannot spam the
/// persistence sink; the auto-arm is cleared either way, BEFORE that dedup, because the clause
/// above is about the override and not about the wish.
#[must_use]
pub const fn immersive_commit(on: bool, desired: bool, fullscreen_override: bool) -> ImmersiveCommit {
    ImmersiveCommit {
        desired: on,
        fullscreen_override: fullscreen_override && on,
        notifies: desired != on,
    }
}

/// A restored mode snapshot's two overrides, floored at `0` — which is Auto, the value a fresh
/// session already holds.
///
/// A negative cap in a hand-edited workspace file must not travel to the host as a request, and
/// refusing the whole restore over one bad number would lose the three modes beside it.
#[must_use]
pub const fn seeded_caps(fps_cap: i64, bitrate_ceiling_bps: i64) -> SeededCaps {
    SeededCaps {
        fps_cap: if fps_cap < 0 { 0 } else { fps_cap },
        bitrate_ceiling_bps: if bitrate_ceiling_bps < 0 {
            0
        } else {
            bitrate_ceiling_bps
        },
    }
}

/// The characters Swift's `CharacterSet.whitespaces` holds: Unicode `Zs`, plus the tab.
///
/// Written out rather than reached for, because every ambient spelling is wrong here. Rust's
/// [`char::is_whitespace`] adds the line breaks, `Zs` alone omits U+0009, and either substitution
/// turns a refusal into an open for text a user can paste.
const fn is_entry_whitespace(character: char) -> bool {
    matches!(
        character,
        '\u{0009}' | '\u{0020}' | '\u{00A0}' | '\u{1680}' | '\u{2000}'
            ..='\u{200A}' | '\u{202F}' | '\u{205F}' | '\u{3000}'
    )
}

/// The window id an entry field holds, or `None` when what is in it is not one.
///
/// Swift's `UInt32(_:)` in full: an optional `+` or `-` sign, then ASCII decimal digits and only
/// those. A `-` is accepted when every digit is `0`, because negating zero lands back on zero — a
/// quirk, but one a user can reach by typing, and the port either has it or the field answers
/// differently on the two halves of the same app. Overflow past `u32::MAX`, an empty string, a bare
/// sign, an inner space, a `0x` prefix, an underscore and a non-ASCII digit are each refusals.
#[must_use]
pub fn parse_window_id(entered: &str) -> Option<u32> {
    let trimmed = entered.trim_matches(is_entry_whitespace);
    let (negative, digits) = trimmed.strip_prefix('-').map_or_else(
        || (false, trimmed.strip_prefix('+').unwrap_or(trimmed)),
        |rest| (true, rest),
    );
    if digits.is_empty() {
        return None;
    }
    let mut value: u32 = 0;
    for character in digits.chars() {
        let digit = character.to_digit(10)?;
        value = value.checked_mul(10)?.checked_add(digit)?;
    }
    if negative && value != 0 {
        return None;
    }
    Some(value)
}

/// What the opened descriptor is CALLED: the bound title, or the window's own number when it has
/// none.
///
/// The id crosses as display data here, the way [`crate::gui_readout::activation_key`]'s pane hash
/// does. It is not being compared, resolved or handed back — a window with no title has nothing
/// else to be called, and `window 7` is the fallback the automation seam has always spelled.
#[must_use]
pub fn descriptor_title(title: &str, window_id: u32) -> String {
    if title.is_empty() {
        format!("window {window_id}")
    } else {
        title.to_owned()
    }
}

/// What the placeholder says when the host REFUSES the session — the target is gone, or the two
/// halves disagree about the protocol.
///
/// The title is quoted with typographic quotes when there is one, and named generically when there
/// is not, so the sentence reads as a sentence either way rather than as `"" is no longer
/// available`.
#[must_use]
pub fn rejection_message(title: &str) -> String {
    let name = if title.is_empty() {
        "The stream target".to_owned()
    } else {
        format!("\u{201C}{title}\u{201D}")
    };
    format!("{name} is no longer available on the host.")
}

/// What the placeholder says when NOTHING answered the hello — no `slopdesk-videohostd` on the
/// host at all, or one on other ports — as opposed to a host that refused.
///
/// Names the address the pane dialled and the daemon that would have answered, because the fix is
/// on the host and the person reading this is at the client. An empty host reads as the loopback
/// default rather than as `:9000`.
#[must_use]
pub fn unreachable_message(host: &str, media_port: u16) -> String {
    let host = if host.is_empty() { "127.0.0.1" } else { host };
    format!(
        "No video host answered at {host}:{media_port}. Start slopdesk-videohostd on the host (`just \
         videohostd-install` in a checkout) and open the window again."
    )
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use super::{
        GeometryUpdate, ImmersiveCommit, NetworkSample, SeededCaps, Size, admits_size, admits_stream_fps,
        admits_stream_kbps, descriptor_title, geometry_update, immersive_commit, network_reading,
        parse_window_id, rejection_message, seeded_caps, unreachable_message,
    };

    /// The whole of Swift's `CharacterSet.whitespaces`, measured against the Swift runtime rather
    /// than recalled — each of these trims and the id behind it parses.
    #[test]
    fn every_character_swift_calls_whitespace_is_trimmed() {
        for scalar in [
            '\u{0009}', '\u{0020}', '\u{00A0}', '\u{1680}', '\u{2000}', '\u{2001}', '\u{2002}', '\u{2003}',
            '\u{2004}', '\u{2005}', '\u{2006}', '\u{2007}', '\u{2008}', '\u{2009}', '\u{200A}', '\u{202F}',
            '\u{205F}', '\u{3000}',
        ] {
            let padded = format!("{scalar}{scalar}7{scalar}");
            assert_eq!(parse_window_id(&padded), Some(7), "{scalar:?} should trim");
        }
    }

    /// The characters Rust WOULD have trimmed and Swift does not. Every one of these is reachable
    /// by pasting into the entry field, and each must refuse rather than open.
    #[test]
    fn the_line_breaks_rust_trims_are_not_whitespace_here() {
        for scalar in [
            '\u{000A}', '\u{000B}', '\u{000C}', '\u{000D}', '\u{0085}', '\u{2028}', '\u{2029}',
        ] {
            let trailing = format!("7{scalar}");
            assert_eq!(parse_window_id(&trailing), None, "{scalar:?} must not trim");
            let leading = format!("{scalar}7");
            assert_eq!(parse_window_id(&leading), None, "{scalar:?} must not trim");
        }
    }

    /// Both signs, spelled as Swift spells them: `+` is transparent, `-` survives only on zero.
    #[test]
    fn the_sign_rule_is_swifts_and_not_rusts() {
        assert_eq!(parse_window_id("+42"), Some(42));
        assert_eq!(parse_window_id("-0"), Some(0));
        assert_eq!(parse_window_id("-000"), Some(0));
        assert_eq!(parse_window_id("-1"), None);
        assert_eq!(parse_window_id("++4"), None);
        assert_eq!(parse_window_id("+"), None);
        assert_eq!(parse_window_id("-"), None);
        assert!(
            "-0".parse::<u32>().is_err(),
            "the divergence this parser exists for"
        );
    }

    /// The shapes a field can hold that are not a number, and the one boundary that is.
    #[test]
    fn the_refusals_and_the_ceiling() {
        for text in [
            "",
            "   ",
            "4 2",
            "0x2a",
            "4_2",
            "\u{0664}\u{0662}",
            "42px",
            "4294967296",
            "99999999999",
        ] {
            assert_eq!(parse_window_id(text), None, "{text:?} is not a window id");
        }
        assert_eq!(parse_window_id("4294967295"), Some(u32::MAX));
        assert_eq!(parse_window_id("0042"), Some(42));
        assert_eq!(parse_window_id("0"), Some(0));
    }

    /// Every id round-trips through the parser, over a sweep that includes both ends.
    #[test]
    fn every_id_survives_being_written_and_read() {
        for id in (0_u32..4096).chain([u32::MAX >> 1_u32, u32::MAX - 1, u32::MAX]) {
            assert_eq!(parse_window_id(&id.to_string()), Some(id));
            assert_eq!(parse_window_id(&format!(" {id}\u{00A0}")), Some(id));
        }
    }

    /// Both axes must be positive, and the two sizes are admitted independently — the case a host
    /// that has reported its window but not its display bounds produces on every open.
    #[test]
    fn a_size_needs_both_axes_and_the_two_are_judged_apart() {
        for (width, height, admitted) in [
            (1920.0, 1080.0, true),
            (0.0, 1080.0, false),
            (1920.0, 0.0, false),
            (-1.0, -1.0, false),
            (f64::NAN, 1080.0, false),
            (f64::INFINITY, 1080.0, true),
        ] {
            assert_eq!(admits_size(width, height), admitted, "{width} x {height}");
        }
        assert_eq!(geometry_update(800.0, 600.0, 0.0, 0.0), GeometryUpdate {
            current: Some(Size {
                width: 800.0,
                height: 600.0
            }),
            max: None,
        });
        assert_eq!(geometry_update(0.0, 0.0, 3840.0, 2160.0), GeometryUpdate {
            current: None,
            max: Some(Size {
                width: 3840.0,
                height: 2160.0
            }),
        });
        assert_eq!(geometry_update(0.0, 0.0, 0.0, 0.0), GeometryUpdate {
            current: None,
            max: None
        });
    }

    /// The three answers to "what does zero mean", side by side, so a change to one is visible
    /// against the other two.
    #[test]
    fn zero_means_three_different_things_on_three_axes() {
        assert!(!admits_stream_fps(0), "a cadence of zero is nonsense");
        assert!(admits_stream_fps(1));
        assert!(!admits_stream_fps(-1));
        assert!(admits_stream_kbps(0), "a bitrate of zero is an idle stream");
        assert!(!admits_stream_kbps(-1));
        let sample = NetworkSample {
            rtt_ms: 0.0,
            ..NetworkSample::default()
        };
        let reading = network_reading(sample).expect("an all-zero sample is a legal reading");
        assert_eq!(reading.rtt_ms, None, "a latency of zero is no reading at all");
        assert!(reading.fps.abs() < f64::EPSILON, "a rate of zero is a rate");
    }

    /// Each axis, alone, refuses the whole sample — the case a per-axis guard would have let past
    /// with seven good rows and one lie.
    #[test]
    fn one_bad_axis_refuses_the_whole_sample() {
        let spoilers: [fn(&mut NetworkSample); 8] = [
            |sample| sample.fps = -1.0,
            |sample| sample.fec_per_sec = -1.0,
            |sample| sample.unrecovered_per_sec = -1.0,
            |sample| sample.rtt_ms = -1.0,
            |sample| sample.encode_ms = -1.0,
            |sample| sample.decode_ms = -1.0,
            |sample| sample.hold_ms = -1,
            |sample| sample.pacer_depth = -1,
        ];
        for spoil in spoilers {
            let mut sample = NetworkSample {
                fps: 59.6,
                fec_per_sec: 1.25,
                unrecovered_per_sec: 0.0,
                rtt_ms: 8.0,
                encode_ms: 2.5,
                decode_ms: 1.5,
                hold_ms: 16,
                pacer_depth: 3,
            };
            spoil(&mut sample);
            assert_eq!(network_reading(sample), None);
        }
    }

    /// A `NaN` fails its comparison and takes the sample with it, on every float axis — the same
    /// arm the negative case lands in, and the reason no branch spells `is_nan`.
    #[test]
    fn a_nan_on_any_axis_is_refused_like_a_negative() {
        let spoilers: [fn(&mut NetworkSample); 6] = [
            |sample| sample.fps = f64::NAN,
            |sample| sample.fec_per_sec = f64::NAN,
            |sample| sample.unrecovered_per_sec = f64::NAN,
            |sample| sample.rtt_ms = f64::NAN,
            |sample| sample.encode_ms = f64::NAN,
            |sample| sample.decode_ms = f64::NAN,
        ];
        for spoil in spoilers {
            let mut sample = NetworkSample::default();
            spoil(&mut sample);
            assert_eq!(network_reading(sample), None);
        }
    }

    /// The measured sample crosses with its rates intact and its three latencies present.
    #[test]
    fn a_measured_sample_keeps_every_axis() {
        let sample = NetworkSample {
            fps: 59.6,
            fec_per_sec: 1.25,
            unrecovered_per_sec: 0.5,
            rtt_ms: 8.0,
            encode_ms: 2.5,
            decode_ms: 1.5,
            hold_ms: 16,
            pacer_depth: 3,
        };
        let reading = network_reading(sample).expect("a clean sample is admitted");
        assert_eq!(reading.rtt_ms, Some(8.0));
        assert_eq!(reading.encode_ms, Some(2.5));
        assert_eq!(reading.decode_ms, Some(1.5));
        assert_eq!(reading.hold_ms, 16);
        assert_eq!(reading.pacer_depth, 3);
    }

    /// The immersive fold over its whole domain: four inputs, eight cases, no gaps.
    #[test]
    fn the_immersive_fold_is_exhaustive_over_its_domain() {
        for on in [false, true] {
            for desired in [false, true] {
                for armed in [false, true] {
                    let commit = immersive_commit(on, desired, armed);
                    assert_eq!(commit.desired, on, "the wish always becomes what was asked");
                    assert_eq!(commit.notifies, desired != on, "a redundant set says nothing");
                    if on {
                        assert_eq!(
                            commit.fullscreen_override, armed,
                            "turning it ON leaves the arm alone"
                        );
                    } else {
                        assert!(!commit.fullscreen_override, "an explicit OFF is the escape hatch");
                    }
                }
            }
        }
    }

    /// The one case the Moonlight lesson is about: OFF while fullscreen-armed clears the arm even
    /// though the latched wish never moved, so nothing is published and the keyboard is released.
    #[test]
    fn an_off_while_armed_clears_the_arm_without_publishing() {
        assert_eq!(immersive_commit(false, false, true), ImmersiveCommit {
            desired: false,
            fullscreen_override: false,
            notifies: false,
        });
    }

    /// The restore clamp, over both signs on both axes.
    #[test]
    fn a_restored_cap_is_floored_at_auto() {
        assert_eq!(seeded_caps(30, 10_000_000), SeededCaps {
            fps_cap: 30,
            bitrate_ceiling_bps: 10_000_000
        });
        assert_eq!(seeded_caps(0, 0), SeededCaps {
            fps_cap: 0,
            bitrate_ceiling_bps: 0
        });
        assert_eq!(seeded_caps(-30, -1), SeededCaps {
            fps_cap: 0,
            bitrate_ceiling_bps: 0
        });
        assert_eq!(seeded_caps(i64::MIN, i64::MAX), SeededCaps {
            fps_cap: 0,
            bitrate_ceiling_bps: i64::MAX
        });
    }

    /// The title fallback and the sentence the host's refusal leaves behind, in both of their arms.
    #[test]
    fn the_two_sentences_have_both_arms() {
        assert_eq!(descriptor_title("", 7), "window 7");
        assert_eq!(descriptor_title("Terminal", 7), "Terminal");
        assert_eq!(descriptor_title("", 0), "window 0");
        assert_eq!(descriptor_title("", u32::MAX), "window 4294967295");
        assert_eq!(
            rejection_message(""),
            "The stream target is no longer available on the host."
        );
        assert_eq!(
            rejection_message("Xcode"),
            "\u{201C}Xcode\u{201D} is no longer available on the host."
        );
    }

    /// Neither sentence can come back empty, which is what lets the boundary keep spelling "no
    /// answer" as a length of zero.
    #[test]
    fn neither_sentence_is_ever_empty() {
        for title in ["", " ", "Xcode", "\u{201C}"] {
            assert!(!rejection_message(title).is_empty());
            assert!(!descriptor_title(title, 0).is_empty());
        }
    }

    /// The unreachable sentence names the address that was dialled and the daemon that would have
    /// answered, and an empty host is spelled as the loopback default it means.
    #[test]
    fn the_unreachable_sentence_names_the_address_and_the_daemon() {
        let sentence = unreachable_message("100.107.14.250", 9000);
        assert!(
            sentence.starts_with("No video host answered at 100.107.14.250:9000."),
            "{sentence}"
        );
        assert!(sentence.contains("slopdesk-videohostd"));
        assert!(unreachable_message("", 9000).contains("127.0.0.1:9000"));
        assert!(!unreachable_message("", 0).is_empty());
    }
}
