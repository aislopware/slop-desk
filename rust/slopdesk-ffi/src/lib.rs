//! `slopdesk-ffi` — what Swift calls, and nothing more.
//!
//! ## The shape of every entry point
//! Inputs are `(const uint8_t *, size_t)` pairs. The output is a `(uint8_t *out, size_t cap)` pair,
//! and the return value is how many bytes the answer NEEDS:
//!
//! | return | meaning |
//! | --- | --- |
//! | `0` | there is no answer — the wrapped function's `None` |
//! | `n <= cap` | `out[0..n]` holds the answer |
//! | `n > cap` | nothing was written; call again with at least `n` bytes |
//!
//! No allocation crosses the boundary, so there is no free function, no allocator pairing to get
//! wrong, and no leak that could be a Swift-side mistake. An undersized buffer costs a second
//! evaluation — acceptable precisely because every wrapped function is pure, so the second call
//! cannot disagree with the first.
//!
//! ## Why the `unsafe` here is small and the same every time
//! One question, repeated: is `(ptr, len)` live for the duration of this call? Swift answers it at
//! the call site with `withUnsafeBytes`, which is exactly the scope this ABI needs, and the Swift
//! wrapper is the only caller. Everything past the marshalling runs in a crate that
//! `forbid`s unsafe, so a bug in the domain logic cannot be a memory bug.
//!
//! ## Two conventions, and when the second applies
//! The above is the PURE convention and covers every function whose answer is a function of its
//! arguments. What it cannot cover is a thing that IS memory — [`replay::SlopDeskReplay`], up to
//! 256 MiB of retained PTY output appended on every chunk; [`blocks`]'s ring of command blocks;
//! [`rate_control::SlopDeskIdrPolicy`]'s token bucket — so those use the HANDLE convention
//! documented in their modules: Rust owns the object, the caller holds an opaque token, and answers
//! are still read out with `(out, cap) -> needed`. Adding a third convention is a design change,
//! not a patch.
//!
//! Which of the two a port takes is decided by the FAR side, not this one. A Swift `struct` copied
//! by value cannot be a handle without two owners silently aliasing one allocation, so it crosses
//! as a pure fold over its own state — see [`rate_control::SlopDeskQpController`]. A Swift `final
//! class` deliberately held by reference can be a handle, and should be.
//!
//! ## What must never appear in this file
//! A decision. No branch that means something, no default that encodes policy, no error mapped to
//! a different error. If a change here needs a paragraph about terminals, it is in the wrong crate:
//! move it down into the crate being wrapped, where the compiler still forbids unsafe.

pub mod abr;
pub mod adaptive_fec;
pub mod agent;
pub mod audio_jitter;
pub mod blob;
pub mod blocks;
pub mod cli;
pub mod client_gestures;
pub mod client_input;
pub mod client_jitter;
pub mod client_session;
pub mod client_view;
pub mod cursor_overlay;
pub mod cursor_wire;
pub mod decode_admission;
pub mod file_transfer;
pub mod find_matches;
pub mod folders;
pub mod frame_decoder;
pub mod frame_rate;
pub mod fuzzy;
pub mod hevc_parameter_sets;
pub mod hint_scan;
pub mod hookevent;
pub mod host_policy;
pub mod host_state;
pub mod input_box;
pub mod input_event;
pub mod input_routing;
pub mod inspector;
pub mod keybind;
pub mod link_detect;
pub mod metadata;
pub mod metadata_wire;
pub mod mint_rescue;
pub mod mux_channels;
pub mod mux_client;
pub mod mux_decoder;
pub mod mux_envelope;
pub mod mux_flow;
pub mod mux_header;
pub mod mux_host;
pub mod pacer_depth;
pub mod paste_safety;
pub mod present_queue;
pub mod rate_control;
pub mod recovery;
pub mod replay;
pub mod sanitize;
pub mod scroll_reproject;
pub mod scroll_resample;
pub mod send_pacing;
pub mod session_state;
pub mod swipe_nav_config;
pub mod swipe_recognizer;
pub mod terminal_config;
pub mod terminal_mode;
pub mod trendline;
pub mod video_control;
pub mod video_fec;
pub mod video_fragment;
pub mod video_frame;
pub mod video_packetize;
pub mod video_policy;
pub mod video_reassemble;
pub mod vimotion;
pub mod wait_scan;
pub mod watch;
pub mod window_feed;
pub mod window_feed_host;
pub mod window_placement;
pub mod wire_message;
pub mod workspace;
pub mod workspace_channel;
pub mod workspace_intent;

use std::ffi::c_uchar;

/// Borrows a caller-provided `(ptr, len)` as a slice, treating a null or empty pair as empty.
///
/// # Safety
/// `ptr` must either be null or point to `len` initialised bytes that stay live and unaliased for
/// the whole call. `len` bytes must not exceed `isize::MAX`.
#[expect(
    unsafe_code,
    reason = "this IS the boundary: a C pointer/length pair becoming a slice"
)]
pub(crate) const unsafe fn borrow<'a>(ptr: *const c_uchar, len: usize) -> &'a [u8] {
    if ptr.is_null() || len == 0 {
        return &[];
    }
    // SAFETY: the caller's obligation above is discharged by Swift's `withUnsafeBytes`, whose scope
    // is exactly this call — the wrapper in `AltScreenCut.swift` is the only caller.
    unsafe { std::slice::from_raw_parts(ptr, len) }
}

/// The low 32 bits of a length — Swift's `UInt32(truncatingIfNeeded:)`.
///
/// This and [`saturating_u32`] were FOUR copies before they were two, all four named
/// `truncating_u32` and two of them saturating instead. The name was lying at half the call sites,
/// which is the failure a shared helper exists to make impossible: the difference is unobservable
/// today (every caller's length is bounded by an MTU or the frame cap, orders of magnitude below
/// 4 GiB) and that is exactly why nobody would have noticed it becoming observable.
#[expect(
    clippy::cast_possible_truncation,
    reason = "the mask is the truncation, stated in the name"
)]
pub(crate) const fn truncating_u32(value: usize) -> u32 {
    (value & 0xFFFF_FFFF) as u32
}

/// A length widened for the wire, CLAMPED at `u32::MAX` rather than wrapped.
///
/// Kept apart from [`truncating_u32`] rather than merged into it: on the unreachable path where
/// they differ, a wrapped length makes the Swift side read a truncated payload as a complete one,
/// while a clamped one makes it ask for a buffer it cannot get. Neither is good, and picking one
/// for all four call sites would have been a behaviour change dressed as a cleanup.
pub(crate) fn saturating_u32(value: usize) -> u32 {
    u32::try_from(value).unwrap_or(u32::MAX)
}

/// One optional value, as a value plus a PRESENCE FLAG rather than a sentinel.
///
/// `docs/55` §4b is the rule — "the far side picks the convention; an absent optional crosses as a
/// value plus a presence flag, never a pointer" — and it had four copies here, one per type it was
/// needed at, each restating the same two lines for `u32`, `u64` and `f64`.
///
/// `absent` is passed rather than taken from `Default` so this can stay `const`, and because what
/// an absent value READS as on the far side is part of the convention rather than an accident: the
/// Swift face never looks at it, but a debugger does.
pub(crate) const fn optional<T: Copy>(value: Option<T>, absent: T) -> (bool, T) {
    match value {
        Some(inner) => (true, inner),
        None => (false, absent),
    }
}

/// The inverse of [`optional`] — what the Swift side's flag and value mean coming back.
pub(crate) const fn optional_of<T: Copy>(present: bool, value: T) -> Option<T> {
    if present { Some(value) } else { None }
}

/// Copies `answer` into the caller's buffer if it fits, and reports the length either way.
///
/// # Safety
/// `out` must either be null or point to `cap` writable bytes for the whole call.
#[expect(
    unsafe_code,
    reason = "writing into the caller's buffer is the other half of the boundary"
)]
pub(crate) const unsafe fn deliver(answer: &[u8], out: *mut c_uchar, cap: usize) -> usize {
    let needed = answer.len();
    if needed == 0 || needed > cap || out.is_null() {
        // Nothing written. A caller seeing `needed > cap` retries with a bigger buffer; a caller
        // seeing 0 has its answer.
        return needed;
    }
    // SAFETY: `needed <= cap` was just checked, `out` is non-null and writable for `cap` bytes by
    // the caller's obligation, and `answer` is a live Rust slice that cannot overlap it — it was
    // allocated inside this call.
    unsafe { std::ptr::copy_nonoverlapping(answer.as_ptr(), out, needed) };
    needed
}

/// Borrows a caller's record array for the duration of one call.
///
/// # Safety
/// `records` must be null, or describe `count` live entries for the call.
#[expect(
    unsafe_code,
    reason = "reconstituting the caller's array IS the boundary this module documents"
)]
pub(crate) const unsafe fn records_of<'a, T>(records: *const T, count: usize) -> &'a [T] {
    if records.is_null() || count == 0 {
        return &[];
    }
    // SAFETY: non-null and, by the caller's obligation, live for this call.
    unsafe { core::slice::from_raw_parts(records, count) }
}

/// Encodes through a LENT buffer: ONE pass both sizes and writes.
///
/// The answer is the byte count NEEDED — §4. A caller that lent too little gets the size it should
/// have lent, so the two-call shape costs one counting pass rather than a second `Vec`.
///
/// # Safety
/// `out` must be null, or writable for `cap` bytes.
#[expect(
    unsafe_code,
    reason = "reconstituting the caller's buffer IS the boundary this module documents"
)]
pub(crate) unsafe fn lend(
    out: *mut c_uchar,
    cap: usize,
    write: impl FnOnce(&mut slopdesk_wire::bytes::ByteWriter<'_>),
) -> usize {
    let mut nowhere = [];
    let room: &mut [u8] = if out.is_null() || cap == 0 {
        &mut nowhere
    } else {
        // SAFETY: non-null and, by the caller's obligation, writable for `cap` for this call.
        unsafe { core::slice::from_raw_parts_mut(out, cap) }
    };
    let mut writer = slopdesk_wire::bytes::ByteWriter::borrowing(room);
    write(&mut writer);
    writer.len()
}

/// A byte pool that answers, for each run appended, WHERE it landed.
///
/// Every door that hands Swift a list of records with text in them uses one: the records carry
/// `(offset, length)` pairs into it rather than pointers, so no record makes the caller own a
/// lifetime. Each door names its own `(offset, length)` struct, because the pair belongs to that
/// door's vocabulary — this only counts bytes.
#[derive(Debug, Default)]
pub(crate) struct TextArena(pub(crate) Vec<u8>);

impl TextArena {
    /// Appends `bytes` and answers `(offset, length)`.
    pub(crate) fn intern(&mut self, bytes: &[u8]) -> (u32, u32) {
        let offset = saturating_u32(self.0.len());
        self.0.extend_from_slice(bytes);
        (offset, saturating_u32(bytes.len()))
    }
}

/// The bytes one `(offset, length)` pair names, or empty when the pair does not fit the arena.
///
/// The inverse of [`TextArena::intern`], and it had SEVEN copies before it had one — the write half
/// was shared from the day the convention was written, the read half never was, so each door that
/// took a list back from Swift re-derived it. Two of the seven overflowed with `checked_add` and
/// three with `saturating_add`; both answer empty on this arena, but only by the accident that
/// `arena.get(start..usize::MAX)` also fails.
///
/// Never a panic: this is the direction the CALLER filled, so a wrong pair is untrusted input on
/// every door rather than a bug in this crate.
pub(crate) fn arena_span(arena: &[u8], offset: u32, length: u32) -> &[u8] {
    let start = offset as usize;
    start
        .checked_add(length as usize)
        .and_then(|end| arena.get(start..end))
        .unwrap_or_default()
}

/// One arena span as the string it holds — [`arena_span`] read as text.
///
/// Lossy ON PURPOSE, and it is the same reason at all seven sites: the bytes are the caller's, so a
/// bad sequence is not something this crate refused. That is the opposite of a decode, where
/// invalid UTF-8 means the input was malformed and the answer is `None`.
pub(crate) fn arena_text(arena: &[u8], offset: u32, length: u32) -> String {
    String::from_utf8_lossy(arena_span(arena, offset, length)).into_owned()
}

/// The escape sequence that re-opens an alt-screen segment beheaded by a front truncation.
///
/// Wraps [`slopdesk_altscreen::reopen_sequence`]. `dropped` is the prefix a ring or journal cut
/// away; `kept_head` is the start of what survived. Returns 0 when the cut did not land inside an
/// alt-screen segment, which is the common case.
///
/// # Safety
/// Both input pairs must describe live, initialised memory for the call; `out` must be writable for
/// `cap` bytes. See the module header for the full convention.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_altscreen_reopen(
    dropped: *const c_uchar,
    dropped_len: usize,
    kept_head: *const c_uchar,
    kept_head_len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations are this function's, restated on `borrow`/`deliver`; nothing
    // between them can invalidate a pointer, because the call in the middle is pure and owns its
    // own allocation.
    unsafe {
        let dropped = borrow(dropped, dropped_len);
        let kept_head = borrow(kept_head, kept_head_len);
        let Some(sequence) = slopdesk_altscreen::reopen_sequence(dropped, kept_head) else {
            return 0;
        };
        deliver(&sequence, out, cap)
    }
}

#[cfg(test)]
// The fixtures here are known-good and built inline, so `unwrap` IS the assertion, and the tests
// deliberately exercise the raw entry points the way Swift does.
#[expect(
    clippy::unwrap_used,
    clippy::indexing_slicing,
    unsafe_code,
    reason = "a panic in a test is the failure report, and calling the C ABI is the thing under test"
)]
mod tests {
    use super::slopdesk_altscreen_reopen;

    /// Calls the entry point the way the Swift wrapper does: ask, size, ask again.
    fn reopen(dropped: &[u8], kept: &[u8]) -> Option<Vec<u8>> {
        let mut buffer = [0_u8; 64];
        // SAFETY: both slices and the buffer are live locals for the duration of the call.
        let needed = unsafe {
            slopdesk_altscreen_reopen(
                dropped.as_ptr(),
                dropped.len(),
                kept.as_ptr(),
                kept.len(),
                buffer.as_mut_ptr(),
                buffer.len(),
            )
        };
        if needed == 0 {
            return None;
        }
        assert!(needed <= buffer.len(), "the fixture outgrew the probe buffer");
        Some(buffer[..needed].to_vec())
    }

    /// A cut inside an alt-screen segment re-opens it, and the answer is the wrapped crate's.
    #[test]
    fn a_cut_inside_the_alt_screen_re_opens_it() {
        let direct = slopdesk_altscreen::reopen_sequence(b"\x1b[?1049h", b"hello");
        assert_eq!(reopen(b"\x1b[?1049h", b"hello"), direct);
        assert!(direct.is_some(), "the fixture must exercise the Some path");
    }

    /// The common case answers 0, which is the ABI's `None` and must not be an empty buffer.
    #[test]
    fn a_cut_outside_the_alt_screen_answers_zero() {
        assert_eq!(reopen(b"plain output\r\n", b"more output"), None);
    }

    /// An undersized buffer reports the length and writes NOTHING — the caller's retry has to see
    /// an untouched buffer, or a partial escape sequence would reach the terminal.
    #[test]
    fn an_undersized_buffer_writes_nothing_and_reports_the_length() {
        let full = reopen(b"\x1b[?1049h", b"hello").unwrap();
        let mut tiny = [0xAA_u8; 1];
        assert!(full.len() > tiny.len(), "the fixture must not fit");
        // SAFETY: the slices and the buffer are live locals for the duration of the call.
        let needed = unsafe {
            slopdesk_altscreen_reopen(
                b"\x1b[?1049h".as_ptr(),
                8,
                b"hello".as_ptr(),
                5,
                tiny.as_mut_ptr(),
                tiny.len(),
            )
        };
        assert_eq!(needed, full.len());
        assert_eq!(
            tiny[0], 0xAA,
            "an undersized call must not write a partial answer"
        );
    }

    /// Null and empty inputs are the same thing to this ABI, so Swift may pass either without a
    /// branch of its own — an empty `Data` has no stable base address.
    #[test]
    fn a_null_input_is_read_as_empty() {
        let mut buffer = [0_u8; 64];
        // SAFETY: null is explicitly permitted by `borrow`; the buffer is a live local.
        let needed = unsafe {
            slopdesk_altscreen_reopen(
                std::ptr::null(),
                0,
                std::ptr::null(),
                0,
                buffer.as_mut_ptr(),
                buffer.len(),
            )
        };
        assert_eq!(needed, 0);
    }

    /// A null output with a zero cap is how a caller ASKS for the length before allocating.
    #[test]
    fn a_null_output_still_reports_the_length() {
        // SAFETY: the inputs are live literals; a null `out` with cap 0 is the size-query form.
        let needed = unsafe {
            slopdesk_altscreen_reopen(
                b"\x1b[?1049h".as_ptr(),
                8,
                b"hello".as_ptr(),
                5,
                std::ptr::null_mut(),
                0,
            )
        };
        assert_eq!(needed, reopen(b"\x1b[?1049h", b"hello").unwrap().len());
    }
}
