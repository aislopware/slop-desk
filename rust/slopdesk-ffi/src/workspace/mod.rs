//! The workspace document's solvers: `rust/slopdesk-workspace` reached from the client's Swift.
//!
//! ## What crosses here, and what deliberately does not
//! `SlopDeskWorkspaceModel` is the app's DOCUMENT — 262 files import its value types. Those types
//! stay in Swift for two reasons, and the first one alone would not hold. It is the one
//! `ClaudeStatus` used (docs/55 §6): a case list a `switch` reads is a vocabulary, not an
//! implementation. The second is the only kind of veto `CLAUDE.md` recognises — a MEASURED one.
//! `WorkspaceMarshalBenchTests` ran the port this header would otherwise invite, over the shipped
//! encoder and decoder rather than a fixture, and moving the whole document per gesture costs
//! ~2.8 ms on a realistic workspace and ~12.6 ms on a hoarder's: a third of a 120 Hz frame, then a
//! missed one, for a divider drag that is otherwise a few hundred microseconds.
//!
//! So what crosses is the half that DECIDES — which neighbour "move focus left" lands on, what
//! order the sidebar's sections come in, which tab takes focus after a close. A RULE is bounded by
//! one tab; the document is not, and that is the whole of why the line is here.
//!
//! ## Everything is flat, because everything here is geometry
//! No handles and no staging: a solver takes an array of `(id, rect)` and answers rects. The
//! caller's `withUnsafeBufferPointer` scope is the whole lifetime, and there is no state to own
//! between calls. Where a solver answers a VARIABLE number of elements it uses §4's convention over
//! its element type — return the count needed, write nothing when it does not fit.
//!
//! ## The closures flatten into parallel arrays
//! Some of these rules take a `Fn(TabId) -> Option<String>` in Rust and a `(TabID) -> String?` in
//! Swift. Rather than trampoline a Swift closure back per element, the caller evaluates it once per
//! id and hands over `(id, span)` pairs into one strings blob — the same encoding the agent module
//! uses, for the same reason: one pointer, one lifetime, one scope.
//!
//! ## Floats cross unrounded, and that is load-bearing
//! `CLAUDE.md` pins this repo's float results bit-exactly: no `mul_add`, and `Double.maximum`
//! rather than a `<` ternary, because the two disagree on signed zero and NaN. A solver whose
//! answer moved by one ULP would move a pane by a subpixel on every drag frame, so the tests on the
//! Swift side compare exactly rather than within a tolerance. Nothing here rounds, clamps or
//! normalises on the way through.
//!
//! ## Why this is a DIRECTORY, and where each door lives
//! One file held all of it until 2026-09-01, and 4 900 lines is past the point where reading the
//! module costs more than reading the door. The cut follows the `// MARK:` banners that were
//! already there — [`panes`] is what a pane is HANDED, [`rows`] is what the sidebar READS,
//! [`tree`] is the split tree and every operation over it, [`codec`] is the multiclient document's
//! wire, and [`file`] is the two passes a loader runs. Nothing moved between banners and nothing
//! changed shape; the three names the rest of the crate already knew at this path — `CEntry`,
//! `TreeNode`, `DividerHandle` — are re-exported here, because a door's address is part of its
//! contract.

pub mod codec;
pub mod file;
pub mod panes;
pub mod rows;
pub mod tree;

#[cfg(test)]
mod tests;

use core::ffi::c_uchar;

/// The shapes a SIBLING module names — re-exported because the rest of the crate learned them at
/// this path before the module became a directory, and a door's address is part of its contract.
pub use codec::CEntry;
pub(crate) use file::MintedPool;
use slopdesk_ids::PaneId;
use slopdesk_tree::Rect;
pub(crate) use tree::borrow_tree;
pub use tree::{DividerHandle, TreeNode};

use crate::borrow;

// MARK: The flat shapes

/// A UUID, in its own byte order.
///
/// Both sides derive their ordering from these bytes, so anything sorted by an id sorts the same
/// way in Swift and in Rust — which matters more than it looks: `successor_after_close` walks an
/// order the caller built, and a disagreement there would send `⌘W` somewhere different per
/// process.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Uuid {
    /// The sixteen bytes, canonical UUID order.
    pub bytes: [u8; 16],
}

/// A rectangle in the plane's coordinates, laid out as Swift's `CGRect` reads it.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct CRect {
    /// The minimum x.
    pub x: f64,
    /// The minimum y.
    pub y: f64,
    /// The width, which the sanitisers floor but this struct does not.
    pub width: f64,
    /// The height.
    pub height: f64,
}

impl CRect {
    pub(crate) const fn resolve(self) -> Rect {
        Rect::xywh(self.x, self.y, self.width, self.height)
    }

    pub(crate) const fn of(rect: Rect) -> Self {
        Self {
            x: rect.origin.x,
            y: rect.origin.y,
            width: rect.size.width,
            height: rect.size.height,
        }
    }
}

/// A point in the plane's coordinates.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct CPoint {
    /// The x.
    pub x: f64,
    /// The y.
    pub y: f64,
}

/// One identified rectangle: a solved frame, a body on the plane.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct Frame {
    /// Which pane this rectangle belongs to.
    pub id: Uuid,
    /// Where it is.
    pub rect: CRect,
}

/// A slice of the caller's strings blob: `present == false` is Swift's `nil`, and a present span of
/// length 0 is an empty string, which is not the same question.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct Span {
    /// Where the text starts in the blob.
    pub offset: usize,
    /// How many bytes it runs for.
    pub len: usize,
    /// Whether there is any text at all.
    pub present: bool,
}

/// A tab and the project key the caller's closure answered for it.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct KeyedTab {
    /// Which tab.
    pub id: Uuid,
    /// Its project key, into the blob passed alongside.
    pub key: Span,
}

/// A pane and the project key the caller's closure answered for it.
///
/// The same two fields as [`KeyedTab`] and deliberately not the same type: a close rule reads a
/// TAB's key and the intent applier reads a PANE's, the two ids name different objects, and a
/// struct whose name says "tab" would let one be passed where the other belongs with nothing but a
/// comment to catch it.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct KeyedPane {
    /// Which pane.
    pub id: Uuid,
    /// Its project key, into the blob passed alongside.
    pub key: Span,
}

/// Borrows a caller's array for one call.
///
/// # Safety
/// `items` must be null, or point to `count` initialised `T`s live for the call.
#[expect(
    unsafe_code,
    reason = "this IS the boundary: a C array pointer becoming a slice"
)]
pub(crate) const unsafe fn borrow_array<'a, T>(items: *const T, count: usize) -> &'a [T] {
    if items.is_null() || count == 0 {
        return &[];
    }
    // SAFETY: non-null, and by the caller's obligation live and initialised for `count` elements.
    unsafe { core::slice::from_raw_parts(items, count) }
}

/// Resolves a span against the blob it indexes.
///
/// Out of range reads as `None` rather than panicking, and so does non-UTF-8: a span arrives from
/// another process's memory, and the only safe reading of a nonsensical one is "no key".
pub(crate) fn text_of(span: Span, blob: &[u8]) -> Option<&str> {
    if !span.present {
        return None;
    }
    let end = span.offset.checked_add(span.len)?;
    core::str::from_utf8(blob.get(span.offset..end)?).ok()
}

/// Reads an optional string argument: absent, or non-UTF-8, both read as `None`.
///
/// # Safety
/// `bytes` must be null or point to `len` initialised bytes live for the call.
#[expect(
    unsafe_code,
    reason = "this IS the boundary: a C pointer/length pair becoming a slice"
)]
unsafe fn optional_str<'a>(bytes: *const c_uchar, len: usize, present: bool) -> Option<&'a str> {
    if !present {
        return None;
    }
    // SAFETY: the caller's obligation, restated above; `borrow` states its own.
    core::str::from_utf8(unsafe { borrow(bytes, len) }).ok()
}

/// Writes an id answer, tolerating a caller that only wanted the yes-or-no.
///
/// # Safety
/// `answer` must be null or writable for one [`Uuid`] for the call.
#[expect(
    unsafe_code,
    reason = "this IS the boundary: writing through a caller's pointer"
)]
unsafe fn deliver_id(found: [u8; 16], answer: *mut Uuid) -> bool {
    if !answer.is_null() {
        // SAFETY: non-null and, by the caller's obligation, writable for one `Uuid` for this call.
        unsafe { *answer = Uuid { bytes: found } };
    }
    true
}

/// A pane identity from its bytes.
const fn pane_id(id: Uuid) -> PaneId {
    PaneId::from_bytes(id.bytes)
}
