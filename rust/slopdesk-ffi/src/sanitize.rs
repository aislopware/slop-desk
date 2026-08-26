//! The scrollback REPLAY transform, in C.
//!
//! One entry point over [`slopdesk_sanitize::sanitize`], under the crate's pure convention: bytes
//! in, bytes out, nothing remembered. The replay handle calls the same function internally on a
//! cold reattach; this exists for the caller's OTHER user of it — the detached-window backlog,
//! which is compacted outside the ring.
//!
//! It replaces a socket. The transform was a screend verb, so reaching it meant an `AF_UNIX` round
//! trip carrying the whole retained history in each direction, and an absent daemon meant the
//! history replayed RAW — which is not merely uglier: raw history can transiently arm a client's
//! input reporting until the shell's next prompt. A pure function has no lifetime that wants a
//! daemon, so it is linked, and the degraded path stopped existing.

use core::ffi::c_uchar;

use slopdesk_sanitize::{Options, inputmode, lines, plaintext, sanitize, styled, syncinput};

use crate::{borrow, deliver};

/// The replay transform's answer, under §4's convention.
///
/// `distill` selects the line-editor collapse — the one pass a caller may decline. The other six
/// always run. `reassert_input_modes` re-appends the stream's NET final input-mode state after the
/// passes: the live ring wants it, so a session still inside a TUI keeps that TUI's modes across a
/// cold reattach, and the disk journal must not, because after a daemon restart there is no TUI to
/// serve.
///
/// # Safety
/// `bytes` must be null or point to `len` live bytes; `out` null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_sanitize(
    bytes: *const c_uchar,
    len: usize,
    distill: bool,
    reassert_input_modes: bool,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; `borrow` states its own.
    let input = unsafe { borrow(bytes, len) };
    let answer = sanitize(input, Options {
        distill,
        reassert_input_modes,
    });
    // SAFETY: the caller's obligation, restated above; `deliver` states its own.
    unsafe { deliver(&answer, out, cap) }
}

/// PTY bytes as the plain text a pattern is matched against.
///
/// Not the replay transform. That one keeps a faithful terminal stream and removes only churn;
/// this removes every sequence and every private-use glyph, because the caller is a regex and a
/// pane's text is all it wants.
///
/// # Safety
/// `bytes` must be null or point to `len` live bytes; `out` null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_plaintext_strip(
    bytes: *const c_uchar,
    len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; `borrow` and `deliver` state their own.
    unsafe { deliver(&plaintext::strip(borrow(bytes, len)), out, cap) }
}

/// The private-use ranges, as `[u32 low][u32 high]` pairs, big-endian.
///
/// The strip above DROPS these codepoints; the chrome SPLICES the bundled Nerd face over exactly
/// them (`NerdSymbolFont`). Opposite operations over one set, which is why the set crosses instead
/// of being typed on both sides — it was typed on both sides until 2026-08-26, and the two copies
/// disagreed about plane 16 and about where plane 15 ends. `plaintext`'s module doc has the detail.
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

/// Plain text as LOGICAL lines — the `read --unwrapped` verb's answer.
///
/// The lines are delivered JOINED by `\n`, with their count written to `line_count`, and the caller
/// splits on the same byte: a logical line cannot contain one by construction, so the join is
/// exact, and the count is what tells no lines at all from one empty line — two answers a joined
/// blob spells identically and an orchestrator asking "did anything arrive" needs apart.
///
/// `limit` is how many lines to keep counting from the END; `0` is all of them.
///
/// # Safety
/// `text` must be null or point to `len` live bytes; `out` null or writable for `cap` bytes;
/// `line_count` null or writable.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_logical_lines(
    text: *const c_uchar,
    len: usize,
    limit: usize,
    out: *mut c_uchar,
    cap: usize,
    line_count: *mut usize,
) -> usize {
    // SAFETY: the caller's obligation above is `borrow`'s.
    let body = String::from_utf8_lossy(unsafe { borrow(text, len) }).into_owned();
    let rows = lines::logical_lines(&body, Some(limit));
    if !line_count.is_null() {
        // SAFETY: non-null and writable by the caller's obligation above.
        unsafe { *line_count = rows.len() };
    }
    // SAFETY: the caller's obligation above is `deliver`'s.
    unsafe { deliver(rows.join("\n").as_bytes(), out, cap) }
}

/// Where a chunk's trailing INCOMPLETE sequence begins, so a caller feeding one chunk at a time can
/// hold that tail back until its continuation arrives.
///
/// `len` means nothing is held. The same grammar [`slopdesk_plaintext_strip`] reads, asked the
/// other way — the two used to be hand-rolled Swift machines whose doc comments promised each other
/// they matched.
///
/// # Safety
/// `bytes` must be null or point to `len` live bytes for the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_plaintext_holdback(bytes: *const c_uchar, len: usize) -> usize {
    // SAFETY: the caller's obligation, restated above; `borrow` states its own.
    unsafe { plaintext::holdback_start(borrow(bytes, len)) }
}

/// An input chunk with everything a KEYBOARD did not produce removed, for the sync-input fan-out.
///
/// The other direction from [`slopdesk_sanitize`]. That one reads host→client bytes and drops the
/// queries a replay would make a fresh terminal answer again; this reads client→host bytes and
/// drops the ANSWERS — terminal replies, mouse reports, focus events — because the tap rides the
/// pane's single OUT funnel and a sibling shell that never asked would run them as a command.
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

/// The bytes that put a terminal back to a known-quiet input state.
///
/// The backstop a restore appends when the passes did not run — a raw journal tail, or a run with
/// the transform disabled. Built from the same array [`slopdesk_sanitize`] strips by, so a mode
/// added there cannot be silently missing here.
///
/// # Safety
/// `out` must be null or writable for `cap` bytes for the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_input_mode_reset(out: *mut c_uchar, cap: usize) -> usize {
    // SAFETY: the caller's obligation, restated above; `deliver` states its own.
    unsafe { deliver(&inputmode::reset_suffix(), out, cap) }
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
    use super::{
        slopdesk_input_mode_reset, slopdesk_plaintext_holdback, slopdesk_plaintext_strip, slopdesk_sanitize,
        slopdesk_styled_lines, slopdesk_sync_input_keyboard_only,
    };

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

    /// The passes run, and the answer fits the convention: a closed alt-screen segment is dropped
    /// and the history either side of it survives.
    #[test]
    fn a_closed_segment_is_stripped_and_its_neighbours_are_not() {
        let mut raw = b"before\n".to_vec();
        raw.extend_from_slice(b"\x1b[?1049h");
        raw.extend_from_slice(b"a whole TUI redrawing itself\n");
        raw.extend_from_slice(b"\x1b[?1049l");
        raw.extend_from_slice(b"after\n");
        let mut out = [0_u8; 256];
        // SAFETY: both buffers are live locals.
        let written =
            unsafe { slopdesk_sanitize(raw.as_ptr(), raw.len(), true, false, out.as_mut_ptr(), out.len()) };
        let text = String::from_utf8_lossy(out.get(..written).unwrap_or(&[])).into_owned();
        assert!(text.contains("before"), "{text:?}");
        assert!(text.contains("after"), "{text:?}");
        assert!(!text.contains("redrawing"), "{text:?}");
    }

    /// A buffer too small writes NOTHING and reports what it needed, so the caller's retry is a
    /// clean second call rather than a truncated screen.
    #[test]
    fn an_undersized_buffer_writes_nothing_and_asks_again() {
        let raw = b"plain history with no churn in it at all\n";
        let mut tiny = [0xAA_u8; 4];
        // SAFETY: both buffers are live locals.
        let needed = unsafe {
            slopdesk_sanitize(
                raw.as_ptr(),
                raw.len(),
                true,
                false,
                tiny.as_mut_ptr(),
                tiny.len(),
            )
        };
        assert!(needed > tiny.len(), "the answer outgrew the buffer");
        assert_eq!(tiny, [0xAA; 4], "and nothing was written into it");
    }

    /// The plaintext doors answer under the same convention, and the two agree about the grammar.
    #[test]
    fn the_plaintext_doors_measure_then_fill_and_name_the_cut() {
        let input = b"\x1b[1mready\x1b[0m";
        let needed =
            unsafe { slopdesk_plaintext_strip(input.as_ptr(), input.len(), core::ptr::null_mut(), 0) };
        assert_eq!(needed, 5, "the measure names the text without writing it");
        let mut room = vec![0_u8; needed];
        let written =
            unsafe { slopdesk_plaintext_strip(input.as_ptr(), input.len(), room.as_mut_ptr(), room.len()) };
        assert_eq!(written, needed);
        assert_eq!(room, b"ready".to_vec());

        let cut = b"ok\x1b[3";
        assert_eq!(
            unsafe { slopdesk_plaintext_holdback(cut.as_ptr(), cut.len()) },
            2,
            "an unfinished CSI waits for its final byte"
        );
        assert_eq!(
            unsafe { slopdesk_plaintext_holdback(input.as_ptr(), input.len()) },
            input.len(),
            "and a whole buffer holds nothing back"
        );
    }

    /// The reset the near side used to spell out, byte for byte.
    #[test]
    fn the_reset_backstop_is_the_bytes_the_near_side_carried() {
        let needed = unsafe { slopdesk_input_mode_reset(core::ptr::null_mut(), 0) };
        let mut room = vec![0_u8; needed];
        let written = unsafe { slopdesk_input_mode_reset(room.as_mut_ptr(), room.len()) };
        assert_eq!(written, needed);
        assert_eq!(
            room,
            b"\x1b[?1049l\x1b[?1l\x1b[?9l\x1b[?1000l\x1b[?1001l\x1b[?1002l\x1b[?1003l\x1b[?1004l\
              \x1b[?1005l\x1b[?1006l\x1b[?1015l\x1b[?1016l\x1b[?2004l\x1b[?2031l\x1b[?2048l\
              \x1b[<32u\x1b[=0;1u\x1b[0m\x1b[?25h\r\n"
                .to_vec(),
            "the same resets, in the order the tracked set is written in"
        );
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
