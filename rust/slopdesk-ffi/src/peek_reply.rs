//! What the Peek & Reply card sends, and what it shows, in C.
//!
//! The rules are [`slopdesk_workspace::peek_reply`]; what is here is the marshalling. Three §4
//! doors, all answering TEXT — which is why none of them uses a handle: a reply is one short line
//! and a transcript tail is four, so the whole answer has a size the first call can report and the
//! ordinary size-then-read retry is cheaper than an arena the caller would have to give back.
//!
//! Which PANE the card answers is not here. That is `slopdesk_agent_peek_*` in
//! [`crate::agent`], beside the ordering the jump chord walks, because the two rank the same panes
//! by the same predicate and must never learn to disagree.
//!
//! ## Two doors for the field and the digit, not one
//!
//! [`slopdesk_ws_peek_quick_answer`] takes an `int32_t` and no text at all, and it would be one
//! character to route it through [`slopdesk_ws_peek_reply_text`] instead. It is separate because
//! the two are asked at different moments — a digit fires on a KEY PRESS while the field is empty,
//! the line fires on submit — and a single door would make a stray `5` typed into the middle of a
//! sentence indistinguishable from the answer to a numbered prompt.
//!
//! ## The transcript tail crosses as parallel blobs
//!
//! `commands` and `statuses` are two flat UTF-8 runs under ONE count, entry `i` of each belonging
//! to the same block — the shape the link and find scans already take. The alternative, one blob of
//! interleaved pairs, would make the caller build a third array to describe it.

use core::ffi::c_uchar;

use slopdesk_workspace::peek_reply;

use crate::link_detect::split;
use crate::{borrow, deliver, push_text, records_of, saturating_u32};

/// `[u32 BE length]` per line, after the count.
const LENGTH: usize = 4;

/// The bytes a typed reply sends down the pane's PTY, newline included.
///
/// `0` is the §4 refusal and here it means exactly what the rule means: an empty, whitespace-only
/// or bare-`!` field sends NOTHING, and the caller no-ops rather than typing a lone newline into a
/// prompt that is waiting for an answer. A real reply is never empty — it always carries at least
/// one character and the newline.
///
/// # Safety
/// `field` must be null or describe live memory for the whole call, and `out` must be null or
/// writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_ws_peek_reply_text(
    field: *const c_uchar,
    field_len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the pair is null or live for the call by the caller's obligation, discharged on the
    // Swift side by `withUnsafeBytes`, whose scope is exactly this call.
    let borrowed = unsafe { borrow(field, field_len) };
    let text = String::from_utf8_lossy(borrowed);
    let answer = peek_reply::reply(&text).unwrap_or_default();
    // SAFETY: `out` is null or writable for `cap` bytes by the caller's obligation, and `answer` is
    // a live local that cannot overlap it.
    unsafe { deliver(answer.as_bytes(), out, cap) }
}

/// The bytes a quick-answer DIGIT sends, or `0` for a key that is not one of `1`–`9`.
///
/// # Safety
/// `out` must be null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_ws_peek_quick_answer(digit: i32, out: *mut c_uchar, cap: usize) -> usize {
    let answer = peek_reply::quick_answer(digit).unwrap_or_default();
    // SAFETY: `out` is null or writable for `cap` bytes by the caller's obligation, and `answer` is
    // a live local that cannot overlap it.
    unsafe { deliver(answer.as_bytes(), out, cap) }
}

/// The `limit` newest command blocks as one line each, oldest-first.
///
/// `commands`/`statuses` are the flat UTF-8 blobs and `command_lengths`/`status_lengths` their
/// per-entry byte counts, all under `count`. The answer is `[u32 BE lines]` followed by that many
/// `[u32 BE length]` words and then the bytes they name, back to back.
///
/// The count leads the blob for the reason it does everywhere here: a pane with no blocks yet is
/// the state most panes are in, and a §4 return of `0` would make "nothing to show" and "ask again"
/// the same number.
///
/// # Safety
/// Each `(ptr, len)` pair must be null or describe live memory for the whole call, each length
/// array must be null or hold `count` entries, and `out` must be null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_ws_peek_recent_lines(
    commands: *const c_uchar,
    commands_len: usize,
    command_lengths: *const usize,
    statuses: *const c_uchar,
    statuses_len: usize,
    status_lengths: *const usize,
    count: usize,
    limit: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: every pair is null or live for the call by the caller's obligation, discharged on the
    // Swift side by `withUnsafeBufferPointer`, whose scope is exactly this call.
    let command_text = split(unsafe { borrow(commands, commands_len) }, unsafe {
        records_of(command_lengths, count)
    });
    // SAFETY: as above.
    let status_text = split(unsafe { borrow(statuses, statuses_len) }, unsafe {
        records_of(status_lengths, count)
    });
    let borrowed_commands: Vec<&str> = command_text.iter().map(String::as_str).collect();
    let borrowed_statuses: Vec<&str> = status_text.iter().map(String::as_str).collect();
    let lines = peek_reply::recent_lines(&borrowed_commands, &borrowed_statuses, limit);

    let body: usize = lines.iter().map(String::len).sum();
    let mut blob = Vec::with_capacity(
        LENGTH
            .saturating_add(lines.len().saturating_mul(LENGTH))
            .saturating_add(body),
    );
    blob.extend_from_slice(&saturating_u32(lines.len()).to_be_bytes());
    for line in &lines {
        blob.extend_from_slice(&saturating_u32(line.len()).to_be_bytes());
    }
    for line in &lines {
        blob.extend_from_slice(line.as_bytes());
    }
    // SAFETY: `out` is null or writable for `cap` bytes by the caller's obligation, and `blob` is a
    // live local that cannot overlap it.
    unsafe { deliver(&blob, out, cap) }
}

/// The card's fixed words, in one delivery.
///
/// ```text
/// 3 × [u32 length][UTF-8 bytes]   // the card title, the empty-state line, the missing-question line
/// ```
///
/// The three doors above answer TEXT as a bare run because each is one string with a size the
/// caller cannot predict. These three are constants and are always wanted together, which is the
/// group shape `docs/55` §6 describes — so they carry the length prefixes the other doors do not.
///
/// # Safety
/// `(out, cap)` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and `(out, cap)` is the caller's buffer"
)]
pub unsafe extern "C" fn slopdesk_ws_peek_words(out: *mut c_uchar, cap: usize) -> usize {
    let mut blob = Vec::new();
    for word in [
        peek_reply::TITLE,
        peek_reply::ALL_CAUGHT_UP,
        peek_reply::MISSING_QUESTION,
    ] {
        push_text(&mut blob, word);
    }
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe { deliver(&blob, out, cap) }
}

/// The card's position counter — `"2 of 5"` — or `0` when there is nothing to count.
///
/// ```text
/// 1 × [u32 length][UTF-8 bytes]
/// ```
///
/// `position` and `total` are read only when `has_position` is set.
///
/// # Safety
/// `(out, cap)` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and `(out, cap)` is the caller's buffer"
)]
pub unsafe extern "C" fn slopdesk_ws_peek_counter(
    has_position: bool,
    position: u32,
    total: u32,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    let Some(text) = peek_reply::counter(has_position.then_some((position, total))) else {
        return 0;
    };
    let mut blob = Vec::new();
    push_text(&mut blob, &text);
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe { deliver(&blob, out, cap) }
}

/// The transcript scroll's ceiling, in points.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_ws_peek_scroll_max_height() -> f64 {
    peek_reply::SCROLL_MAX_HEIGHT
}

/// The question a card prints, and whether it is the PLACEHOLDER rather than the agent's own words.
///
/// ```text
/// [u8 is_placeholder]
/// 1 × [u32 length][UTF-8 bytes]
/// ```
///
/// The flag exists because an agent that happened to ask the placeholder's exact sentence must
/// still be drawn as having asked it — the near side dims a placeholder, and dimming a real
/// question would hide what the card is for.
///
/// # Safety
/// `question` must be null or `question_len` live bytes; `(out, cap)` must be writable for `cap`
/// bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and both pointers are the caller's"
)]
pub unsafe extern "C" fn slopdesk_ws_peek_question(
    question: *const c_uchar,
    question_len: usize,
    has_question: bool,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, restated above; the borrow dies with this call.
    let question = String::from_utf8_lossy(unsafe { borrow(question, question_len) });
    let (text, placeholder) = peek_reply::question(has_question.then_some(question.as_ref()));
    let mut blob = vec![u8::from(placeholder)];
    push_text(&mut blob, text);
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe { deliver(&blob, out, cap) }
}

#[cfg(test)]
#[expect(unsafe_code, reason = "calling the door is the only way to test the door")]
mod tests {
    use slopdesk_workspace::peek_reply;

    use super::{
        LENGTH, slopdesk_ws_peek_counter, slopdesk_ws_peek_question, slopdesk_ws_peek_quick_answer,
        slopdesk_ws_peek_recent_lines, slopdesk_ws_peek_reply_text, slopdesk_ws_peek_scroll_max_height,
        slopdesk_ws_peek_words,
    };
    use crate::testing::{delivered, runs};

    #[test]
    fn the_three_fixed_words_cross_in_their_documented_order() {
        let blob = delivered(|out, cap| {
            // SAFETY: `out` is a live local for the call.
            unsafe { slopdesk_ws_peek_words(out, cap) }
        });
        let words = runs(&blob, 3);
        assert_eq!(words.first().map(String::as_str), Some(peek_reply::TITLE));
        assert_eq!(words.get(1).map(String::as_str), Some(peek_reply::ALL_CAUGHT_UP));
        assert_eq!(
            words.get(2).map(String::as_str),
            Some(peek_reply::MISSING_QUESTION)
        );
    }

    #[test]
    fn the_counter_crosses_unchanged_including_its_silence() {
        for position in [None, Some((0_u32, 0_u32)), Some((2, 5))] {
            let (has, at, total) = position.map_or((false, 0, 0), |(at, total)| (true, at, total));
            let blob = delivered(|out, cap| {
                // SAFETY: `out` is a live local for the call.
                unsafe { slopdesk_ws_peek_counter(has, at, total, out, cap) }
            });
            let expected = peek_reply::counter(position);
            if blob.is_empty() {
                assert_eq!(expected, None, "{position:?}");
            } else {
                assert_eq!(runs(&blob, 1).first().cloned(), expected, "{position:?}");
            }
        }
    }

    /// The placeholder flag survives an agent asking the placeholder's own sentence.
    #[test]
    fn the_question_crosses_with_its_provenance() {
        for question in [
            None,
            Some(""),
            Some("Proceed?"),
            Some(peek_reply::MISSING_QUESTION),
        ] {
            let bytes = question.unwrap_or_default().as_bytes().to_vec();
            let blob = delivered(|out, cap| {
                // SAFETY: `bytes` and `out` are live locals for the call.
                unsafe {
                    slopdesk_ws_peek_question(bytes.as_ptr(), bytes.len(), question.is_some(), out, cap)
                }
            });
            let (text, placeholder) = peek_reply::question(question);
            let (flag, rest) = blob
                .split_first()
                .map_or((0xFF, [].as_slice()), |(flag, rest)| (*flag, rest));
            assert_eq!(flag == 1, placeholder, "{question:?}");
            assert_eq!(
                runs(rest, 1).first().map(String::as_str),
                Some(text),
                "{question:?}"
            );
        }
    }

    #[test]
    fn the_scroll_ceiling_crosses_unchanged() {
        assert!((slopdesk_ws_peek_scroll_max_height() - peek_reply::SCROLL_MAX_HEIGHT).abs() < f64::EPSILON);
    }

    /// One §4 text door, sized then read.
    fn text(call: impl Fn(*mut u8, usize) -> usize) -> Option<String> {
        let needed = call(core::ptr::null_mut(), 0);
        if needed == 0 {
            return None;
        }
        let mut answer = vec![0_u8; needed];
        let written = call(answer.as_mut_ptr(), answer.len());
        assert_eq!(written, needed, "the sizing call and the filling call must agree");
        Some(String::from_utf8_lossy(&answer).into_owned())
    }

    fn reply(field: &str) -> Option<String> {
        text(|out, cap| {
            // SAFETY: every pointer names a live local for the duration of the call.
            unsafe { slopdesk_ws_peek_reply_text(field.as_ptr(), field.len(), out, cap) }
        })
    }

    fn quick(digit: i32) -> Option<String> {
        // SAFETY: the out pointer is the caller's local for the duration of the call.
        text(|out, cap| unsafe { slopdesk_ws_peek_quick_answer(digit, out, cap) })
    }

    fn recent(blocks: &[(&str, &str)], limit: usize) -> Vec<String> {
        let mut commands = Vec::new();
        let mut command_lengths = Vec::new();
        let mut statuses = Vec::new();
        let mut status_lengths = Vec::new();
        for (command, status) in blocks {
            commands.extend_from_slice(command.as_bytes());
            command_lengths.push(command.len());
            statuses.extend_from_slice(status.as_bytes());
            status_lengths.push(status.len());
        }
        let call = |out: *mut u8, cap: usize| {
            // SAFETY: every pointer names a live local for the duration of the call.
            unsafe {
                slopdesk_ws_peek_recent_lines(
                    commands.as_ptr(),
                    commands.len(),
                    command_lengths.as_ptr(),
                    statuses.as_ptr(),
                    statuses.len(),
                    status_lengths.as_ptr(),
                    blocks.len(),
                    limit,
                    out,
                    cap,
                )
            }
        };
        let needed = call(core::ptr::null_mut(), 0);
        let mut answer = vec![0_u8; needed];
        let written = call(answer.as_mut_ptr(), answer.len());
        assert_eq!(written, needed, "the sizing call and the filling call must agree");

        let word = |at: usize| {
            answer
                .get(at..at + LENGTH)
                .and_then(|bytes| <[u8; LENGTH]>::try_from(bytes).ok())
                .map_or(0, u32::from_be_bytes) as usize
        };
        let lines = word(0);
        let mut cursor = LENGTH + lines * LENGTH;
        (0..lines)
            .map(|index| {
                let length = word(LENGTH + index * LENGTH);
                let run = answer.get(cursor..cursor + length).unwrap_or(&[]);
                cursor += length;
                String::from_utf8_lossy(run).into_owned()
            })
            .collect()
    }

    #[test]
    fn the_three_reply_shapes_cross_with_their_newline() {
        assert_eq!(reply("yes").as_deref(), Some("yes\n"));
        assert_eq!(reply("  ! git status ").as_deref(), Some("git status\n"));
        assert_eq!(quick(7).as_deref(), Some("7\n"));
    }

    #[test]
    fn nothing_to_send_crosses_as_the_refusal() {
        for silent in ["", "   ", "!", "  !  "] {
            assert_eq!(reply(silent), None, "{silent:?}");
        }
        for outside in [0, 10, -1, i32::MAX] {
            assert_eq!(quick(outside), None, "{outside}");
        }
        // SAFETY: a null pair is exactly what the door is documented to accept.
        assert_eq!(
            unsafe { slopdesk_ws_peek_reply_text(core::ptr::null(), 0, core::ptr::null_mut(), 0) },
            0
        );
    }

    /// The separator and the ellipsis are multi-byte, so the length words are the crossing that
    /// matters: a line counted in characters would truncate both.
    #[test]
    fn the_tail_crosses_with_its_multi_byte_punctuation_intact() {
        let blocks = [
            ("make", "exit 0"),
            ("swift build", "exit 1"),
            ("swift test", "running\u{2026}"),
        ];
        assert_eq!(recent(&blocks, 2), vec![
            "swift build \u{b7} exit 1".to_owned(),
            "swift test \u{b7} running\u{2026}".to_owned(),
        ]);
    }

    #[test]
    fn a_pane_with_no_blocks_answers_a_count_of_zero_and_not_a_refusal() {
        let needed = {
            // SAFETY: a null pair is exactly what the door is documented to accept.
            unsafe {
                slopdesk_ws_peek_recent_lines(
                    core::ptr::null(),
                    0,
                    core::ptr::null(),
                    core::ptr::null(),
                    0,
                    core::ptr::null(),
                    0,
                    4,
                    core::ptr::null_mut(),
                    0,
                )
            }
        };
        assert_eq!(needed, LENGTH, "a count of zero, not the §4 refusal");
        assert!(recent(&[], 4).is_empty());
        assert!(recent(&[("x", "exit 0")], 0).is_empty());
    }

    #[test]
    fn a_block_with_no_command_crosses_as_its_status_alone() {
        assert_eq!(recent(&[("   ", "running\u{2026}")], 4), vec![
            "running\u{2026}".to_owned()
        ]);
    }
}
