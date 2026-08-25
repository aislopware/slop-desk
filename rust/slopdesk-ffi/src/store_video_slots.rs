//! The concurrent-live-video ledger of docs/22 §7, in C.
//!
//! `slopdesk_workspace::store_video_slots` owns the cap, the two sets and the promotion nudge. What
//! is here is the marshalling.
//!
//! ## Why this one is a HANDLE
//!
//! Every other `store_*` door in this crate is a fold: a column of facts in, one verdict out. This
//! one is state that outlives the call — who is decoding, who is still letting go, and a counter
//! that only moves on the transitions that free something — mutated from four call sites and living
//! as long as the store. That is `docs/55` §4b's test, and [`crate::mux_resize`] set the shape.
//!
//! ## What did NOT cross
//!
//! The pane. Every entry point takes a `uint32_t` token the near side minted for a `PaneID`; the
//! UUID stays where it is, and the ledger's only claim about a token is that two equal tokens name
//! the same pane. Nor did the decoder: whether a pane IS a video pane and whether it is decoding
//! right now are readings off a live object, so they are arguments here rather than questions.
//!
//! ## Serialisation is the caller's
//!
//! The mutating doors take `&mut` through the pointer, so two overlapping calls on one handle would
//! be aliasing UB. The Swift owner is `@MainActor` and every call site is main-actor-isolated — the
//! same guarantee the store's stored properties had when this state was three of them.

use core::ffi::c_uchar;

use slopdesk_workspace::store_video_slots::{Admission, SlotToken, VideoSlots};

/// One client's live-video ledger, as an opaque handle.
#[derive(Debug)]
pub struct SlopDeskWsVideoSlots {
    /// The state the main actor serialises.
    inner: VideoSlots,
}

/// Turns the caller's handle back into a reference.
///
/// # Safety
/// `handle` must be null or a live pointer from [`slopdesk_ws_video_slots_new`] that has not been
/// freed, and no other reference to it may be live for the duration of the call.
#[expect(
    unsafe_code,
    reason = "turning the caller's handle back into a reference is this module's whole obligation"
)]
const unsafe fn held<'a>(handle: *mut SlopDeskWsVideoSlots) -> Option<&'a mut SlopDeskWsVideoSlots> {
    // SAFETY: by the caller's obligation this is a live, exclusively-held allocation from `new`.
    unsafe { handle.as_mut() }
}

/// The verdict byte: `0` refuse · `1` already decoding · `2` a slot is free.
///
/// A refusal is the conservative answer, which is why it is also what a null handle reads as: a
/// client with no ledger admits nothing rather than admitting everything.
const fn verdict_of(admission: Admission) -> c_uchar {
    match admission {
        Admission::Refuse => 0,
        Admission::AlreadyLive => 1,
        Admission::Proceed => 2,
    }
}

/// A ledger with a ceiling of `cap` concurrent live video panes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_ws_video_slots_new(cap: usize) -> *mut SlopDeskWsVideoSlots {
    Box::into_raw(Box::new(SlopDeskWsVideoSlots {
        inner: VideoSlots::new(cap),
    }))
}

/// Frees a ledger. Null is a no-op, and the same pointer must not be freed twice.
///
/// # Safety
/// `handle` must be null or a pointer from [`slopdesk_ws_video_slots_new`], freed exactly once.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_ws_video_slots_free(handle: *mut SlopDeskWsVideoSlots) {
    if handle.is_null() {
        return;
    }
    // SAFETY: by the caller's obligation this pointer came from one `new` and is freed once.
    drop(unsafe { Box::from_raw(handle) });
}

/// The verdict on a request to make `token`'s pane decode: `0` refuse · `1` already decoding ·
/// `2` a slot is free, go ahead and report back.
///
/// `is_video` and `already_live` are the caller's readings off the pane it holds.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_ws_video_slots_admit(
    handle: *mut SlopDeskWsVideoSlots,
    token: SlotToken,
    is_video: bool,
    already_live: bool,
) -> c_uchar {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    unsafe { held(handle) }.map_or(0, |state| {
        verdict_of(state.inner.admit(token, is_video, already_live))
    })
}

/// Whether a slot is free FOR `token` right now — the pure read, with no mutation.
///
/// Self-excluding and releasing-aware, so it agrees with what an admission this same tick would
/// decide. This is what tells a gated pane's two reasons apart: the cap is full, versus the pane is
/// simply not dialled in yet.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_ws_video_slots_admits(
    handle: *mut SlopDeskWsVideoSlots,
    token: SlotToken,
) -> bool {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    unsafe { held(handle) }.is_some_and(|state| state.inner.admits(token))
}

/// Records what `token`'s pane ACTUALLY is after something flipped it — the confirm-read after an
/// activation, and the resync after a pause or resume flipped the flag behind the store's back.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_ws_video_slots_note_live(
    handle: *mut SlopDeskWsVideoSlots,
    token: SlotToken,
    live: bool,
) {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    let Some(state) = (unsafe { held(handle) }) else {
        return;
    };
    state.inner.note_live(token, live);
}

/// `token`'s pane stops decoding while staying open, answering the promotion generation to publish.
///
/// `was_live` is the caller's reading from BEFORE it stood the pane down, and it is what keeps a
/// no-op stand-down from churning every gated sibling.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_ws_video_slots_stand_down(
    handle: *mut SlopDeskWsVideoSlots,
    token: SlotToken,
    was_live: bool,
) -> i64 {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    unsafe { held(handle) }.map_or(0, |state| state.inner.stand_down(token, was_live))
}

/// `token`'s pane CLOSED, answering the promotion generation to publish.
///
/// `holds_stack` is the caller's reading, taken before teardown nils it, of whether the pane was a
/// video pane that was actually decoding — the one that keeps its slot booked until the hardware is
/// really let go.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_ws_video_slots_orphan(
    handle: *mut SlopDeskWsVideoSlots,
    token: SlotToken,
    holds_stack: bool,
) -> i64 {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    unsafe { held(handle) }.map_or(0, |state| state.inner.orphan(token, holds_stack))
}

/// Whether `token`'s decode stack is still letting go — the guard on the caller's settle sleep.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_ws_video_slots_is_releasing(
    handle: *mut SlopDeskWsVideoSlots,
    token: SlotToken,
) -> bool {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    unsafe { held(handle) }.is_some_and(|state| state.inner.is_releasing(token))
}

/// `token`'s decode stack is released, answering the promotion generation to publish. A token that
/// was not booked freed nothing, and the generation does not move.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_ws_video_slots_release(
    handle: *mut SlopDeskWsVideoSlots,
    token: SlotToken,
) -> i64 {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    unsafe { held(handle) }.map_or(0, |state| state.inner.release(token))
}

/// Forgets every releasing token, for a caller that has drained every teardown it spawned. Silent:
/// a repair does not announce a slot as newly free.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_ws_video_slots_clear_releasing(handle: *mut SlopDeskWsVideoSlots) {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    let Some(state) = (unsafe { held(handle) }) else {
        return;
    };
    state.inner.clear_releasing();
}

/// The promotion generation as it stands, for the caller's first projection at construction.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_ws_video_slots_generation(handle: *mut SlopDeskWsVideoSlots) -> i64 {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    unsafe { held(handle) }.map_or(0, |state| state.inner.generation())
}

#[cfg(test)]
mod tests {
    #![expect(unsafe_code, reason = "calling the door is the only way to test the door")]

    use super::{
        SlopDeskWsVideoSlots, slopdesk_ws_video_slots_admit, slopdesk_ws_video_slots_admits,
        slopdesk_ws_video_slots_clear_releasing, slopdesk_ws_video_slots_free,
        slopdesk_ws_video_slots_generation, slopdesk_ws_video_slots_is_releasing,
        slopdesk_ws_video_slots_new, slopdesk_ws_video_slots_note_live, slopdesk_ws_video_slots_orphan,
        slopdesk_ws_video_slots_release, slopdesk_ws_video_slots_stand_down,
    };

    /// The whole admission ladder, crossed: two panes take both slots, a third is refused, one
    /// stands down and nudges, and the third is then admitted.
    #[test]
    fn the_ceiling_and_the_nudge_cross_together() {
        let handle = slopdesk_ws_video_slots_new(2);
        // SAFETY: `handle` came from `new` above and is exclusively held by this test.
        unsafe {
            assert_eq!(slopdesk_ws_video_slots_admit(handle, 0, true, false), 2);
            slopdesk_ws_video_slots_note_live(handle, 0, true);
            assert_eq!(slopdesk_ws_video_slots_admit(handle, 1, true, false), 2);
            slopdesk_ws_video_slots_note_live(handle, 1, true);

            assert_eq!(slopdesk_ws_video_slots_admit(handle, 2, true, false), 0);
            assert!(!slopdesk_ws_video_slots_admits(handle, 2));
            assert!(slopdesk_ws_video_slots_admits(handle, 0), "its own slot is free");
            assert_eq!(slopdesk_ws_video_slots_admit(handle, 0, true, true), 1);

            assert_eq!(slopdesk_ws_video_slots_stand_down(handle, 0, true), 1);
            assert_eq!(slopdesk_ws_video_slots_admit(handle, 2, true, false), 2);
            slopdesk_ws_video_slots_free(handle);
        }
    }

    /// A no-op stand-down and a non-video request leave the generation where it was.
    #[test]
    fn nothing_that_freed_nothing_moves_the_generation() {
        let handle = slopdesk_ws_video_slots_new(2);
        // SAFETY: `handle` came from `new` above and is exclusively held by this test.
        unsafe {
            assert_eq!(slopdesk_ws_video_slots_admit(handle, 0, false, false), 0);
            assert_eq!(slopdesk_ws_video_slots_stand_down(handle, 0, false), 0);
            assert_eq!(slopdesk_ws_video_slots_generation(handle), 0);
            slopdesk_ws_video_slots_free(handle);
        }
    }

    /// A closed decoding pane keeps its slot until the release, and nudges at both ends.
    #[test]
    fn a_closed_stack_holds_its_slot_across_the_settle() {
        let handle = slopdesk_ws_video_slots_new(1);
        // SAFETY: `handle` came from `new` above and is exclusively held by this test.
        unsafe {
            slopdesk_ws_video_slots_note_live(handle, 0, true);
            assert_eq!(slopdesk_ws_video_slots_orphan(handle, 0, true), 1);
            assert!(slopdesk_ws_video_slots_is_releasing(handle, 0));
            assert!(
                !slopdesk_ws_video_slots_admits(handle, 5),
                "the stack still counts"
            );
            assert_eq!(slopdesk_ws_video_slots_release(handle, 0), 2);
            assert!(slopdesk_ws_video_slots_admits(handle, 5));
            assert_eq!(slopdesk_ws_video_slots_release(handle, 0), 2, "already released");
            slopdesk_ws_video_slots_free(handle);
        }
    }

    /// The drain repair frees every held slot without announcing one.
    #[test]
    fn the_drain_repair_crosses_silently() {
        let handle = slopdesk_ws_video_slots_new(2);
        // SAFETY: `handle` came from `new` above and is exclusively held by this test.
        unsafe {
            slopdesk_ws_video_slots_note_live(handle, 0, true);
            slopdesk_ws_video_slots_orphan(handle, 0, true);
            let after_close = slopdesk_ws_video_slots_generation(handle);
            slopdesk_ws_video_slots_clear_releasing(handle);
            assert!(!slopdesk_ws_video_slots_is_releasing(handle, 0));
            assert_eq!(slopdesk_ws_video_slots_generation(handle), after_close);
            slopdesk_ws_video_slots_free(handle);
        }
    }

    /// A null handle is inert at every entry point, and admits NOTHING — the conservative reading.
    #[test]
    fn a_null_handle_is_inert() {
        let null: *mut SlopDeskWsVideoSlots = core::ptr::null_mut();
        // SAFETY: a null handle is the documented inert case at every entry point.
        unsafe {
            assert_eq!(slopdesk_ws_video_slots_admit(null, 0, true, false), 0);
            assert!(!slopdesk_ws_video_slots_admits(null, 0));
            slopdesk_ws_video_slots_note_live(null, 0, true);
            assert_eq!(slopdesk_ws_video_slots_stand_down(null, 0, true), 0);
            assert_eq!(slopdesk_ws_video_slots_orphan(null, 0, true), 0);
            assert!(!slopdesk_ws_video_slots_is_releasing(null, 0));
            assert_eq!(slopdesk_ws_video_slots_release(null, 0), 0);
            slopdesk_ws_video_slots_clear_releasing(null);
            assert_eq!(slopdesk_ws_video_slots_generation(null), 0);
            slopdesk_ws_video_slots_free(null);
        }
    }

    /// Many ledgers created, filled and destroyed. One `free` per `new`, nothing left behind — the
    /// obligation a handle carries that a by-value door does not.
    #[test]
    fn every_ledger_is_freed_exactly_once() {
        for round in 0..2_000_u32 {
            let handle = slopdesk_ws_video_slots_new(2);
            // SAFETY: `handle` came from `new` on this iteration and is freed once below.
            unsafe {
                slopdesk_ws_video_slots_note_live(handle, round, true);
                slopdesk_ws_video_slots_note_live(handle, round.wrapping_add(1), true);
                slopdesk_ws_video_slots_orphan(handle, round, true);
                slopdesk_ws_video_slots_free(handle);
            }
        }
    }
}
