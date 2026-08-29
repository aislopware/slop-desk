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
//! arguments. What it cannot cover is a thing that IS memory — [`blocks`]'s ring of command blocks,
//! appended on every prompt mark; [`blob::SlopDeskBlobAssembler`]'s partial icons — so those use
//! the HANDLE convention documented
//! in their modules: Rust owns the object, the caller holds an opaque token, and answers are still
//! read out with `(out, cap) -> needed`. Adding a third convention is a design change, not a patch.
//!
//! Which of the two a port takes is decided by the FAR side, not this one. A Swift `struct` copied
//! by value cannot be a handle without two owners silently aliasing one allocation, so it crosses
//! as a pure fold over its own state. A Swift `final class` deliberately held by reference can be a
//! handle, and should be.
//!
//! ## What must never appear in this file
//! A decision. No branch that means something, no default that encodes policy, no error mapped to
//! a different error. If a change here needs a paragraph about terminals, it is in the wrong crate:
//! move it down into the crate being wrapped, where the compiler still forbids unsafe.

pub mod adaptive_fec;
pub mod agent;
pub mod agent_readout;
pub mod android_bridge;
pub mod android_control;
pub mod android_log_level;
pub mod android_presentation;
pub mod android_sidebar;
pub mod android_stream;
pub mod annexb;
pub mod attention_fold;
// macOS only: the Accessibility grant, which is a question about THIS PROCESS and so cannot be
// asked from a slice that has no such grant to hold. See the module.
#[cfg(target_os = "macos")]
pub mod ax;
// Apple only, both, and for the same reason `decoder`/`encoder` are: they are the audio row's other
// half. `audio_codec` is the DECODER now — the encoding half went to `rust/slopdesk-videohostd`
// with the rest of the host, and every client decodes. `audio_player` is the client's speakers and
// rides the same cfg because its `cpal` edge does.
#[cfg(any(target_os = "macos", target_os = "ios"))]
pub mod audio_codec;
#[cfg(any(target_os = "macos", target_os = "ios"))]
pub mod audio_player;
pub mod binding_config;
pub mod binding_rows;
pub mod binding_search;
pub mod blob;
pub mod block_rerun;
pub mod blocks;
pub mod channel_run;
pub mod cheat_sheet;
pub mod chip_notice;
pub mod chrome;
// Apple only, both slices, and unlike `audio_codec` above there is no half that stays behind: every
// client has a system pasteboard, so the doors are declared OUTSIDE `slopdesk_ffi.h`'s macOS-only
// region and `slopdesk-apple-pasteboard` picks the framework under them by `cfg`.
pub mod client_ctl;
pub mod client_gestures;
pub mod client_input;
pub mod client_jitter;
pub mod client_session;
pub mod client_view;
#[cfg(any(target_os = "macos", target_os = "ios"))]
pub mod clipboard;
pub mod close_confirm;
pub mod code_panel;
pub mod code_surface;
pub mod command_navigator;
pub mod config;
pub mod connect_form;
pub mod connect_gate;
pub mod connect_run;
pub mod connection;
pub mod context_menu;
pub mod control_request;
pub mod copy_receipt;
pub mod cursor_overlay;
pub mod cursor_wire;
pub mod decode_admission;
// UNGATED, and the only `slopdesk-apple-*` door left: every client decodes, so this ships on every
// slice. The encoder it used to be paired with is the host's, and the host links VideoToolbox
// directly. See the module.
pub mod decoder;
pub mod device_geometry;
pub mod device_log;
pub mod device_panel;
pub mod device_sections;
pub mod drop_action;
pub mod drop_register;
pub mod file_transfer;
pub mod find_bar;
pub mod find_matches;
pub mod folders;
pub mod fuzzy;
pub mod git_line;
pub mod global_search;
pub mod grid_geometry;
pub mod grid_readout;
pub mod gui_readout;
pub mod hid_virtual_key;
pub mod hint_overlay;
pub mod hint_scan;
pub mod input_box;
pub mod input_event;
pub mod inspector;
pub mod inspector_store;
pub mod jump_breadcrumb;
pub mod jump_to;
pub mod key_capture;
pub mod key_naming;
pub mod key_repeat;
pub mod keybind;
pub mod keystroke_replay;
pub mod link_action;
pub mod link_detect;
pub mod link_hit;
pub mod list_nav;
pub mod listen_port;
pub mod metadata;
pub mod metadata_wire;
pub mod mirror_fold;
// `mux_admission`, `mux_channels`, `mux_decoder` and `mux_envelope` were deleted with the Swift mux
// in `docs/63` G.3, and twelve of `mux_flow`'s thirteen doors went with them: 1812 lines and 36
// doors whose ONLY caller was `Sources/SlopDeskTransport/Mux`. The channel table, the admission
// rule, the framing handle, the envelope codec and the three by-value flow policies each crossed
// for one reason and no other — the connection above them was Swift. `slopdesk-clientnet` owns
// that connection now and calls all of it in-process, so `docs/55` §4b's retirement criterion
// applies literally: a handle whose far side went away. A door nothing calls is not free — it is a
// second spelling of the mux that compiles, tests green, and drifts. What survived is the flow
// CONSTANT, which is read from outside the mux; `mux_header` is not in this list at all, because
// its caller is `VideoMuxHeaderCodec.swift` and that is PATH-2.
pub mod mux_client;
pub mod mux_flow;
pub mod mux_header;
pub mod mux_transport;
pub mod new_tab_position;
pub mod notify;
pub mod notify_rate_limit;
pub mod open_quickly;
pub mod outline;
pub mod pacer_depth;
pub mod palette_card;
pub mod palette_rows;
pub mod pane_chooser;
pub mod pane_driver;
pub mod pane_drop;
pub mod pane_empty;
pub mod pane_facts;
pub mod pane_kind;
pub mod pane_session;
pub mod pane_switcher;
pub mod pane_title_freshness;
pub mod panel_key;
pub mod panel_scroll;
pub mod panel_tabs;
pub mod paste_menu;
pub mod paste_safety;
pub mod peek_reply;
pub mod phone_key;
pub mod pointer_shape;
pub mod preference;
pub mod present_queue;
pub mod prompt_flash;
pub mod rail_list;
pub mod rail_structure;
pub mod rate_control;
pub mod recovery;
pub mod remote_window;
pub mod responsive;
pub mod sanitize;
pub mod scroll_reproject;
pub mod search_rank;
pub mod session_marks;
pub mod session_template_engine;
pub mod sidebar_row;
pub mod simulator_control;
pub mod simulator_decode;
pub mod simulator_input;
pub mod simulator_presentation;
pub mod simulator_routes;
pub mod simulator_wire;
pub mod split_zoom;
pub mod state_scalars;
pub mod status_pill;
pub mod store_git_cadence;
pub mod store_rollup;
pub mod store_seed;
pub mod store_shape;
pub mod store_video_slots;
// The four `supervisor_*` modules were deleted with `Sources/SlopDeskSupervisor` in `docs/60`
// Batch B. They were 3124 lines and 29 doors whose ONLY caller was the Swift daemon hostd stopped
// being: hostd talks to superd through `slopdesk-superclient` now, in-process, with no C boundary
// in the middle. A door nothing calls is not free — it is a second spelling of the protocol that
// compiles, tests green, and drifts.
pub mod surface_gesture;
pub mod swipe_recognizer;
pub mod terminal_config;
pub mod terminal_controls;
pub mod terminal_mode;
pub mod toast;
pub mod trendline;
pub mod upload_progress;
pub mod vi_hints;
pub mod video_control;
pub mod video_fec;
pub mod video_fragment;
pub mod video_frame;
pub mod video_packetize;
pub mod video_policy;
pub mod video_reassemble;
pub mod vimotion;
pub mod watch;
pub mod window_feed;
pub mod window_rail;
pub mod window_size;
pub mod wire_message;
pub mod workspace;
pub mod workspace_channel;
pub mod workspace_intent;
pub mod workspace_key_order;
pub mod workspace_liveness;
pub mod workspace_mirror;
pub mod workspace_state_file;
pub mod workspace_templates;
pub mod wrap_map;

use std::ffi::c_uchar;

/// Borrows a caller-provided `(ptr, len)` as a slice, treating a null or empty pair as empty.
///
/// Generic in the ELEMENT because the boundary is: most doors lend bytes, and the ones that lend a
/// `#[repr(C)]` record array — the occluder scan, the display list — are lending the same thing in
/// a wider unit. One obligation, stated once.
///
/// # Safety
/// `ptr` must either be null or point to `len` initialised `T` that stay live and unaliased for the
/// whole call. `len * size_of::<T>()` must not exceed `isize::MAX`.
#[expect(
    unsafe_code,
    reason = "this IS the boundary: a C pointer/length pair becoming a slice"
)]
pub(crate) const unsafe fn borrow<'a, T>(ptr: *const T, len: usize) -> &'a [T] {
    if ptr.is_null() || len == 0 {
        return &[];
    }
    // SAFETY: the caller's obligation above is discharged by Swift's `withUnsafeBytes` /
    // `withUnsafeBufferPointer`, whose scope is exactly this call.
    unsafe { std::slice::from_raw_parts(ptr, len) }
}

/// Borrows a caller-provided `(ptr, len)` as `&str`, reading absent and unreadable as `""`.
///
/// The text half of [`borrow`], and separate from it because the failure it folds is a different
/// one: a null pair is a caller that HAS no text, while a non-UTF-8 pair is a caller whose text
/// this side cannot read. Both answer empty, because every door that lends text here treats empty
/// as "nothing to latch" — so a span that cannot be decoded latches nothing rather than latching a
/// replacement-character string that would then dedupe against itself forever.
///
/// # Safety
/// `bytes` must either be null or name `len` initialised bytes that stay live for the whole call.
#[expect(
    unsafe_code,
    reason = "this IS the boundary: a C pointer/length pair becoming a str"
)]
pub(crate) unsafe fn lent<'a>(bytes: *const c_uchar, len: usize) -> &'a str {
    // SAFETY: the caller's obligation above, discharged by the shared slice helper.
    let span = unsafe { borrow(bytes, len) };
    std::str::from_utf8(span).unwrap_or_default()
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

/// Appends one length-prefixed field to a blob: four big-endian bytes, then that many UTF-8 bytes.
///
/// The one framing every door that answers a TABLE of words uses — `docs/55` §4's plain shape,
/// repeated per field so the far side can cut the delivery with a single splitter. Big-endian
/// because this is read across a C boundary where a width that followed the target would be a bug
/// waiting for a 32-bit build.
///
/// A length that will not fit the prefix writes an EMPTY field rather than a lying one. Nothing in
/// a `&'static` table can reach four gigabytes, but a prefix that disagreed with the bytes after it
/// would desynchronise every field after it, which is a worse answer than a blank.
pub(crate) fn push_text(blob: &mut Vec<u8>, text: &str) {
    let Ok(length) = u32::try_from(text.len()) else {
        blob.extend_from_slice(&0_u32.to_be_bytes());
        return;
    };
    blob.extend_from_slice(&length.to_be_bytes());
    blob.extend_from_slice(text.as_bytes());
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

/// Copies `answer` into the caller's RECORD array if it fits, and reports the count either way.
///
/// The typed twin of [`deliver`], for a door that answers a list of `#[repr(C)]` records rather
/// than bytes. The answer is the count NEEDED — §4 — so a caller that lent too little is told what
/// to lend. It began as `window_feed_host`'s private `spill_ids`; the second door with the same
/// shape is where the convention belongs here instead.
///
/// # Safety
/// `out` must be null, or writable for `cap` `T` for the whole call.
#[expect(
    unsafe_code,
    reason = "writing into the caller's buffer is the other half of the boundary"
)]
pub(crate) const unsafe fn spill<T: Copy>(answer: &[T], out: *mut T, cap: usize) -> usize {
    let needed = answer.len();
    if needed == 0 || needed > cap || out.is_null() {
        // Nothing written. A caller seeing `needed > cap` retries with a bigger buffer.
        return needed;
    }
    // SAFETY: `needed <= cap` was just checked, `out` is non-null and writable for `cap` records by
    // the caller's obligation, and `answer` is a live Rust slice that cannot overlap it — every
    // caller builds it inside the call.
    unsafe { std::ptr::copy_nonoverlapping(answer.as_ptr(), out, needed) };
    needed
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
/// lifetime. Most doors name their own `(offset, length)` struct, because the pair belongs to that
/// door's vocabulary — this only counts bytes. [`SlopDeskByteSpan`] is the exception, for the doors
/// whose record IS the run and nothing else.
#[derive(Debug, Default)]
pub(crate) struct TextArena(pub(crate) Vec<u8>);

/// One run of bytes inside the caller's arena.
///
/// The unnamed pair, for a door whose record carries no other field to name it after — the pane
/// session's paths and the folder store's. It lived in the video host's own module until that host
/// became a Rust daemon that needs no door at all; it is here now because the two doors that still
/// speak it belong to different vocabularies and neither can own the other's.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct SlopDeskByteSpan {
    /// Where the run starts.
    pub offset: u32,
    /// How long it is.
    pub length: u32,
}

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

/// The reads every group-delivery door's tests perform, written once.
#[cfg(test)]
// `pub` rather than `pub(crate)` only because the two lints disagree otherwise: a `pub(crate)`
// item inside a private module is `redundant_pub_crate`, and a `pub` one is `unreachable_pub`.
// The module is `#[cfg(test)]`, so nothing outside a test build can see it either way.
pub mod testing;

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
