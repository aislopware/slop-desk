//! PTY bytes as the STYLED text a person reads — the clipboard's skimmer, and the coloured one.
//!
//! A finished command's captured output is already the on-screen byte stream for that command, so a
//! linear pass with column rewriting reproduces what the person saw closely enough to copy or to
//! preview. This is that pass, and every byte it emits carries the SGR state that was live when it
//! was written.
//!
//! ## Not [`crate::plaintext`], and not a terminal
//!
//! `plaintext` renders bytes for a REGEX: it removes every sequence, folds Nerd-Font glyphs away
//! and never rewrites a column, because a pattern is not a screen. This renders bytes for an EYE:
//! the `CR` line-rewrite so a progress bar collapses to its final frame, `ESC [ K` truncation, the
//! zsh `PROMPT_EOL_MARK` chop, and the colours kept. Neither is a terminal emulator — no cursor
//! addressing, no scroll regions, no alternate screen.
//!
//! ## One pass, two readings
//!
//! The plain-text reading is this pass with the styles discarded (`run.text` joined, lines joined
//! by `\n`). That is why they are one function: as two, the clipboard's text and the coloured text
//! were two behaviours whose doc comments promised each other they matched.
//!
//! ## Columns are BYTES
//!
//! A multi-byte scalar occupies several columns, so a `CR` rewrite can land mid-scalar. That is
//! what the pass this replaced did, and its tests pin it. Each run is decoded LOSSILY at the end,
//! so a cut scalar costs one `U+FFFD` rather than the line.

use crate::vtscan::{ESC, Terminators, parse_csi, string_sequence_end};

/// One colour as the stream expressed it. The palette that resolves it belongs to the view.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Color {
    /// A palette slot: 0–7 standard, 8–15 bright, 16–255 the xterm cube + greyscale ramp.
    Indexed(u8),
    /// A direct 24-bit colour (`ESC [ 38 ; 2 ; r ; g ; b m`).
    Rgb(u8, u8, u8),
}

/// The SGR state one run of text was written under.
///
/// `inverse` is carried rather than applied: swapping it means naming the DEFAULT foreground and
/// background, and only the surface knows those.
///
/// Five bools, not a state with five states: SGR sets and clears each one independently, and every
/// combination of them is something a real stream produces. Packing them into flags would only move
/// the same five questions behind a mask.
#[expect(
    clippy::struct_excessive_bools,
    reason = "SGR sets and clears each attribute independently — all 32 combinations are reachable"
)]
#[derive(Clone, Copy, PartialEq, Eq, Debug, Default)]
pub struct Style {
    /// The foreground, or `None` for the surface's default.
    pub foreground: Option<Color>,
    /// The background, or `None` for the surface's default.
    pub background: Option<Color>,
    /// SGR 1.
    pub bold: bool,
    /// SGR 2.
    pub dim: bool,
    /// SGR 3.
    pub italic: bool,
    /// SGR 4.
    pub underline: bool,
    /// SGR 7 — reverse video.
    pub inverse: bool,
}

/// A maximal stretch of text written under one style.
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct Run {
    /// The text, decoded lossily.
    pub text: String,
    /// The style every byte of it was written under.
    pub style: Style,
}

/// The cap a decoded parameter is accumulated under, so a degenerate digit run (`ESC [ 99999…m`)
/// can never overflow. Well past every parameter any real sequence carries.
const PARAM_CAP: u32 = 100_000_000;

/// Skims `bytes` into LINES of styled runs.
///
/// One entry per line INCLUDING the last, unterminated one — so joining the entries' text with
/// `\n` reproduces the plain text byte for byte, which is the property the clipboard path is
/// expressed on. An empty input is one empty line, not zero lines.
#[must_use]
pub fn lines(bytes: &[u8]) -> Vec<Vec<Run>> {
    if bytes.is_empty() {
        return vec![Vec::new()];
    }
    let mut out: Vec<Vec<Run>> = Vec::new();
    // The current visual line as a COLUMN-indexed buffer of (byte, style) with a cursor, so a
    // progress bar redrawing one line via `\r` collapses to its final frame rather than every frame
    // concatenated.
    let mut line: Vec<(u8, Style)> = Vec::new();
    let mut col = 0_usize; // invariant: col <= line.len()
    let mut style = Style::default();
    // The column of a reverse-video `%`/`#` followed only by pad whitespace — zsh's
    // PROMPT_EOL_MARK, which lands inside the captured bytes when a command's last line has no
    // trailing newline and would otherwise survive as a bare "%". Chopped at the very end.
    let mut eol_mark: Option<usize> = None;
    let mut i = 0_usize;

    while let Some(&byte) = bytes.get(i) {
        match byte {
            ESC => {
                let end = escape_end(bytes, i);
                apply_sgr(bytes, i, end, &mut style);
                if is_erase_to_line_end(bytes, i, end) && col < line.len() {
                    line.truncate(col); // `ESC [ K` — erase cursor → end of line
                }
                i = end;
            },
            0x0A => {
                // LF — commit the current visual line.
                out.push(runs_of(&line));
                line.clear();
                col = 0;
                eol_mark = None;
                i += 1;
            },
            0x09 => {
                // HT — meaningful whitespace, kept at the cursor.
                eol_mark = None;
                put(&mut line, &mut col, 0x09, style);
                i += 1;
            },
            0x0D => {
                // CR — `\r\n` is a newline; a lone `\r` rewinds the cursor (overwrite motion).
                if bytes.get(i + 1) == Some(&0x0A) {
                    out.push(runs_of(&line));
                    line.clear();
                    col = 0;
                    eol_mark = None;
                    i += 2;
                } else {
                    col = 0;
                    i += 1;
                }
            },
            0x00..=0x08 | 0x0B | 0x0C | 0x0E..=0x1F | 0x7F => {
                i += 1; // other C0 controls + DEL — formatting noise for a preview or a paste
            },
            b'#' | b'%' => {
                // A candidate zsh EOL mark iff currently reverse-video.
                eol_mark = style.inverse.then_some(col);
                put(&mut line, &mut col, byte, style);
                i += 1;
            },
            b' ' => {
                // Pad after the mark; keeps a pending candidate alive.
                put(&mut line, &mut col, byte, style);
                i += 1;
            },
            _ => {
                // Printable ASCII or a UTF-8 lead/continuation byte — kept verbatim; any ordinary
                // printable invalidates a pending EOL-mark candidate.
                eol_mark = None;
                put(&mut line, &mut col, byte, style);
                i += 1;
            },
        }
    }
    // Chop a trailing PROMPT_EOL_MARK from the final, unterminated line, then flush it.
    if let Some(mark) = eol_mark.filter(|&mark| mark < line.len()) {
        line.truncate(mark);
    }
    out.push(runs_of(&line));
    out
}

/// Writes one byte at the cursor, extending the line when the cursor is at its end.
fn put(line: &mut Vec<(u8, Style)>, col: &mut usize, byte: u8, style: Style) {
    if let Some(cell) = line.get_mut(*col) {
        *cell = (byte, style);
    } else {
        line.push((byte, style));
    }
    *col += 1;
}

/// Coalesces a column buffer into maximal same-style runs, decoding each LOSSILY — a preview is
/// best-effort and must never lose a whole line to one bad byte.
fn runs_of(line: &[(u8, Style)]) -> Vec<Run> {
    let Some(&(_, first)) = line.first() else {
        return Vec::new();
    };
    let mut result = Vec::new();
    let mut buffer: Vec<u8> = Vec::new();
    let mut current = first;
    for &(byte, style) in line {
        if style != current {
            result.push(Run {
                text: String::from_utf8_lossy(&buffer).into_owned(),
                style: current,
            });
            buffer.clear();
            current = style;
        }
        buffer.push(byte);
    }
    result.push(Run {
        text: String::from_utf8_lossy(&buffer).into_owned(),
        style: current,
    });
    result
}

/// The index PAST the escape sequence beginning at `start` (where `bytes[start]` is `ESC`).
///
/// An UNTERMINATED sequence at end-of-buffer consumes to the end: there is no next chunk here, and
/// rendering half a sequence as text is worse than dropping it.
fn escape_end(bytes: &[u8], start: usize) -> usize {
    let n = bytes.len();
    let Some(&intro) = bytes.get(start + 1) else {
        return n; // a trailing bare ESC — consume it
    };
    match intro {
        b'[' => {
            parse_csi(bytes, start).map_or_else(
                || {
                    // A `CSI` the strict parser refuses — a stray byte in the parameter run. Scan on to
                    // the first final byte anyway: the alternative is emitting the sequence as text.
                    // Well-formed input never reaches here, because every parameter and intermediate
                    // byte is below `0x40`, so both readings stop at the same byte.
                    bytes
                        .iter()
                        .enumerate()
                        .skip(start + 2)
                        .find(|&(_, &b)| (0x40..=0x7E).contains(&b))
                        .map_or(n, |(j, _)| j + 1)
                },
                |csi| csi.end,
            )
        },
        // OSC, DCS, SOS, PM, APC, and screen/tmux's `ESC k` title. `BEL` ends every one of them
        // here: this is a captured stream, not a replay, so a producer that terminates a `DCS` the
        // lenient way is read the way it meant rather than swallowing the rest of the output.
        b']' | b'P' | b'X' | b'^' | b'_' | b'k' => {
            string_sequence_end(bytes, start + 2, Terminators::osc()).map_or(n, |seq| seq.seq_end)
        },
        // A short escape (charset select `ESC ( X`, keypad `ESC =`, …). Most are two bytes; the
        // charset-designator forms are three.
        b'(' | b')' | b'*' | b'+' if start + 2 < n => start + 3,
        _ => start + 2,
    }
}

/// True iff `bytes[start..end]` is an ERASE-TO-END-OF-LINE `CSI` (`ESC [ K` / `ESC [ 0 K`) — the
/// form a progress bar uses to clear stale trailing characters after a shorter frame.
fn is_erase_to_line_end(bytes: &[u8], start: usize, end: usize) -> bool {
    let Some(params) = csi_params(bytes, start, end, b'K') else {
        return false;
    };
    let mut value = 0_u32;
    let mut saw_digit = false;
    for &byte in params {
        if !byte.is_ascii_digit() {
            return false;
        }
        if value < PARAM_CAP {
            value = value * 10 + u32::from(byte - b'0');
        }
        saw_digit = true;
    }
    !saw_digit || value == 0
}

/// The parameter bytes of the `CSI` spanning `start..end` when its final byte is `final_byte` and
/// it is not a PRIVATE-mode sequence (`ESC [ ? … `), which this pass never interprets.
fn csi_params(bytes: &[u8], start: usize, end: usize, final_byte: u8) -> Option<&[u8]> {
    if end.checked_sub(start)? < 3 {
        return None;
    }
    if bytes.get(start + 1) != Some(&b'[') || bytes.get(end - 1) != Some(&final_byte) {
        return None;
    }
    let params = bytes.get(start + 2..end - 1)?;
    if params.first().is_some_and(|b| (0x3C..=0x3F).contains(b)) {
        return None;
    }
    Some(params)
}

/// Applies the escape sequence `bytes[start..end]` to `style` when it is an SGR (a `CSI` ending in
/// `m`); leaves it untouched otherwise.
fn apply_sgr(bytes: &[u8], start: usize, end: usize, style: &mut Style) {
    let Some(params) = csi_params(bytes, start, end, b'm') else {
        return;
    };
    // `ESC [ m` == `ESC [ 0 m` — a full reset.
    if params.is_empty() {
        *style = Style::default();
        return;
    }
    let mut fields: Vec<u32> = Vec::new();
    let mut value = 0_u32;
    let mut saw_digit = false;
    for &byte in params {
        if byte == b';' || byte == b':' {
            // Both separate parameters in the wild — a `38:2:…` sub-parameter form reads the same
            // way here as the `;` one, which is what every producer means by it.
            fields.push(if saw_digit { value } else { 0 });
            value = 0;
            saw_digit = false;
        } else if byte.is_ascii_digit() {
            if value < PARAM_CAP {
                value = value * 10 + u32::from(byte - b'0');
            }
            saw_digit = true;
        } else {
            return; // an intermediate byte — not a plain SGR this pass interprets
        }
    }
    fields.push(if saw_digit { value } else { 0 });
    apply_fields(&fields, style);
}

/// Folds decoded SGR parameters into `style`.
fn apply_fields(fields: &[u32], style: &mut Style) {
    let mut index = 0;
    while let Some(&field) = fields.get(index) {
        match field {
            0 => *style = Style::default(),
            1 => style.bold = true,
            2 => style.dim = true,
            3 => style.italic = true,
            4 => style.underline = true,
            7 => style.inverse = true,
            22 => {
                style.bold = false;
                style.dim = false;
            },
            23 => style.italic = false,
            24 => style.underline = false,
            27 => style.inverse = false,
            30..=37 => style.foreground = Some(Color::Indexed(clamp_byte(field - 30))),
            39 => style.foreground = None,
            40..=47 => style.background = Some(Color::Indexed(clamp_byte(field - 40))),
            49 => style.background = None,
            90..=97 => style.foreground = Some(Color::Indexed(clamp_byte(field - 90 + 8))),
            100..=107 => style.background = Some(Color::Indexed(clamp_byte(field - 100 + 8))),
            38 | 48 => {
                let (colour, consumed) = extended_colour(fields, index + 1);
                if let Some(colour) = colour {
                    if field == 38 {
                        style.foreground = Some(colour);
                    } else {
                        style.background = Some(colour);
                    }
                }
                index += consumed;
            },
            _ => {}, // an SGR this preview does not model (blink, framed, overline…)
        }
        index += 1;
    }
}

/// Decodes the argument of a `38`/`48` at `from`: `5 ; N` (palette) or `2 ; r ; g ; b` (direct),
/// returning the colour and how many parameters it consumed. A truncated or unknown form yields
/// `None` and consumes what it saw, so the scan always advances.
fn extended_colour(fields: &[u32], from: usize) -> (Option<Color>, usize) {
    match fields.get(from) {
        None => (None, 0),
        Some(5) => {
            match fields.get(from + 1) {
                Some(&slot) => (Some(Color::Indexed(clamp_byte(slot))), 2),
                None => (None, 1),
            }
        },
        Some(2) => {
            match (fields.get(from + 1), fields.get(from + 2), fields.get(from + 3)) {
                (Some(&r), Some(&g), Some(&b)) => {
                    (Some(Color::Rgb(clamp_byte(r), clamp_byte(g), clamp_byte(b))), 4)
                },
                _ => (None, fields.len() - from),
            }
        },
        Some(_) => (None, 1),
    }
}

/// Clamps a decoded parameter into a byte — a malformed `38;2;999;…` must not wrap.
fn clamp_byte(value: u32) -> u8 {
    u8::try_from(value).unwrap_or(u8::MAX)
}

#[cfg(test)]
#[expect(
    clippy::indexing_slicing,
    reason = "every fixture's run count is asserted before its runs are read"
)]
mod tests {
    use super::{Color, Run, Style, lines};

    fn plain_text(input: &str) -> String {
        lines(input.as_bytes())
            .iter()
            .map(|line| {
                line.iter()
                    .map(|run| run.text.as_str())
                    .collect::<Vec<_>>()
                    .concat()
            })
            .collect::<Vec<_>>()
            .join("\n")
    }

    fn only_line(input: &str) -> Vec<Run> {
        let mut all = lines(input.as_bytes());
        assert_eq!(all.len(), 1, "expected one line from {input:?}");
        all.remove(0)
    }

    #[test]
    fn an_empty_input_is_one_empty_line() {
        assert_eq!(lines(b""), vec![Vec::new()]);
    }

    #[test]
    fn a_colour_run_keeps_its_text_and_its_style() {
        let runs = only_line("\u{1B}[31mred\u{1B}[0m plain");
        assert_eq!(runs.len(), 2);
        assert_eq!(runs[0].text, "red");
        assert_eq!(runs[0].style.foreground, Some(Color::Indexed(1)));
        assert_eq!(runs[1].text, " plain");
        assert_eq!(runs[1].style, Style::default());
    }

    #[test]
    fn the_extended_colour_forms_decode_and_a_malformed_one_clamps() {
        let runs = only_line("\u{1B}[38;5;201mx");
        assert_eq!(runs[0].style.foreground, Some(Color::Indexed(201)));
        let direct = only_line("\u{1B}[48;2;10;20;30my");
        assert_eq!(direct[0].style.background, Some(Color::Rgb(10, 20, 30)));
        let huge = only_line("\u{1B}[38;2;999;0;0mz");
        assert_eq!(huge[0].style.foreground, Some(Color::Rgb(255, 0, 0)));
        // Truncated: the scan advances and nothing is set.
        assert_eq!(only_line("\u{1B}[38;5mq")[0].style.foreground, None);
    }

    #[test]
    fn a_lone_cr_rewrites_the_line_so_a_progress_bar_collapses_to_its_last_frame() {
        assert_eq!(plain_text("10%\r55%\r100%"), "100%");
        assert_eq!(plain_text("longer\rab"), "abnger");
    }

    #[test]
    fn erase_to_end_of_line_truncates_at_the_cursor() {
        assert_eq!(plain_text("longer\rab\u{1B}[K"), "ab");
        assert_eq!(plain_text("longer\rab\u{1B}[0K"), "ab");
        // A private-mode CSI ending in K is not the erase this pass acts on.
        assert_eq!(plain_text("longer\rab\u{1B}[?1K"), "abnger");
        // `ESC [ 1 K` erases toward the START, which this pass does not model.
        assert_eq!(plain_text("longer\rab\u{1B}[1K"), "abnger");
    }

    #[test]
    fn crlf_is_a_newline_and_a_bare_lf_commits_the_line() {
        assert_eq!(plain_text("a\r\nb"), "a\nb");
        assert_eq!(plain_text("a\nb"), "a\nb");
        assert_eq!(lines(b"a\nb").len(), 2);
    }

    #[test]
    fn a_trailing_prompt_eol_mark_is_chopped_and_an_ordinary_percent_is_not() {
        assert_eq!(plain_text("done\n\u{1B}[7m%\u{1B}[0m   "), "done\n");
        assert_eq!(plain_text("100% done"), "100% done");
        // Reverse video, but text follows: not the mark.
        assert_eq!(plain_text("\u{1B}[7m% ok"), "% ok");
    }

    #[test]
    fn c0_controls_and_del_are_dropped_but_tab_survives() {
        assert_eq!(plain_text("a\u{0}b\u{7}c\u{7F}d"), "abcd");
        assert_eq!(plain_text("a\tb"), "a\tb");
    }

    #[test]
    fn an_unterminated_sequence_at_the_end_is_consumed_rather_than_shown() {
        assert_eq!(plain_text("ok\u{1B}[31"), "ok");
        assert_eq!(plain_text("ok\u{1B}]0;title"), "ok");
        assert_eq!(plain_text("ok\u{1B}"), "ok");
    }

    #[test]
    fn a_string_sequence_body_is_skipped_whole() {
        assert_eq!(plain_text("a\u{1B}]0;t\u{7}b"), "ab");
        assert_eq!(plain_text("a\u{1B}]0;t\u{1B}\\b"), "ab");
        assert_eq!(plain_text("a\u{1B}Pq;stuff\u{1B}\\b"), "ab");
        assert_eq!(plain_text("a\u{1B}kname\u{1B}\\b"), "ab");
    }

    #[test]
    fn a_charset_designator_consumes_three_bytes_and_a_short_escape_two() {
        assert_eq!(plain_text("a\u{1B}(Bb"), "ab");
        assert_eq!(plain_text("a\u{1B}=b"), "ab");
    }

    #[test]
    fn the_attribute_resets_undo_exactly_what_they_name() {
        let runs = only_line("\u{1B}[1;3;4;7mall\u{1B}[22;23;24;27mnone");
        assert!(runs[0].style.bold && runs[0].style.italic);
        assert!(runs[0].style.underline && runs[0].style.inverse);
        assert_eq!(runs[1].style, Style::default());
    }

    #[test]
    fn a_degenerate_parameter_run_neither_wraps_nor_runs_away() {
        // Capped accumulation: the value is nonsense, the pass still terminates and stays sane.
        assert_eq!(plain_text("\u{1B}[99999999999999mx"), "x");
    }

    #[test]
    fn joining_the_lines_reproduces_the_plain_text_byte_for_byte() {
        let input = "one\u{1B}[32mtwo\u{1B}[0m\nthree\r\nfour\rXX";
        assert_eq!(lines(input.as_bytes()).len(), 3);
        assert_eq!(plain_text(input), "onetwo\nthree\nXXur");
    }
}
