//! What a close confirmation says, in C.
//!
//! The rules are `slopdesk_workspace::close_confirm`; what is here is the marshalling.
//!
//! ## Both sentences ride in ONE delivery
//!
//! The headline and the body are never wanted apart — an alert is raised with both or not at all —
//! and they share every input. Two doors would cross the same five facts twice and give a caller a
//! way to pair a headline about a pane with a body about a tab.
//!
//! The confirmation ITSELF stays on the near side: it is an `NSAlert` sheet on the Mac and a
//! `SwiftUI` `.alert` on the phone, and there is nothing to port about either.

use core::ffi::c_uchar;

use slopdesk_workspace::close_confirm::{self, Policy, Request, Scope};

use crate::workspace::{Span, text_of};
use crate::{borrow, deliver, push_text};

/// The headline and the body for a parked close, in one delivery.
///
/// ```text
/// 2 × [u32 length][UTF-8 bytes]   // the headline, then the body
/// ```
///
/// `pane_title` and `project_name` are spans into `blob`; an ABSENT span is a parked TAB close and
/// a project the close does not take the last pane of. A present span of length 0 is its own case —
/// a pane with no title is named generically rather than with a pair of empty quotes — which is why
/// they cross as spans rather than as a pointer that is null when blank.
///
/// # Safety
/// `(blob, blob_len)` must be readable for the call, and `(out, cap)` writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and both pointers are the caller's"
)]
pub unsafe extern "C" fn slopdesk_ws_close_confirm_copy(
    scope: u8,
    policy_gated: bool,
    policy: u8,
    pane_title: Span,
    project_name: Span,
    blob: *const c_uchar,
    blob_len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, restated above; the borrow dies with this call.
    let lent = unsafe { borrow(blob, blob_len) };
    let request = Request {
        scope: Scope::from_code(scope),
        pane_title: text_of(pane_title, lent),
        policy_gated,
        policy: Policy::from_code(policy),
        project_name: text_of(project_name, lent),
    };
    let mut answer = Vec::new();
    push_text(&mut answer, &close_confirm::title(&request));
    push_text(&mut answer, &close_confirm::message(&request));
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe { deliver(&answer, out, cap) }
}

#[cfg(test)]
mod tests {
    #![expect(unsafe_code, reason = "calling the boundary IS what these tests are for")]

    use slopdesk_workspace::close_confirm::{self, Policy, Request, Scope};

    use super::slopdesk_ws_close_confirm_copy;
    use crate::testing::{delivered, runs};
    use crate::workspace::Span;

    /// A span over the whole of `blob`, or the absent one.
    const fn span(present: bool, len: usize) -> Span {
        Span {
            offset: 0,
            len: if present { len } else { 0 },
            present,
        }
    }

    /// Crosses one park and answers the pair the near side would read.
    fn copy(
        scope: Scope,
        pane_title: Option<&str>,
        policy_gated: bool,
        project: Option<&str>,
    ) -> (String, String) {
        // One arena is enough: at most one of the two spans is present in every case tested here.
        let text = pane_title.or(project).unwrap_or("").as_bytes().to_vec();
        let (title_span, project_span) = if pane_title.is_some() {
            (span(true, text.len()), span(false, 0))
        } else {
            (span(false, 0), span(project.is_some(), text.len()))
        };
        let blob = delivered(|out, cap| {
            // SAFETY: `text` and `out` are live locals for the call.
            unsafe {
                slopdesk_ws_close_confirm_copy(
                    scope.code(),
                    policy_gated,
                    Policy::Process.code(),
                    title_span,
                    project_span,
                    text.as_ptr(),
                    text.len(),
                    out,
                    cap,
                )
            }
        });
        let pair = runs(&blob, 2);
        (
            pair.first().cloned().unwrap_or_default(),
            pair.get(1).cloned().unwrap_or_default(),
        )
    }

    /// The rule's own answers, for the same park.
    fn expected(
        scope: Scope,
        pane_title: Option<&str>,
        policy_gated: bool,
        project: Option<&str>,
    ) -> (String, String) {
        let request = Request {
            scope,
            pane_title,
            policy_gated,
            policy: Policy::Process,
            project_name: project,
        };
        (close_confirm::title(&request), close_confirm::message(&request))
    }

    #[test]
    fn a_named_pane_and_a_nameless_one_cross_as_different_facts() {
        assert_eq!(
            copy(Scope::Pane, Some("make check"), true, None),
            expected(Scope::Pane, Some("make check"), true, None),
        );
        assert_eq!(
            copy(Scope::Pane, Some(""), true, None),
            expected(Scope::Pane, Some(""), true, None),
            "a present empty span is a nameless pane, not an absent one",
        );
        assert_eq!(
            copy(Scope::Tab, None, true, None),
            expected(Scope::Tab, None, true, None),
        );
    }

    /// The defect the rule exists for, checked THROUGH the door: an ungated park blames nothing.
    #[test]
    fn an_ungated_park_crosses_without_the_policy_line() {
        let (_, body) = copy(Scope::Tab, None, false, Some("slopdesk"));
        assert!(body.contains("last tab of"), "{body:?}");
        assert!(!body.contains("A process is still running"), "{body:?}");
    }

    #[test]
    fn a_stale_scope_or_policy_code_over_warns_rather_than_crossing_as_nothing() {
        assert_eq!(Scope::from_code(200), Scope::Tab);
        assert_eq!(Policy::from_code(200), Policy::Process);
    }
}
