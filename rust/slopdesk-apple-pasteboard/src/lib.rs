//! `NSPasteboard` — the board's counter, the types its owner declared, and its bytes.
//!
//! Read `docs/57-apple-frameworks-in-rust.md` §2 before adding anything: this crate turns a board
//! into values and takes values back, and decides nothing. WHICH flavour of a clip is worth
//! shipping, how large one may be, whether a concealed clip may leave the machine, and whether an
//! arriving read is the client's own push echoing back are `slopdesk_hostserver::clipsync`'s, which
//! forbids `unsafe` and is tested against a fake board that never touches `AppKit`.
//!
//! ## Declared types versus content, and why both are here
//! macOS lets anything read a pasteboard's content, so the split matters less here than it does on
//! the phone — but the SHAPE is the same one `SystemPasteboard` documents for iOS, and it is the
//! shape the fold above wants either way: [`Board::declared_types`] answers what the current owner
//! SAID it has, which is how the concealed-clip and file-copy refusals are taken without reading a
//! byte, and [`Board::data`] / [`Board::text`] answer the bytes.
//!
//! ## Writes validate before they clear
//! `clearContents` destroys whatever is on the board, so a write that can fail must fail BEFORE it
//! runs — otherwise a garbage clip arriving over the wire destroys the clip a person put there.
//! That is why [`Board::write_text`] and [`Board::write_png`] are whole operations rather than a
//! `clear` this crate exports and a `set` the caller remembers to order after it.
//!
//! macOS-only, with no cross-platform shape: `UIPasteboard` is a different framework with a
//! different permission model (see `SystemPasteboard`'s header), and the iOS client speaks to its
//! own board through Swift. `slopdesk-apple-power` is the precedent for a crate whose subject does
//! not exist elsewhere offering no stub to call there.

#![cfg_attr(not(target_os = "macos"), allow(unused_crate_dependencies))]

#[cfg(target_os = "macos")]
mod board;

#[cfg(target_os = "macos")]
pub use board::{Board, CONCEALED_TYPE, Flavour, png_of_tiff};
