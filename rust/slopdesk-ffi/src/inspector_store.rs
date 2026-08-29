//! The inspector CLIENT's store, as a handle.
//!
//! One store per pane, built when the pane's session is, fed one event body at a time. The
//! `inspector` module in this crate is the other end of the same feature: that one is the daemon's
//! FRAME, this one is the fold applied to what the frame delivered. The door prefixes are
//! `slopdesk_inspector_` and `slopdesk_inspector_store_` for exactly that reason.
//!
//! ## Why the STATE crossed, and not just the rules
//!
//! It used to be five doors answering one decision each — a ring's ceiling, a ring's overflow, the
//! empty-state gate, the agent tree — while the state they decided about sat in a Swift
//! `@Observable` class, along with a second declaration of the whole event taxonomy and a second
//! JSON decoder for it. Every read marshalled state ACROSS the boundary so a rule could be told
//! about it: the todo-scent door took the entire todo list, packed into length-prefixed fields, on
//! every read of a caption.
//!
//! Now the store holds its own values, so the arguments are gone: the tree walks a map of real
//! `String` ids instead of spans into a lent blob, the scent reads the list it already has, and the
//! caps are applied where the collections live rather than being vended one integer at a time. See
//! `docs/66`.
//!
//! ## What the doors answer
//!
//! Exactly what a surface reads. `docs/66` §3 measures that: the pending-tool line, the todo scent,
//! and the empty-state gate. The rest of the store — the timeline, the agent tree, the message log,
//! the unknown-line window — is reachable from `slopdesk-inspectord`'s own tests and has no reader
//! on this side, so it gets no door until a panel asks for one.

use core::ffi::c_uchar;

use slopdesk_inspectord::store::InspectorStore;

use crate::{borrow, deliver, push_text};

/// Turns the caller's handle back into a reference.
///
/// # Safety
/// `handle` must be null or a live pointer from [`slopdesk_inspector_store_new`] that has not been
/// freed, and no other reference to it may be live for the duration of the call.
#[expect(
    unsafe_code,
    reason = "turning the caller's handle back into a reference is this module's whole obligation"
)]
const unsafe fn held<'a>(handle: *mut InspectorStore) -> Option<&'a mut InspectorStore> {
    // SAFETY: by the caller's obligation this is a live, exclusively-held allocation from `new`.
    unsafe { handle.as_mut() }
}

/// Builds an empty store.
///
/// # Safety
/// Nothing is borrowed. The function is `unsafe` only because an exported C entry point is, in
/// edition 2024.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_inspector_store_new() -> *mut InspectorStore {
    Box::into_raw(Box::new(InspectorStore::new()))
}

/// Frees a store. Null is a no-op; anything else must come from exactly one
/// [`slopdesk_inspector_store_new`] and be freed exactly once.
///
/// # Safety
/// `handle` must be null, or a live pointer from [`slopdesk_inspector_store_new`] not yet freed,
/// with no other call on it in flight.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_inspector_store_free(handle: *mut InspectorStore) {
    if handle.is_null() {
        return;
    }
    // SAFETY: by the caller's obligation this came from one `new` and has not been freed.
    drop(unsafe { Box::from_raw(handle) });
}

/// Folds one event's JSON body in. `false` means the body did not decode and nothing changed.
///
/// A `false` is NOT an error the caller must act on: it is this wire's resilience contract, where a
/// future or corrupt event costs that event and never the session's feed.
///
/// # Safety
/// `handle` must be live per [`held`]; `(body, len)` must be null-with-zero-length or that many
/// readable bytes for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_inspector_store_apply(
    handle: *mut InspectorStore,
    body: *const c_uchar,
    len: usize,
) -> bool {
    // SAFETY: the caller's obligations are this function's.
    unsafe { held(handle).is_some_and(|store| store.apply(borrow(body, len))) }
}

/// Undoes what a replay from sequence zero would otherwise double.
///
/// Called on entry to each subscribe, because an iOS resume re-asks for the WHOLE history on the
/// same store. Deliberately not a clear — see `InspectorStore::reset`.
///
/// # Safety
/// `handle` must be live per [`held`].
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_inspector_store_reset(handle: *mut InspectorStore) {
    // SAFETY: the caller's obligation, above.
    unsafe {
        if let Some(store) = held(handle) {
            store.reset();
        }
    }
}

/// The counter a reader diffs against to learn that anything at all changed. `0` for a null handle.
///
/// # Safety
/// `handle` must be live per [`held`].
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_inspector_store_revision(handle: *mut InspectorStore) -> u64 {
    // SAFETY: the caller's obligation, above.
    unsafe { held(handle).map_or(0, |store| store.revision()) }
}

/// Whether anything user-visible has been folded in yet — the empty-state placeholder's gate.
///
/// # Safety
/// `handle` must be live per [`held`].
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_inspector_store_has_activity(handle: *mut InspectorStore) -> bool {
    // SAFETY: the caller's obligation, above.
    unsafe { held(handle).is_some_and(|store| store.has_renderable_activity()) }
}

/// The pending-tool line, as three length-prefixed fields.
///
/// The newest still-waiting card's NAME, its input SUMMARY and its full input DISPLAY, in
/// [`crate::push_text`]'s framing. `0` bytes when nothing is in flight.
///
/// Three fields rather than one joined string because each is drawn on its own: both peek overlays
/// render the name and the summary in two foreground weights on the collapsed row, and swap in the
/// display when that row is expanded. Splitting a combined string on the far side would be a second
/// place deciding where the splits fall. Zero is unambiguous as the refusal: a real answer carries
/// three four-byte prefixes, so it is never shorter than twelve bytes.
///
/// # Safety
/// `handle` must be live per [`held`]; `(out, cap)` must be null-with-zero-capacity or writable for
/// `cap` bytes for the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_inspector_store_pending_line(
    handle: *mut InspectorStore,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, above.
    let Some(store) = (unsafe { held(handle) }) else {
        return 0;
    };
    let Some(pending) = store.pending_card() else {
        return 0;
    };
    let mut blob = Vec::new();
    push_text(&mut blob, &pending.card.name);
    push_text(&mut blob, &pending.render.summary);
    push_text(&mut blob, &pending.render.display);
    // SAFETY: as above, for the out half.
    unsafe { deliver(&blob, out, cap) }
}

/// The `i/n · activeForm` line for the todos in flight, or `0` bytes when nothing is.
///
/// No argument beyond the handle: the todo list is the store's own, which is the whole difference
/// between this and the door it replaces.
///
/// Whether the caller may SHOW it is a separate question its own live-feed gate answers; this only
/// says whether there is one and what it reads.
///
/// # Safety
/// `handle` must be live per [`held`]; `(out, cap)` must be null-with-zero-capacity or writable for
/// `cap` bytes for the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_inspector_store_todo_scent(
    handle: *mut InspectorStore,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, above.
    let Some(scent) = (unsafe { held(handle) }).and_then(|store| store.todo_scent()) else {
        return 0;
    };
    // SAFETY: as above, for the out half.
    unsafe { deliver(scent.as_bytes(), out, cap) }
}

#[cfg(test)]
#[expect(
    unsafe_code,
    reason = "calling the boundary the way Swift does IS what these tests are for"
)]
mod tests {
    use core::ffi::c_uchar;

    use super::{
        slopdesk_inspector_store_apply, slopdesk_inspector_store_free, slopdesk_inspector_store_has_activity,
        slopdesk_inspector_store_new, slopdesk_inspector_store_pending_line, slopdesk_inspector_store_reset,
        slopdesk_inspector_store_revision, slopdesk_inspector_store_todo_scent,
    };

    /// One store for the body of a test, freed on the way out.
    fn with_store(body: impl FnOnce(*mut slopdesk_inspectord::store::InspectorStore)) {
        // SAFETY: `new` borrows nothing, and the handle is freed exactly once below.
        let handle = unsafe { slopdesk_inspector_store_new() };
        assert!(
            !handle.is_null(),
            "the store allocates or the process is out of memory"
        );
        body(handle);
        // SAFETY: the one handle from the one `new` above, not yet freed.
        unsafe { slopdesk_inspector_store_free(handle) };
    }

    /// Folds a body the way the Swift face does.
    fn apply(handle: *mut slopdesk_inspectord::store::InspectorStore, json: &str) -> bool {
        // SAFETY: the handle is live for the test, and the slice lives across the call.
        unsafe { slopdesk_inspector_store_apply(handle, json.as_ptr(), json.len()) }
    }

    /// A door's answer, read the way the Swift face reads one: probe for the size, then fill.
    fn read(
        handle: *mut slopdesk_inspectord::store::InspectorStore,
        door: unsafe extern "C" fn(
            *mut slopdesk_inspectord::store::InspectorStore,
            *mut c_uchar,
            usize,
        ) -> usize,
    ) -> Vec<u8> {
        // SAFETY: a null output with zero capacity is `docs/55` §4's documented length probe.
        let needed = unsafe { door(handle, core::ptr::null_mut(), 0) };
        if needed == 0 {
            return Vec::new();
        }
        let mut room = vec![0_u8; needed];
        // SAFETY: `room` is writable for exactly the `needed` bytes the probe named.
        let written = unsafe { door(handle, room.as_mut_ptr(), room.len()) };
        assert_eq!(
            written, needed,
            "a door sized its answer differently than it wrote it"
        );
        room
    }

    /// Cuts `push_text`'s framing back into its fields.
    fn fields(blob: &[u8]) -> Vec<String> {
        let mut answer = Vec::new();
        let mut cursor = 0;
        while cursor + 4 <= blob.len() {
            let mut length = 0_usize;
            for offset in 0..4 {
                length = length << 8 | usize::from(blob.get(cursor + offset).copied().unwrap_or_default());
            }
            cursor += 4;
            let Some(bytes) = blob.get(cursor..cursor + length) else {
                break;
            };
            answer.push(String::from_utf8_lossy(bytes).into_owned());
            cursor += length;
        }
        assert_eq!(cursor, blob.len(), "the framing cut evenly");
        answer
    }

    const PENDING_BASH: &str =
        r#"{"toolCard":{"_0":{"id":"b1","name":"Bash","input":{"command":"ls -la"},"status":"pending"}}}"#;

    #[test]
    fn a_null_handle_answers_the_empty_reading_rather_than_trapping() {
        let null = core::ptr::null_mut();
        // SAFETY: null is the documented no-op for every door here.
        unsafe {
            assert!(!slopdesk_inspector_store_apply(null, b"{}".as_ptr(), 2));
            assert_eq!(slopdesk_inspector_store_revision(null), 0);
            assert!(!slopdesk_inspector_store_has_activity(null));
            assert_eq!(
                slopdesk_inspector_store_pending_line(null, core::ptr::null_mut(), 0),
                0
            );
            assert_eq!(
                slopdesk_inspector_store_todo_scent(null, core::ptr::null_mut(), 0),
                0
            );
            // Freeing null is the documented no-op, and the reason a Swift `deinit` needs no guard.
            slopdesk_inspector_store_free(null);
        }
    }

    #[test]
    fn a_fresh_store_reads_empty_and_one_event_moves_every_reading() {
        with_store(|handle| {
            assert_eq!(
                read(handle, slopdesk_inspector_store_pending_line),
                Vec::<u8>::new()
            );
            // SAFETY: the handle is live for the closure.
            unsafe {
                assert!(!slopdesk_inspector_store_has_activity(handle));
                assert_eq!(slopdesk_inspector_store_revision(handle), 0);
            }

            assert!(apply(handle, PENDING_BASH));
            // SAFETY: as above.
            unsafe {
                assert!(slopdesk_inspector_store_has_activity(handle));
                assert_eq!(slopdesk_inspector_store_revision(handle), 1);
            }
            assert_eq!(fields(&read(handle, slopdesk_inspector_store_pending_line)), [
                "Bash".to_owned(),
                "ls -la".to_owned(),
                "command: ls -la".to_owned()
            ]);
        });
    }

    #[test]
    fn a_body_that_does_not_decode_folds_nothing_and_says_so() {
        with_store(|handle| {
            assert!(!apply(handle, "{not json"));
            // SAFETY: the handle is live for the closure.
            unsafe {
                assert_eq!(slopdesk_inspector_store_revision(handle), 0);
                assert!(!slopdesk_inspector_store_has_activity(handle));
            }
        });
    }

    #[test]
    fn the_scent_reads_off_the_store_with_no_list_lent_to_it() {
        with_store(|handle| {
            assert_eq!(
                read(handle, slopdesk_inspector_store_todo_scent),
                Vec::<u8>::new()
            );
            assert!(apply(
                handle,
                r#"{"todosUpdated":{"_0":[
                    {"content":"first","status":"completed"},
                    {"content":"second","status":"in_progress","activeForm":"doing the second"}
                ]}}"#,
            ));
            assert_eq!(
                String::from_utf8_lossy(&read(handle, slopdesk_inspector_store_todo_scent)),
                "2/2 · doing the second",
            );
        });
    }

    #[test]
    fn a_short_lend_writes_nothing_and_reports_what_it_needed() {
        with_store(|handle| {
            assert!(apply(handle, PENDING_BASH));
            let mut room = [0_u8; 4];
            // SAFETY: the handle is live and `room` is deliberately too small.
            let needed =
                unsafe { slopdesk_inspector_store_pending_line(handle, room.as_mut_ptr(), room.len()) };
            assert!(needed > room.len(), "a short lend is told what to lend");
            assert_eq!(room, [0; 4], "and nothing was written");
        });
    }

    #[test]
    fn a_reset_clears_the_accumulators_and_keeps_the_cards() {
        with_store(|handle| {
            assert!(apply(handle, PENDING_BASH));
            assert!(apply(handle, r#"{"unknownLine":{"raw":"x"}}"#));
            // SAFETY: the handle is live for the closure.
            let before = unsafe { slopdesk_inspector_store_revision(handle) };
            // SAFETY: as above.
            unsafe { slopdesk_inspector_store_reset(handle) };
            // SAFETY: as above.
            unsafe {
                assert!(
                    slopdesk_inspector_store_revision(handle) > before,
                    "a reset is a change a reader must see",
                );
                assert!(
                    slopdesk_inspector_store_has_activity(handle),
                    "the card survived, so the panel still has something to draw",
                );
            }
            assert_eq!(fields(&read(handle, slopdesk_inspector_store_pending_line)), [
                "Bash".to_owned(),
                "ls -la".to_owned(),
                "command: ls -la".to_owned()
            ]);
        });
    }
}
