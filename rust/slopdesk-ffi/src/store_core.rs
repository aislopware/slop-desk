//! The workspace store's own decisions, in C.
//!
//! `slopdesk_workspace::store_core` owns the dial gate, the save-generation guard, the cache
//! provenance rule and the revision every projection of the document is keyed on. What is here is
//! the marshalling.
//!
//! ## Why this one is a HANDLE
//!
//! The same test [`crate::store_video_slots`] passes, for the same reason: state that outlives the
//! call, mutated from a dozen call sites, living exactly as long as the store does. `docs/55` §4b.
//!
//! ## The edges are RETURNED, not observed
//!
//! Every mutating door answers a small `#[repr(C)]` record of what the caller now owes the world —
//! cancel or arm the backstop timer, fan the re-dials out, write the file. The near side holds the
//! `Task`s and walks its own panes; it is never asked to decide whether to. That split is what
//! keeps the store's extensions reading as marshalling: the question "where is the decision?" has
//! one answer, and the answer is not on this side of the door.
//!
//! ## The near side's own facts are ARGUMENTS
//!
//! Three facts the gate needs live on objects the far side has never seen — a channel client, a
//! dictionary of automation variables, the mirror's pending set. They cross as
//! [`SlopDeskWsCoreInputs`] on every call rather than being pushed and remembered, because a
//! remembered copy of a fact whose owner is elsewhere goes stale between the write that moved it
//! and the call that pushes it.
//!
//! ## What did NOT cross
//!
//! A pane, a tab and a session are UUIDs the near side owns, and none of them appears here. The one
//! string that does is a `host:port`, which is a VALUE the store prints and persists rather than a
//! handle to anything.
//!
//! ## Serialisation is the caller's
//!
//! The mutating doors take `&mut` through the pointer, so two overlapping calls on one handle would
//! be aliasing UB. The Swift owner is `@MainActor` and every call site is main-actor-isolated — the
//! same guarantee these fields had when they were stored properties of that class.

use core::ffi::c_uchar;

use slopdesk_workspace::store_core::{Backstop, Channel, GateEdge, Inputs, WorkspaceCore};

use crate::{borrow, deliver};

/// One store's decisions, as an opaque handle.
#[derive(Debug)]
pub struct SlopDeskWsCore {
    /// The state the main actor serialises.
    inner: WorkspaceCore,
}

/// The near-side facts the gate cannot know on its own.
#[derive(Clone, Copy, Debug)]
#[repr(C)]
pub struct SlopDeskWsCoreInputs {
    /// What the workspace channel is: `0` none · `1` refused · `2` an in-process document · `3` a
    /// real host channel in any live state. Anything else reads as "no channel", the state under
    /// which a store waits for nothing — the conservative reading of a byte this side did not
    /// write.
    pub channel: c_uchar,
    /// Whether an automation bootstrap owns this launch's layout and publishes it itself.
    pub bootstrap_armed: bool,
    /// Whether this launch's `adoptWorkspace` proposal is still outstanding.
    pub offer_pending: bool,
}

/// What one gate recomputation asks the caller to do.
#[derive(Clone, Copy, Debug)]
#[repr(C)]
pub struct SlopDeskWsCoreGateEdge {
    /// Whether the published answer moved at all.
    pub changed: bool,
    /// The RELEASING edge: dial everything the hold was holding.
    pub opened: bool,
    /// `0` leave the backstop timer alone · `1` arm it · `2` cancel it.
    pub backstop: c_uchar,
}

/// What one folded document frame asks the caller to do, past the effects it already ran.
#[derive(Clone, Copy, Debug)]
#[repr(C)]
pub struct SlopDeskWsCoreFrameEdge {
    /// The gate recomputation this frame implied.
    pub gate: SlopDeskWsCoreGateEdge,
    /// Whether this frame stamped the attached host as the one vouching for the ids on screen.
    pub provenance_stamped: bool,
    /// Whether a booked re-dial fan-out came due.
    pub redial_booking_fired: bool,
}

/// Turns the caller's handle back into a reference.
///
/// # Safety
/// `handle` must be null or a live pointer from [`slopdesk_ws_core_new`] that has not been freed,
/// and no other reference to it may be live for the duration of the call.
#[expect(
    unsafe_code,
    reason = "turning the caller's handle back into a reference is this module's whole obligation"
)]
const unsafe fn held<'a>(handle: *mut SlopDeskWsCore) -> Option<&'a mut SlopDeskWsCore> {
    // SAFETY: by the caller's obligation this is a live, exclusively-held allocation from `new`.
    unsafe { handle.as_mut() }
}

/// The Rust shape of the near side's facts.
const fn inputs_of(inputs: SlopDeskWsCoreInputs) -> Inputs {
    Inputs {
        channel: match inputs.channel {
            1 => Channel::Refused,
            2 => Channel::LocalDocument,
            3 => Channel::Attached,
            _ => Channel::Absent,
        },
        bootstrap_armed: inputs.bootstrap_armed,
        offer_pending: inputs.offer_pending,
    }
}

/// The C shape of a gate edge.
const fn edge_of(edge: GateEdge) -> SlopDeskWsCoreGateEdge {
    SlopDeskWsCoreGateEdge {
        changed: edge.changed,
        opened: edge.opened,
        backstop: match edge.backstop {
            Backstop::Leave => 0,
            Backstop::Arm => 1,
            Backstop::Cancel => 2,
        },
    }
}

/// The edge a call on a null handle reads as: nothing moved and nothing is owed.
const fn quiet_edge() -> SlopDeskWsCoreGateEdge {
    SlopDeskWsCoreGateEdge {
        changed: false,
        opened: false,
        backstop: 0,
    }
}

/// A core for a store whose cache was seeded from the `host_key_len` bytes at `host_key` (empty for
/// the headless and test paths).
///
/// # Safety
/// `host_key` must be a readable run of `host_key_len` bytes, or null with `host_key_len` zero.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_ws_core_new(
    host_key: *const c_uchar,
    host_key_len: usize,
) -> *mut SlopDeskWsCore {
    // SAFETY: the caller's obligation above is `borrow`'s, restated.
    let bytes = unsafe { borrow(host_key, host_key_len) };
    let key = core::str::from_utf8(bytes).unwrap_or_default();
    Box::into_raw(Box::new(SlopDeskWsCore {
        inner: WorkspaceCore::new(key),
    }))
}

/// Frees a core. Null is a no-op, and the same pointer must not be freed twice.
///
/// # Safety
/// `handle` must be null or a pointer from [`slopdesk_ws_core_new`], freed exactly once.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_ws_core_free(handle: *mut SlopDeskWsCore) {
    if handle.is_null() {
        return;
    }
    // SAFETY: by the caller's obligation this pointer came from one `new` and is freed once.
    drop(unsafe { Box::from_raw(handle) });
}

/// The projection key as it stands.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_ws_core_revision(handle: *mut SlopDeskWsCore) -> u64 {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    unsafe { held(handle) }.map_or(0, |state| state.inner.revision())
}

/// Moves the projection key, answering its new value.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_ws_core_bump_revision(handle: *mut SlopDeskWsCore) -> u64 {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    unsafe { held(handle) }.map_or(0, |state| state.inner.bump_revision())
}

/// Whether the panes on screen may open their host channels.
///
/// A core-less client dials: a store with no handle is a store with no channel, which waits for
/// nothing.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_ws_core_panes_may_dial(handle: *mut SlopDeskWsCore) -> bool {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    unsafe { held(handle) }.is_none_or(|state| state.inner.panes_may_dial())
}

/// Recomputes the gate against `inputs` — the one door for every site that moves a near-side fact
/// without folding a frame.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_ws_core_refresh_dial_gate(
    handle: *mut SlopDeskWsCore,
    inputs: SlopDeskWsCoreInputs,
) -> SlopDeskWsCoreGateEdge {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    unsafe { held(handle) }.map_or_else(quiet_edge, |state| {
        edge_of(state.inner.refresh_dial_gate(inputs_of(inputs)))
    })
}

/// The backstop ran out with no answer of any kind, which opens the hold.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_ws_core_note_backstop_expired(
    handle: *mut SlopDeskWsCore,
    inputs: SlopDeskWsCoreInputs,
) -> SlopDeskWsCoreGateEdge {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    unsafe { held(handle) }.map_or_else(quiet_edge, |state| {
        edge_of(state.inner.note_backstop_expired(inputs_of(inputs)))
    })
}

/// A connect committed the `host_key_len` bytes at `host_key` as this run's target.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation, and `host_key` must be a readable run of
/// `host_key_len` bytes, or null with `host_key_len` zero.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_ws_core_commit_connection_target(
    handle: *mut SlopDeskWsCore,
    inputs: SlopDeskWsCoreInputs,
    host_key: *const c_uchar,
    host_key_len: usize,
) -> SlopDeskWsCoreGateEdge {
    // SAFETY: the caller's obligation above is `borrow`'s, restated.
    let bytes = unsafe { borrow(host_key, host_key_len) };
    let key = core::str::from_utf8(bytes).unwrap_or_default();
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    unsafe { held(handle) }.map_or_else(quiet_edge, |state| {
        edge_of(state.inner.commit_connection_target(inputs_of(inputs), key))
    })
}

/// Books the establish fan-out a second run, on the first document frame the attached host folds.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub const unsafe extern "C" fn slopdesk_ws_core_arm_redial_on_document(handle: *mut SlopDeskWsCore) {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    if let Some(state) = unsafe { held(handle) } {
        state.inner.arm_redial_on_document();
    }
}

/// A document frame folded: stamp the provenance if this is a new one, recompute the gate, and
/// answer whether the booked fan-out came due.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_ws_core_note_document_frame(
    handle: *mut SlopDeskWsCore,
    inputs: SlopDeskWsCoreInputs,
    frames_applied: u64,
    epoch_is_seed: bool,
) -> SlopDeskWsCoreFrameEdge {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    unsafe { held(handle) }.map_or(
        SlopDeskWsCoreFrameEdge {
            gate: quiet_edge(),
            provenance_stamped: false,
            redial_booking_fired: false,
        },
        |state| {
            let edge = state
                .inner
                .note_document_frame(inputs_of(inputs), frames_applied, epoch_is_seed);
            SlopDeskWsCoreFrameEdge {
                gate: edge_of(edge.gate),
                provenance_stamped: edge.provenance_stamped,
                redial_booking_fired: edge.redial_booking_fired,
            }
        },
    )
}

/// Whether the armed launch offer may go out now.
///
/// `known_epoch_is_seed` is the mirror's own reading: the seed IS the tree the offer carries, so
/// offering it back to a document that already adopted it would spend the host's one pristine
/// chance on a no-op.
///
/// A pure fold rather than a read off the handle — every input is the caller's, so asking for a
/// core would suggest the answer depended on stored state.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_ws_core_launch_offer_ready(
    inputs: SlopDeskWsCoreInputs,
    known_epoch_is_seed: bool,
    can_mutate: bool,
) -> bool {
    WorkspaceCore::launch_offer_ready(inputs_of(inputs), known_epoch_is_seed, can_mutate)
}

/// Arms the debounced write, after the construction reconcile.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub const unsafe extern "C" fn slopdesk_ws_core_enable_saving(handle: *mut SlopDeskWsCore) {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    if let Some(state) = unsafe { held(handle) } {
        state.inner.enable_saving();
    }
}

/// Claims a generation for a debounced write, writing it to `out` and answering `true`; answers
/// `false` and touches nothing while writes are disarmed.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation, and `out` must be null or a writable `uint64_t`.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub const unsafe extern "C" fn slopdesk_ws_core_begin_save(
    handle: *mut SlopDeskWsCore,
    out: *mut u64,
) -> bool {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    let Some(state) = (unsafe { held(handle) }) else {
        return false;
    };
    let Some(generation) = state.inner.begin_save() else {
        return false;
    };
    if !out.is_null() {
        // SAFETY: by the caller's obligation `out` is a writable `uint64_t`, checked non-null
        // above.
        unsafe { out.write(generation) };
    }
    true
}

/// Claims a generation for a write happening right now, whatever is in flight, and answers it.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_ws_core_supersede_save(handle: *mut SlopDeskWsCore) -> u64 {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    unsafe { held(handle) }.map_or(0, |state| state.inner.supersede_save())
}

/// Whether a captured generation is still the live one.
///
/// A core-less store never writes, so a generation it never issued is never current.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_ws_core_is_current_save_generation(
    handle: *mut SlopDeskWsCore,
    generation: u64,
) -> bool {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    unsafe { held(handle) }.is_some_and(|state| state.inner.is_current_save_generation(generation))
}

/// The live save generation, as a value. Zero for a core-less store, which never writes.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_ws_core_save_generation(handle: *mut SlopDeskWsCore) -> u64 {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    unsafe { held(handle) }.map_or(0, |state| state.inner.save_generation())
}

/// Whether debounced writes are armed at all — the guard the cache's own debounce shares.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_ws_core_saving_enabled(handle: *mut SlopDeskWsCore) -> bool {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    unsafe { held(handle) }.is_some_and(|state| state.inner.saving_enabled())
}

/// The `host:port` the cached picture is written under, as UTF-8. Answers the byte count NEEDED, so
/// an under-sized `cap` writes nothing and asks again; zero means the cache may not be written.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation, and `out` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_ws_core_cache_host_key(
    handle: *mut SlopDeskWsCore,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    let Some(state) = (unsafe { held(handle) }) else {
        return 0;
    };
    // SAFETY: by the caller's obligation `out` is writable for `cap` bytes.
    unsafe { deliver(state.inner.cache_host_key().as_bytes(), out, cap) }
}

#[cfg(test)]
#[expect(unsafe_code, reason = "calling the boundary IS what these tests are for")]
#[expect(
    clippy::indexing_slicing,
    reason = "every index here is into a buffer this module just filled"
)]
mod tests {
    use super::{
        SlopDeskWsCore, SlopDeskWsCoreInputs, slopdesk_ws_core_bump_revision,
        slopdesk_ws_core_cache_host_key, slopdesk_ws_core_commit_connection_target, slopdesk_ws_core_free,
        slopdesk_ws_core_is_current_save_generation, slopdesk_ws_core_new,
        slopdesk_ws_core_note_document_frame, slopdesk_ws_core_panes_may_dial,
    };

    /// The inputs of a store attached to a real host, with no offer out and no bootstrap.
    const ATTACHED: SlopDeskWsCoreInputs = SlopDeskWsCoreInputs {
        channel: 3,
        bootstrap_armed: false,
        offer_pending: false,
    };

    /// A core seeded from `key`, through the same door the near side calls.
    fn core(key: &str) -> *mut SlopDeskWsCore {
        // SAFETY: a live slice's pointer and length, which is `new`'s whole obligation.
        unsafe { slopdesk_ws_core_new(key.as_ptr(), key.len()) }
    }

    /// Commits `key` as the attached target, through the door.
    fn commit(handle: *mut SlopDeskWsCore, key: &str) {
        // SAFETY: `handle` is this test's own live core, and the slice is live for the call.
        unsafe { slopdesk_ws_core_commit_connection_target(handle, ATTACHED, key.as_ptr(), key.len()) };
    }

    #[test]
    fn a_null_core_dials_and_answers_nothing() {
        // SAFETY: null is the documented no-op for every door here.
        unsafe {
            assert!(slopdesk_ws_core_panes_may_dial(core::ptr::null_mut()));
            assert_eq!(slopdesk_ws_core_bump_revision(core::ptr::null_mut()), 0);
            assert!(!slopdesk_ws_core_is_current_save_generation(
                core::ptr::null_mut(),
                0
            ));
            slopdesk_ws_core_free(core::ptr::null_mut());
        }
    }

    #[test]
    fn the_gate_crosses_as_an_edge_the_caller_acts_on() {
        let handle = core("studio:7070");
        commit(handle, "studio:7070");
        // SAFETY: `handle` is this test's own live core for every call below.
        unsafe {
            assert!(
                !slopdesk_ws_core_panes_may_dial(handle),
                "no host has named these ids yet"
            );
            let edge = slopdesk_ws_core_note_document_frame(handle, ATTACHED, 1, false);
            assert!(edge.provenance_stamped);
            assert!(edge.gate.opened);
            assert_eq!(
                edge.gate.backstop, 2,
                "an answer arrived, so the timer is cancelled"
            );
            assert!(slopdesk_ws_core_panes_may_dial(handle));
            slopdesk_ws_core_free(handle);
        }
    }

    #[test]
    fn the_cache_key_is_delivered_with_a_guess() {
        let handle = core("studio:7070");
        let mut buffer = [0_u8; 64];
        // SAFETY: `handle` is this test's own live core, and `buffer` is writable for its length.
        let written = unsafe { slopdesk_ws_core_cache_host_key(handle, buffer.as_mut_ptr(), buffer.len()) };
        assert_eq!(&buffer[..written], b"studio:7070");
        commit(handle, "elsewhere:7070");
        // SAFETY: same core, same buffer.
        let after = unsafe { slopdesk_ws_core_cache_host_key(handle, buffer.as_mut_ptr(), buffer.len()) };
        assert_eq!(after, 0, "a mixed picture belongs to neither host");
        // SAFETY: freed exactly once, at the end of its one owner's scope.
        unsafe { slopdesk_ws_core_free(handle) };
    }
}
