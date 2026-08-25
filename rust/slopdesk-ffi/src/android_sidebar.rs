//! The Android sidebar's list rules, clocks and words, in C.
//!
//! The rules are `slopdesk_devicepanel::android_sidebar`; what is here is the marshalling.
//!
//! ## No identity crosses
//!
//! A device key and a device serial are strings the near side holds, and neither of them travels.
//! The list crosses as one three-flag record per row saying which rows the question is ABOUT, and
//! the lookup door answers a POSITION into the array the caller still has. That is
//! `slopdesk_ws_most_recent_survivor`'s shape: the comparison belongs to whoever owns the values,
//! the fold over its results belongs to the crate.
//!
//! ## One number family, one door
//!
//! Eleven measures — two counts and nine durations — cross through a single indexed door rather
//! than eleven entry points, for the reason `docs/55` gives about the constant door. An index no
//! build wrote answers `0`, which no member of the family can be.
//!
//! ## The words
//!
//! The five NOTICES are a fixed table and cross in one delivery, read once into a Swift
//! `static let`. The six REPORTS interpolate a device name, so each is a call: a failure is rare
//! enough that the allocation `docs/55`'s cost table warns about is not on any path that repeats.

use core::ffi::c_uchar;

use slopdesk_devicepanel::android_sidebar::{
    DeviceRow, Notice, Report, boot_is_visible, log_overflow, measure, row_position, shutdown_is_visible,
    stream_size_is_news, within_grace,
};

use crate::{borrow, deliver, optional_of, push_text};

/// One device row, in the three flags the list rules read.
///
/// `matches_key` and `matches_serial` are the CALLER's comparison — it holds the strings — and the
/// rest of the answer is the crate's. A row where both are false is one that is merely present,
/// which most of them are.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SlopDeskAndroidSidebarRow {
    /// Whether this row is the one the caller named by key.
    pub matches_key: bool,
    /// Whether this row carries the serial the caller named.
    pub matches_serial: bool,
    /// Whether the row has a serial at all.
    pub has_serial: bool,
}

/// Lends the caller's rows as the rule's own record.
///
/// # Safety
/// `(rows, len)` must be readable for the call.
#[expect(
    unsafe_code,
    reason = "this IS the boundary: the caller's array becoming a slice"
)]
unsafe fn lend_rows(rows: *const SlopDeskAndroidSidebarRow, len: usize) -> Vec<DeviceRow> {
    // SAFETY: the caller's obligation, restated above; the borrow dies with this call.
    unsafe { borrow(rows, len) }
        .iter()
        .map(|row| {
            DeviceRow {
                matches_key: row.matches_key,
                matches_serial: row.matches_serial,
                has_serial: row.has_serial,
            }
        })
        .collect()
}

/// Where the row named by key sits, or `-1` when the list no longer carries it.
///
/// A signed sentinel rather than a presence flag because a position is never negative by
/// construction — the convention `slopdesk_ws_swap_partner` keeps.
///
/// # Safety
/// `(rows, len)` must be readable for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and the pointer is the caller's"
)]
pub unsafe extern "C" fn slopdesk_android_sidebar_row_position(
    rows: *const SlopDeskAndroidSidebarRow,
    len: usize,
) -> isize {
    // SAFETY: the caller's obligation, restated above.
    let lent = unsafe { lend_rows(rows, len) };
    row_position(&lent)
        .and_then(|position| isize::try_from(position).ok())
        .unwrap_or(-1)
}

/// Whether the boot the caller is holding a spinner for has SURFACED in this list.
///
/// # Safety
/// `(rows, len)` must be readable for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and the pointer is the caller's"
)]
pub unsafe extern "C" fn slopdesk_android_sidebar_boot_is_visible(
    rows: *const SlopDeskAndroidSidebarRow,
    len: usize,
) -> bool {
    // SAFETY: the caller's obligation, restated above.
    let lent = unsafe { lend_rows(rows, len) };
    boot_is_visible(&lent)
}

/// Whether the shutdown the caller is holding a spinner for has LANDED in this list.
///
/// # Safety
/// `(rows, len)` must be readable for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and the pointer is the caller's"
)]
pub unsafe extern "C" fn slopdesk_android_sidebar_shutdown_is_visible(
    rows: *const SlopDeskAndroidSidebarRow,
    len: usize,
) -> bool {
    // SAFETY: the caller's obligation, restated above.
    let lent = unsafe { lend_rows(rows, len) };
    shutdown_is_visible(&lent)
}

/// How many console rows to drop from the FRONT at `count`. `0` while the console is under its cap.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_android_sidebar_log_overflow(count: usize) -> usize {
    log_overflow(count)
}

/// Whether a session packet's geometry is worth writing to the panel's one size field.
///
/// `has_current` false is "the stream has not named a size yet", and then any real size is news.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_android_sidebar_stream_size_is_news(
    has_current: bool,
    current_width: f64,
    current_height: f64,
    width: f64,
    height: f64,
) -> bool {
    stream_size_is_news(
        optional_of(has_current, (current_width, current_height)),
        width,
        height,
    )
}

/// Whether a wait for video still has patience left.
///
/// `has_elapsed` false is "no campaign is running", which is always within grace.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_android_sidebar_within_grace(has_elapsed: bool, elapsed_ms: u64) -> bool {
    within_grace(optional_of(has_elapsed, elapsed_ms))
}

/// The failure sentence for `kind`, with `name` folded in where the report names a device.
///
/// An empty or absent name reads as the anonymous subject rather than leaving a hole at the front
/// of the sentence. A `kind` this build cannot name answers `0` — no sentence, rather than the
/// wrong one.
///
/// # Safety
/// `(name, name_len)` must be readable for the call, and `out` either null or writable for `cap`
/// bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and both pointers are the caller's"
)]
pub unsafe extern "C" fn slopdesk_android_sidebar_report(
    kind: u8,
    name: *const c_uchar,
    name_len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    let Some(report) = Report::from_code(kind) else {
        return 0;
    };
    // SAFETY: the caller's obligation, restated above; the borrow dies with this call.
    let bytes = unsafe { borrow(name, name_len) };
    let sentence = report.sentence(&String::from_utf8_lossy(bytes));
    // SAFETY: `out` is the caller's, writable for `cap` by the obligation above.
    unsafe { deliver(sentence.as_bytes(), out, cap) }
}

/// Every confirmation the panel shows, in one delivery.
///
/// Five `[uint32 length][UTF-8 bytes]` runs, in `Notice::ALL` order: screen on, screen off, pasted,
/// copied, screenshot copied. The field ORDER is the contract.
///
/// # Safety
/// `out` must be null, or writable for `cap` bytes for the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and the pointer is the caller's"
)]
pub unsafe extern "C" fn slopdesk_android_sidebar_notices(out: *mut c_uchar, cap: usize) -> usize {
    let mut blob: Vec<u8> = Vec::new();
    for notice in Notice::ALL {
        push_text(&mut blob, notice.text());
    }
    // SAFETY: `out` is the caller's, writable for `cap` by the obligation above.
    unsafe { deliver(&blob, out, cap) }
}

/// The measure at `index` — rows for the console cap, PIXELS for the mirror's edge, milliseconds
/// for the nine clocks. `0` for an index this build cannot name.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_android_sidebar_measure(index: u32) -> u64 {
    measure(index)
}

#[cfg(test)]
#[expect(
    unsafe_code,
    reason = "calling the boundary the way Swift does IS what these tests are for"
)]
mod tests {
    use slopdesk_devicepanel::android_sidebar::{Measure, Notice, Report};

    use super::{
        SlopDeskAndroidSidebarRow, slopdesk_android_sidebar_boot_is_visible,
        slopdesk_android_sidebar_log_overflow, slopdesk_android_sidebar_measure,
        slopdesk_android_sidebar_notices, slopdesk_android_sidebar_report,
        slopdesk_android_sidebar_row_position, slopdesk_android_sidebar_shutdown_is_visible,
        slopdesk_android_sidebar_stream_size_is_news, slopdesk_android_sidebar_within_grace,
    };

    /// A row that is nobody's subject and carries nothing.
    const fn blank() -> SlopDeskAndroidSidebarRow {
        SlopDeskAndroidSidebarRow {
            matches_key: false,
            matches_serial: false,
            has_serial: false,
        }
    }

    /// The lookup door, over a slice the way Swift lends one.
    fn position_of(rows: &[SlopDeskAndroidSidebarRow]) -> isize {
        // SAFETY: the borrow lives for the call, which is the whole obligation.
        unsafe { slopdesk_android_sidebar_row_position(rows.as_ptr(), rows.len()) }
    }

    /// One delivery from a door, with `docs/55` §4's retry.
    fn answer(door: unsafe extern "C" fn(*mut u8, usize) -> usize) -> Vec<u8> {
        // SAFETY: null with a zero cap is the documented length probe.
        let needed = unsafe { door(core::ptr::null_mut(), 0) };
        let mut room = vec![0_u8; needed];
        // SAFETY: the buffer is exactly `needed` bytes and lives for the call.
        let written = unsafe { door(room.as_mut_ptr(), room.len()) };
        room.truncate(written.min(needed));
        room
    }

    /// The runs a `[uint32 length][UTF-8]` blob carries.
    fn runs(blob: &[u8]) -> Vec<String> {
        let mut out: Vec<String> = Vec::new();
        let mut cursor = 0_usize;
        while let Some(prefix) = blob.get(cursor..cursor.saturating_add(4)) {
            let mut length = 0_usize;
            for byte in prefix {
                length = length.saturating_mul(256).saturating_add(usize::from(*byte));
            }
            cursor = cursor.saturating_add(4);
            let Some(text) = blob.get(cursor..cursor.saturating_add(length)) else {
                break;
            };
            out.push(String::from_utf8_lossy(text).into_owned());
            cursor = cursor.saturating_add(length);
        }
        out
    }

    #[test]
    fn the_lookup_answers_a_position_and_minus_one_for_a_list_without_the_row() {
        assert_eq!(position_of(&[]), -1);
        assert_eq!(position_of(&[blank(), blank()]), -1);
        let named = SlopDeskAndroidSidebarRow {
            matches_key: true,
            ..blank()
        };
        assert_eq!(position_of(&[blank(), named, blank()]), 1);
        assert_eq!(
            position_of(&[named, named]),
            0,
            "the first match, as every reader took it"
        );
    }

    #[test]
    fn a_null_list_reads_as_an_empty_one_rather_than_a_trap() {
        // SAFETY: null is the documented "no rows", and `borrow` answers an empty slice for it.
        let position = unsafe { slopdesk_android_sidebar_row_position(core::ptr::null(), 0) };
        assert_eq!(position, -1);
        // SAFETY: same probe, against the two verdict doors.
        let (booted, shut) = unsafe {
            (
                slopdesk_android_sidebar_boot_is_visible(core::ptr::null(), 0),
                slopdesk_android_sidebar_shutdown_is_visible(core::ptr::null(), 0),
            )
        };
        assert!(!booted, "no rows is not a boot that surfaced");
        assert!(shut, "no rows is a shutdown that landed");
    }

    #[test]
    fn a_zero_length_list_with_a_live_pointer_reads_the_same_way() {
        let rows = [blank()];
        // SAFETY: the pointer is live; the length says to read none of it.
        let position = unsafe { slopdesk_android_sidebar_row_position(rows.as_ptr(), 0) };
        assert_eq!(position, -1);
    }

    #[test]
    fn the_two_lifecycle_verdicts_cross_whole() {
        let surfaced = SlopDeskAndroidSidebarRow {
            matches_key: true,
            has_serial: true,
            ..blank()
        };
        let waiting = SlopDeskAndroidSidebarRow {
            matches_key: true,
            ..blank()
        };
        let carrier = SlopDeskAndroidSidebarRow {
            matches_serial: true,
            ..blank()
        };
        // SAFETY: every borrow lives for its call.
        unsafe {
            let one = [surfaced];
            assert!(slopdesk_android_sidebar_boot_is_visible(one.as_ptr(), one.len()));
            let two = [waiting];
            assert!(!slopdesk_android_sidebar_boot_is_visible(two.as_ptr(), two.len()));
            let three = [blank(), carrier];
            assert!(!slopdesk_android_sidebar_shutdown_is_visible(
                three.as_ptr(),
                three.len()
            ));
            let four = [blank(), blank()];
            assert!(slopdesk_android_sidebar_shutdown_is_visible(
                four.as_ptr(),
                four.len()
            ));
        }
    }

    #[test]
    fn the_console_trim_crosses_as_a_count() {
        let capacity = usize::try_from(Measure::LogCapacity.value()).unwrap_or(usize::MAX);
        assert_eq!(slopdesk_android_sidebar_log_overflow(0), 0);
        assert_eq!(slopdesk_android_sidebar_log_overflow(capacity), 0);
        assert_eq!(slopdesk_android_sidebar_log_overflow(capacity + 7), 7);
    }

    #[test]
    fn the_size_gate_reads_its_presence_flag_rather_than_a_sentinel() {
        assert!(slopdesk_android_sidebar_stream_size_is_news(
            false, 0.0, 0.0, 1024.0, 2280.0
        ));
        assert!(!slopdesk_android_sidebar_stream_size_is_news(
            true, 1024.0, 2280.0, 1024.0, 2280.0
        ));
        assert!(slopdesk_android_sidebar_stream_size_is_news(
            true, 1024.0, 2280.0, 720.0, 1600.0
        ));
        assert!(!slopdesk_android_sidebar_stream_size_is_news(
            false, 0.0, 0.0, 0.0, 2280.0
        ));
        assert!(!slopdesk_android_sidebar_stream_size_is_news(
            false, 0.0, 0.0, 1024.0, 0.0
        ));
    }

    #[test]
    fn patience_reads_its_presence_flag_too() {
        let grace = Measure::DeviceGraceMs.value();
        assert!(slopdesk_android_sidebar_within_grace(false, u64::MAX));
        assert!(slopdesk_android_sidebar_within_grace(true, 0));
        assert!(!slopdesk_android_sidebar_within_grace(true, grace));
    }

    #[test]
    fn every_report_crosses_with_its_name_folded_in() {
        for report in Report::ALL {
            let name = "Pixel 8";
            // SAFETY: both the name and the buffer live for their calls.
            let needed = unsafe {
                slopdesk_android_sidebar_report(
                    report.code(),
                    name.as_ptr(),
                    name.len(),
                    core::ptr::null_mut(),
                    0,
                )
            };
            let mut room = vec![0_u8; needed];
            // SAFETY: the buffer is exactly what the probe asked for.
            let written = unsafe {
                slopdesk_android_sidebar_report(
                    report.code(),
                    name.as_ptr(),
                    name.len(),
                    room.as_mut_ptr(),
                    room.len(),
                )
            };
            assert_eq!(written, needed);
            room.truncate(written);
            assert_eq!(String::from_utf8_lossy(&room), report.sentence(name));
        }
    }

    #[test]
    fn a_short_buffer_writes_nothing_and_reports_what_it_needed() {
        let name = "Pixel 8";
        let mut room = [0_u8; 2];
        // SAFETY: both pointers are live for the call; the buffer is deliberately too small.
        let needed = unsafe {
            slopdesk_android_sidebar_report(
                Report::NoLongerRunning.code(),
                name.as_ptr(),
                name.len(),
                room.as_mut_ptr(),
                room.len(),
            )
        };
        assert!(needed > room.len(), "a short lend is told what to lend");
        assert_eq!(room, [0, 0], "and nothing was written into it");
    }

    #[test]
    fn a_missing_name_still_names_something_and_an_unknown_kind_says_nothing() {
        // SAFETY: null with a zero length is the documented empty string.
        let needed = unsafe {
            slopdesk_android_sidebar_report(
                Report::NoLongerRunning.code(),
                core::ptr::null(),
                0,
                core::ptr::null_mut(),
                0,
            )
        };
        let mut room = vec![0_u8; needed];
        // SAFETY: the buffer is exactly what the probe asked for.
        let written = unsafe {
            slopdesk_android_sidebar_report(
                Report::NoLongerRunning.code(),
                core::ptr::null(),
                0,
                room.as_mut_ptr(),
                room.len(),
            )
        };
        room.truncate(written);
        assert_eq!(
            String::from_utf8_lossy(&room),
            "This device is no longer running."
        );

        let unnamed = u8::try_from(Report::ALL.len()).unwrap_or(u8::MAX);
        // SAFETY: null pointers with zero lengths, which every door reads as no answer.
        let nothing = unsafe {
            slopdesk_android_sidebar_report(unnamed, core::ptr::null(), 0, core::ptr::null_mut(), 0)
        };
        assert_eq!(nothing, 0, "a kind this build cannot name has no sentence");
    }

    #[test]
    fn the_notice_table_crosses_whole_and_in_order() {
        let blob = answer(slopdesk_android_sidebar_notices);
        let table = runs(&blob);
        let expected: Vec<String> = Notice::ALL
            .iter()
            .map(|notice| notice.text().to_owned())
            .collect();
        assert_eq!(table, expected);
        assert_eq!(
            table.len(),
            5,
            "the field order is the contract, so the count is part of it"
        );
    }

    #[test]
    fn every_measure_crosses_and_an_unknown_index_answers_zero() {
        for known in Measure::ALL {
            assert_eq!(slopdesk_android_sidebar_measure(known.index()), known.value());
            assert!(slopdesk_android_sidebar_measure(known.index()) > 0);
        }
        let count = u32::try_from(Measure::ALL.len()).unwrap_or(u32::MAX);
        assert_eq!(slopdesk_android_sidebar_measure(count), 0);
        assert_eq!(slopdesk_android_sidebar_measure(u32::MAX), 0);
    }
}
