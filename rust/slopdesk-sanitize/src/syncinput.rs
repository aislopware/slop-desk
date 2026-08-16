//! Sync-input hygiene: only what a KEYBOARD produced is mirrored into a sibling pane.
//!
//! The other direction from [`crate::query`]. That pass reads host→client bytes and drops the
//! QUERIES a replay would make a fresh terminal answer again; this reads client→host bytes and
//! drops the ANSWERS, because the sync-input fan-out mirrors one pane's input into its siblings.
//!
//! ## Why
//! The tap rides the pane's single OUT funnel, which carries more than keystrokes: the terminal
//! emulator answers its shell's queries (CPR `ESC[row;colR`, DA `ESC[?…c`, XTWINOPS `ESC[8;…t`,
//! DECRPM `ESC[?…$y`, kitty-flags `ESC[?…u`, OSC colour/clipboard replies, DCS `XTGETTCAP`
//! replies) and streams mouse reports (`ESC[<…M/m`, `ESC[M…`) and focus events (`ESC[I`/`ESC[O`)
//! through the same path. Those bytes answer questions only the SOURCE pane's shell asked.
//! Mirrored into a sibling that never asked, they type garbage onto its command line — and the
//! next mirrored `↩` EXECUTES it. Observed in the field: a scroll burst plus a window report ran
//! as a command in the sibling.
//!
//! ## What survives
//! Everything a keyboard or a paste actually produces: plain bytes/UTF-8, control bytes,
//! `ESC`-prefixed keys (SS3 `ESC O …`, CSI arrows/nav/`~`-keys, kitty `CSI code;mods u` in its
//! non-private form), and bracketed-paste wrappers plus body — "type once, run everywhere" covers
//! paste.
//!
//! Known accepted gap: a MODIFIED F3 (`ESC[1;mR`) is byte-identical to a cursor-position report
//! and is dropped from the MIRROR. The source pane still receives it, and plain F3 (`ESC O R`)
//! rides SS3, so it is unaffected.

use crate::vtscan::{Csi, ESC, Terminators, parse_csi, string_introducer, string_sequence_end};

/// Returns `bytes` with terminal-reply and mouse/focus-report sequences removed.
///
/// A TRUNCATED trailing sequence passes through verbatim. Input arrives one whole key or reply
/// event per chunk, so a split sequence is not a real shape, and passthrough is the least
/// surprising fallback — the same convention every replay pass in this crate keeps.
#[must_use]
pub fn keyboard_only(bytes: &[u8]) -> Vec<u8> {
    let n = bytes.len();
    let mut out = Vec::with_capacity(n);
    let mut i = 0;

    while i < n {
        if bytes[i] != ESC || i + 1 >= n {
            out.push(bytes[i]);
            i += 1;
            continue;
        }
        match bytes[i + 1] {
            b'[' => {
                let Some(csi) = parse_csi(bytes, i) else {
                    out.extend_from_slice(&bytes[i..]); // truncated — passthrough
                    break;
                };
                if is_reply_or_report(&csi) {
                    i = csi.end;
                    // X10 mouse: `ESC [ M` is followed by three RAW payload bytes (button, x, y)
                    // that are not CSI params — their coordinates exceed 0x3F — so the scanner
                    // stops before them and they must be consumed with the report.
                    if is_x10_mouse(&csi) {
                        i = (i + 3).min(n);
                    }
                } else {
                    out.extend_from_slice(&bytes[i..csi.end]);
                    i = csi.end;
                }
            },
            introducer if string_introducer(introducer).is_some() => {
                // OSC / DCS / SOS / PM / APC in the INPUT direction are always replies — colour
                // queries, OSC 52 clipboard, XTGETTCAP. Never keystrokes, so drop the whole body.
                let bel_terminates = string_introducer(introducer) == Some(true);
                let policy = Terminators::replay(bel_terminates);
                let Some(sequence) = string_sequence_end(bytes, i + 2, policy) else {
                    out.extend_from_slice(&bytes[i..]); // truncated — passthrough
                    break;
                };
                i = sequence.seq_end;
            },
            _ => {
                // Two-byte escapes — SS3 keys `ESC O …`, meta-prefixed chars — are keyboard. Keep.
                out.push(bytes[i]);
                out.push(bytes[i + 1]);
                i += 2;
            },
        }
    }
    out
}

/// The bare-`M` X10 mouse report, whose three payload bytes trail outside the CSI.
const fn is_x10_mouse(csi: &Csi<'_>) -> bool {
    csi.final_byte == b'M' && csi.params.is_empty() && csi.intermediates.is_empty()
}

/// Whether a CSI arriving on the INPUT path is a terminal reply or a mouse/focus report — never
/// something a keyboard produces.
fn is_reply_or_report(csi: &Csi<'_>) -> bool {
    // `<`, `=`, `>`, `?` — the ECMA-48 private markers.
    let is_private = csi
        .params
        .first()
        .is_some_and(|byte| (0x3C..=0x3F).contains(byte));
    match csi.final_byte {
        b'M' | b'm' => {
            // SGR mouse (`ESC[<…M/m`) or X10 mouse (`ESC[M` + three payload bytes). A plain `m`
            // without the `<` marker is not an input-direction shape either, but keep the check
            // tight: only the `<`-marked SGR form and the bare-`M` X10 form are reports.
            csi.params.first() == Some(&b'<') || is_x10_mouse(csi)
        },
        // CPR `ESC[row;colR`. Accepted gap: modified F3 shares the shape (see the module doc).
        b'R' => !csi.params.is_empty(),
        // DSR status (`0n`/`3n`), DA1/DA2 (`?…c`/`>…c`), XTWINOPS (`8;…t`), DECRPM (`?…$y`).
        // No keyboard encoding uses these finals.
        b'n' | b'c' | b't' | b'y' => true,
        // Focus in/out — exactly `ESC[I` / `ESC[O`, no params.
        b'I' | b'O' => csi.params.is_empty() && csi.intermediates.is_empty(),
        // The kitty keyboard-flags REPLY is the private `ESC[?flags u`; the non-private
        // `CSI code;mods u` is a KEYSTROKE and must survive.
        b'u' => is_private,
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::keyboard_only;

    /// The filter over a `str`, which every case below is written in.
    fn filter(input: &str) -> String {
        String::from_utf8_lossy(&keyboard_only(input.as_bytes())).into_owned()
    }

    /// Plain text, control bytes, SS3 keys, CSI arrows/nav/`~` keys, and kitty `CSI u` keystrokes
    /// all pass through byte-exact — the identity path for real typing.
    #[test]
    fn keyboard_bytes_survive() {
        for kept in [
            "ls -la\r",
            "\u{03}",                           // Ctrl-C
            "\u{1B}[A\u{1B}[B\u{1B}[C\u{1B}[D", // arrows
            "\u{1B}[1;5C",                      // ctrl-arrow
            "\u{1B}[3~\u{1B}[5~\u{1B}[6~",      // delete / page keys
            "\u{1B}OP\u{1B}OQ\u{1B}OR",         // SS3 F1–F3 (plain F3 is SS3, NOT the CPR shape)
            "\u{1B}[97;5u",                     // kitty-encoded Ctrl-A (non-private `u`)
            "\u{1B}a",                          // meta-prefixed char
        ] {
            assert_eq!(filter(kept), kept, "{kept:?} must survive the mirror");
        }
    }

    /// Bracketed paste — wrappers and body — survives: "type once, run everywhere" covers paste.
    #[test]
    fn bracketed_paste_survives() {
        let paste = "\u{1B}[200~echo hello\u{1B}[201~";
        assert_eq!(filter(paste), paste);
    }

    /// SGR mouse reports (`ESC[<…M/m`) — the field-observed scroll burst — are stripped.
    #[test]
    fn strips_sgr_mouse_reports() {
        let burst = "\u{1B}[<65;31;18M\u{1B}[<65;31;18m\u{1B}[<0;5;7M";
        assert_eq!(filter(&format!("a{burst}b")), "ab");
    }

    /// X10 mouse (`ESC[M` + three raw payload bytes) is stripped INCLUDING its payload, which is
    /// not CSI params and would otherwise leak through as printable garbage.
    #[test]
    fn strips_x10_mouse_with_payload() {
        let x10 = "\u{1B}[M !\""; // button 0x20, x 0x21, y 0x22
        assert_eq!(filter(&format!("a{x10}b")), "ab");
    }

    /// Terminal query replies — CPR, DSR, DA1/DA2, XTWINOPS, DECRPM, kitty-flags — are stripped.
    #[test]
    fn strips_query_replies() {
        for reply in [
            "\u{1B}[24;80R",       // CPR
            "\u{1B}[0n",           // DSR ok
            "\u{1B}[?1;2c",        // DA1
            "\u{1B}[>0;276;0c",    // DA2
            "\u{1B}[8;33;96t",     // XTWINOPS text-area size (the field-observed shape)
            "\u{1B}[4;1452;1632t", // XTWINOPS pixel size
            "\u{1B}[?2026;1$y",    // DECRPM
            "\u{1B}[?1u",          // kitty keyboard-flags reply (private `u`)
        ] {
            assert_eq!(filter(&format!("x{reply}y")), "xy", "{reply:?} must be stripped");
        }
    }

    /// Focus in/out events (`ESC[I` / `ESC[O`, exactly — no params) are stripped.
    #[test]
    fn strips_focus_events() {
        assert_eq!(filter("a\u{1B}[Ib\u{1B}[Oc"), "abc");
    }

    /// OSC and DCS reply bodies — colour queries, OSC 52 clipboard, XTGETTCAP — are stripped whole.
    #[test]
    fn strips_string_replies() {
        let osc = "\u{1B}]11;rgb:1e1e/1e1e/2e2e\u{07}";
        let osc_st = "\u{1B}]52;c;aGVsbG8=\u{1B}\\";
        let dcs = "\u{1B}P1+r544e\u{1B}\\";
        assert_eq!(filter(&format!("a{osc}{osc_st}{dcs}b")), "ab");
    }

    /// The field-observed garbage — a window report plus an SGR scroll burst that EXECUTED as a
    /// command in the sibling — is stripped entirely; the surrounding keystrokes survive.
    #[test]
    fn strips_the_field_observed_garbage_burst() {
        let garbage = "\u{1B}[8;33;96t\u{1B}[4;1452;1632t\u{1B}[<65;31;18M\u{1B}[<65;31;18M\u{1B}[<66;31;18M";
        assert_eq!(filter(&format!("cc{garbage}\r")), "cc\r");
    }

    /// A truncated trailing sequence passes through verbatim.
    #[test]
    fn a_truncated_trailing_sequence_passes_through() {
        for cut in ["tail\u{1B}[38;5", "tail\u{1B}]11;rgb", "tail\u{1B}"] {
            assert_eq!(filter(cut), cut, "{cut:?} must pass through");
        }
    }

    /// Empty input is empty output.
    #[test]
    fn empty_is_empty() {
        assert!(keyboard_only(b"").is_empty());
    }

    /// Modified F3 (`ESC[1;2R`) shares the CPR shape and is dropped from the MIRROR — the
    /// documented accepted gap. The source pane still receives it, and plain F3 rides SS3.
    #[test]
    fn modified_f3_is_the_documented_accepted_gap() {
        assert_eq!(filter("a\u{1B}[1;2Rb"), "ab");
        assert_eq!(filter("a\u{1B}ORb"), "a\u{1B}ORb", "plain SS3 F3 survives");
    }

    /// A bare `ESC` inside an OSC body does not end it — the replay terminator policy, which the
    /// hand-rolled Swift original also kept. Without it one corrupt introducer changes where the
    /// reply is judged to stop.
    #[test]
    fn a_bare_escape_inside_an_osc_body_does_not_end_it() {
        assert_eq!(filter("a\u{1B}]11;rg\u{1B}b:00\u{07}z"), "az");
    }
}
