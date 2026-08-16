//! `wait --until`'s live scan, in C.
//!
//! §4b's handle, because the scan IS state: three carried buffers that only mean anything in
//! sequence, fed one PTY chunk at a time from the read loop. A pure entry would have to be handed
//! the whole accumulation every chunk, which is the quadratic shape this replaced.
//!
//! The handle is created by the connection thread and fed by the PTY read-loop thread, one chunk at
//! a time, under the caller's lock. It is `!Sync` on purpose — nothing here serialises, and the
//! Swift face is the thing that already holds an `NSCondition` around every touch.

use core::ffi::c_uchar;

use slopdesk_rowscan::waituntil::Scanner;

use crate::{borrow, deliver};

/// One live scan. Opaque to C.
#[derive(Debug)]
pub struct SlopDeskWaitScan(Scanner);

/// Opens a scan for `pattern`, or returns null when the pattern does not compile.
///
/// Null is the ERROR here, not an empty answer: unlike a find field being typed into, this pattern
/// arrived whole from an agent, and a caller that mistyped it would otherwise block until its
/// timeout with no way to tell that from a marker that never appeared.
///
/// # Safety
/// `pattern` must be null or describe live memory for the call. The returned handle must be freed
/// exactly once with [`slopdesk_wait_scan_free`].
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_wait_scan_new(
    pattern: *const c_uchar,
    pattern_len: usize,
    buffer_cap: usize,
) -> *mut SlopDeskWaitScan {
    // SAFETY: null or live for the call by the caller's obligation.
    let text = String::from_utf8_lossy(unsafe { borrow(pattern, pattern_len) }).into_owned();
    Scanner::new(&text, buffer_cap).map_or(core::ptr::null_mut(), |scanner| {
        Box::into_raw(Box::new(SlopDeskWaitScan(scanner)))
    })
}

/// Releases a scan. Null is a no-op, and a handle must not be used after this.
///
/// # Safety
/// `handle` must be null or a handle from [`slopdesk_wait_scan_new`] that has not been freed.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_wait_scan_free(handle: *mut SlopDeskWaitScan) {
    if handle.is_null() {
        return;
    }
    // SAFETY: the caller's obligation says this came from `new` and has not been freed, so
    // reclaiming the box is the matching half of `Box::into_raw`.
    drop(unsafe { Box::from_raw(handle) });
}

/// Feeds one raw PTY chunk. `true` when the pattern matched in the window this chunk completed.
///
/// # Safety
/// `handle` must be a live handle and `chunk` must be null or live for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_wait_scan_ingest(
    handle: *mut SlopDeskWaitScan,
    chunk: *const c_uchar,
    chunk_len: usize,
) -> bool {
    // SAFETY: live by the caller's obligation, and this is the only reference for the call.
    let Some(scan) = (unsafe { handle.as_mut() }) else {
        return false;
    };
    // SAFETY: null or live for the call by the caller's obligation.
    scan.0.ingest(unsafe { borrow(chunk, chunk_len) })
}

/// The capped accumulation of everything stripped so far, under §4's convention.
///
/// # Safety
/// `handle` must be a live handle, and `out` must be null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_wait_scan_stripped(
    handle: *mut SlopDeskWaitScan,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: live by the caller's obligation, and this is the only reference for the call.
    let Some(scan) = (unsafe { handle.as_mut() }) else {
        return 0;
    };
    // SAFETY: null or writable for `cap` bytes by the caller's obligation, and the accumulation is
    // held by the handle, which cannot overlap the caller's buffer.
    unsafe { deliver(scan.0.stripped(), out, cap) }
}

#[cfg(test)]
#[expect(unsafe_code, reason = "calling the door is the only way to test the door")]
mod tests {
    use super::{
        slopdesk_wait_scan_free, slopdesk_wait_scan_ingest, slopdesk_wait_scan_new,
        slopdesk_wait_scan_stripped,
    };

    #[test]
    fn a_marker_split_across_chunks_crosses_the_door_as_one_match() {
        let pattern = "BUILD COMPLETE";
        // SAFETY: every pointer names a live local for the duration of the call.
        let handle = unsafe { slopdesk_wait_scan_new(pattern.as_ptr(), pattern.len(), 64 * 1024) };
        assert!(!handle.is_null(), "the pattern compiles");
        let feed = |bytes: &[u8]| {
            // SAFETY: the handle is live and the chunk is a live local.
            unsafe { slopdesk_wait_scan_ingest(handle, bytes.as_ptr(), bytes.len()) }
        };
        assert!(!feed(b"earlier output BUILD COM"));
        assert!(feed(b"PLETE\n"));
        // SAFETY: the handle is live; a null `out` is the sizing half of §4.
        let needed = unsafe { slopdesk_wait_scan_stripped(handle, core::ptr::null_mut(), 0) };
        assert_eq!(needed, "earlier output BUILD COMPLETE\n".len());
        // SAFETY: the handle came from `new` above and is freed exactly once.
        unsafe { slopdesk_wait_scan_free(handle) };
    }

    #[test]
    fn a_pattern_that_does_not_compile_answers_null() {
        let pattern = "([unclosed";
        // SAFETY: the pattern is a live local for the duration of the call.
        let handle = unsafe { slopdesk_wait_scan_new(pattern.as_ptr(), pattern.len(), 1024) };
        assert!(handle.is_null(), "null is the error, not an empty scan");
        // SAFETY: freeing null is the documented no-op.
        unsafe { slopdesk_wait_scan_free(handle) };
    }
}
