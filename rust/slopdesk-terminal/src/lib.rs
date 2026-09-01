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
//! - [`prompt`] — what is IN that box: the editor-like command line of `docs/68` §5.4. Multi-line
//!   text over a grapheme cursor, UAX #29 words, selection, undo that coalesces a typing run into
//!   one step, history with prefix recall and ⌃R, fuzzy completion over caller-supplied sources,
//!   and one shell lexer answering the highlight, the word under the caret and whether Enter runs
//!   anything.
//! - [`link`] — the paths, `path:line:col` diagnostics and URLs in the rendered rows, in display
//!   cells so the ⌘-hold underline, Jump-To and Hint Mode all land on the same glyph.
//! - [`blocks`] — the per-command records the host segments the stream into: their bounded ring,
//!   the status each derives, the jump-to-failed walk, and the coalescing that keeps ten clicks on
//!   one block from becoming ten wire requests.
//! - [`paste`] — what a clipboard payload would DO at a prompt, and the states in which it provably
//!   cannot run, which is the difference between a confirmation worth reading and one worth
//!   dismissing.
//! - [`controls`] — the multi-state control knobs: what each stored token means, which `ghostty`
//!   config token it becomes, and how an untrusted one repairs.
//! - [`surface`] — what a gesture MEANS before anything is sent: which clicks and keys the embedder
//!   takes for itself, and the two facts — who owns the pointer, who owns the screen — that make it
//!   step aside.
//!
//! ## What is guaranteed
//! - **No `unsafe`.** `#![forbid(unsafe_code)]`, so not even a downstream `allow` reintroduces it.
//!   Note this covers `prompt` too: an editor whose input is a paste from an untrusted clipboard is
//!   under exactly the same contract as a parser whose input is an untrusted PTY.
//! - **No panics on hostile input.** Every byte parsed here was written by whatever program holds
//!   the far side of a PTY. Indexing goes through `get`, both escape-sequence buffers are
//!   hard-capped, and a malformed stream resynchronises rather than wedging the parser.
//! - **No EXTERNAL dependencies beyond Unicode segmentation.** The scanners are bounded `position`
//!   walks over a slice; a supply chain would buy nothing a parser this small cannot do itself. The
//!   two exceptions are argued in `Cargo.toml`: `unicode-segmentation`, because a grapheme cursor
//!   is a Unicode table rather than a parser, and the sibling `slopdesk-fuzzy`, because the
//!   completion ORDER has to be the same one every other search field in the app already uses.
//! - **No clock and no I/O.** Everything is a fold over bytes, so a mis-parse is reproducible from
//!   a transcript.

#![forbid(unsafe_code)]

pub mod blocks;
pub mod config;
pub mod context_menu;
pub mod controls;
pub mod copy_receipt;
pub mod dedup;
pub mod geometry;
pub mod inputbox;
pub mod keybind;
pub mod link;
pub mod link_action;
pub mod link_hit;
pub mod mode;
pub mod paste;
pub mod prompt;
pub mod prompt_flash;
pub mod surface;
pub mod surface_action;
pub mod tracker;
pub mod vimotion;

pub use blocks::{BlockNavigatorFilter, BlockRing, BlockStatus, CommandBlock, OutputRequests};
pub use controls::{ClipboardAccess, MouseShiftCapture, OptionAsAlt, RightClickAction, SchemeDetection};
pub use dedup::InputDedupRing;
pub use inputbox::{Ingested, InputAffordance, InputBoxModel};
pub use link::{DetectedLink, DetectedLinkKind, LinkSchemePolicy};
pub use link_action::{CmdClick, CmdShiftClick, LinkAction, LinkConfig, LinkTarget, LinkTrigger};
pub use mode::{TerminalMode, TerminalModeEvent};
pub use prompt::buffer::{Direction, LineColumn, Motion, TextBuffer};
pub use prompt::complete::{Candidate, CandidateKind, CandidateProvider, CompletionRequest, Ranked};
pub use prompt::history::{CommandHistory, HistoryWalk, Recalled};
pub use prompt::syntax::{Lexed, SyntaxSpan, TokenKind, Unterminated, Word, WordRole};
pub use prompt::undo::{Edit, EditKind, UndoStack};
pub use prompt::{CommandEditor, SearchSession, Submission};
pub use tracker::TerminalModeTracker;
