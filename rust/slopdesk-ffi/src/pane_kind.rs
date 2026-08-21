//! What a pane KIND is — the discriminator that names one, and what one can be sent — in C.
//!
//! Two doors over [`slopdesk_workspace::session::PaneKind`], reached by two different callers. The
//! first reads a persisted discriminator; the second asks a kind byte whether text can be typed
//! into it. They are together because they are one vocabulary, not because they share a caller.
//!
//! The first is a door over [`slopdesk_workspace::session::PaneKind::from_raw`], which is where the
//! retired vocabulary lives: `claudeCode`, `web`, `chooser`, `remoteGUI` and `systemDialog` are the
//! five kinds this project has removed, and each of them names a pane that is still a pane — a
//! plain terminal — rather than a file that must be refused.
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
//! number. The retired set does not need to be WALKABLE from Swift, because after this port the
//! Swift side holds no copy of it to keep in step, and a door nothing calls is the second way to
//! ask a question a live door already answers.
//!
//! ## The second door, and why a one-line predicate is worth one
//! `docs/55` §6 says a one-line identity predicate stays in Swift — routing `self == .terminal`
//! through C only restates the case list. What that carve-out is about is a predicate over a
//! vocabulary NOBODY ELSE CLASSIFIES. `PaneKind` is not that: this crate already asks
//! `slopdesk_ws_pane_kind_is_video` on every restore, because the tree repair drops video panes,
//! and `check-supervisor.sh` fails if the Swift face stops asking for it.
//!
//! `can_receive_text` is the same classification's other half — which input funnel a kind has, a
//! PTY's or the cursor-and-key side channel — and it was `self == .terminal` in Swift beside a
//! `PaneKind::can_receive_text` in the crate that no Rust caller had ever reached. That pairing is
//! `docs/55` §8's `MIN_WEIGHT`/`MAX_DEPTH` anti-pattern exactly: two halves of one rule, one asked
//! through a door and one transcribed beside it, and one of the two is always wrong. A third kind
//! that streams a display AND takes typed text would have split them, with the broadcast recipient
//! set and the restore filter disagreeing about the same pane and both suites green.

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

/// Whether a `pane/kind` byte names a pane text can be TYPED into — the recipient set for
/// broadcast, or synchronized, input.
///
/// A predicate rather than a case list, for the reason [`crate::workspace`]'s video door gives one
/// section up in the module header: the two select complementary halves of the same vocabulary, and
/// a kind spelled out on one side of the boundary agrees with the crate right up until it does not.
///
/// A byte this build has no kind for reads as a terminal, which is where the whole boundary
/// degrades a `pane/kind` it does not recognise. Failing OPEN is right here for the same reason it
/// is right there: the worst case is a broadcast line delivered to a pane that renders it, against
/// a keystroke silently dropped for a pane the person is looking at.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_ws_pane_kind_can_receive_text(kind: c_uchar) -> bool {
    PaneKind::from_byte(kind).can_receive_text()
}

#[cfg(test)]
#[expect(unsafe_code, reason = "calling the boundary IS what these tests are for")]
mod tests {
    use slopdesk_workspace::session::PaneKind;

    use super::{slopdesk_ws_pane_kind_can_receive_text, slopdesk_ws_pane_kind_from_raw};

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

    /// Walked for the third time, and for the sharpest of the three reasons: a kind added on one
    /// side only is precisely what makes a transcribed `self == .terminal` stop selecting the same
    /// panes as the crate does.
    #[test]
    fn every_kind_crosses_with_the_input_funnel_its_own_case_has() {
        for kind in PaneKind::ALL {
            assert_eq!(
                slopdesk_ws_pane_kind_can_receive_text(kind.as_byte()),
                kind.can_receive_text(),
                "{} crossed with an input funnel its case does not have",
                kind.raw(),
            );
        }
    }

    #[test]
    fn a_byte_this_build_has_no_kind_for_takes_typed_text_the_way_a_terminal_does() {
        assert!(
            slopdesk_ws_pane_kind_can_receive_text(200),
            "an unrecognised kind degrades to a terminal, and a terminal takes text",
        );
    }

    #[test]
    fn bytes_that_are_not_utf8_refuse_rather_than_being_read_lossily() {
        let bytes = [0xFF_u8, 0xFE];
        // SAFETY: the pointer names a live local for the duration of the call.
        let answer = unsafe { slopdesk_ws_pane_kind_from_raw(bytes.as_ptr(), bytes.len()) };
        assert_eq!(answer, -1);
    }
}
