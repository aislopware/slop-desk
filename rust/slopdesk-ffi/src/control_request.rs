//! The client control socket's validate-then-drop rules, in C.
//!
//! The rules are `slopdesk_workspace::control_request`; what is here is the marshalling.
//!
//! ## The line crosses once, as a span
//!
//! [`slopdesk_ws_ctl_line_scan`] answers OFFSETS into the caller's own line rather than a copy of
//! the request inside it — `docs/55` §4c's shape, and the reason a 64 KiB request costs one length
//! comparison here rather than an allocation. The near side slices its own bytes at the offsets,
//! which is the operation it was going to do anyway.
//!
//! ## What deliberately does not cross
//!
//! The method names and the placement / font-scope / badge tokens. `slopdesk-cli` writes them and
//! `slopdesk-invariants` holds that spelling against the Swift protocol the far end dispatches
//! through; a third copy behind this door would be a vocabulary no gate reads.

use core::ffi::c_uchar;

use slopdesk_workspace::control_request::{self, LineVerdict, Refusal, SendKeysFacts};

use crate::{borrow, deliver};

// ---------------------------------------------------------------------------------------------- //
// The line guard
// ---------------------------------------------------------------------------------------------- //

/// The cap one request line is refused past — `control_request::MAX_REQUEST_BYTES`.
///
/// A door for a single number, because there are TWO Swift servers on this cap (the client's and
/// the host's) and a third transcription of `64 * 1024` is how the two ends of one socket end up
/// disagreeing about which line was too long. `shared-number-asked-or-ratcheted` is the rule that
/// says so.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_ws_ctl_max_request_bytes() -> usize {
    control_request::MAX_REQUEST_BYTES
}

/// What one raw request line is — `0` blank, `1` too large, `2` worth parsing — writing the BYTE
/// span of the trimmed request to `start` and `end`.
///
/// Both out-pointers may be null, which asks only for the verdict. The span is written for every
/// verdict, including the two that refuse.
///
/// Bytes that are not UTF-8 cannot be trimmed, so they cross as the WHOLE line: too large if the
/// raw length is past the cap, worth parsing otherwise — where the parser refuses them as
/// malformed, which is the answer they would have reached anyway.
///
/// # Safety
/// `(line, len)` must be readable for the call, and `start` / `end` must each be null or writable
/// for one `size_t`.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and every pointer is the caller's"
)]
pub unsafe extern "C" fn slopdesk_ws_ctl_line_scan(
    line: *const c_uchar,
    len: usize,
    start: *mut usize,
    end: *mut usize,
) -> c_uchar {
    // SAFETY: the caller's obligation, restated above; the borrow dies with this call.
    let bytes = unsafe { borrow(line, len) };
    let (verdict, from, to) = match core::str::from_utf8(bytes) {
        Ok(text) => {
            let scan = control_request::scan_line(text);
            (scan.verdict, scan.start, scan.end)
        },
        Err(_) if len > control_request::MAX_REQUEST_BYTES => (LineVerdict::TooLarge, 0, len),
        Err(_) => (LineVerdict::Parse, 0, len),
    };
    if !start.is_null() {
        // SAFETY: non-null and writable for one `size_t` by the caller's obligation.
        unsafe { start.write(from) };
    }
    if !end.is_null() {
        // SAFETY: non-null and writable for one `size_t` by the caller's obligation.
        unsafe { end.write(to) };
    }
    verdict.code()
}

// ---------------------------------------------------------------------------------------------- //
// The two bounded payloads
// ---------------------------------------------------------------------------------------------- //

/// How many scrollback lines a `pane-capture` request asks for, or `-1` when the count is not a
/// positive integer.
///
/// Signed, because the answer is positive by construction — the sentinel is outside its range,
/// which is what `docs/55` §4b asks of one. An absent count answers the default; a present one is
/// clamped to the ceiling rather than refused, because asking for more scrollback than exists is
/// what a big number MEANS.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_ws_ctl_capture_lines(present: bool, is_integer: bool, raw: i64) -> i64 {
    control_request::capture_lines(present, is_integer, raw).unwrap_or(-1)
}

/// What a `pane-send-keys` request carries, once its `keys` have been read.
///
/// Four bools on purpose: they are facts about two independent fields, and the pair per field is
/// what makes "present but wrong" distinguishable from "absent". (`struct_excessive_bools` does not
/// fire on a `repr(C)` record, so there is no expectation to carry here — the C layout IS the
/// argument list.)
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SlopDeskWsSendKeys {
    /// Whether the request carried a `keys` field at all.
    pub keys_present: bool,
    /// Whether that field was an array. Meaningless when `keys_present` is `false`.
    pub keys_is_array: bool,
    /// Whether `text` is a non-empty string.
    pub has_text: bool,
    /// Whether any key survived the read — the near side drops non-string elements as it reads
    /// them.
    pub has_keys: bool,
}

/// Why a `pane-send-keys` request cannot be served, as a refusal code, or `0` when it can.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_ws_ctl_send_keys_refusal(facts: SlopDeskWsSendKeys) -> c_uchar {
    control_request::send_keys_refusal(SendKeysFacts {
        keys_present: facts.keys_present,
        keys_is_array: facts.keys_is_array,
        has_text: facts.has_text,
        has_keys: facts.has_keys,
    })
    .map_or(0, Refusal::code)
}

// ---------------------------------------------------------------------------------------------- //
// The refusal vocabulary
// ---------------------------------------------------------------------------------------------- //

/// The sentence refusal `code` answers with, as 1 run.
///
/// `(detail, detail_len)` is filled in where the refusal names one; `0` is a code this build does
/// not know — including `0` itself, which is the ABSENCE of a refusal rather than one to print.
///
/// A detail handed to a refusal that names none is ignored, so a caller that always passes what it
/// read stays a one-liner. A detail that is not UTF-8 reads as an EMPTY one: the near side's string
/// cannot produce those bytes, and a message is not the place to report that it somehow did.
///
/// # Safety
/// `(detail, detail_len)` must be readable for the call, and `out` must either be null or point to
/// `cap` writable bytes for the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and every pointer is the caller's"
)]
pub unsafe extern "C" fn slopdesk_ws_ctl_refusal_message(
    code: c_uchar,
    detail: *const c_uchar,
    detail_len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    let Some(refusal) = Refusal::from_code(code) else {
        return 0;
    };
    // SAFETY: the caller's obligation, restated above; the borrow dies with this call.
    let bytes = unsafe { borrow(detail, detail_len) };
    let named = core::str::from_utf8(bytes).unwrap_or_default();
    // SAFETY: the caller's obligation, restated above.
    unsafe { deliver(refusal.message(named).as_bytes(), out, cap) }
}

#[cfg(test)]
mod tests {
    #![expect(unsafe_code, reason = "calling the door is the only way to test the door")]

    use slopdesk_workspace::control_request::{
        DEFAULT_CAPTURE_LINES, LineVerdict, MAX_CAPTURE_LINES, MAX_REQUEST_BYTES, Refusal,
    };

    use super::{
        SlopDeskWsSendKeys, slopdesk_ws_ctl_capture_lines, slopdesk_ws_ctl_line_scan,
        slopdesk_ws_ctl_refusal_message, slopdesk_ws_ctl_send_keys_refusal,
    };

    /// Scans one line, answering the verdict and the span the caller would slice at.
    fn scan(line: &str) -> (u8, usize, usize) {
        let bytes = line.as_bytes();
        let mut start = usize::MAX;
        let mut end = usize::MAX;
        // SAFETY: the slice and both locals are live for the call.
        let verdict =
            unsafe { slopdesk_ws_ctl_line_scan(bytes.as_ptr(), bytes.len(), &raw mut start, &raw mut end) };
        (verdict, start, end)
    }

    #[test]
    fn a_request_line_crosses_as_a_verdict_and_a_span() {
        let (verdict, start, end) = scan("  {\"id\":\"1\"} \n");
        assert_eq!(verdict, LineVerdict::Parse.code());
        assert_eq!((start, end), (2, 12));
    }

    #[test]
    fn a_blank_line_crosses_as_an_empty_span() {
        let (verdict, start, end) = scan("   \n");
        assert_eq!(verdict, LineVerdict::Blank.code());
        assert_eq!(start, end);
        // SAFETY: a zero-length read of a dangling-but-aligned pointer, and two null out-pointers.
        let empty = unsafe {
            slopdesk_ws_ctl_line_scan(
                core::ptr::NonNull::dangling().as_ptr(),
                0,
                core::ptr::null_mut(),
                core::ptr::null_mut(),
            )
        };
        assert_eq!(empty, LineVerdict::Blank.code(), "null out-pointers are inert");
    }

    #[test]
    fn an_oversized_line_crosses_as_a_refusal() {
        let line = "x".repeat(MAX_REQUEST_BYTES.saturating_add(1));
        let (verdict, ..) = scan(&line);
        assert_eq!(verdict, LineVerdict::TooLarge.code());
    }

    /// Bytes nothing can trim cross as the whole line, for the parser to refuse.
    #[test]
    fn a_non_utf8_line_crosses_whole() {
        let raw = [b' ', 0xFF, b'{'];
        let mut start = usize::MAX;
        let mut end = usize::MAX;
        // SAFETY: the array and both locals are live for the call.
        let verdict =
            unsafe { slopdesk_ws_ctl_line_scan(raw.as_ptr(), raw.len(), &raw mut start, &raw mut end) };
        assert_eq!(verdict, LineVerdict::Parse.code());
        assert_eq!((start, end), (0, raw.len()));
    }

    #[test]
    fn the_capture_count_crosses_signed() {
        assert_eq!(
            slopdesk_ws_ctl_capture_lines(false, false, 0),
            DEFAULT_CAPTURE_LINES
        );
        assert_eq!(slopdesk_ws_ctl_capture_lines(true, true, 42), 42);
        assert_eq!(
            slopdesk_ws_ctl_capture_lines(true, true, i64::MAX),
            MAX_CAPTURE_LINES
        );
        assert_eq!(slopdesk_ws_ctl_capture_lines(true, true, 0), -1);
        assert_eq!(slopdesk_ws_ctl_capture_lines(true, false, 5), -1);
    }

    #[test]
    fn a_send_keys_payload_crosses_as_a_refusal_code_or_zero() {
        let sendable = SlopDeskWsSendKeys {
            keys_present: false,
            keys_is_array: false,
            has_text: true,
            has_keys: false,
        };
        assert_eq!(slopdesk_ws_ctl_send_keys_refusal(sendable), 0);
        assert_eq!(
            slopdesk_ws_ctl_send_keys_refusal(SlopDeskWsSendKeys::default()),
            Refusal::NothingToSend.code(),
        );
        let wrong_type = SlopDeskWsSendKeys {
            keys_present: true,
            keys_is_array: false,
            has_text: true,
            has_keys: false,
        };
        assert_eq!(
            slopdesk_ws_ctl_send_keys_refusal(wrong_type),
            Refusal::KeysNotAnArray.code(),
        );
    }

    /// Reads one refusal's sentence through the door.
    fn message(code: u8, detail: &str) -> String {
        let bytes = detail.as_bytes();
        let mut out = [0_u8; 128];
        // SAFETY: the slice and the buffer are live locals for the call.
        let needed = unsafe {
            slopdesk_ws_ctl_refusal_message(code, bytes.as_ptr(), bytes.len(), out.as_mut_ptr(), out.len())
        };
        if needed == 0 || needed > out.len() {
            return String::new();
        }
        core::str::from_utf8(out.get(..needed).unwrap_or_default())
            .unwrap_or_default()
            .to_owned()
    }

    /// Every refusal's sentence crosses verbatim, detail and all.
    #[test]
    fn every_refusal_message_crosses_verbatim() {
        for refusal in Refusal::ALL {
            assert_eq!(
                message(refusal.code(), "zzz-token"),
                refusal.message("zzz-token"),
                "{refusal:?}",
            );
        }
    }

    /// A code naming no refusal — including `0`, the absence of one — answers nothing.
    #[test]
    fn an_unnamed_refusal_code_says_nothing() {
        assert_eq!(message(0, ""), "");
        assert_eq!(message(21, ""), "");
        assert_eq!(message(u8::MAX, ""), "");
    }

    /// A short buffer is told the length and written nothing.
    #[test]
    fn a_short_buffer_is_told_the_length() {
        let expected = Refusal::NothingToLearn.message("");
        let mut short = [0_u8; 4];
        // SAFETY: the buffer is a live local, and a zero-length detail read of a dangling pointer.
        let needed = unsafe {
            slopdesk_ws_ctl_refusal_message(
                Refusal::NothingToLearn.code(),
                core::ptr::NonNull::dangling().as_ptr(),
                0,
                short.as_mut_ptr(),
                short.len(),
            )
        };
        assert_eq!(needed, expected.len());
        assert_eq!(short, [0, 0, 0, 0]);
    }

    /// A detail that is not UTF-8 reads as an empty one rather than refusing the message.
    #[test]
    fn a_non_utf8_detail_names_nothing() {
        let raw = [0xFF_u8, 0xFE];
        let mut out = [0_u8; 64];
        // SAFETY: both arrays are live locals for the call.
        let needed = unsafe {
            slopdesk_ws_ctl_refusal_message(
                Refusal::UnknownKey.code(),
                raw.as_ptr(),
                raw.len(),
                out.as_mut_ptr(),
                out.len(),
            )
        };
        assert_eq!(needed, Refusal::UnknownKey.message("").len());
    }
}
