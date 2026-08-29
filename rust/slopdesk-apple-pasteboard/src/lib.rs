//! The system pasteboard — its counter, the types its owner declared, and its bytes.
//!
//! Read `docs/57-apple-frameworks-in-rust.md` §2 before adding anything: this crate turns a board
//! into values and takes values back, and decides nothing. WHICH flavour of a clip is worth
//! shipping, how large one may be, whether a concealed clip may leave the machine, and whether an
//! arriving read is the client's own push echoing back are [`slopdesk_clipboard`]'s, which forbids
//! `unsafe` and is tested against a fake board that touches no framework at all.
//!
//! ## ONE area, two frameworks, and why that is still one crate
//! The pasteboard is the area. `AppKit` spells it `NSPasteboard` and `UIKit` spells it
//! `UIPasteboard`, and every question this crate asks — the counter, the declared types, the text,
//! the image as PNG, a write that validates first — is the same question in both. A crate per
//! spelling would give a reviewer two places to hold one question, which is the thing §2's "one
//! framework area, one crate" is written to prevent; `slopdesk-apple-vt` already carries the
//! precedent from the other direction, one crate over two areas on two different slices.
//!
//! The two halves are `appkit.rs` and `uikit.rs`, selected by `cfg`, and [`Board`] is whichever one
//! this slice compiled. Nothing here is generic over the pair: a caller names [`Board`] and gets
//! the platform's, exactly the way a caller of `std::fs` does.
//!
//! ## Declared types versus content, and why both are here
//! macOS lets anything read a pasteboard's content. iOS has not since iOS 16 — an unattended read
//! raises a modal "Allow Paste?" alert, and the probes do not. So the split is a NECESSITY on one
//! half and merely the right shape on the other: [`Board::declared`] and [`Board::has_text`] answer
//! what the current owner SAID it has, which is how the concealed-clip and file-copy refusals are
//! taken without reading a byte, and [`Board::text`] / [`Board::png`] answer the bytes.
//!
//! WHEN a content read is allowed is not decided here. It is a fact about the platform's paste
//! permission and the gesture the user just made, and the caller is the one holding both.
//!
//! ## Writes validate before they clear
//! Clearing destroys whatever is on the board, so a write that can fail must fail BEFORE it runs —
//! otherwise a garbage clip arriving over the wire destroys the clip a person put there. That is
//! why [`Board::write_text`], [`Board::write_png`] and [`Board::write_image`] are whole operations
//! rather than a clear this crate exports and a set the caller remembers to order after it.
//!
//! ## Where each half is asserted
//! The `AppKit` half's suite — including `docs/57` §3's leak test — runs under `cargo test` on
//! macOS. The `UIKit` half cannot: there is no iOS host to run a cargo test on, and a simulator is
//! not one. Its assertions are the iOS test bundle's, driving the same operations through
//! `slopdesk_clipboard_*`, which is the one place in this tree that runs anything on that triple
//! (`just check-ios-tests`).

#![cfg_attr(
    not(any(target_os = "macos", target_os = "ios")),
    allow(unused_crate_dependencies)
)]

#[cfg(target_os = "macos")]
mod appkit;
#[cfg(target_os = "ios")]
mod uikit;

#[cfg(target_os = "macos")]
pub use appkit::{Board, CONCEALED_TYPE, Flavour, png_of_image};
#[cfg(target_os = "ios")]
pub use uikit::{Board, CONCEALED_TYPE, Flavour, png_of_image};
