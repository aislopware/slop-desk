//! The client's own board: what is on it, what may leave the device, and what goes back on.
//!
//! [`slopdesk_apple_pasteboard`] is the board and [`slopdesk_clipboard`] is the four rules over it;
//! this module is the boundary and nothing else. Every door here is one of those two calls with a
//! `(ptr, len)` pair reconstituted in front of it.
//!
//! ## Why every door takes a board NAME
//! The Swift face used to hold a `static let` board, chosen once: the machine's general one in the
//! app, and a per-PROCESS named one under `XCTest`, because the general pasteboard is
//! machine-global shared state and a parallel test worker — or the developer's own ⌘C mid-run —
//! clobbers whatever a suite asserts on. That choice is a fact about the Swift TEST HARNESS
//! (`NSClassFromString("XCTestCase")`), so it stays on the Swift side and arrives here as a name.
//!
//! An EMPTY name is the machine's board, which is what every shipping call passes. Re-asking for a
//! board is a lookup rather than an allocation on both platforms, so a stateless door costs nothing
//! and spares the boundary a handle whose lifetime neither side wants to own.
//!
//! ## The two answers that are bytes
//! [`slopdesk_clipboard_read`] answers `[kind byte][content]` — `docs/55` §4's plain shape, and one
//! byte is enough because the kind is the wire's own (`1` text, `2` PNG) with `0` reserved. A board
//! with nothing shippable on it answers 0 bytes, which cannot be confused with a clip: a clip is at
//! least two. [`slopdesk_clipboard_read_text`] answers the plain-text head as UTF-8, 0 bytes for a
//! board that holds something else.
//!
//! ## What is NOT here
//! Whether a content read may happen right now. On iOS an unattended read of the CONTENT raises a
//! modal "Allow Paste?" alert while the probes do not, so a tick loop must branch — but the branch
//! belongs to whoever holds the user's gesture, which is the UI.
//! [`slopdesk_clipboard_unattended_read_is_permitted`] answers the PLATFORM half of that question
//! so the Swift stops carrying a `#if` for it; WHEN to ask is still the caller's.

use std::ffi::c_uchar;

use slopdesk_apple_pasteboard::Board;
use slopdesk_clipboard::{CONCEALED_TYPE, Pasteboard, apply_clip, clip_of_text, is_syncable, shippable_clip};
use slopdesk_wire::metadata::codec::ClipboardClip;

use crate::{borrow, deliver, lent};

/// One named board, wearing the fold's trait.
///
/// A newtype because the trait and the board are in two other crates and neither may name the
/// other: the fold must build with no framework at all, and a wrapper crate holds no logic. The
/// host end carries the same twenty lines for its own board (`slopdesk_hostserver::clipsync`'s
/// `GeneralBoard`) and the two are not one type on purpose — they differ in the only thing a board
/// door decides, which is WHICH board.
#[derive(Debug)]
struct ClientBoard(Board);

impl ClientBoard {
    /// The board `name` names, or the machine's when `name` is empty.
    fn of(name: &str) -> Self {
        Self(if name.is_empty() {
            Board::general()
        } else {
            Board::named(name)
        })
    }
}

impl Pasteboard for ClientBoard {
    fn change_count(&self) -> i64 {
        self.0.change_count()
    }

    fn declared(&self) -> Vec<String> {
        self.0.declared()
    }

    fn text(&self) -> Option<String> {
        self.0.text()
    }

    fn png(&self) -> Option<Vec<u8>> {
        self.0.png()
    }

    fn write_text(&self, text: &str) -> bool {
        self.0.write_text(text)
    }

    fn write_png(&self, png: &[u8]) -> bool {
        self.0.write_png(png)
    }
}

/// Whether an UNATTENDED read of a board's CONTENT is free of a user-visible consequence.
///
/// `true` on macOS, `false` on iOS — see the module header. A door rather than a Swift `#if`
/// because it is a fact about the platform's paste permission, and the Swift that branches on it is
/// a tick loop that should carry no framework fork of its own.
#[expect(
    unsafe_code,
    reason = "an exported symbol is unsafe to declare; this door reconstitutes nothing"
)]
#[unsafe(no_mangle)]
pub const extern "C" fn slopdesk_clipboard_unattended_read_is_permitted() -> bool {
    cfg!(target_os = "macos")
}

/// The UTI a password manager marks a concealed clip with, so a Swift fixture can SEED one.
///
/// The one door here with no shipping caller, and it exists for the reason
/// `slopdesk_ws_paste_preview_limit` does: a suite that wants to prove
/// [`slopdesk_clipboard_is_syncable`] refuses a concealed board has to put a concealed clip ON a
/// board, and the only other way to spell that is a string literal in Swift — a third copy of a UTI
/// that would keep passing against a marker the fold had stopped recognising. `one-pasteboard-clip`
/// bans the literal in Swift outright, which is only a rule anybody can follow because of this.
///
/// # Safety
/// `(out, cap)` must describe live memory for the call.
#[expect(
    unsafe_code,
    reason = "reconstituting the caller's bytes IS the boundary this module documents"
)]
#[unsafe(no_mangle)]
pub const unsafe extern "C" fn slopdesk_clipboard_concealed_type(out: *mut c_uchar, cap: usize) -> usize {
    // SAFETY: the caller's obligation above.
    unsafe { deliver(CONCEALED_TYPE.as_bytes(), out, cap) }
}

/// The board's change counter, which advances on every write by anybody.
///
/// The whole of a clipboard poll, and the half of it iOS still allows: it discloses no content.
///
/// # Safety
/// `(name, name_len)` must describe live memory for the call.
#[expect(
    unsafe_code,
    reason = "reconstituting the caller's bytes IS the boundary this module documents"
)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn slopdesk_clipboard_change_count(name: *const c_uchar, name_len: usize) -> i64 {
    // SAFETY: the caller's obligation above.
    ClientBoard::of(unsafe { lent(name, name_len) }).change_count()
}

/// Whether this board's content may leave the device.
///
/// Not a concealed clip (a password manager's) and not a file copy (a path means nothing on the
/// other machine). Both answered from the DECLARED types, so neither platform prompts and no
/// content crosses — which is what lets a caller that already holds attended text still owe the
/// privacy refusal without spending a second permission.
///
/// # Safety
/// `(name, name_len)` must describe live memory for the call.
#[expect(
    unsafe_code,
    reason = "reconstituting the caller's bytes IS the boundary this module documents"
)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn slopdesk_clipboard_is_syncable(name: *const c_uchar, name_len: usize) -> bool {
    // SAFETY: the caller's obligation above.
    let board = ClientBoard::of(unsafe { lent(name, name_len) });
    is_syncable(&board.declared())
}

/// Whether the board holds plain text AT ALL, without reading it.
///
/// The ENABLEMENT question — "would a paste have anything to type?" — and the one of the pair a
/// renderer may ask on every frame, because it discloses nothing and raises no alert.
///
/// # Safety
/// `(name, name_len)` must describe live memory for the call.
#[expect(
    unsafe_code,
    reason = "reconstituting the caller's bytes IS the boundary this module documents"
)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn slopdesk_clipboard_has_text(name: *const c_uchar, name_len: usize) -> bool {
    // SAFETY: the caller's obligation above.
    ClientBoard::of(unsafe { lent(name, name_len) }).0.has_text()
}

/// The board's current shippable clip as `[kind byte][content]`, or 0 bytes for nothing to ship.
///
/// 0 for an empty board, a file copy, an over-cap clip, an image that will not transcode, and —
/// when `skipping_concealed` — a concealed one. The board is left untouched in every case.
///
/// ⚠️ A CONTENT read. See the module header on where the permission question lives.
///
/// # Safety
/// `(name, name_len)` and `(out, cap)` must describe live memory for the call.
#[expect(
    unsafe_code,
    reason = "reconstituting the caller's bytes IS the boundary this module documents"
)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn slopdesk_clipboard_read(
    name: *const c_uchar,
    name_len: usize,
    skipping_concealed: bool,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation above.
    let board = ClientBoard::of(unsafe { lent(name, name_len) });
    let Some(clip) = shippable_clip(&board, skipping_concealed) else {
        return 0;
    };
    let mut answer = Vec::with_capacity(1 + clip.bytes.len());
    answer.push(clip.kind_byte);
    answer.extend_from_slice(&clip.bytes);
    // SAFETY: the caller's obligation above.
    unsafe { deliver(&answer, out, cap) }
}

/// The board's plain-text head as UTF-8, or 0 bytes when it holds something else.
///
/// The raw read behind a "paste this into the device" path, which wants the characters rather than
/// a wire clip: no cap, no refusals, no kind byte. A caller shipping the text ANYWHERE asks
/// [`slopdesk_clipboard_is_syncable`] and [`slopdesk_clipboard_text_is_shippable`] first.
///
/// ⚠️ A CONTENT read.
///
/// # Safety
/// `(name, name_len)` and `(out, cap)` must describe live memory for the call.
#[expect(
    unsafe_code,
    reason = "reconstituting the caller's bytes IS the boundary this module documents"
)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn slopdesk_clipboard_read_text(
    name: *const c_uchar,
    name_len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation above.
    let board = ClientBoard::of(unsafe { lent(name, name_len) });
    let Some(text) = board.text() else { return 0 };
    // SAFETY: the caller's obligation above.
    unsafe { deliver(text.as_bytes(), out, cap) }
}

/// Whether text the caller ALREADY HOLDS is a clip the wire will carry.
///
/// The attended door: a platform that refuses an unattended content read gives its push half the
/// text on the paste the user asked for, and re-reading the board through
/// [`slopdesk_clipboard_read`] would spend a permission the caller already spent. It exists so that
/// path does not type the codec's cap a second time.
///
/// # Safety
/// `(text, text_len)` must describe live memory for the call.
#[expect(
    unsafe_code,
    reason = "reconstituting the caller's bytes IS the boundary this module documents"
)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn slopdesk_clipboard_text_is_shippable(text: *const c_uchar, text_len: usize) -> bool {
    // SAFETY: the caller's obligation above.
    clip_of_text(unsafe { lent(text, text_len) }).is_some()
}

/// Writes a wire clip onto the board; `false` — board UNTOUCHED — for content that will not decode.
///
/// `kind` is the wire's own byte. Non-UTF-8 text, PNG bytes that will not decode and an unknown
/// future kind are each a refusal, and every one of them is decided BEFORE anything is cleared, so
/// a garbage clip off the wire cannot destroy the clip a person put there.
///
/// # Safety
/// `(name, name_len)` and `(bytes, bytes_len)` must describe live memory for the call.
#[expect(
    unsafe_code,
    reason = "reconstituting the caller's bytes IS the boundary this module documents"
)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn slopdesk_clipboard_write(
    name: *const c_uchar,
    name_len: usize,
    kind: u8,
    bytes: *const c_uchar,
    bytes_len: usize,
) -> bool {
    // SAFETY: the caller's obligation above.
    let (board, content) = unsafe { (ClientBoard::of(lent(name, name_len)), borrow(bytes, bytes_len)) };
    apply_clip(&board, &ClipboardClip {
        kind_byte: kind,
        bytes: content.to_vec(),
    })
}

/// Replaces the board's contents with `text`; `false` — board UNTOUCHED — for empty text.
///
/// The client's one "copy" funnel. Separate from [`slopdesk_clipboard_write`] because a copy is not
/// a wire clip: it carries no kind byte and owes no cap, since nothing is shipping it anywhere.
///
/// # Safety
/// `(name, name_len)` and `(text, text_len)` must describe live memory for the call.
#[expect(
    unsafe_code,
    reason = "reconstituting the caller's bytes IS the boundary this module documents"
)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn slopdesk_clipboard_write_text(
    name: *const c_uchar,
    name_len: usize,
    text: *const c_uchar,
    text_len: usize,
) -> bool {
    // SAFETY: the caller's obligation above.
    let (board, value) = unsafe { (ClientBoard::of(lent(name, name_len)), lent(text, text_len)) };
    board.write_text(value)
}

/// Replaces the board's contents with an image in any format the system decoder reads; `false` —
/// board UNTOUCHED — for bytes that are not an image.
///
/// Format-blind because the two device panels hand it PNG and JPEG respectively and one decoder
/// reads either. Answering rather than returning nothing is what lets a caller tell "those bytes
/// were not an image" — a truncated capture, worth reporting — from "it is on the clipboard".
///
/// # Safety
/// `(name, name_len)` and `(bytes, bytes_len)` must describe live memory for the call.
#[expect(
    unsafe_code,
    reason = "reconstituting the caller's bytes IS the boundary this module documents"
)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn slopdesk_clipboard_write_image(
    name: *const c_uchar,
    name_len: usize,
    bytes: *const c_uchar,
    bytes_len: usize,
) -> bool {
    // SAFETY: the caller's obligation above.
    let (board, content) = unsafe { (ClientBoard::of(lent(name, name_len)), borrow(bytes, bytes_len)) };
    board.0.write_image(content)
}

/// Drops everything on the board.
///
/// One caller, and it is the reason the name parameter exists: a Swift suite opens its per-process
/// board and clears it before the first assertion, because a pid the system reused hands back the
/// board the LAST run of that pid left behind.
///
/// # Safety
/// `(name, name_len)` must describe live memory for the call.
#[expect(
    unsafe_code,
    reason = "reconstituting the caller's bytes IS the boundary this module documents"
)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn slopdesk_clipboard_clear(name: *const c_uchar, name_len: usize) {
    // SAFETY: the caller's obligation above.
    ClientBoard::of(unsafe { lent(name, name_len) }).0.clear();
}
