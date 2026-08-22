//! One option group's choices, in C.
//!
//! The rules are `slopdesk_settings::settings_catalog`; what is here is the marshalling.
//!
//! ## A GROUP crosses, because a group is what the caller asked for
//!
//! This was five doors addressed positionally — a count, then a token, a label, a caption and a
//! menu label per option — and the near side's only reader of any of them was
//! `SettingsCatalog.tokens(_:)`, which builds the WHOLE group. So naming one token cost `1 + 4n`
//! crossings, and every face above it (`options(_:as:)`, `stringOptions(_:)`, `label(_:for:)`) paid
//! that price to read one field. Twenty-three groups holding sixty-seven options between them came
//! to 291 crossings for a table that is `&'static` on this side.
//!
//! Worse, the readers are `SwiftUI` bodies. The phone's all-settings list calls `stringOptions`
//! from inside a `ForEach` over its matched rows, and that view declares ~55 `@Default` wrappers,
//! so any settings write anywhere on the page re-ran the walk — as did every keystroke in its
//! search field. `slopdesk_settings_layout_page` had already made this argument for a page; this is
//! the same argument one level in, and it is the argument `slopdesk_settings_row_fields` made for a
//! row.
//!
//! One door now answers with the group: the count, then every string every option needs, in ONE
//! `(out, cap)` delivery under `docs/55` §4's retry protocol.
//!
//! ## The layout
//!
//! All lengths are big-endian, because this is read across a C boundary where a width that followed
//! the target would be a bug waiting for a 32-bit build.
//!
//! ```text
//! [u16 option_count]
//! option_count × 4 × [u32 length][UTF-8 bytes]
//! ```
//!
//! The four fields per option are `token`, `label`, `caption`, `menu_label`, in that order, options
//! in render order. Their number is derivable from the header, which is what lets the near side cut
//! them with the length-prefixed splitter it already uses for `slopdesk_settings_layout_page` and
//! PAD to the count the header promised: a delivery that came up short is a layout disagreement
//! between the two sides, and padding is what stops it becoming a silent off-by-one where every
//! option after the gap wears its neighbour's words.
//!
//! **A zero-length caption is NO caption.** That is the reading the deleted `…option_caption` door
//! already had — it answered an absent caveat and an empty one with the same zero-length delivery —
//! so keeping the conflation is what makes this a marshalling change and not a behaviour one. It is
//! the opposite of §4b's presence-flag rule for the reason `settings_layout` states: a caption that
//! is empty and a caption that is missing render identically, so a flag would name a distinction
//! nothing downstream can act on.
//!
//! ## `0` is no such GROUP, never an empty one
//!
//! A group with no options would still deliver its two-byte header, so §4's `0` keeps its literal
//! meaning here: there is no group at that index. Nothing in the table is empty either —
//! `every_group_is_non_empty_and_its_tokens_are_unique` in the wrapped crate is what says so — but
//! the encoding does not lean on that.

use core::ffi::c_uchar;

use slopdesk_settings::settings_catalog::{self, Group};

use crate::deliver;

/// Appends one length-prefixed field: four big-endian bytes, then that many UTF-8 bytes.
///
/// A length that will not fit the prefix writes an EMPTY field rather than a lying one. Nothing in
/// a `&'static` table can reach four gigabytes, but a prefix that disagreed with the bytes after it
/// would desynchronise every field in the rest of the group, which is a worse answer than a blank.
fn push_text(blob: &mut Vec<u8>, text: &str) {
    let Ok(length) = u32::try_from(text.len()) else {
        blob.extend_from_slice(&0_u32.to_be_bytes());
        return;
    };
    blob.extend_from_slice(&length.to_be_bytes());
    blob.extend_from_slice(text.as_bytes());
}

/// Every choice in one option group, in render order, in one delivery.
///
/// The layout is the module header's. `0` is "there is no such group" — a group index no group has
/// — and a return larger than `cap` means nothing was written, so the caller asks again at that
/// size.
///
/// # Safety
/// `(out, cap)` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and `(out, cap)` is the caller's buffer"
)]
pub unsafe extern "C" fn slopdesk_settings_option_group(group: u8, out: *mut c_uchar, cap: usize) -> usize {
    let Some(id) = Group::from_index(group) else {
        return 0;
    };
    let rows = settings_catalog::group(id);
    // A count that will not fit its prefix would make the reader walk a group that is not the one
    // this call encoded, so it is refused whole. No table this crate can hold comes near it.
    let Ok(count) = u16::try_from(rows.len()) else {
        return 0;
    };
    let mut blob = Vec::new();
    blob.extend_from_slice(&count.to_be_bytes());
    for row in rows {
        push_text(&mut blob, row.token);
        push_text(&mut blob, row.label);
        push_text(&mut blob, row.caption);
        // COMPOSED on this side, as it was when it had a door of its own: where the en dash goes and
        // what a captionless row reads as are a rule, and a rule spelled in two languages is two.
        push_text(&mut blob, &row.menu_label());
    }
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe { deliver(&blob, out, cap) }
}

#[cfg(test)]
mod tests {
    #![expect(unsafe_code, reason = "calling the boundary IS what these tests are for")]
    #![expect(
        clippy::indexing_slicing,
        reason = "walking the group by the offsets its own header names is what the near side does; an \
                  index past the end here IS the failure report, and softening it to a default would let a \
                  truncated delivery read as an empty group and pass"
    )]

    use slopdesk_settings::settings_catalog::{self, Group};

    use super::slopdesk_settings_option_group;

    /// `SettingsCatalog.inlineCapacity` on the near side. Pinned here rather than there because
    /// this is the side that can measure it: a group that outgrew the guess would still be
    /// correct — §4's retry would fetch it — but it would pay two crossings for the answer this
    /// port exists to deliver in one, and nothing on the Swift side would say so.
    const SWIFT_FIRST_GUESS: usize = 1024;

    /// One delivery of one group, at a capacity generous enough that the retry is never travelled.
    fn delivered(group: u8) -> Vec<u8> {
        let mut out = vec![0_u8; 1 << 16];
        // SAFETY: `out` is a live local for the call.
        let needed = unsafe { slopdesk_settings_option_group(group, out.as_mut_ptr(), out.len()) };
        assert!(needed <= out.len(), "a group outgrew the test's buffer");
        out.get(..needed).unwrap_or_default().to_vec()
    }

    /// One option as the near side reads it back.
    #[derive(PartialEq, Eq, Debug)]
    struct Option4 {
        token: String,
        label: String,
        caption: String,
        menu_label: String,
    }

    /// The delivery, cut back into the options it encodes — the walk the near side performs,
    /// written once here so a test can assert against it.
    fn walk(blob: &[u8]) -> Vec<Option4> {
        let count = usize::from(blob[0]) << 8 | usize::from(blob[1]);
        let mut fields = Vec::new();
        let mut cursor = 2;
        while cursor + 4 <= blob.len() {
            let length = blob[cursor..cursor + 4]
                .iter()
                .fold(0_usize, |acc, byte| acc << 8 | usize::from(*byte));
            cursor += 4;
            fields.push(String::from_utf8_lossy(&blob[cursor..cursor + length]).into_owned());
            cursor += length;
        }
        assert_eq!(cursor, blob.len(), "the walk must land exactly on the end");
        assert_eq!(
            fields.len(),
            count * 4,
            "the header promised a field count the run did not carry"
        );
        (0..count)
            .map(|index| {
                Option4 {
                    token: fields[index * 4].clone(),
                    label: fields[index * 4 + 1].clone(),
                    caption: fields[index * 4 + 2].clone(),
                    menu_label: fields[index * 4 + 3].clone(),
                }
            })
            .collect()
    }

    /// EVERY option of EVERY group agrees with the table the deleted per-index doors read one field
    /// at a time.
    ///
    /// `settings_catalog::group` and `OptionRow::menu_label` ARE what those five doors called, so
    /// this is the parity assertion they would have supported, over the whole corpus rather than
    /// one probe. It walks `Group::ALL`'s indices rather than naming cases, so a twenty-fourth
    /// group is covered the day it is added — `docs/55` §8's "a vocabulary pin needs a COUNT as
    /// well as a map".
    #[test]
    fn every_option_of_every_group_matches_the_table_the_index_doors_read() {
        let mut seen = 0;
        for index in 0..u8::MAX {
            let Some(id) = Group::from_index(index) else {
                continue;
            };
            let rows = settings_catalog::group(id);
            let crossed = walk(&delivered(index));
            assert_eq!(crossed.len(), rows.len(), "option count for {id:?}");
            for (option, row) in crossed.iter().zip(rows) {
                assert_eq!(option, &Option4 {
                    token: row.token.to_owned(),
                    label: row.label.to_owned(),
                    caption: row.caption.to_owned(),
                    menu_label: row.menu_label(),
                });
                seen += 1;
            }
        }
        assert!(
            seen > 60,
            "the corpus walked only {seen} options — this gate stopped reading"
        );
    }

    /// A caveat rides its own field AND the folded one, because a card hangs it under the label and
    /// a menu has no second line to hang it on.
    #[test]
    fn a_caveat_crosses_raw_and_folded_and_a_plain_row_carries_neither() {
        let crossed = walk(&delivered(Group::NewTabPosition.index()));
        assert_eq!(crossed[0].token, "auto");
        assert_eq!(crossed[0].caption, "Appends, like End");
        assert_eq!(crossed[0].menu_label, "Automatic — Appends, like End");
        assert_eq!(crossed[1].caption, "", "no caveat, and no dangling dash");
        assert_eq!(crossed[1].menu_label, "End");
    }

    /// The tab close-confirmation group is the window group's PREFIX, and it crosses as one.
    #[test]
    fn a_prefix_group_crosses_as_its_own_group() {
        let window = walk(&delivered(Group::CloseConfirmation.index()));
        let tab = walk(&delivered(Group::CloseConfirmationTab.index()));
        assert_eq!(window.len(), 3);
        assert_eq!(tab.len(), 2);
        assert_eq!(&window[..2], &tab[..]);
    }

    /// A group index no group has is no group at all, which is §4's `0` used for its literal
    /// meaning rather than an empty group the reader would have to tell apart from a real one.
    #[test]
    fn nothing_is_read_past_the_end() {
        let mut out = [0xAA_u8; 8];
        // SAFETY: `out` is a live local for the call.
        let needed = unsafe { slopdesk_settings_option_group(200, out.as_mut_ptr(), out.len()) };
        assert_eq!(needed, 0);
        assert_eq!(out, [0xAA; 8], "no answer means nothing was written");
    }

    /// A group that cannot fit its answer writes nothing and reports the size to ask at — §4's
    /// retry protocol, which the near side's first guess is sized so as never to travel.
    #[test]
    fn a_group_too_long_for_the_buffer_reports_its_size() {
        let full = delivered(Group::RightClickAction.index()).len();
        let mut tiny = [0xAA_u8; 4];
        // SAFETY: `tiny` is a live local for the call.
        let needed =
            unsafe { slopdesk_settings_option_group(Group::RightClickAction.index(), tiny.as_mut_ptr(), 4) };
        assert_eq!(needed, full);
        assert_eq!(tiny, [0xAA; 4], "nothing is written when the answer does not fit");
    }

    /// Every group fits the near side's first guess — so the retry above stays a correctness
    /// property rather than a cost the catalog's one-time build pays twice.
    #[test]
    fn every_group_fits_the_near_sides_first_guess() {
        for index in 0..u8::MAX {
            if Group::from_index(index).is_none() {
                continue;
            }
            let size = delivered(index).len();
            assert!(
                size <= SWIFT_FIRST_GUESS,
                "group {index} needs {size} bytes, past the {SWIFT_FIRST_GUESS} the near side guesses — \
                 raise SettingsCatalog.inlineCapacity with this number",
            );
        }
    }
}
