//! The clipboard menu's previews and its enablement, in C.
//!
//! The rules are [`slopdesk_workspace::paste_menu`]; what is here is the marshalling.
//!
//! ## The clip TEXT only travels one way
//!
//! A row carries the full clip so it can be typed, and a masked label so it can be drawn. Only the
//! second crosses. The caller already holds the ring it is asking about — it is the caller's own
//! clipboard history — so sending the clips back would be handing somebody their own secrets across
//! a boundary for no reason at all. The doors here answer LABELS, and the near side zips them
//! against the prefix of the ring it asked for.
//!
//! ## The mask flag rides inside the run rather than beside it
//!
//! A preview is two answers, a label and a verdict, and they must not be asked separately: two
//! doors would classify the same clip twice, and a classifier that answered differently the second
//! time would draw a masked row and then paste it as ordinary text. So each run's FIRST byte is the
//! verdict and the rest is the label. One classification, one delivery.

use core::ffi::c_uchar;

use slopdesk_workspace::paste_menu;

use crate::{borrow, deliver, lent, saturating_u32};

/// One preview as a run: the secret flag, then the label's UTF-8.
fn push_preview(blob: &mut Vec<u8>, text: &str) {
    let preview = paste_menu::preview(text);
    let mut run = Vec::with_capacity(preview.label.len() + 1);
    run.push(u8::from(preview.is_secret));
    run.extend_from_slice(preview.label.as_bytes());
    // `push_text` frames a run and takes `&str`; this one is not one, so the frame is spelled here.
    blob.extend_from_slice(&saturating_u32(run.len()).to_be_bytes());
    blob.extend_from_slice(&run);
}

/// How many characters of a non-secret clip survive before the ellipsis, in grapheme clusters.
///
/// Asked rather than transcribed: it is what the near side's tests assert a truncated label's
/// length against, and a copy would pass on a limit this side stopped applying.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_ws_paste_preview_limit() -> usize {
    paste_menu::PREVIEW_LIMIT
}

/// How many recent clips the ring submenu lists.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_ws_paste_row_limit() -> usize {
    paste_menu::ROW_LIMIT
}

/// One clip's preview: `[u32 length][flag byte][label UTF-8]`.
///
/// Never 0 — the flag byte is always there, so a length of 1 is an empty label (a whitespace-only
/// clip) rather than an absent answer.
///
/// # Safety
/// `(bytes, len)` must be null, or name `len` initialised bytes live for the call; `(out, cap)`
/// must be null, or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and both pointers are the caller's"
)]
pub unsafe extern "C" fn slopdesk_ws_paste_preview(
    bytes: *const c_uchar,
    len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, forwarded unchanged.
    let text = unsafe { lent(bytes, len) };
    let mut answer = Vec::new();
    push_preview(&mut answer, text);
    // SAFETY: ditto; `deliver` writes at most `cap`.
    unsafe { deliver(&answer, out, cap) }
}

/// The submenu's previews for a whole ring, capped at `limit`.
///
/// `ring` is `count` length-prefixed runs — the framing [`crate::push_text`] writes — and the
/// answer is one preview run per ROW, in the same order, so the near side zips them against the
/// ring's own prefix. A ring longer than `limit` is cut HERE, so the cap cannot be applied twice or
/// not at all.
///
/// 0 means no rows, which an empty ring and a `limit` of zero both produce; the view draws that as
/// a disabled "No recent clips" rather than as an empty menu.
///
/// # Safety
/// `(ring, ring_len)` must be null, or name `ring_len` initialised bytes live for the call;
/// `(out, cap)` must be null, or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and both pointers are the caller's"
)]
pub unsafe extern "C" fn slopdesk_ws_paste_rows(
    ring: *const c_uchar,
    ring_len: usize,
    count: usize,
    limit: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, forwarded unchanged.
    let blob = unsafe { borrow(ring, ring_len) };
    let rows = paste_menu::row_count(count, limit);
    let mut answer = Vec::new();
    let mut cursor = 0_usize;
    for _ in 0..rows {
        let Some(text) = next_run(blob, &mut cursor) else {
            // A truncated blob stops the walk rather than reading past its end: the answer is the
            // rows that were whole, which is what a caller that mis-framed its ring should see.
            break;
        };
        push_preview(&mut answer, text);
    }
    // SAFETY: ditto; `deliver` writes at most `cap`.
    unsafe { deliver(&answer, out, cap) }
}

/// The next length-prefixed run of `blob`, advancing the cursor past it.
///
/// `None` for a truncated or over-claiming prefix. Unreadable UTF-8 reads as empty, exactly as
/// [`crate::lent`] does, because a clip this side cannot decode still occupies a ring slot.
fn next_run<'a>(blob: &'a [u8], cursor: &mut usize) -> Option<&'a str> {
    let header = blob.get(*cursor..cursor.checked_add(4)?)?;
    let length = usize::try_from(u32::from_be_bytes(header.try_into().ok()?)).ok()?;
    let start = cursor.checked_add(4)?;
    let end = start.checked_add(length)?;
    let run = blob.get(start..end)?;
    *cursor = end;
    Some(core::str::from_utf8(run).unwrap_or(""))
}

/// Whether the "Paste as Keystrokes" item is enabled.
///
/// A scalar door with a scalar answer, and `clipboard_has_text` is a FLAG rather than the
/// clipboard: reading iOS's pasteboard content from a renderer raises the modal "Allow Paste?"
/// alert, so an enablement path that COULD take content is one that eventually will. The module
/// says it at more length.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_ws_paste_can_paste(
    can_paste_keystrokes: bool,
    clipboard_has_text: bool,
) -> bool {
    paste_menu::can_paste(can_paste_keystrokes, clipboard_has_text)
}

/// Whether a clip already in hand is worth typing: present, and not only whitespace.
///
/// A null pair and an empty one both answer `false`, which is why this takes bytes rather than an
/// optional: an absent clipboard and an empty one are the same nothing to this question.
///
/// # Safety
/// `(bytes, len)` must be null, or name `len` initialised bytes live for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and `(bytes, len)` is the caller's"
)]
pub unsafe extern "C" fn slopdesk_ws_paste_is_pastable(bytes: *const c_uchar, len: usize) -> bool {
    // SAFETY: the caller's obligation, forwarded unchanged.
    let text = unsafe { lent(bytes, len) };
    // A null pair reads as `""` here, and an empty clip is not pastable — so the rule's `None` and
    // its `Some("")` land on the same answer without this door having to tell them apart.
    paste_menu::is_pastable(Some(text))
}

#[cfg(test)]
mod tests {
    #![expect(unsafe_code, reason = "calling the boundary IS what these tests are for")]
    #![expect(
        clippy::panic,
        reason = "an unreachable branch in a test IS the report — a silent `return` would pass"
    )]

    use slopdesk_workspace::paste_menu;

    use super::{
        slopdesk_ws_paste_can_paste, slopdesk_ws_paste_is_pastable, slopdesk_ws_paste_preview,
        slopdesk_ws_paste_preview_limit, slopdesk_ws_paste_row_limit, slopdesk_ws_paste_rows,
    };
    use crate::push_text;
    use crate::testing::delivered;

    /// A ring as the door reads one.
    fn ring(clips: &[&str]) -> Vec<u8> {
        let mut blob = Vec::new();
        for clip in clips {
            push_text(&mut blob, clip);
        }
        blob
    }

    /// Splits a delivery back into `(is_secret, label)` pairs.
    fn previews(blob: &[u8]) -> Vec<(bool, String)> {
        let mut rows = Vec::new();
        let mut cursor = 0_usize;
        while cursor + 4 <= blob.len() {
            let Some(header) = blob.get(cursor..cursor + 4) else {
                break;
            };
            let Ok(header) = <[u8; 4]>::try_from(header) else {
                break;
            };
            let length = u32::from_be_bytes(header) as usize;
            let Some(run) = blob.get(cursor + 4..cursor + 4 + length) else {
                break;
            };
            cursor += 4 + length;
            let Some((flag, label)) = run.split_first() else {
                break;
            };
            rows.push((*flag == 1, String::from_utf8_lossy(label).into_owned()));
        }
        rows
    }

    /// The two limits come from the crate, so a near side that asserts against them asserts against
    /// what is applied.
    #[test]
    fn the_limits_are_the_crates() {
        assert_eq!(slopdesk_ws_paste_preview_limit(), paste_menu::PREVIEW_LIMIT);
        assert_eq!(slopdesk_ws_paste_row_limit(), paste_menu::ROW_LIMIT);
    }

    /// One clip: the flag and the label in one delivery, and the clip itself never coming back.
    #[test]
    fn a_preview_carries_its_verdict_in_the_same_run_as_its_label() {
        let plain =
            delivered(|out, cap| unsafe { slopdesk_ws_paste_preview("hello world".as_ptr(), 11, out, cap) });
        assert_eq!(previews(&plain), vec![(false, "hello world".to_owned())]);

        let secret = ["aB3xK9mZ", "2qP7wL5n", "R8tY4vC1"].concat();
        let masked = delivered(|out, cap| unsafe {
            slopdesk_ws_paste_preview(secret.as_ptr(), secret.len(), out, cap)
        });
        let rows = previews(&masked);
        assert_eq!(rows.len(), 1);
        let Some((is_secret, label)) = rows.first() else {
            panic!("one preview, always")
        };
        assert!(*is_secret, "flagged secret");
        assert!(label.starts_with(paste_menu::MASK_LEAD));
        assert!(!label.contains(&secret), "the clip did not come back");
    }

    /// A whitespace-only clip answers a run of exactly the flag byte — an empty label, not an
    /// absent one.
    #[test]
    fn an_empty_label_is_one_byte_and_not_a_missing_answer() {
        let blank = delivered(|out, cap| unsafe { slopdesk_ws_paste_preview("   ".as_ptr(), 3, out, cap) });
        assert_eq!(blank.len(), 5, "four framing bytes and the flag");
        assert_eq!(previews(&blank), vec![(false, String::new())]);
    }

    /// The ring is cut at the limit HERE, so the cap is applied exactly once.
    #[test]
    fn the_ring_is_previewed_in_order_and_cut_at_the_limit() {
        let clips: Vec<String> = (0..20).map(|index| format!("clip-{index}")).collect();
        let borrowed: Vec<&str> = clips.iter().map(String::as_str).collect();
        let blob = ring(&borrowed);
        let answer = delivered(|out, cap| unsafe {
            slopdesk_ws_paste_rows(blob.as_ptr(), blob.len(), clips.len(), 5, out, cap)
        });
        let labels: Vec<String> = previews(&answer).into_iter().map(|row| row.1).collect();
        assert_eq!(labels, ["clip-0", "clip-1", "clip-2", "clip-3", "clip-4"]);
        assert!(
            previews(&answer).iter().all(|row| !row.0),
            "a plain clip is not flagged",
        );
    }

    /// An empty ring, and a zero limit, both answer nothing.
    #[test]
    fn an_empty_ring_lists_nothing() {
        let empty: Vec<u8> = Vec::new();
        assert_eq!(
            unsafe { slopdesk_ws_paste_rows(empty.as_ptr(), 0, 0, 12, core::ptr::null_mut(), 0) },
            0,
        );
        let blob = ring(&["a", "b"]);
        assert_eq!(
            unsafe { slopdesk_ws_paste_rows(blob.as_ptr(), blob.len(), 2, 0, core::ptr::null_mut(), 0) },
            0,
        );
    }

    /// A ring whose framing claims more than it carries stops at the last whole run rather than
    /// reading past the end — the same totality every door here owes a caller.
    #[test]
    fn a_truncated_ring_stops_at_the_last_whole_run() {
        let mut blob = ring(&["one", "two"]);
        blob.truncate(blob.len() - 1);
        let answer = delivered(|out, cap| unsafe {
            slopdesk_ws_paste_rows(blob.as_ptr(), blob.len(), 2, 12, out, cap)
        });
        assert_eq!(previews(&answer), vec![(false, "one".to_owned())]);
    }

    /// Enablement and the content-in-hand reduction, both scalar.
    #[test]
    fn the_two_enablement_doors_answer_the_crates_rules() {
        assert!(slopdesk_ws_paste_can_paste(true, true));
        assert!(!slopdesk_ws_paste_can_paste(false, true));
        assert!(!slopdesk_ws_paste_can_paste(true, false));

        assert!(unsafe { slopdesk_ws_paste_is_pastable("hi".as_ptr(), 2) });
        assert!(!unsafe { slopdesk_ws_paste_is_pastable(core::ptr::null(), 0) });
        assert!(!unsafe { slopdesk_ws_paste_is_pastable("".as_ptr(), 0) });
        assert!(!unsafe { slopdesk_ws_paste_is_pastable("  \n\t ".as_ptr(), 5) });
    }
}
