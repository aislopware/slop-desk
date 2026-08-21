//! Which pane kind a persisted DISCRIMINATOR names, in C.
//!
//! One door over [`slopdesk_workspace::session::PaneKind::from_raw`], which is where the retired
//! vocabulary lives: `claudeCode`, `web`, `chooser`, `remoteGUI` and `systemDialog` are the five
//! kinds this project has removed, and each of them names a pane that is still a pane — a plain
//! terminal — rather than a file that must be refused.
//!
//! ## Why the STRING side needs a door at all when the byte side already has one
//! A `PaneKind` reaches this boundary as a byte nearly everywhere
//! (`slopdesk_ws_pane_kind_is_video`, every `ffiByte` on a topology crossing) because the workspace
//! document spells it as one, and `slopdesk_workspace::persist` reads the workspace FILE's string
//! form on the Rust side of its own door. Neither of those covers the one file whose decoder is
//! still Foundation's: `device-prefs.json` carries the captured session-template library, a
//! `TemplatePane` inside it carries a `PaneKind`, and `JSONDecoder` reaches the Swift `init(from:)`
//! on every launch. That decode had the five retired names written out a second time, beside a fold
//! that had to agree with this crate's by inspection — a third copy of a rule that already had an
//! owner.
//!
//! The failure that copy sets up is not a wrong pane. `DevicePreferences` decodes as one
//! synthesized whole, so a `PaneKind` that THROWS unwinds past the template library, past the
//! latched video modes and past the per-host connection targets, and the store's `try?` answers a
//! fresh default — every device-local preference silently reset because one leaf of one template
//! named a kind that was retired after it was captured. A retired name that this side folds and
//! that side rejects is exactly that, and nothing logs it.
//!
//! ## What is NOT here
//! Which names are retired, and what each of them folds to. That list is `PaneKind::from_raw`'s, in
//! a crate that forbids `unsafe`; this module reads a `(ptr, len)` and hands the answer back as a
//! number. It is one entry point rather than a family: the retired set does not need to be WALKABLE
//! from Swift, because after this port the Swift side holds no copy of it to keep in step, and a
//! door nothing calls is the second way to ask a question a live door already answers.

use core::ffi::c_uchar;

use slopdesk_workspace::session::PaneKind;

use crate::borrow;

/// The kind byte a persisted discriminator names, or `-1` for one this build has never had.
///
/// A signed answer rather than §4's `(out, cap) -> needed` because `0` is the most common REAL
/// answer here — it is `terminal`, which is what every folded retired name becomes — so the
/// convention's "0 means there is no answer" is unavailable. `-1` is outside the answer's range by
/// construction: a kind byte is a case index, and a case index is never negative. That is the same
/// argument [`crate::fuzzy`]'s rank door makes for its own sentinel, and it is why the return type
/// has to say so rather than being a `size_t` a caller might read as a length.
///
/// A discriminator that is not valid UTF-8 is refused rather than read lossily, which is the
/// opposite of what [`crate::paste_safety`] does with a clipboard and right for the opposite
/// reason: a clipboard is whatever the platform handed over and must still be classified, while a
/// discriminator is one of a closed set of ASCII names, so bytes that are not one of them are
/// corruption in the file rather than an awkward payload.
///
/// # Safety
/// `(raw, len)` must be null, or describe `len` live bytes for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_pane_kind_from_raw(raw: *const c_uchar, len: usize) -> i32 {
    // SAFETY: the caller's obligation, restated above; `borrow` states its own.
    let bytes = unsafe { borrow(raw, len) };
    let Ok(name) = std::str::from_utf8(bytes) else {
        return -1;
    };
    PaneKind::from_raw(name).map_or(-1, |kind| i32::from(kind.as_byte()))
}

#[cfg(test)]
#[expect(unsafe_code, reason = "calling the boundary IS what these tests are for")]
mod tests {
    use slopdesk_workspace::session::PaneKind;

    use super::slopdesk_ws_pane_kind_from_raw;

    fn from_raw(name: &str) -> i32 {
        // SAFETY: the pointer names a live local for the duration of the call.
        unsafe { slopdesk_ws_pane_kind_from_raw(name.as_ptr(), name.len()) }
    }

    /// Walked rather than named, for the reason `slopdesk_ws_pane_kind_count` exists: a third kind
    /// added to the vocabulary is invisible to a test that lists the two it was written against.
    #[test]
    fn every_live_name_crosses_as_the_byte_its_own_case_carries() {
        for kind in PaneKind::ALL {
            assert_eq!(
                from_raw(kind.raw()),
                i32::from(kind.as_byte()),
                "{} crossed as a byte its case does not carry",
                kind.raw(),
            );
        }
    }

    /// Walked for the same reason, and the stakes are higher here: a sixth retirement that this
    /// door stopped folding would refuse a whole preferences file rather than one pane.
    #[test]
    fn every_retired_name_folds_to_a_terminal_rather_than_refusing() {
        for name in PaneKind::RETIRED_RAW_VALUES {
            assert_eq!(
                from_raw(name),
                i32::from(PaneKind::Terminal.as_byte()),
                "{name} must fold rather than refuse — a whole preferences file rides on it",
            );
        }
    }

    #[test]
    fn a_name_this_build_has_never_had_refuses_with_a_value_no_kind_can_be() {
        assert_eq!(from_raw("wormhole"), -1);
        assert_eq!(from_raw(""), -1, "a blank discriminator is not a kind");
        assert_eq!(
            from_raw("Terminal"),
            -1,
            "the names are case-sensitive, as the file writes them"
        );
        // SAFETY: a null pointer with a zero length is what `borrow` documents.
        assert_eq!(unsafe { slopdesk_ws_pane_kind_from_raw(std::ptr::null(), 0) }, -1);
    }

    #[test]
    fn bytes_that_are_not_utf8_refuse_rather_than_being_read_lossily() {
        let bytes = [0xFF_u8, 0xFE];
        // SAFETY: the pointer names a live local for the duration of the call.
        let answer = unsafe { slopdesk_ws_pane_kind_from_raw(bytes.as_ptr(), bytes.len()) };
        assert_eq!(answer, -1);
    }
}
