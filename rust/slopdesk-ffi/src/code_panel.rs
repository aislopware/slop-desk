//! The code panel's dressing, in C: one composed sheet and a catalogue of fixed texts.
//!
//! The rule is [`slopdesk_codepanel::dressing`]; what is here is the marshalling, and it is §4's
//! plain shape throughout — a lent buffer, and a return that is the number of BYTES the answer
//! needs, so a caller that lent too little is told exactly how much to lend.
//!
//! ## Why one door for eleven texts
//! Ten of the eleven are `&'static str` this process built once, and the eleventh is the
//! four-kilobyte dressing script whose three font URLs the caller alone knows. Eleven exported
//! symbols would be eleven header lines, eleven `REQUIRED_SYMBOLS` entries and eleven Swift
//! wrappers for what is one lookup — so the fixed texts share [`slopdesk_code_panel_text`] under
//! `SLOPDESK_CODE_PANEL_*` codes, and only [`slopdesk_code_panel_dressing_script`], which takes
//! arguments, stands alone.
//!
//! ## Why the sheet is composed on this side
//! The pool installs ONE user script. Handing the stylesheet out so Swift could hand it straight
//! back to be wrapped would copy several kilobytes of CSS and a base64 SVG across the boundary
//! twice, to no end — the composition is arithmetic, and arithmetic belongs where the strings are.

use core::ffi::c_uchar;

use slopdesk_codepanel::dressing;

use crate::deliver;

/// One of the panel's fixed texts, by code; `0` for a code this build does not know.
///
/// The codes are declared in `slopdesk_ffi.h` as `SLOPDESK_CODE_PANEL_*`. A caller passing a code
/// from a newer header than the linked artifact reads `0`, which is the same answer as "there is
/// nothing here" — the Swift face turns it into `nil` and the script is simply not installed,
/// rather than a page dressed with a truncated fragment.
///
/// # Safety
/// `out` must be null, or point to `cap` writable bytes for the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_code_panel_text(kind: u8, out: *mut c_uchar, cap: usize) -> usize {
    let answer: &str = match kind {
        0 => dressing::STYLE_ELEMENT_ID,
        1 => dressing::CLIPBOARD_HANDLER_NAME,
        2 => dressing::CANVAS_STYLE_ELEMENT_ID,
        3 => dressing::WORKBENCH_CONFIGURATION_META_ID,
        4 => dressing::FOCUS_TRUTH_SYNC_NAME,
        5 => dressing::FOCUS_TRUTH_SYNC_CALL,
        6 => dressing::focus_truth_script(),
        7 => dressing::webview_canvas_script(),
        8 => dressing::clipboard_bridge_script(),
        9 => dressing::bundled_recommendation_tips_script(),
        10 => dressing::NERD_FONT_FAMILY,
        11 => dressing::MONO_FONT_FAMILY,
        _ => "",
    };
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe { deliver(answer.as_bytes(), out, cap) }
}

/// The finished dressing user script for a webview whose bundle resolved these faces.
///
/// Each face is a `(bytes, len)` pair the caller lends for the call, or `(null, 0)` for a face this
/// bundle has no resource for — the sheet then omits it rather than naming a URL the pool's scheme
/// handler would 404. Bytes that are not UTF-8 are read lossily: a mangled URL is a face that does
/// not load, and refusing the whole sheet over one would take the softening and the letterpress
/// down with it.
///
/// # Safety
/// Each `(ptr, len)` pair must be null, or describe `len` readable bytes for the whole call, and
/// `out` must be null or point to `cap` writable bytes for the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_code_panel_dressing_script(
    nerd: *const c_uchar,
    nerd_len: usize,
    mono_upright: *const c_uchar,
    mono_upright_len: usize,
    mono_italic: *const c_uchar,
    mono_italic_len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation — each pair is null or live and readable for this call.
    let (nerd, upright, italic) = unsafe {
        (
            lent(nerd, nerd_len),
            lent(mono_upright, mono_upright_len),
            lent(mono_italic, mono_italic_len),
        )
    };
    let script = dressing::dressing_script(nerd.as_deref(), upright.as_deref(), italic.as_deref());
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe { deliver(script.as_bytes(), out, cap) }
}

/// One lent `(bytes, len)` pair as an optional string, lossily.
///
/// # Safety
/// `bytes` must be null, or point to `len` readable bytes for the whole call.
#[expect(
    unsafe_code,
    reason = "reconstituting the caller's span IS the boundary this module documents"
)]
unsafe fn lent<'a>(bytes: *const c_uchar, len: usize) -> Option<std::borrow::Cow<'a, str>> {
    if bytes.is_null() || len == 0 {
        return None;
    }
    // SAFETY: non-null and, by the caller's obligation, readable for `len` bytes for this call.
    let span = unsafe { core::slice::from_raw_parts(bytes, len) };
    Some(String::from_utf8_lossy(span))
}

#[cfg(test)]
#[expect(unsafe_code, reason = "calling the boundary IS what these tests are for")]
#[expect(
    clippy::expect_used,
    reason = "a panic in a test is the failure report, not a runtime fault"
)]
mod tests {
    use super::{slopdesk_code_panel_dressing_script, slopdesk_code_panel_text};

    fn text(kind: u8) -> String {
        let needed = unsafe { slopdesk_code_panel_text(kind, core::ptr::null_mut(), 0) };
        let mut buffer = vec![0_u8; needed];
        // SAFETY: the buffer is a live local, exactly as long as the sizing call asked for.
        let written = unsafe { slopdesk_code_panel_text(kind, buffer.as_mut_ptr(), buffer.len()) };
        assert_eq!(
            written, needed,
            "the second call must fit what the first asked for"
        );
        String::from_utf8(buffer).expect("every text this door serves is UTF-8")
    }

    #[test]
    fn every_declared_code_answers_and_the_next_one_does_not() {
        for kind in 0..=11 {
            assert!(!text(kind).is_empty(), "code {kind} answered nothing");
        }
        let past_the_end = unsafe { slopdesk_code_panel_text(12, core::ptr::null_mut(), 0) };
        assert_eq!(
            past_the_end, 0,
            "an unknown code reads as absent, never as a fragment"
        );
    }

    #[test]
    fn the_codes_are_the_ones_the_header_declares() {
        assert_eq!(text(0), "slopdesk-dressing");
        assert_eq!(text(1), "slopdeskClipboard");
        assert_eq!(text(2), "slopdesk-webview-canvas");
        assert_eq!(text(3), "vscode-workbench-web-configuration");
        assert_eq!(text(4), "__slopdeskSyncFocusTruth");
        assert!(text(5).starts_with("window.__slopdeskSyncFocusTruth &&"));
        assert!(text(6).contains("document.hasFocus()"));
        assert!(text(7).contains("--vscode-editor-background"));
        assert!(text(8).contains("clipboard.writeText = function"));
        assert!(text(9).contains("extensionRecommendations"));
        assert_eq!(text(10), "Symbols Nerd Font");
        assert_eq!(text(11), "JetBrains Mono");
    }

    #[test]
    fn a_short_buffer_is_told_the_size_and_left_alone() {
        let mut out = [9_u8; 4];
        // SAFETY: the buffer is a live local for the duration of the call.
        let needed = unsafe { slopdesk_code_panel_text(0, out.as_mut_ptr(), out.len()) };
        assert_eq!(needed, "slopdesk-dressing".len());
        assert_eq!(out, [9; 4], "nothing torn was written");
    }

    fn dressing(faces: [Option<&str>; 3]) -> String {
        let spans = faces.map(|face| face.map_or((core::ptr::null(), 0), |url| (url.as_ptr(), url.len())));
        let door = |out: *mut u8, cap: usize| {
            // SAFETY: every span names a live local for the duration of the call.
            unsafe {
                slopdesk_code_panel_dressing_script(
                    spans[0].0, spans[0].1, spans[1].0, spans[1].1, spans[2].0, spans[2].1, out, cap,
                )
            }
        };
        let needed = door(core::ptr::null_mut(), 0);
        let mut buffer = vec![0_u8; needed];
        assert_eq!(door(buffer.as_mut_ptr(), buffer.len()), needed);
        String::from_utf8(buffer).expect("the script is UTF-8")
    }

    #[test]
    fn the_three_faces_cross_and_a_null_one_is_simply_omitted() {
        let all = dressing([
            Some("slopdesk-font:n"),
            Some("slopdesk-font:u"),
            Some("slopdesk-font:i"),
        ]);
        assert_eq!(all.matches("@font-face").count(), 3);
        assert!(all.contains("slopdesk-font:i"));

        let none = dressing([None, None, None]);
        assert!(
            !none.contains("@font-face"),
            "a face with no bundle resource names no URL"
        );
        assert!(none.contains("slopdesk-dressing"), "and the sheet still installs");
    }

    #[test]
    fn the_script_the_door_composes_is_the_one_the_rule_builds() {
        let expected = slopdesk_codepanel::dressing::dressing_script(Some("a"), None, Some("b"));
        assert_eq!(dressing([Some("a"), None, Some("b")]), expected);
    }
}
