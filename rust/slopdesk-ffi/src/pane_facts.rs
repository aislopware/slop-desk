//! What one status landing on a pane moves, in C.
//!
//! The rules are `slopdesk_workspace::pane_facts`; what is here is the marshalling.
//!
//! ## Why the commit crosses as a struct rather than a bitmask
//!
//! Every field is applied unconditionally by the near side — it writes six lines and branches on
//! none of them — so the shape that reads best there is six named booleans, not a word the caller
//! has to mask. The ABI cost is the same: a six-byte aggregate is returned in registers.
//!
//! ## No pane identity crosses
//!
//! Not one of these doors learns which pane it is talking about. The commit takes three statuses,
//! the queue order takes badges and instants and answers POSITIONS in the list it was handed. A
//! `PaneID` is a `UUID` the near side owns, and carrying it across would buy nothing but a second
//! place for the identity to be wrong.

use core::ffi::c_uchar;

use slopdesk_agent::badge::TabBadge;
use slopdesk_workspace::pane_facts::{self, Unseen, Waiting};

use crate::agent::status_from;
use crate::borrow;

/// Which of a pane's facts one committed status change moves.
///
/// `changed` is the guard: every other field is meaningless when it is `false`, which is the
/// `Option` the rule answers, flattened for a caller that has no such type. A no-change verdict
/// leaves the rest zeroed rather than undefined, so a near side that forgets the guard degrades
/// into doing nothing instead of into doing something arbitrary.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SlopDeskPaneStatusCommit {
    /// Whether the status actually changed. `false` ⇒ ignore every field below.
    pub changed: bool,
    /// Latch the new status as the one last notified for, and park a notification for it.
    pub notify_edge: bool,
    /// Forget what was last notified — the pane left the attention bucket.
    pub rearm_notified: bool,
    /// Park a notification for a hook-less finish.
    pub schedule_completion: bool,
    /// Stamp the completion instant, arm the flash decay, bump this client's own counter.
    pub stamp_completed: bool,
    /// Mark the pane's current finish read — the agent moved on.
    pub mark_seen: bool,
    /// Anchor the turn clock. `false` ⇒ retire it.
    pub stamp_working: bool,
}

/// One pane in the unseen-attention queue.
///
/// `since` is a flag plus a value because the absent case is real — a manual badge override has no
/// age evidence — and a sentinel would sort by whatever the comparison did with it.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct SlopDeskWaitingPane {
    /// The pane's resolved, gated badge, as its `TabBadge::ALL` discriminant.
    pub badge: c_uchar,
    /// Whether `since` carries an instant.
    pub has_since: bool,
    /// When the pane entered attention, in the caller's own timebase.
    pub since: f64,
}

/// The ladder one per-pane status write runs.
///
/// `last_notified` is the coalescing memory, NOT the previous status: `done → working → done`
/// re-enters a state already announced and has to stay quiet, which only a memory can tell from a
/// first arrival. `quiet` is the host's bookkeeping qualification — it vetoes rings and nothing
/// else.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_ws_pane_status_commit(
    previous: c_uchar,
    last_notified: c_uchar,
    next: c_uchar,
    quiet: bool,
) -> SlopDeskPaneStatusCommit {
    pane_facts::commit(
        status_from(previous),
        status_from(last_notified),
        status_from(next),
        quiet,
    )
    .map_or_else(SlopDeskPaneStatusCommit::default, |commit| {
        SlopDeskPaneStatusCommit {
            changed: true,
            notify_edge: commit.notify_edge,
            rearm_notified: commit.rearm_notified,
            schedule_completion: commit.schedule_completion,
            stamp_completed: commit.stamp_completed,
            mark_seen: commit.mark_seen,
            stamp_working: commit.stamp_working,
        }
    })
}

/// What a pane's unread-finish marker should become: `0` clear, `1` clear AND record it seen,
/// `2` mark it unread.
///
/// `has_seen` distinguishes "this device has never recorded a value" from "it recorded zero", which
/// are different answers: the first can never match a live counter, and the second is the state
/// every pane is in before the document arrives.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_ws_pane_unseen_done(
    epoch: u32,
    has_seen: bool,
    seen: u32,
    is_visible: bool,
) -> c_uchar {
    match pane_facts::unseen_done(epoch, if has_seen { Some(seen) } else { None }, is_visible) {
        Unseen::Clear => 0,
        Unseen::SeenThenClear => 1,
        Unseen::Mark => 2,
    }
}

/// The order the unseen-attention queue is walked in, as POSITIONS into `entries`.
///
/// Returns the count NEEDED. A short or null `out` is written nothing and told the length, the same
/// contract every other counted door here keeps.
///
/// # Safety
/// `(entries, len)` must be readable for the call, and `out` writable for `capacity` `u32`s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and both pointers are the caller's"
)]
pub unsafe extern "C" fn slopdesk_ws_attention_order(
    entries: *const SlopDeskWaitingPane,
    len: usize,
    out: *mut u32,
    capacity: usize,
) -> usize {
    // SAFETY: the caller's obligation, restated above; the borrow dies with this call.
    let lent = unsafe { borrow(entries, len) };
    let waiting: Vec<Waiting> = lent
        .iter()
        .map(|entry| {
            Waiting {
                // An unnamed discriminant sorts as a non-attention badge, which ranks last. A badge
                // this build cannot name must never jump the queue.
                badge: TabBadge::ALL
                    .get(entry.badge as usize)
                    .copied()
                    .unwrap_or(TabBadge::Running),
                since: entry.has_since.then_some(entry.since),
            }
        })
        .collect();
    let order = pane_facts::attention_order(&waiting);
    let count = order.len();
    if count == 0 || count > capacity || out.is_null() {
        return count;
    }
    // SAFETY: `count <= capacity` was just checked, `out` is non-null and writable for `capacity`
    // elements by the caller's obligation, and `order` was allocated inside this call, so the two
    // cannot overlap.
    unsafe { core::ptr::copy_nonoverlapping(order.as_ptr(), out, count) };
    count
}

#[cfg(test)]
mod tests {
    #![expect(unsafe_code, reason = "calling the door is the only way to test the door")]

    use slopdesk_agent::badge::TabBadge;
    use slopdesk_agent::status::ClaudeStatus;
    use slopdesk_workspace::pane_facts;

    use super::{
        SlopDeskWaitingPane, slopdesk_ws_attention_order, slopdesk_ws_pane_status_commit,
        slopdesk_ws_pane_unseen_done,
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

    /// The discriminant a badge crosses as.
    fn badge_byte(badge: TabBadge) -> u8 {
        u8::try_from(
            TabBadge::ALL
                .into_iter()
                .position(|candidate| candidate == badge)
                .unwrap_or(0),
        )
        .unwrap_or(0)
    }

    /// Every `(previous, last_notified, next, quiet)` the rule can be asked about crosses to the
    /// same verdict the rule gives directly — the differential the boundary exists to keep true.
    #[test]
    fn every_commit_crosses_verbatim() {
        for previous in ClaudeStatus::ALL {
            for last_notified in ClaudeStatus::ALL {
                for next in ClaudeStatus::ALL {
                    for quiet in [false, true] {
                        let crossed = slopdesk_ws_pane_status_commit(
                            byte(previous),
                            byte(last_notified),
                            byte(next),
                            quiet,
                        );
                        let native = pane_facts::commit(previous, last_notified, next, quiet);
                        assert_eq!(crossed.changed, native.is_some());
                        let Some(native) = native else {
                            assert_eq!(
                                crossed,
                                super::SlopDeskPaneStatusCommit::default(),
                                "a no-change verdict is zeroed, not arbitrary"
                            );
                            continue;
                        };
                        assert_eq!(crossed.notify_edge, native.notify_edge);
                        assert_eq!(crossed.rearm_notified, native.rearm_notified);
                        assert_eq!(crossed.schedule_completion, native.schedule_completion);
                        assert_eq!(crossed.stamp_completed, native.stamp_completed);
                        assert_eq!(crossed.mark_seen, native.mark_seen);
                        assert_eq!(crossed.stamp_working, native.stamp_working);
                    }
                }
            }
        }
    }

    /// An unnamed status byte degrades to `None`, the conservative case, rather than aborting.
    #[test]
    fn an_unnamed_status_byte_reads_as_absence() {
        let crossed = slopdesk_ws_pane_status_commit(200, 201, byte(ClaudeStatus::Done), false);
        assert!(crossed.changed && crossed.stamp_completed);
    }

    #[test]
    fn the_unread_verdicts_cross_as_their_three_codes() {
        assert_eq!(slopdesk_ws_pane_unseen_done(0, false, 0, false), 0);
        assert_eq!(slopdesk_ws_pane_unseen_done(3, true, 3, false), 0);
        assert_eq!(slopdesk_ws_pane_unseen_done(3, false, 0, true), 1);
        assert_eq!(slopdesk_ws_pane_unseen_done(3, false, 0, false), 2);
        assert_eq!(slopdesk_ws_pane_unseen_done(3, true, 2, false), 2);
    }

    /// Never recorded is not the same as recorded zero, and the flag is what says which.
    #[test]
    fn an_absent_record_marks_where_a_matching_one_clears() {
        assert_eq!(slopdesk_ws_pane_unseen_done(7, false, 7, false), 2);
        assert_eq!(slopdesk_ws_pane_unseen_done(7, true, 7, false), 0);
    }

    /// The queue order crosses as positions, and a short buffer is told the length.
    #[test]
    fn the_queue_order_crosses_as_positions() {
        let entries = [
            SlopDeskWaitingPane {
                badge: badge_byte(TabBadge::Finished),
                has_since: true,
                since: 1.0,
            },
            SlopDeskWaitingPane {
                badge: badge_byte(TabBadge::AwaitingInput),
                has_since: true,
                since: 9.0,
            },
            SlopDeskWaitingPane {
                badge: badge_byte(TabBadge::Error),
                has_since: false,
                since: 0.0,
            },
        ];
        let mut order = [0_u32; 3];
        // SAFETY: both arrays are live locals for the call.
        let count =
            unsafe { slopdesk_ws_attention_order(entries.as_ptr(), entries.len(), order.as_mut_ptr(), 3) };
        assert_eq!(count, 3);
        assert_eq!(order, [1, 2, 0]);

        let mut short = [0_u32; 1];
        // SAFETY: both arrays are live locals for the call.
        let needed =
            unsafe { slopdesk_ws_attention_order(entries.as_ptr(), entries.len(), short.as_mut_ptr(), 1) };
        assert_eq!(needed, 3, "a short buffer is told the length");
        assert_eq!(short, [0], "and written nothing");
    }

    /// An unnamed badge ranks behind every waiting one rather than jumping the queue.
    #[test]
    fn an_unnamed_badge_sorts_last() {
        let entries = [
            SlopDeskWaitingPane {
                badge: 250,
                has_since: true,
                since: 0.0,
            },
            SlopDeskWaitingPane {
                badge: badge_byte(TabBadge::Finished),
                has_since: true,
                since: 100.0,
            },
        ];
        let mut order = [0_u32; 2];
        // SAFETY: both arrays are live locals for the call.
        let count =
            unsafe { slopdesk_ws_attention_order(entries.as_ptr(), entries.len(), order.as_mut_ptr(), 2) };
        assert_eq!(count, 2);
        assert_eq!(order, [1, 0]);
    }

    /// An empty queue is zero, and a null `out` is answered rather than dereferenced.
    #[test]
    fn an_empty_queue_and_a_null_buffer_are_both_inert() {
        // SAFETY: a zero-length read of a dangling-but-aligned pointer, and `out` is never touched.
        let empty = unsafe {
            slopdesk_ws_attention_order(
                core::ptr::NonNull::dangling().as_ptr(),
                0,
                core::ptr::null_mut(),
                0,
            )
        };
        assert_eq!(empty, 0);
        let entries = [SlopDeskWaitingPane {
            badge: badge_byte(TabBadge::AwaitingInput),
            has_since: false,
            since: 0.0,
        }];
        // SAFETY: `entries` is a live local, and a null `out` is the documented short case.
        let needed =
            unsafe { slopdesk_ws_attention_order(entries.as_ptr(), entries.len(), core::ptr::null_mut(), 1) };
        assert_eq!(needed, 1);
    }
}
