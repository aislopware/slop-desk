//! The superd control socket's framing — the reading end's half of it.
//!
//! `slopdesk_superwire` owns the layout. This is the door, and it is a PURE one: the parsers answer
//! byte offsets INTO THE CALLER'S OWN BODY, so a pane's output crosses back as a span rather than a
//! copy — which matters here more than anywhere else, since that body is up to 4 MiB of terminal
//! bytes arriving at up to a megabyte a second per pane.
//!
//! ## Why this is not Swift
//! It was, and so was superd's copy: `SupervisorFrame.swift` and `slopdesk-superd/src/frame.rs`
//! each opened by calling the other a mirror. Two hand-written spellings of one byte layout, in the
//! one place where a disagreement shows up as a DESYNCHRONISED SOCKET rather than as a wrong value.
//!
//! ## What did NOT move
//! The syscalls. `recvmsg` with `SCM_RIGHTS`, the write-until-gone loop and the read-exactly loop
//! stay in Swift, because the descriptor has to land in the reading process and the lane already
//! has a contract of its own in `slopdesk-invariants`. What crosses here is the LAYOUT: which tag,
//! how long, and what the packed bodies mean.

use core::ffi::c_uchar;

use crate::borrow;

/// The header a frame's body length is written into, and read out of.
pub const SUPERVISOR_HEADER_LEN: usize = slopdesk_superwire::HEADER_LEN;

/// A parsed pane-output or pane-JSON body, as offsets into the body the caller passed in.
///
/// `offset` is meaningful only for an output body: it is the absolute position of the first payload
/// byte in that pane's output since it was born, which is what lets a receiver detect a GAP rather
/// than splice across one silently.
#[derive(Debug, Clone, Copy, Default)]
#[repr(C)]
pub struct SlopDeskSupervisorBody {
    /// Where the pane id starts in the body. Always 2 — the id follows its own 2-byte length.
    pub pane_offset: u32,
    /// How long the pane id is.
    pub pane_len: u32,
    /// Where the payload or JSON starts.
    pub payload_offset: u32,
    /// How long it is.
    pub payload_len: u32,
    /// The absolute stream position of the first payload byte. Zero for a pane-JSON body.
    pub offset: u64,
}

/// The largest body either side will send or accept.
///
/// # Safety
/// Nothing is borrowed. The function is `unsafe` only because an exported C entry point is, in
/// edition 2024.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub const unsafe extern "C" fn slopdesk_supervisor_max_body() -> usize {
    slopdesk_superwire::MAX_BODY_BYTES
}

/// Whether `tag` is one this protocol defines.
///
/// A leading byte that is not leaves the stream desynchronised, with no marker to resynchronise on,
/// so the caller drops the connection — and closes any descriptor the kernel already installed.
///
/// # Safety
/// Nothing is borrowed. The function is `unsafe` only because an exported C entry point is, in
/// edition 2024.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub const unsafe extern "C" fn slopdesk_supervisor_is_known_tag(tag: u8) -> bool {
    slopdesk_superwire::is_known_tag(tag)
}

/// The tag a caller writes for a frame carrying no descriptor.
///
/// A door rather than a Swift constant: the tag numbering is the wire, and one side holding its own
/// copy is how the two spellings drifted apart in the first place.
///
/// # Safety
/// Nothing is borrowed. The function is `unsafe` only because an exported C entry point is, in
/// edition 2024.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub const unsafe extern "C" fn slopdesk_supervisor_tag(which: u32) -> u8 {
    match which {
        SUPERVISOR_TAG_WITH_DESCRIPTOR => slopdesk_superwire::TAG_WITH_DESCRIPTOR,
        SUPERVISOR_TAG_OUTPUT => slopdesk_superwire::TAG_OUTPUT,
        SUPERVISOR_TAG_SNIFF => slopdesk_superwire::TAG_SNIFF,
        SUPERVISOR_TAG_BLOCKS => slopdesk_superwire::TAG_BLOCKS,
        _ => slopdesk_superwire::TAG_PLAIN,
    }
}

/// Selector for [`slopdesk_supervisor_tag`] — the frame carrying no descriptor.
pub const SUPERVISOR_TAG_PLAIN: u32 = 0;
/// Selector — the frame carrying one `SCM_RIGHTS` descriptor.
pub const SUPERVISOR_TAG_WITH_DESCRIPTOR: u32 = 1;
/// Selector — the frame carrying a pane's raw output bytes.
pub const SUPERVISOR_TAG_OUTPUT: u32 = 2;
/// Selector — the frame carrying what the shell said out of band.
pub const SUPERVISOR_TAG_SNIFF: u32 = 3;
/// Selector — the frame carrying command-block changes.
pub const SUPERVISOR_TAG_BLOCKS: u32 = 4;

/// Writes the four header bytes for a body of `length` into `out`.
///
/// `false` REFUSES a length past the cap, having written nothing — a truncated length loses the
/// frame boundary, and a socket with a lost boundary never resynchronises. `false` also for an
/// `out` shorter than [`SUPERVISOR_HEADER_LEN`].
///
/// # Safety
/// `out` is null or `cap` writable bytes for the duration of this call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_supervisor_header(length: usize, out: *mut c_uchar, cap: usize) -> bool {
    let Some(header) = slopdesk_superwire::header(length) else {
        return false;
    };
    if out.is_null() || cap < header.len() {
        return false;
    }
    // SAFETY: the caller's obligation above is discharged by Swift's `withUnsafeMutableBufferPointer`,
    // whose scope is exactly this call, and `cap` was just checked against the write.
    unsafe { core::ptr::copy_nonoverlapping(header.as_ptr(), out, header.len()) };
    true
}

/// The body length a header names, or `usize::MAX` for one past the cap.
///
/// The sentinel is safe to read as a refusal because a real length can never reach it — the cap is
/// 4 MiB, and a caller comparing against [`slopdesk_supervisor_max_body`] rejects it either way.
///
/// # Safety
/// `header` is null or `len` readable bytes for the duration of this call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_supervisor_body_length(header: *const c_uchar, len: usize) -> usize {
    // SAFETY: forwarded to the caller, who owns the buffer for this call.
    let bytes = unsafe { borrow(header, len) };
    let Ok(header) = <[u8; slopdesk_superwire::HEADER_LEN]>::try_from(bytes) else {
        return usize::MAX;
    };
    slopdesk_superwire::body_length(header).unwrap_or(usize::MAX)
}

/// Parses a pane-output body — `<2B be pane-id length> <pane id> <8B be offset> <payload>`.
///
/// `false` is validate-then-drop: a body too short to hold its own header, one whose id is not
/// UTF-8, or one whose claimed id length overruns it. The peer may be an older or corrupt build.
///
/// # Safety
/// `body` is null or `len` readable bytes, and `out` is null or a writable, aligned
/// [`SlopDeskSupervisorBody`] — both for the duration of this call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_supervisor_parse_output(
    body: *const c_uchar,
    len: usize,
    out: *mut SlopDeskSupervisorBody,
) -> bool {
    // SAFETY: forwarded to the caller, who owns the buffer for this call.
    let bytes = unsafe { borrow(body, len) };
    let Some((pane, offset, payload)) = slopdesk_superwire::parse_output(bytes) else {
        return false;
    };
    let record = SlopDeskSupervisorBody {
        pane_offset: 2,
        pane_len: narrow(pane.len()),
        payload_offset: narrow(bytes.len() - payload.len()),
        payload_len: narrow(payload.len()),
        offset,
    };
    // SAFETY: forwarded to the caller, who owns the record for this call.
    unsafe { place(out, record) };
    true
}

/// Parses a pane-JSON body — `<2B be pane-id length> <pane id> <JSON>`.
///
/// The two out-of-band tags share a body shape, so they share this parse. `offset` in the record is
/// zero and carries no meaning here.
///
/// # Safety
/// `body` is null or `len` readable bytes, and `out` is null or a writable, aligned
/// [`SlopDeskSupervisorBody`] — both for the duration of this call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_supervisor_parse_pane_json(
    body: *const c_uchar,
    len: usize,
    out: *mut SlopDeskSupervisorBody,
) -> bool {
    // SAFETY: forwarded to the caller, who owns the buffer for this call.
    let bytes = unsafe { borrow(body, len) };
    let Some((pane, json)) = slopdesk_superwire::parse_pane_json(bytes) else {
        return false;
    };
    let record = SlopDeskSupervisorBody {
        pane_offset: 2,
        pane_len: narrow(pane.len()),
        payload_offset: narrow(bytes.len() - json.len()),
        payload_len: narrow(json.len()),
        offset: 0,
    };
    // SAFETY: forwarded to the caller, who owns the record for this call.
    unsafe { place(out, record) };
    true
}

/// A length that is already inside a body the cap bounds, narrowed for the field that carries it.
fn narrow(value: usize) -> u32 {
    u32::try_from(value).unwrap_or(u32::MAX)
}

/// Writes `record` through `out` when `out` is non-null.
///
/// # Safety
/// `out` is null or a writable, aligned `SlopDeskSupervisorBody` for this call.
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
const unsafe fn place(out: *mut SlopDeskSupervisorBody, record: SlopDeskSupervisorBody) {
    if !out.is_null() {
        // SAFETY: the caller's obligation above is discharged by Swift's `&record`, whose scope is
        // exactly this call.
        unsafe { *out = record };
    }
}

#[cfg(test)]
#[expect(
    clippy::unwrap_used,
    unsafe_code,
    reason = "a door that refused a known-good fixture has already failed, and calling one is unsafe"
)]
mod tests {
    use super::{
        SUPERVISOR_TAG_BLOCKS, SUPERVISOR_TAG_OUTPUT, SUPERVISOR_TAG_PLAIN, SUPERVISOR_TAG_SNIFF,
        SUPERVISOR_TAG_WITH_DESCRIPTOR, SlopDeskSupervisorBody, slopdesk_supervisor_body_length,
        slopdesk_supervisor_header, slopdesk_supervisor_is_known_tag, slopdesk_supervisor_max_body,
        slopdesk_supervisor_parse_output, slopdesk_supervisor_parse_pane_json, slopdesk_supervisor_tag,
    };

    #[test]
    fn the_tag_door_answers_the_five_the_protocol_defines() {
        let tags: Vec<u8> = [
            SUPERVISOR_TAG_PLAIN,
            SUPERVISOR_TAG_WITH_DESCRIPTOR,
            SUPERVISOR_TAG_OUTPUT,
            SUPERVISOR_TAG_SNIFF,
            SUPERVISOR_TAG_BLOCKS,
        ]
        .iter()
        // SAFETY: no pointers.
        .map(|which| unsafe { slopdesk_supervisor_tag(*which) })
        .collect();
        assert_eq!(tags, vec![1, 2, 3, 4, 5]);
        for tag in &tags {
            // SAFETY: no pointers.
            assert!(unsafe { slopdesk_supervisor_is_known_tag(*tag) });
        }
        // SAFETY: no pointers.
        assert!(unsafe { !slopdesk_supervisor_is_known_tag(0x7F) });
    }

    #[test]
    fn a_header_crosses_and_comes_back_as_the_same_length() {
        let mut header = [0_u8; 4];
        // SAFETY: `header` is a live local of the declared capacity.
        assert!(unsafe { slopdesk_supervisor_header(1234, header.as_mut_ptr(), header.len()) });
        // SAFETY: `header` is a live local.
        assert_eq!(
            unsafe { slopdesk_supervisor_body_length(header.as_ptr(), header.len()) },
            1234
        );
    }

    #[test]
    fn a_length_past_the_cap_is_refused_in_both_directions() {
        // SAFETY: no pointers.
        let cap = unsafe { slopdesk_supervisor_max_body() };
        let mut header = [0_u8; 4];
        // SAFETY: `header` is a live local of the declared capacity.
        assert!(unsafe { !slopdesk_supervisor_header(cap + 1, header.as_mut_ptr(), header.len()) });
        assert_eq!(header, [0, 0, 0, 0], "a refusal writes nothing");
        let claimed = [0xFF_u8, 0xFF, 0xFF, 0xFF];
        // SAFETY: `claimed` is a live local.
        assert_eq!(
            unsafe { slopdesk_supervisor_body_length(claimed.as_ptr(), claimed.len()) },
            usize::MAX
        );
    }

    #[test]
    fn an_undersized_header_buffer_is_refused_rather_than_written_past() {
        let mut two = [0_u8; 2];
        // SAFETY: `two` is a live local of the declared capacity.
        assert!(unsafe { !slopdesk_supervisor_header(1, two.as_mut_ptr(), two.len()) });
        assert_eq!(two, [0, 0]);
    }

    #[test]
    fn an_output_body_crosses_as_spans_into_the_callers_own_buffer() {
        let body = slopdesk_superwire::pack_output("pane-7", 99, b"hello").unwrap();
        let mut record = SlopDeskSupervisorBody::default();
        // SAFETY: `body` and `record` are live locals.
        assert!(unsafe { slopdesk_supervisor_parse_output(body.as_ptr(), body.len(), &raw mut record) });
        let pane = record.pane_offset as usize..(record.pane_offset + record.pane_len) as usize;
        let payload = record.payload_offset as usize..(record.payload_offset + record.payload_len) as usize;
        assert_eq!(body.get(pane), Some(b"pane-7".as_slice()));
        assert_eq!(body.get(payload), Some(b"hello".as_slice()));
        assert_eq!(record.offset, 99);
    }

    #[test]
    fn a_pane_json_body_crosses_the_same_way_with_no_offset() {
        let body = slopdesk_superwire::pack_pane_json("p", br#"{"events":[]}"#).unwrap();
        let mut record = SlopDeskSupervisorBody::default();
        // SAFETY: `body` and `record` are live locals.
        assert!(unsafe { slopdesk_supervisor_parse_pane_json(body.as_ptr(), body.len(), &raw mut record) });
        assert_eq!(record.pane_len, 1);
        assert_eq!(record.payload_len, 13);
        assert_eq!(record.offset, 0, "a pane-JSON body carries no stream position");
    }

    #[test]
    fn a_body_the_layout_declines_is_false_rather_than_a_half_filled_record() {
        let torn = [0_u8, 9, b'p'];
        let mut record = SlopDeskSupervisorBody {
            offset: 7,
            ..SlopDeskSupervisorBody::default()
        };
        // SAFETY: `torn` and `record` are live locals.
        assert!(unsafe { !slopdesk_supervisor_parse_output(torn.as_ptr(), torn.len(), &raw mut record) });
        assert_eq!(record.offset, 7, "a refusal leaves the caller's record untouched");
        // SAFETY: a null buffer of length zero is what `borrow` is written for.
        assert!(unsafe { !slopdesk_supervisor_parse_output(core::ptr::null(), 0, &raw mut record) });
    }
}
