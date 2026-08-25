//! Where an inbound `channelOpen` goes, and the numbers a reattach turns on — in C.
//!
//! Seven doors over [`slopdesk_muxsession::open_route`], and not one of them holds state. That is
//! unusual for this file's neighbours and it is the point: the router IS a function of the facts
//! hostd reads under its own lock, so there is nothing to allocate, nothing to free, and no handle
//! whose lifetime could be got wrong. hostd calls, acts, and the answer is gone.
//!
//! ## The facts cross as scalars, never as identities
//! A `MuxChannelSession` is a Swift actor around a PTY and a `DetachedSessionStore` is a Swift
//! object with a TTL task. Neither crosses. What crosses is the SHAPE of what hostd found —
//! "somebody live holds this id, under another key" — and the verdict comes back as a byte hostd
//! resolves against the objects it already has. The claim itself stays Swift for the same reason:
//! it mutates that store and cancels that task.
//!
//! ## Why every door answers a byte
//! Each verdict is a closed enum whose discriminants are `1`-based, so `0` is available as "this
//! build has no answer" and a Swift `RawRepresentable` init can refuse it rather than fold it into
//! a case that means something. A route byte read as the wrong case here forks a shell.

use core::ffi::{c_longlong, c_uchar, c_ulonglong};

use slopdesk_muxsession::open_route::{
    Claim, Incumbent, OpenFacts, Redraw, Route, SurvivorResume, ownership_allows_adoption, redraw,
    restores_transcript, resume_from, route, settle, survivor_resume,
};

use crate::lent;

/// Routes one `channelOpen`.
///
/// The five facts cross as they are read: hostd holds ONE critical section, reads its maps into
/// these scalars, and unlocks. An `incumbent` byte outside the enum reads as
/// [`Incumbent::None`] — the conservative answer, because it is the one that leaves the claim and
/// the spawn free to discover the truth for themselves rather than joining a session that may not
/// be there.
///
/// # Safety
/// Pure. Nothing is borrowed and nothing is retained.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_mux_open_route(
    channel_class: c_uchar,
    incumbent: c_uchar,
    stopping: bool,
    real_session_id: bool,
    detached_store: bool,
) -> c_uchar {
    let incumbent = match incumbent {
        1 => Incumbent::ThisKey,
        2 => Incumbent::OtherKey,
        _ => Incumbent::None,
    };
    let verdict = route(OpenFacts {
        channel_class,
        incumbent,
        stopping,
        real_session_id,
        detached_store,
    });
    match verdict {
        Route::Workspace => 1,
        Route::Decline => 2,
        Route::RefuseStopping => 3,
        Route::ReAck => 4,
        Route::Join => 5,
        Route::Claim => 6,
        Route::SpawnFresh => 7,
    }
}

/// Turns the detached store's answer into the next action.
///
/// An outcome byte this build has no name for settles as a fresh spawn: the store said something
/// unrecognised, and forking a shell is the one action that is correct whatever it was.
///
/// # Safety
/// Pure.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_mux_open_settle(outcome: c_uchar) -> c_uchar {
    let outcome = match outcome {
        1 => Claim::Claimed,
        2 => Claim::ReapedDeadChild,
        _ => Claim::NotFound,
    };
    settle(outcome) as c_uchar
}

/// The host-authoritative resume verdict — the client's memory, clamped to what this session can
/// actually number.
///
/// # Safety
/// Pure.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_mux_open_resume_from(
    last_received_seq: c_longlong,
    highest_assigned_seq: c_longlong,
) -> c_longlong {
    resume_from(last_received_seq, highest_assigned_seq)
}

/// Which repaint a reattached pane earns: `1` a plain nudge, `2` the size jiggle.
///
/// # Safety
/// Pure.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_mux_open_redraw(cold_client: bool, snapshot_composed: bool) -> c_uchar {
    match redraw(cold_client, snapshot_composed) {
        Redraw::Nudge => 1,
        Redraw::Jiggle => 2,
    }
}

/// Whether a fresh spawn for a returning id replays the on-disk transcript first.
///
/// # Safety
/// Pure.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_mux_open_restores_transcript(
    real_session_id: bool,
    last_received_seq: c_longlong,
) -> bool {
    restores_transcript(real_session_id, last_received_seq)
}

/// Where an adopted pane's supervised stream resumes.
///
/// `head` is optional at the ABI the way every optional number in this file is: `has_head` says
/// whether the value beside it is one. `unpositioned` is written through the out-parameter and is
/// the caller's cue to log — the one case where the answer had to be guessed.
///
/// # Safety
/// `unpositioned` must be a valid, writable `bool` for the duration of the call, or null. A null
/// pointer drops the flag rather than faulting; the offset is still returned.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "reconstituting the caller's spans IS the boundary this module documents"
)]
pub unsafe extern "C" fn slopdesk_mux_open_survivor_resume(
    stored_bytes: c_ulonglong,
    has_head: bool,
    head: c_ulonglong,
    unpositioned: *mut bool,
) -> c_ulonglong {
    let SurvivorResume {
        offset,
        unpositioned: guessed,
    } = survivor_resume(stored_bytes, has_head.then_some(head));
    if !unpositioned.is_null() {
        // SAFETY: the caller's contract above — non-null means a live, writable `bool`. Swift
        // passes `&flag` on a local `var`, which is exactly that for the call's duration.
        unsafe { unpositioned.write(guessed) };
    }
    offset
}

/// Whether a surviving pane's recorded owner permits THIS hostd to adopt it.
///
/// Both spans read as empty when they are null, not valid UTF-8, or zero-length — and an empty
/// OWNER is the "no owner recorded" case, which is adoptable by design. An owner that is not UTF-8
/// therefore reads as unowned rather than as a stranger's: superd writes this field as an ASCII
/// identity, so bytes that are not one are a record this build cannot interpret, and the pre-1.4
/// answer is the one that does not strand a live shell.
///
/// # Safety
/// Each `(ptr, len)` pair must name `len` initialised bytes live for the call, or be null.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "reconstituting the caller's spans IS the boundary this module documents"
)]
pub unsafe extern "C" fn slopdesk_mux_open_ownership_allows_adoption(
    owner: *const c_uchar,
    owner_len: usize,
    ours: *const c_uchar,
    ours_len: usize,
) -> bool {
    // SAFETY: the caller's contract above, discharged by the shared text-borrow helper.
    let owner = unsafe { lent(owner, owner_len) };
    // SAFETY: as above.
    let ours = unsafe { lent(ours, ours_len) };
    ownership_allows_adoption(owner, ours)
}

#[cfg(test)]
#[expect(unsafe_code, reason = "calling the door is the only way to test the door")]
mod tests {
    use super::*;

    const PANE: c_uchar = 0;
    const WORKSPACE: c_uchar = 1;

    fn adoptable(owner: &str, ours: &str) -> bool {
        unsafe {
            slopdesk_mux_open_ownership_allows_adoption(
                owner.as_ptr(),
                owner.len(),
                ours.as_ptr(),
                ours.len(),
            )
        }
    }

    #[test]
    fn every_route_crosses_as_its_own_byte() {
        assert_eq!(slopdesk_mux_open_route(WORKSPACE, 0, false, true, true), 1);
        assert_eq!(slopdesk_mux_open_route(9, 0, false, true, true), 2);
        assert_eq!(slopdesk_mux_open_route(PANE, 0, true, true, true), 3);
        assert_eq!(slopdesk_mux_open_route(PANE, 1, false, true, true), 4);
        assert_eq!(slopdesk_mux_open_route(PANE, 2, false, true, true), 5);
        assert_eq!(slopdesk_mux_open_route(PANE, 0, false, true, true), 6);
        assert_eq!(slopdesk_mux_open_route(PANE, 0, false, false, true), 7);
    }

    #[test]
    fn an_incumbent_byte_this_build_has_no_name_for_holds_nothing() {
        // 3 is not a state — it must not read as OtherKey and join a session that is not there.
        assert_eq!(slopdesk_mux_open_route(PANE, 3, false, true, true), 6);
        assert_eq!(slopdesk_mux_open_route(PANE, 255, false, true, false), 7);
    }

    #[test]
    fn a_claim_outcome_settles_and_an_unknown_one_forks() {
        assert_eq!(slopdesk_mux_open_settle(1), 1);
        assert_eq!(slopdesk_mux_open_settle(2), 2);
        assert_eq!(slopdesk_mux_open_settle(3), 3);
        assert_eq!(slopdesk_mux_open_settle(200), 3);
    }

    #[test]
    fn the_reattach_numbers_cross_unchanged() {
        assert_eq!(slopdesk_mux_open_resume_from(4_000, 1), 1);
        assert_eq!(slopdesk_mux_open_resume_from(120, 4_000), 120);
        assert_eq!(
            slopdesk_mux_open_resume_from(-1, 900),
            -1,
            "a seq is signed on the wire"
        );
        assert_eq!(slopdesk_mux_open_redraw(true, false), 2);
        assert_eq!(slopdesk_mux_open_redraw(true, true), 1);
        assert!(slopdesk_mux_open_restores_transcript(true, 0));
        assert!(!slopdesk_mux_open_restores_transcript(true, 7));
    }

    #[test]
    fn a_survivor_without_a_position_says_so_through_the_out_parameter() {
        let mut guessed = false;
        assert_eq!(
            unsafe { slopdesk_mux_open_survivor_resume(4_096, true, 4_096, &raw mut guessed) },
            4_096,
        );
        assert!(!guessed);
        assert_eq!(
            unsafe { slopdesk_mux_open_survivor_resume(4_096, false, 0, &raw mut guessed) },
            u64::MAX,
        );
        assert!(guessed);
        // An empty file resumes at 0 and clears the flag it may have set on a previous call.
        assert_eq!(
            unsafe { slopdesk_mux_open_survivor_resume(0, false, 0, &raw mut guessed) },
            0,
        );
        assert!(!guessed);
    }

    #[test]
    fn a_null_out_parameter_drops_the_flag_rather_than_faulting() {
        assert_eq!(
            unsafe { slopdesk_mux_open_survivor_resume(4_096, false, 0, core::ptr::null_mut()) },
            u64::MAX,
        );
    }

    #[test]
    fn an_owner_span_that_is_absent_or_unreadable_reads_as_unowned() {
        assert!(adoptable(
            "hostd port=7777 state=default",
            "hostd port=7777 state=default"
        ));
        assert!(!adoptable(
            "hostd port=7778 state=default",
            "hostd port=7777 state=default"
        ));
        assert!(adoptable("", "hostd port=7777 state=default"));
        let ours = "hostd port=7777 state=default";
        assert!(unsafe {
            slopdesk_mux_open_ownership_allows_adoption(core::ptr::null(), 0, ours.as_ptr(), ours.len())
        });
        // Not UTF-8: a record this build cannot interpret is the pre-1.4 case, not a stranger's.
        let raw = [0xFFu8, 0xFE, 0xFD];
        assert!(unsafe {
            slopdesk_mux_open_ownership_allows_adoption(raw.as_ptr(), raw.len(), ours.as_ptr(), ours.len())
        });
    }
}
