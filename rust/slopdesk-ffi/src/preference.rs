//! What the preference surface decides, in C.
//!
//! The rules are `slopdesk_workspace::preference`; what is here is the marshalling. Three
//! decisions cross, and none of them is a SETTING — the settings are a file, resolved one crate
//! further down, and nothing in this module knows a path, a default or a token.
//!
//! ## Two of the three answer BY VALUE, and the third is counted
//!
//! The suite verdict is one byte and the zoom answer is a flag beside a double, so neither needs
//! §4's `(out, cap) -> needed` protocol. The zoom carries its `moved` flag rather than a sentinel
//! delta for §4b's reason: every `double` is a legal delta — `0.0` most of all, since that is
//! exactly what ⌘0 lands on — so no value could have meant "the press moved nothing".
//!
//! The hint zip is counted, because how many patterns survive is what the call decides.
//!
//! ## No string crosses any of them
//!
//! A suite name is the caller's (one is built from its own pid, the other read out of its own
//! environment) and a hint regex is the user's own text. The rules read one bit of each, so what
//! travels is that bit and what comes back names POSITIONS the caller reads its own arrays at —
//! `store_rollup`'s convention, at two more call sites.
//!
//! The one exception is the suite door's environment value, which crosses as `(ptr, len)` so the
//! emptiness rule stays on the far side. A NULL pointer and a zero length answer the same thing
//! there, and deliberately: an absent variable and one set to the empty string are the same
//! decision, so §4b's presence flag would name a distinction nothing downstream can act on.

use core::ffi::c_uchar;

use slopdesk_workspace::preference::{self, HintSlot, SuiteSource, Zoom};

use crate::borrow;

/// The answer one press of a zoom chord gives: a new runtime delta, or nothing.
///
/// `moved` is a flag beside the value rather than a sentinel inside it. A `delta` of `0.0` is what
/// ⌘0 lands on, so it is the single most common REAL answer this door gives — encoding "no move" as
/// that number would make a reset indistinguishable from a refusal.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct SlopDeskWsFontZoom {
    /// The new runtime delta, in points from the size the config file states. Read it only when
    /// `moved` is true.
    pub delta: f64,
    /// Whether the press moved anything at all.
    pub moved: bool,
}

/// One surviving Hint Mode pattern, as a position in the caller's own list.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SlopDeskWsHintSlot {
    /// Which entry of the pattern list this slot's regex is — an index into the array the caller
    /// still holds, never the position in this answer.
    pub pattern: u32,
    /// Whether the action list carries a template at that same index.
    pub has_action: bool,
}

/// `0` ⌘+ · `1` ⌘- · `2` ⌘0. Anything this build cannot name is a RESET, which is the only reading
/// that cannot leave the terminal at a size nobody asked for.
const fn zoom_of(raw: c_uchar) -> Zoom {
    match raw {
        0 => Zoom::In,
        1 => Zoom::Out,
        _ => Zoom::Reset,
    }
}

/// Which `UserDefaults` suite this process binds its per-session STATE to: `0` the standard domain,
/// `1` a per-process throwaway suite, `2` the one the environment names.
///
/// The `XCTest` suite wins outright — a stray automation variable in a developer's shell must not
/// put parallel test workers back onto one shared domain. An EMPTY environment value is no value,
/// which is why the emptiness test lives on this side rather than at the call site.
///
/// `(named, named_len)` is the environment value, not the variable's name. A NULL pointer and a
/// zero length are the same answer here on purpose: an unset variable and one set to the empty
/// string are the same decision.
///
/// # Safety
/// `(named, named_len)` must be readable for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and the pointer is the caller's"
)]
pub unsafe extern "C" fn slopdesk_ws_state_suite_source(
    under_test: bool,
    named: *const c_uchar,
    named_len: usize,
) -> c_uchar {
    // SAFETY: the caller's obligation, restated above; the borrow dies with this call.
    let lent = unsafe { borrow(named, named_len) };
    // Invalid UTF-8 cannot be a suite name anybody meant to bind, so it reads as no override —
    // never as a name with the bad bytes replaced, which would bind a DIFFERENT domain silently.
    // An empty borrow needs no case of its own: it decodes to `Some("")`, and the rule already
    // answers the standard domain for that.
    let value = core::str::from_utf8(lent).ok();
    match preference::state_suite_source(under_test, value) {
        SuiteSource::Standard => 0,
        SuiteSource::TestProcess => 1,
        SuiteSource::Environment => 2,
    }
}

/// The size the terminal draws at: the file's answer plus the runtime delta, held inside the zoom
/// band NaN-faithfully.
///
/// No pointer and no buffer — every argument is a scalar and the answer is one, which is §4's
/// "entry that takes no memory at all".
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_ws_font_size_effective(configured: f64, delta: f64) -> f64 {
    preference::effective_font_size(configured, delta)
}

/// The new runtime delta one press of ⌘+ / ⌘- / ⌘0 lands on, and whether it moved anything.
///
/// `press` is `0` in, `1` out, `2` reset; anything else is read as a reset. A press against either
/// edge of the band answers `moved: false`, and so does ⌘0 at a delta of zero — the refusal is what
/// stops a held key re-publishing an identical terminal configuration through a generation counter
/// that bumps unconditionally.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_ws_font_zoom(configured: f64, delta: f64, press: c_uchar) -> SlopDeskWsFontZoom {
    preference::zoom(configured, delta, zoom_of(press)).map_or_else(SlopDeskWsFontZoom::default, |moved| {
        SlopDeskWsFontZoom {
            delta: moved,
            moved: true,
        }
    })
}

/// The zip of the two parallel Hint Mode lists, as slots into the pattern list.
///
/// Both inputs carry one EMPTINESS flag per entry, in the file's own order — no regex and no action
/// template crosses, because the rule reads exactly one bit of each. An empty PATTERN is dropped (an
/// empty regex matches everything); an action that is absent, empty, or past the end of its list is
/// no action.
///
/// Returns the count NEEDED. A short or null `out` is written nothing and told the length.
///
/// # Safety
/// `(patterns_empty, patterns_len)` and `(actions_empty, actions_len)` must be readable for the
/// call, and `out` writable for `capacity` slots.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and all three pointers are the caller's"
)]
pub unsafe extern "C" fn slopdesk_ws_hint_patterns(
    patterns_empty: *const bool,
    patterns_len: usize,
    actions_empty: *const bool,
    actions_len: usize,
    out: *mut SlopDeskWsHintSlot,
    capacity: usize,
) -> usize {
    // SAFETY: the caller's obligation, restated above; both borrows die with this call.
    let patterns = unsafe { borrow(patterns_empty, patterns_len) };
    // SAFETY: the caller's obligation, restated above; both borrows die with this call.
    let actions = unsafe { borrow(actions_empty, actions_len) };
    let slots: Vec<SlopDeskWsHintSlot> = preference::hint_patterns(patterns, actions)
        .into_iter()
        .map(|slot: HintSlot| {
            SlopDeskWsHintSlot {
                pattern: u32::try_from(slot.pattern).unwrap_or(u32::MAX),
                has_action: slot.has_action,
            }
        })
        .collect();
    let count = slots.len();
    if count == 0 || count > capacity || out.is_null() {
        return count;
    }
    // SAFETY: `count <= capacity` was just checked, `out` is non-null and writable for `capacity`
    // slots by the caller's obligation, and `slots` was allocated inside this call, so the two
    // cannot overlap.
    unsafe { core::ptr::copy_nonoverlapping(slots.as_ptr(), out, count) };
    count
}

#[cfg(test)]
mod tests {
    #![expect(unsafe_code, reason = "calling the door is the only way to test the door")]

    use slopdesk_workspace::preference::{FONT_SIZE_MAX, FONT_SIZE_MIN};

    use super::{
        SlopDeskWsFontZoom, SlopDeskWsHintSlot, slopdesk_ws_font_size_effective, slopdesk_ws_font_zoom,
        slopdesk_ws_hint_patterns, slopdesk_ws_state_suite_source,
    };

    /// Reads the suite door with a value the caller lends as bytes.
    fn suite(under_test: bool, named: Option<&str>) -> u8 {
        match named {
            // SAFETY: `bytes` is the caller's live slice for the duration of the call.
            Some(value) => {
                let bytes = value.as_bytes();
                unsafe { slopdesk_ws_state_suite_source(under_test, bytes.as_ptr(), bytes.len()) }
            },
            // SAFETY: a null pointer with a zero length is the documented absent case.
            None => unsafe { slopdesk_ws_state_suite_source(under_test, core::ptr::null(), 0) },
        }
    }

    /// The whole precedence, crossed: the test suite first, then a named environment value, then
    /// the standard domain — and an empty value is not a name.
    #[test]
    fn the_suite_precedence_crosses_as_three_bytes() {
        assert_eq!(suite(true, Some("run.42")), 1);
        assert_eq!(suite(true, None), 1);
        assert_eq!(suite(false, Some("run.42")), 2);
        assert_eq!(suite(false, Some("")), 0, "an empty value is no override");
        assert_eq!(suite(false, None), 0);
    }

    /// Bytes that are not UTF-8 read as NO override, rather than as a name with the bad bytes
    /// replaced — which would bind a different domain and say nothing.
    #[test]
    fn a_non_utf8_environment_value_is_no_override() {
        let bytes = [0xFF_u8, 0xFE];
        // SAFETY: `bytes` is a live local for the call.
        let crossed = unsafe { slopdesk_ws_state_suite_source(false, bytes.as_ptr(), bytes.len()) };
        assert_eq!(crossed, 0);
    }

    /// The scalar door answers the band, from both ends and from a `NaN`.
    #[test]
    fn the_effective_size_crosses_as_one_scalar() {
        assert_eq!(
            slopdesk_ws_font_size_effective(14.0, 3.0).to_bits(),
            17.0_f64.to_bits()
        );
        assert_eq!(
            slopdesk_ws_font_size_effective(14.0, 900.0).to_bits(),
            FONT_SIZE_MAX.to_bits()
        );
        assert_eq!(
            slopdesk_ws_font_size_effective(14.0, -900.0).to_bits(),
            FONT_SIZE_MIN.to_bits()
        );
        assert!(!slopdesk_ws_font_size_effective(f64::NAN, 0.0).is_nan());
    }

    /// A press that moves comes back with its flag up and its delta beside it; a press against the
    /// edge comes back with the flag down and the delta left at zero.
    #[test]
    fn a_zoom_carries_a_flag_beside_its_delta() {
        assert_eq!(slopdesk_ws_font_zoom(14.0, 0.0, 0), SlopDeskWsFontZoom {
            delta: 1.0,
            moved: true
        });
        assert_eq!(slopdesk_ws_font_zoom(14.0, 0.0, 1), SlopDeskWsFontZoom {
            delta: -1.0,
            moved: true
        });
        assert_eq!(
            slopdesk_ws_font_zoom(FONT_SIZE_MAX, 0.0, 0),
            SlopDeskWsFontZoom::default()
        );
        assert_eq!(
            slopdesk_ws_font_zoom(FONT_SIZE_MIN, 0.0, 1),
            SlopDeskWsFontZoom::default()
        );
    }

    /// ⌘0 lands on a delta of `0.0` WITH the flag up, which is exactly the pair a sentinel could
    /// not have told apart from a refusal.
    #[test]
    fn a_reset_and_a_refusal_are_told_apart_by_the_flag() {
        assert_eq!(slopdesk_ws_font_zoom(14.0, 4.0, 2), SlopDeskWsFontZoom {
            delta: 0.0,
            moved: true
        });
        assert_eq!(
            slopdesk_ws_font_zoom(14.0, 0.0, 2),
            SlopDeskWsFontZoom::default(),
            "nothing to reset — the same two fields, and only the flag separates them"
        );
    }

    /// A press byte this build cannot name is read as a RESET, the only reading that cannot leave
    /// the terminal at a size nobody asked for.
    #[test]
    fn an_unnamed_press_byte_resets() {
        assert_eq!(slopdesk_ws_font_zoom(14.0, 4.0, 200), SlopDeskWsFontZoom {
            delta: 0.0,
            moved: true
        });
    }

    /// Reads the zip door's answer out of a buffer sized to the count it asked for.
    fn zipped(patterns: &[bool], actions: &[bool]) -> Vec<SlopDeskWsHintSlot> {
        // SAFETY: both slices are live locals here, and `out` is null — the documented size call.
        let needed = unsafe {
            slopdesk_ws_hint_patterns(
                patterns.as_ptr(),
                patterns.len(),
                actions.as_ptr(),
                actions.len(),
                core::ptr::null_mut(),
                0,
            )
        };
        let mut out = vec![SlopDeskWsHintSlot::default(); needed];
        // SAFETY: all three buffers are live for the call, and `out` holds exactly `needed` slots.
        let count = unsafe {
            slopdesk_ws_hint_patterns(
                patterns.as_ptr(),
                patterns.len(),
                actions.as_ptr(),
                actions.len(),
                out.as_mut_ptr(),
                needed,
            )
        };
        assert_eq!(count, needed, "the size call and the read call must agree");
        out
    }

    /// The three cases the file's shape cannot express, crossed: a pair, a pattern past the end of
    /// the action list, and a pattern whose action is present but empty. The surviving slots name
    /// ORIGINAL indices, which is what keeps the pairing across the dropped entry.
    #[test]
    fn the_zip_crosses_as_original_positions() {
        // ["ERR-\d+", "", "TODO", "FIXME"] × ["open", "open", ""]
        assert_eq!(
            zipped(&[false, true, false, false], &[false, false, true]),
            vec![
                SlopDeskWsHintSlot {
                    pattern: 0,
                    has_action: true
                },
                SlopDeskWsHintSlot {
                    pattern: 2,
                    has_action: false
                },
                SlopDeskWsHintSlot {
                    pattern: 3,
                    has_action: false
                },
            ]
        );
    }

    /// No patterns at all — and a null pair — answer zero rather than being dereferenced.
    #[test]
    fn an_empty_pattern_list_answers_nothing() {
        // SAFETY: null pointers with zero lengths are the documented empty case.
        let needed = unsafe {
            slopdesk_ws_hint_patterns(
                core::ptr::null(),
                0,
                core::ptr::null(),
                0,
                core::ptr::null_mut(),
                0,
            )
        };
        assert_eq!(needed, 0);
        assert!(zipped(&[true, true], &[false]).is_empty());
    }

    /// A short buffer is told the length and written nothing — §4's retry, which the near side's
    /// arithmetic bound means it never has to travel.
    #[test]
    fn a_short_buffer_is_told_the_length_and_written_nothing() {
        let patterns = [false, false, false];
        let actions = [false];
        let mut short = [SlopDeskWsHintSlot::default(); 1];
        // SAFETY: all three arrays are live locals for the call.
        let needed = unsafe {
            slopdesk_ws_hint_patterns(
                patterns.as_ptr(),
                patterns.len(),
                actions.as_ptr(),
                actions.len(),
                short.as_mut_ptr(),
                1,
            )
        };
        assert_eq!(needed, 3);
        assert_eq!(short, [SlopDeskWsHintSlot::default()], "and untouched");
    }
}
