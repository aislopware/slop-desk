//! The Android console's log-level filter, in C — `Sources/SlopDeskDevicePanels/Android/
//! AndroidLogLevel.swift`.
//!
//! The table is [`slopdesk_androidd::protocol::LOGCAT_LEVELS`]; what is here is the marshalling.
//!
//! ## Why the menu could not keep its own copy
//!
//! There were three lists of `logcat` priority letters in this tree and two of them were answering
//! the same question. `LOGCAT_LEVELS` is the FILTER alphabet: the letter the client picks is
//! interpolated into `*:<level>` and reaches an argument vector, and `logcat` treats an unparsable
//! filter spec as a fatal error, so androidd validates against that array before spawning.
//! `AndroidLogLevel` was the MENU the client picks from — the same set, written again in Swift, and
//! it stopped one letter short: it offered `V D I W E` where the alphabet is `V D I W E F`. The
//! consequence was not a crash, which is why it survived. It was a filter the user could not ask
//! for: `F` is `logcat`'s FATAL, so the one severity someone opens a console to find had no way to
//! be selected, and the menu simply did not admit that the level existed.
//!
//! `slopdesk_devicelog::logcat`'s wider `F|A|E|W|I|V|D|S` is NOT a third copy of this and is
//! deliberately left alone. It answers a different question — which leading letter of a PRINTED
//! line is a priority rather than the first word of a sentence — so it carries `A` (assert, which
//! some builds print in place of `F`) and `S` (silent, a filter level that never appears in output
//! but is accepted so the parse cannot disagree with a spec that named it). A parser being
//! permissive where a spawner is strict is the correct asymmetry, not drift.
//!
//! ## Why two doors rather than one blob
//!
//! [`crate::settings_catalog`]'s shape, for its reason: a count and an indexed read make no
//! assumption about how long an entry is. Delivering `VDIWEF` as six bytes would have worked only
//! because every priority happens to be one letter, which would put a rule about `logcat`'s
//! spelling back on the near side — the exact thing this module exists to end.

use core::ffi::c_uchar;

use slopdesk_androidd::protocol::LOGCAT_LEVELS;

use crate::deliver;

/// How many levels the filter menu offers.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_android_log_level_count() -> usize {
    LOGCAT_LEVELS.len()
}

/// The `logcat` priority letter at `index`, least severe first.
///
/// `0` is "no such level", which cannot collide with a real answer: every entry in the alphabet is
/// a non-empty letter, so an empty delivery is outside the answer's range by construction.
///
/// # Safety
/// `(out, cap)` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and `(out, cap)` is the caller's buffer"
)]
pub unsafe extern "C" fn slopdesk_android_log_level_letter(
    index: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    let Some(level) = LOGCAT_LEVELS.get(index) else {
        return 0;
    };
    // SAFETY: the caller's contract.
    unsafe { deliver(level.as_bytes(), out, cap) }
}

#[cfg(test)]
#[expect(unsafe_code, reason = "calling the boundary IS what these tests are for")]
mod tests {
    use super::{slopdesk_android_log_level_count, slopdesk_android_log_level_letter};

    fn letter(index: usize) -> Option<String> {
        let mut buffer = [0_u8; 8];
        // SAFETY: the buffer is a live local.
        let needed = unsafe { slopdesk_android_log_level_letter(index, buffer.as_mut_ptr(), buffer.len()) };
        if needed == 0 {
            return None;
        }
        buffer
            .get(..needed)
            .map(|bytes| String::from_utf8_lossy(bytes).into_owned())
    }

    #[test]
    fn the_menu_reads_the_whole_filter_alphabet_including_fatal() {
        let offered: Vec<String> = (0..slopdesk_android_log_level_count())
            .filter_map(letter)
            .collect();
        assert_eq!(offered, ["V", "D", "I", "W", "E", "F"]);
    }

    #[test]
    fn an_index_past_the_end_is_no_level_rather_than_a_wrong_one() {
        assert_eq!(letter(slopdesk_android_log_level_count()), None);
        assert_eq!(letter(usize::MAX), None);
    }
}
