//! The terminal engine, and the only place in slopdesk that touches one.
//!
//! slopdesk drives `libghostty-vt` — the renderer-agnostic half of ghostty — rather than
//! libghostty's opaque *surface* API. That is the whole architecture in one sentence, and
//! `docs/68-terminal-surface-in-rust.md` argues it at length. The short form: a surface composites
//! the entire grid into one layer and hands back pixels, so there is no seam to put a view into —
//! and blocks are layout, not decoration. Owning the grid is what makes them possible.
//!
//! ## What is here
//!
//! - [`session`] — [`VtSession`], the one owner of every engine handle. Feeds bytes, resizes,
//!   scrolls, and scans the viewport into a frame.
//! - [`events`] — the two things the far side PUSHES that nothing else can carry: the replies the
//!   terminal owes the pty, and an OSC-52 clipboard write. Held in a bounded sink until the surface
//!   drains it, so the boundary above stays a set of questions rather than a set of callbacks. The
//!   bell, the notification and the progress report are the HOST's to report, and the module says
//!   why.
//! - [`frame`] — [`Frame`], the grid flattened into plain owned data. Everything downstream reads
//!   this and never the engine.
//! - [`graphics`] — the kitty graphics protocol's images and placements, flattened the same way and
//!   for the same reason. Also the two refusals every terminal here makes about images: the file
//!   and shared-memory transmission mediums are closed, because in this app the terminal is the
//!   CLIENT and a path a remote program names would resolve on the user's own machine.
//! - [`placeholder`] — kitty's unicode-placeholder form, where an image is positioned by CELLS
//!   rather than by its placement. A decoded run rides on the row that spelled it; [`graphics`] is
//!   where a run and the placement it names meet and become an [`ImagePlacement`].
//! - [`input`] — a keystroke and a pointer gesture, encoded to the bytes the far side expects,
//!   through the engine's own encoders so the kitty protocol and mouse formats are not re-derived.
//! - [`keycode`] — the one table between an `AppKit` `NSEvent.keyCode` and a key the engine names.
//!   `AppKit` reports a *position*; the engine encodes a *key*. Nothing else can bridge the two.
//! - [`search`] — the literal matcher the engine does not ship. Regex belongs to
//!   `slopdesk_workspace::find_bar`; this is the fast path underneath it.
//! - [`selection`] — selecting text with a pointer, over the engine's own gesture state machine,
//!   and reading the result back as text. Click sequencing and drag granularity are rules about a
//!   gesture's HISTORY, which is why they are not re-derived from pointer events upstream.
//!
//! ## What is guaranteed
//!
//! - **No `unsafe`.** `#![forbid(unsafe_code)]`. Every `unsafe` this crate depends on is inside
//!   `libghostty-vt`, behind the bindings' own wrappers — and "audited" is a claim about a
//!   particular commit, not a property of the crate. It was false for the clipboard path at
//!   `Uzaaft/libghostty-rs@a0b5a46`: `ClipboardContent` built a `&str` with `from_utf8_unchecked`
//!   over an OSC 52 payload, which is base64-decoded bytes any program in the pty picks, and
//!   `ClipboardWrite::contents` sliced a null pointer for the "clear the clipboard" shape.
//!   Upstream's own issue #75 and its two `cfg(miri)` reproducers are the evidence. We build on the
//!   pinned fork that fixes both, and [`events::preferred_text`] takes the bytes and decides.
//! - **The engine never escapes.** Every handle is `!Send` and `!Sync` and upstream locks nothing.
//!   [`VtSession`] owns all of them together, so a caller cannot hold one alone, and the only thing
//!   that leaves is a [`Frame`], which is plain data.
//! - **No panics on hostile input.** The far side of a PTY is untrusted. `vt_write` is documented
//!   never to fail, indexing goes through `get`, and every conversion has a defined fallback.
//!
//! [`VtSession`]: session::VtSession
//! [`Frame`]: frame::Frame

#![forbid(unsafe_code)]

pub mod compression;
#[cfg(test)]
mod conformance;
pub mod events;
pub mod find;
pub mod frame;
pub mod graphics;
pub mod input;
pub mod keycode;
pub mod keyscript;
pub mod mousescript;
pub mod placeholder;
pub mod recording;
pub mod screen;
pub mod search;
pub mod selection;
pub mod session;

pub use compression::CompressionStep;
pub use events::{ClipboardTarget, ClipboardWrite};
pub use frame::{
    CellFlags, ColumnSpan, CursorShape, Frame, FrameCell, FrameColors, FrameCursor, FrameDirty, FrameRow,
    Rgb, RowSemantic, TextSpan, UnderlineStyle, text_cells,
};
pub use graphics::{ImageMeta, ImagePixels, ImagePlacement};
pub use input::{Key, KeyAction, KeyPress, Mods, MouseAction, MouseButton, MouseMove, OptionAsAlt};
pub use keycode::key_from_macos_keycode;
pub use placeholder::PlaceholderRun;
pub use screen::{LogicalLineText, PromptSpan, ScreenMatch, SelectionAdjust, ViewportInfo};
pub use search::{Match, Matcher, SearchQuery, search_rows};
pub use selection::{Autoscroll, ClickLadder, CopyFormat, Granularity, SurfacePoint};
pub use session::{Result, Scroll, VtError, VtSession};
