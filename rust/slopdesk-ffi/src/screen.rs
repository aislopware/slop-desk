//! The screend wire's CLIENT end — requests out, replies in.
//!
//! `rust/slopdesk-screenwire` owns every layout. This is the door.
//!
//! ## Why the client end is not Swift
//! `crate::file_transfer`'s reason, and the same history. `docs/DECISIONS.md` recorded in stage 17
//! that each protocol's client end moves into Rust so the round trip becomes a TEST —
//! `what_this_end_encodes_the_other_end_decodes` — instead of an agreement two files keep by
//! review. dropd's client end moved and its Swift original was deleted. screend's moved too, and
//! its Swift original was NOT: `ScreenProtocol.swift` kept hand-writing the same frame, so the two
//! copies could only ever agree or be a bug.
//!
//! They had already diverged. Both refuse an over-long detect label, and they refused differently:
//! Swift threw, Rust truncated to the prefix's capacity. Rust's is the surviving reading, and its
//! own doc argues it — a truncation is a wrong answer where a panic is no answer at all, and no
//! manifest label is within three orders of magnitude of 64 KiB.
//!
//! ## What is NOT here
//! The verb numbers, the status numbers, the flag bits and the hello banner. Those are a
//! VOCABULARY, not a layout, and `slopdesk-invariants` already pins them across the two languages
//! the way it pins the other five daemons'. A door per constant would buy nothing the ratchet does
//! not already guarantee, and would cost a call on a path that runs per scan.
//!
//! The frame CEILING is not in that list, and the distinction is worth stating because the gate
//! script had it the other way round until 2026-08-22. It is not a vocabulary: it is a bound this
//! end ENFORCES, in both directions — a request body is measured against it before framing, and a
//! reply's length prefix is measured against it before allocating — so it is part of the same
//! layout every other rule here belongs to. The argument recorded against a door for it was that
//! "screend is a separately-shipped binary, so a door is not available", and that is true of the
//! DAEMON and was never true of hostd's client end, which has linked this crate since the client
//! end moved. `slopdesk_screen_constant` vends it, and the ratchet that compared two spellings has
//! nothing left to compare.

use core::ffi::c_uchar;

use slopdesk_screenwire::{
    LENGTH_PREFIX_LEN, MAX_FRAME, Request, Status, Verb, encode_detect_payload, encode_request,
    reply_body_length,
};

use crate::{borrow, deliver};

/// The framed bytes of one hostd→screend request, under §4's convention.
///
/// `0` means REFUSED, which a request frame's own length can never be: the fixed header alone is
/// twelve bytes. Two things are refused — a verb byte this build does not serve, and a body over
/// [`MAX_FRAME`], which screend would answer by killing the connection mid-stream rather than by
/// replying. Refusing here is what turns that into an error the caller can hold.
///
/// `rows`/`cols` are clamped into the `u16` the wire carries rather than refused: a geometry
/// outside that range is a caller bug the daemon answers with `BadRequest`, and clamping keeps the
/// answer a status byte instead of a dead socket.
///
/// # Safety
/// `pane` and `raw` must be null or point to `pane_len`/`raw_len` live bytes; `out` null or
/// writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_screen_encode_request(
    verb: u8,
    flags: u8,
    rows: u32,
    cols: u32,
    pane: *const c_uchar,
    pane_len: usize,
    raw: *const c_uchar,
    raw_len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    let Some(verb) = Verb::from_byte(verb) else {
        return 0;
    };
    // SAFETY: the caller's obligations, restated above; `borrow` states its own.
    let (pane_bytes, raw_bytes) = unsafe { (borrow(pane, pane_len), borrow(raw, raw_len)) };
    // A pane id that is not UTF-8 cannot be a pane id — the daemon decodes it back as one.
    let Ok(pane_text) = core::str::from_utf8(pane_bytes) else {
        return 0;
    };
    // The same body length the encoder is about to compute, checked BEFORE it allocates: the
    // refusal must not cost a 64 MiB copy to discover.
    if 8_usize
        .saturating_add(pane_bytes.len())
        .saturating_add(raw_bytes.len())
        > MAX_FRAME
    {
        return 0;
    }
    let frame = encode_request(&Request {
        verb,
        flags,
        rows: rows.min(u32::from(u16::MAX)) as usize,
        cols: cols.min(u32::from(u16::MAX)) as usize,
        pane: pane_text,
        raw: raw_bytes,
    });
    // SAFETY: the caller's obligation, restated above; `deliver` states its own.
    unsafe { deliver(&frame, out, cap) }
}

/// `Verb::Detect`'s verb-local payload — `u16 agent_len | agent… | bytes…` — under §4's convention.
///
/// Never `0` for a well-formed call: the length prefix alone is two bytes, so the answer is always
/// at least that. `0` means the agent label is not UTF-8, which no manifest label is.
///
/// # Safety
/// `agent` and `raw` must be null or point to `agent_len`/`raw_len` live bytes; `out` null or
/// writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_screen_encode_detect_payload(
    agent: *const c_uchar,
    agent_len: usize,
    raw: *const c_uchar,
    raw_len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; `borrow` states its own.
    let (label, bytes) = unsafe { (borrow(agent, agent_len), borrow(raw, raw_len)) };
    let Ok(label_text) = core::str::from_utf8(label) else {
        return 0;
    };
    // SAFETY: the caller's obligation, restated above; `deliver` states its own.
    unsafe { deliver(&encode_detect_payload(label_text, bytes), out, cap) }
}

/// One of this wire's size constants, by index — so neither end writes a number the other writes.
///
/// 0 the frame ceiling · 1 the length prefix's own width · 2 the fixed request header after it. An
/// index nobody defined answers `0`, which none of the three can be, so a caller asking for a
/// constant that does not exist gets an answer it cannot mistake for one that does.
///
/// Read once into a `static let` on the near side, so the crossing is a call at launch.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_screen_constant(index: u8) -> usize {
    match index {
        0 => MAX_FRAME,
        1 => LENGTH_PREFIX_LEN,
        2 => slopdesk_screenwire::HEADER_LEN,
        _ => 0,
    }
}

/// The reply body length a length prefix names, or `0` for one this end will not read.
///
/// The highest-value four bytes on this lane: they are the first thing off an untrusted stream and
/// the only lever a peer has to make the reader allocate. The rule was hand-written on the near
/// side — four `Int(bytes[i])` shifts, a `>= 1` and a re-spelled 64 MiB cap — against an encoder
/// this crate already owns, which is `docs/55` §8's shape with a parser on the exposed half.
/// `slopdesk_supervisor_body_length` is the same question one lane over.
///
/// **It is not the same SENTINEL, and that is deliberate.** The supervisor door refuses with
/// `usize::MAX` because a zero-length body is legal on that wire; here it is not — a reply is at
/// least its status byte — so `0` is free and §4 already gives it the meaning "no answer". That
/// matters more than the symmetry: Swift imports `size_t` as the SIGNED `Int`, so a `usize::MAX`
/// refusal arrives as `-1` and a caller writing the obvious `count != .max` compares it against
/// `Int.max` and lets it through. Verified by running it, not by reading it. A refusal a caller can
/// only catch by knowing that is the wrong refusal to hand across this boundary.
///
/// A prefix that is not exactly four bytes is refused the same way: a partial prefix is not a
/// length, however many bytes arrived.
///
/// # Safety
/// `prefix` must be null or point to `len` readable bytes for the duration of this call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_screen_body_length(prefix: *const c_uchar, len: usize) -> usize {
    // SAFETY: the caller's obligation, restated above; `borrow` states its own.
    let bytes = unsafe { borrow(prefix, len) };
    let Ok(prefix) = <[u8; LENGTH_PREFIX_LEN]>::try_from(bytes) else {
        return 0;
    };
    reply_body_length(prefix).unwrap_or(0)
}

/// The status a reply body names, or a negative verdict.
///
/// `0`/`1`/`2` are `Ok`/`BadRequest`/`Internal`. `-1` is an EMPTY body, which is truncated rather
/// than a status; `-2` is a byte naming no status this build knows, which is deliberately not
/// degraded to `Ok` — a status is the answer to "did my request succeed", and guessing hands the
/// caller a payload it has no reason to trust.
///
/// The payload is every byte after the first. That is the whole of the reply layout, and it is
/// stated once in `slopdesk-screenwire`.
///
/// # Safety
/// `body` must be null or point to `len` live bytes for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const unsafe extern "C" fn slopdesk_screen_reply_status(body: *const c_uchar, len: usize) -> i32 {
    // SAFETY: the caller's obligation, restated above; `borrow` states its own.
    let bytes = unsafe { borrow(body, len) };
    let Some(first) = bytes.first() else {
        return -1;
    };
    match Status::from_byte(*first) {
        Some(Status::Ok) => 0,
        Some(Status::BadRequest) => 1,
        Some(Status::Internal) => 2,
        None => -2,
    }
}

#[cfg(test)]
#[expect(
    unsafe_code,
    clippy::indexing_slicing,
    clippy::expect_used,
    reason = "calling the boundary IS what these tests are for; a fixed offset into a frame the test just \
              built is the assertion, and a panic in a test is the failure report"
)]
mod tests {
    use super::{
        slopdesk_screen_body_length, slopdesk_screen_constant, slopdesk_screen_encode_detect_payload,
        slopdesk_screen_encode_request, slopdesk_screen_reply_status,
    };

    /// The measure-then-fill convention, and the frame the daemon's own decoder reads back.
    #[test]
    fn a_request_measures_then_fills() {
        let pane = b"pane-1";
        let raw = b"\x1b[2J";
        // SAFETY: both buffers are live locals; a null `out` with `cap` 0 is the measuring call.
        let needed = unsafe {
            slopdesk_screen_encode_request(
                2,
                0x01,
                40,
                120,
                pane.as_ptr(),
                pane.len(),
                raw.as_ptr(),
                raw.len(),
                core::ptr::null_mut(),
                0,
            )
        };
        assert_eq!(needed, 4 + 8 + pane.len() + raw.len());

        let mut out = vec![0_u8; needed];
        // SAFETY: both buffers are live locals.
        let written = unsafe {
            slopdesk_screen_encode_request(
                2,
                0x01,
                40,
                120,
                pane.as_ptr(),
                pane.len(),
                raw.as_ptr(),
                raw.len(),
                out.as_mut_ptr(),
                out.len(),
            )
        };
        assert_eq!(written, needed);

        let decoded = slopdesk_screenwire::decode_request(&out[4..]).expect("the daemon reads its own wire");
        assert_eq!(decoded.pane, "pane-1");
        assert_eq!(decoded.rows, 40);
        assert_eq!(decoded.cols, 120);
        assert_eq!(decoded.raw, raw);
    }

    /// A verb this build does not serve is refused, and a refusal is `0` rather than a frame.
    #[test]
    fn an_unknown_verb_is_refused() {
        // SAFETY: null pointers with zero lengths are the documented empty case.
        let answer = unsafe {
            slopdesk_screen_encode_request(
                7, // retired, deliberately unallocated
                0,
                0,
                0,
                core::ptr::null(),
                0,
                core::ptr::null(),
                0,
                core::ptr::null_mut(),
                0,
            )
        };
        assert_eq!(answer, 0, "a retired verb never becomes a frame");
    }

    /// The detect payload's label is length-prefixed, and an empty label is a real one.
    #[test]
    fn a_detect_payload_carries_its_label_length() {
        let agent = b"claude";
        let raw = b"screen";
        let mut out = [0_u8; 32];
        // SAFETY: all three buffers are live locals.
        let written = unsafe {
            slopdesk_screen_encode_detect_payload(
                agent.as_ptr(),
                agent.len(),
                raw.as_ptr(),
                raw.len(),
                out.as_mut_ptr(),
                out.len(),
            )
        };
        assert_eq!(&out[..2], &6_u16.to_be_bytes());
        assert_eq!(&out[2..written], b"claudescreen");
    }

    /// Every status crosses as itself, and the two faults stay distinguishable from them.
    #[test]
    fn a_reply_status_is_read_or_named_as_a_fault() {
        for (byte, expected) in [(0_u8, 0_i32), (1, 1), (2, 2)] {
            let body = [byte, b'x'];
            // SAFETY: the body is a live local.
            assert_eq!(
                unsafe { slopdesk_screen_reply_status(body.as_ptr(), body.len()) },
                expected
            );
        }
        // SAFETY: a null pointer with a zero length is the documented empty case.
        assert_eq!(unsafe { slopdesk_screen_reply_status(core::ptr::null(), 0) }, -1);
        let unknown = [9_u8];
        // SAFETY: the body is a live local.
        assert_eq!(unsafe { slopdesk_screen_reply_status(unknown.as_ptr(), 1) }, -2);
    }

    /// The size family, and the refusal an undefined index gets.
    #[test]
    fn the_size_constants_are_vended_and_an_unknown_index_is_not_a_size() {
        assert_eq!(slopdesk_screen_constant(0), 64 * 1024 * 1024);
        assert_eq!(slopdesk_screen_constant(1), 4);
        assert_eq!(slopdesk_screen_constant(2), 8);
        assert_eq!(
            slopdesk_screen_constant(3),
            0,
            "no size is zero, so this cannot be read as one"
        );
        assert_eq!(slopdesk_screen_constant(u8::MAX), 0);
    }

    /// The length prefix through the raw pointers Swift uses: what the daemon's encoder wrote comes
    /// back, and every shape a hostile peer can put in four bytes answers the refusal.
    #[test]
    fn a_reply_length_is_read_or_refused_and_never_guessed() {
        let frame = slopdesk_screenwire::encode_reply(slopdesk_screenwire::Status::Ok, b"payload");
        // SAFETY: the frame is a live local.
        let declared = unsafe { slopdesk_screen_body_length(frame.as_ptr(), 4) };
        assert_eq!(declared, 8, "the status byte plus its payload");
        assert_eq!(frame.len(), 4 + declared);

        for hostile in [0_u32, 64 * 1024 * 1024 + 1, u32::MAX] {
            let bytes = hostile.to_be_bytes();
            // SAFETY: the array is a live local.
            let answer = unsafe { slopdesk_screen_body_length(bytes.as_ptr(), bytes.len()) };
            assert_eq!(answer, 0, "{hostile}");
        }
        let at_cap = (64_u32 * 1024 * 1024).to_be_bytes();
        // SAFETY: the array is a live local.
        assert_eq!(
            unsafe { slopdesk_screen_body_length(at_cap.as_ptr(), at_cap.len()) },
            64 * 1024 * 1024
        );

        // A prefix that is not four bytes is not a prefix, however many bytes arrived.
        let short = [0_u8, 0, 1];
        // SAFETY: the array is a live local.
        assert_eq!(
            unsafe { slopdesk_screen_body_length(short.as_ptr(), short.len()) },
            0
        );
        // SAFETY: a null pointer with a zero length is the documented empty case.
        assert_eq!(unsafe { slopdesk_screen_body_length(core::ptr::null(), 0) }, 0);
    }
}
