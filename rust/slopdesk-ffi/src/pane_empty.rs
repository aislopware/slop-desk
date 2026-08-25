//! The empty pane area's reading of a live connection — WHY there is nothing to draw, and the four
//! strings that say so.
//!
//! Two doors rather than one, because the two questions are asked at different moments: the CAUSE
//! is resolved when the connection changes and is then carried around as the branch a renderer's
//! action button switches on, while the COPY is asked for at draw time with the host and the
//! failure reason the caller already holds.
//!
//! The copy is one head plus four runs — the symbol NAME, the title, the caption and the action
//! label — so a renderer cannot draw a title from one reading beside a caption from another. The
//! head's flag separates a cause with NO action (a redial, which the supervisor is already driving)
//! from one whose label happens to be empty; a button offered there would suggest the user must do
//! something.

use core::ffi::c_uchar;

use slopdesk_workspace::pane_empty::{self, Cause};

use crate::connection::status;
use crate::workspace::{Span, borrow_array, text_of};
use crate::{borrow, deliver, push_text};

/// No host connected — the next action is the Connect editor.
pub const SLOPDESK_WS_PANE_EMPTY_NEVER_CONNECTED: u8 = 0;
/// A host WAS reachable and the link is down; the supervisor is redialing, so there is no action.
pub const SLOPDESK_WS_PANE_EMPTY_LINK_DOWN: u8 = 1;
/// Connected fine — just no open tabs.
pub const SLOPDESK_WS_PANE_EMPTY_NO_TABS: u8 = 2;
/// The last explicit connect attempt failed; the caption carries the real reason.
pub const SLOPDESK_WS_PANE_EMPTY_CONNECT_FAILED: u8 = 3;

/// How many spans [`slopdesk_ws_pane_empty_copy`] reads, in its own order: the host being
/// redialled, then the failure reason.
pub const PANE_EMPTY_SPANS: usize = 2;

/// The bytes the copy answer leads with: the presence flag for the action label.
pub const PANE_EMPTY_HEAD_BYTES: usize = 4;

/// Which `SLOPDESK_WS_PANE_EMPTY_*` cause a `SLOPDESK_CONNECTION_STATUS_*` code reads as.
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
#[unsafe(no_mangle)]
pub const extern "C" fn slopdesk_ws_pane_empty_cause(status_code: u32) -> u8 {
    pane_empty::cause(status(status_code)).as_byte()
}

/// Everything the empty pane area says for `cause`: `[u32 has_action]`, then the symbol name, the
/// title, the caption and the action label as `[u32 len][UTF-8]` runs.
///
/// A span array of the wrong length answers NOTHING rather than reading a neighbour's slot: the two
/// are positional, and a caption drawn from the host slot would name the wrong thing confidently.
///
/// # Safety
/// `(blob, blob_len)` must be null, or name `blob_len` initialised bytes live for the call;
/// `(spans, span_count)` likewise for `span_count` spans; `(out, cap)` must be writable for `cap`
/// bytes.
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and every pointer is the caller's"
)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn slopdesk_ws_pane_empty_copy(
    cause: u8,
    blob: *const c_uchar,
    blob_len: usize,
    spans: *const Span,
    span_count: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, restated above.
    let bytes = unsafe { borrow(blob, blob_len) };
    // SAFETY: ditto.
    let spans = unsafe { borrow_array(spans, span_count) };
    if spans.len() != PANE_EMPTY_SPANS {
        return 0;
    }
    let at = |index: usize| {
        spans
            .get(index)
            .and_then(|span| text_of(*span, bytes))
            .unwrap_or_default()
    };
    let cause = Cause::from_byte(cause);
    let caption = pane_empty::caption(cause, at(0), at(1));
    let action = cause.action();
    let mut answer = Vec::with_capacity(PANE_EMPTY_HEAD_BYTES + caption.len() + 96);
    answer.extend_from_slice(&u32::from(action.is_some()).to_be_bytes());
    push_text(&mut answer, cause.symbol());
    push_text(&mut answer, cause.title());
    push_text(&mut answer, &caption);
    push_text(&mut answer, action.unwrap_or_default());
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe { deliver(&answer, out, cap) }
}

#[cfg(test)]
#[expect(unsafe_code, reason = "calling the boundary IS what these tests are for")]
mod tests {
    use super::{
        PANE_EMPTY_HEAD_BYTES, PANE_EMPTY_SPANS, SLOPDESK_WS_PANE_EMPTY_CONNECT_FAILED,
        SLOPDESK_WS_PANE_EMPTY_LINK_DOWN, SLOPDESK_WS_PANE_EMPTY_NEVER_CONNECTED,
        SLOPDESK_WS_PANE_EMPTY_NO_TABS, slopdesk_ws_pane_empty_cause, slopdesk_ws_pane_empty_copy,
    };
    use crate::connection::{
        SLOPDESK_CONNECTION_STATUS_CONNECTED, SLOPDESK_CONNECTION_STATUS_CONNECTING,
        SLOPDESK_CONNECTION_STATUS_DISCONNECTED, SLOPDESK_CONNECTION_STATUS_FAILED,
        SLOPDESK_CONNECTION_STATUS_RECONNECTING, SLOPDESK_CONNECTION_STATUS_UNREACHABLE,
    };
    use crate::testing::delivered;
    use crate::workspace::Span;

    /// Packs the host and the reason into one arena and reads the door's flag and four runs back.
    fn copy(cause: u8, host: &str, reason: &str) -> (bool, Vec<String>) {
        let mut blob = Vec::new();
        let mut spans = Vec::new();
        for text in [host, reason] {
            let offset = blob.len();
            blob.extend_from_slice(text.as_bytes());
            spans.push(Span {
                offset,
                len: text.len(),
                present: true,
            });
        }
        // SAFETY: every pointer names a live local for the duration of the call.
        let answer = delivered(|out, cap| unsafe {
            slopdesk_ws_pane_empty_copy(
                cause,
                blob.as_ptr(),
                blob.len(),
                spans.as_ptr(),
                spans.len(),
                out,
                cap,
            )
        });
        let head = answer
            .get(..PANE_EMPTY_HEAD_BYTES)
            .and_then(|four| <[u8; 4]>::try_from(four).ok())
            .map_or(0, u32::from_be_bytes);
        let mut runs = Vec::new();
        let mut cursor = PANE_EMPTY_HEAD_BYTES;
        while let Some(four) = answer
            .get(cursor..cursor + 4)
            .and_then(|four| <[u8; 4]>::try_from(four).ok())
        {
            let length = u32::from_be_bytes(four) as usize;
            cursor += 4;
            let Some(run) = answer.get(cursor..cursor + length) else {
                break;
            };
            runs.push(String::from_utf8_lossy(run).into_owned());
            cursor += length;
        }
        (head == 1, runs)
    }

    #[test]
    fn every_status_code_crosses_to_the_cause_that_describes_it() {
        assert_eq!(
            slopdesk_ws_pane_empty_cause(SLOPDESK_CONNECTION_STATUS_CONNECTED),
            SLOPDESK_WS_PANE_EMPTY_NO_TABS
        );
        assert_eq!(
            slopdesk_ws_pane_empty_cause(SLOPDESK_CONNECTION_STATUS_RECONNECTING),
            SLOPDESK_WS_PANE_EMPTY_LINK_DOWN
        );
        assert_eq!(
            slopdesk_ws_pane_empty_cause(SLOPDESK_CONNECTION_STATUS_FAILED),
            SLOPDESK_WS_PANE_EMPTY_CONNECT_FAILED
        );
        for code in [
            SLOPDESK_CONNECTION_STATUS_DISCONNECTED,
            SLOPDESK_CONNECTION_STATUS_CONNECTING,
            SLOPDESK_CONNECTION_STATUS_UNREACHABLE,
        ] {
            assert_eq!(
                slopdesk_ws_pane_empty_cause(code),
                SLOPDESK_WS_PANE_EMPTY_NEVER_CONNECTED
            );
        }
    }

    /// The four strings cross together, and the host is read from its own slot rather than the one
    /// beside it.
    #[test]
    fn a_redial_names_its_host_and_offers_no_button() {
        let (has_action, runs) = copy(SLOPDESK_WS_PANE_EMPTY_LINK_DOWN, "mac-studio", "refused");
        assert!(!has_action, "the supervisor is already dialing");
        assert_eq!(runs, [
            "wifi.exclamationmark",
            "Connection Lost",
            "Reconnecting to mac-studio…",
            ""
        ]);
    }

    /// A failure prints the reason it was given rather than the generic not-connected copy.
    #[test]
    fn a_failure_carries_its_reason_and_re_offers_the_editor() {
        let (has_action, runs) = copy(
            SLOPDESK_WS_PANE_EMPTY_CONNECT_FAILED,
            "mac-studio",
            "Connection refused",
        );
        assert!(has_action);
        assert_eq!(runs.get(2).map(String::as_str), Some("Connection refused"));
        assert_eq!(runs.get(3).map(String::as_str), Some("Connect to Host…"));
    }

    /// A layout disagreement must lose the reading whole — a caption drawn from the host slot would
    /// name the wrong thing confidently.
    #[test]
    fn a_short_span_array_answers_nothing_rather_than_shifting_a_slot() {
        let spans = [Span {
            offset: 0,
            len: 0,
            present: false,
        }; PANE_EMPTY_SPANS - 1];
        // SAFETY: both pointers name live locals for the duration of the call.
        let answer = delivered(|out, cap| unsafe {
            slopdesk_ws_pane_empty_copy(
                SLOPDESK_WS_PANE_EMPTY_NO_TABS,
                std::ptr::null(),
                0,
                spans.as_ptr(),
                spans.len(),
                out,
                cap,
            )
        });
        assert!(answer.is_empty());
    }
}
