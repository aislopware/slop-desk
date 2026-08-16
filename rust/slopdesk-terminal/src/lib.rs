//! Client-side reading of the host→client terminal byte stream.
//!
//! Four things live here — the three the input surface needs to know, and what the overlays find in
//! the grid those bytes painted:
//!
//! - [`tracker`] — which screen the host is presenting (main vs alternate) and where the shell's
//!   OSC 133 command boundaries are, from a byte-at-a-time state machine that survives an escape
//!   sequence split across any chunk boundary.
//! - [`dedup`] — which bytes of the output are merely the PTY echoing back what the compose box
//!   just typed, held-and-confirmed so a byte that only shares a prefix with the expected echo is
//!   never eaten.
//! - [`inputbox`] — the two tied together: an alt-screen flip changes the compose box's whole mode
//!   and clears any half-matched echo.
//! - [`link`] — the paths, `path:line:col` diagnostics and URLs in the rendered rows, in display
//!   cells so the ⌘-hold underline, Jump-To and Hint Mode all land on the same glyph.
//! - [`blocks`] — the per-command records the host segments the stream into: their bounded ring,
//!   the status each derives, the jump-to-failed walk, and the coalescing that keeps ten clicks on
//!   one block from becoming ten wire requests.
//! - [`paste`] — what a clipboard payload would DO at a prompt, and the states in which it provably
//!   cannot run, which is the difference between a confirmation worth reading and one worth
//!   dismissing.
//!
//! ## What is guaranteed
//! - **No `unsafe`.** `#![forbid(unsafe_code)]`, so not even a downstream `allow` reintroduces it.
//! - **No panics on hostile input.** Every byte parsed here was written by whatever program holds
//!   the far side of a PTY. Indexing goes through `get`, both escape-sequence buffers are
//!   hard-capped, and a malformed stream resynchronises rather than wedging the parser.
//! - **No dependencies.** The scan is a bounded `position` over a slice; a supply chain would buy
//!   nothing a parser this small cannot do itself.
//! - **No clock and no I/O.** Everything is a fold over bytes, so a mis-parse is reproducible from
//!   a transcript.

#![forbid(unsafe_code)]

pub mod blocks;
pub mod config;
pub mod dedup;
pub mod inputbox;
pub mod keybind;
pub mod link;
pub mod mode;
pub mod paste;
pub mod tracker;
pub mod vimotion;

pub use blocks::{BlockNavigatorFilter, BlockRing, BlockStatus, CommandBlock, OutputRequests};
pub use dedup::InputDedupRing;
pub use inputbox::{Ingested, InputAffordance, InputBoxModel};
pub use link::{DetectedLink, DetectedLinkKind, LinkSchemePolicy};
pub use mode::{TerminalMode, TerminalModeEvent};
pub use tracker::TerminalModeTracker;
