//! What the SANITIZE passes still owe C, once the replay transform itself stopped crossing.
//!
//! The doors over `slopdesk-sanitize`, under the crate's pure convention: bytes in, bytes out,
//! nothing remembered. The whole-history transform is NOT among them any more. It crossed as
//! `slopdesk_sanitize` for the detached-window backlog, which was compacted outside the ring by a
//! Swift `ReplayBuffer` wrapper; `a0d0aa54` retired the replay doors and that wrapper together, and
//! the backlog is hostd's now — `slopdesk-hostd` calls `slopdesk_sanitize::sanitize` as a CRATE, in
//! `spawn.rs` and `transcripts.rs`, with no boundary in the middle. The door outlived its only
//! caller by one commit and was found by the door gate the day after.
//!
//! What crossed here replaced a socket, and that argument still holds for the three that remain:
//! reaching a screend verb meant an `AF_UNIX` round trip carrying the payload each way, and an
//! absent daemon meant the bytes went through RAW — which for the replay direction was not merely
//! uglier, since raw history can transiently arm a client's input reporting until the next prompt.
//! A pure function has no lifetime that wants a daemon, so it is linked, and the degraded path
//! stopped existing. Where the CALLER is Rust too, the link is a `use`, not a door.

use core::ffi::c_uchar;

use slopdesk_sanitize::{plaintext, styled, syncinput};

use crate::{borrow, deliver};

/// The private-use ranges, as `[u32 low][u32 high]` pairs, big-endian.
///
/// The plaintext strip DROPS these codepoints; the chrome SPLICES the bundled Nerd face over
/// exactly them (`NerdSymbolFont`). Opposite operations over one set, which is why the set crosses
/// instead of being typed on both sides — it was typed on both sides until 2026-08-26, and the two
/// copies disagreed about plane 16 and about where plane 15 ends. `plaintext`'s module doc has the
/// detail.
///
/// A TABLE crosses here where every other door in this file crosses an ANSWER, and that is the
/// point: the classification is per-scalar over a title redrawn on every keystroke, so a door per
/// scalar would be the wrong boundary at the wrong rate. The caller reads this once into a `static`
/// and asks it locally forever after.
///
/// # Safety
/// `out` must be null, or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and `(out, cap)` is the caller's"
)]
pub unsafe extern "C" fn slopdesk_private_use_ranges(out: *mut c_uchar, cap: usize) -> usize {
    let mut answer = Vec::with_capacity(plaintext::private_use_ranges().len() * 8);
    for &(low, high) in plaintext::private_use_ranges() {
        answer.extend_from_slice(&low.to_be_bytes());
        answer.extend_from_slice(&high.to_be_bytes());
    }
    // SAFETY: the caller's obligation, forwarded unchanged; `deliver` writes at most `cap`.
    unsafe { deliver(&answer, out, cap) }
}

/// An input chunk with everything a KEYBOARD did not produce removed, for the sync-input fan-out.
///
/// The other direction from the replay transform. That one reads host→client bytes and drops the
/// queries a replay would make a fresh terminal answer again — and it runs entirely inside hostd
/// now, as `slopdesk_sanitize::sanitize`; this reads client→host bytes and drops the ANSWERS —
/// terminal replies, mouse reports, focus events — because the tap rides the pane's single OUT
/// funnel and a sibling shell that never asked would run them as a command.
///
/// # Safety
/// `bytes` must be null or point to `len` live bytes; `out` null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_sync_input_keyboard_only(
    bytes: *const c_uchar,
    len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; `borrow` and `deliver` state their own.
    unsafe { deliver(&syncinput::keyboard_only(borrow(bytes, len)), out, cap) }
}

/// PTY bytes as the STYLED lines a person reads — the clipboard's skimmer, and the coloured one.
///
/// Not [`slopdesk_plaintext`]. That one renders for a REGEX and removes every sequence; this
/// renders for an EYE, so it rewrites columns (`CR`, `ESC [ K`), chops the zsh `PROMPT_EOL_MARK`
/// and keeps the SGR state each byte was written under.
///
/// ## The answer
/// ```text
/// [u32 BE lines]  ( [u32 BE runs]  ( [run header: 13 bytes] [text bytes] )* )*
/// ```
/// with a run header of `[u8 flags][u8 fg kind][u8 fg a][u8 fg b][u8 fg c][u8 bg …×4][u32 BE len]`.
/// `flags` is bold 1, dim 2, italic 4, underline 8, inverse 16; a colour kind is `0` absent, `1`
/// palette (`a` is the slot), `2` direct (`a`,`b`,`c` are r,g,b).
///
/// A colour's ABSENCE is a kind of `0` rather than a sentinel slot, for §4b's reason: the surface's
/// default is not a palette entry, and encoding it as one would paint a pane's own background over
/// text the stream never coloured.
///
/// An answer is never 0 bytes — an empty input is one empty line, which is four bytes of count plus
/// four of zero — so 0 stays the refusal it is everywhere else in this crate.
///
/// # Safety
/// `bytes` must be null or point to `len` live bytes; `out` null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_styled_lines(
    bytes: *const c_uchar,
    len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; `borrow` states its own.
    let input = unsafe { borrow(bytes, len) };
    let lines = styled::lines(input);
    let mut answer = Vec::new();
    answer.extend_from_slice(&count(lines.len()).to_be_bytes());
    for line in &lines {
        answer.extend_from_slice(&count(line.len()).to_be_bytes());
        for run in line {
            answer.push(flags(run.style));
            answer.extend_from_slice(&colour(run.style.foreground));
            answer.extend_from_slice(&colour(run.style.background));
            // A run past 4 GiB is a producer no clipboard is going to serve; the count is clamped
            // rather than wrapped so the walk the caller does stays inside the buffer either way.
            let text = run.text.as_bytes();
            answer.extend_from_slice(&count(text.len()).to_be_bytes());
            answer.extend_from_slice(text);
        }
    }
    // SAFETY: the caller's obligation, restated above; `deliver` states its own.
    unsafe { deliver(&answer, out, cap) }
}

/// A length as the `u32` the answer spells it with, clamped rather than wrapped.
fn count(value: usize) -> u32 {
    u32::try_from(value).unwrap_or(u32::MAX)
}

/// The five SGR attributes as one byte.
const fn flags(style: styled::Style) -> u8 {
    (style.bold as u8)
        | ((style.dim as u8) << 1)
        | ((style.italic as u8) << 2)
        | ((style.underline as u8) << 3)
        | ((style.inverse as u8) << 4)
}

/// One colour as `[kind, a, b, c]` — kind `0` absent, `1` palette, `2` direct.
const fn colour(value: Option<styled::Color>) -> [u8; 4] {
    match value {
        None => [0, 0, 0, 0],
        Some(styled::Color::Indexed(slot)) => [1, slot, 0, 0],
        Some(styled::Color::Rgb(r, g, b)) => [2, r, g, b],
    }
}

#[cfg(test)]
#[expect(
    unsafe_code,
    clippy::indexing_slicing,
    reason = "calling the boundary IS what these tests are for, and a decoded answer's shape is asserted \
              before it is read"
)]
mod tests {
    use super::{slopdesk_styled_lines, slopdesk_sync_input_keyboard_only};

    /// The sync-input door answers under the same convention, and strips the input direction's
    /// reports rather than the output direction's queries.
    #[test]
    fn the_sync_input_door_measures_then_fills() {
        let input = b"cc\x1b[8;33;96t\x1b[<65;31;18M\r";
        // SAFETY: the input is a live local; a null `out` with `cap` 0 is the measuring call.
        let needed = unsafe {
            slopdesk_sync_input_keyboard_only(input.as_ptr(), input.len(), core::ptr::null_mut(), 0)
        };
        assert_eq!(needed, 3, "the measure names the keystrokes without writing them");

        let mut out = [0_u8; 16];
        // SAFETY: both buffers are live locals.
        let written =
            unsafe { slopdesk_sync_input_keyboard_only(input.as_ptr(), input.len(), out.as_mut_ptr(), 16) };
        assert_eq!(
            &out[..written],
            b"cc\r",
            "the reports are gone and the typing is not"
        );
    }

    // The two tests that called the retired `slopdesk_sanitize` went with it, and neither took an
    // assertion out of the tree: the closed-alt-screen strip is asserted natively over the function
    // itself in `slopdesk-sanitize/src/sanitize.rs` and eight ways in that crate's `altscreen.rs`,
    // and §4's undersized-buffer retry is the shape every counted door here shares — `audio_codec`,
    // `simulator_decode` and `blocks` each pin it. A door's test may not be the last home of a
    // behaviour, or deleting the door deletes the coverage.

    /// A buffer too small writes NOTHING and reports what it needed, so the caller's retry is a
    /// clean second call rather than a truncated screen.
    #[test]
    fn an_undersized_buffer_writes_nothing_and_asks_again() {
        let input = b"cc\x1b[<65;31;18M\r";
        let mut tiny = [0xAA_u8; 2];
        // SAFETY: both buffers are live locals.
        let needed = unsafe {
            slopdesk_sync_input_keyboard_only(input.as_ptr(), input.len(), tiny.as_mut_ptr(), tiny.len())
        };
        assert!(needed > tiny.len(), "the answer outgrew the buffer");
        assert_eq!(tiny, [0xAA; 2], "and nothing was written into it");
    }

    /// One decoded run: the attribute flags, the foreground, the background, the text.
    type DecodedRun = (u8, [u8; 4], [u8; 4], String);

    /// The styled answer's own walk, so the layout the Swift face decodes is pinned on this side
    /// too: a caller that reads it wrong here reads it wrong there.
    fn styled(body: &str) -> Vec<Vec<DecodedRun>> {
        let mut buffer = [0_u8; 4096];
        // SAFETY: both pointers name a live local for the duration of the call.
        let needed =
            unsafe { slopdesk_styled_lines(body.as_ptr(), body.len(), buffer.as_mut_ptr(), buffer.len()) };
        assert!(needed > 0 && needed <= buffer.len(), "the fixture fits");
        let answer = buffer.get(..needed).unwrap_or_default().to_vec();
        let mut cursor = 0;
        let mut take = |n: usize| {
            let slice = answer.get(cursor..cursor + n).unwrap_or_default().to_vec();
            cursor += n;
            slice
        };
        let four = |bytes: Vec<u8>| -> u32 {
            u32::from_be_bytes(<[u8; 4]>::try_from(bytes.as_slice()).unwrap_or_default())
        };
        let line_count = four(take(4));
        let mut lines = Vec::new();
        for _ in 0..line_count {
            let run_count = four(take(4));
            let mut runs = Vec::new();
            for _ in 0..run_count {
                let flags = take(1).first().copied().unwrap_or_default();
                let fg = <[u8; 4]>::try_from(take(4).as_slice()).unwrap_or_default();
                let bg = <[u8; 4]>::try_from(take(4).as_slice()).unwrap_or_default();
                let len = four(take(4)) as usize;
                let text = String::from_utf8_lossy(&take(len)).into_owned();
                runs.push((flags, fg, bg, text));
            }
            lines.push(runs);
        }
        assert_eq!(cursor, answer.len(), "the walk consumed exactly the answer");
        lines
    }

    #[test]
    fn a_styled_line_crosses_with_its_colours_and_its_attributes() {
        let lines = styled("\x1b[1;31mred\x1b[0m plain");
        assert_eq!(lines.len(), 1);
        assert_eq!(lines[0].len(), 2);
        assert_eq!(lines[0][0].0, 1, "bold");
        assert_eq!(lines[0][0].1, [1, 1, 0, 0], "palette slot 1");
        assert_eq!(lines[0][0].3, "red");
        assert_eq!(lines[0][1].0, 0);
        assert_eq!(lines[0][1].1, [0, 0, 0, 0], "absent is a kind, not a slot");
        assert_eq!(lines[0][1].3, " plain");
    }

    #[test]
    fn a_direct_colour_and_an_empty_input_both_have_a_shape() {
        let lines = styled("\x1b[48;2;10;20;30mx");
        assert_eq!(lines[0][0].2, [2, 10, 20, 30]);
        // An empty input is one empty line — never zero bytes, which is this crate's refusal.
        let mut buffer = [0_u8; 16];
        // SAFETY: the output pointer names a live local; a null input is what `borrow` documents.
        let needed = unsafe { slopdesk_styled_lines(std::ptr::null(), 0, buffer.as_mut_ptr(), buffer.len()) };
        assert_eq!(needed, 8, "one line count, one run count");
        assert_eq!(buffer.get(..8), Some(&[0, 0, 0, 1, 0, 0, 0, 0][..]));
    }
}
