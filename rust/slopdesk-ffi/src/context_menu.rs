//! The terminal's right-click menu, in C.
//!
//! The rules are `slopdesk_terminal::context_menu`; what is here is the marshalling.
//!
//! ## The ORDER crosses separately from the WORDS
//!
//! A menu is built twice for two different reasons: once when it is constructed, from a list of
//! item indices in display order, and once per item, for the title and glyph that item wears. The
//! first answer is a handful of bytes and never changes; the second is four strings and is asked
//! once per row. Folding them into one delivery would send every word again whenever the menu is
//! rebuilt, which on a right-click is every time.
//!
//! Enablement is the third question and it is a pure SCALAR — four gates in, one bit out — because
//! it is re-asked as the menu opens, against a context that changed since the last open.

use core::ffi::c_uchar;

use slopdesk_terminal::context_menu::{self, Context, Item, LinkItem};

use crate::link_detect::kind_of;
use crate::{deliver, push_text};

/// The items the menu draws, in display order, as one byte each.
///
/// ```text
/// items × [u8 item_index]
/// ```
///
/// `paste_as` asks for the paste-as submenu's four items instead of the main menu's ten. Both are
/// non-empty, so `0` keeps its one meaning.
///
/// # Safety
/// `(out, cap)` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and `(out, cap)` is the caller's buffer"
)]
pub unsafe extern "C" fn slopdesk_term_menu_items(paste_as: bool, out: *mut c_uchar, cap: usize) -> usize {
    let items: &[Item] = if paste_as {
        &context_menu::PASTE_AS_ITEMS
    } else {
        &context_menu::ITEMS
    };
    let blob: Vec<u8> = items.iter().map(|item| item.index()).collect();
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe { deliver(&blob, out, cap) }
}

/// One item's separator and its two words, in one delivery.
///
/// ```text
/// [u8 separator_before]
/// 2 × [u32 length][UTF-8 bytes]   // the title, then the symbol name
/// ```
///
/// The separator is a property of the ITEM, not of its position: the same item opens the same
/// group wherever the list places it, which is what stops a reordering from silently moving a rule.
///
/// `0` is "there is no such item".
///
/// # Safety
/// `(out, cap)` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and `(out, cap)` is the caller's buffer"
)]
pub unsafe extern "C" fn slopdesk_term_menu_item(index: u8, out: *mut c_uchar, cap: usize) -> usize {
    let Some(item) = Item::from_index(index) else {
        return 0;
    };
    let mut blob = vec![u8::from(item.separator_before())];
    push_text(&mut blob, item.title());
    push_text(&mut blob, item.symbol());
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe { deliver(&blob, out, cap) }
}

/// Whether `index` is live in `context`.
///
/// `context` packs the four gates low bit first: a selection exists, the clipboard holds text, the
/// pane is connected, the pane has command output. An item nobody has is dead, which is the answer
/// that cannot fire a verb.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_term_menu_enabled(index: u8, context: u8) -> bool {
    Item::from_index(index).is_some_and(|item| item.is_enabled(Context::from_bits(context)))
}

/// The menu's one fixed word, in one delivery.
///
/// ```text
/// 1 × [u32 length][UTF-8 bytes]   // the paste-as submenu's title
/// ```
///
/// # Safety
/// `(out, cap)` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and `(out, cap)` is the caller's buffer"
)]
pub unsafe extern "C" fn slopdesk_term_menu_words(out: *mut c_uchar, cap: usize) -> usize {
    let mut blob = Vec::new();
    push_text(&mut blob, context_menu::PASTE_AS_SUBMENU_TITLE);
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe { deliver(&blob, out, cap) }
}

/// The verbs a link of `kind` offers, in display order, as one byte each.
///
/// ```text
/// verbs × [u8 link_item_index]
/// ```
///
/// `kind` is the same `SLOPDESK_LINK_KIND_*` constant the detector answers with, so a caller that
/// scanned a row can hand the kind straight through without a second vocabulary. A code no kind has
/// offers nothing — the honest answer for a span the detector did not produce.
///
/// # Safety
/// `(out, cap)` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and `(out, cap)` is the caller's buffer"
)]
pub unsafe extern "C" fn slopdesk_term_link_items(kind: u32, out: *mut c_uchar, cap: usize) -> usize {
    let Some(kind) = kind_of(kind) else {
        return 0;
    };
    let blob: Vec<u8> = context_menu::link_items(kind)
        .iter()
        .map(|item| item.index())
        .collect();
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe { deliver(&blob, out, cap) }
}

/// One link verb's two words, in one delivery.
///
/// ```text
/// 2 × [u32 length][UTF-8 bytes]   // the title, then the symbol name
/// ```
///
/// The title depends on the KIND — "Open Link" against a URL is "Open File" against a path — which
/// is why the kind crosses here and not only at [`slopdesk_term_link_items`].
///
/// `0` is "there is no such verb, or no such kind".
///
/// # Safety
/// `(out, cap)` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and `(out, cap)` is the caller's buffer"
)]
pub unsafe extern "C" fn slopdesk_term_link_item(
    index: u8,
    kind: u32,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    let (Some(item), Some(kind)) = (LinkItem::from_index(index), kind_of(kind)) else {
        return 0;
    };
    let mut blob = Vec::new();
    push_text(&mut blob, item.title(kind));
    push_text(&mut blob, item.symbol());
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe { deliver(&blob, out, cap) }
}

#[cfg(test)]
mod tests {
    #![expect(unsafe_code, reason = "calling the boundary IS what these tests are for")]

    use slopdesk_terminal::context_menu::{self, Context, Item, LinkItem};

    use super::{
        slopdesk_term_link_item, slopdesk_term_link_items, slopdesk_term_menu_enabled,
        slopdesk_term_menu_item, slopdesk_term_menu_items, slopdesk_term_menu_words,
    };
    use crate::link_detect::kind_code;
    use crate::testing::{delivered, runs};

    #[test]
    fn both_menus_cross_in_their_drawn_order() {
        for (paste_as, expected) in [
            (false, context_menu::ITEMS.as_slice()),
            (true, context_menu::PASTE_AS_ITEMS.as_slice()),
        ] {
            let blob = delivered(|out, cap| {
                // SAFETY: `out` is a live local for the call.
                unsafe { slopdesk_term_menu_items(paste_as, out, cap) }
            });
            let indices: Vec<u8> = expected.iter().map(|item| item.index()).collect();
            assert_eq!(blob, indices, "paste_as {paste_as}");
        }
    }

    #[test]
    fn every_item_crosses_with_its_separator_and_its_two_words() {
        for item in Item::ALL {
            let blob = delivered(|out, cap| {
                // SAFETY: `out` is a live local for the call.
                unsafe { slopdesk_term_menu_item(item.index(), out, cap) }
            });
            let (flag, rest) = blob
                .split_first()
                .map_or((0xFF, [].as_slice()), |(flag, rest)| (*flag, rest));
            assert_eq!(flag == 1, item.separator_before(), "{item:?}");
            let words = runs(rest, 2);
            assert_eq!(words.first().map(String::as_str), Some(item.title()));
            assert_eq!(words.get(1).map(String::as_str), Some(item.symbol()));
        }
    }

    /// EVERY item against EVERY context — a parity sweep over all 224 pairs.
    #[test]
    fn every_item_agrees_with_the_crate_in_every_context() {
        for item in Item::ALL {
            for bits in 0..16_u8 {
                assert_eq!(
                    slopdesk_term_menu_enabled(item.index(), bits),
                    item.is_enabled(Context::from_bits(bits)),
                    "{item:?} at {bits:#06b}",
                );
            }
        }
    }

    #[test]
    fn the_submenu_title_crosses_unchanged() {
        let blob = delivered(|out, cap| {
            // SAFETY: `out` is a live local for the call.
            unsafe { slopdesk_term_menu_words(out, cap) }
        });
        assert_eq!(
            runs(&blob, 1).first().map(String::as_str),
            Some(context_menu::PASTE_AS_SUBMENU_TITLE),
        );
    }

    /// Every link kind offers the verbs the crate offers, and every verb wears that kind's words.
    #[test]
    fn every_link_kind_crosses_with_its_own_verbs_and_their_words() {
        for kind in [
            slopdesk_terminal::link::DetectedLinkKind::AbsolutePath,
            slopdesk_terminal::link::DetectedLinkKind::TildePath,
            slopdesk_terminal::link::DetectedLinkKind::RelativePath,
            slopdesk_terminal::link::DetectedLinkKind::PathLineCol,
            slopdesk_terminal::link::DetectedLinkKind::Url,
            slopdesk_terminal::link::DetectedLinkKind::FileUrl,
        ] {
            let code = kind_code(kind);
            let blob = delivered(|out, cap| {
                // SAFETY: `out` is a live local for the call.
                unsafe { slopdesk_term_link_items(code, out, cap) }
            });
            let expected = context_menu::link_items(kind);
            let indices: Vec<u8> = expected.iter().map(|item| item.index()).collect();
            assert_eq!(blob, indices, "{kind:?}");
            for item in expected {
                let words = delivered(|out, cap| {
                    // SAFETY: `out` is a live local for the call.
                    unsafe { slopdesk_term_link_item(item.index(), code, out, cap) }
                });
                let words = runs(&words, 2);
                assert_eq!(words.first().map(String::as_str), Some(item.title(kind)));
                assert_eq!(words.get(1).map(String::as_str), Some(item.symbol()));
            }
        }
    }

    /// The kind constants and the item indices both refuse past their end.
    #[test]
    fn nothing_is_read_past_the_end() {
        let mut out = [0xAA_u8; 8];
        // SAFETY: `out` is a live local for the call.
        assert_eq!(
            unsafe { slopdesk_term_menu_item(99, out.as_mut_ptr(), out.len()) },
            0
        );
        // SAFETY: `out` is a live local for the call — 6 is the detector's NONE code.
        assert_eq!(
            unsafe { slopdesk_term_link_items(6, out.as_mut_ptr(), out.len()) },
            0
        );
        // SAFETY: `out` is a live local for the call.
        assert_eq!(
            unsafe { slopdesk_term_link_item(0, 99, out.as_mut_ptr(), out.len()) },
            0
        );
        // SAFETY: `out` is a live local for the call.
        assert_eq!(
            unsafe { slopdesk_term_link_item(99, 4, out.as_mut_ptr(), out.len()) },
            0
        );
        assert_eq!(out, [0xAA; 8], "no answer means nothing was written");
        assert!(!slopdesk_term_menu_enabled(99, 0b1111));
        assert_eq!(LinkItem::ALL.len(), 4, "the corpus this gate walks");
    }
}
