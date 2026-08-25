//! The focused-finish watch and its two neighbours, in C.
//!
//! The rules are `slopdesk_workspace::attention_fold`; what is here is the marshalling.
//!
//! ## Why the fold crosses as one array
//!
//! The near side holds a map of running clocks and a list of candidates, and the old spelling
//! looped over each separately — which is how a pane fell out of one and stayed in the other. The
//! door takes the UNION as rows and answers one verdict byte per row, so the two loops are one and
//! the caller cannot iterate them in the wrong order.
//!
//! ## No pane identity crosses
//!
//! Not one of these doors learns which pane it is talking about. The fold answers
//! positions-in-order into the rows the caller built, and the three scalar doors take booleans. A
//! `PaneID` is a `UUID` the near side owns.

use core::ffi::c_uchar;

use slopdesk_workspace::attention_fold::{self, Watch};

use crate::agent::status_from;
use crate::{borrow, deliver};

/// One pane's standing in the focused-finish watch.
///
/// `watched` is meaningless when `watching` is `false` and is never read there, so a caller with no
/// clock to report leaves it zero rather than inventing an instant.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct SlopDeskWsSettleWatch {
    /// Whether a dwell clock is already running on this pane.
    pub watching: bool,
    /// Whether the pane is one a watch may run on right now.
    pub candidate: bool,
    /// How long the clock has run, in the caller's own timebase.
    pub watched: f64,
}

/// The focused-finish fold: one verdict byte per row, in the caller's order.
///
/// `0` hold · `1` start a clock · `2` drop one · `3` the window elapsed, acknowledge the pane.
///
/// `arms` is written whether or not the buffer fits — it is the fold's second conclusion (did ANY
/// row start a clock, so must the one-shot be armed) and a caller that had to re-derive it by
/// scanning the bytes would be the third place the rule lived.
///
/// Returns the count NEEDED. A short or null `out` is written nothing and told the length.
///
/// # Safety
/// `(rows, len)` must be readable for the call, `out` writable for `capacity` bytes, and `arms`
/// either null or writable.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and every pointer is the caller's"
)]
pub unsafe extern "C" fn slopdesk_ws_settle_step(
    rows: *const SlopDeskWsSettleWatch,
    len: usize,
    window: f64,
    out: *mut c_uchar,
    capacity: usize,
    arms: *mut bool,
) -> usize {
    // SAFETY: the caller's obligation, restated above; the borrow dies with this call.
    let lent = unsafe { borrow(rows, len) };
    let watches: Vec<Watch> = lent
        .iter()
        .map(|row| {
            Watch {
                watching: row.watching,
                watched: row.watched,
                candidate: row.candidate,
            }
        })
        .collect();
    let verdicts = attention_fold::settle_step(&watches, window);
    if !arms.is_null() {
        // SAFETY: non-null and writable for one `bool` by the caller's obligation above.
        unsafe {
            arms.write(attention_fold::arms_scheduler(&verdicts));
        }
    }
    let bytes: Vec<c_uchar> = verdicts.iter().map(|verdict| verdict.code()).collect();
    // SAFETY: `out` is null or writable for `capacity` bytes by the caller's obligation.
    unsafe { deliver(&bytes, out, capacity) }
}

/// Whether a watch may run on a pane at all: focused in an ACTIVE app, and carrying a finished-turn
/// marker — either a live done status or the unread latch.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_ws_settle_candidate(
    app_active: bool,
    focused: bool,
    finished: bool,
    unseen_finish: bool,
) -> bool {
    attention_fold::settle_candidate(app_active, focused, finished, unseen_finish)
}

/// Whether a walk in progress has been interrupted by a focus change it did not make itself.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_ws_walk_interrupted(walking: bool, focus_held: bool) -> bool {
    attention_fold::walk_interrupted(walking, focus_held)
}

/// Whether an explicit acknowledge may settle this status to idle. Only a finished turn — a live
/// state, and above all an approval gate, is left alone.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_ws_badge_clear_settles(status: c_uchar) -> bool {
    attention_fold::badge_clear_settles(status_from(status))
}

/// Text with nothing in it, as the ABSENCE of a value: the trimmed bytes, or `0` when what is left
/// is empty.
///
/// Zero is the whole point rather than a degenerate case — it is what the caller REMOVES its key
/// on, so the row falls back down its own chain instead of titling itself with a blank. The answer
/// is never longer than the input, so one buffer the size of the input is the arithmetic bound and
/// the retry path is never travelled.
///
/// # Safety
/// `(text, len)` must be readable for the call and `out` writable for `capacity` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and both pointers are the caller's"
)]
pub unsafe extern "C" fn slopdesk_ws_normalized_text(
    text: *const c_uchar,
    len: usize,
    out: *mut c_uchar,
    capacity: usize,
) -> usize {
    // SAFETY: the caller's obligation, restated above; the borrow dies with this call.
    let lent = unsafe { borrow(text, len) };
    let held = String::from_utf8_lossy(lent);
    let answer = attention_fold::normalized_text(&held).unwrap_or_default();
    // SAFETY: `out` is null or writable for `capacity` bytes by the caller's obligation.
    unsafe { deliver(answer.as_bytes(), out, capacity) }
}

#[cfg(test)]
mod tests {
    #![expect(unsafe_code, reason = "calling the door is the only way to test the door")]

    use slopdesk_agent::status::ClaudeStatus;
    use slopdesk_workspace::attention_fold::{self, Watch};

    use super::{
        SlopDeskWsSettleWatch, slopdesk_ws_badge_clear_settles, slopdesk_ws_normalized_text,
        slopdesk_ws_settle_candidate, slopdesk_ws_settle_step, slopdesk_ws_walk_interrupted,
    };

    /// The byte a status crosses as — `ClaudeStatus::ALL`'s own order, which is the Swift enum's.
    fn byte(status: ClaudeStatus) -> u8 {
        u8::try_from(
            ClaudeStatus::ALL
                .into_iter()
                .position(|candidate| candidate == status)
                .unwrap_or(0),
        )
        .unwrap_or(0)
    }

    /// Every row shape crosses to the verdict the rule gives directly, and the arming flag agrees.
    #[test]
    fn every_row_crosses_verbatim() {
        for watching in [false, true] {
            for candidate in [false, true] {
                for watched in [0.0_f64, 29.9, 30.0, 100.0] {
                    let row = SlopDeskWsSettleWatch {
                        watching,
                        candidate,
                        watched,
                    };
                    let mut verdicts = [0_u8; 1];
                    let mut arms = false;
                    // SAFETY: every pointer is a live local for the call.
                    let count = unsafe {
                        slopdesk_ws_settle_step(
                            &raw const row,
                            1,
                            30.0,
                            verdicts.as_mut_ptr(),
                            1,
                            &raw mut arms,
                        )
                    };
                    let native = attention_fold::settle_step(
                        &[Watch {
                            watching,
                            watched,
                            candidate,
                        }],
                        30.0,
                    );
                    assert_eq!(count, 1);
                    assert_eq!(
                        verdicts.first().copied().unwrap_or(255),
                        native.first().map_or(255, |verdict| verdict.code()),
                        "({watching}, {candidate}, {watched})"
                    );
                    assert_eq!(arms, attention_fold::arms_scheduler(&native));
                }
            }
        }
    }

    /// A short buffer is told the length and written nothing — and still learns whether to arm.
    #[test]
    fn a_short_buffer_is_told_the_length_and_still_arms() {
        let rows = [
            SlopDeskWsSettleWatch {
                watching: false,
                candidate: true,
                watched: 0.0,
            },
            SlopDeskWsSettleWatch {
                watching: true,
                candidate: false,
                watched: 0.0,
            },
        ];
        let mut short = [9_u8; 1];
        let mut arms = false;
        // SAFETY: every pointer is a live local for the call.
        let needed = unsafe {
            slopdesk_ws_settle_step(
                rows.as_ptr(),
                rows.len(),
                30.0,
                short.as_mut_ptr(),
                1,
                &raw mut arms,
            )
        };
        assert_eq!(needed, 2);
        assert_eq!(short, [9], "and written nothing");
        assert!(arms, "the arming flag is written whatever the buffer does");
    }

    /// An empty fold is zero, and a null `out` and a null `arms` are both answered rather than
    /// dereferenced.
    #[test]
    fn an_empty_fold_and_null_buffers_are_inert() {
        // SAFETY: a zero-length read of a dangling-but-aligned pointer; neither out param is touched.
        let empty = unsafe {
            slopdesk_ws_settle_step(
                core::ptr::NonNull::dangling().as_ptr(),
                0,
                30.0,
                core::ptr::null_mut(),
                0,
                core::ptr::null_mut(),
            )
        };
        assert_eq!(empty, 0);
    }

    /// The three scalar doors answer their rules verbatim over their whole domains.
    #[test]
    fn the_scalar_doors_cross_verbatim() {
        for app_active in [false, true] {
            for focused in [false, true] {
                for finished in [false, true] {
                    for unseen in [false, true] {
                        assert_eq!(
                            slopdesk_ws_settle_candidate(app_active, focused, finished, unseen),
                            attention_fold::settle_candidate(app_active, focused, finished, unseen),
                        );
                    }
                }
            }
        }
        for walking in [false, true] {
            for held in [false, true] {
                assert_eq!(
                    slopdesk_ws_walk_interrupted(walking, held),
                    attention_fold::walk_interrupted(walking, held),
                );
            }
        }
        for status in ClaudeStatus::ALL {
            assert_eq!(
                slopdesk_ws_badge_clear_settles(byte(status)),
                attention_fold::badge_clear_settles(status),
            );
        }
    }

    /// An unnamed status byte reads as no agent, which never settles anything.
    #[test]
    fn an_unnamed_status_byte_settles_nothing() {
        assert!(!slopdesk_ws_badge_clear_settles(200));
    }

    /// Blank text answers zero — the caller's signal to remove the key — and real text crosses
    /// trimmed.
    #[test]
    fn blank_text_crosses_as_zero() {
        let blank = b"  \n ";
        // SAFETY: both buffers are live locals for the call.
        let needed =
            unsafe { slopdesk_ws_normalized_text(blank.as_ptr(), blank.len(), core::ptr::null_mut(), 0) };
        assert_eq!(needed, 0);

        let raw = b"  cargo build  ";
        let mut out = [0_u8; 32];
        // SAFETY: both buffers are live locals for the call.
        let count = unsafe { slopdesk_ws_normalized_text(raw.as_ptr(), raw.len(), out.as_mut_ptr(), 32) };
        assert_eq!(count, 11);
        assert_eq!(out.get(..count), Some(b"cargo build".as_slice()));
    }

    /// A buffer the size of the input always fits, which is why the near side never retries.
    #[test]
    fn the_input_length_is_always_enough() {
        for raw in [
            "",
            " ",
            "x",
            "  é  ",
            "a very long running command --with --flags",
        ] {
            let bytes = raw.as_bytes();
            let mut out = vec![0_u8; bytes.len()];
            // SAFETY: both buffers are live locals for the call.
            let count = unsafe {
                slopdesk_ws_normalized_text(bytes.as_ptr(), bytes.len(), out.as_mut_ptr(), out.len())
            };
            assert!(count <= bytes.len(), "{raw:?}");
            assert_eq!(
                out.get(..count)
                    .map(|written| String::from_utf8_lossy(written).into_owned()),
                Some(
                    attention_fold::normalized_text(raw)
                        .unwrap_or_default()
                        .to_owned()
                ),
            );
        }
    }
}
