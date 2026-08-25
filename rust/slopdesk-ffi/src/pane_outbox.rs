//! One pane's outbound frame queue: what coalesces, where an over-cap head splits, and that `.exit`
//! is a barrier — docs/59 step 2.
//!
//! `rust/slopdesk-muxsession`'s `outbox` owns the order. This is the door.
//!
//! ## Why this one is a HANDLE and [`crate::mux_flow`] is not
//! The same test [`crate::mux_resize`] answers: a flow policy is two `i64`s that fit in the call,
//! and this is a queue that lives as long as the pane, mutated from the read-loop thread, the exit
//! task and the drain under one `NSLock`.
//!
//! ## What did NOT cross
//! Every byte. The queue holds `(slot, len)`; hostd holds the `Data` each slot names and does the
//! concatenation where that `Data` already is. A door that took the chunk would pay a `Data`
//! allocation per 32 KiB read — docs/55 §4c prices that at 227.5 ns against a crossing's 1.0, per
//! chunk, forever. So does the wake: every entry point answers what the queue now holds, and the
//! `AsyncStream` continuation, the drain `Task` and the pause sink stay in hostd.
//!
//! ## Where the cap comes from
//! Here, not the caller. `max_output_frame_payload_bytes` is `slopdesk-wire`'s — the PROTOCOL's
//! number, which `slopdesk-muxsession` deliberately does not depend on — so the fold takes it as an
//! argument and this door reads it fresh per pop, exactly as the Swift original re-read the
//! computed `MuxFlowControl.maxOutputFramePayloadBytes`. That keeps it spelled once and keeps
//! `SLOPDESK_MUX_WINDOW`/`SLOPDESK_MUX_MERGE_CAP` live without a constant crossing.

use slopdesk_muxsession::outbox::{Frame, Outbox};
use slopdesk_wire::mux::MuxFlowControl;

/// [`SlopDeskOutboxFrame::kind`] for a queue with nothing waiting.
pub const SLOPDESK_OUTBOX_EMPTY: u8 = 0;
/// [`SlopDeskOutboxFrame::kind`] for a data frame.
pub const SLOPDESK_OUTBOX_OUTPUT: u8 = 1;
/// [`SlopDeskOutboxFrame::kind`] for the exit barrier.
pub const SLOPDESK_OUTBOX_EXIT: u8 = 2;

/// What one [`slopdesk_pane_outbox_take`] asks the caller to ship.
#[repr(C)]
#[derive(Debug, Clone, Copy, Default)]
pub struct SlopDeskOutboxFrame {
    /// The first slot of the run to concatenate.
    pub first_slot: u64,
    /// How many CONSECUTIVE slots the run covers: `first_slot ..< first_slot + slots`. The run is
    /// consecutive because the exit barrier takes no slot, which is why no counted buffer is needed
    /// to name it.
    pub slots: u64,
    /// Payload bytes this frame ships — what the bounded-queue gate dequeues once it is sent.
    pub byte_count: u64,
    /// The reaped status, for [`SLOPDESK_OUTBOX_EXIT`].
    pub exit_code: i32,
    /// One of [`SLOPDESK_OUTBOX_EMPTY`], [`SLOPDESK_OUTBOX_OUTPUT`], [`SLOPDESK_OUTBOX_EXIT`].
    pub kind: u8,
    /// Whether the head slot was SPLIT rather than consumed: `slots` is 1, `byte_count` bytes of it
    /// ship now, and it stays queued holding the remainder. The caller keeps the slot, drops the
    /// shipped prefix from its payload, and clears its control — that control rides the prefix.
    pub split: bool,
}

/// One pane's outbound queue, as an opaque handle.
#[derive(Debug)]
pub struct SlopDeskPaneOutbox {
    /// The state the caller's `fifoLock` guards.
    inner: Outbox,
}

/// Turns the caller's handle back into a reference.
///
/// # Safety
/// `handle` must be null or a live pointer from [`slopdesk_pane_outbox_new`] that has not been
/// freed, and no other reference to it may be live for the duration of the call.
#[expect(
    unsafe_code,
    reason = "turning the caller's handle back into a reference is this module's whole obligation"
)]
const unsafe fn held<'a>(handle: *mut SlopDeskPaneOutbox) -> Option<&'a mut SlopDeskPaneOutbox> {
    // SAFETY: by the caller's obligation this is a live, exclusively-held allocation from `new`.
    unsafe { handle.as_mut() }
}

/// An empty queue for a fresh pane session.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_pane_outbox_new() -> *mut SlopDeskPaneOutbox {
    Box::into_raw(Box::new(SlopDeskPaneOutbox { inner: Outbox::new() }))
}

/// Frees a queue. Null is a no-op, and the same pointer must not be freed twice.
///
/// # Safety
/// `handle` must be null or a pointer from [`slopdesk_pane_outbox_new`], freed exactly once.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_pane_outbox_free(handle: *mut SlopDeskPaneOutbox) {
    if handle.is_null() {
        return;
    }
    // SAFETY: by the caller's obligation this pointer came from one `new` and is freed once.
    drop(unsafe { Box::from_raw(handle) });
}

/// Enqueues `len` bytes and answers the SLOT the caller must store them under.
///
/// The slot is minted here so the run a frame names stays consecutive; the payload never crosses.
/// A dead handle answers zero, which the caller will simply overwrite on the next append — the
/// queue that would have shipped it does not exist either.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_pane_outbox_append_chunk(handle: *mut SlopDeskPaneOutbox, len: u64) -> u64 {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    let Some(state) = (unsafe { held(handle) }) else {
        return 0;
    };
    state
        .inner
        .append_chunk(usize::try_from(len).unwrap_or(usize::MAX))
}

/// Enqueues the exit barrier. It takes no slot and never coalesces with a chunk.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_pane_outbox_append_exit(handle: *mut SlopDeskPaneOutbox, code: i32) {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    if let Some(state) = unsafe { held(handle) } {
        state.inner.append_exit(code);
    }
}

/// Whether anything is waiting — the "carried frames" question a restarted drain asks before
/// deciding whether the rebind owes it a kick.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_pane_outbox_is_empty(handle: *mut SlopDeskPaneOutbox) -> bool {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    (unsafe { held(handle) }).is_none_or(|state| state.inner.is_empty())
}

/// Pops the next frame, coalescing up to the credit-safe payload cap.
///
/// `out` is written on every call, including the empty one — a caller that reads `kind` first never
/// sees stale fields.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation, and `out` must be a writable
/// [`SlopDeskOutboxFrame`].
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_pane_outbox_take(
    handle: *mut SlopDeskPaneOutbox,
    out: *mut SlopDeskOutboxFrame,
) {
    let Some(slot) = (
        // SAFETY: by the caller's obligation `out` is a writable frame for the call.
        unsafe { out.as_mut() }
    ) else {
        return;
    };
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    let taken = (unsafe { held(handle) }).and_then(|state| state.inner.take(cap()));
    *slot = match taken {
        None => SlopDeskOutboxFrame::default(),
        Some(Frame::Output {
            first_slot,
            slots,
            byte_count,
            split,
        }) => {
            SlopDeskOutboxFrame {
                kind: SLOPDESK_OUTBOX_OUTPUT,
                split,
                exit_code: 0,
                first_slot,
                slots: wide(slots),
                byte_count: wide(byte_count),
            }
        },
        Some(Frame::Exit { code }) => {
            SlopDeskOutboxFrame {
                kind: SLOPDESK_OUTBOX_EXIT,
                split: false,
                exit_code: code,
                first_slot: 0,
                slots: 0,
                byte_count: 0,
            }
        },
    };
}

/// A count on its way out. `usize` is 64 bits on every target this ships to, so the widening is
/// exact — `try_from` keeps that a fact the compiler checks rather than a comment, and saturates
/// rather than wrapping if it ever stopped being one, because a wrapped length would name a run the
/// caller does not hold.
fn wide(count: usize) -> u64 {
    u64::try_from(count).unwrap_or(u64::MAX)
}

/// The credit-safe payload cap, read fresh per pop so the env seams stay live.
fn cap() -> usize {
    usize::try_from(MuxFlowControl::max_output_frame_payload_bytes()).unwrap_or(0)
}

#[cfg(test)]
mod tests {
    #![expect(unsafe_code, reason = "calling the door is the only way to test the door")]

    use super::{
        SLOPDESK_OUTBOX_EMPTY, SLOPDESK_OUTBOX_EXIT, SLOPDESK_OUTBOX_OUTPUT, SlopDeskOutboxFrame,
        slopdesk_pane_outbox_append_chunk, slopdesk_pane_outbox_append_exit, slopdesk_pane_outbox_free,
        slopdesk_pane_outbox_is_empty, slopdesk_pane_outbox_new, slopdesk_pane_outbox_take,
    };

    /// One pop through the door.
    fn take(handle: *mut super::SlopDeskPaneOutbox) -> SlopDeskOutboxFrame {
        let mut out = SlopDeskOutboxFrame::default();
        // SAFETY: `handle` is live for the test and `out` is a local.
        unsafe { slopdesk_pane_outbox_take(handle, &raw mut out) };
        out
    }

    #[test]
    fn an_empty_queue_answers_the_empty_kind() {
        let handle = slopdesk_pane_outbox_new();
        // SAFETY: a live handle from `new`.
        assert!(unsafe { slopdesk_pane_outbox_is_empty(handle) });
        assert_eq!(take(handle).kind, SLOPDESK_OUTBOX_EMPTY);
        // SAFETY: freed exactly once.
        unsafe { slopdesk_pane_outbox_free(handle) };
    }

    #[test]
    fn chunks_coalesce_into_one_consecutive_run() {
        let handle = slopdesk_pane_outbox_new();
        // SAFETY: a live handle from `new`, for every call below.
        unsafe {
            assert_eq!(slopdesk_pane_outbox_append_chunk(handle, 3), 0);
            assert_eq!(slopdesk_pane_outbox_append_chunk(handle, 5), 1);
        }
        let frame = take(handle);
        assert_eq!(frame.kind, SLOPDESK_OUTBOX_OUTPUT);
        assert!(!frame.split);
        assert_eq!((frame.first_slot, frame.slots, frame.byte_count), (0, 2, 8));
        // SAFETY: a live handle; freed exactly once.
        unsafe {
            assert!(slopdesk_pane_outbox_is_empty(handle));
            slopdesk_pane_outbox_free(handle);
        }
    }

    #[test]
    fn the_barrier_pops_alone() {
        let handle = slopdesk_pane_outbox_new();
        // SAFETY: a live handle from `new`.
        unsafe {
            slopdesk_pane_outbox_append_chunk(handle, 4);
            slopdesk_pane_outbox_append_exit(handle, 7);
        }
        assert_eq!(take(handle).kind, SLOPDESK_OUTBOX_OUTPUT);
        let exit = take(handle);
        assert_eq!(exit.kind, SLOPDESK_OUTBOX_EXIT);
        assert_eq!(exit.exit_code, 7);
        // SAFETY: freed exactly once.
        unsafe { slopdesk_pane_outbox_free(handle) };
    }

    #[test]
    fn an_over_cap_head_reports_the_split_and_keeps_its_slot() {
        let handle = slopdesk_pane_outbox_new();
        let cap = super::wide(super::cap());
        // SAFETY: a live handle from `new`.
        let slot = unsafe { slopdesk_pane_outbox_append_chunk(handle, cap + 9) };
        let first = take(handle);
        assert!(first.split);
        assert_eq!((first.first_slot, first.slots, first.byte_count), (slot, 1, cap));
        let tail = take(handle);
        assert!(!tail.split);
        assert_eq!((tail.first_slot, tail.byte_count), (slot, 9));
        // SAFETY: freed exactly once.
        unsafe { slopdesk_pane_outbox_free(handle) };
    }

    #[test]
    fn a_null_handle_is_inert_rather_than_a_crash() {
        assert_eq!(take(std::ptr::null_mut()).kind, SLOPDESK_OUTBOX_EMPTY);
        // SAFETY: null is the documented no-op for each of these.
        unsafe {
            assert_eq!(slopdesk_pane_outbox_append_chunk(std::ptr::null_mut(), 4), 0);
            slopdesk_pane_outbox_append_exit(std::ptr::null_mut(), 1);
            assert!(slopdesk_pane_outbox_is_empty(std::ptr::null_mut()));
            slopdesk_pane_outbox_free(std::ptr::null_mut());
        }
    }
}
