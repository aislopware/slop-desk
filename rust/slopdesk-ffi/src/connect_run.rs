//! One pane client's connect ladder — which attempt owns the pane, and what a drop MEANS.
//!
//! `rust/slopdesk-workspace`'s `connect_run` owns the decisions. This is the door.
//!
//! ## Why this handle is exclusive
//! Every caller is `ConnectionViewModel` or `AppConnection`, both `@MainActor` — so like
//! [`crate::channel_run`] and unlike [`crate::pane_lifecycle`], this handle is reached from exactly
//! one thread and hands out `&mut`. The actor IS the lock.
//!
//! ## What did NOT cross
//! The chained connect task, the teardown order, the OUT FIFO and its single drain, and the client
//! IDENTITY check the near side pairs with the generation — object identity is not a number. The
//! door answers which attempt is current, whether an automatic dial may proceed, and what a
//! `.disconnected`/`.reconnected` edge means.

use slopdesk_workspace::connect_run::{CloseCause, ConnectRun};

/// One pane client's connect ladder, as an opaque handle.
///
/// `Copy` deliberately absent: the handle OWNS a boxed ladder, and a type that copied would let two
/// callers hold generations that agree only until the first dial.
#[derive(Debug)]
#[expect(
    missing_copy_implementations,
    reason = "a copied ladder is two attempts each believing it owns the pane"
)]
pub struct SlopDeskConnectRun {
    /// The state the main actor serializes.
    inner: ConnectRun,
}

/// The host said nothing about this pane: the link died. Latches nothing.
pub const CLOSE_CAUSE_LINK: u8 = 0;

/// The host reaped the PANE under this channel. Gates the automatic dial paths.
pub const CLOSE_CAUSE_RETIRED: u8 = 1;

/// The host evicted this subscriber from a pane that is still running. Does NOT gate them.
pub const CLOSE_CAUSE_EVICTED: u8 = 2;

/// Turns the caller's handle back into a reference.
///
/// # Safety
/// `handle` must be null or a live pointer from [`slopdesk_connect_run_new`] that has not been
/// freed, and no other reference to it may be live for the duration of the call.
#[expect(
    unsafe_code,
    reason = "turning the caller's handle back into a reference is this module's whole obligation"
)]
const unsafe fn held<'a>(handle: *mut SlopDeskConnectRun) -> Option<&'a mut SlopDeskConnectRun> {
    // SAFETY: by the caller's obligation this is a live, exclusively-held allocation from `new`.
    unsafe { handle.as_mut() }
}

/// A pane that has never dialled: no attempt, no latch.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_connect_run_new() -> *mut SlopDeskConnectRun {
    Box::into_raw(Box::new(SlopDeskConnectRun {
        inner: ConnectRun::new(),
    }))
}

/// Frees a connect ladder. Null is a no-op, and the same pointer must not be freed twice.
///
/// # Safety
/// `handle` must be null or a pointer from [`slopdesk_connect_run_new`], freed exactly once, with
/// no other reference to it live.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_connect_run_free(handle: *mut SlopDeskConnectRun) {
    if handle.is_null() {
        return;
    }
    // SAFETY: by the caller's obligation this pointer came from one `new` and is freed once.
    drop(unsafe { Box::from_raw(handle) });
}

/// Opens an EXPLICIT attempt, clears all three latches and answers the generation it must quote
/// after the handshake. A dead handle answers `0`, which is never current.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_connect_run_begin(handle: *mut SlopDeskConnectRun) -> u64 {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    unsafe { held(handle) }.map_or(0, |run| run.inner.begin())
}

/// Whether the attempt born under `generation` still owns this pane. A dead handle answers `false`.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_connect_run_is_current(
    handle: *mut SlopDeskConnectRun,
    generation: u64,
) -> bool {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    unsafe { held(handle) }.is_some_and(|run| run.inner.is_current(generation))
}

/// Latches a deliberate close. A dead handle latches nothing.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub const unsafe extern "C" fn slopdesk_connect_run_close_deliberately(handle: *mut SlopDeskConnectRun) {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    if let Some(run) = unsafe { held(handle) } {
        run.inner.close_deliberately();
    }
}

/// Retires every attempt in flight without saying the close was deliberate — the background unpin.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub const unsafe extern "C" fn slopdesk_connect_run_supersede(handle: *mut SlopDeskConnectRun) {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    if let Some(run) = unsafe { held(handle) } {
        run.inner.supersede();
    }
}

/// Clears the deliberate-close latch without opening an attempt — the video automation seam.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub const unsafe extern "C" fn slopdesk_connect_run_admit_without_dialling(handle: *mut SlopDeskConnectRun) {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    if let Some(run) = unsafe { held(handle) } {
        run.inner.admit_without_dialling();
    }
}

/// Latches what the host said on a `.disconnected` edge.
///
/// A `cause` outside the ladder reads as [`CLOSE_CAUSE_LINK`], which latches nothing.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub const unsafe extern "C" fn slopdesk_connect_run_note_host_close(
    handle: *mut SlopDeskConnectRun,
    cause: u8,
) {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    if let Some(run) = unsafe { held(handle) } {
        run.inner.note_host_close(CloseCause::from_tag(cause));
    }
}

/// Whether an AUTOMATIC dial path may proceed. A dead handle answers `false` — a pane with no
/// ladder is not one to dial into.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_connect_run_may_auto_dial(handle: *mut SlopDeskConnectRun) -> bool {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    unsafe { held(handle) }.is_some_and(|run| run.inner.may_auto_dial())
}

/// Whether a `.disconnected` edge is a definite disconnect rather than the start of a campaign.
/// A dead handle answers `true`: no campaign can follow a pane with no ladder.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_connect_run_disconnect_is_quiet(handle: *mut SlopDeskConnectRun) -> bool {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    unsafe { held(handle) }.is_none_or(|run| run.inner.disconnect_is_quiet())
}

/// Whether a `.reconnected` event may still be acted on. A dead handle answers `false`.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_connect_run_reconnect_is_welcome(handle: *mut SlopDeskConnectRun) -> bool {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    unsafe { held(handle) }.is_some_and(|run| run.inner.reconnect_is_welcome())
}

/// Whether the near side closed this pane on purpose, for the reconnect fold that takes it as an
/// input. A dead handle answers `true` — nothing should campaign for a pane with no ladder.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_connect_run_was_closed_deliberately(
    handle: *mut SlopDeskConnectRun,
) -> bool {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    unsafe { held(handle) }.is_none_or(|run| run.inner.was_closed_deliberately())
}

#[cfg(test)]
#[expect(unsafe_code, reason = "calling the door is the only way to test the door")]
mod tests {
    use super::{
        CLOSE_CAUSE_EVICTED, CLOSE_CAUSE_LINK, CLOSE_CAUSE_RETIRED, slopdesk_connect_run_begin,
        slopdesk_connect_run_close_deliberately, slopdesk_connect_run_disconnect_is_quiet,
        slopdesk_connect_run_free, slopdesk_connect_run_is_current, slopdesk_connect_run_may_auto_dial,
        slopdesk_connect_run_new, slopdesk_connect_run_note_host_close,
        slopdesk_connect_run_reconnect_is_welcome, slopdesk_connect_run_supersede,
        slopdesk_connect_run_was_closed_deliberately,
    };

    #[test]
    fn a_superseded_attempt_stops_owning_the_pane() {
        let run = slopdesk_connect_run_new();
        // SAFETY: `run` is the live handle `new` just returned, and nothing else holds it.
        unsafe {
            let first = slopdesk_connect_run_begin(run);
            assert!(slopdesk_connect_run_is_current(run, first));
            let second = slopdesk_connect_run_begin(run);
            assert!(!slopdesk_connect_run_is_current(run, first));
            assert!(slopdesk_connect_run_is_current(run, second));
            slopdesk_connect_run_free(run);
        }
    }

    #[test]
    fn the_two_host_closes_answer_the_automatic_paths_differently() {
        let reaped = slopdesk_connect_run_new();
        let evicted = slopdesk_connect_run_new();
        // SAFETY: both are live handles from `new`, each held by nobody else.
        unsafe {
            slopdesk_connect_run_begin(reaped);
            slopdesk_connect_run_note_host_close(reaped, CLOSE_CAUSE_RETIRED);
            assert!(!slopdesk_connect_run_may_auto_dial(reaped));
            assert!(slopdesk_connect_run_disconnect_is_quiet(reaped));

            slopdesk_connect_run_begin(evicted);
            slopdesk_connect_run_note_host_close(evicted, CLOSE_CAUSE_EVICTED);
            assert!(slopdesk_connect_run_may_auto_dial(evicted));
            assert!(slopdesk_connect_run_disconnect_is_quiet(evicted));

            slopdesk_connect_run_free(reaped);
            slopdesk_connect_run_free(evicted);
        }
    }

    #[test]
    fn a_dead_link_leaves_the_campaign_alone() {
        let run = slopdesk_connect_run_new();
        // SAFETY: `run` is the live handle `new` just returned, and nothing else holds it.
        unsafe {
            slopdesk_connect_run_begin(run);
            slopdesk_connect_run_note_host_close(run, CLOSE_CAUSE_LINK);
            assert!(slopdesk_connect_run_may_auto_dial(run));
            assert!(!slopdesk_connect_run_disconnect_is_quiet(run));
            slopdesk_connect_run_free(run);
        }
    }

    #[test]
    fn a_deliberate_close_refuses_a_buffered_reconnect() {
        let run = slopdesk_connect_run_new();
        // SAFETY: `run` is the live handle `new` just returned, and nothing else holds it.
        unsafe {
            slopdesk_connect_run_begin(run);
            slopdesk_connect_run_close_deliberately(run);
            assert!(!slopdesk_connect_run_reconnect_is_welcome(run));
            assert!(slopdesk_connect_run_was_closed_deliberately(run));
            slopdesk_connect_run_begin(run);
            assert!(slopdesk_connect_run_reconnect_is_welcome(run));
            slopdesk_connect_run_free(run);
        }
    }

    #[test]
    fn superseding_disowns_the_attempt_without_claiming_a_cancel() {
        let run = slopdesk_connect_run_new();
        // SAFETY: `run` is the live handle `new` just returned, and nothing else holds it.
        unsafe {
            let attempt = slopdesk_connect_run_begin(run);
            slopdesk_connect_run_supersede(run);
            assert!(!slopdesk_connect_run_is_current(run, attempt));
            assert!(!slopdesk_connect_run_was_closed_deliberately(run));
            slopdesk_connect_run_free(run);
        }
    }

    #[test]
    fn a_dead_handle_dials_nothing_and_campaigns_for_nothing() {
        // SAFETY: null is the one pointer `held` accepts without an allocation behind it.
        unsafe {
            assert_eq!(slopdesk_connect_run_begin(std::ptr::null_mut()), 0);
            assert!(!slopdesk_connect_run_is_current(std::ptr::null_mut(), 0));
            assert!(!slopdesk_connect_run_may_auto_dial(std::ptr::null_mut()));
            assert!(slopdesk_connect_run_disconnect_is_quiet(std::ptr::null_mut()));
            assert!(!slopdesk_connect_run_reconnect_is_welcome(std::ptr::null_mut()));
            assert!(slopdesk_connect_run_was_closed_deliberately(std::ptr::null_mut()));
            slopdesk_connect_run_free(std::ptr::null_mut());
        }
    }
}
