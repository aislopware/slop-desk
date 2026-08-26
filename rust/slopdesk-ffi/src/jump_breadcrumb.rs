//! The jump notice's two sentences, in C.
//!
//! The rules are `slopdesk_workspace::rail_title`; what is here is the marshalling.
//!
//! Both doors answer TEXT, so both take the `(out, cap) -> needed` shape and nothing else. The one
//! thing worth reading twice is the pair of presence conventions on
//! [`slopdesk_ws_tab_display_title`], because they are not the same for the two optional titles it
//! takes and that is deliberate — see the door.

use core::ffi::c_uchar;

use slopdesk_workspace::rail_title;

use crate::{deliver, lent};

/// What a tab is CALLED: an explicit rename, else the resolved pane's live title, else its spec
/// title, else `"Tab"`.
///
/// The two optional titles cross under DIFFERENT conventions, and swapping them would change the
/// answer:
///
/// * `has_spec` is a real presence flag, because "this pane has no spec" and "this pane's spec has
///   a blank title" are different facts here — with no spec the live title is not consulted at all.
///   A sentinel could not say that; an empty `spec_title` with `has_spec == true` means the blank
///   title, which is the case that then falls through to `"Tab"`.
/// * `live_title` has no flag, because an absent live title and an empty one both fall through to
///   the spec title. Adding a flag there would be a bit the far side could set two ways for one
///   meaning.
///
/// The answer is never empty, so a `0` return cannot happen: the fallback is a non-empty
/// `&'static str`. WHICH pane was resolved is the caller's — it walks a live tree to find the
/// active leaf, and a tree does not cross.
///
/// # Safety
/// Each `(ptr, len)` pair must be null, or name that many initialised bytes live for the call.
/// `(out, cap)` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and every pointer here is the caller's"
)]
pub unsafe extern "C" fn slopdesk_ws_tab_display_title(
    tab_title: *const c_uchar,
    tab_title_len: usize,
    has_spec: bool,
    spec_title: *const c_uchar,
    spec_title_len: usize,
    live_title: *const c_uchar,
    live_title_len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, forwarded unchanged.
    let (tab, spec, live) = unsafe {
        (
            lent(tab_title, tab_title_len),
            lent(spec_title, spec_title_len),
            lent(live_title, live_title_len),
        )
    };
    // The flag decides whether the spec text is a title at all; the live text needs no flag,
    // because an absent live title and an empty one take the same rung.
    let answer = rail_title::tab_display_title(tab, has_spec.then_some(spec), Some(live));
    // SAFETY: the caller's buffer obligation, forwarded unchanged.
    unsafe { deliver(answer.as_bytes(), out, cap) }
}

/// The breadcrumb line: `"<session> ▸ <tab>"`, or the tab title alone.
///
/// `0` means the line is EMPTY, which one input reaches: an unqualified breadcrumb over a tab whose
/// title is empty. A caller that resolved the title through
/// [`slopdesk_ws_tab_display_title`] first cannot get there, and one that did not gets an empty
/// string rather than a lone separator.
///
/// # Safety
/// Each `(ptr, len)` pair must be null, or name that many initialised bytes live for the call.
/// `(out, cap)` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and every pointer here is the caller's"
)]
pub unsafe extern "C" fn slopdesk_ws_jump_breadcrumb(
    session_name: *const c_uchar,
    session_name_len: usize,
    tab_title: *const c_uchar,
    tab_title_len: usize,
    include_session: bool,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, forwarded unchanged.
    let (session, tab) = unsafe {
        (
            lent(session_name, session_name_len),
            lent(tab_title, tab_title_len),
        )
    };
    let answer = rail_title::breadcrumb_text(session, tab, include_session);
    // SAFETY: the caller's buffer obligation, forwarded unchanged.
    unsafe { deliver(answer.as_bytes(), out, cap) }
}

#[cfg(test)]
#[expect(unsafe_code, reason = "calling the boundary IS what these tests are for")]
#[expect(
    clippy::expect_used,
    reason = "a door that answers bytes it cannot re-read IS the report"
)]
#[expect(
    clippy::indexing_slicing,
    reason = "cutting the delivery at the length the door returned IS the test"
)]
mod tests {
    use super::{slopdesk_ws_jump_breadcrumb, slopdesk_ws_tab_display_title};

    fn title(tab: &str, spec: Option<&str>, live: Option<&str>) -> String {
        let mut out = [0_u8; 64];
        let (spec_ptr, spec_len) = spec.map_or((core::ptr::null(), 0), |s| (s.as_ptr(), s.len()));
        let (live_ptr, live_len) = live.map_or((core::ptr::null(), 0), |s| (s.as_ptr(), s.len()));
        // SAFETY: every pair names live bytes of a local, and `out` is a live local buffer.
        let needed = unsafe {
            slopdesk_ws_tab_display_title(
                tab.as_ptr(),
                tab.len(),
                spec.is_some(),
                spec_ptr,
                spec_len,
                live_ptr,
                live_len,
                out.as_mut_ptr(),
                out.len(),
            )
        };
        String::from_utf8(out[..needed].to_vec()).expect("the door answers UTF-8")
    }

    fn breadcrumb(session: &str, tab: &str, include: bool) -> String {
        let mut out = [0_u8; 64];
        // SAFETY: both pairs name live bytes of a local, and `out` is a live local buffer.
        let needed = unsafe {
            slopdesk_ws_jump_breadcrumb(
                session.as_ptr(),
                session.len(),
                tab.as_ptr(),
                tab.len(),
                include,
                out.as_mut_ptr(),
                out.len(),
            )
        };
        String::from_utf8(out[..needed].to_vec()).expect("the door answers UTF-8")
    }

    #[test]
    fn the_chain_crosses_in_the_order_the_crate_decides_it() {
        assert_eq!(title("Renamed", Some("Spec"), Some("Live")), "Renamed");
        assert_eq!(title("", Some("Spec"), Some("Live")), "Live");
        assert_eq!(title("", Some("Spec"), Some("")), "Spec");
        assert_eq!(title("", Some("Spec"), None), "Spec");
        assert_eq!(title("", Some(""), Some("")), "Tab");
    }

    /// The flag, not the length, is what says "no spec" — and it is the only input that keeps a
    /// live title from being read.
    #[test]
    fn a_missing_spec_is_a_different_answer_from_a_blank_one() {
        assert_eq!(title("", None, Some("Live")), "Tab");
        assert_eq!(title("", Some(""), Some("Live")), "Live");
    }

    #[test]
    fn a_qualified_breadcrumb_carries_the_separator_and_an_unqualified_one_does_not() {
        assert_eq!(breadcrumb("Work", "Build", true), "Work \u{25B8} Build");
        assert_eq!(breadcrumb("Work", "Build", false), "Build");
        assert_eq!(breadcrumb("", "Build", true), "Build");
    }

    /// The one input whose answer is `0` rather than bytes.
    #[test]
    fn an_empty_line_answers_zero_rather_than_an_empty_buffer() {
        let mut out = [0xAA_u8; 8];
        // SAFETY: both pairs name live bytes of a local, and `out` is a live local buffer.
        let needed = unsafe {
            slopdesk_ws_jump_breadcrumb(
                core::ptr::null(),
                0,
                core::ptr::null(),
                0,
                true,
                out.as_mut_ptr(),
                out.len(),
            )
        };
        assert_eq!(needed, 0);
        assert_eq!(out, [0xAA; 8], "nothing was written");
    }

    /// A probe with no buffer reports the size and leaves the caller's bytes alone.
    #[test]
    fn a_probe_that_did_not_fit_leaves_the_buffer_untouched() {
        let mut out = [0xAA_u8; 2];
        // SAFETY: both pairs name live bytes of a local, and `out` is a live local buffer.
        let needed = unsafe {
            slopdesk_ws_jump_breadcrumb(
                "Work".as_ptr(),
                4,
                "Build".as_ptr(),
                5,
                true,
                out.as_mut_ptr(),
                out.len(),
            )
        };
        assert_eq!(needed, "Work \u{25B8} Build".len());
        assert_eq!(out, [0xAA; 2], "nothing was written");
    }
}
