//! The host-windows rail's fold, in C.
//!
//! The rules are `slopdesk_workspace::window_feed`; what is here is the marshalling.
//!
//! ## NO WINDOW CROSSES, ONLY POSITIONS
//!
//! A window is a `CGWindowID` and a bundle id, which is identity, and `docs/55` §4b keeps identity
//! on the near side. So [`slopdesk_ws_feed_structure_plan`] is handed two arrays of dense TOKENS —
//! one table minted across BOTH the structure the caller holds and the snapshot that arrived, the
//! same shape `slopdesk_ws_weight_change` uses for two flattenings of one tree — and answers
//! [`SlopDeskWsFeedFoldSlot`]s naming positions in those two arrays. The bundle id, the app name
//! and the title never travel at all: a survivor keeps the record the caller already has, and a
//! newcomer is built from the snapshot row the answer points at.
//!
//! The buffer the near side lends is the ARITHMETIC bound — the structure plus the snapshot, since
//! nothing can be kept and added at once — so §4's retry is there for correctness and is never
//! travelled.
//!
//! ## The frontmost is a `ptrdiff_t`, and the title can be empty
//!
//! [`slopdesk_ws_feed_frontmost`] answers `-1` for "nobody is focused", which is outside a
//! position's range by construction — the `slopdesk_ws_most_recent_survivor` precedent — so `0`,
//! the commonest landing there is, stays a real answer.
//!
//! [`slopdesk_ws_feed_display_title`] is the one door here whose EMPTY answer is real: a window
//! with no title belonging to an app with no name has nothing to be called. Its caller maps §4's
//! `0` to `""` rather than to "no answer", and says so where it does.

use core::ffi::c_uchar;

use slopdesk_workspace::window_feed::{self, FoldSlot};

use crate::{borrow, deliver, truncating_u32};

/// Where one entry of the folded structure comes from.
///
/// `index` is a position into the caller's EXISTING structure when `is_new` is false, and into the
/// snapshot that just arrived when it is true. Two arrays, one flag, no identity.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SlopDeskWsFeedFoldSlot {
    /// The position, in whichever of the two arrays `is_new` names.
    pub index: u32,
    /// False => `index` is into the existing structure; true => into the incoming snapshot.
    pub is_new: bool,
}

/// The rail's display title: the window's own, or the app's name when the window has none.
///
/// The EMPTY answer is REAL here — an untitled window belonging to an unnamed app — so a caller
/// reading §4's `0` must render `""` rather than treat it as a refusal.
///
/// # Safety
/// Both input pairs must be readable for the call, and `(out, cap)` writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and every pointer is the caller's"
)]
pub unsafe extern "C" fn slopdesk_ws_feed_display_title(
    title: *const c_uchar,
    title_len: usize,
    app_name: *const c_uchar,
    app_len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, restated above; both borrows die with this call.
    let lent_title = unsafe { borrow(title, title_len) };
    // SAFETY: the caller's obligation, restated above.
    let lent_app = unsafe { borrow(app_name, app_len) };
    let title_text = String::from_utf8_lossy(lent_title);
    let app_text = String::from_utf8_lossy(lent_app);
    // Copied before delivery rather than lent straight back: the winner is a slice of the CALLER's
    // input, and `deliver`'s non-overlap obligation is stated over buffers this call allocated. A
    // row title is a handful of bytes, and correctness here is not negotiable.
    let answer = window_feed::display_title(&title_text, &app_text)
        .as_bytes()
        .to_vec();
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe { deliver(&answer, out, cap) }
}

/// The structure after one snapshot: survivors in the order they already had, then the newcomers in
/// the order the host sent them.
///
/// Nothing is ever reordered — that is the whole feature, and the reason this is a plan rather than
/// a sort. Returns the count NEEDED; a short or null `out` is written nothing and told the length.
///
/// # Safety
/// Both token arrays must be readable for the call, and `out` writable for `capacity` slots.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and every pointer is the caller's"
)]
pub unsafe extern "C" fn slopdesk_ws_feed_structure_plan(
    structure: *const u32,
    structure_len: usize,
    snapshot: *const u32,
    snapshot_len: usize,
    out: *mut SlopDeskWsFeedFoldSlot,
    capacity: usize,
) -> usize {
    // SAFETY: the caller's obligation, restated above; both borrows die with this call.
    let held = unsafe { borrow(structure, structure_len) };
    // SAFETY: the caller's obligation, restated above.
    let arrived = unsafe { borrow(snapshot, snapshot_len) };
    let slots: Vec<SlopDeskWsFeedFoldSlot> = window_feed::structure_plan(held, arrived)
        .into_iter()
        .map(|slot| {
            match slot {
                FoldSlot::Kept(position) => {
                    SlopDeskWsFeedFoldSlot {
                        index: truncating_u32(position),
                        is_new: false,
                    }
                },
                FoldSlot::Added(position) => {
                    SlopDeskWsFeedFoldSlot {
                        index: truncating_u32(position),
                        is_new: true,
                    }
                },
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

/// The POSITION of the host's focused window in the snapshot, or `-1` when none is focused.
///
/// At most one window per snapshot carries the flag, so the FIRST is the answer. `-1` is outside a
/// position's range by construction, which keeps `0` — the frontmost window is often first in
/// z-order — a real answer.
///
/// # Safety
/// `(focused, len)` must be readable for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and the pointer is the caller's"
)]
pub unsafe extern "C" fn slopdesk_ws_feed_frontmost(focused: *const bool, len: usize) -> isize {
    // SAFETY: the caller's obligation, restated above; the borrow dies with this call.
    let lent = unsafe { borrow(focused, len) };
    window_feed::frontmost(lent).map_or(-1, |position| isize::try_from(position).unwrap_or(-1))
}

/// Whether a "you are current" ack may mark the feed LIVE — only when it names the generation this
/// client actually holds.
///
/// A stale or duplicated datagram acking an older generation is not confirmation of what we have,
/// and UDP delivers both.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_ws_feed_ack_marks_live(is_live: bool, acked: u32, known: u32) -> bool {
    window_feed::ack_marks_live(is_live, acked, known)
}

/// Whether the renewal interval that just elapsed makes the feed stale — no answer for two full
/// renewal gaps plus the first-answer gap.
///
/// `has_elapsed` false means no answer has ever landed, which is not staleness: it is the state
/// before any interval has been timed. Durations are NANOSECONDS and the grace saturates, because a
/// panic crossing this boundary aborts the process.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_ws_feed_goes_stale(
    is_live: bool,
    answered_since_open: bool,
    has_elapsed: bool,
    elapsed_ns: i64,
    renewal_ns: i64,
    first_answer_ns: i64,
) -> bool {
    let elapsed = if has_elapsed { Some(elapsed_ns) } else { None };
    window_feed::goes_stale(is_live, answered_since_open, elapsed, renewal_ns, first_answer_ns)
}

/// How long to wait before the next renewal, in NANOSECONDS: the fast retransmit gap until the
/// FIRST answer lands on a freshly opened lane, the ordinary gap after that.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_ws_feed_renewal_wait_ns(
    answered_since_open: bool,
    renewal_ns: i64,
    first_answer_ns: i64,
) -> i64 {
    window_feed::renewal_wait_ns(answered_since_open, renewal_ns, first_answer_ns)
}

#[cfg(test)]
mod tests {
    #![expect(unsafe_code, reason = "calling the door is the only way to test the door")]

    use slopdesk_workspace::window_feed::{self, FoldSlot};

    use super::{
        SlopDeskWsFeedFoldSlot, slopdesk_ws_feed_ack_marks_live, slopdesk_ws_feed_display_title,
        slopdesk_ws_feed_frontmost, slopdesk_ws_feed_goes_stale, slopdesk_ws_feed_renewal_wait_ns,
        slopdesk_ws_feed_structure_plan,
    };
    use crate::testing::delivered;

    /// Runs the plan door the way the near side does — lending the arithmetic bound, so the retry
    /// is never travelled.
    fn plan(structure: &[u32], snapshot: &[u32]) -> Vec<SlopDeskWsFeedFoldSlot> {
        let bound = structure.len() + snapshot.len();
        let mut slots = vec![SlopDeskWsFeedFoldSlot::default(); bound];
        // SAFETY: all three are live slices for the call.
        let count = unsafe {
            slopdesk_ws_feed_structure_plan(
                structure.as_ptr(),
                structure.len(),
                snapshot.as_ptr(),
                snapshot.len(),
                slots.as_mut_ptr(),
                slots.len(),
            )
        };
        assert!(count <= bound, "the arithmetic bound must hold");
        slots.truncate(count);
        slots
    }

    /// The plan crosses slot for slot with the rule, over the whole cross-product of small
    /// structures and snapshots — the differential the boundary exists to keep true.
    #[test]
    fn the_plan_crosses_slot_for_slot() {
        for held in 0_u32..5 {
            for arrived in 0_u32..5 {
                for offset in 0_u32..4 {
                    let structure: Vec<u32> = (0..held).collect();
                    let snapshot: Vec<u32> = (0..arrived).map(|index| index.saturating_add(offset)).collect();
                    let native = window_feed::structure_plan(&structure, &snapshot);
                    let crossed = plan(&structure, &snapshot);
                    assert_eq!(crossed.len(), native.len(), "{structure:?} then {snapshot:?}");
                    for (slot, expected) in crossed.iter().zip(native.iter()) {
                        let (position, is_new) = match *expected {
                            FoldSlot::Kept(position) => (position, false),
                            FoldSlot::Added(position) => (position, true),
                        };
                        assert_eq!(usize::try_from(slot.index), Ok(position));
                        assert_eq!(slot.is_new, is_new);
                    }
                }
            }
        }
    }

    /// A reordered snapshot moves nothing across the boundary either — the one behaviour the rail
    /// exists for, asserted where it is actually called.
    #[test]
    fn a_reordered_snapshot_crosses_as_three_keeps() {
        assert_eq!(plan(&[7, 3, 9], &[9, 7, 3]), vec![
            SlopDeskWsFeedFoldSlot {
                index: 0,
                is_new: false
            },
            SlopDeskWsFeedFoldSlot {
                index: 1,
                is_new: false
            },
            SlopDeskWsFeedFoldSlot {
                index: 2,
                is_new: false
            },
        ]);
    }

    /// An empty fold is `0` slots, and a null `out` with a real answer is told the count.
    #[test]
    fn an_empty_fold_and_a_sizing_call() {
        assert_eq!(plan(&[], &[]), Vec::new());
        assert_eq!(plan(&[7], &[]), Vec::new());
        let snapshot = [7_u32, 3];
        // SAFETY: a null structure with a zero length is the empty lend; `out` is null on purpose.
        let count = unsafe {
            slopdesk_ws_feed_structure_plan(
                core::ptr::null(),
                0,
                snapshot.as_ptr(),
                snapshot.len(),
                core::ptr::null_mut(),
                0,
            )
        };
        assert_eq!(count, 2, "sizing reports what it would have written");
    }

    /// A short buffer is written nothing and told the count, which is §4's retry contract for a
    /// counted-RECORD door.
    #[test]
    fn a_short_buffer_is_told_the_count_and_left_untouched() {
        let snapshot = [7_u32, 3, 9];
        let mut slots = [SlopDeskWsFeedFoldSlot {
            index: 42,
            is_new: true,
        }; 2];
        // SAFETY: both arrays are live locals for the call.
        let count = unsafe {
            slopdesk_ws_feed_structure_plan(
                core::ptr::null(),
                0,
                snapshot.as_ptr(),
                snapshot.len(),
                slots.as_mut_ptr(),
                slots.len(),
            )
        };
        assert_eq!(count, 3);
        assert_eq!(
            slots,
            [SlopDeskWsFeedFoldSlot {
                index: 42,
                is_new: true
            }; 2],
            "nothing written"
        );
    }

    /// The title crosses verbatim in both arms, and its empty answer is REAL rather than a refusal.
    #[test]
    fn the_title_crosses_and_its_empty_answer_is_real() {
        let ask = |title: &str, app: &str| {
            let title_bytes = title.as_bytes();
            let app_bytes = app.as_bytes();
            let blob = delivered(|out, cap| {
                // SAFETY: every pointer is a live local for the call.
                unsafe {
                    slopdesk_ws_feed_display_title(
                        title_bytes.as_ptr(),
                        title_bytes.len(),
                        app_bytes.as_ptr(),
                        app_bytes.len(),
                        out,
                        cap,
                    )
                }
            });
            String::from_utf8_lossy(&blob).into_owned()
        };
        assert_eq!(ask("", "Xcode"), "Xcode");
        assert_eq!(ask("Untitled 2", "Xcode"), "Untitled 2");
        assert_eq!(ask("", ""), "", "nothing to be called is a real answer");
        assert_eq!(ask(" ", "Xcode"), " ", "a blank is not empty");
    }

    /// The frontmost crosses as a position, and its refusal is the one number a position cannot be.
    #[test]
    fn the_frontmost_crosses_as_a_position() {
        let ask = |flags: &[bool]| {
            // SAFETY: `flags` is a live slice for the call.
            unsafe { slopdesk_ws_feed_frontmost(flags.as_ptr(), flags.len()) }
        };
        assert_eq!(ask(&[false, true, false]), 1);
        assert_eq!(ask(&[true, false]), 0);
        assert_eq!(ask(&[false, false]), -1);
        assert_eq!(ask(&[]), -1);
        // SAFETY: a null pair with a zero length is the documented empty lend.
        let empty = unsafe { slopdesk_ws_feed_frontmost(core::ptr::null(), 0) };
        assert_eq!(empty, -1);
    }

    /// The ack rule crosses over its whole domain.
    #[test]
    fn the_ack_rule_crosses() {
        for is_live in [false, true] {
            for acked in 0_u32..4 {
                for known in 0_u32..4 {
                    assert_eq!(
                        slopdesk_ws_feed_ack_marks_live(is_live, acked, known),
                        window_feed::ack_marks_live(is_live, acked, known)
                    );
                }
            }
        }
    }

    /// The staleness verdict crosses with both gates and the strict boundary intact.
    #[test]
    fn the_staleness_verdict_crosses() {
        let renewal = 2_000_000_000_i64;
        let first = 500_000_000_i64;
        let grace = 4_500_000_000_i64;
        assert!(!slopdesk_ws_feed_goes_stale(
            true,
            true,
            false,
            grace + 1,
            renewal,
            first
        ));
        assert!(!slopdesk_ws_feed_goes_stale(
            false,
            true,
            true,
            grace + 1,
            renewal,
            first
        ));
        assert!(!slopdesk_ws_feed_goes_stale(
            true,
            false,
            true,
            grace + 1,
            renewal,
            first
        ));
        assert!(!slopdesk_ws_feed_goes_stale(
            true, true, true, grace, renewal, first
        ));
        assert!(slopdesk_ws_feed_goes_stale(
            true,
            true,
            true,
            grace + 1,
            renewal,
            first
        ));
    }

    /// The cadence choice crosses on both sides of the first answer.
    #[test]
    fn the_cadence_choice_crosses() {
        assert_eq!(
            slopdesk_ws_feed_renewal_wait_ns(false, 2_000_000_000, 500_000_000),
            500_000_000
        );
        assert_eq!(
            slopdesk_ws_feed_renewal_wait_ns(true, 2_000_000_000, 500_000_000),
            2_000_000_000
        );
    }
}
