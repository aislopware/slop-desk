//! Classifies one client→PTY input chunk: does it carry a USER KEYSTROKE, or only the terminal
//! emulator's own automatic traffic — and, more narrowly, does it carry a CANCEL key?
//!
//! The same `input` frames that carry keystrokes also carry replies the client terminal emits with
//! no human behind them — focus in/out (`CSI I` / `CSI O`, sent by merely VISITING a pane), cursor
//! position / device-attribute / window-geometry reports answering the program's queries, and mouse
//! events (motion included: the renderer forwards every pointer position to a mouse-reporting TUI,
//! so merely HOVERING a pane floods this path). The unblock signal must fire on none of those: a
//! visit, a scroll or a hover is READING a blocked pane, not answering its dialog.
//!
//! Pure and total (validate-then-drop): any byte sequence is tolerated, and a sequence truncated at
//! the chunk boundary classifies as NOT a keystroke — conservative, never demote on an unknowable
//! fragment. The one deliberate exception: a chunk ENDING in a bare `ESC` is the Esc key's legacy
//! encoding — the exact key that cancels a dialog — not a truncated report, because reports arrive
//! as complete writes.

/// True iff `bytes` contains at least one user keystroke.
#[must_use]
pub fn contains_user_keystroke(bytes: &[u8]) -> bool {
    scan(bytes, false)
}

/// True iff `bytes` contains a CANCEL key.
///
/// That is `Esc` in ANY of its encodings — the bare legacy `0x1B`, `ESC ESC`, and kitty's
/// `CSI 27 u`, which is what Claude Code's own keyboard mode actually sends — or `Ctrl-C` (`0x03`,
/// still legacy under kitty's disambiguate flag).
///
/// This, not [`contains_user_keystroke`], is what may demote a standing block. The unblock exists
/// for exactly ONE case — an Esc-cancelled dialog, which fires no hook and would otherwise leave
/// the pane blocked forever — and every OTHER way of resolving a dialog announces itself: answering
/// a permission prompt fires `PreToolUse`, answering an `AskUserQuestion` fires its `PostToolUse`.
/// Demoting on ANY keystroke therefore bought nothing and cost a false edge: arrowing between an
/// `AskUserQuestion`'s options, or retyping an answer, walked the pane blocked → idle, the
/// still-visible dialog walked it straight back to blocked, and the second entry rang the
/// awaiting-input cue again — once per keypress (user-reported 2026-08-10).
#[must_use]
pub fn contains_cancel_keystroke(bytes: &[u8]) -> bool {
    scan(bytes, true)
}

/// The ONE scanner behind both predicates: walks `bytes`, consuming the emulator's automatic
/// replies, and answers whether it saw a key (`cancel_only == false`) or specifically a cancel key.
/// Sharing the walk is what keeps the two answers from drifting — a report shape taught to one is
/// known to both.
fn scan(bytes: &[u8], cancel_only: bool) -> bool {
    let end = bytes.len();
    let mut index = 0;
    while index < end {
        let Some(&byte) = bytes.get(index) else {
            return false;
        };
        if byte != ESC {
            // Any byte outside an escape sequence — printable, CR, control chords — is a key. For
            // the cancel question only `Ctrl-C` qualifies; everything else keeps scanning, because
            // a later byte in the same chunk may still be the Esc we are looking for.
            if !cancel_only {
                return true;
            }
            if byte == CTRL_C {
                return true;
            }
            index += 1;
            continue;
        }
        let introducer_index = index + 1;
        // A chunk ending in a bare ESC is the Esc KEY (legacy encoding), not a fragment.
        let Some(&introducer) = bytes.get(introducer_index) else {
            return true;
        };
        match introducer {
            b'[' => {
                match classify_csi(bytes, introducer_index + 1, end) {
                    // Most CSI keys (arrows, tilde keys, shift-tab) are not cancels, so the cancel scan
                    // STEPS OVER them and keeps looking — returning false here would miss the Esc in a
                    // chunk that batched an arrow and an Esc into one write. The exception is kitty's
                    // `CSI 27 u`, which IS the Esc key (see `classify_csi`).
                    CsiClass::Keystroke { resume_at, is_cancel } => {
                        if !cancel_only || is_cancel {
                            return true;
                        }
                        index = resume_at;
                    },
                    CsiClass::Report { resume_at } => index = resume_at,
                    CsiClass::Truncated => return false,
                }
            },
            // OSC / DCS / SOS / PM / APC — string replies (colour queries, XTGETTCAP…). Consume
            // through the BEL or ST terminator; truncated is a conservative no.
            b']' | b'P' | b'X' | b'^' | b'_' => {
                let Some(next) = index_past_string_terminator(bytes, introducer_index + 1, end) else {
                    return false;
                };
                index = next;
            },
            // ESC ESC — the Esc key pressed twice (or once, with the emulator's meta-escape). The
            // FIRST one is a genuine bare Esc: a cancel.
            ESC => return true,
            // ESC + anything else: SS3 function keys (`ESC O P`), alt-chords (`ESC f`) — all user
            // keys, none of them a cancel.
            _ => {
                if !cancel_only {
                    return true;
                }
                index = introducer_index + 1;
            },
        }
    }
    false
}

const ESC: u8 = 0x1B;
const CTRL_C: u8 = 0x03;
const BEL: u8 = 0x07;

/// What one CSI sequence turned out to be.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum CsiClass {
    /// A real key. Carries the resume index anyway, so the CANCEL scan can step over it and keep
    /// looking (a chunk may batch an arrow key and an Esc into one write). `is_cancel` is true for
    /// the ONE CSI key that cancels a dialog — kitty's `CSI 27 u` Esc.
    Keystroke { resume_at: usize, is_cancel: bool },
    /// The emulator answering a query, or reporting focus or the mouse. Not a key.
    Report { resume_at: usize },
    /// The sequence runs off the end of this chunk, or is malformed. Conservative no.
    Truncated,
}

/// Classifies one CSI sequence starting at its first parameter byte.
///
/// Reports are recognised three ways: a private-marker prefix (`?` = DA1/DECRPM/DECXCPR/kitty-flags
/// replies, `>` = DA2, `<` = SGR mouse), a report-only final byte (`R` CPR, `n` DSR, `c` DA, `y`
/// DECRPM, `I`/`O` focus, `t` XTWINOPS geometry, `M` mouse), or the bare X10 mouse form, whose
/// three POSITION bytes follow the final `M` and must be consumed with it. Everything else —
/// arrows, tilde keys, `CSI u` kitty keys, shift-tab `Z` — is a keystroke.
///
/// ⚠️ `M` is why hovering a blocked pane used to ring the awaiting-input cue. libghostty encodes
/// mouse reports in whatever scheme the program asked for, and the X10 default (`CSI M Cb Cx Cy`)
/// has no private marker and a final byte this switch did not know — so every pointer MOTION event
/// over a mouse-reporting TUI classified as a keystroke, demoted the block, and let the
/// still-visible dialog re-raise it (user-reported 2026-08-10). No keyboard encoding produces
/// `CSI …M` / `CSI …t`, so both finals are unconditionally reports.
fn classify_csi(bytes: &[u8], parameter_start: usize, end: usize) -> CsiClass {
    let has_private_marker = bytes
        .get(parameter_start)
        .is_some_and(|c| (0x3C..=0x3F).contains(c));
    let mut index = parameter_start;
    while index < end {
        let Some(&byte) = bytes.get(index) else {
            return CsiClass::Truncated;
        };
        if (0x40..=0x7E).contains(&byte) {
            let next = index + 1;
            if has_private_marker {
                return CsiClass::Report { resume_at: next };
            }
            return match byte {
                // Bare `CSI M` (no parameters consumed) is X10/UTF-8 mouse: three position bytes
                // ride BEHIND the final byte and are not part of any grammar this scanner would
                // otherwise skip — leaving them would re-enter the loop on a raw `Cb` byte and read
                // it as a keystroke. A parameterised `CSI …M` is the urxvt (1015) mouse form, which
                // carries its position in the parameters.
                b'M' => {
                    if index != parameter_start {
                        return CsiClass::Report { resume_at: next };
                    }
                    let past = next + 3;
                    if past > end {
                        return CsiClass::Truncated;
                    }
                    CsiClass::Report { resume_at: past }
                },
                b'R' | b'c' | b'I' | b'O' | b'n' | b't' | b'y' => CsiClass::Report { resume_at: next },
                // kitty keyboard protocol (`CSI <keycode>[;<mods>] u`), which Claude Code turns on.
                // Under it the Esc KEY stops arriving as a bare `0x1B` and becomes `CSI 27 u` — so
                // without this branch the Esc-cancel unblock, the whole reason the cancel predicate
                // exists, would never fire inside a claude pane.
                b'u' => {
                    CsiClass::Keystroke {
                        resume_at: next,
                        is_cancel: first_parameter(bytes, parameter_start, index) == Some(27),
                    }
                },
                _ => {
                    CsiClass::Keystroke {
                        resume_at: next,
                        is_cancel: false,
                    }
                },
            };
        }
        // Parameter / intermediate bytes; anything outside 0x20–0x3F is a malformed sequence —
        // treat it like a truncation (conservative no).
        if !(0x20..=0x3F).contains(&byte) {
            return CsiClass::Truncated;
        }
        index += 1;
    }
    CsiClass::Truncated
}

/// The leading DECIMAL parameter of a CSI sequence — the bytes between `from` and the first `;` or
/// the final byte at `to` — or `None` when it is absent, non-numeric, or absurdly long.
///
/// Used only to read a kitty key code; bounded by construction, so no overflow path exists.
fn first_parameter(bytes: &[u8], from: usize, to: usize) -> Option<u32> {
    let mut value: u32 = 0;
    let mut digits: u32 = 0;
    let mut index = from;
    while index < to {
        let &byte = bytes.get(index)?;
        if byte == b';' {
            break;
        }
        if !byte.is_ascii_digit() || digits >= 6 {
            return None;
        }
        value = value * 10 + u32::from(byte - b'0');
        digits += 1;
        index += 1;
    }
    (digits > 0).then_some(value)
}

/// The index just past a BEL- or ST-terminated string sequence, or `None` when the terminator is
/// missing from this chunk.
fn index_past_string_terminator(bytes: &[u8], from: usize, end: usize) -> Option<usize> {
    let mut index = from;
    while index < end {
        let &byte = bytes.get(index)?;
        if byte == BEL {
            return Some(index + 1);
        }
        if byte == ESC {
            let next = index + 1;
            if bytes.get(next) == Some(&b'\\') {
                return Some(next + 1);
            }
        }
        index += 1;
    }
    None
}

#[cfg(test)]
mod tests {
    use super::{contains_cancel_keystroke, contains_user_keystroke};

    #[test]
    fn a_printable_byte_is_a_key_and_is_not_a_cancel() {
        assert!(contains_user_keystroke(b"a"));
        assert!(!contains_cancel_keystroke(b"a"));
        assert!(contains_user_keystroke(b"\r"));
        assert!(!contains_cancel_keystroke(b"hello world"));
    }

    #[test]
    fn an_empty_chunk_is_neither() {
        assert!(!contains_user_keystroke(b""));
        assert!(!contains_cancel_keystroke(b""));
    }

    #[test]
    fn every_encoding_of_the_escape_key_cancels() {
        assert!(contains_cancel_keystroke(b"\x1B")); // bare legacy Esc
        assert!(contains_cancel_keystroke(b"\x1B\x1B")); // Esc Esc / meta-escape
        assert!(contains_cancel_keystroke(b"\x1B[27u")); // kitty, no modifiers
        assert!(contains_cancel_keystroke(b"\x1B[27;1u")); // kitty, with modifiers
        assert!(contains_cancel_keystroke(b"\x03")); // Ctrl-C
    }

    #[test]
    fn another_kitty_key_is_a_keystroke_but_never_a_cancel() {
        assert!(contains_user_keystroke(b"\x1B[97u")); // kitty `a`
        assert!(!contains_cancel_keystroke(b"\x1B[97u"));
        assert!(!contains_cancel_keystroke(b"\x1B[u")); // no parameter at all
    }

    #[test]
    fn merely_visiting_a_pane_is_not_a_keystroke() {
        assert!(!contains_user_keystroke(b"\x1B[I")); // focus in
        assert!(!contains_user_keystroke(b"\x1B[O")); // focus out
        assert!(!contains_cancel_keystroke(b"\x1B[I\x1B[O"));
    }

    #[test]
    fn the_emulators_answers_to_the_programs_own_queries_are_not_keystrokes() {
        assert!(!contains_user_keystroke(b"\x1B[12;40R")); // CPR
        assert!(!contains_user_keystroke(b"\x1B[0n")); // DSR
        assert!(!contains_user_keystroke(b"\x1B[?62;1;6c")); // DA1 with private marker
        assert!(!contains_user_keystroke(b"\x1B[>0;10;1c")); // DA2
        assert!(!contains_user_keystroke(b"\x1B[?2026;2$y")); // DECRPM
        assert!(!contains_user_keystroke(b"\x1B[4;600;800t")); // XTWINOPS geometry
        assert!(!contains_user_keystroke(b"\x1B]11;rgb:1c1c/1c1c/1c1c\x07")); // OSC + BEL
        assert!(!contains_user_keystroke(b"\x1B]10;rgb:ffff/ffff/ffff\x1B\\")); // OSC + ST
        assert!(!contains_user_keystroke(b"\x1BP1$r0m\x1B\\")); // DCS
    }

    #[test]
    fn hovering_a_mouse_reporting_pane_never_reads_as_a_key() {
        // X10: three position bytes ride behind the final `M` and must be consumed with it.
        assert!(!contains_user_keystroke(b"\x1B[M !!"));
        assert!(!contains_cancel_keystroke(b"\x1B[M !!"));
        // A batch of motion events — the shape that used to demote a block on every hover.
        assert!(!contains_user_keystroke(b"\x1B[M !!\x1B[M \"\"\x1B[M ##"));
        // SGR (1006) and urxvt (1015) forms.
        assert!(!contains_user_keystroke(b"\x1B[<35;10;20M"));
        assert!(!contains_user_keystroke(b"\x1B[32;10;20M"));
    }

    #[test]
    fn a_position_byte_that_looks_like_a_key_is_still_consumed_as_position() {
        // `Cb Cx Cy` = 0x20 0x61 0x62 — the `a` in the middle must never surface as a keystroke.
        assert!(!contains_user_keystroke(b"\x1B[M ab"));
    }

    #[test]
    fn a_truncated_report_is_conservatively_not_a_key() {
        assert!(!contains_user_keystroke(b"\x1B[12;")); // CSI cut mid-parameter
        assert!(!contains_user_keystroke(b"\x1B[M ")); // X10 cut mid-position
        assert!(!contains_user_keystroke(b"\x1B]11;rgb:1c1c")); // OSC with no terminator
        assert!(!contains_cancel_keystroke(b"\x1B[12;"));
    }

    #[test]
    fn the_cancel_scan_steps_over_a_report_or_a_plain_key_to_find_the_esc_behind_it() {
        assert!(contains_cancel_keystroke(b"\x1B[A\x1B")); // arrow, then Esc
        assert!(contains_cancel_keystroke(b"\x1B[I\x1B[27u")); // focus report, then kitty Esc
        assert!(contains_cancel_keystroke(b"abc\x1B")); // typing, then Esc
        assert!(contains_cancel_keystroke(b"\x1B[M !!\x1B")); // mouse motion, then Esc
        assert!(contains_cancel_keystroke(b"\x1BOP\x1B")); // SS3 F1, then Esc
    }

    #[test]
    fn a_function_or_alt_key_is_a_keystroke_and_not_a_cancel() {
        assert!(contains_user_keystroke(b"\x1BOP")); // SS3 F1
        assert!(!contains_cancel_keystroke(b"\x1BOP"));
        assert!(contains_user_keystroke(b"\x1Bf")); // alt-f
        assert!(!contains_cancel_keystroke(b"\x1Bf"));
        assert!(contains_user_keystroke(b"\x1B[Z")); // shift-tab
        assert!(!contains_cancel_keystroke(b"\x1B[Z"));
        assert!(contains_user_keystroke(b"\x1B[3~")); // delete
    }

    #[test]
    fn a_malformed_sequence_is_tolerated_rather_than_trusted() {
        assert!(!contains_user_keystroke(b"\x1B[\x00A"));
        assert!(!contains_cancel_keystroke(b"\x1B[\x01"));
    }

    #[test]
    fn no_byte_sequence_makes_the_scanner_run_away() {
        // Every 3-byte chunk over a hostile alphabet must terminate and answer something.
        let alphabet = [0x00_u8, 0x03, 0x1B, b'[', b'M', b';', b'9', 0x7F, 0xFF];
        for a in alphabet {
            for b in alphabet {
                for c in alphabet {
                    let chunk = [a, b, c];
                    let _keystroke = contains_user_keystroke(&chunk);
                    let _cancel = contains_cancel_keystroke(&chunk);
                }
            }
        }
    }
}
