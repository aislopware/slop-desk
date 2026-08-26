//! The client control socket's VOCABULARY — five doors over `slopdesk-clientctl`.
//!
//! The sibling of [`crate::control_request`], and deliberately a separate module: that one carries
//! the socket's *judgements* — the line cap, the capture bound, the refusal sentences — out of
//! `slopdesk-workspace`, while this one carries its *words* out of `slopdesk-clientctl`. Two
//! crates, two modules, one `slopdesk_ws_ctl_` prefix, because a caller reads them as one socket.
//!
//! ## Why these words cross at all now
//!
//! They used to not. `slopdesk-cli` held the method names and the three token vocabularies, the
//! Swift `ClientControlProtocol` held a second spelling of all of them, and a `slopdesk-invariants`
//! rule compared one file's regexes against the other's — the shape "one implementation, never two
//! languages" exists to delete. The module moved into its own crate so BOTH ends could link it, and
//! what is left in Swift is a face.
//!
//! ## Two shapes, and the reason for each
//!
//! The METHODS cross as WORDS, because the far side dispatches a `switch` on the string a foreign
//! process wrote — the string is the thing. They arrive as one blob in `METHODS` order: `[u16
//! count]`, then per method `[u32 length][UTF-8]`, which is [`crate::push_text`]'s framing and what
//! Swift's `DevicePanelBlob` cursor already walks. One delivery, read once into a `static let`.
//!
//! The TOKENS cross as INDICES, because the far side does not dispatch on them — it turns each into
//! a case of its own enum and then only ever switches on that. A token is parsed exactly once,
//! here, and what crosses is the position: `slopdesk_ws_ctl_placement_for_token` answers 0…5 into
//! [`PLACEMENTS`], which is the Swift enum's `rawValue`. An unknown token answers `-1`, which is
//! `nil` on the far side and a `Refusal::InvalidPlacement` after that — SIGNED for that reason, and
//! matching `TabBadgeKind`'s own `init?(ffiByte: Int8)` next door.
//!
//! The one token that crosses in BOTH directions is the badge, because a tab can be LISTED wearing
//! one: `slopdesk_ws_ctl_badge_token` is the reverse, total over the ladder, and the four badges no
//! request may set are exactly the four it can spell that `..._badge_for_token` refuses.

use core::ffi::c_uchar;

use slopdesk_agent::badge::TabBadge;
use slopdesk_clientctl::{FONT_SCOPES, METHODS, PLACEMENTS, badge_for_token, index_of, token_for_badge};

use crate::{borrow, deliver, push_text};

/// What a token no vocabulary carries answers. `-1` rather than a large unsigned byte because the
/// far side's `init?` takes an `Int8`, and because a sentinel that is not a plausible index is one
/// a reader cannot mistake for one.
const NO_TOKEN: i8 = -1;

/// The position `token` holds in `vocabulary`, or [`NO_TOKEN`].
///
/// Non-UTF-8 bytes read as no token rather than as an error: the near side's `String` cannot
/// produce them, and a vocabulary lookup is not the place to report that it somehow did.
///
/// # Safety
/// `(token, token_len)` must be null, or name `token_len` initialised bytes live for the call.
#[expect(
    unsafe_code,
    reason = "reconstituting the caller's text IS the boundary this module documents"
)]
unsafe fn position(vocabulary: &[&str], token: *const c_uchar, token_len: usize) -> i8 {
    // SAFETY: the caller's obligation, restated above; the borrow dies with this call.
    let bytes = unsafe { borrow(token, token_len) };
    let Ok(text) = core::str::from_utf8(bytes) else {
        return NO_TOKEN;
    };
    index_of(vocabulary, text)
        .and_then(|index| i8::try_from(index).ok())
        .unwrap_or(NO_TOKEN)
}

/// Every method the socket dispatches, in `METHODS` order, as ONE delivery.
///
/// `[u16 count]`, then per method `[u32 length][UTF-8]`. A fixed table read once into a Swift
/// `static let`, the way `slopdesk_android_sidebar_notices` is — there is nothing per-call here, so
/// the alternative would be fourteen entry points naming one array.
///
/// # Safety
/// `out` must be null, or writable for `cap` bytes for the whole call.
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and the buffer is the caller's"
)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn slopdesk_ws_ctl_methods(out: *mut c_uchar, cap: usize) -> usize {
    let mut blob = Vec::with_capacity(256);
    blob.extend_from_slice(&u16::try_from(METHODS.len()).unwrap_or(u16::MAX).to_be_bytes());
    for method in METHODS {
        push_text(&mut blob, method);
    }
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe { deliver(&blob, out, cap) }
}

/// The badge a settable `--kind` token names, as `TabBadge::ALL`'s index, or [`NO_TOKEN`].
///
/// The four badges a foreground process derives — the two command tiers and the two privilege
/// markers — are NOT settable, so their own canonical spellings answer `-1` here even though
/// [`slopdesk_ws_ctl_badge_token`] prints them. That asymmetry is the rule, not an omission: a
/// request may not claim a tab is running `sudo`.
///
/// # Safety
/// `(token, token_len)` must be null, or name `token_len` initialised bytes live for the call.
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and the text is the caller's"
)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn slopdesk_ws_ctl_badge_for_token(token: *const c_uchar, token_len: usize) -> i8 {
    // SAFETY: the caller's obligation, restated above; the borrow dies with this call.
    let bytes = unsafe { borrow(token, token_len) };
    let Ok(text) = core::str::from_utf8(bytes) else {
        return NO_TOKEN;
    };
    let Some(badge) = badge_for_token(text) else {
        return NO_TOKEN;
    };
    TabBadge::ALL
        .iter()
        .position(|candidate| *candidate == badge)
        .and_then(|index| i8::try_from(index).ok())
        .unwrap_or(NO_TOKEN)
}

/// The canonical token for a badge, by its `TabBadge::ALL` index. A byte no badge answers to writes
/// nothing and reports 0.
///
/// # Safety
/// `out` must be null, or writable for `cap` bytes for the whole call.
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and the buffer is the caller's"
)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn slopdesk_ws_ctl_badge_token(badge: u8, out: *mut c_uchar, cap: usize) -> usize {
    let Some(badge) = TabBadge::ALL.get(badge as usize) else {
        return 0;
    };
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe { deliver(token_for_badge(*badge).as_bytes(), out, cap) }
}

/// Where a `view`/`edit` shim opens, as an index into `PLACEMENTS`, or [`NO_TOKEN`].
///
/// # Safety
/// `(token, token_len)` must be null, or name `token_len` initialised bytes live for the call.
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and the text is the caller's"
)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn slopdesk_ws_ctl_placement_for_token(token: *const c_uchar, token_len: usize) -> i8 {
    // SAFETY: the caller's obligation, restated above.
    unsafe { position(PLACEMENTS, token, token_len) }
}

/// Which font surface `font list --scope` names, as an index into `FONT_SCOPES`, or [`NO_TOKEN`].
///
/// # Safety
/// `(token, token_len)` must be null, or name `token_len` initialised bytes live for the call.
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and the text is the caller's"
)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn slopdesk_ws_ctl_font_scope_for_token(token: *const c_uchar, token_len: usize) -> i8 {
    // SAFETY: the caller's obligation, restated above.
    unsafe { position(FONT_SCOPES, token, token_len) }
}

#[cfg(test)]
mod tests {
    #![expect(unsafe_code, reason = "calling the door is the only way to test the door")]
    #![expect(
        clippy::expect_used,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use slopdesk_agent::badge::TabBadge;
    use slopdesk_clientctl::{FONT_SCOPES, METHODS, PLACEMENTS};

    use super::{
        slopdesk_ws_ctl_badge_for_token, slopdesk_ws_ctl_badge_token, slopdesk_ws_ctl_font_scope_for_token,
        slopdesk_ws_ctl_methods, slopdesk_ws_ctl_placement_for_token,
    };

    /// One delivery, sized then taken — `docs/55` §4's shape from the caller's side.
    fn delivered(call: impl Fn(*mut u8, usize) -> usize) -> Vec<u8> {
        let needed = call(std::ptr::null_mut(), 0);
        let mut out = vec![0_u8; needed];
        let written = call(out.as_mut_ptr(), out.len());
        assert_eq!(written, needed);
        out
    }

    /// Walks the `[u16 count]` + `[u32 length][UTF-8]` framing back into words.
    fn words(blob: &[u8]) -> Vec<String> {
        let mut cursor = blob.iter().copied();
        let mut take = |n: usize| -> Vec<u8> { (0..n).filter_map(|_| cursor.next()).collect() };
        let count = u16::from_be_bytes(take(2).try_into().unwrap_or([0, 0]));
        (0..count)
            .map(|_| {
                let length = u32::from_be_bytes(take(4).try_into().unwrap_or([0; 4]));
                String::from_utf8(take(length as usize)).unwrap_or_default()
            })
            .collect()
    }

    fn parse(call: unsafe extern "C" fn(*const u8, usize) -> i8, token: &str) -> i8 {
        // SAFETY: the slice is live for the call and nothing escapes it.
        unsafe { call(token.as_ptr(), token.len()) }
    }

    #[test]
    fn every_method_crosses_in_declaration_order() {
        // SAFETY: `delivered` lends a live buffer of exactly the length the door asked for.
        let blob = delivered(|out, cap| unsafe { slopdesk_ws_ctl_methods(out, cap) });
        assert_eq!(
            words(&blob),
            METHODS.iter().map(|m| (*m).to_owned()).collect::<Vec<_>>()
        );
    }

    #[test]
    fn a_settable_token_crosses_as_its_badge_index_and_nothing_else_does() {
        assert_eq!(parse(slopdesk_ws_ctl_badge_for_token, "running"), 0);
        assert_eq!(parse(slopdesk_ws_ctl_badge_for_token, "awaiting-input"), 6);
        // The many-to-one row: `unread` is `Finished`, whose own index is 4.
        assert_eq!(parse(slopdesk_ws_ctl_badge_for_token, "unread"), 4);
        assert_eq!(parse(slopdesk_ws_ctl_badge_for_token, "finished"), 4);
        // Spellable, listable, and still not settable.
        assert_eq!(parse(slopdesk_ws_ctl_badge_for_token, "sudo"), -1);
        assert_eq!(parse(slopdesk_ws_ctl_badge_for_token, "command-busy"), -1);
        assert_eq!(parse(slopdesk_ws_ctl_badge_for_token, "purple"), -1);
        // SAFETY: a null pair is the documented "no text" case.
        assert_eq!(
            unsafe { slopdesk_ws_ctl_badge_for_token(std::ptr::null(), 0) },
            -1
        );
    }

    #[test]
    fn every_badge_index_prints_its_canonical_token() {
        let printed: Vec<String> = (0..TabBadge::ALL.len())
            .map(|index| {
                let byte = u8::try_from(index).unwrap_or(u8::MAX);
                // SAFETY: `delivered` lends a live buffer of exactly the length the door asked for.
                let bytes = delivered(|out, cap| unsafe { slopdesk_ws_ctl_badge_token(byte, out, cap) });
                String::from_utf8(bytes).expect("a canonical token is UTF-8")
            })
            .collect();
        assert_eq!(printed.first().map(String::as_str), Some("running"));
        assert_eq!(printed.last().map(String::as_str), Some("sudo"));
        assert!(printed.iter().all(|token| !token.is_empty()));
        // A byte past the ladder writes nothing rather than a neighbour's word.
        // SAFETY: a null buffer with a zero cap is the documented sizing call.
        assert_eq!(
            unsafe { slopdesk_ws_ctl_badge_token(9, std::ptr::null_mut(), 0) },
            0
        );
    }

    #[test]
    fn the_two_closed_vocabularies_cross_as_positions() {
        for (index, token) in PLACEMENTS.iter().enumerate() {
            let expected = i8::try_from(index).unwrap_or(-1);
            assert_eq!(
                parse(slopdesk_ws_ctl_placement_for_token, token),
                expected,
                "{token}"
            );
        }
        for (index, token) in FONT_SCOPES.iter().enumerate() {
            let expected = i8::try_from(index).unwrap_or(-1);
            assert_eq!(
                parse(slopdesk_ws_ctl_font_scope_for_token, token),
                expected,
                "{token}"
            );
        }
        assert_eq!(parse(slopdesk_ws_ctl_placement_for_token, "centre"), -1);
        assert_eq!(parse(slopdesk_ws_ctl_font_scope_for_token, "cloud"), -1);
        assert_eq!(parse(slopdesk_ws_ctl_font_scope_for_token, ""), -1);
    }

    /// The byte contract the Swift enums are declared against. A vocabulary that grows here without
    /// the far side growing a case makes the new token unreachable rather than wrong — but it is
    /// still a change nobody meant to make silently.
    #[test]
    fn the_vocabularies_are_the_size_the_far_side_declares() {
        assert_eq!(PLACEMENTS.len(), 6);
        assert_eq!(FONT_SCOPES.len(), 2);
        assert_eq!(METHODS.len(), 14);
    }
}
