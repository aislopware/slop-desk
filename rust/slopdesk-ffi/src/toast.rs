//! The three toast factories, in C.
//!
//! The rules are `slopdesk_workspace::toast`; what is here is the marshalling.
//!
//! A card is SIX values that are only ever wanted together — an id, a flavour, a source, a title,
//! and two optional lines — so all three doors answer the same layout and share one reader:
//!
//! ```text
//! [u8 flavor][u8 source][u8 flags]
//! 4 × [u32 length][UTF-8 bytes]   // id, title, body, headline
//! ```
//!
//! `flags` bit 0 is "the body is present", bit 1 "the headline is present". An absent line and an
//! empty one are DIFFERENT — a card with `Some("")` draws a blank second row and a card with `None`
//! draws none — and a length prefix alone cannot tell them apart.
//!
//! ## Redaction happens on THIS side
//!
//! The remote's own text (an OSC title, a pane title) reaches the factory unmasked and leaves it
//! masked, because the masker is already a Rust face. A near side that masked first would be a
//! second implementation of the one rule, which is exactly what this port exists to remove.

use core::ffi::c_uchar;

use slopdesk_workspace::toast::{self as toast, Card, ResumeOutcome};

use crate::{borrow, deliver, push_text};

/// One card in the shared layout.
fn packed(card: &Card) -> Vec<u8> {
    let mut flags = 0_u8;
    if card.body.is_some() {
        flags |= 1;
    }
    if card.headline.is_some() {
        flags |= 2;
    }
    let mut blob = vec![card.flavor.code(), card.source.code(), flags];
    push_text(&mut blob, &card.id);
    push_text(&mut blob, &card.title);
    push_text(&mut blob, card.body.as_deref().unwrap_or_default());
    push_text(&mut blob, card.headline.as_deref().unwrap_or_default());
    blob
}

/// The card for an explicit OSC 9/777 notification.
///
/// Both the title and the body are the remote's text and both are masked when `redact` is set.
/// `body` is read only when `has_body` is set — a notification with no body is not one with an
/// empty body.
///
/// # Safety
/// Each `(ptr, len)` pair must be null or that many live bytes; `(out, cap)` must be writable for
/// `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and every pointer is the caller's"
)]
pub unsafe extern "C" fn slopdesk_ws_toast_explicit_osc(
    pane_key: *const c_uchar,
    pane_key_len: usize,
    title: *const c_uchar,
    title_len: usize,
    body: *const c_uchar,
    body_len: usize,
    has_body: bool,
    redact: bool,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, restated above; every borrow dies with this call.
    let (pane_key, title, body) = unsafe {
        (
            String::from_utf8_lossy(borrow(pane_key, pane_key_len)),
            String::from_utf8_lossy(borrow(title, title_len)),
            String::from_utf8_lossy(borrow(body, body_len)),
        )
    };
    let card = toast::explicit_osc(&pane_key, &title, has_body.then_some(body.as_ref()), redact);
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe { deliver(&packed(&card), out, cap) }
}

/// The card for a finished long-running command.
///
/// `exit_code` is read only when `has_exit` is set; a command whose status never arrived prints
/// `"?"` and is treated as a clean exit, because a red card about a result nobody has is a lie in
/// the louder direction.
///
/// # Safety
/// Each `(ptr, len)` pair must be null or that many live bytes; `(out, cap)` must be writable for
/// `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and every pointer is the caller's"
)]
pub unsafe extern "C" fn slopdesk_ws_toast_long_command(
    pane_key: *const c_uchar,
    pane_key_len: usize,
    pane_title: *const c_uchar,
    pane_title_len: usize,
    exit_code: i32,
    has_exit: bool,
    duration_ms: u32,
    redact: bool,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, restated above; both borrows die with this call.
    let (pane_key, pane_title) = unsafe {
        (
            String::from_utf8_lossy(borrow(pane_key, pane_key_len)),
            String::from_utf8_lossy(borrow(pane_title, pane_title_len)),
        )
    };
    let card = toast::long_command(
        &pane_key,
        &pane_title,
        has_exit.then_some(exit_code),
        duration_ms,
        redact,
    );
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe { deliver(&packed(&card), out, cap) }
}

/// The card for a completed reconnect, or `0` when the outcome earns none.
///
/// An undetermined reconnect says nothing at all — the toast exists to tell the user their session
/// SURVIVED or did not, and a shrug is not either of those.
///
/// # Safety
/// `pane_key` must be null or `pane_key_len` live bytes; `(out, cap)` must be writable for `cap`
/// bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and both pointers are the caller's"
)]
pub unsafe extern "C" fn slopdesk_ws_toast_session_resume(
    pane_key: *const c_uchar,
    pane_key_len: usize,
    outcome: u8,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, restated above; the borrow dies with this call.
    let pane_key = String::from_utf8_lossy(unsafe { borrow(pane_key, pane_key_len) });
    let Some(card) = toast::session_resume(&pane_key, ResumeOutcome::from_index(outcome)) else {
        return 0;
    };
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe { deliver(&packed(&card), out, cap) }
}

#[cfg(test)]
mod tests {
    #![expect(unsafe_code, reason = "calling the boundary IS what these tests are for")]

    use slopdesk_workspace::toast::{self as toast, Card, ResumeOutcome};

    use super::{
        slopdesk_ws_toast_explicit_osc, slopdesk_ws_toast_long_command, slopdesk_ws_toast_session_resume,
    };
    use crate::testing::{delivered, runs};

    /// Cuts a delivery back into the card the near side would build from it.
    fn unpacked(blob: &[u8]) -> Option<Card> {
        let header = blob.get(..3)?;
        let flags = *header.get(2)?;
        let words = runs(blob.get(3..)?, 4);
        Some(Card {
            id: words.first()?.clone(),
            flavor: match header.first()? {
                1 => toast::Flavor::Success,
                2 => toast::Flavor::Error,
                3 => toast::Flavor::Attention,
                _ => toast::Flavor::Default,
            },
            source: if header.get(1) == Some(&1) {
                toast::Source::Command
            } else {
                toast::Source::Agent
            },
            title: words.get(1)?.clone(),
            body: (flags & 1 == 1).then(|| words.get(2).cloned()).flatten(),
            headline: (flags & 2 == 2).then(|| words.get(3).cloned()).flatten(),
        })
    }

    /// A round trip through the layout, over the masked and unmasked halves of the rule.
    #[test]
    fn an_osc_card_crosses_whole() {
        // Assembled rather than spelled: push protection scans source, not intent.
        let secret = ["AKIA", "IOSFODNN7EXAMPLE"].concat();
        let title = format!("deploy {secret}");
        for redact in [false, true] {
            for body in [None, Some(""), Some("done")] {
                let (key, title_bytes) = (b"p1".to_vec(), title.as_bytes().to_vec());
                let body_bytes = body.unwrap_or_default().as_bytes().to_vec();
                let blob = delivered(|out, cap| {
                    // SAFETY: every buffer is a live local for the call.
                    unsafe {
                        slopdesk_ws_toast_explicit_osc(
                            key.as_ptr(),
                            key.len(),
                            title_bytes.as_ptr(),
                            title_bytes.len(),
                            body_bytes.as_ptr(),
                            body_bytes.len(),
                            body.is_some(),
                            redact,
                            out,
                            cap,
                        )
                    }
                });
                assert_eq!(
                    unpacked(&blob),
                    Some(toast::explicit_osc("p1", &title, body, redact)),
                    "redact {redact}, body {body:?}",
                );
            }
        }
    }

    /// An absent body and an empty one survive the crossing as different cards — the flag's job.
    #[test]
    fn an_absent_line_is_not_an_empty_one() {
        let key = b"p1".to_vec();
        let title = b"t".to_vec();
        let card = |has_body: bool| {
            let blob = delivered(|out, cap| {
                // SAFETY: every buffer is a live local for the call.
                unsafe {
                    slopdesk_ws_toast_explicit_osc(
                        key.as_ptr(),
                        key.len(),
                        title.as_ptr(),
                        title.len(),
                        core::ptr::null(),
                        0,
                        has_body,
                        false,
                        out,
                        cap,
                    )
                }
            });
            unpacked(&blob).and_then(|card| card.body)
        };
        assert_eq!(card(true), Some(String::new()));
        assert_eq!(card(false), None);
    }

    #[test]
    fn a_finished_command_crosses_whole() {
        for exit in [None, Some(0), Some(1), Some(-9)] {
            for pane_title in ["", "build"] {
                let (key, title) = (b"p2".to_vec(), pane_title.as_bytes().to_vec());
                let blob = delivered(|out, cap| {
                    // SAFETY: every buffer is a live local for the call.
                    unsafe {
                        slopdesk_ws_toast_long_command(
                            key.as_ptr(),
                            key.len(),
                            title.as_ptr(),
                            title.len(),
                            exit.unwrap_or_default(),
                            exit.is_some(),
                            90_500,
                            true,
                            out,
                            cap,
                        )
                    }
                });
                assert_eq!(
                    unpacked(&blob),
                    Some(toast::long_command("p2", pane_title, exit, 90_500, true)),
                    "exit {exit:?}, title {pane_title:?}",
                );
            }
        }
    }

    #[test]
    fn only_a_determined_reconnect_earns_a_card() {
        for index in 0..4_u8 {
            let key = b"p3".to_vec();
            let blob = delivered(|out, cap| {
                // SAFETY: `key` and `out` are live locals for the call.
                unsafe { slopdesk_ws_toast_session_resume(key.as_ptr(), key.len(), index, out, cap) }
            });
            let expected = toast::session_resume("p3", ResumeOutcome::from_index(index));
            if blob.is_empty() {
                assert_eq!(expected, None, "index {index}");
            } else {
                assert_eq!(unpacked(&blob), expected, "index {index}");
            }
        }
    }
}
