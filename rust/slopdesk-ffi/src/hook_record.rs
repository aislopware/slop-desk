//! Which pane a hook record belongs to, in C.
//!
//! The grammar is `slopdesk_muxsession::hook_record`; what is here is the marshalling, and the
//! marshalling is the interesting part — because nothing is marshalled.
//!
//! ## The answer is POSITIONS, so the record is never copied
//!
//! A hook body carries the tool input. A `Write` call puts hundreds of kilobytes through here,
//! twice per tool call, and the near side is already holding those bytes in the `Data` it read off
//! the socket. Delivering the JSON back through `(out, cap)` would copy the whole of it to hand the
//! caller something it never let go of. So both halves come back as OFFSETS into the record the
//! caller still owns — the same convention `detach_retention` uses one door over, for the same
//! reason from the other end: what crosses is where the answer is, not the answer.
//!
//! Two consequences worth naming. The pane id comes back as a range too, so the trim happened HERE
//! and the near side does not respell Foundation's whitespace set. And a record with no pane is an
//! ABSENT range rather than an empty one — an empty pane id and no pane header at all are different
//! records, and only one of them keeps its first line as part of the body.

use core::ffi::c_uchar;

use slopdesk_muxsession::hook_record;

use crate::borrow;

/// Where each half of a hook record is, as byte offsets into the record the caller handed in.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SlopDeskHookRecordSplit {
    /// The trimmed pane id's offset; read only when `has_pane`.
    pub pane_offset: usize,
    /// Its length in bytes; read only when `has_pane`.
    pub pane_len: usize,
    /// The hook JSON's offset. Zero when the whole record is the body, which is what a record with
    /// no recognisable `pane=` header answers.
    pub json_offset: usize,
    /// The hook JSON's length. Zero is a record that carried no body — a header and nothing else —
    /// which the parser drops on its own rather than being spared here.
    pub json_len: usize,
    /// There is a pane id. False for each of the four shapes that name none: no newline, a first
    /// line that is not `pane=`, an empty id, and an id that is not UTF-8. The router drops a
    /// record with no pane.
    pub has_pane: bool,
}

/// Splits one received record into its routing key and its body.
///
/// The record is what the drain handed over: the relay's framing with its single trailing newline
/// already stripped.
///
/// # Safety
/// `(record, len)` must be null, or name `len` initialised bytes live for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and the pointer is the caller's"
)]
pub unsafe extern "C" fn slopdesk_hook_record_split(
    record: *const c_uchar,
    len: usize,
) -> SlopDeskHookRecordSplit {
    // SAFETY: the caller's obligation, restated above; the borrow dies with this call.
    let bytes = unsafe { borrow(record, len) };
    let found = hook_record::split(bytes);
    let (pane_offset, pane_len, has_pane) = found
        .pane
        .map_or((0, 0, false), |range| (range.start, range.len(), true));
    SlopDeskHookRecordSplit {
        pane_offset,
        pane_len,
        json_offset: found.json.start,
        json_len: found.json.len(),
        has_pane,
    }
}

#[cfg(test)]
mod tests {
    #![expect(unsafe_code, reason = "calling the door is the only way to test the door")]

    use super::{SlopDeskHookRecordSplit, slopdesk_hook_record_split};

    fn split(record: &[u8]) -> SlopDeskHookRecordSplit {
        // SAFETY: `record` is a live Rust slice for the length of the call.
        unsafe { slopdesk_hook_record_split(record.as_ptr(), record.len()) }
    }

    /// The offsets have to INDEX the caller's own buffer, so the assertion is the slice they name
    /// rather than the numbers themselves.
    #[test]
    fn the_offsets_index_the_record_the_caller_still_holds() {
        let record = br#"pane=conn-1:3
{"hook_event_name":"Stop"}"#;
        let found = split(record);
        assert!(found.has_pane);
        assert_eq!(
            record.get(found.pane_offset..found.pane_offset + found.pane_len),
            Some(b"conn-1:3".as_slice())
        );
        assert_eq!(
            record.get(found.json_offset..found.json_offset + found.json_len),
            Some(br#"{"hook_event_name":"Stop"}"#.as_slice())
        );
    }

    /// An empty id and no header at all are DIFFERENT records: only the second keeps its first line
    /// as part of the body. Both answer `has_pane: false`, so the offsets are the only thing that
    /// tells them apart on the near side.
    #[test]
    fn an_empty_id_and_a_missing_header_answer_different_bodies() {
        let empty = split(b"pane=\n{}");
        assert!(!empty.has_pane);
        assert_eq!(empty.json_offset, 6, "the body starts after the header line");
        assert_eq!(empty.json_len, 2);

        let headerless = split(b"{}");
        assert!(!headerless.has_pane);
        assert_eq!(headerless.json_offset, 0, "the whole record is the body");
        assert_eq!(headerless.json_len, 2);
    }

    #[test]
    fn the_trim_happens_here_so_the_near_side_holds_no_whitespace_set() {
        let record = b"pane=  p1 \n{}";
        let found = split(record);
        assert!(found.has_pane);
        assert_eq!(
            record.get(found.pane_offset..found.pane_offset + found.pane_len),
            Some(b"p1".as_slice())
        );
    }

    #[test]
    fn a_null_record_is_an_empty_one_rather_than_a_trap() {
        // SAFETY: a null pointer with a zero length is exactly what `borrow` accepts as empty.
        let found = unsafe { slopdesk_hook_record_split(core::ptr::null(), 0) };
        assert_eq!(found, SlopDeskHookRecordSplit::default());
    }
}
