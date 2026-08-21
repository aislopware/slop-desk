//! Every setting as a row, in C.
//!
//! The rules are `slopdesk_workspace::settings_rows`; what is here is the marshalling. Same idiom
//! as its sibling next door — a count plus indexed accessors — with two additions a row list needs
//! and a choice list does not.
//!
//! ## A key is looked up, not scanned
//!
//! The near side holds keys (they are `Defaults.Key` names and cannot leave Swift), so it asks for
//! a row BY key as often as it walks the list. [`slopdesk_settings_row_index`] answers with a
//! position it can then read fields from, or [`SLOPDESK_SETTINGS_ROW_NONE`] — a sentinel rather
//! than a zero, because zero is a real row.
//!
//! ## A filter crosses as positions
//!
//! [`slopdesk_settings_row_matches`] fills a caller's buffer with the POSITIONS a query matched and
//! returns how many there are, under the same retry protocol every string door uses: a `needed`
//! larger than `cap` means nothing was written and the caller should ask again at that size.
//! Sending positions rather than rows is what keeps the match one crossing instead of one per field
//! per row.

use core::ffi::c_uchar;

use slopdesk_workspace::settings_rows::{self, Persistence, SettingRow};

use crate::{borrow, deliver};

/// What [`slopdesk_settings_row_index`] answers for a key no row has.
pub const SLOPDESK_SETTINGS_ROW_NONE: usize = usize::MAX;

/// How many settings the all-settings list advertises.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_settings_row_count() -> usize {
    settings_rows::ROWS.len()
}

/// The monospace configuration key a row is filed under.
///
/// # Safety
/// `(out, cap)` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_settings_row_key(index: usize, out: *mut c_uchar, cap: usize) -> usize {
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe { row_field(index, out, cap, |row| row.key) }
}

/// WHERE the row's value lives: `0` `UserDefaults`, `1` device-local, `2` model-backed.
///
/// The reset question, not the render one — the bucket byte in front of
/// [`slopdesk_settings_row_fields`]'s delivery is that. `0` for an index no row has, which is the
/// safe answer twice over: a caller that got here learned the row exists from the count, and
/// `UserDefaults` is the arm a global reset already reaches.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_settings_row_persistence(index: usize) -> u8 {
    settings_rows::row_at(index).map_or_else(
        || Persistence::UserDefaults.index(),
        |row| row.persistence.index(),
    )
}

/// Whether the list renders a real inline editor for this row.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_settings_row_is_inline_editable(index: usize) -> bool {
    settings_rows::row_at(index).is_some_and(|row| row.inline_editable)
}

/// Whether the half that identifies as `mac` advertises the row at `index`.
///
/// `shown` rather than `platform`, for the reason [`crate::palette_rows`] states: the near side
/// already knows which slice it is, and what it must never do is turn that back into a `#if` around
/// a row. `false` past the end — an index no row has advertises nothing.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_settings_row_shown(index: usize, mac: bool) -> bool {
    settings_rows::shown_at(index, mac)
}

/// The seven strings and the bucket byte, in ONE delivery.
///
/// ## Why a row crosses whole
///
/// The module header already argues the principle for the MATCH — positions rather than rows, so a
/// filter is one crossing and not one per field per row — and then the near side turned each
/// position back into eight calls. Settings search reads every matched row on every keystroke, so
/// the seven per-field doors this one replaced were costing roughly `8 × matches` crossings per
/// character typed, and each string door could retry, so the real figure was higher. Whole-row is
/// the same argument applied one level out: the caller wants the row, so the row is what crosses.
///
/// They were deleted rather than kept beside it. Once the near side read rows through here, nothing
/// called them — and an exported door with no caller is a second way to ask what a live door
/// already answers, which is the drift `docs/55` §8 is about. The doors that survive are the ones a
/// caller still asks a SINGLE question through: [`slopdesk_settings_row_key`] for the key lookup,
/// [`slopdesk_settings_row_shown`] for the platform gate, [`slopdesk_settings_row_persistence`] for
/// the reset walk.
///
/// ## The layout
///
/// One byte of bucket, then seven fields, each a four-byte big-endian length followed by that many
/// UTF-8 bytes, in the order the near side's row type declares them: key, label, page label,
/// description, default text, target section, keywords. Big-endian and explicit rather than
/// `usize`-native, because the layout is read by a decoder on the other side of a C boundary and a
/// width that changes with the target is a bug waiting for a 32-bit build.
///
/// An empty field is a zero length, which is how `target_section` says "edited in place". There is
/// one delivery and therefore one reading, so nothing can diverge from it.
///
/// A return larger than `cap` means nothing was written; ask again at that size. An index no row
/// has delivers nothing at all, which the caller distinguishes from a real row by the count it
/// already had to consult to get here.
///
/// # Safety
/// `(out, cap)` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and `(out, cap)` is the caller's buffer"
)]
pub unsafe extern "C" fn slopdesk_settings_row_fields(index: usize, out: *mut c_uchar, cap: usize) -> usize {
    let Some(row) = settings_rows::row_at(index) else {
        return 0;
    };
    let fields = [
        row.key,
        row.label,
        row.page_label(),
        row.description,
        row.default_text,
        row.target_section,
        row.keywords,
    ];
    let mut blob = Vec::with_capacity(1 + fields.len() * 4 + fields.iter().map(|f| f.len()).sum::<usize>());
    blob.push(row.bucket.index());
    for field in fields {
        let len = u32::try_from(field.len()).unwrap_or(u32::MAX);
        blob.extend_from_slice(&len.to_be_bytes());
        blob.extend_from_slice(field.as_bytes());
    }
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe { deliver(&blob, out, cap) }
}

/// One field of one row, delivered.
///
/// # Safety
/// `(out, cap)` must be writable for `cap` bytes.
#[expect(
    unsafe_code,
    reason = "the delivery is the marshalling; the door that calls it restates the same obligation"
)]
unsafe fn row_field(
    index: usize,
    out: *mut c_uchar,
    cap: usize,
    field: impl Fn(&SettingRow) -> &'static str,
) -> usize {
    let Some(row) = settings_rows::row_at(index) else {
        return 0;
    };
    // SAFETY: the caller's obligation, restated above.
    unsafe { deliver(field(row).as_bytes(), out, cap) }
}

/// The position of the row a key names, or [`SLOPDESK_SETTINGS_ROW_NONE`].
///
/// # Safety
/// `(key, key_len)` must be a readable UTF-8 buffer for the duration of the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_settings_row_index(key: *const c_uchar, key_len: usize) -> usize {
    // SAFETY: the caller's obligation, restated above.
    let bytes = unsafe { borrow(key, key_len) };
    let Ok(key) = core::str::from_utf8(bytes) else {
        return SLOPDESK_SETTINGS_ROW_NONE;
    };
    settings_rows::ROWS
        .iter()
        .position(|row| row.key == key)
        .unwrap_or(SLOPDESK_SETTINGS_ROW_NONE)
}

/// The positions a query matches, written into `(out, cap)`; returns how many there are.
///
/// `needed > cap` means nothing was written — ask again at that size. A key that is not valid UTF-8
/// matches nothing, which is the same answer a nonsense query gets.
///
/// # Safety
/// `(query, query_len)` must be readable for the call, and `(out, cap)` writable for `cap` entries.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_settings_row_matches(
    query: *const c_uchar,
    query_len: usize,
    out: *mut usize,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, restated above.
    let bytes = unsafe { borrow(query, query_len) };
    let Ok(query) = core::str::from_utf8(bytes) else {
        return 0;
    };
    let hits = settings_rows::matches(query);
    if hits.len() > cap || out.is_null() {
        return hits.len();
    }
    for (slot, index) in hits.iter().enumerate() {
        // SAFETY: `slot < hits.len() <= cap`, and the caller promised `cap` writable entries.
        unsafe { out.add(slot).write(*index) };
    }
    hits.len()
}

#[cfg(test)]
#[expect(unsafe_code, reason = "calling the boundary IS what these tests are for")]
#[expect(
    clippy::expect_used,
    reason = "a panic while walking a length prefix this test just asked the door for IS the failure report \
              — softening it to a default would let a short delivery read as an empty field and pass"
)]
mod tests {
    use super::*;

    fn read(mut door: impl FnMut(*mut c_uchar, usize) -> usize) -> Option<String> {
        let mut out = [0_u8; 256];
        let written = door(out.as_mut_ptr(), out.len());
        if written == 0 {
            return None;
        }
        assert!(
            written <= out.len(),
            "no row string is longer than the probe buffer"
        );
        out.get(..written)
            .map(|bytes| String::from_utf8_lossy(bytes).into_owned())
    }

    fn index_of(key: &str) -> usize {
        // SAFETY: `key` is a live local for the call.
        unsafe { slopdesk_settings_row_index(key.as_ptr(), key.len()) }
    }

    /// The slots of the one delivery, in the order the door's doc comment declares them. Named
    /// rather than spelled as bare numbers, because a reader indexing the wrong slot is exactly the
    /// silent shift the near side pads against.
    const KEY: usize = 0;
    const LABEL: usize = 1;
    const PAGE_LABEL: usize = 2;
    const DESCRIPTION: usize = 3;
    const DEFAULT_TEXT: usize = 4;
    const TARGET_SECTION: usize = 5;
    const KEYWORDS: usize = 6;

    /// The bucket byte and the seven fields of one row, read the way the near side reads them.
    /// `None` for an index no row has, which is the door delivering nothing at all.
    fn row(index: usize) -> Option<(u8, Vec<String>)> {
        // SAFETY: the buffer inside `read_bytes` is a live local.
        let blob = read_bytes(|out, cap| unsafe { slopdesk_settings_row_fields(index, out, cap) });
        (!blob.is_empty()).then(|| split_row_blob(&blob))
    }

    /// One slot of a delivery. A slot that is not THERE is the failure report rather than an empty
    /// field: an absent slot shifts every field behind it, which is the silent mis-render the near
    /// side's own padding exists to refuse.
    fn at(fields: &[String], slot: usize) -> &str {
        fields
            .get(slot)
            .expect("the delivery carries every slot")
            .as_str()
    }

    /// One field out of the whole-row delivery. An empty field answers `None`, because "this row
    /// jumps nowhere" and "this row jumps to the empty section" are not two states.
    fn field(index: usize, slot: usize) -> Option<String> {
        let (_, fields) = row(index)?;
        Some(at(&fields, slot))
            .filter(|text| !text.is_empty())
            .map(String::from)
    }

    #[test]
    fn a_row_crosses_whole() {
        let index = index_of("controls.copyOnSelect");
        assert_ne!(index, SLOPDESK_SETTINGS_ROW_NONE);
        let (bucket, fields) = row(index).expect("a key the index resolved names a row");
        assert_eq!(at(&fields, LABEL), "Copy on Select");
        assert_eq!(at(&fields, KEY), "controls.copyOnSelect");
        assert_eq!(at(&fields, DEFAULT_TEXT), "Off");
        assert_eq!(field(index, TARGET_SECTION), None, "an inline row jumps nowhere");
        assert_eq!(bucket, 0);
        assert!(slopdesk_settings_row_is_inline_editable(index));
        // The one string door that survived the widening answers the same key the delivery carries,
        // because the near side resolves a key through it and reads the row through the other.
        // SAFETY: the buffer inside `read` is a live local.
        let key = read(|out, cap| unsafe { slopdesk_settings_row_key(index, out, cap) });
        assert_eq!(key.as_deref(), Some("controls.copyOnSelect"));
    }

    /// The delivery carries every field of the row the rules hold, on every row.
    ///
    /// This is the load-bearing test for the door, because it is now the ONLY way a row reaches the
    /// near side: seven per-field doors used to stand beside it and cross-check it, and they were
    /// deleted when nothing called them. So the cross-check is against `slopdesk_workspace`'s own
    /// row — the rules themselves — rather than against a second marshalling of them, which is the
    /// stronger of the two comparisons and the one that survives having a single door. Walking
    /// EVERY row rather than a sample is what makes a field appended to `SettingRow` and forgotten
    /// here fail immediately.
    #[test]
    fn the_whole_row_door_carries_every_field_of_every_row() {
        for index in 0..slopdesk_settings_row_count() {
            let (bucket, fields) = row(index).expect("every index below the count names a row");
            let source = settings_rows::row_at(index).expect("the rules hold the row the count promised");
            assert_eq!(bucket, source.bucket.index(), "row {index} bucket");
            // Paired with its slot rather than positionally, so the ORDER the near side decodes by
            // is pinned here too — a field swapped with its neighbour would otherwise still pass.
            let expected = [
                (KEY, source.key),
                (LABEL, source.label),
                (PAGE_LABEL, source.page_label()),
                (DESCRIPTION, source.description),
                (DEFAULT_TEXT, source.default_text),
                (TARGET_SECTION, source.target_section),
                (KEYWORDS, source.keywords),
            ];
            assert_eq!(fields.len(), expected.len(), "row {index} field count");
            for (slot, want) in expected {
                assert_eq!(at(&fields, slot), want, "row {index} slot {slot}");
            }
            // The key the delivery carries is the key the lookup resolves, so a caller that walks
            // the list and a caller that arrives by key cannot land on different rows.
            assert_eq!(index_of(at(&fields, KEY)), index, "row {index} key round trip");
        }
    }

    /// The page register overrides the index register where a row carries one, and falls back to
    /// the label where it does not — so the near side never has to know which rows have an
    /// override.
    #[test]
    fn a_page_label_falls_back_to_the_index_label() {
        let overridden = (0..slopdesk_settings_row_count())
            .filter_map(row)
            .filter(|(_, fields)| at(fields, PAGE_LABEL) != at(fields, LABEL))
            .count();
        assert!(overridden > 0, "some row carries a page-register override");
        for index in 0..slopdesk_settings_row_count() {
            let (_, fields) = row(index).expect("every index below the count names a row");
            assert!(
                !at(&fields, PAGE_LABEL).is_empty(),
                "row {index} delivers no page label, so a page would draw a nameless row",
            );
        }
    }

    /// An index past the last delivers nothing, rather than a row of empty fields that would read
    /// as a real setting with no name.
    #[test]
    fn a_row_past_the_end_delivers_nothing_at_all() {
        let past = slopdesk_settings_row_count();
        // SAFETY: the buffer is a live local.
        let needed = unsafe { slopdesk_settings_row_fields(past, core::ptr::null_mut(), 0) };
        assert_eq!(needed, 0);
    }

    /// An overflow reports the size it needs and leaves the caller's buffer untouched — §4's retry.
    #[test]
    fn a_row_that_does_not_fit_names_its_size_and_writes_nothing() {
        let mut tiny = [0xAA_u8; 4];
        // SAFETY: the buffer is a live local.
        let needed = unsafe { slopdesk_settings_row_fields(0, tiny.as_mut_ptr(), tiny.len()) };
        assert!(needed > tiny.len(), "row 0 is wider than four bytes");
        assert_eq!(tiny, [0xAA; 4], "an overflow leaves the caller's buffer alone");
    }

    /// The size-then-read protocol, then the length-prefixed walk the near side does.
    fn read_bytes(mut door: impl FnMut(*mut c_uchar, usize) -> usize) -> Vec<u8> {
        let needed = door(core::ptr::null_mut(), 0);
        let mut out = vec![0_u8; needed];
        let written = door(out.as_mut_ptr(), out.len());
        assert_eq!(written, needed);
        out
    }

    /// The bucket byte and the seven length-prefixed fields behind it.
    fn split_row_blob(blob: &[u8]) -> (u8, Vec<String>) {
        let (bucket, mut rest) = blob.split_first().expect("a row is never empty");
        let mut fields = Vec::new();
        while !rest.is_empty() {
            let (header, tail) = rest.split_at(4);
            let len = u32::from_be_bytes(header.try_into().expect("four bytes")) as usize;
            let (body, tail) = tail.split_at(len);
            fields.push(String::from_utf8(body.to_vec()).expect("a Rust &str's bytes"));
            rest = tail;
        }
        (*bucket, fields)
    }

    #[test]
    fn a_jump_row_names_its_section() {
        let index = index_of("font-family");
        assert_eq!(field(index, TARGET_SECTION).as_deref(), Some("appearance"));
        let (bucket, _) = row(index).expect("a key the index resolved names a row");
        assert_eq!(bucket, 1);
        assert!(!slopdesk_settings_row_is_inline_editable(index));
    }

    #[test]
    fn an_unknown_key_is_an_answer_rather_than_a_crash() {
        assert_eq!(index_of("no.such.key"), SLOPDESK_SETTINGS_ROW_NONE);
        assert_eq!(index_of(""), SLOPDESK_SETTINGS_ROW_NONE);
        // SAFETY: a null key with a zero length is what `borrow` is written against.
        assert_eq!(
            unsafe { slopdesk_settings_row_index(core::ptr::null(), 0) },
            SLOPDESK_SETTINGS_ROW_NONE,
        );
        // SAFETY: the buffer inside `read` is a live local.
        assert_eq!(
            read(|out, cap| unsafe { slopdesk_settings_row_key(9999, out, cap) }),
            None
        );
        assert_eq!(row(9999), None, "and the whole-row door delivers nothing either");
    }

    #[test]
    fn a_filter_crosses_as_positions_under_the_retry_protocol() {
        let query = "clipboard";
        let mut out = [0_usize; 64];
        // SAFETY: both buffers are live locals.
        let found = unsafe {
            slopdesk_settings_row_matches(query.as_ptr(), query.len(), out.as_mut_ptr(), out.len())
        };
        assert!(found > 1, "clipboard names more than one setting");
        let named = out
            .iter()
            .take(found)
            .filter_map(|index| field(*index, LABEL))
            .count();
        assert_eq!(named, found, "every reported position must name a row");

        // An overflow reports the size it needs and writes NOTHING.
        let mut tiny = [usize::MAX; 1];
        // SAFETY: as above.
        let needed = unsafe {
            slopdesk_settings_row_matches(query.as_ptr(), query.len(), tiny.as_mut_ptr(), tiny.len())
        };
        assert_eq!(needed, found);
        assert_eq!(
            tiny[0],
            usize::MAX,
            "an overflow leaves the caller's buffer alone"
        );
    }

    #[test]
    fn each_arm_of_the_persistence_door_answers_for_a_row_that_has_it() {
        assert_eq!(
            slopdesk_settings_row_persistence(index_of("general.onLaunch")),
            0,
            "an ordinary defaults key a global reset reaches",
        );
        assert_eq!(
            slopdesk_settings_row_persistence(index_of("follow-session-focus")),
            1,
            "device-local: `device-prefs.json` holds it, so a defaults reset cannot",
        );
        assert_eq!(
            slopdesk_settings_row_persistence(index_of("font-family")),
            2,
            "a typed render field, restored with the model it belongs to",
        );
        assert_eq!(
            slopdesk_settings_row_persistence(slopdesk_settings_row_count()),
            0,
            "past the end answers the arm a reset already reaches, never a fourth case",
        );
    }

    #[test]
    fn a_row_whose_control_is_the_macs_alone_crosses_as_hidden_from_the_phone() {
        let dock = index_of("appearance.dockIconErrorBadge");
        assert!(slopdesk_settings_row_shown(dock, true));
        assert!(
            !slopdesk_settings_row_shown(dock, false),
            "a ✎ into an Appearance page with no Dock Icon group on it",
        );
        let both = index_of("controls.copyOnSelect");
        assert!(slopdesk_settings_row_shown(both, true) && slopdesk_settings_row_shown(both, false));
        assert!(
            !slopdesk_settings_row_shown(slopdesk_settings_row_count(), true),
            "past the end names no row, so there is nothing to advertise",
        );
    }

    #[test]
    fn an_empty_query_reports_the_whole_list() {
        let mut out = [0_usize; 128];
        // SAFETY: both buffers are live locals.
        let found =
            unsafe { slopdesk_settings_row_matches(core::ptr::null(), 0, out.as_mut_ptr(), out.len()) };
        assert_eq!(found, slopdesk_settings_row_count());
    }
}
