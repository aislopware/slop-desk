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

use slopdesk_workspace::settings_rows::{self, Bucket, SettingRow};

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

/// The label a settings PAGE shows for a row — the page register where it has one, the index
/// register otherwise, so the near side never has to know which rows carry an override.
///
/// # Safety
/// `(out, cap)` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_settings_row_page_label(
    index: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe { row_field(index, out, cap, SettingRow::page_label) }
}

/// A row's human label, as the flat INDEX shows it.
///
/// # Safety
/// `(out, cap)` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_settings_row_label(index: usize, out: *mut c_uchar, cap: usize) -> usize {
    // SAFETY: as above.
    unsafe { row_field(index, out, cap, |row| row.label) }
}

/// A row's one-line description.
///
/// # Safety
/// `(out, cap)` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_settings_row_description(
    index: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: as above.
    unsafe { row_field(index, out, cap, |row| row.description) }
}

/// What a row's default reads as.
///
/// # Safety
/// `(out, cap)` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_settings_row_default_text(
    index: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: as above.
    unsafe { row_field(index, out, cap, |row| row.default_text) }
}

/// The extra searchable text a row carries. `0` for a row that needs none.
///
/// # Safety
/// `(out, cap)` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_settings_row_keywords(
    index: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: as above.
    unsafe { row_field(index, out, cap, |row| row.keywords) }
}

/// The section a row jumps to, or `0` for one edited in place.
///
/// # Safety
/// `(out, cap)` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_settings_row_target_section(
    index: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: as above.
    unsafe { row_field(index, out, cap, |row| row.target_section) }
}

/// How a row is edited: `0` inline, `1` on a dedicated section. `0` for an index no row has, which
/// is safe because a caller that got here learned the row exists from the count.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_settings_row_bucket(index: usize) -> u8 {
    settings_rows::row_at(index).map_or_else(|| Bucket::AdvancedOnly.index(), |row| row.bucket.index())
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

/// One field of one row, delivered.
///
/// # Safety
/// `(out, cap)` must be writable for `cap` bytes.
#[expect(
    unsafe_code,
    reason = "the delivery is the marshalling; every door above restates the same obligation"
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

    #[test]
    fn a_row_crosses_field_by_field() {
        let index = index_of("controls.copyOnSelect");
        assert_ne!(index, SLOPDESK_SETTINGS_ROW_NONE);
        // SAFETY: the buffer inside `read` is a live local.
        let label = read(|out, cap| unsafe { slopdesk_settings_row_label(index, out, cap) });
        assert_eq!(label.as_deref(), Some("Copy on Select"));
        // SAFETY: as above.
        let key = read(|out, cap| unsafe { slopdesk_settings_row_key(index, out, cap) });
        assert_eq!(key.as_deref(), Some("controls.copyOnSelect"));
        // SAFETY: as above.
        let default = read(|out, cap| unsafe { slopdesk_settings_row_default_text(index, out, cap) });
        assert_eq!(default.as_deref(), Some("Off"));
        // SAFETY: as above.
        let target = read(|out, cap| unsafe { slopdesk_settings_row_target_section(index, out, cap) });
        assert_eq!(target, None, "an inline row jumps nowhere");
        assert_eq!(slopdesk_settings_row_bucket(index), 0);
        assert!(slopdesk_settings_row_is_inline_editable(index));
    }

    #[test]
    fn a_jump_row_names_its_section() {
        let index = index_of("font-family");
        // SAFETY: the buffer inside `read` is a live local.
        let target = read(|out, cap| unsafe { slopdesk_settings_row_target_section(index, out, cap) });
        assert_eq!(target.as_deref(), Some("appearance"));
        assert_eq!(slopdesk_settings_row_bucket(index), 1);
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
            read(|out, cap| unsafe { slopdesk_settings_row_label(9999, out, cap) }),
            None
        );
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
            // SAFETY: the buffer inside `read` is a live local.
            .filter_map(|index| read(|out, cap| unsafe { slopdesk_settings_row_label(*index, out, cap) }))
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
