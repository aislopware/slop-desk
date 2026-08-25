//! The workspace channel client's run ladder — which run still speaks, what it still owns.
//!
//! `rust/slopdesk-workspace`'s `channel_run` owns the decisions. This is the door.
//!
//! ## Why this handle is exclusive
//! Every caller is `WorkspaceChannelClient`, which is `@MainActor` — so unlike
//! [`crate::pane_lifecycle`], whose latches are written from three threads, this one is reached
//! from exactly one and hands out `&mut`. The actor IS the lock.
//!
//! ## Reading a state across the boundary
//! `RunState` is a tagged number on the far side and a Swift `enum` with an associated value on the
//! near one, so it crosses as the PAIR the tag and the `stateNum` make:
//! `slopdesk_channel_run_state` answers the tag and writes the number through an out-parameter.
//! Collapsing that to a tag alone would make `.live(5)` and `.live(6)` the same state and swallow
//! every document frame after the first.
//!
//! ## What did NOT cross
//! The two ordered drains and their queues, the bounded handshake race, the mirror the frames land
//! in, and the loopback document. A `Task` slot is not a number and a queue's ORDER is an argument
//! about main-actor hops; the door answers whether a run may start, whether its publish is still
//! wanted, who releases the channel, and which presence clock is next.

use slopdesk_workspace::channel_run::{ChannelRun, RunState};

/// One workspace channel client's run ladder, as an opaque handle.
///
/// `Copy` deliberately absent: the handle OWNS a boxed ladder, and a type that copied would let two
/// callers hold generations that agree only until the first `start`.
#[derive(Debug)]
#[expect(
    missing_copy_implementations,
    reason = "a copied ladder is two clients claiming one channel"
)]
pub struct SlopDeskChannelRun {
    /// The state the main actor serializes.
    inner: ChannelRun,
}

/// The `start` verdict for a client that may not open a run — already running, or refused.
pub const START_REFUSED: u64 = 0;

/// A [`slopdesk_channel_run_finish`] from a run a newer one has superseded: say nothing, touch
/// nothing.
pub const FINISH_STALE: u8 = 0;

/// A [`slopdesk_channel_run_finish`] from the current run, ending on the state it was already in:
/// retire the task, announce nothing.
pub const FINISH_QUIET: u8 = 1;

/// A [`slopdesk_channel_run_finish`] from the current run, ending somewhere new: retire the task
/// and announce.
pub const FINISH_NEWS: u8 = 2;

/// Turns the caller's handle back into a reference.
///
/// # Safety
/// `handle` must be null or a live pointer from [`slopdesk_channel_run_new`] that has not been
/// freed, and no other reference to it may be live for the duration of the call.
#[expect(
    unsafe_code,
    reason = "turning the caller's handle back into a reference is this module's whole obligation"
)]
const unsafe fn held<'a>(handle: *mut SlopDeskChannelRun) -> Option<&'a mut SlopDeskChannelRun> {
    // SAFETY: by the caller's obligation this is a live, exclusively-held allocation from `new`.
    unsafe { handle.as_mut() }
}

/// A client that has never opened anything: idle, owning no channel, at clock zero.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_channel_run_new() -> *mut SlopDeskChannelRun {
    Box::into_raw(Box::new(SlopDeskChannelRun {
        inner: ChannelRun::new(),
    }))
}

/// Frees a run ladder. Null is a no-op, and the same pointer must not be freed twice.
///
/// # Safety
/// `handle` must be null or a pointer from [`slopdesk_channel_run_new`], freed exactly once, with
/// no other reference to it live.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_channel_run_free(handle: *mut SlopDeskChannelRun) {
    if handle.is_null() {
        return;
    }
    // SAFETY: by the caller's obligation this pointer came from one `new` and is freed once.
    drop(unsafe { Box::from_raw(handle) });
}

/// The current state's tag, writing the `.live` state number to `state_num` when it is non-null.
///
/// A dead handle answers the idle tag and writes `0`, which is what a client with no ladder is.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation, and `state_num` must be null or point at one
/// writable `int64_t` for the duration of the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_channel_run_state(
    handle: *mut SlopDeskChannelRun,
    state_num: *mut i64,
) -> u8 {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    let (tag, number) =
        (unsafe { held(handle) }).map_or(RunState::Idle.parts(), |run| run.inner.state().parts());
    if !state_num.is_null() {
        // SAFETY: by the caller's obligation this points at one writable `i64` for this call.
        unsafe { state_num.write(number) };
    }
    tag
}

/// Whether this client can carry an intent right now. A dead handle answers `false`.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_channel_run_may_send_intent(handle: *mut SlopDeskChannelRun) -> bool {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    unsafe { held(handle) }.is_some_and(|run| run.inner.may_send_intent())
}

/// Admits a run and answers the generation it must quote in every later publish.
///
/// [`START_REFUSED`] for a client that already has a run in flight, for one the host has refused,
/// and for a dead handle — generations start at 1, so zero is unambiguous.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_channel_run_start(
    handle: *mut SlopDeskChannelRun,
    run_in_flight: bool,
) -> u64 {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    let Some(run) = (unsafe { held(handle) }) else {
        return START_REFUSED;
    };
    run.inner.start(run_in_flight).unwrap_or(START_REFUSED)
}

/// Retires every run in flight and claims the channel for release.
///
/// Answers whether `.closed` is news, writing the channel id this stop claimed to `release` when it
/// is non-null and `has_release`. A dead handle publishes nothing and claims nothing.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation, and each of `release`/`has_release` must be null or
/// point at one writable `uint32_t`/`bool` for the duration of the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_channel_run_stop(
    handle: *mut SlopDeskChannelRun,
    release: *mut u32,
    has_release: *mut bool,
) -> bool {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    let Some(run) = (unsafe { held(handle) }) else {
        if !has_release.is_null() {
            // SAFETY: by the caller's obligation this points at one writable `bool` for this call.
            unsafe { has_release.write(false) };
        }
        return false;
    };
    let verdict = run.inner.stop();
    if !has_release.is_null() {
        // SAFETY: by the caller's obligation this points at one writable `bool` for this call.
        unsafe { has_release.write(verdict.release.is_some()) };
    }
    if !release.is_null() {
        // SAFETY: by the caller's obligation this points at one writable `u32` for this call.
        unsafe { release.write(verdict.release.unwrap_or_default()) };
    }
    verdict.publish
}

/// Records the channel a run just opened, so a stop arriving mid-handshake knows what to release.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub const unsafe extern "C" fn slopdesk_channel_run_claim(handle: *mut SlopDeskChannelRun, channel: u32) {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    if let Some(run) = unsafe { held(handle) } {
        run.inner.claim(channel);
    }
}

/// Claims `channel` for release, but only while this client still owns it.
///
/// A dead handle answers `false`: a client with no ladder never claimed anything, and closing a
/// pooled channel twice tears down a connection a reconnect has already rebuilt.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_channel_run_release_if_owned(
    handle: *mut SlopDeskChannelRun,
    channel: u32,
) -> bool {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    unsafe { held(handle) }.is_some_and(|run| run.inner.release_if_owned(channel))
}

/// Publishes the state `tag`/`state_num` names on behalf of the run born under `generation`.
///
/// Answers [`FINISH_STALE`] for a superseded run and for a dead handle — a run that owns nothing
/// touches nothing — [`FINISH_QUIET`] for a current run that ended on the state it was already in,
/// and [`FINISH_NEWS`] for one that ended somewhere new. Both of the latter retire the near side's
/// task slot; only the last announces. A tag outside the ladder reads as idle, which is the state
/// that admits a fresh start.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_channel_run_finish(
    handle: *mut SlopDeskChannelRun,
    tag: u8,
    state_num: i64,
    generation: u64,
) -> u8 {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    unsafe { held(handle) }.map_or(FINISH_STALE, |run| {
        run.inner
            .finish(RunState::from_parts(tag, state_num), generation)
            .tag()
    })
}

/// Moves to the state `tag`/`state_num` names, whatever run is current.
///
/// Answers whether that is news. These are the transitions belonging to no run: the `opening` a
/// start announces, and the loopback client born live against an in-process document.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_channel_run_publish(
    handle: *mut SlopDeskChannelRun,
    tag: u8,
    state_num: i64,
) -> bool {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    unsafe { held(handle) }.is_some_and(|run| run.inner.publish(RunState::from_parts(tag, state_num)))
}

/// Mints the next presence clock. A dead handle answers `0`, which no host keeps.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_channel_run_mint_presence_clock(handle: *mut SlopDeskChannelRun) -> i64 {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    (unsafe { held(handle) }).map_or(0, |run| run.inner.mint_presence_clock())
}

#[cfg(test)]
#[expect(unsafe_code, reason = "calling the door is the only way to test the door")]
mod tests {
    use super::{
        FINISH_NEWS, FINISH_STALE, START_REFUSED, slopdesk_channel_run_claim, slopdesk_channel_run_finish,
        slopdesk_channel_run_free, slopdesk_channel_run_may_send_intent,
        slopdesk_channel_run_mint_presence_clock, slopdesk_channel_run_new, slopdesk_channel_run_publish,
        slopdesk_channel_run_release_if_owned, slopdesk_channel_run_start, slopdesk_channel_run_state,
        slopdesk_channel_run_stop,
    };

    /// The tags `RunState::parts` assigns, spelled the way the header spells them.
    const IDLE: u8 = 0;
    const OPENING: u8 = 1;
    const LIVE: u8 = 2;
    const REFUSED: u8 = 3;
    const CLOSED: u8 = 4;

    #[test]
    fn a_fresh_handle_is_idle_and_carries_no_intent() {
        let run = slopdesk_channel_run_new();
        let mut state_num = -1;
        // SAFETY: `run` is live and exclusively held here, and `state_num` is one writable `i64`.
        let tag = unsafe { slopdesk_channel_run_state(run, &raw mut state_num) };
        assert_eq!((tag, state_num), (IDLE, 0));
        // SAFETY: as above.
        assert!(!unsafe { slopdesk_channel_run_may_send_intent(run) });
        // SAFETY: `run` came from one `new` and is freed once.
        unsafe { slopdesk_channel_run_free(run) };
    }

    #[test]
    fn a_null_handle_decides_nothing_and_owns_nothing() {
        let mut state_num = 7;
        // SAFETY: a null handle is the documented dead case, and `state_num` is writable.
        let tag = unsafe { slopdesk_channel_run_state(std::ptr::null_mut(), &raw mut state_num) };
        assert_eq!((tag, state_num), (IDLE, 0));
        // SAFETY: a null handle is the documented dead case.
        unsafe {
            assert_eq!(
                slopdesk_channel_run_start(std::ptr::null_mut(), false),
                START_REFUSED
            );
            assert!(!slopdesk_channel_run_release_if_owned(std::ptr::null_mut(), 4));
            assert!(!slopdesk_channel_run_publish(std::ptr::null_mut(), LIVE, 0));
            assert_eq!(slopdesk_channel_run_mint_presence_clock(std::ptr::null_mut()), 0);
            slopdesk_channel_run_free(std::ptr::null_mut());
        }
    }

    #[test]
    fn a_stop_claims_the_channel_and_the_run_finds_it_gone() {
        let run = slopdesk_channel_run_new();
        let mut release = 0;
        let mut has_release = false;
        // SAFETY: `run` is live and exclusively held, and both out-parameters are writable.
        unsafe {
            assert_eq!(slopdesk_channel_run_start(run, false), 1);
            slopdesk_channel_run_claim(run, 12);
            assert!(slopdesk_channel_run_stop(
                run,
                &raw mut release,
                &raw mut has_release
            ));
            assert!(has_release);
            assert_eq!(release, 12);
            assert!(!slopdesk_channel_run_release_if_owned(run, 12));
            slopdesk_channel_run_free(run);
        }
    }

    #[test]
    fn a_superseded_run_cannot_report_the_live_one_dead() {
        let run = slopdesk_channel_run_new();
        let mut state_num = 0;
        // SAFETY: `run` is live and exclusively held, and `state_num` is one writable `i64`.
        unsafe {
            let first = slopdesk_channel_run_start(run, false);
            slopdesk_channel_run_stop(run, std::ptr::null_mut(), std::ptr::null_mut());
            let second = slopdesk_channel_run_start(run, false);
            assert_eq!(slopdesk_channel_run_finish(run, CLOSED, 0, first), FINISH_STALE);
            assert_eq!(slopdesk_channel_run_state(run, &raw mut state_num), OPENING);
            assert_eq!(slopdesk_channel_run_finish(run, LIVE, 5, second), FINISH_NEWS);
            assert_eq!(slopdesk_channel_run_state(run, &raw mut state_num), LIVE);
            assert_eq!(state_num, 5);
            assert!(slopdesk_channel_run_may_send_intent(run));
            slopdesk_channel_run_free(run);
        }
    }

    #[test]
    fn a_refusal_is_final_until_a_deliberate_stop() {
        let run = slopdesk_channel_run_new();
        // SAFETY: `run` is live and exclusively held throughout.
        unsafe {
            let generation = slopdesk_channel_run_start(run, false);
            assert_eq!(
                slopdesk_channel_run_finish(run, REFUSED, 0, generation),
                FINISH_NEWS
            );
            assert_eq!(slopdesk_channel_run_start(run, false), START_REFUSED);
            slopdesk_channel_run_stop(run, std::ptr::null_mut(), std::ptr::null_mut());
            assert_ne!(slopdesk_channel_run_start(run, false), START_REFUSED);
            slopdesk_channel_run_free(run);
        }
    }

    #[test]
    fn every_acked_state_number_is_news() {
        let run = slopdesk_channel_run_new();
        // SAFETY: `run` is live and exclusively held throughout.
        unsafe {
            assert!(slopdesk_channel_run_publish(run, LIVE, 5));
            assert!(!slopdesk_channel_run_publish(run, LIVE, 5));
            assert!(slopdesk_channel_run_publish(run, LIVE, 6));
            slopdesk_channel_run_free(run);
        }
    }

    #[test]
    fn the_presence_clock_climbs_across_a_reconnect() {
        let run = slopdesk_channel_run_new();
        // SAFETY: `run` is live and exclusively held throughout.
        unsafe {
            assert_eq!(slopdesk_channel_run_mint_presence_clock(run), 1);
            slopdesk_channel_run_stop(run, std::ptr::null_mut(), std::ptr::null_mut());
            assert_eq!(slopdesk_channel_run_mint_presence_clock(run), 2);
            slopdesk_channel_run_free(run);
        }
    }
}
