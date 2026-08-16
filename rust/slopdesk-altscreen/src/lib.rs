//! Exact alternate-screen state at a front-truncation CUT of a terminal byte stream, and the
//! DECSET that re-opens the segment the cut beheaded.
//!
//! ## Why
//! Every scrollback retainer cuts its stream from the FRONT when it outgrows the cap: the in-memory
//! ring (`slopdesk_wire::replay::ReplayBuffer`'s ack eviction) and superd's on-disk journal
//! (`slopdesk_superd::journal`'s compaction). A cut that lands INSIDE an open alt-screen segment
//! (`?1049h … ?1049l` — a Claude Code session holds one open for its whole run) beheads it: the
//! surviving stream starts with segment interior and ends it with an UNPAIRED `?1049l`.
//! Replay-side segmentation rightly treats an unpaired leave as a defensive reset and passes
//! everything through — so tens of MiB of full-screen TUI churn replays onto the MAIN screen and
//! floods the client's scrollback.
//!
//! "Drop the prefix up to the unpaired leave" is NOT a safe heuristic: apps emit redundant
//! `?1049l` while already on the main screen (Claude's exit cleanup does), and that would eat real
//! history. This scanner removes the guess: the evictor feeds it the exact bytes being dropped, and
//! the net DECSET/DECRST state says whether the cut is inside a segment.
//!
//! ## Repair invariant — the state lives IN the bytes
//! When the cut is inside a segment, the evictor PREPENDS the returned re-opener to the surviving
//! head (ring entry / file tail). The surviving stream is then well-formed again, so the NEXT
//! eviction's scan — which starts from that repaired head — needs no carried state. For the journal
//! the repair is on disk, so the invariant survives the daemon.
//!
//! ## Semantics
//! - DECSET/DECRST with any of 47/1047/1049 flips the state; the re-opener uses the SAME mode that
//!   last entered (a `?47h` app must not be re-opened with 1049's save/clear semantics).
//! - String-sequence bodies (OSC/DCS/SOS/PM/APC) are opaque — an embedded `?1049h` is body text. A
//!   body still open at the end of the dropped prefix cannot contain transitions, so the state at
//!   the cut is the state at the body's start.
//! - A CSI that STRADDLES the cut (starts in the dropped prefix, finishes in the kept head) is
//!   resolved by peeking a bounded slice of the kept head; sequences that START in the kept head
//!   belong to the surviving stream and are never applied.

#![forbid(unsafe_code)]

use slopdesk_sanitize::vtscan::{self, Csi, ESC, Terminators};

/// DEC private modes that switch to the alternate screen.
const ALT_MODES: [u32; 3] = [47, 1047, 1049];

/// Bounded kept-head peek: enough to finish any realistic straddling CSI (params + final).
const STRADDLE_PEEK_BYTES: usize = 64;

/// The DECSET to prepend to a front-truncated stream's surviving tail, or `None`.
///
/// Scans `dropped` — the bytes being evicted from the front of a scrollback stream — and answers
/// with the re-opener (e.g. `ESC [ ? 1049 h`) when the cut lands inside an open alt-screen segment.
///
/// `kept_head` is the first bytes of the SURVIVING stream, used only to resolve a sequence
/// straddling the cut. Pass what is cheap; missing bytes degrade to "straddler unresolved → state
/// unchanged", never to a wrong transition.
#[must_use]
pub fn reopen_sequence(dropped: &[u8], kept_head: &[u8]) -> Option<Vec<u8>> {
    let boundary = dropped.len();
    let mut bytes = Vec::with_capacity(boundary + STRADDLE_PEEK_BYTES);
    bytes.extend_from_slice(dropped);
    bytes.extend(kept_head.iter().take(STRADDLE_PEEK_BYTES));

    let mut in_alt = false;
    let mut enter_mode: u32 = 1049;
    let mut index = 0;
    // Only sequences STARTING inside the dropped prefix are applied; one straddler may finish in
    // the peek region, after which `index >= boundary` ends the scan.
    while index < boundary {
        if bytes.get(index) != Some(&ESC) || index + 1 >= bytes.len() {
            index += 1;
            continue;
        }
        match bytes.get(index + 1).copied() {
            // CSI
            Some(b'[') => {
                match vtscan::parse_csi(&bytes, index) {
                    Some(sequence) => {
                        if let Some(mode) = alt_transition_param(&sequence) {
                            in_alt = sequence.final_byte == b'h';
                            if in_alt {
                                enter_mode = mode;
                            }
                        }
                        index = sequence.end;
                    },
                    // Truncated trailing CSI — unresolvable, state as-is.
                    None => index = bytes.len(),
                }
            },
            // OSC / DCS / SOS / PM / APC — opaque bodies.
            Some(terminator @ (b']' | b'P' | b'X' | b'^' | b'_')) => {
                let policy = Terminators::replay(terminator == b']');
                match vtscan::string_sequence_end(&bytes, index + 2, policy) {
                    Some(sequence) => index = sequence.seq_end,
                    // Cut inside the body — no transitions possible past here.
                    None => index = bytes.len(),
                }
            },
            _ => index += 2,
        }
    }
    if !in_alt {
        return None;
    }
    Some(format!("\u{1B}[?{enter_mode}h").into_bytes())
}

/// The alt-screen mode when the CSI is a DECSET/DECRST whose params include one, else `None`.
fn alt_transition_param(sequence: &Csi<'_>) -> Option<u32> {
    if sequence.final_byte != b'h' && sequence.final_byte != b'l' {
        return None;
    }
    // Intermediates present ⇒ not a DECSET/DECRST, whatever the final byte says. The hand-rolled
    // parser expressed this by zeroing its own `final_byte`; the shared `Csi` reports both, so the
    // discrimination has to be made here instead of hidden in the scan.
    if !sequence.intermediates.is_empty() {
        return None;
    }
    let (marker, rest) = sequence.params.split_first()?;
    if *marker != b'?' {
        return None;
    }
    // Same lossy split discipline as the stripper siblings: a non-numeric parameter is skipped
    // rather than failing the whole sequence.
    rest.split(|&byte| byte == b';')
        .filter_map(|token| core::str::from_utf8(token).ok()?.parse::<u32>().ok())
        .find(|mode| ALT_MODES.contains(mode))
}

#[cfg(test)]
mod tests {
    use super::reopen_sequence;

    fn reopen(dropped: &str, kept: &str) -> Option<String> {
        reopen_sequence(dropped.as_bytes(), kept.as_bytes())
            .map(|bytes| String::from_utf8_lossy(&bytes).into_owned())
    }

    // MARK: Net state

    #[test]
    fn plain_text_is_outside_alt_screen() {
        assert_eq!(reopen("hello\nworld\n", ""), None);
    }

    /// The two properties the hand-rolled scanner enforced implicitly and `vtscan` reports instead
    /// of deciding, so the discrimination now lives in `alt_transition_param` where it can be read.
    #[test]
    fn an_intermediate_byte_disqualifies_a_look_alike_decset() {
        // `ESC [ ? 1049 SP h` — parameters and a final byte that read like an enter, with an
        // intermediate between them. ECMA-48 says that is a different sequence entirely.
        assert_eq!(reopen("\u{1B}[?1049 h", ""), None);
    }

    /// `vtscan` offers a LENIENT policy where a bare `ESC` ends a string body. This crate must not
    /// take it: an unterminated OSC here is a head-cut artifact, and calling it "ended" would let
    /// the scan walk into body text and read an embedded `?1049h` as a real transition.
    #[test]
    fn a_bare_escape_inside_an_osc_body_does_not_end_it() {
        assert_eq!(reopen("\u{1B}]0;ti\u{1B}tle\u{1B}[?1049h", ""), None);
    }

    #[test]
    fn empty_dropped_is_outside_alt_screen() {
        assert_eq!(reopen("", ""), None);
    }

    #[test]
    fn an_open_segment_at_the_cut_reopens_1049() {
        assert_eq!(
            reopen("before\n\u{1B}[?1049halt churn", ""),
            Some("\u{1B}[?1049h".to_owned())
        );
    }

    #[test]
    fn a_closed_segment_at_the_cut_does_not_reopen() {
        assert_eq!(reopen("a\u{1B}[?1049hchurn\u{1B}[?1049lb", ""), None);
    }

    #[test]
    fn a_redundant_leave_on_the_main_screen_stays_outside() {
        // Claude's exit cleanup emits ?1049l while already on the main screen — the exact pattern
        // that makes a "drop prefix to first unpaired l" heuristic dangerous.
        assert_eq!(reopen("text\u{1B}[?1049lmore\u{1B}[?1049lend", ""), None);
    }

    #[test]
    fn a_close_then_reenter_reopens() {
        assert_eq!(
            reopen("\u{1B}[?1049ha\u{1B}[?1049lb\u{1B}[?1049hc", ""),
            Some("\u{1B}[?1049h".to_owned())
        );
    }

    // MARK: Mode variants — reopen with the SAME mode that opened

    #[test]
    fn mode_47_reopens_47() {
        assert_eq!(reopen("x\u{1B}[?47hy", ""), Some("\u{1B}[?47h".to_owned()));
    }

    #[test]
    fn mode_1047_reopens_1047() {
        assert_eq!(reopen("x\u{1B}[?1047hy", ""), Some("\u{1B}[?1047h".to_owned()));
    }

    #[test]
    fn a_mixed_parameter_enter_is_recognised() {
        assert_eq!(reopen("x\u{1B}[?25;1049hy", ""), Some("\u{1B}[?1049h".to_owned()));
    }

    #[test]
    fn a_mixed_parameter_leave_is_recognised() {
        assert_eq!(reopen("\u{1B}[?1049ha\u{1B}[?1049;25lb", ""), None);
    }

    // MARK: String-sequence bodies are opaque

    #[test]
    fn a_decset_inside_an_osc_body_does_not_open() {
        assert_eq!(reopen("\u{1B}]0;title \u{1B}[?1049h fake\u{07}rest", ""), None);
    }

    #[test]
    fn a_decset_inside_a_dcs_body_does_not_open() {
        assert_eq!(reopen("\u{1B}Pq\u{1B}[?1049h\u{1B}\\rest", ""), None);
    }

    #[test]
    fn a_cut_inside_an_osc_body_keeps_the_state_from_before_the_body() {
        // The body never terminates within the dropped prefix — transitions cannot occur inside it,
        // so the state at the cut is the state at the body's start.
        assert_eq!(
            reopen("\u{1B}[?1049halt\u{1B}]0;unterminated title", ""),
            Some("\u{1B}[?1049h".to_owned())
        );
        assert_eq!(reopen("main\u{1B}]0;unterminated \u{1B}[?1049h title", ""), None);
    }

    // MARK: Straddling sequences (cut lands mid-CSI)

    #[test]
    fn an_enter_straddling_the_cut_is_resolved_via_the_kept_head() {
        assert_eq!(
            reopen("text\u{1B}[?10", "49halt churn"),
            Some("\u{1B}[?1049h".to_owned())
        );
    }

    #[test]
    fn a_leave_straddling_the_cut_is_resolved_via_the_kept_head() {
        assert_eq!(reopen("\u{1B}[?1049halt\u{1B}[?104", "9lmain"), None);
    }

    #[test]
    fn a_sequence_starting_in_the_kept_head_is_not_applied() {
        // Only sequences that START inside the dropped prefix count — the kept head belongs to the
        // surviving stream and will be interpreted by the client itself.
        assert_eq!(reopen("plain text", "\u{1B}[?1049halt"), None);
    }

    #[test]
    fn an_unresolvable_trailing_escape_leaves_the_state_as_is() {
        assert_eq!(
            reopen("\u{1B}[?1049halt\u{1B}", ""),
            Some("\u{1B}[?1049h".to_owned())
        );
        assert_eq!(reopen("main\u{1B}[?10", ""), None);
    }

    #[test]
    fn a_straddler_longer_than_the_peek_window_is_left_unresolved() {
        // The peek is bounded; a straddler whose final byte lies past it degrades to "state
        // unchanged" rather than to a wrong transition.
        let padding = "0".repeat(super::STRADDLE_PEEK_BYTES);
        assert_eq!(reopen("x\u{1B}[?1049", &format!("{padding}h")), None);
    }
}
