//! The workspace binding table, in C.
//!
//! The rule is [`slopdesk_workspace::bindings`]; what is here is the marshalling. This module
//! replaces `binding_rows`, which crossed ONE column of a row — which half lists it — while the
//! other six lived in a Swift array literal that `rust/slopdesk-invariants` held equal to the Rust
//! one with a regex on each side. docs/64 is why that ended; the whole row crosses now, and the
//! Swift side has no table to drift from.
//!
//! ## Whole-table doors, walked once
//!
//! Four doors, three of them answering the WHOLE table in one crossing rather than a call per row
//! per field. The registry builds a `static let` from them at first touch and never asks again, so
//! what matters is that a cold read is one pass rather than 77 × 4 crossings — and that nothing on
//! the per-keystroke path goes through here at all (the chord lookup is a Swift hash over the
//! assembled table).
//!
//! The scalars cross as `#[repr(C)]` records through [`crate::spill`]; the four strings per row
//! cross as one length-prefixed blob through [`crate::push_text`], read back by `wsRuns` — the
//! group-delivery idiom every catalogue door here already uses.

use core::ffi::c_uchar;

use slopdesk_workspace::bindings::{self, Action};

use crate::{deliver, push_text, spill};

/// One binding row's scalars, as C reads them.
///
/// The strings are NOT here: they cross in the companion blob, in row order, four per row. A
/// `(ptr, len)` per string per row would mean 308 borrows with 308 lifetimes for a table that is
/// read once.
#[derive(Debug, Clone, Copy)]
#[repr(C)]
pub struct BindingRowRecord {
    /// The `WorkspaceAction` tag — [`Action::tag`].
    pub action: u16,
    /// `0` for the eleven named keys, `-1` for a printable one. See
    /// [`BindingRowRecord::chord_char`].
    pub chord_named: i16,
    /// The payload the action carries, or `0`. Only `SelectPane` uses it.
    pub arg: i32,
    /// The printable key's Unicode scalar. Meaningless unless `chord_named` is `-1`.
    pub chord_char: u32,
    /// `0` panes · `1` tabs · `2` focus · `3` view.
    pub category: u8,
    /// Shift `1` · Control `2` · Option `4` · Command `8`.
    pub chord_modifiers: u8,
    /// `0` a declared row, `1` the collapsed ⌘1…⌘9 representative.
    pub kind: u8,
    /// Whether the row carries a default chord at all.
    pub has_chord: bool,
    /// Whether the half that ASKED lists this row — and therefore binds its chord.
    pub shown: bool,
}

/// One alias: a second chord that fires an existing action without minting a display row.
#[derive(Debug, Clone, Copy)]
#[repr(C)]
pub struct BindingAliasRecord {
    /// The action the alias fires.
    pub action: u16,
    /// `-1` for a printable key; otherwise the named-key index.
    pub chord_named: i16,
    /// The printable key's Unicode scalar. Meaningless unless `chord_named` is `-1`.
    pub chord_char: u32,
    /// Shift `1` · Control `2` · Option `4` · Command `8`.
    pub chord_modifiers: u8,
}

/// `-1` for a printable key; the eleven named keys keep their own index.
///
/// `KeyChord.Key.namedIndex` answers `nil` for a printable key and the far side reads this the same
/// way — a sentinel rather than a second flag, because a chord has exactly one key and the
/// discriminator IS which kind it is.
const PRINTABLE: i16 = -1;

/// How many binding rows the table declares.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_ws_binding_count() -> usize {
    bindings::ROWS.len()
}

/// Every row's scalars, in display order, answered for the half that identifies as `mac`.
///
/// The answer is the count NEEDED — docs/55 §4 — so a caller that lent too little is told what to
/// lend rather than handed a truncated table.
///
/// # Safety
/// `out` must be null, or writable for `cap` [`BindingRowRecord`] for the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_binding_rows(
    mac: bool,
    out: *mut BindingRowRecord,
    cap: usize,
) -> usize {
    let records: Vec<BindingRowRecord> = bindings::ROWS
        .iter()
        .map(|row| {
            BindingRowRecord {
                action: row.action.tag(),
                chord_named: row
                    .chord
                    .and_then(|chord| chord.named)
                    .map_or(PRINTABLE, |named| named as i16),
                arg: row.arg,
                chord_char: row.chord.map_or(0, |chord| chord.character as u32),
                category: row.category as u8,
                chord_modifiers: row.chord.map_or(0, |chord| chord.modifiers),
                kind: row.kind as u8,
                has_chord: row.chord.is_some(),
                shown: row.platform.shown_on(mac),
            }
        })
        .collect();
    // SAFETY: the caller's obligation, restated above; `spill` writes at most `cap` records.
    unsafe { spill(&records, out, cap) }
}

/// Every row's four strings, in row order: id, title, symbol, keywords.
///
/// Four runs per row ALWAYS, so the far side's cursor advances by a constant and a row with no
/// keywords is an empty run rather than a missing one — a variable count would make an absent field
/// indistinguishable from a lost one, and every run after it would wear its neighbour's words.
///
/// # Safety
/// `(out, cap)` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_binding_text(out: *mut c_uchar, cap: usize) -> usize {
    let mut blob = Vec::new();
    for row in bindings::ROWS {
        push_text(&mut blob, row.id);
        push_text(&mut blob, row.title);
        push_text(&mut blob, row.symbol);
        push_text(&mut blob, row.keywords.unwrap_or_default());
    }
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe { deliver(&blob, out, cap) }
}

/// Every alias chord, in table order.
///
/// # Safety
/// `out` must be null, or writable for `cap` [`BindingAliasRecord`] for the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_binding_aliases(out: *mut BindingAliasRecord, cap: usize) -> usize {
    let records: Vec<BindingAliasRecord> = bindings::ALIASES
        .iter()
        .map(|(chord, action)| {
            BindingAliasRecord {
                action: action.tag(),
                chord_named: chord.named.map_or(PRINTABLE, |named| named as i16),
                chord_char: chord.character as u32,
                chord_modifiers: chord.modifiers,
            }
        })
        .collect();
    // SAFETY: the caller's obligation, restated above; `spill` writes at most `cap` records.
    unsafe { spill(&records, out, cap) }
}

/// Whether running `action` requires an active pane.
///
/// A tag this build does not know answers `false` — the palette LISTS such a row rather than hiding
/// it, which is the same fail-open [`slopdesk_workspace::bindings::shown`] takes and for the same
/// reason: a tag that arrived from a newer half must not silently delete a command.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_ws_action_requires_active_pane(action: u16) -> bool {
    Action::from_tag(action).is_some_and(Action::requires_active_pane)
}

#[cfg(test)]
#[expect(unsafe_code, reason = "calling the boundary IS what these tests are for")]
#[expect(
    clippy::expect_used,
    clippy::indexing_slicing,
    reason = "a panic in a test is the failure report, and every index here is into a buffer this module \
              just filled"
)]
mod tests {
    use slopdesk_workspace::bindings;

    use super::{
        BindingAliasRecord, BindingRowRecord, PRINTABLE, slopdesk_ws_action_requires_active_pane,
        slopdesk_ws_binding_aliases, slopdesk_ws_binding_count, slopdesk_ws_binding_rows,
        slopdesk_ws_binding_text,
    };

    fn rows(mac: bool) -> Vec<BindingRowRecord> {
        let count = slopdesk_ws_binding_count();
        let mut out = vec![
            BindingRowRecord {
                action: 0,
                chord_named: 0,
                arg: 0,
                chord_char: 0,
                category: 0,
                chord_modifiers: 0,
                kind: 0,
                has_chord: false,
                shown: false,
            };
            count
        ];
        // SAFETY: the buffer is a live local, `count` records long, for the duration of the call.
        let written = unsafe { slopdesk_ws_binding_rows(mac, out.as_mut_ptr(), out.len()) };
        assert_eq!(written, count, "the table crossed short");
        out
    }

    fn text() -> Vec<u8> {
        let mut out = [0_u8; 16];
        // SAFETY: the buffer is a live local for the duration of the call.
        let needed = unsafe { slopdesk_ws_binding_text(out.as_mut_ptr(), out.len()) };
        assert!(needed > out.len(), "the whole table cannot fit sixteen bytes");
        let mut big = vec![0_u8; needed];
        // SAFETY: the buffer is a live local, `needed` bytes long, for the duration of the call.
        let written = unsafe { slopdesk_ws_binding_text(big.as_mut_ptr(), big.len()) };
        assert_eq!(
            written, needed,
            "the door disagreed with itself between two calls"
        );
        big
    }

    /// Cuts the blob the way `wsRuns` does on the far side.
    fn runs(blob: &[u8]) -> Vec<String> {
        let mut cut = Vec::new();
        let mut at = 0;
        while at + 4 <= blob.len() {
            let length = u32::from_be_bytes([blob[at], blob[at + 1], blob[at + 2], blob[at + 3]]);
            at += 4;
            let end = at + usize::try_from(length).expect("a run length fits a usize");
            assert!(end <= blob.len(), "a run ran past the blob");
            cut.push(String::from_utf8(blob[at..end].to_vec()).expect("the table is UTF-8"));
            at = end;
        }
        assert_eq!(at, blob.len(), "the blob had trailing bytes no run claimed");
        cut
    }

    #[test]
    fn the_whole_table_crosses_and_stops_at_the_end() {
        let count = slopdesk_ws_binding_count();
        assert_eq!(count, bindings::ROWS.len());
        assert!(count > 0);
        // SAFETY: a null pointer with a zero capacity is what `spill` documents.
        let needed = unsafe { slopdesk_ws_binding_rows(true, std::ptr::null_mut(), 0) };
        assert_eq!(needed, count, "a caller that lent nothing is told what to lend");
    }

    #[test]
    fn the_text_blob_carries_exactly_four_runs_per_row() {
        let blob = text();
        let cut = runs(&blob);
        assert_eq!(cut.len(), slopdesk_ws_binding_count() * 4);
        for (index, row) in bindings::ROWS.iter().enumerate() {
            assert_eq!(cut[index * 4], row.id);
            assert_eq!(cut[index * 4 + 1], row.title);
            assert_eq!(cut[index * 4 + 2], row.symbol);
            assert_eq!(cut[index * 4 + 3], row.keywords.unwrap_or_default());
        }
    }

    #[test]
    fn a_row_with_no_keywords_still_takes_its_slot() {
        // Nothing in the table omits keywords today, so the guarantee is stated against the
        // ENCODER rather than against a row that might grow one: four runs, always.
        let cut = runs(&text());
        assert_eq!(cut.len() % 4, 0);
    }

    #[test]
    fn a_named_chord_and_a_printable_one_are_told_apart_by_the_sentinel() {
        let table = rows(true);
        let zoom = table
            .iter()
            .zip(bindings::ROWS)
            .find(|(_, row)| row.id == "view.zoom")
            .expect("view.zoom is in the table")
            .0;
        assert!(zoom.has_chord);
        assert_eq!(zoom.chord_named, 0, "⌘⇧↩ is the named Return key, index 0");

        let split = table
            .iter()
            .zip(bindings::ROWS)
            .find(|(_, row)| row.id == "pane.splitRight")
            .expect("pane.splitRight is in the table")
            .0;
        assert_eq!(split.chord_named, PRINTABLE);
        assert_eq!(split.chord_char, u32::from('d'));
        assert_eq!(split.chord_modifiers, bindings::COMMAND);
    }

    #[test]
    fn a_chord_less_row_crosses_with_no_chord_rather_than_a_blank_one() {
        let table = rows(true);
        let rename = table
            .iter()
            .zip(bindings::ROWS)
            .find(|(_, row)| row.id == "pane.rename")
            .expect("pane.rename is in the table")
            .0;
        assert!(!rename.has_chord);
        assert_eq!(rename.chord_modifiers, 0);
    }

    #[test]
    fn the_mac_rows_cross_as_shown_only_to_the_mac() {
        let on_mac = rows(true);
        let on_phone = rows(false);
        for (index, row) in bindings::ROWS.iter().enumerate() {
            if row.id == "pane.detach" {
                assert!(on_mac[index].shown);
                assert!(!on_phone[index].shown);
            }
            if row.id == "pane.close" {
                assert!(on_mac[index].shown && on_phone[index].shown);
            }
        }
        assert_eq!(
            on_mac.len(),
            on_phone.len(),
            "the table is one table on both halves"
        );
    }

    #[test]
    fn the_representative_crosses_as_its_own_kind_carrying_the_digit() {
        let table = rows(true);
        let last = table.last().expect("the table is not empty");
        assert_eq!(last.kind, 1);
        assert_eq!(last.arg, 1, "the stand-in names pane one");
        assert!(!last.has_chord);
    }

    #[test]
    fn every_alias_crosses_with_the_action_it_fires() {
        let count = bindings::ALIASES.len();
        let mut out = vec![
            BindingAliasRecord {
                action: 0,
                chord_named: 0,
                chord_char: 0,
                chord_modifiers: 0
            };
            count
        ];
        // SAFETY: the buffer is a live local, `count` records long, for the duration of the call.
        let written = unsafe { slopdesk_ws_binding_aliases(out.as_mut_ptr(), out.len()) };
        assert_eq!(written, count);
        for (record, (chord, action)) in out.iter().zip(bindings::ALIASES) {
            assert_eq!(record.action, action.tag());
            assert_eq!(record.chord_modifiers, chord.modifiers);
        }
        assert!(
            out.iter().any(|record| record.chord_named != PRINTABLE),
            "⌃⇧Space is a NAMED key and must not cross as a printable one",
        );
    }

    #[test]
    fn an_action_answers_for_its_pane_requirement_and_an_unknown_tag_falls_open() {
        assert!(slopdesk_ws_action_requires_active_pane(
            bindings::Action::SplitRight.tag()
        ));
        assert!(!slopdesk_ws_action_requires_active_pane(
            bindings::Action::CommandPalette.tag()
        ));
        assert!(
            !slopdesk_ws_action_requires_active_pane(u16::MAX),
            "a tag this build does not know must LIST the row, not hide it",
        );
    }
}
