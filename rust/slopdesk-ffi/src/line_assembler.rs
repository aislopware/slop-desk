//! A service's PTY stream, back into lines, in C.
//!
//! The rule is `slopdesk_sidecars::line_assembler`. This is the handle convention rather than the
//! pure one, for the reason [`crate::replay`] states at length and this shares: the type IS the
//! memory. It holds the residue of a line that has not finished arriving, across as many `read`
//! calls as it takes, and passing that residue back and forth per chunk would copy it twice on
//! every wake of a daemon whose whole job is to be quiet.
//!
//! ## The handle convention, as it applies here
//! - [`slopdesk_line_assembler_new`] returns an opaque pointer, or null if it cannot allocate.
//! - Exactly one [`slopdesk_line_assembler_free`] per `new`; null is inert.
//! - **No two calls on one handle may overlap.** `append` takes `&mut` from the pointer, so a
//!   concurrent call is aliasing UB. The near side serialises under the lock the Swift class it
//!   replaces already held — the stream callback that drives it is not the only thread in that
//!   process.
//! - The lines produced by an `append` are held BY THE HANDLE and read out one at a time under the
//!   ordinary `(out, cap) -> needed` convention. Nothing is allocated on one side and freed on the
//!   other.
//!
//! ## Why the lines come out one at a time rather than flattened
//!
//! An adopt replays a service's whole retained ring through here in one call — the announce line is
//! the first thing the child ever said, and the ring still holds it — so one `append` can produce
//! thousands of lines. The caller has to land each one in its own `String` for its sink regardless,
//! so flattening them into a single delivery would add a whole extra copy of the ring to save
//! crossings that the count already saved. Same trade [`crate::replay`]'s payload slot refuses, for
//! the same reason.

use core::ffi::c_uchar;

use slopdesk_sidecars::line_assembler::LineAssembler;

use crate::{borrow, deliver};

/// The opaque handle: the assembler, plus the slot holding the last `append`'s lines.
#[derive(Debug, Default)]
pub struct SlopDeskLineAssembler {
    assembler: LineAssembler,
    /// Lines produced by the last [`slopdesk_line_assembler_append`]. Held until the next one
    /// overwrites them, so a caller may take a length, allocate, and copy without a lock between.
    lines: Vec<String>,
}

/// Turns a caller's handle pointer into a reference for the duration of one call.
///
/// # Safety
/// `handle` must be a live pointer from [`slopdesk_line_assembler_new`] that has not been freed,
/// and no other call on it may overlap this one.
#[expect(
    unsafe_code,
    reason = "reconstituting the handle IS the boundary this module documents"
)]
unsafe fn held<'a>(handle: *mut SlopDeskLineAssembler) -> Option<&'a mut SlopDeskLineAssembler> {
    if handle.is_null() {
        return None;
    }
    // SAFETY: non-null and, by the caller's obligation, live, correctly aligned and unaliased for
    // this call — the near side serialises every entry point under the lock it already held.
    Some(unsafe { &mut *handle })
}

/// Creates an assembler with nothing pending and returns its handle, or null if allocation failed.
///
/// # Safety
/// Nothing is borrowed — the handle owns everything it needs. The function is `unsafe` only because
/// an exported C entry point is, in edition 2024.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_line_assembler_new() -> *mut SlopDeskLineAssembler {
    Box::into_raw(Box::new(SlopDeskLineAssembler::default()))
}

/// Frees a handle. Null is a no-op; anything else must come from exactly one
/// [`slopdesk_line_assembler_new`] and be freed exactly once.
///
/// # Safety
/// `handle` must be null, or a live pointer from [`slopdesk_line_assembler_new`] not yet freed,
/// with no other call on it in flight.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_line_assembler_free(handle: *mut SlopDeskLineAssembler) {
    if handle.is_null() {
        return;
    }
    // SAFETY: by the caller's obligation this pointer came from `Box::into_raw` in
    // `slopdesk_line_assembler_new` and has not been freed, so reclaiming the box is sound.
    drop(unsafe { Box::from_raw(handle) });
}

/// Folds one chunk in and returns how many complete lines it produced, which the caller then reads
/// out of the slot with [`slopdesk_line_assembler_line`].
///
/// Zero is the ordinary answer while a line is still arriving. It is also what the cap answers when
/// it has just dropped a runaway's residue, and the two are deliberately not told apart — see the
/// rule's own module for what that costs and why remembering the drop would cost more.
///
/// # Safety
/// `handle` must be a live, unfreed pointer from [`slopdesk_line_assembler_new`] with no other call
/// on it in flight, and `(chunk, len)` must be null or name `len` initialised bytes live for the
/// call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and both the handle and the chunk are the caller's"
)]
pub unsafe extern "C" fn slopdesk_line_assembler_append(
    handle: *mut SlopDeskLineAssembler,
    chunk: *const c_uchar,
    len: usize,
) -> usize {
    // SAFETY: the caller's obligation, forwarded unchanged.
    let Some(state) = (unsafe { held(handle) }) else {
        return 0;
    };
    // SAFETY: ditto; the borrow dies with this call.
    let bytes = unsafe { borrow(chunk, len) };
    state.lines = state.assembler.append(bytes);
    state.lines.len()
}

/// Copies one line out of the slot by index, under §4's convention.
///
/// An index past the slot's end, and a line that is empty — which a bare `\r\n` produces and which
/// is a line the caller must still report — both answer 0. They are distinguishable by the count
/// the caller already holds, so nothing here needs a second signal for it.
///
/// # Safety
/// `handle` must be a live, unfreed pointer from [`slopdesk_line_assembler_new`] with no other call
/// on it in flight, and `out` must be null or writable for `cap` bytes for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and both the handle and the buffer are the caller's"
)]
pub unsafe extern "C" fn slopdesk_line_assembler_line(
    handle: *mut SlopDeskLineAssembler,
    index: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, forwarded unchanged.
    let Some(state) = (unsafe { held(handle) }) else {
        return 0;
    };
    let answer = state.lines.get(index).map_or("", String::as_str);
    // SAFETY: ditto; `deliver` writes at most `cap`.
    unsafe { deliver(answer.as_bytes(), out, cap) }
}

#[cfg(test)]
mod tests {
    #![expect(unsafe_code, reason = "calling the door is the only way to test the door")]

    use super::{
        SlopDeskLineAssembler, slopdesk_line_assembler_append, slopdesk_line_assembler_free,
        slopdesk_line_assembler_line, slopdesk_line_assembler_new,
    };

    /// A handle for the length of one test, freed exactly once.
    struct Owned(*mut SlopDeskLineAssembler);

    impl Owned {
        fn new() -> Self {
            // SAFETY: nothing is borrowed; the handle owns everything it needs.
            Self(unsafe { slopdesk_line_assembler_new() })
        }

        /// Appends a chunk and reads every line the slot then holds — the whole loop the near side
        /// runs, so the test travels the door the way Swift does.
        fn append(&self, chunk: &[u8]) -> Vec<String> {
            // SAFETY: the handle is live and unfreed, this call does not overlap another, and
            // `chunk` is a live Rust slice for its length.
            let count = unsafe { slopdesk_line_assembler_append(self.0, chunk.as_ptr(), chunk.len()) };
            (0..count).map(|index| self.line(index)).collect()
        }

        /// One line, sized first and then copied — the two-call shape the convention prescribes.
        fn line(&self, index: usize) -> String {
            // SAFETY: the handle is live and unfreed; a null output with zero capacity is the
            // supported way to ask for the length.
            let needed = unsafe { slopdesk_line_assembler_line(self.0, index, core::ptr::null_mut(), 0) };
            let mut room = vec![0_u8; needed];
            // SAFETY: ditto, and `room` is writable for exactly `needed` bytes.
            let written =
                unsafe { slopdesk_line_assembler_line(self.0, index, room.as_mut_ptr(), room.len()) };
            room.truncate(written.min(needed));
            String::from_utf8(room).unwrap_or_default()
        }
    }

    impl Drop for Owned {
        fn drop(&mut self) {
            // SAFETY: exactly one free per new, with no call in flight.
            unsafe { slopdesk_line_assembler_free(self.0) };
        }
    }

    #[test]
    fn one_handle_carries_a_line_across_the_chunks_it_arrived_in() {
        let assembler = Owned::new();
        assert!(assembler.append(b"listening on por").is_empty());
        assert_eq!(assembler.append(b"t 41234\r\n"), ["listening on port 41234"]);
    }

    #[test]
    fn the_slot_holds_every_line_of_one_append_in_order() {
        let assembler = Owned::new();
        assert_eq!(assembler.append(b"one\r\ntwo\r\nthree\r\n"), [
            "one", "two", "three"
        ]);
    }

    /// An empty line is a line, and it answers 0 bytes — the same as an index past the end. The
    /// COUNT is what tells them apart, which is why the caller reads it first.
    #[test]
    fn an_empty_line_is_delivered_as_zero_bytes_and_still_counted() {
        let assembler = Owned::new();
        // SAFETY: the handle is live and unfreed and the chunk is a live Rust slice.
        let count = unsafe { slopdesk_line_assembler_append(assembler.0, b"\r\na\n".as_ptr(), 4) };
        assert_eq!(count, 2);
        assert_eq!(assembler.line(0), "");
        assert_eq!(assembler.line(1), "a");
        assert_eq!(assembler.line(9), "", "past the end is the same zero, by design");
    }

    #[test]
    fn a_short_buffer_is_told_the_length_and_written_nothing() {
        let assembler = Owned::new();
        // SAFETY: the handle is live and unfreed and the chunk is a live Rust slice.
        unsafe { slopdesk_line_assembler_append(assembler.0, b"abcdef\n".as_ptr(), 7) };
        let mut room = [0_u8; 2];
        // SAFETY: ditto, and `room` is writable for its own length.
        let needed = unsafe { slopdesk_line_assembler_line(assembler.0, 0, room.as_mut_ptr(), room.len()) };
        assert_eq!(needed, 6);
        assert_eq!(room, [0, 0], "nothing is written when the answer does not fit");
    }

    /// Every entry point is inert on null, so a failed `new` cannot become a crash one call later.
    #[test]
    fn a_null_handle_is_inert_everywhere() {
        // SAFETY: null is explicitly accepted by every entry point here.
        unsafe {
            assert_eq!(
                slopdesk_line_assembler_append(core::ptr::null_mut(), b"a\n".as_ptr(), 2),
                0
            );
            assert_eq!(
                slopdesk_line_assembler_line(core::ptr::null_mut(), 0, core::ptr::null_mut(), 0),
                0
            );
            slopdesk_line_assembler_free(core::ptr::null_mut());
        }
    }

    /// A null chunk is an empty one — it must not lose the residue already pending.
    #[test]
    fn a_null_chunk_completes_nothing_and_loses_nothing() {
        let assembler = Owned::new();
        assert!(assembler.append(b"half").is_empty());
        // SAFETY: the handle is live, and a null chunk with zero length is accepted as empty.
        let count = unsafe { slopdesk_line_assembler_append(assembler.0, core::ptr::null(), 0) };
        assert_eq!(count, 0);
        assert_eq!(assembler.append(b"-done\n"), ["half-done"]);
    }
}
