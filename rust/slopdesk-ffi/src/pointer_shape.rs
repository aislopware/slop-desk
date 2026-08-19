//! The two pointer actions libghostty delegates to the embedder.
//!
//! [`slopdesk_terminal::pointer`] owns both tables; this is the door. Neither call touches memory,
//! so both are the §4 convention's degenerate case: one scalar in, one scalar out, nothing to size
//! and nothing to free.
//!
//! ## Why the raw value crosses, and not a parsed one
//! The input is a `ghostty_action_mouse_shape_e` / `ghostty_action_mouse_visibility_e` that the C
//! callback already has in hand. Parsing it Swift-side first would mean a Swift enum mirroring the
//! C one — which is what this port DELETED, because that mirror is a third copy of a table whose
//! first two already have to agree. The raw `int32_t` travels, and the crate that owns the meaning
//! validates it.

use slopdesk_terminal::pointer::{mouse_visible, shape_token};

/// The answer that means KEEP the cursor the pointer is already wearing.
///
/// A negative sentinel rather than a `bool` out-parameter, because every real token is a small
/// non-negative discriminant and "no change" is not an error — it is the commonest answer of all
/// (nineteen of the thirty-four shapes, plus every unknown value).
pub const SLOPDESK_POINTER_TOKEN_NONE: i32 = -1;

/// The cursor a raw `ghostty_action_mouse_shape_e` asks for, or [`SLOPDESK_POINTER_TOKEN_NONE`].
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub extern "C" fn slopdesk_pointer_shape_token(raw: i32) -> i32 {
    shape_token(raw).map_or(SLOPDESK_POINTER_TOKEN_NONE, |token| token as i32)
}

/// Whether the pointer should be VISIBLE, from a raw `ghostty_action_mouse_visibility_e`.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub const extern "C" fn slopdesk_pointer_mouse_visible(raw: i32) -> bool {
    mouse_visible(raw)
}

#[cfg(test)]
mod tests {
    use super::{SLOPDESK_POINTER_TOKEN_NONE, slopdesk_pointer_mouse_visible, slopdesk_pointer_shape_token};

    /// The discriminants the Swift enum is pinned to. Asserted through the DOOR rather than against
    /// the Rust enum, because the number Swift receives is the number this function returns.
    #[test]
    fn the_supported_shapes_cross_as_the_discriminants_swift_is_pinned_to() {
        assert_eq!(slopdesk_pointer_shape_token(0), 0); // default  → arrow
        assert_eq!(slopdesk_pointer_shape_token(8), 1); // text     → text
        assert_eq!(slopdesk_pointer_shape_token(9), 2); // vertical → verticalText
        assert_eq!(slopdesk_pointer_shape_token(3), 3); // pointer  → pointer
        assert_eq!(slopdesk_pointer_shape_token(15), 4); // grab     → grab
        assert_eq!(slopdesk_pointer_shape_token(16), 5); // grabbing → grabbing
        assert_eq!(slopdesk_pointer_shape_token(1), 6); // context  → contextMenu
        assert_eq!(slopdesk_pointer_shape_token(7), 7); // crosshair
        assert_eq!(slopdesk_pointer_shape_token(14), 8); // not-allowed
        assert_eq!(slopdesk_pointer_shape_token(23), 9); // w-resize  → resizeLeft
        assert_eq!(slopdesk_pointer_shape_token(21), 10); // e-resize  → resizeRight
        assert_eq!(slopdesk_pointer_shape_token(20), 11); // n-resize  → resizeUp
        assert_eq!(slopdesk_pointer_shape_token(22), 12); // s-resize  → resizeDown
        assert_eq!(slopdesk_pointer_shape_token(29), 13); // ns-resize → resizeUpDown
        assert_eq!(slopdesk_pointer_shape_token(28), 14); // ew-resize → resizeLeftRight
    }

    #[test]
    fn an_unsupported_or_unknown_shape_crosses_as_the_keep_sentinel() {
        assert_eq!(slopdesk_pointer_shape_token(5), SLOPDESK_POINTER_TOKEN_NONE);
        assert_eq!(slopdesk_pointer_shape_token(33), SLOPDESK_POINTER_TOKEN_NONE);
        assert_eq!(slopdesk_pointer_shape_token(34), SLOPDESK_POINTER_TOKEN_NONE);
        assert_eq!(slopdesk_pointer_shape_token(-7), SLOPDESK_POINTER_TOKEN_NONE);
    }

    #[test]
    fn only_the_hidden_value_hides() {
        assert!(slopdesk_pointer_mouse_visible(0));
        assert!(!slopdesk_pointer_mouse_visible(1));
        assert!(slopdesk_pointer_mouse_visible(2));
        assert!(slopdesk_pointer_mouse_visible(-1));
    }
}
