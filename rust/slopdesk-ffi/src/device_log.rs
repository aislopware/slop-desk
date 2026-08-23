//! The two device consoles' line grammars — a line in, four spans out.
//!
//! `slopdesk_devicelog` owns both. This is the door, and it is a PURE one: no handle, no retry, no
//! output buffer. The record names byte offsets INTO THE CALLER'S OWN LINE, so nothing crosses back
//! except six numbers and a severity, and neither side allocates.
//!
//! ## Why the parse is not Swift
//! It ran over text a program on the far side of a device wrote, thousands of lines a minute, on
//! the socket read path — and it asked `Character.isNumber` and `Character.isUppercase`, which are
//! Unicode property lookups per grapheme cluster, then built four `String`s per row. Every one of
//! those was a `Substring` walk over a `String` whose storage the row was going to be sliced out of
//! anyway.
//!
//! ## Two doors, one record
//! The GRAMMARS stay apart — `logcat -v time` puts a priority letter and a `Tag( pid):` header
//! where `log stream --style compact` puts a severity token and a `Process[pid:tid]`, and a console
//! that guessed between them would mis-colour every row of one device. What they share is the shape
//! of an answer, so they share the record and the severity scale.
//!
//! ## The refusal
//! A line longer than `u32::MAX` cannot be named by this record. It is refused — `false`, nothing
//! written — rather than truncated, because a truncated offset names the WRONG bytes of a real line
//! and would render as a row someone might believe. No source writes one; the check is what makes
//! that a fact rather than an assumption.

use core::ffi::c_uchar;

use slopdesk_devicelog::{Line, Severity, logcat, unified};

use crate::{borrow, deliver};

/// Uninked — `logcat`'s `V`/`D` and the unified log's `Df`, which are most of a busy device's
/// output.
pub const DEVICE_LOG_PLAIN: u8 = 0;
/// The unified log's `Db` and `A`. `logcat` never answers this.
pub const DEVICE_LOG_DEBUG: u8 = 1;
/// `I` in both.
pub const DEVICE_LOG_INFO: u8 = 2;
/// `logcat`'s `W`. The unified log never answers this.
pub const DEVICE_LOG_WARNING: u8 = 3;
/// `E` in both.
pub const DEVICE_LOG_ERROR: u8 = 4;
/// `F` in both, plus `logcat`'s `A` — its ASSERT, which is what a native abort prints.
pub const DEVICE_LOG_FATAL: u8 = 5;

/// One parsed row, as offsets into the line the caller passed in.
///
/// An unrecognised line is not a failure: it answers [`DEVICE_LOG_PLAIN`], empty `time` and `name`,
/// and a `message` covering the whole input. Both consoles' sources emit their own banners, and a
/// swallowed banner is a console that looks like it silently lost the boundary between two runs.
#[derive(Debug, Clone, Copy, Default)]
#[repr(C)]
pub struct SlopDeskDeviceLogLine {
    /// Where `13:50:19.565` starts. Zero-length for a line this parse did not recognise.
    pub time_offset: u32,
    /// How long the time is.
    pub time_len: u32,
    /// Where the `logcat` tag or the process name starts.
    pub name_offset: u32,
    /// How long it is.
    pub name_len: u32,
    /// Where the message starts, with only the header's trailing gap trimmed off its head.
    pub message_offset: u32,
    /// How long it is.
    pub message_len: u32,
    /// One of the `DEVICE_LOG_*` constants.
    pub severity: u8,
}

const fn ink(severity: Severity) -> u8 {
    match severity {
        Severity::Plain => DEVICE_LOG_PLAIN,
        Severity::Debug => DEVICE_LOG_DEBUG,
        Severity::Info => DEVICE_LOG_INFO,
        Severity::Warning => DEVICE_LOG_WARNING,
        Severity::Error => DEVICE_LOG_ERROR,
        Severity::Fatal => DEVICE_LOG_FATAL,
    }
}

/// The record for a parsed line, or `None` when the line is longer than a `u32` offset can name.
///
/// Every span this builds came from a walk over the same slice, so `start <= end <= len` holds by
/// construction and the conversions below cannot narrow once the length itself has been checked.
fn record(line: &Line, len: usize) -> Option<SlopDeskDeviceLogLine> {
    if u32::try_from(len).is_err() {
        return None;
    }
    let span = |range: &core::ops::Range<usize>| {
        (
            u32::try_from(range.start).unwrap_or_default(),
            u32::try_from(range.end.saturating_sub(range.start)).unwrap_or_default(),
        )
    };
    let (time_offset, time_len) = span(&line.time);
    let (name_offset, name_len) = span(&line.name);
    let (message_offset, message_len) = span(&line.message);
    Some(SlopDeskDeviceLogLine {
        time_offset,
        time_len,
        name_offset,
        name_len,
        message_offset,
        message_len,
        severity: ink(line.severity),
    })
}

/// Writes `record` through `out` when `out` is non-null.
///
/// # Safety
/// `out` is null or a writable, aligned `SlopDeskDeviceLogLine` for this call.
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
const unsafe fn place(out: *mut SlopDeskDeviceLogLine, record: SlopDeskDeviceLogLine) {
    if !out.is_null() {
        // SAFETY: the caller's obligation above is discharged by Swift's `&record`, whose scope is
        // exactly this call.
        unsafe { *out = record };
    }
}

/// One `logcat -v time` line. `true` when the record was written.
///
/// # Safety
/// `line` is null or `len` readable bytes, and `out` is null or a writable, aligned
/// [`SlopDeskDeviceLogLine`] — both for the duration of this call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_logcat_parse(
    line: *const c_uchar,
    len: usize,
    out: *mut SlopDeskDeviceLogLine,
) -> bool {
    // SAFETY: forwarded to the caller, who owns the buffer for this call.
    let bytes = unsafe { borrow(line, len) };
    let Some(record) = record(&logcat::parse(bytes), bytes.len()) else {
        return false;
    };
    // SAFETY: forwarded to the caller, who owns the record for this call.
    unsafe { place(out, record) };
    true
}

/// One `log stream --style compact` line. `true` when the record was written.
///
/// # Safety
/// `line` is null or `len` readable bytes, and `out` is null or a writable, aligned
/// [`SlopDeskDeviceLogLine`] — both for the duration of this call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_unified_log_parse(
    line: *const c_uchar,
    len: usize,
    out: *mut SlopDeskDeviceLogLine,
) -> bool {
    // SAFETY: forwarded to the caller, who owns the buffer for this call.
    let bytes = unsafe { borrow(line, len) };
    let Some(record) = record(&unified::parse(bytes), bytes.len()) else {
        return false;
    };
    // SAFETY: forwarded to the caller, who owns the record for this call.
    unsafe { place(out, record) };
    true
}

/// One row as plain text — what Copy Line and Copy Console hand over.
///
/// Takes the three CUT fields rather than the line it came from: the caller holds a row a model
/// accumulated, not a byte slice it is still parsing. Invalid UTF-8 in any field reads as empty,
/// which is the same non-answer an absent column already makes.
///
/// Returns the bytes NEEDED — `0` for a row whose three fields are all empty. A return larger than
/// `cap` means nothing was written.
///
/// # Safety
/// `time`, `name` and `message` must be null or point to their stated lengths in live bytes, and
/// `out` must be null or point to `cap` writable bytes, all for the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_device_log_plain(
    time: *const c_uchar,
    time_len: usize,
    name: *const c_uchar,
    name_len: usize,
    message: *const c_uchar,
    message_len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, restated above; `borrow` states its own.
    let time = core::str::from_utf8(unsafe { borrow(time, time_len) }).unwrap_or_default();
    // SAFETY: the caller's obligation, restated above.
    let name = core::str::from_utf8(unsafe { borrow(name, name_len) }).unwrap_or_default();
    // SAFETY: the caller's obligation, restated above.
    let message = core::str::from_utf8(unsafe { borrow(message, message_len) }).unwrap_or_default();
    // SAFETY: the caller's obligation, restated above.
    unsafe {
        deliver(
            slopdesk_devicelog::plain(time, name, message).as_bytes(),
            out,
            cap,
        )
    }
}

#[cfg(test)]
#[expect(
    clippy::unwrap_used,
    unsafe_code,
    reason = "a door that refused a short fixture has already failed, and calling one is unsafe"
)]
mod tests {
    use super::{
        DEVICE_LOG_ERROR, DEVICE_LOG_PLAIN, SlopDeskDeviceLogLine, slopdesk_logcat_parse,
        slopdesk_unified_log_parse,
    };

    fn parsed(
        door: unsafe extern "C" fn(*const u8, usize, *mut SlopDeskDeviceLogLine) -> bool,
        text: &str,
    ) -> (String, String, String, u8) {
        let mut record = SlopDeskDeviceLogLine::default();
        // SAFETY: `text` outlives the call and `record` is a live local.
        assert!(unsafe { door(text.as_ptr(), text.len(), &raw mut record) });
        let cut = |offset: u32, len: usize| {
            let start = offset as usize;
            core::str::from_utf8(text.as_bytes().get(start..start + len).unwrap())
                .unwrap()
                .to_owned()
        };
        (
            cut(record.time_offset, record.time_len as usize),
            cut(record.name_offset, record.name_len as usize),
            cut(record.message_offset, record.message_len as usize),
            record.severity,
        )
    }

    #[test]
    fn the_logcat_door_answers_offsets_into_the_callers_own_line() {
        let (time, tag, message, severity) =
            parsed(slopdesk_logcat_parse, "08-04 13:50:19.565 E/Zygote(12345): boom");
        assert_eq!(time, "13:50:19.565");
        assert_eq!(tag, "Zygote");
        assert_eq!(message, "boom");
        assert_eq!(severity, DEVICE_LOG_ERROR);
    }

    #[test]
    fn the_unified_door_answers_its_own_grammar() {
        let (time, process, message, severity) = parsed(
            slopdesk_unified_log_parse,
            "2026-08-04 13:50:19.565 Df Poster[76037:219b94d] laid out",
        );
        assert_eq!(time, "13:50:19.565");
        assert_eq!(process, "Poster");
        assert_eq!(message, "laid out");
        assert_eq!(severity, DEVICE_LOG_PLAIN);
    }

    #[test]
    fn each_door_reads_its_own_grammar_and_not_the_others() {
        // The one mistake a shared record invites: a caller wired to the wrong door still gets a
        // record back, so the grammars must decline each other's lines rather than half-split them.
        let logcat = "08-04 13:50:19.565 E/Zygote(12345): boom";
        assert_eq!(parsed(slopdesk_unified_log_parse, logcat).2, logcat);
        let unified = "2026-08-04 13:50:19.565 Df Poster[1:2] laid out";
        assert_eq!(parsed(slopdesk_logcat_parse, unified).2, unified);
    }

    #[test]
    fn an_empty_line_crosses_as_an_empty_row() {
        for door in [slopdesk_logcat_parse, slopdesk_unified_log_parse] {
            let mut record = SlopDeskDeviceLogLine::default();
            // SAFETY: a null buffer of length zero is what `borrow` is written for.
            assert!(unsafe { door(core::ptr::null(), 0, &raw mut record) });
            assert_eq!(record.message_len, 0);
            assert_eq!(record.severity, DEVICE_LOG_PLAIN);
        }
    }

    #[test]
    fn a_null_record_is_a_parse_nobody_reads_rather_than_a_write_through_null() {
        let text = "08-04 13:50:19.565 I/X( 1): hi";
        // SAFETY: `out` is explicitly null, which the door is documented to accept.
        assert!(unsafe { slopdesk_logcat_parse(text.as_ptr(), text.len(), core::ptr::null_mut()) });
    }
}
