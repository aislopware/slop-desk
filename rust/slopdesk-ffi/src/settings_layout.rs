//! The shape of a settings page, in C.
//!
//! The rules are `slopdesk_workspace::settings_layout`; what is here is the marshalling.
//!
//! ## The half asking is an ARGUMENT, not the slice
//!
//! The door takes `mac: bool`. That looks redundant — the xcframework is built per slice, so the
//! Mac renderer could have been given a table already filtered by `cfg!` — and it is deliberate.
//! Filtering by the compiled slice would make "which groups does the phone show" unanswerable on a
//! Mac, and that question is exactly what the tests on both sides ask. A platform gate became data
//! so that it could be READ; compiling it back in would give the property away again.
//!
//! ## A PAGE crosses, because a page is what the caller asked for
//!
//! This was ten doors addressed positionally — a group count, then a title, a timing and a row
//! count per group, then six more per row. The near side is a renderer building a whole page, so it
//! walked them, and the walk cost `1 + 3G + 6R` crossings for one question: Appearance alone is
//! nine groups and twenty-three rows, so ~166 calls to lay out one page, on every re-render of a
//! `SwiftUI` `body` that holds the page's own `@Default` bindings — which is once per frame while a
//! slider on it is being dragged.
//!
//! The crossings were the cheap half. Each of them re-derived the whole answer to get at one
//! member: `settings_layout::row_at` calls `group_at`, which filters the flat 42-entry table into a
//! fresh `Vec`, and then filters that group's rows into a second one. So laying out Appearance
//! filtered the table ~166 times and allocated ~330 vectors to read 23 rows that were `&'static`
//! all along. That is the quadratic marshalling `docs/55` §4's "whole-answer crossing" exists to
//! delete, and it is the same argument `slopdesk_settings_row_fields` made one level in.
//!
//! One door now answers with the page: the counts, the fixed per-group and per-row records, and
//! every string the page needs, in ONE `(out, cap)` delivery under §4's retry protocol. The table
//! is filtered exactly once per call.
//!
//! ## The layout, and why the strings are one flat run
//!
//! All lengths are big-endian, because this is read across a C boundary where a width that followed
//! the target would be a bug waiting for a 32-bit build.
//!
//! ```text
//! [u16 group_count][u16 row_total]
//! group_count × [u8 timing][u16 row_count]
//! row_total   × [u8 control_kind][u8 control_argument]
//! (group_count + 4 × row_total) × [u32 length][UTF-8 bytes]
//! ```
//!
//! The strings ride BEHIND the fixed records rather than interleaved with them, and their number is
//! derivable from the header — group titles in group order, then `key`, `subtitle`, `glyph` and
//! `bespoke_id` per row, rows in page order. That is what lets the near side cut them with the
//! length-prefixed splitter it already uses for `slopdesk_ws_rail_disambiguated_labels` and PAD to
//! the count the header promised: a delivery that came up short is a layout disagreement between
//! the two sides, and padding is what stops it becoming a silent off-by-one where every row after
//! the gap renders its neighbour's words.
//!
//! **A zero length is NO string, not an empty one.** That is the opposite of §4b's presence-flag
//! rule, and it is right here for `hint_scan`'s reason: a row with an empty glyph and a row with no
//! glyph draw identically, and the ten doors this replaces already answered both with a zero-length
//! delivery. A flag would name a distinction nothing downstream can act on — and would change the
//! near side's reading, which is the one thing a marshalling change must not do.
//!
//! ## Which rows a filtered page does NOT contain
//!
//! `(section, mac)` selects a page and the groups and rows inside it are already filtered to that
//! half, so a phone reading group 4 of General gets its own fourth group, never a hole where a
//! macOS-only group was. The near side never sees the unfiltered table and cannot render from it.

use core::ffi::c_uchar;

use slopdesk_workspace::settings_catalog::Section;
use slopdesk_workspace::settings_layout::{self, LayoutRow};

use crate::deliver;

/// What a row's control argument reads as where its kind draws over neither an option group nor a
/// scalar ladder.
pub const SLOPDESK_SETTINGS_LAYOUT_NONE: u8 = u8::MAX;

/// The page a section index names, or `None` for an index no section has.
fn section(index: u8) -> Option<Section> {
    Section::ALL.get(index as usize).copied()
}

/// Appends one length-prefixed field: four big-endian bytes, then that many UTF-8 bytes.
///
/// A length that will not fit the prefix writes an EMPTY field rather than a lying one. Nothing in
/// a `&'static` table can reach four gigabytes, but a prefix that disagreed with the bytes after it
/// would desynchronise every field in the rest of the page, which is a worse answer than a blank.
fn push_text(blob: &mut Vec<u8>, text: &str) {
    let Ok(length) = u32::try_from(text.len()) else {
        blob.extend_from_slice(&0_u32.to_be_bytes());
        return;
    };
    blob.extend_from_slice(&length.to_be_bytes());
    blob.extend_from_slice(text.as_bytes());
}

/// The whole shape of one settings page, as one half draws it, in one delivery.
///
/// The layout is the module header's. `0` is "there is no such page" — a section index no section
/// has — and a return larger than `cap` means nothing was written, so the caller asks again at that
/// size.
///
/// # Safety
/// `(out, cap)` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and `(out, cap)` is the caller's buffer"
)]
pub unsafe extern "C" fn slopdesk_settings_layout_page(
    section_index: u8,
    mac: bool,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    let Some(page) = section(section_index) else {
        return 0;
    };
    // The one filter of the table this call makes. Everything below reads these two lists.
    let groups = settings_layout::groups(page, mac);
    let per_group: Vec<Vec<&'static LayoutRow>> = groups
        .iter()
        .map(|group| settings_layout::rows(group, mac))
        .collect();
    let row_total: usize = per_group.iter().map(Vec::len).sum();
    // A count that will not fit its prefix would make the reader walk a page that is not the one
    // this call encoded, so it is refused whole. No table this crate can hold comes near it.
    let (Ok(group_count), Ok(rows_encoded)) = (u16::try_from(groups.len()), u16::try_from(row_total)) else {
        return 0;
    };
    let mut blob = Vec::new();
    blob.extend_from_slice(&group_count.to_be_bytes());
    blob.extend_from_slice(&rows_encoded.to_be_bytes());
    for (group, rows) in groups.iter().zip(&per_group) {
        blob.push(group.timing.index());
        let Ok(count) = u16::try_from(rows.len()) else {
            return 0;
        };
        blob.extend_from_slice(&count.to_be_bytes());
    }
    for row in per_group.iter().flatten() {
        blob.push(row.control.kind());
        blob.push(row.control.argument().unwrap_or(SLOPDESK_SETTINGS_LAYOUT_NONE));
    }
    for group in &groups {
        push_text(&mut blob, group.title);
    }
    for row in per_group.iter().flatten() {
        push_text(&mut blob, row.key);
        push_text(&mut blob, row.subtitle);
        push_text(&mut blob, row.control.glyph().unwrap_or(""));
        push_text(&mut blob, row.control.bespoke_id());
    }
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe { deliver(&blob, out, cap) }
}

#[cfg(test)]
mod tests {
    #![expect(unsafe_code, reason = "calling the boundary IS what these tests are for")]
    #![expect(
        clippy::indexing_slicing,
        reason = "walking the page by the offsets its own header names is what the near side does; an index \
                  past the end here IS the failure report, and softening it to a default would let a \
                  truncated delivery read as an empty page and pass"
    )]
    #![expect(
        clippy::expect_used,
        reason = "a group the door itself just promised must be in the table it was built from — a panic \
                  here is the disagreement being reported"
    )]

    use slopdesk_workspace::settings_catalog::{ApplyTiming, Section};
    use slopdesk_workspace::settings_layout;

    use super::{SLOPDESK_SETTINGS_LAYOUT_NONE, slopdesk_settings_layout_page};

    /// `SettingsLayout.inlineCapacity` on the near side. Pinned here rather than there because this
    /// is the side that can measure it: a page that outgrew the guess would still be correct — §4's
    /// retry would fetch it — but it would pay two crossings for the answer this port exists to
    /// deliver in one, and nothing on the Swift side would say so.
    const SWIFT_FIRST_GUESS: usize = 4096;

    /// One delivery of one page, at a capacity generous enough that the retry is never travelled.
    fn page(section_index: u8, mac: bool) -> Vec<u8> {
        let mut out = vec![0_u8; 1 << 16];
        // SAFETY: `out` is a live local for the call.
        let needed =
            unsafe { slopdesk_settings_layout_page(section_index, mac, out.as_mut_ptr(), out.len()) };
        assert!(needed <= out.len(), "a page outgrew the test's buffer");
        out.get(..needed).unwrap_or_default().to_vec()
    }

    /// The page, cut back into the groups and rows it encodes — the walk the near side performs,
    /// written once here so a test can assert against it.
    struct Walk {
        /// Per group: its timing byte, its title, and its rows.
        groups: Vec<(u8, String, Vec<Row>)>,
    }

    #[derive(PartialEq, Eq, Debug)]
    struct Row {
        kind: u8,
        argument: u8,
        key: String,
        subtitle: String,
        glyph: String,
        bespoke: String,
    }

    impl Walk {
        fn of(blob: &[u8]) -> Self {
            let be16 = |at: usize| usize::from(blob[at]) << 8 | usize::from(blob[at + 1]);
            let group_count = be16(0);
            let row_total = be16(2);
            let row_base = 4 + group_count * 3;
            let string_base = row_base + row_total * 2;
            assert!(blob.len() >= string_base, "the fixed records were truncated");
            let mut fields = Vec::new();
            let mut cursor = string_base;
            while cursor + 4 <= blob.len() {
                let length = blob.get(cursor..cursor + 4).map_or(0, |bytes| {
                    bytes
                        .iter()
                        .fold(0_usize, |acc, byte| acc << 8 | usize::from(*byte))
                });
                cursor += 4;
                let text = blob.get(cursor..cursor + length).unwrap_or_default();
                fields.push(String::from_utf8_lossy(text).into_owned());
                cursor += length;
            }
            assert_eq!(cursor, blob.len(), "the walk must land exactly on the end");
            assert_eq!(
                fields.len(),
                group_count + row_total * 4,
                "the header promised a field count the run did not carry"
            );
            let mut groups = Vec::new();
            let mut row = 0;
            for index in 0..group_count {
                let record = 4 + index * 3;
                let count = be16(record + 1);
                let rows = (row..row + count)
                    .map(|position| {
                        let at = row_base + position * 2;
                        let text = group_count + position * 4;
                        Row {
                            kind: blob[at],
                            argument: blob[at + 1],
                            key: fields[text].clone(),
                            subtitle: fields[text + 1].clone(),
                            glyph: fields[text + 2].clone(),
                            bespoke: fields[text + 3].clone(),
                        }
                    })
                    .collect();
                row += count;
                groups.push((blob[record], fields[index].clone(), rows));
            }
            assert_eq!(row, row_total, "the per-group counts must sum to the total");
            Self { groups }
        }
    }

    /// EVERY member of EVERY page, on BOTH halves, agrees with the table the deleted per-index
    /// doors read one member at a time.
    ///
    /// `group_at` and `row_at` ARE what those doors called, so this is the parity assertion they
    /// would have supported, over the whole corpus rather than one probe.
    #[test]
    fn every_row_of_every_page_matches_the_table_the_index_doors_read() {
        let mut seen = 0;
        for (index, page_section) in Section::ALL.iter().enumerate() {
            let section_index = u8::try_from(index).expect("the section list is short");
            for mac in [true, false] {
                let walk = Walk::of(&page(section_index, mac));
                assert_eq!(
                    walk.groups.len(),
                    settings_layout::groups(*page_section, mac).len(),
                    "group count for section {index}, mac {mac}"
                );
                for (group_index, (timing, title, rows)) in walk.groups.iter().enumerate() {
                    let expected = settings_layout::group_at(*page_section, mac, group_index)
                        .expect("the door promised this group");
                    assert_eq!(*timing, expected.timing.index());
                    assert_eq!(title, expected.title);
                    let table = settings_layout::rows(expected, mac);
                    assert_eq!(rows.len(), table.len(), "row count for group {}", expected.title);
                    for (row_index, row) in rows.iter().enumerate() {
                        let want = settings_layout::row_at(*page_section, mac, group_index, row_index)
                            .expect("the door promised this row");
                        assert_eq!(row, &Row {
                            kind: want.control.kind(),
                            argument: want.control.argument().unwrap_or(SLOPDESK_SETTINGS_LAYOUT_NONE),
                            key: want.key.to_owned(),
                            subtitle: want.subtitle.to_owned(),
                            glyph: want.control.glyph().unwrap_or("").to_owned(),
                            bespoke: want.control.bespoke_id().to_owned(),
                        });
                        seen += 1;
                    }
                }
            }
        }
        assert!(
            seen > 100,
            "the corpus walked only {seen} rows — this gate stopped reading"
        );
    }

    /// The General page crosses whole, and the two halves differ by exactly the group iOS cannot
    /// back. Asserted THROUGH the boundary rather than against the table, because the point of the
    /// `mac` argument is that one process can ask both questions.
    #[test]
    fn both_halves_of_the_general_page_cross() {
        let titles = |mac: bool| {
            Walk::of(&page(0, mac))
                .groups
                .into_iter()
                .map(|(_, title, _)| title)
                .collect::<Vec<_>>()
        };
        assert_eq!(titles(true), [
            "General",
            "Close Confirmation",
            "Privacy & New Panes",
            "Shared Focus",
            "OS Integration"
        ]);
        assert_eq!(titles(false), [
            "General",
            "Close Confirmation",
            "Privacy & New Panes",
            "Shared Focus"
        ]);
    }

    /// A control crosses as a kind plus its payloads, and a toggle reads as one.
    #[test]
    fn a_toggle_crosses_as_a_kind_a_glyph_and_no_argument() {
        // General → Privacy & New Panes → the redact toggle.
        let walk = Walk::of(&page(0, true));
        let row = &walk.groups[2].2[0];
        assert_eq!(row.kind, 0);
        assert_eq!(row.argument, SLOPDESK_SETTINGS_LAYOUT_NONE);
        assert_eq!(row.glyph, "eye.slash");
        assert_eq!(row.key, "features.redactSecrets");
        assert_eq!(row.bespoke, "", "a toggle names no bespoke surface");
    }

    /// A menu crosses carrying the option group it lists.
    #[test]
    fn a_menu_crosses_carrying_its_option_group() {
        // General → General → On launch, which lists `Group::OnLaunch` (case index 7).
        let walk = Walk::of(&page(0, true));
        assert_eq!(walk.groups[0].2[0].kind, 1);
        assert_eq!(walk.groups[0].2[0].argument, 7);
        assert_eq!(walk.groups[0].0, ApplyTiming::Live.index());
    }

    /// A section index no section has is no page at all, which is §4's `0` used for its literal
    /// meaning rather than an empty page the reader would have to tell apart from a real one.
    #[test]
    fn nothing_is_read_past_the_end() {
        let mut out = [0xAA_u8; 8];
        // SAFETY: `out` is a live local for the call.
        let needed = unsafe { slopdesk_settings_layout_page(200, true, out.as_mut_ptr(), out.len()) };
        assert_eq!(needed, 0);
        assert_eq!(out, [0xAA; 8], "no answer means nothing was written");
    }

    /// A page that cannot fit its answer writes nothing and reports the size to ask at — §4's retry
    /// protocol, which the near side's first guess is sized so as never to travel.
    #[test]
    fn a_page_too_long_for_the_buffer_reports_its_size() {
        let full = page(0, true).len();
        let mut tiny = [0xAA_u8; 4];
        // SAFETY: `tiny` is a live local for the call.
        let needed = unsafe { slopdesk_settings_layout_page(0, true, tiny.as_mut_ptr(), tiny.len()) };
        assert_eq!(needed, full);
        assert_eq!(tiny, [0xAA; 4], "nothing is written when the answer does not fit");
    }

    /// Every page, on both halves, fits the near side's first guess — so the retry above stays a
    /// correctness property rather than a cost every settings render pays twice.
    #[test]
    fn every_page_fits_the_near_sides_first_guess() {
        for index in 0..Section::ALL.len() {
            let section_index = u8::try_from(index).expect("the section list is short");
            for mac in [true, false] {
                let size = page(section_index, mac).len();
                assert!(
                    size <= SWIFT_FIRST_GUESS,
                    "section {index} (mac {mac}) needs {size} bytes, past the {SWIFT_FIRST_GUESS} the near \
                     side guesses — raise SettingsLayout.inlineCapacity with this number",
                );
            }
        }
    }
}
