//! Replay hygiene: no re-answered queries, no stale colour state.
//!
//! Strips terminal QUERY sequences (and their echoed responses) from a scrollback REPLAY stream.
//!
//! ## Why
//! The scrollback ring and the disk journal record the raw host→client bytes — including the
//! queries a prompt or shell integration sent in the ORIGINAL session (DA1, XTVERSION, DECRQM,
//! the `OSC 11;?` background-colour probe…). Those queries were answered
//! live, once. Replaying them into the client terminal makes it answer AGAIN: the fresh responses
//! ride the wire back as PTY *input*, and with the foreground process not reading them (`sleep`, a
//! TUI…) they spill onto the command line as garbage (`^[]11;rgb:…^G^[[?62;22;52c^[P>|ghostty…^[\`)
//! — the reattach bug this pass fixes. Echoed RESPONSE forms already polluting a recorded
//! transcript are stripped too, so an already-poisoned journal renders clean on its next restore.
//!
//! Colour-state `OSC` (10/11/12/17/19, palette 4/104…, and clipboard 52) is stripped in BOTH query
//! and set form: stale colour/clipboard state must never ride a history replay into a fresh
//! terminal — the live shell re-asserts what it needs.
//!
//! ## Where it runs
//! In [`crate::sanitize`], after the distiller and before the prompt-mark pass. The un-acked live
//! tail is NEVER touched: a query in the tail was never delivered, so its issuer may legitimately
//! still await the answer (byte-exact resume). Stored bytes stay raw, so an improvement here
//! retroactively benefits existing journals.

use crate::vtscan::{Csi, ESC, Terminators, parse_csi, string_sequence_end};

/// Window-op report requests (`CSI Ps t` with these leading params) — the terminal replies with
/// geometry/title reports. 22/23 (title push/pop) and 8 (resize) are NOT reports, so they are kept.
const WINDOW_REPORT_OPS: &[&[u8]] = &[b"11", b"13", b"14", b"15", b"16", b"18", b"19", b"20", b"21"];

/// `OSC` numbers whose query AND set forms are stripped from replay.
///
/// Dynamic colours (10/11/12/17/19 plus resets 110/111/112), palette (4/5/104/105), clipboard (52),
/// and the kitty colour protocol (21 — a live `key=?` query/response `OSC` in ghostty, same shape
/// and PTY-input delivery mechanism as 10/11/12).
const STRIPPED_OSC_NUMBERS: &[&[u8]] = &[
    b"4", b"5", b"10", b"11", b"12", b"17", b"19", b"21", b"52", b"104", b"105", b"110", b"111", b"112",
];

/// Returns `bytes` with query/response/colour-state sequences removed.
///
/// Everything else — text, `SGR`, modes (`h`/`l`), `OSC` titles/marks/hyperlinks, `DECSCUSR` —
/// passes through verbatim. A truncated trailing sequence passes through unchanged (a ring head-cut
/// artifact is display noise, never a replayable query).
#[must_use]
pub fn strip(bytes: &[u8]) -> Vec<u8> {
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
                if !should_strip_csi(&csi) {
                    out.extend_from_slice(&bytes[i..csi.end]);
                }
                i = csi.end;
            },
            b']' => {
                let Some(seq) = string_sequence_end(bytes, i + 2, Terminators::osc()) else {
                    out.extend_from_slice(&bytes[i..]);
                    break;
                };
                if !should_strip_osc(&bytes[i + 2..seq.body_end]) {
                    out.extend_from_slice(&bytes[i..seq.seq_end]);
                }
                i = seq.seq_end;
            },
            b'P' => {
                let Some(seq) = string_sequence_end(bytes, i + 2, Terminators::st_only()) else {
                    out.extend_from_slice(&bytes[i..]);
                    break;
                };
                if !should_strip_dcs(&bytes[i + 2..seq.body_end]) {
                    out.extend_from_slice(&bytes[i..seq.seq_end]);
                }
                i = seq.seq_end;
            },
            // SOS/PM/APC — keep whole.
            b'X' | b'^' | b'_' => {
                let Some(seq) = string_sequence_end(bytes, i + 2, Terminators::st_only()) else {
                    out.extend_from_slice(&bytes[i..]);
                    break;
                };
                out.extend_from_slice(&bytes[i..seq.seq_end]);
                i = seq.seq_end;
            },
            // DECID — the ancient DA query.
            b'Z' => i += 2,
            // Any other ESC pair — keep.
            _ => {
                out.extend_from_slice(&bytes[i..(i + 2).min(n)]);
                i += 2;
            },
        }
    }
    out
}

/// All work is per-branch and byte-wise: the overwhelmingly common `SGR` final `m` falls straight
/// to `false` without scanning intermediates — the hot path over huge replay blobs.
fn should_strip_csi(csi: &Csi<'_>) -> bool {
    match csi.final_byte {
        // The three finals that are ALWAYS a query or its echoed answer, whatever the params:
        // `c` = DA1/DA2/DA3 and the `?`-prefixed DA response; `n` = DSR/CPR requests (5n/6n/?6n…)
        // and DSR responses (0n/3n); `R` = the echoed CPR response (`CSI row;col R`).
        b'c' | b'n' | b'R' => true,
        // DECREQTPARM query and its `x`-final response.
        b'x' => csi.intermediates.is_empty(),
        // DECRQM query and the echoed DECRPM response, both marked by the `$` intermediate; keep
        // their un-marked namesakes DECSTR `!p` and DECTST.
        b'p' | b'y' => csi.intermediates.contains(&b'$'),
        // XTVERSION `CSI > Ps q`; keep DECSCUSR `SP q` / DECSCA `" q`.
        b'q' => csi.intermediates.is_empty() && csi.params.first() == Some(&b'>'),
        // kitty keyboard-flags query `CSI ? u`; keep push/pop/restore.
        b'u' => csi.params.first() == Some(&b'?'),
        // Window-op REPORT requests only.
        b't' => {
            let first: &[u8] = csi.params.split(|&b| b == b';').next().unwrap_or_default();
            WINDOW_REPORT_OPS.contains(&first)
        },
        _ => false,
    }
}

fn should_strip_osc(body: &[u8]) -> bool {
    let number: &[u8] = body.split(|&b| b == b';').next().unwrap_or_default();
    STRIPPED_OSC_NUMBERS.contains(&number)
}

/// `DCS` bodies that are queries (XTGETTCAP `+q…`, DECRQSS `$q…`), the echoed XTVERSION response
/// (`>|…`), or the echoed DECRQSS/XTGETTCAP responses (`{0|1}$r…` / `{0|1}+r…`, ghostty's reply
/// formats): a poisoned transcript carrying a reply would re-emit raw `DCS` garbage on the fresh
/// command line. Anything else (sixel…) is kept.
fn should_strip_dcs(body: &[u8]) -> bool {
    if matches!(
        (body.first(), body.get(1)),
        (Some(b'+' | b'$'), Some(b'q')) | (Some(b'>'), Some(b'|'))
    ) {
        return true;
    }
    // The zero-body miss responses `0$r`/`1$r`/`0+r`/`1+r` are exactly 3 bytes; longer hit responses
    // carry the payload after `r` — both are covered by the 3-byte prefix match.
    matches!(
        (body.first(), body.get(1), body.get(2)),
        (Some(b'0' | b'1'), Some(b'$' | b'+'), Some(b'r'))
    )
}

#[cfg(test)]
mod tests {
    use super::strip;

    #[test]
    fn the_device_attribute_query_and_its_echoed_response_both_go() {
        assert_eq!(strip(b"a\x1b[cb"), b"ab");
        assert_eq!(strip(b"a\x1b[?62;22;52cb"), b"ab");
        assert_eq!(strip(b"a\x1b[>0;10;1cb"), b"ab");
    }

    #[test]
    fn cursor_position_requests_and_reports_both_go() {
        assert_eq!(strip(b"a\x1b[6nb"), b"ab");
        assert_eq!(strip(b"a\x1b[?6nb"), b"ab");
        assert_eq!(strip(b"a\x1b[12;40Rb"), b"ab");
    }

    #[test]
    fn the_ancient_decid_query_goes() {
        assert_eq!(strip(b"a\x1bZb"), b"ab");
    }

    #[test]
    fn decrqm_goes_but_decstr_stays() {
        assert_eq!(strip(b"a\x1b[?2026$pb"), b"ab");
        assert_eq!(strip(b"a\x1b[?2026;1$yb"), b"ab");
        assert_eq!(strip(b"a\x1b[!pb"), b"a\x1b[!pb");
    }

    /// `q` is shared by XTVERSION, `DECSCUSR` and `DECSCA`; only the first is a query.
    #[test]
    fn xtversion_goes_but_the_cursor_shape_stays() {
        assert_eq!(strip(b"a\x1b[>0qb"), b"ab");
        assert_eq!(strip(b"a\x1b[4 qb"), b"a\x1b[4 qb");
        assert_eq!(strip(b"a\x1b[1\"qb"), b"a\x1b[1\"qb");
    }

    #[test]
    fn the_kitty_flags_query_goes_but_push_and_pop_stay() {
        assert_eq!(strip(b"a\x1b[?ub"), b"ab");
        assert_eq!(strip(b"a\x1b[>1ub"), b"a\x1b[>1ub");
        assert_eq!(strip(b"a\x1b[<1ub"), b"a\x1b[<1ub");
    }

    #[test]
    fn window_report_requests_go_but_resize_and_title_stack_stay() {
        assert_eq!(strip(b"a\x1b[14tb"), b"ab");
        assert_eq!(strip(b"a\x1b[18tb"), b"ab");
        assert_eq!(strip(b"a\x1b[8;24;80tb"), b"a\x1b[8;24;80tb");
        assert_eq!(strip(b"a\x1b[22;0tb"), b"a\x1b[22;0tb");
        assert_eq!(strip(b"a\x1b[23;0tb"), b"a\x1b[23;0tb");
    }

    #[test]
    fn colour_and_clipboard_osc_go_in_both_query_and_set_form() {
        assert_eq!(strip(b"a\x1b]11;?\x07b"), b"ab");
        assert_eq!(strip(b"a\x1b]11;rgb:1111/2222/3333\x07b"), b"ab");
        assert_eq!(strip(b"a\x1b]4;1;?\x07b"), b"ab");
        assert_eq!(strip(b"a\x1b]104\x07b"), b"ab");
        assert_eq!(strip(b"a\x1b]52;c;SGVsbG8=\x07b"), b"ab");
        assert_eq!(strip(b"a\x1b]112\x07b"), b"ab");
        assert_eq!(strip(b"a\x1b]21;key=?\x07b"), b"ab");
    }

    #[test]
    fn titles_marks_and_hyperlinks_survive() {
        for osc in [
            &b"\x1b]0;my title\x07"[..],
            &b"\x1b]133;A\x07"[..],
            &b"\x1b]8;;https://example.com\x07"[..],
            &b"\x1b]7;file:///tmp\x07"[..],
        ] {
            assert_eq!(strip(osc), osc, "{osc:?} must survive");
        }
    }

    #[test]
    fn dcs_queries_and_echoed_replies_go_but_a_sixel_stays() {
        assert_eq!(strip(b"a\x1bP+q544e\x1b\\b"), b"ab");
        assert_eq!(strip(b"a\x1bP$qm\x1b\\b"), b"ab");
        assert_eq!(strip(b"a\x1bP>|ghostty 1.0\x1b\\b"), b"ab");
        assert_eq!(strip(b"a\x1bP1$r0m\x1b\\b"), b"ab");
        assert_eq!(strip(b"a\x1bP0$r\x1b\\b"), b"ab");
        assert_eq!(strip(b"a\x1bP1+r544e=787465726d\x1b\\b"), b"ab");
        let sixel = b"a\x1bPq#0;2;0;0;0\x1b\\b";
        assert_eq!(strip(sixel), sixel);
    }

    /// The dominant case by volume: `SGR` must not even reach the intermediate scan.
    #[test]
    fn ordinary_output_and_sgr_ride_through_untouched() {
        let stream = b"plain \x1b[1;31mred\x1b[0m\r\n\x1b[?25l\x1b[H";
        assert_eq!(strip(stream), stream);
    }

    #[test]
    fn a_truncated_trailing_sequence_passes_through_verbatim() {
        assert_eq!(strip(b"text\x1b[?62"), b"text\x1b[?62");
        assert_eq!(strip(b"text\x1b]11;rgb"), b"text\x1b]11;rgb");
        assert_eq!(strip(b"text\x1bP+q54"), b"text\x1bP+q54");
        assert_eq!(strip(b"text\x1b"), b"text\x1b");
    }

    /// SOS/PM/APC bodies are opaque and kept whole — including one that looks like a query.
    #[test]
    fn application_program_commands_are_kept_whole() {
        let apc = b"a\x1b_\x1b[c\x1b\\b";
        assert_eq!(strip(apc), apc);
    }

    #[test]
    fn an_empty_stream_stays_empty() {
        assert_eq!(strip(b""), b"");
    }
}
