//! The Android bridge's request/response grammar, in C — `Sources/SlopDeskDevicePanels/Android/
//! AndroidBridgeClient.swift` and `AndroidBridgeSocket.swift`.
//!
//! The rules are [`slopdesk_devicepanel::android_bridge`]'s; what is here is the marshalling.
//!
//! ## What did NOT move, and why the socket is still Swift
//!
//! `docs/55` §1 picks by lifetime, and an `NWConnection` is the caller's: it outlives the call,
//! delivers on its own queue and is torn down by the view model that owns it. So the four doors
//! below are the two ENDS of that connection — the bytes written into it, and the meaning of the
//! line read back — and nothing in between. The ack/stream split stays in the receive handler
//! because it is the receive handler: the reply line and the first bytes of the stream arrive in
//! the same `receive`, and a door in the middle of that would be a second buffer to keep in step
//! with the socket's own.
//!
//! ## The one door that is a handle
//!
//! The console's line framing cannot be a function, for [`crate::android_stream`]'s reason at a
//! smaller size: the half-line left over from one `recv` is what the next one completes, and a
//! caller holding that tail is a caller holding the rule. It is the packetizer's park-then-read
//! shape rather than §4's measure-then-fill, because a push is not idempotent — asking twice would
//! fold the same chunk in twice.

use core::ffi::c_uchar;

use slopdesk_devicepanel::android_bridge::{
    BridgeOp, LogLineSplitter, console_output, reply_failure, request_line, screenshot_bytes,
};

use crate::{borrow, deliver, lent, push_text, saturating_u32};

/// Writes one bridge request line — the JSON object and its terminating newline — into `out`.
///
/// `op` is `0` list · `1` boot · `2` shutdown · `3` console · `4` screenshot · `5` logcat ·
/// `6` open. `argument` is the op's second field: the AVD name for boot, the command for console,
/// the `logcat` priority letter for logcat, and unread for the rest. `max_size` is read for open
/// alone.
///
/// `0` is "this request cannot be built" — an op byte no build wrote, or a required field that is
/// empty. It cannot collide with a real answer: every line this writes carries at least `{"op":…}`
/// and a newline. The near side has ONE arm for it, where it used to have one per operation
/// guarding a JSON encoder that raised an Objective-C exception rather than throwing.
///
/// # Safety
/// `serial` and `argument` must each be null or point to their length in live bytes for the call;
/// `(out, cap)` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_android_bridge_request(
    op: u8,
    serial: *const c_uchar,
    serial_len: usize,
    argument: *const c_uchar,
    argument_len: usize,
    max_size: i64,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; `lent` and `deliver` state their own.
    unsafe {
        let Some(op) = BridgeOp::from_byte(op) else {
            return 0;
        };
        let serial = lent(serial, serial_len);
        let argument = lent(argument, argument_len);
        let Some(line) = request_line(op, serial, argument, max_size) else {
            return 0;
        };
        deliver(line.as_bytes(), out, cap)
    }
}

/// Why the host refused this reply line, in the words it used. `0` is "the host acked".
///
/// The sentinel is sound by construction rather than by convention: every failure this answers is a
/// non-empty sentence, because a refusal that named no reason — or named an empty one — reads as
/// the panel's own "The host refused." rather than as a blank dialog.
///
/// # Safety
/// `line` must be null or point to `line_len` live bytes for the call; `(out, cap)` must be
/// writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_android_bridge_reply_failure(
    line: *const c_uchar,
    line_len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above.
    unsafe {
        let Some(message) = reply_failure(borrow(line, line_len)) else {
            return 0;
        };
        deliver(message.as_bytes(), out, cap)
    }
}

/// What one console command printed, out of its reply line.
///
/// `0` is an EMPTY answer rather than no answer, and the two are deliberately not told apart: a
/// reply with no `output` and a reply whose `output` is `""` both print nothing, so a flag would
/// name a distinction the console cannot act on.
///
/// # Safety
/// `line` must be null or point to `line_len` live bytes for the call; `(out, cap)` must be
/// writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_android_bridge_console_output(
    line: *const c_uchar,
    line_len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above.
    unsafe { deliver(console_output(borrow(line, line_len)).as_bytes(), out, cap) }
}

/// How many PNG bytes follow this ack, or `0` for a capture the panel will not collect.
///
/// One answer for all three refusals — no count, a count of zero or less, and a count past the
/// 16 MiB ceiling — because the near side does the same thing with each. `0` is outside the
/// answer's range by construction: a capture of no bytes is not one.
///
/// # Safety
/// `line` must be null or point to `line_len` live bytes for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_android_bridge_screenshot_bytes(
    line: *const c_uchar,
    line_len: usize,
) -> usize {
    // SAFETY: the caller's obligation, restated above; `borrow` states its own.
    let line = unsafe { borrow(line, line_len) };
    screenshot_bytes(line).unwrap_or(0)
}

/// Builds a line splitter at the head of a fresh `logcat` subscription.
///
/// There is no `_reset`: a subscription that is re-opened is a new splitter, and freeing one to
/// build another costs two calls once per connect where a reset door would cost a rule the near
/// side has to remember to call.
///
/// # Safety
/// Nothing is borrowed. The function is `unsafe` only because an exported C entry point is, in
/// edition 2024.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_android_log_lines_new() -> *mut LogLines {
    Box::into_raw(Box::new(LogLines {
        splitter: LogLineSplitter::new(),
        answer: Vec::new(),
    }))
}

/// Frees a splitter. Null is a no-op; anything else must come from exactly one
/// [`slopdesk_android_log_lines_new`] and be freed exactly once.
///
/// # Safety
/// `handle` must be null, or a live pointer from [`slopdesk_android_log_lines_new`] not yet freed,
/// with no other call on it in flight.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_android_log_lines_free(handle: *mut LogLines) {
    if handle.is_null() {
        return;
    }
    // SAFETY: by the caller's obligation this came from one `new` and has not been freed.
    drop(unsafe { Box::from_raw(handle) });
}

/// One splitter, plus the answer its last push parked.
///
/// The blob is parked rather than measured because a push CONSUMES: §4's "call again with a bigger
/// buffer" would fold the same chunk in a second time, and a `logcat` console would print every
/// line twice on the first short read.
#[derive(Debug)]
pub struct LogLines {
    splitter: LogLineSplitter,
    answer: Vec<u8>,
}

/// Folds one freshly received chunk in and parks the lines it completed.
///
/// Answers how many bytes [`slopdesk_android_log_lines_answer`] needs — `0` when the chunk
/// completed no line, which is the ordinary answer mid-line. Every push REPLACES the parked answer,
/// including with nothing, so a caller that skips the read cannot see the previous chunk's lines
/// again.
///
/// The parked blob is `[u32 count]` then `count` × (`[u32 length]`, that many UTF-8 bytes), all
/// big-endian — the same framing every door here that answers a table of words uses. The count
/// rides in front even though it is derivable, because a console that stops mid-walk on a lying
/// length is one that shows a partial chunk with no way to tell it was partial.
///
/// # Safety
/// `handle` must be a live pointer from [`slopdesk_android_log_lines_new`] that has not been freed,
/// with no other call on it overlapping; `chunk` must be null or point to `chunk_len` live bytes
/// for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_android_log_lines_push(
    handle: *mut LogLines,
    chunk: *const c_uchar,
    chunk_len: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above.
    unsafe {
        let Some(state) = held(handle) else {
            return 0;
        };
        let lines = state.splitter.push(borrow(chunk, chunk_len));
        state.answer.clear();
        if lines.is_empty() {
            return 0;
        }
        state
            .answer
            .extend_from_slice(&saturating_u32(lines.len()).to_be_bytes());
        for line in &lines {
            push_text(&mut state.answer, line);
        }
        state.answer.len()
    }
}

/// Copies the lines the last push parked, under §4's convention.
///
/// Readable as often as the caller likes: nothing is consumed here, so a short buffer costs a call
/// and never a line.
///
/// # Safety
/// `handle` must be live per [`slopdesk_android_log_lines_push`]'s obligation; `(out, cap)` must be
/// writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_android_log_lines_answer(
    handle: *mut LogLines,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above.
    unsafe {
        let Some(state) = held(handle) else {
            return 0;
        };
        deliver(&state.answer, out, cap)
    }
}

/// Turns a caller's handle pointer into a reference for the duration of one call.
///
/// # Safety
/// `handle` must be a live pointer from [`slopdesk_android_log_lines_new`] that has not been freed,
/// and no other call on it may overlap this one.
#[expect(
    unsafe_code,
    reason = "reconstituting the handle IS the boundary this module documents"
)]
unsafe fn held<'a>(handle: *mut LogLines) -> Option<&'a mut LogLines> {
    if handle.is_null() {
        return None;
    }
    // SAFETY: non-null and, by the caller's obligation, live and unaliased for this call — the
    // Swift owner is one splitter per console subscription, driven by one receive loop.
    Some(unsafe { &mut *handle })
}

#[cfg(test)]
#[expect(unsafe_code, reason = "calling the boundary IS what these tests are for")]
mod tests {
    use super::{
        LogLines, slopdesk_android_bridge_console_output, slopdesk_android_bridge_reply_failure,
        slopdesk_android_bridge_request, slopdesk_android_bridge_screenshot_bytes,
        slopdesk_android_log_lines_answer, slopdesk_android_log_lines_free, slopdesk_android_log_lines_new,
        slopdesk_android_log_lines_push,
    };

    /// The §4 dance every text door here takes: size, then fill.
    fn text(mut door: impl FnMut(*mut u8, usize) -> usize) -> Option<String> {
        let needed = door(core::ptr::null_mut(), 0);
        if needed == 0 {
            return None;
        }
        let mut buffer = vec![0_u8; needed];
        let written = door(buffer.as_mut_ptr(), buffer.len());
        assert_eq!(written, needed, "the second call agrees with the first");
        buffer.truncate(written);
        String::from_utf8(buffer).ok()
    }

    fn request(op: u8, serial: &str, argument: &str, max_size: i64) -> Option<String> {
        text(|out, cap| {
            // SAFETY: both inputs are live locals and `(out, cap)` is the caller's buffer.
            unsafe {
                slopdesk_android_bridge_request(
                    op,
                    serial.as_ptr(),
                    serial.len(),
                    argument.as_ptr(),
                    argument.len(),
                    max_size,
                    out,
                    cap,
                )
            }
        })
    }

    fn failure(line: &str) -> Option<String> {
        text(|out, cap| {
            // SAFETY: the line is a live local and `(out, cap)` is the caller's buffer.
            unsafe { slopdesk_android_bridge_reply_failure(line.as_ptr(), line.len(), out, cap) }
        })
    }

    #[test]
    fn a_request_crosses_as_the_line_the_daemon_decodes() {
        let line = request(0, "", "", 0).unwrap_or_default();
        assert_eq!(line, "{\"op\":\"list\"}\n");
    }

    #[test]
    fn an_op_byte_no_build_wrote_builds_nothing() {
        assert_eq!(request(7, "serial", "", 0), None);
        assert_eq!(request(u8::MAX, "serial", "", 0), None);
    }

    #[test]
    fn a_missing_required_field_is_the_same_refusal_as_a_bad_op() {
        // Shutdown with no serial: the one arm the near side keeps.
        assert_eq!(request(2, "", "", 0), None);
    }

    #[test]
    fn a_null_input_pair_reads_as_absent_rather_than_as_a_crash() {
        // SAFETY: null is the documented "no text" spelling at this boundary.
        let needed = unsafe {
            slopdesk_android_bridge_request(
                1,
                core::ptr::null(),
                0,
                core::ptr::null(),
                0,
                0,
                core::ptr::null_mut(),
                0,
            )
        };
        assert_eq!(needed, 0, "a boot with no AVD name builds nothing");
    }

    #[test]
    fn an_acked_reply_answers_zero_and_a_refusal_answers_its_sentence() {
        assert_eq!(failure(r#"{"ok":true}"#), None);
        assert_eq!(
            failure(r#"{"ok":false,"error":"no such avd"}"#).as_deref(),
            Some("no such avd")
        );
        assert_eq!(
            failure("not json").as_deref(),
            Some("The host's reply made no sense.")
        );
        assert_eq!(failure(r#"{"ok":false}"#).as_deref(), Some("The host refused."));
    }

    #[test]
    fn a_short_buffer_leaves_it_untouched_and_reports_what_it_needs() {
        let line = r#"{"ok":false,"error":"no such avd"}"#;
        let mut small = [0_u8; 3];
        // SAFETY: both buffers are live locals.
        let needed = unsafe {
            slopdesk_android_bridge_reply_failure(line.as_ptr(), line.len(), small.as_mut_ptr(), small.len())
        };
        assert_eq!(needed, "no such avd".len());
        assert_eq!(small, [0, 0, 0], "nothing was written");
    }

    #[test]
    fn console_output_crosses_and_an_absent_one_is_an_empty_answer() {
        let reply = r#"{"ok":true,"output":"OK"}"#;
        let answer = text(|out, cap| {
            // SAFETY: the line is a live local.
            unsafe { slopdesk_android_bridge_console_output(reply.as_ptr(), reply.len(), out, cap) }
        });
        assert_eq!(answer.as_deref(), Some("OK"));

        let bare = r#"{"ok":true}"#;
        // SAFETY: the line is a live local; a null output is the size-only call.
        let needed = unsafe {
            slopdesk_android_bridge_console_output(bare.as_ptr(), bare.len(), core::ptr::null_mut(), 0)
        };
        assert_eq!(needed, 0);
    }

    #[test]
    fn a_screenshot_count_answers_zero_for_every_refusal() {
        let count = |line: &str| {
            // SAFETY: the line is a live local.
            unsafe { slopdesk_android_bridge_screenshot_bytes(line.as_ptr(), line.len()) }
        };
        assert_eq!(count(r#"{"ok":true,"bytes":2048}"#), 2048);
        assert_eq!(count(r#"{"ok":true,"bytes":0}"#), 0);
        assert_eq!(count(r#"{"ok":true,"bytes":33554432}"#), 0);
        assert_eq!(count("not json"), 0);
    }

    /// Reads the parked blob back into the rows a console would draw.
    fn walk(handle: *mut LogLines) -> Vec<String> {
        // SAFETY: the handle is live for the test.
        let needed = unsafe { slopdesk_android_log_lines_answer(handle, core::ptr::null_mut(), 0) };
        if needed == 0 {
            return Vec::new();
        }
        let mut blob = vec![0_u8; needed];
        // SAFETY: the handle is live and the buffer is a live local.
        let written = unsafe { slopdesk_android_log_lines_answer(handle, blob.as_mut_ptr(), blob.len()) };
        assert_eq!(written, needed);

        let mut cursor = 0_usize;
        let mut next = |width: usize| -> Vec<u8> {
            let taken = blob.get(cursor..cursor + width).unwrap_or_default().to_vec();
            cursor += width;
            taken
        };
        let count = u32::from_be_bytes(next(4).try_into().unwrap_or([0; 4]));
        let mut rows = Vec::new();
        for _ in 0..count {
            let length = u32::from_be_bytes(next(4).try_into().unwrap_or([0; 4])) as usize;
            rows.push(String::from_utf8_lossy(&next(length)).into_owned());
        }
        assert_eq!(cursor, blob.len(), "the walk lands exactly on the end");
        rows
    }

    fn push(handle: *mut LogLines, chunk: &[u8]) -> usize {
        // SAFETY: the handle is live for the test and the chunk is a live local.
        unsafe { slopdesk_android_log_lines_push(handle, chunk.as_ptr(), chunk.len()) }
    }

    #[test]
    fn a_console_stream_crosses_chunk_by_chunk() {
        // SAFETY: nothing is borrowed by `new`.
        let handle = unsafe { slopdesk_android_log_lines_new() };
        assert_eq!(push(handle, b"first half"), 0, "no line completed yet");
        assert!(walk(handle).is_empty());
        assert!(push(handle, b" second\nnext\r\n") > 0);
        assert_eq!(walk(handle), ["first half second", "next"]);
        // A push that completes nothing REPLACES the answer rather than leaving it standing.
        assert_eq!(push(handle, b"tail"), 0);
        assert!(walk(handle).is_empty());
        // SAFETY: one `new`, freed once.
        unsafe { slopdesk_android_log_lines_free(handle) };
    }

    #[test]
    fn a_short_buffer_costs_a_call_and_never_a_line() {
        // SAFETY: nothing is borrowed by `new`.
        let handle = unsafe { slopdesk_android_log_lines_new() };
        let needed = push(handle, b"row\n");
        let mut small = [0_u8; 2];
        // SAFETY: the handle is live and the buffer is a live local.
        let again = unsafe { slopdesk_android_log_lines_answer(handle, small.as_mut_ptr(), small.len()) };
        assert_eq!(again, needed);
        assert_eq!(small, [0, 0], "nothing was written");
        assert_eq!(walk(handle), ["row"], "the answer survived the bad guess");
        // SAFETY: one `new`, freed once.
        unsafe { slopdesk_android_log_lines_free(handle) };
    }

    #[test]
    fn a_null_handle_is_inert_at_every_entry_point() {
        assert_eq!(push(core::ptr::null_mut(), b"row\n"), 0);
        // SAFETY: null is the documented no-op.
        unsafe {
            assert_eq!(
                slopdesk_android_log_lines_answer(core::ptr::null_mut(), core::ptr::null_mut(), 0),
                0
            );
            slopdesk_android_log_lines_free(core::ptr::null_mut());
        }
    }
}
