//! What one frame does to the client's replica of the workspace document, in C.
//!
//! The rules are `slopdesk_workspace::mirror_fold`; what is here is the marshalling.
//!
//! ## Why the frame verdict takes a BIT where the wire has a UUID
//!
//! "Is this frame's epoch the one I hold" is a `UUID` comparison, and a `UUID` is the near side's.
//! The rule needs the ANSWER, not the identity, so the comparison stays where the values are and
//! one bool crosses. The same is true of the intent verdict: the wire's status vocabulary belongs
//! to the codec, and re-spelling it here would be a second place for it to drift.
//!
//! ## The two roster joins, and why nothing is named
//!
//! A client crosses as a dense `u32` token the caller minted for its instance id, plus two flags.
//! An attachment crosses as the same token. The answers are POSITIONS into the client array the
//! caller still holds — so the join decides WHICH label, and the caller reads it. A label's TEXT
//! never crosses in either direction.

use core::ffi::c_uchar;

use slopdesk_workspace::mirror_fold::{self, Age, RosterClient};

use crate::{borrow, deliver, optional_of};

/// One in-flight optimistic patch, as both pending folds need to see it.
///
/// One record for two doors on purpose: the caller holds ONE array of patches and asks two
/// questions about it — what the frame that just landed retires, and what the clock has expired —
/// so building the rows twice would be two chances to build them differently.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct SlopDeskWsPendingPatch {
    /// The frame count at which host truth has certainly superseded this patch. Read only when
    /// `retiring` is `true`.
    pub retire_at: u64,
    /// When the intent was issued, in the caller's own timebase.
    pub issued_at: f64,
    /// Whether the host has already ANSWERED this patch, so it is waiting on a frame rather than on
    /// the host.
    pub retiring: bool,
}

/// One roster client, as the two presence joins need to see it.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SlopDeskWsPresenceClient {
    /// The dense token the caller minted for this client's instance id.
    pub token: u32,
    /// Whether the client published a label anybody can read.
    pub labelled: bool,
    /// Whether the client is looking at the pane being asked about.
    pub viewing: bool,
}

/// What the host's verdict on one intent does to its optimistic patch.
///
/// `holds` is the guard: `retire_at` is meaningless when it is `false`, which is the [`Option`] the
/// rule answers flattened for a caller that has no such type. A refusal zeroes it rather than
/// leaving it undefined.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SlopDeskWsIntentRetire {
    /// Whether the patch is HELD until a frame retires it. `false` ⇒ drop it now.
    pub holds: bool,
    /// The frame count that retires it.
    pub retire_at: u64,
}

/// Copies an answer of POSITIONS into the caller's buffer if it fits, and reports the count either
/// way — [`crate::deliver`]'s contract in a wider unit.
///
/// # Safety
/// `out` must either be null or point to `cap` writable `u32` for the whole call.
#[expect(
    unsafe_code,
    reason = "writing into the caller's buffer is the other half of the boundary"
)]
unsafe fn deliver_positions(answer: &[u32], out: *mut u32, cap: usize) -> usize {
    let needed = answer.len();
    if needed == 0 || needed > cap || out.is_null() {
        return needed;
    }
    // SAFETY: `needed <= cap` was just checked, `out` is non-null and writable for `cap` elements
    // by the caller's obligation, and `answer` was allocated inside this call, so the two cannot
    // overlap.
    unsafe { core::ptr::copy_nonoverlapping(answer.as_ptr(), out, needed) };
    needed
}

/// Whether a DIFF frame may be folded: `0` re-subscribe · `1` ignore it · `2` apply it.
///
/// `epoch_held` is the caller's own "I hold a document AND it is this frame's" — the identity is a
/// `UUID`, and only the answer crosses.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_ws_mirror_diff_frame(
    epoch_held: bool,
    base: i64,
    new: i64,
    held: i64,
) -> c_uchar {
    mirror_fold::diff_frame(epoch_held, base, new, held).code()
}

/// What `subscribe` should declare as the state it holds. All-or-nothing with the epoch.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_ws_mirror_known_state(epoch_held: bool, state_num: i64) -> i64 {
    mirror_fold::known_state_num(epoch_held, state_num)
}

/// What the host's verdict does to one optimistic patch: dropped now, or held one more frame.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_ws_mirror_intent_retire(
    applied: bool,
    frames_applied: u64,
) -> SlopDeskWsIntentRetire {
    mirror_fold::intent_retire(applied, frames_applied).map_or_else(
        SlopDeskWsIntentRetire::default,
        |retire_at| {
            SlopDeskWsIntentRetire {
                holds: true,
                retire_at,
            }
        },
    )
}

/// Which patches survive the document frame that just landed, as POSITIONS into `rows`.
///
/// `frames_applied` is the count INCLUDING that frame. Returns the count NEEDED; a short or null
/// `out` is written nothing and told the length.
///
/// # Safety
/// `(rows, len)` must be readable for the call and `out` writable for `capacity` `u32`s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and both pointers are the caller's"
)]
pub unsafe extern "C" fn slopdesk_ws_mirror_frame_survivors(
    rows: *const SlopDeskWsPendingPatch,
    len: usize,
    frames_applied: u64,
    out: *mut u32,
    capacity: usize,
) -> usize {
    // SAFETY: the caller's obligation, restated above; the borrow dies with this call.
    let lent = unsafe { borrow(rows, len) };
    let retire_at: Vec<Option<u64>> = lent
        .iter()
        .map(|row| optional_of(row.retiring, row.retire_at))
        .collect();
    let survivors = mirror_fold::survivors_after_frame(&retire_at, frames_applied);
    // SAFETY: `out` is null or writable for `capacity` elements by the caller's obligation.
    unsafe { deliver_positions(&survivors, out, capacity) }
}

/// Which patches survive the expiry sweep at `now`, as POSITIONS into `rows`.
///
/// Returns the count NEEDED; a short or null `out` is written nothing and told the length.
///
/// # Safety
/// `(rows, len)` must be readable for the call and `out` writable for `capacity` `u32`s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and both pointers are the caller's"
)]
pub unsafe extern "C" fn slopdesk_ws_mirror_timeout_survivors(
    rows: *const SlopDeskWsPendingPatch,
    len: usize,
    now: f64,
    timeout: f64,
    out: *mut u32,
    capacity: usize,
) -> usize {
    // SAFETY: the caller's obligation, restated above; the borrow dies with this call.
    let lent = unsafe { borrow(rows, len) };
    let ages: Vec<Age> = lent
        .iter()
        .map(|row| {
            Age {
                issued_at: row.issued_at,
                retiring: row.retiring,
            }
        })
        .collect();
    let survivors = mirror_fold::survivors_after_timeout(&ages, now, timeout);
    // SAFETY: `out` is null or writable for `capacity` elements by the caller's obligation.
    unsafe { deliver_positions(&survivors, out, capacity) }
}

/// Which of the three candidates names the command a pane is RUNNING, and its text.
///
/// `source` is written whatever the buffer does — `0` nothing · `1` the host's open block · `2`
/// this client's own · `3` the caller's process label — because it is the answer, and the text is
/// only the part of it this side is holding. `3` and `0` write no text: the process label is the
/// caller's own string, already cleaned up on the near side.
///
/// Returns the count NEEDED for the text. It is never longer than the longer input, so a buffer of
/// that size is the arithmetic bound rather than a guess.
///
/// # Safety
/// Both input pairs must be readable for the call, `source` either null or writable for one byte,
/// and `out` writable for `capacity` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and every pointer is the caller's"
)]
pub unsafe extern "C" fn slopdesk_ws_mirror_running_command(
    hosted: *const c_uchar,
    hosted_len: usize,
    open: *const c_uchar,
    open_len: usize,
    has_process_label: bool,
    source: *mut c_uchar,
    out: *mut c_uchar,
    capacity: usize,
) -> usize {
    // SAFETY: the caller's obligation, restated above; both borrows die with this call.
    let held = String::from_utf8_lossy(unsafe { borrow(hosted, hosted_len) });
    // SAFETY: as above.
    let newest = String::from_utf8_lossy(unsafe { borrow(open, open_len) });
    let chosen = mirror_fold::running_command(&held, &newest, has_process_label);
    if !source.is_null() {
        // SAFETY: non-null and writable for one byte by the caller's obligation above.
        unsafe {
            source.write(chosen.code());
        }
    }
    let answer = chosen.text().unwrap_or_default();
    // SAFETY: `out` is null or writable for `capacity` bytes by the caller's obligation.
    unsafe { deliver(answer.as_bytes(), out, capacity) }
}

/// Whether the host has actually resolved a grid for a pane. Both axes, or neither.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_ws_mirror_grid_published(cols: u32, rows: u32) -> bool {
    mirror_fold::grid_published(cols, rows)
}

/// Whether a document change may reconcile the registry against the layout it produced.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_ws_mirror_reconcile_admitted(
    reconciling: bool,
    projected: bool,
    bootstrap_armed: bool,
    adopt_pending: bool,
    epoch_is_seed: bool,
) -> bool {
    mirror_fold::reconcile_admitted(
        reconciling,
        projected,
        bootstrap_armed,
        adopt_pending,
        epoch_is_seed,
    )
}

/// Which intent a spec edit becomes: `0` none · `1` the video binding · `2` an authored rename.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_ws_mirror_spec_intent(
    video_moved: bool,
    user_renamed: bool,
    title_moved: bool,
    was_user_renamed: bool,
) -> c_uchar {
    mirror_fold::spec_intent(video_moved, user_renamed, title_moved, was_user_renamed).code()
}

/// The other clients currently LOOKING at a pane, as POSITIONS into `clients`.
///
/// `has_own` is false for a client with no workspace channel of its own, which is then not in the
/// roster to be excluded from it.
///
/// # Safety
/// `(clients, len)` must be readable for the call and `out` writable for `capacity` `u32`s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and both pointers are the caller's"
)]
pub unsafe extern "C" fn slopdesk_ws_mirror_viewers(
    clients: *const SlopDeskWsPresenceClient,
    len: usize,
    has_own: bool,
    own: u32,
    out: *mut u32,
    capacity: usize,
) -> usize {
    // SAFETY: the caller's obligation, restated above; the borrow dies with this call.
    let lent = unsafe { borrow(clients, len) };
    let roster: Vec<RosterClient> = lent.iter().map(|client| seat_of(*client)).collect();
    let found = mirror_fold::viewers(&roster, optional_of(has_own, own));
    // SAFETY: `out` is null or writable for `capacity` elements by the caller's obligation.
    unsafe { deliver_positions(&found, out, capacity) }
}

/// The other clients HOLDING a channel on a pane: one answer per surviving attachment, in
/// `attachments` order.
///
/// Each answer is a POSITION into `clients`, or `-1` for an attachment no roster client names — a
/// real client holding a real pane that nothing can label. `-1` is admissible as a refusal here
/// because a position is never negative by construction.
///
/// # Safety
/// Both input arrays must be readable for the call, and `out` writable for `capacity` `ptrdiff_t`.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and every pointer is the caller's"
)]
pub unsafe extern "C" fn slopdesk_ws_mirror_holders(
    attachments: *const u32,
    attachments_len: usize,
    clients: *const SlopDeskWsPresenceClient,
    clients_len: usize,
    has_own: bool,
    own: u32,
    out: *mut isize,
    capacity: usize,
) -> usize {
    // SAFETY: the caller's obligation, restated above; the borrow dies with this call.
    let held = unsafe { borrow(attachments, attachments_len) };
    // SAFETY: as above.
    let lent = unsafe { borrow(clients, clients_len) };
    let roster: Vec<RosterClient> = lent.iter().map(|client| seat_of(*client)).collect();
    let found = mirror_fold::holders(held, &roster, optional_of(has_own, own));
    let answer: Vec<isize> = found
        .iter()
        .map(|position| position.map_or(-1, |index| isize::try_from(index).unwrap_or(-1)))
        .collect();
    let needed = answer.len();
    if needed == 0 || needed > capacity || out.is_null() {
        return needed;
    }
    // SAFETY: `needed <= capacity` was just checked, `out` is non-null and writable for `capacity`
    // elements by the caller's obligation, and `answer` was allocated inside this call.
    unsafe { core::ptr::copy_nonoverlapping(answer.as_ptr(), out, needed) };
    needed
}

/// One lent roster row, as the rules know it.
fn seat_of(client: SlopDeskWsPresenceClient) -> RosterClient {
    RosterClient {
        token: client.token,
        labelled: client.labelled,
        viewing: client.viewing,
    }
}

#[cfg(test)]
mod tests {
    #![expect(unsafe_code, reason = "calling the door is the only way to test the door")]

    use slopdesk_workspace::mirror_fold::{self, Age, RosterClient};

    use super::{
        SlopDeskWsPendingPatch, SlopDeskWsPresenceClient, slopdesk_ws_mirror_diff_frame,
        slopdesk_ws_mirror_frame_survivors, slopdesk_ws_mirror_grid_published, slopdesk_ws_mirror_holders,
        slopdesk_ws_mirror_intent_retire, slopdesk_ws_mirror_known_state,
        slopdesk_ws_mirror_reconcile_admitted, slopdesk_ws_mirror_running_command,
        slopdesk_ws_mirror_spec_intent, slopdesk_ws_mirror_timeout_survivors, slopdesk_ws_mirror_viewers,
    };

    /// Every `(epoch_held, base, new)` the rule can be asked about crosses to the same verdict the
    /// rule gives directly.
    #[test]
    fn every_frame_verdict_crosses_verbatim() {
        for epoch_held in [false, true] {
            for base in 0..=6_i64 {
                for new in 0..=6_i64 {
                    assert_eq!(
                        slopdesk_ws_mirror_diff_frame(epoch_held, base, new, 3),
                        mirror_fold::diff_frame(epoch_held, base, new, 3).code(),
                        "({epoch_held}, {base}, {new})"
                    );
                }
            }
        }
    }

    /// The declared state, and the intent verdict's guard-plus-value shape.
    #[test]
    fn the_scalar_doors_cross_verbatim() {
        assert_eq!(slopdesk_ws_mirror_known_state(true, 9), 9);
        assert_eq!(slopdesk_ws_mirror_known_state(false, 9), 0);

        let held = slopdesk_ws_mirror_intent_retire(true, 4);
        assert!(held.holds);
        assert_eq!(held.retire_at, 5);
        let dropped = slopdesk_ws_mirror_intent_retire(false, 4);
        assert!(!dropped.holds);
        assert_eq!(dropped.retire_at, 0, "a refusal is zeroed, not arbitrary");

        assert!(slopdesk_ws_mirror_grid_published(80, 24));
        assert!(!slopdesk_ws_mirror_grid_published(80, 0));

        for reconciling in [false, true] {
            for projected in [false, true] {
                for bootstrap in [false, true] {
                    for adopt in [false, true] {
                        for seed in [false, true] {
                            assert_eq!(
                                slopdesk_ws_mirror_reconcile_admitted(
                                    reconciling,
                                    projected,
                                    bootstrap,
                                    adopt,
                                    seed
                                ),
                                mirror_fold::reconcile_admitted(
                                    reconciling,
                                    projected,
                                    bootstrap,
                                    adopt,
                                    seed
                                ),
                            );
                        }
                    }
                }
            }
        }

        for video in [false, true] {
            for renamed in [false, true] {
                for moved in [false, true] {
                    for was in [false, true] {
                        assert_eq!(
                            slopdesk_ws_mirror_spec_intent(video, renamed, moved, was),
                            mirror_fold::spec_intent(video, renamed, moved, was).code(),
                        );
                    }
                }
            }
        }
    }

    /// The two pending folds cross their positions, and a short buffer is told the length.
    #[test]
    fn the_pending_folds_cross_as_positions() {
        let rows = [
            SlopDeskWsPendingPatch {
                retire_at: 0,
                issued_at: 0.0,
                retiring: false,
            },
            SlopDeskWsPendingPatch {
                retire_at: 4,
                issued_at: 1.0,
                retiring: true,
            },
            SlopDeskWsPendingPatch {
                retire_at: 9,
                issued_at: 2.0,
                retiring: true,
            },
        ];
        let mut out = [0_u32; 3];
        // SAFETY: both arrays are live locals for the call.
        let count =
            unsafe { slopdesk_ws_mirror_frame_survivors(rows.as_ptr(), rows.len(), 4, out.as_mut_ptr(), 3) };
        assert_eq!(count, 2);
        assert_eq!(out.get(..count), Some([0_u32, 2].as_slice()));

        let mut short = [7_u32; 1];
        // SAFETY: both arrays are live locals for the call.
        let needed = unsafe {
            slopdesk_ws_mirror_frame_survivors(rows.as_ptr(), rows.len(), 4, short.as_mut_ptr(), 1)
        };
        assert_eq!(needed, 2);
        assert_eq!(short, [7], "and written nothing");

        let ages: Vec<Age> = rows
            .iter()
            .map(|row| {
                Age {
                    issued_at: row.issued_at,
                    retiring: row.retiring,
                }
            })
            .collect();
        let mut timed = [0_u32; 3];
        // SAFETY: both arrays are live locals for the call.
        let expired = unsafe {
            slopdesk_ws_mirror_timeout_survivors(rows.as_ptr(), rows.len(), 3.0, 3.0, timed.as_mut_ptr(), 3)
        };
        let native = mirror_fold::survivors_after_timeout(&ages, 3.0, 3.0);
        assert_eq!(expired, native.len());
        assert_eq!(timed.get(..expired), Some(native.as_slice()));
    }

    /// An empty fold is zero, and a null buffer is answered rather than dereferenced.
    #[test]
    fn empty_folds_and_null_buffers_are_inert() {
        // SAFETY: a zero-length read of a dangling-but-aligned pointer; `out` is never touched.
        let empty = unsafe {
            slopdesk_ws_mirror_frame_survivors(
                core::ptr::NonNull::dangling().as_ptr(),
                0,
                1,
                core::ptr::null_mut(),
                0,
            )
        };
        assert_eq!(empty, 0);
        // SAFETY: as above.
        let none = unsafe {
            slopdesk_ws_mirror_holders(
                core::ptr::NonNull::dangling().as_ptr(),
                0,
                core::ptr::NonNull::dangling().as_ptr(),
                0,
                false,
                0,
                core::ptr::null_mut(),
                0,
            )
        };
        assert_eq!(none, 0);
    }

    /// The chain names its rung on the way out, and delivers the winner's text trimmed.
    #[test]
    fn the_running_command_crosses_its_rung_and_its_text() {
        let hosted = "  cargo build  ".as_bytes();
        let open = " make test ".as_bytes();
        let mut source = 9_u8;
        let mut out = [0_u8; 32];
        // SAFETY: every pointer is a live local for the call.
        let count = unsafe {
            slopdesk_ws_mirror_running_command(
                hosted.as_ptr(),
                hosted.len(),
                open.as_ptr(),
                open.len(),
                true,
                &raw mut source,
                out.as_mut_ptr(),
                32,
            )
        };
        assert_eq!(source, 1);
        assert_eq!(out.get(..count), Some(b"cargo build".as_slice()));

        let blank = b"   ";
        // SAFETY: every pointer is a live local for the call.
        let open_wins = unsafe {
            slopdesk_ws_mirror_running_command(
                blank.as_ptr(),
                blank.len(),
                open.as_ptr(),
                open.len(),
                true,
                &raw mut source,
                out.as_mut_ptr(),
                32,
            )
        };
        assert_eq!(source, 2);
        assert_eq!(out.get(..open_wins), Some(b"make test".as_slice()));

        // SAFETY: every pointer is a live local for the call.
        let label = unsafe {
            slopdesk_ws_mirror_running_command(
                blank.as_ptr(),
                blank.len(),
                blank.as_ptr(),
                blank.len(),
                true,
                &raw mut source,
                out.as_mut_ptr(),
                32,
            )
        };
        assert_eq!(source, 3);
        assert_eq!(label, 0, "the process label's text is the caller's own");

        // SAFETY: a zero-length read of a dangling-but-aligned pointer.
        let nothing = unsafe {
            slopdesk_ws_mirror_running_command(
                core::ptr::NonNull::dangling().as_ptr(),
                0,
                core::ptr::NonNull::dangling().as_ptr(),
                0,
                false,
                &raw mut source,
                core::ptr::null_mut(),
                0,
            )
        };
        assert_eq!(source, 0);
        assert_eq!(nothing, 0);
    }

    /// Both joins cross verbatim, and the unnamed attachment crosses as the one negative.
    #[test]
    fn the_roster_joins_cross_verbatim() {
        let clients = [
            SlopDeskWsPresenceClient {
                token: 1,
                labelled: true,
                viewing: true,
            },
            SlopDeskWsPresenceClient {
                token: 2,
                labelled: false,
                viewing: true,
            },
            SlopDeskWsPresenceClient {
                token: 3,
                labelled: true,
                viewing: true,
            },
        ];
        let roster: Vec<RosterClient> = clients
            .iter()
            .map(|client| {
                RosterClient {
                    token: client.token,
                    labelled: client.labelled,
                    viewing: client.viewing,
                }
            })
            .collect();
        let mut out = [0_u32; 3];
        // SAFETY: both arrays are live locals for the call.
        let count = unsafe {
            slopdesk_ws_mirror_viewers(clients.as_ptr(), clients.len(), true, 3, out.as_mut_ptr(), 3)
        };
        let native = mirror_fold::viewers(&roster, Some(3));
        assert_eq!(count, native.len());
        assert_eq!(out.get(..count), Some(native.as_slice()));

        let attachments = [1_u32, 2, 9, 3];
        let mut holders = [0_isize; 4];
        // SAFETY: every array is a live local for the call.
        let held = unsafe {
            slopdesk_ws_mirror_holders(
                attachments.as_ptr(),
                attachments.len(),
                clients.as_ptr(),
                clients.len(),
                true,
                3,
                holders.as_mut_ptr(),
                4,
            )
        };
        assert_eq!(held, 3);
        assert_eq!(holders.get(..held), Some([0_isize, -1, -1].as_slice()));
    }
}
