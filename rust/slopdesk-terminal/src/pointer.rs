//! What the program on the far side of the PTY asked the POINTER to look like.
//!
//! Two libghostty actions, both arriving as one raw C enum value, both answering a question about
//! the cursor rather than about the grid:
//!
//! - `GHOSTTY_ACTION_MOUSE_SHAPE` — the shape a program selected with `OSC 22 ; <name> ST`, which
//!   libghostty has already parsed into `ghostty_action_mouse_shape_e`.
//! - `GHOSTTY_ACTION_MOUSE_VISIBILITY` — whether the pointer should be showing at all, which
//!   `mouse-hide-while-typing` DECIDES and then delegates to the embedder to carry out.
//!
//! ## Validate-then-drop, both times
//!
//! The input is an `i32` written by a C library across an FFI boundary, so an unknown value is a
//! real possibility — a newer libghostty, or a corrupt one. Neither answer here may trap on it, and
//! the two safe defaults are not the same:
//!
//! - An unknown SHAPE keeps the current cursor. That is also what upstream does for the shapes
//!   macOS has no native cursor for, so "unknown" and "unsupported" reach the same behaviour by the
//!   same door rather than by two rules.
//! - An unknown VISIBILITY shows the pointer. Only the explicit `hidden` value hides, read as a
//!   value rather than assumed from a `{0, 1}` layout, because the failure a wrong guess produces
//!   is a pointer stranded invisible — and there is no gesture that brings it back.
//!
//! ## What is deliberately NOT here
//!
//! The cursor itself. A [`PointerToken`] names one; turning it into an `NSCursor` is `AppKit`'s,
//! and the availability dance around the macOS-15 `columnResize`/`rowResize` cursors belongs next
//! to the drawing. What crosses is the DECISION — which of fifteen cursors, or none.

/// The pointer shape a program selected, as libghostty's `ghostty_action_mouse_shape_e`.
///
/// The values are pinned to the C enum's DECLARATION ORDER (`CGhostty/ghostty.h`), which is what
/// makes the raw `i32` meaningful without linking that header into this crate. A shape upstream has
/// no macOS cursor for still gets a name here: the table below is easier to check against
/// `setCursorShape` when both sides list the same thirty-four shapes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(i32)]
pub enum Shape {
    /// The pointer a terminal has when no program asked for anything else.
    Default = 0,
    /// `context-menu`.
    ContextMenu = 1,
    /// `help`.
    Help = 2,
    /// `pointer` — the hand.
    Pointer = 3,
    /// `progress`.
    Progress = 4,
    /// `wait`.
    Wait = 5,
    /// `cell`.
    Cell = 6,
    /// `crosshair`.
    Crosshair = 7,
    /// `text` — the I-beam.
    Text = 8,
    /// `vertical-text`.
    VerticalText = 9,
    /// `alias`.
    Alias = 10,
    /// `copy`.
    Copy = 11,
    /// `move`.
    Move = 12,
    /// `no-drop`.
    NoDrop = 13,
    /// `not-allowed`.
    NotAllowed = 14,
    /// `grab` — the open hand.
    Grab = 15,
    /// `grabbing` — the closed hand.
    Grabbing = 16,
    /// `all-scroll`.
    AllScroll = 17,
    /// `col-resize`.
    ColResize = 18,
    /// `row-resize`.
    RowResize = 19,
    /// `n-resize`.
    NResize = 20,
    /// `e-resize`.
    EResize = 21,
    /// `s-resize`.
    SResize = 22,
    /// `w-resize`.
    WResize = 23,
    /// `ne-resize`.
    NeResize = 24,
    /// `nw-resize`.
    NwResize = 25,
    /// `se-resize`.
    SeResize = 26,
    /// `sw-resize`.
    SwResize = 27,
    /// `ew-resize`.
    EwResize = 28,
    /// `ns-resize`.
    NsResize = 29,
    /// `nesw-resize`.
    NeswResize = 30,
    /// `nwse-resize`.
    NwseResize = 31,
    /// `zoom-in`.
    ZoomIn = 32,
    /// `zoom-out`.
    ZoomOut = 33,
}

impl Shape {
    /// The shape a raw `ghostty_action_mouse_shape_e` names, or `None` for a value no libghostty
    /// this code knows about emits.
    #[must_use]
    pub const fn from_raw(raw: i32) -> Option<Self> {
        // A `match` rather than a transmute, which is the whole point of the crate boundary: this
        // file is `forbid(unsafe_code)`, and a C enum arriving out of range is expected input.
        Some(match raw {
            0 => Self::Default,
            1 => Self::ContextMenu,
            2 => Self::Help,
            3 => Self::Pointer,
            4 => Self::Progress,
            5 => Self::Wait,
            6 => Self::Cell,
            7 => Self::Crosshair,
            8 => Self::Text,
            9 => Self::VerticalText,
            10 => Self::Alias,
            11 => Self::Copy,
            12 => Self::Move,
            13 => Self::NoDrop,
            14 => Self::NotAllowed,
            15 => Self::Grab,
            16 => Self::Grabbing,
            17 => Self::AllScroll,
            18 => Self::ColResize,
            19 => Self::RowResize,
            20 => Self::NResize,
            21 => Self::EResize,
            22 => Self::SResize,
            23 => Self::WResize,
            24 => Self::NeResize,
            25 => Self::NwResize,
            26 => Self::SeResize,
            27 => Self::SwResize,
            28 => Self::EwResize,
            29 => Self::NsResize,
            30 => Self::NeswResize,
            31 => Self::NwseResize,
            32 => Self::ZoomIn,
            33 => Self::ZoomOut,
            _ => return None,
        })
    }
}

/// The cursor the surface should adopt — a NAME, not a cursor.
///
/// The cases mirror ghostty's own macOS `CursorStyle`, so the resolution below can be read against
/// upstream's `setCursorShape` line for line. The values are the discriminants that cross the FFI
/// boundary, and the Swift enum that receives them is pinned to these numbers.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(i32)]
pub enum PointerToken {
    /// The ordinary arrow. Also where `Default` resets to, which is what returns the cursor after a
    /// full-screen program like `btop` or `yazi` exits back to the shell.
    Arrow = 0,
    /// The I-beam.
    Text = 1,
    /// The I-beam, rotated for vertical text.
    VerticalText = 2,
    /// The pointing hand.
    Pointer = 3,
    /// The open hand.
    Grab = 4,
    /// The closed hand.
    Grabbing = 5,
    /// The context-menu arrow.
    ContextMenu = 6,
    /// The crosshair.
    Crosshair = 7,
    /// The "operation not allowed" cursor.
    NotAllowed = 8,
    /// Resize west.
    ResizeLeft = 9,
    /// Resize east.
    ResizeRight = 10,
    /// Resize north.
    ResizeUp = 11,
    /// Resize south.
    ResizeDown = 12,
    /// Resize on the vertical axis.
    ResizeUpDown = 13,
    /// Resize on the horizontal axis.
    ResizeLeftRight = 14,
}

/// The cursor a raw shape value asks for, or `None` to KEEP the current one.
///
/// `None` covers two cases that behave identically and should: a shape macOS has no native cursor
/// for (help, progress, wait, cell, alias, copy, move, no-drop, all-scroll, the col/row/diagonal
/// resizes, the zooms) and a raw value that names no shape at all. Upstream "ignores unknown
/// shapes", and inventing a substitute for an unsupported one would be a worse answer than leaving
/// the cursor a person is already looking at.
#[must_use]
pub const fn shape_token(raw: i32) -> Option<PointerToken> {
    let Some(shape) = Shape::from_raw(raw) else {
        return None;
    };
    Some(match shape {
        Shape::Default => PointerToken::Arrow,
        Shape::Text => PointerToken::Text,
        Shape::VerticalText => PointerToken::VerticalText,
        Shape::Pointer => PointerToken::Pointer,
        Shape::Grab => PointerToken::Grab,
        Shape::Grabbing => PointerToken::Grabbing,
        Shape::ContextMenu => PointerToken::ContextMenu,
        Shape::Crosshair => PointerToken::Crosshair,
        Shape::NotAllowed => PointerToken::NotAllowed,
        Shape::WResize => PointerToken::ResizeLeft,
        Shape::EResize => PointerToken::ResizeRight,
        Shape::NResize => PointerToken::ResizeUp,
        Shape::SResize => PointerToken::ResizeDown,
        Shape::NsResize => PointerToken::ResizeUpDown,
        Shape::EwResize => PointerToken::ResizeLeftRight,
        // No native cursor — keep whatever the pointer is wearing.
        Shape::Help
        | Shape::Progress
        | Shape::Wait
        | Shape::Cell
        | Shape::Alias
        | Shape::Copy
        | Shape::Move
        | Shape::NoDrop
        | Shape::AllScroll
        | Shape::ColResize
        | Shape::RowResize
        | Shape::NeResize
        | Shape::NwResize
        | Shape::SeResize
        | Shape::SwResize
        | Shape::NeswResize
        | Shape::NwseResize
        | Shape::ZoomIn
        | Shape::ZoomOut => return None,
    })
}

/// `ghostty_action_mouse_visibility_e`'s hidden value.
const VISIBILITY_HIDDEN: i32 = 1;

/// Whether the pointer should be VISIBLE, from a raw `ghostty_action_mouse_visibility_e`.
///
/// Only the explicit hidden value hides. Every other input — the visible value, and any unknown,
/// corrupt or future one — shows the pointer, because the two failures are not symmetrical: a
/// pointer wrongly shown is a cosmetic miss during typing, and a pointer wrongly hidden is a
/// person moving a mouse they cannot see.
#[must_use]
pub const fn mouse_visible(raw: i32) -> bool {
    raw != VISIBILITY_HIDDEN
}

#[cfg(test)]
mod tests {
    use super::{PointerToken, Shape, mouse_visible, shape_token};

    /// The fifteen shapes macOS has a cursor for, against upstream's `setCursorShape`.
    #[test]
    fn every_supported_shape_resolves_to_the_cursor_upstream_picks() {
        assert_eq!(shape_token(0), Some(PointerToken::Arrow));
        assert_eq!(shape_token(1), Some(PointerToken::ContextMenu));
        assert_eq!(shape_token(3), Some(PointerToken::Pointer));
        assert_eq!(shape_token(7), Some(PointerToken::Crosshair));
        assert_eq!(shape_token(8), Some(PointerToken::Text));
        assert_eq!(shape_token(9), Some(PointerToken::VerticalText));
        assert_eq!(shape_token(14), Some(PointerToken::NotAllowed));
        assert_eq!(shape_token(15), Some(PointerToken::Grab));
        assert_eq!(shape_token(16), Some(PointerToken::Grabbing));
        assert_eq!(shape_token(20), Some(PointerToken::ResizeUp));
        assert_eq!(shape_token(21), Some(PointerToken::ResizeRight));
        assert_eq!(shape_token(22), Some(PointerToken::ResizeDown));
        assert_eq!(shape_token(23), Some(PointerToken::ResizeLeft));
        assert_eq!(shape_token(28), Some(PointerToken::ResizeLeftRight));
        assert_eq!(shape_token(29), Some(PointerToken::ResizeUpDown));
    }

    /// The compass is the half of the table that is easy to mirror: `w` is LEFT and `e` is RIGHT,
    /// and a swap would still look plausible on screen.
    #[test]
    fn the_compass_directions_are_not_mirrored() {
        assert_eq!(shape_token(Shape::WResize as i32), Some(PointerToken::ResizeLeft));
        assert_eq!(
            shape_token(Shape::EResize as i32),
            Some(PointerToken::ResizeRight)
        );
        assert_eq!(shape_token(Shape::NResize as i32), Some(PointerToken::ResizeUp));
        assert_eq!(shape_token(Shape::SResize as i32), Some(PointerToken::ResizeDown));
    }

    /// Unsupported and unknown reach the same answer, which is why the caller needs one branch.
    #[test]
    fn a_shape_with_no_cursor_and_a_value_with_no_shape_both_keep_the_current_one() {
        for unsupported in [
            2, 4, 5, 6, 10, 11, 12, 13, 17, 18, 19, 24, 25, 26, 27, 30, 31, 32, 33,
        ] {
            assert_eq!(shape_token(unsupported), None, "shape {unsupported}");
        }
        for unknown in [-1, 34, 99, i32::MIN, i32::MAX] {
            assert_eq!(shape_token(unknown), None, "raw {unknown}");
        }
    }

    /// Every shape in range names a shape — the guard against a gap opening in the table.
    #[test]
    fn the_declared_range_is_dense() {
        for raw in 0..=33 {
            assert!(Shape::from_raw(raw).is_some(), "raw {raw} names no shape");
        }
        assert_eq!(Shape::from_raw(34), None);
    }

    /// Only the explicit hidden value hides; a bad value can never strand the pointer.
    #[test]
    fn only_the_hidden_value_hides_and_everything_else_shows() {
        assert!(mouse_visible(0));
        assert!(!mouse_visible(1));
        for unknown in [-1, 2, 7, i32::MIN, i32::MAX] {
            assert!(mouse_visible(unknown), "raw {unknown} must fail safe to visible");
        }
    }
}
