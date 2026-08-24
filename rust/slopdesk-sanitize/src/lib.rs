//! The scrollback REPLAY transform — retained PTY bytes in, the same history without the churn out.
//!
//! Seven passes over a byte stream, in an order that matters, plus the two scanners they are
//! written in. Nothing here remembers anything between calls: [`sanitize`] is a pure function, and
//! that is why it is a linked library rather than a socket verb.
//!
//! ## What it removes, and why each pass exists
//! 1. [`inputmode`] — mouse / kitty-keyboard / in-band-resize changes, so replayed history can
//!    never transiently arm a client's input reporting. FIRST, on the RAW stream: the net final
//!    state must be computed in true chronological order, and the distiller reorders it.
//! 2. [`altscreen`] — closed alt-screen segments. A TUI's drawing contributes nothing to the final
//!    display and costs tens of MiB that render as a pane "stuck inside vim". A segment still OPEN
//!    at end-of-stream is kept verbatim: that is the repaint.
//! 3. [`syncframe`] — synchronized-output frames that repaint in place, the inline-TUI counterpart
//!    of pass 2 for churn that never enters the alt screen.
//! 4. [`overprint`] — superseded revisions of a line a progress reporter overprints with `CR`.
//! 5. [`distill`] — the line-editor collapse, the one pass a caller may decline.
//! 6. [`query`] — terminal queries, echoed responses and stale colour state.
//! 7. [`prompteol`] — zsh `PROMPT_SP` clusters, whose width-dependent overprint trick surfaces
//!    stray `%` lines when history replays at a different grid width. LAST: the earlier passes only
//!    improve its adjacency anchor.
//!
//! [`plaintext`] is not one of the passes: it renders PTY bytes as the plain text a REGEX is
//! matched against, which means removing every sequence rather than only the churn. It lives here
//! because it reads the same grammar through the same scanner. [`styled`] is its counterpart for an
//! EYE rather than a pattern — the clipboard's and the preview's reading, colours kept, columns
//! rewritten — and it lives here for the same reason.
//!
//! [`boundary`] holds back the trailing half of an escape sequence the caller's own chunking cut,
//! so the reassert appended after the passes cannot land in the middle of one.
//!
//! ## What is guaranteed
//! - **No `unsafe`.** `forbid(unsafe_code)`, so not even a downstream `allow` reintroduces it.
//! - **No dependencies.** Every byte here was written by whatever program holds the far side of a
//!   PTY; a supply chain would buy nothing and cost the app's binary size. [`escape`] records the
//!   one place that reasoning was tested and held — `percent-encoding` is lenient where these two
//!   callers must refuse.
//! - **No panics on hostile input.** Indexing goes through `get`, and `indexing_slicing` is denied
//!   in this crate precisely because there is no grid here whose coordinates were already clamped.

pub mod altscreen;
pub mod boundary;
pub mod distill;
pub mod escape;
pub mod inputmode;
pub mod lines;
pub mod overprint;
pub mod plaintext;
pub mod prompteol;
pub mod query;
pub mod sanitize;
pub mod styled;
pub mod syncframe;
pub mod syncinput;
pub mod vtscan;
pub mod width;

pub use inputmode::InputModeFinalState;
pub use overprint::collapse;
pub use sanitize::{Options, sanitize};
