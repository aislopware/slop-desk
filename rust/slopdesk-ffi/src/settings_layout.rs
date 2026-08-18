//! The shape of a settings page, in C.
//!
//! The rules are `slopdesk_workspace::settings_layout`; what is here is the marshalling.
//!
//! ## The half asking is an ARGUMENT, not the slice
//!
//! Every door takes `mac: bool`. That looks redundant — the xcframework is built per slice, so the
//! Mac renderer could have been given a table already filtered by `cfg!` — and it is deliberate.
//! Filtering by the compiled slice would make "which groups does the phone show" unanswerable on a
//! Mac, and that question is exactly what the tests on both sides ask. A platform gate became data
//! so that it could be READ; compiling it back in would give the property away again.
//!
//! ## A group and a row are addressed positionally, within the filter
//!
//! `(section, mac)` selects a page; a group index selects within that page's FILTERED list, and a
//! row index within that group's filtered rows. So a phone asking for group 4 of General gets
//! whatever its own fourth group is, never a hole where a macOS-only group was. The near side never
//! sees the unfiltered table and cannot accidentally render from it.

use core::ffi::c_uchar;

use slopdesk_workspace::settings_catalog::Section;
use slopdesk_workspace::settings_layout::{self, LayoutGroup, LayoutRow};

use crate::deliver;

/// What the group and row accessors answer for a position or a section that does not exist.
pub const SLOPDESK_SETTINGS_LAYOUT_NONE: u8 = u8::MAX;

/// The page a section index names, or `None` for an index no section has.
fn section(index: u8) -> Option<Section> {
    Section::ALL.get(index as usize).copied()
}

/// The group at a position on a page, as one half sees that page.
fn group(section_index: u8, mac: bool, group_index: usize) -> Option<&'static LayoutGroup> {
    settings_layout::group_at(section(section_index)?, mac, group_index)
}

/// The row at a position within a group, as one half sees both.
fn row(section_index: u8, mac: bool, group_index: usize, row_index: usize) -> Option<&'static LayoutRow> {
    settings_layout::row_at(section(section_index)?, mac, group_index, row_index)
}

/// How many groups one half draws on one page.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_settings_layout_group_count(section_index: u8, mac: bool) -> usize {
    section(section_index).map_or(0, |page| settings_layout::groups(page, mac).len())
}

/// A group's header.
///
/// # Safety
/// `(out, cap)` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_settings_layout_group_title(
    section_index: u8,
    mac: bool,
    group_index: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    let Some(found) = group(section_index, mac, group_index) else {
        return 0;
    };
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe { deliver(found.title.as_bytes(), out, cap) }
}

/// The apply-timing footer a group carries, as an `ApplyTiming` case index, or
/// [`SLOPDESK_SETTINGS_LAYOUT_NONE`] for a group that is not there.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_settings_layout_group_timing(
    section_index: u8,
    mac: bool,
    group_index: usize,
) -> u8 {
    group(section_index, mac, group_index).map_or(SLOPDESK_SETTINGS_LAYOUT_NONE, |found| found.timing.index())
}

/// How many rows one half draws in one group.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_settings_layout_row_count(
    section_index: u8,
    mac: bool,
    group_index: usize,
) -> usize {
    group(section_index, mac, group_index).map_or(0, |found| settings_layout::rows(found, mac).len())
}

/// The setting a row edits. Empty for a bespoke group, which edits no single key.
///
/// # Safety
/// `(out, cap)` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_settings_layout_row_key(
    section_index: u8,
    mac: bool,
    group_index: usize,
    row_index: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe {
        row_field(section_index, mac, group_index, row_index, out, cap, |found| {
            found.key
        })
    }
}

/// The gray line under a row's label.
///
/// # Safety
/// `(out, cap)` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_settings_layout_row_subtitle(
    section_index: u8,
    mac: bool,
    group_index: usize,
    row_index: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe {
        row_field(section_index, mac, group_index, row_index, out, cap, |found| {
            found.subtitle
        })
    }
}

/// The leading SF Symbol a row draws, empty where it draws none.
///
/// # Safety
/// `(out, cap)` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_settings_layout_row_glyph(
    section_index: u8,
    mac: bool,
    group_index: usize,
    row_index: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe {
        row_field(section_index, mac, group_index, row_index, out, cap, |found| {
            found.control.glyph().unwrap_or("")
        })
    }
}

/// What the renderer switches on to draw a bespoke group, empty for every other control kind.
///
/// # Safety
/// `(out, cap)` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_settings_layout_row_bespoke_id(
    section_index: u8,
    mac: bool,
    group_index: usize,
    row_index: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe {
        row_field(section_index, mac, group_index, row_index, out, cap, |found| {
            found.control.bespoke_id()
        })
    }
}

/// What a row draws, as a `Control` case index, or [`SLOPDESK_SETTINGS_LAYOUT_NONE`] for a row that
/// is not there.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_settings_layout_row_control(
    section_index: u8,
    mac: bool,
    group_index: usize,
    row_index: usize,
) -> u8 {
    row(section_index, mac, group_index, row_index)
        .map_or(SLOPDESK_SETTINGS_LAYOUT_NONE, |found| found.control.kind())
}

/// The option `Group` or scalar `Ladder` a row's control draws over, or
/// [`SLOPDESK_SETTINGS_LAYOUT_NONE`] where its kind draws over neither.
///
/// Which of the two it is follows from [`slopdesk_settings_layout_row_control`], which the caller
/// has necessarily already read to know what widget to build.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_settings_layout_row_control_argument(
    section_index: u8,
    mac: bool,
    group_index: usize,
    row_index: usize,
) -> u8 {
    row(section_index, mac, group_index, row_index)
        .and_then(|found| found.control.argument())
        .unwrap_or(SLOPDESK_SETTINGS_LAYOUT_NONE)
}

/// Delivers one of a row's string fields, or nothing when the position names no row.
///
/// # Safety
/// `(out, cap)` must be writable for `cap` bytes.
#[expect(
    unsafe_code,
    reason = "the delivery is the marshalling; every door above restates the same obligation"
)]
unsafe fn row_field(
    section_index: u8,
    mac: bool,
    group_index: usize,
    row_index: usize,
    out: *mut c_uchar,
    cap: usize,
    field: impl Fn(&LayoutRow) -> &'static str,
) -> usize {
    let Some(found) = row(section_index, mac, group_index, row_index) else {
        return 0;
    };
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe { deliver(field(found).as_bytes(), out, cap) }
}

#[cfg(test)]
#[expect(unsafe_code, reason = "calling the boundary IS what these tests are for")]
mod tests {
    use super::*;

    /// Reads a door that delivers a string, at a capacity no field here exceeds.
    fn text(door: impl Fn(*mut c_uchar, usize) -> usize) -> String {
        let mut out = [0u8; 256];
        let written = door(out.as_mut_ptr(), out.len());
        assert!(written <= out.len(), "a field overflowed the test's buffer");
        out.get(..written)
            .map_or_else(String::new, |bytes| String::from_utf8_lossy(bytes).into_owned())
    }

    /// The General page crosses whole, and the two halves differ by exactly the group iOS cannot
    /// back. Asserted THROUGH the boundary rather than against the table, because the point of the
    /// `mac` argument is that one process can ask both questions.
    #[test]
    fn both_halves_of_the_general_page_cross() {
        let general = 0u8;
        let titles = |mac: bool| {
            (0..slopdesk_settings_layout_group_count(general, mac))
                .map(|index| {
                    // SAFETY: `out` is the probe buffer, live for the call.
                    text(|out, cap| unsafe {
                        slopdesk_settings_layout_group_title(general, mac, index, out, cap)
                    })
                })
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
        let (general, group_index, row_index) = (0u8, 2usize, 0usize);
        assert_eq!(
            slopdesk_settings_layout_row_control(general, true, group_index, row_index),
            0
        );
        assert_eq!(
            slopdesk_settings_layout_row_control_argument(general, true, group_index, row_index),
            SLOPDESK_SETTINGS_LAYOUT_NONE,
        );
        assert_eq!(
            text(|out, cap| {
                // SAFETY: `out` is the probe buffer, live for the call.
                unsafe { slopdesk_settings_layout_row_glyph(general, true, group_index, row_index, out, cap) }
            }),
            "eye.slash",
        );
        assert_eq!(
            text(|out, cap| {
                // SAFETY: `out` is the probe buffer, live for the call.
                unsafe { slopdesk_settings_layout_row_key(general, true, group_index, row_index, out, cap) }
            }),
            "features.redactSecrets",
        );
    }

    /// A menu crosses carrying the option group it lists.
    #[test]
    fn a_menu_crosses_carrying_its_option_group() {
        // General → General → On launch, which lists `Group::OnLaunch` (case index 7).
        assert_eq!(slopdesk_settings_layout_row_control(0, true, 0, 0), 1);
        assert_eq!(slopdesk_settings_layout_row_control_argument(0, true, 0, 0), 7);
    }

    /// A position past the end is not a group, and neither is a section index no section has.
    #[test]
    fn nothing_is_read_past_the_end() {
        assert_eq!(slopdesk_settings_layout_group_count(200, true), 0);
        assert_eq!(
            slopdesk_settings_layout_group_timing(0, true, 99),
            SLOPDESK_SETTINGS_LAYOUT_NONE
        );
        assert_eq!(slopdesk_settings_layout_row_count(0, true, 99), 0);
        assert_eq!(
            slopdesk_settings_layout_row_control(0, true, 0, 99),
            SLOPDESK_SETTINGS_LAYOUT_NONE
        );
        assert_eq!(
            text(|out, cap| {
                // SAFETY: `out` is the probe buffer, live for the call.
                unsafe { slopdesk_settings_layout_group_title(0, true, 99, out, cap) }
            }),
            "",
        );
    }

    /// A string door that cannot fit its answer writes nothing and reports the size to ask at — the
    /// retry protocol every other door here follows.
    #[test]
    fn a_field_too_long_for_the_buffer_reports_its_size() {
        let mut tiny = [0u8; 2];
        // SAFETY: `tiny` is a live local for the call.
        let needed =
            unsafe { slopdesk_settings_layout_group_title(0, true, 1, tiny.as_mut_ptr(), tiny.len()) };
        assert_eq!(needed, "Close Confirmation".len());
        assert_eq!(tiny, [0, 0], "nothing is written when the answer does not fit");
    }
}
