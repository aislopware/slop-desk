//! Replay hygiene: history must not arm the client's input reporting.
//!
//! Strips INPUT-AFFECTING terminal mode changes from a scrollback REPLAY stream and reports the net
//! final state so the caller can re-assert it AFTER the replay.
//!
//! ## Why
//! Replayed history is executed by the client terminal like live output. A prior life's TUI
//! (`nvim`, `claude`) enabled mouse tracking (`?1000–1006h`), in-band resize (`?2048h`) and kitty
//! keyboard reporting (`CSI > flags u`) near the START of its run and disabled them near the END —
//! megabytes apart. During the seconds the replay takes to render, the client terminal is
//! transiently armed exactly as the TUI left it: enabling `?2048h` makes it emit an in-band size
//! report (`CSI 48;…t`) IMMEDIATELY, and any user scroll / click / keystroke mid-replay emits SGR
//! mouse reports / kitty release events. All of that rides the wire back as PTY *input* to a shell
//! sitting at a plain prompt — the `zsh: command not found: 18M65…` reattach garbage this pass
//! fixes. The matching disables arrive later in the replay, too late.
//!
//! The fix: mode changes are removed from the replayed bytes entirely, and only the NET final state
//! (what a terminal replaying the stream would end at) is re-asserted after the replay via
//! [`InputModeFinalState::reassert_sequence`]. A session whose TUIs all exited nets to all-off —
//! nothing is emitted, nothing is ever armed. A session still INSIDE a TUI nets to that TUI's
//! modes — the single trailing re-assert restores them, so a live `vim` keeps its mouse across a
//! cold reattach (re-asserting `?2048h` also makes the client send one fresh size report, which is
//! exactly what a live in-band-resize consumer wants after a reattach).
//!
//! ## Scope
//! Stripped (the set that changes what the CLIENT SENDS): DECCKM `?1`, mouse
//! `?9/1000/1001/1002/1003/1005/1006/1015/1016`, focus `?1004`, bracketed paste `?2004`,
//! colour-scheme notifications `?2031` (report-on-enable, like 2048), in-band resize `?2048`, and
//! the kitty keyboard ops `CSI > flags u` (push) / `CSI < n u` (pop) / `CSI = flags ; mode u`
//! (set). Display state (alt-screen `?1049`, cursor `?25`, autowrap `?7`, sync `?2026`…) passes
//! through untouched — the replay needs it to render. A DECSET with MIXED params (`?1049;2004h`) is
//! rewritten to keep the non-stripped params.
//!
//! ## Where it runs
//! FIRST in [`crate::sanitize`], on the raw stream, before the distiller: the net state must be
//! computed in true chronological order, and the distiller reorders it (an open `B`→`C` span's
//! bytes are flushed out of sequence or replaced by the committed command line). The un-acked live
//! tail is NEVER touched (byte-exact resume) — a mode change there is at most milliseconds of
//! transient arming, and its consumer may genuinely be alive.
//!
//! The kitty simulation uses a single stack (the real protocol keeps one per main/alt screen);
//! pushes and pops in replayed history overwhelmingly balance out per TUI run, and a live TUI's net
//! entries are re-asserted onto whichever screen the replay ends on — the one that TUI is on.

use std::collections::BTreeMap;

use crate::vtscan::{Csi, ESC, Terminators, parse_csi, string_introducer, string_sequence_end};

/// DEC private modes whose set/reset is stripped from replay and tracked for re-assert.
///
/// 2031 (colour-scheme notifications) is in the set for the same reason as 2048: the terminal emits
/// a report (`CSI ? 997 ; 1|2 n`) the instant the mode is set.
pub const TRACKED_MODES: [i64; 14] = [
    1, 9, 1000, 1001, 1002, 1003, 1004, 1005, 1006, 1015, 1016, 2004, 2031, 2048,
];

/// The bytes that put a terminal back to a known-quiet input state.
///
/// The BACKSTOP for a restore path that did not run this pass — a raw journal tail, or a run with
/// the transform disabled. Every mode in [`TRACKED_MODES`] is reset, plus the alt screen FIRST so
/// the resets that follow land on the main screen, plus the kitty keyboard stack popped and its
/// flags cleared, the graphic rendition reset and the cursor shown.
///
/// It is built from the same array the pass strips by, so a mode added there cannot be silently
/// missing here. That is the whole reason it is not a literal: the near side used to spell all
/// fourteen of them out, and nothing connected the two lists.
#[must_use]
pub fn reset_suffix() -> Vec<u8> {
    let mut out = Vec::new();
    // Leave the alternate screen first. It is not a tracked mode — the alt-screen pass owns it —
    // but a reset that lands on a TUI's screen is a reset the main screen never sees.
    out.extend_from_slice(b"\x1b[?1049l");
    for mode in TRACKED_MODES {
        out.extend_from_slice(b"\x1b[?");
        out.extend_from_slice(mode.to_string().as_bytes());
        out.push(b'l');
    }
    // Pop every kitty keyboard flag the stack holds, then clear the flags themselves: a TUI that
    // pushed and never popped leaves a client reporting keys in a grammar the shell cannot read.
    out.extend_from_slice(b"\x1b[<32u\x1b[=0;1u");
    // Then the two a user SEES: colour and attributes off, and the cursor back.
    out.extend_from_slice(b"\x1b[0m\x1b[?25h\r\n");
    out
}

/// Whether `mode` is one this pass strips and simulates.
#[must_use]
pub fn is_tracked(mode: i64) -> bool {
    TRACKED_MODES.contains(&mode)
}

/// Simulation cap on the kitty stack depth.
///
/// kitty itself caps the stack; entries pushed beyond the cap are dropped rather than growing
/// unboundedly on a hostile stream.
const STACK_CAP: usize = 32;

/// The net input-mode state at the end of a replayed stream — what a terminal executing the raw
/// history would have been left with.
///
/// [`Self::reassert_sequence`] re-creates exactly that state in a fresh terminal (empty when
/// everything nets to defaults, the common all-TUIs-exited case).
///
/// `BTreeMap` rather than a hash map because [`Self::reassert_sequence`] emits modes in ascending
/// order — the order apps enable them in — and an ordered map makes that a property of the type
/// rather than of a sort at the point of use.
#[derive(Clone, PartialEq, Eq, Debug, Default)]
pub struct InputModeFinalState {
    /// Tracked DEC private modes seen in the stream: mode → last set/reset. Modes never seen are
    /// absent (fresh-terminal default, off).
    modes: BTreeMap<i64, bool>,
    /// `XTSAVE`/`XTRESTORE` slots for the tracked modes (`CSI ? Pm s` / `CSI ? Pm r`). A restore
    /// with no prior save yields the fresh-terminal default (off) — xterm's initial-value
    /// semantics.
    saved_modes: BTreeMap<i64, bool>,
    /// The kitty flags value with an empty stack (mutable via `CSI = flags u`).
    kitty_base: i64,
    /// Pushed kitty entries, bottom-to-top.
    kitty_stack: Vec<i64>,
}

impl InputModeFinalState {
    fn apply(&mut self, mode: i64, enabled: bool) {
        self.modes.insert(mode, enabled);
    }

    fn save(&mut self, mode: i64) {
        let current = self.modes.get(&mode).copied().unwrap_or(false);
        self.saved_modes.insert(mode, current);
    }

    fn restore(&mut self, mode: i64) {
        let restored = self.saved_modes.get(&mode).copied().unwrap_or(false);
        self.modes.insert(mode, restored);
    }

    fn kitty_push(&mut self, flags: i64) {
        if self.kitty_stack.len() < STACK_CAP {
            self.kitty_stack.push(flags);
        }
    }

    fn kitty_pop(&mut self, count: i64) {
        let clamped = usize::try_from(count.max(0)).unwrap_or(usize::MAX);
        let drop = clamped.min(self.kitty_stack.len());
        self.kitty_stack.truncate(self.kitty_stack.len() - drop);
    }

    fn kitty_set(&mut self, flags: i64, mode: i64) {
        let current = self.kitty_stack.last().copied().unwrap_or(self.kitty_base);
        let updated = match mode {
            2 => current | flags,
            3 => current & !flags,
            _ => flags,
        };
        match self.kitty_stack.last_mut() {
            Some(top) => *top = updated,
            None => self.kitty_base = updated,
        }
    }

    /// TRUE when the state is a fresh terminal's default — nothing to re-assert.
    #[must_use]
    pub fn is_neutral(&self) -> bool {
        self.kitty_base == 0 && self.kitty_stack.is_empty() && !self.modes.values().any(|&on| on)
    }

    /// The byte sequence that re-creates this state in a FRESH terminal: one DECSET per mode that
    /// nets ON (ascending, the order apps enable them), then the kitty base and pushes.
    ///
    /// Modes that net OFF emit nothing — a fresh terminal is already off, and an unmatched reset is
    /// harmless noise this pass exists to remove.
    #[must_use]
    pub fn reassert_sequence(&self) -> Vec<u8> {
        let mut out = Vec::new();
        for (mode, enabled) in &self.modes {
            if *enabled {
                out.extend_from_slice(format!("\x1b[?{mode}h").as_bytes());
            }
        }
        if self.kitty_base != 0 {
            out.extend_from_slice(format!("\x1b[={};1u", self.kitty_base).as_bytes());
        }
        for flags in &self.kitty_stack {
            out.extend_from_slice(format!("\x1b[>{flags}u").as_bytes());
        }
        out
    }
}

/// Returns `bytes` with the tracked sequences removed, plus the net final state a terminal
/// replaying `bytes` would end at.
///
/// A truncated trailing sequence passes through unchanged (a ring head-cut artifact is display
/// noise, never a replayable mode change).
#[must_use]
pub fn strip(bytes: &[u8]) -> (Vec<u8>, InputModeFinalState) {
    let mut out = Vec::with_capacity(bytes.len());
    let mut state = InputModeFinalState::default();
    let n = bytes.len();
    let mut i = 0;

    while i < n {
        if bytes[i] != ESC || i + 1 >= n {
            out.push(bytes[i]);
            i += 1;
            continue;
        }
        let introducer = bytes[i + 1];
        if introducer == b'[' {
            let Some(csi) = parse_csi(bytes, i) else {
                out.extend_from_slice(&bytes[i..]); // truncated — passthrough
                break;
            };
            match process(&csi, &mut state) {
                None => out.extend_from_slice(&bytes[i..csi.end]),
                Some(rewritten) => out.extend_from_slice(&rewritten),
            }
            i = csi.end;
        } else if let Some(bel_terminates) = string_introducer(introducer) {
            // Kept whole; the body must never be parsed as a CSI.
            let Some(seq) = string_sequence_end(bytes, i + 2, Terminators::replay(bel_terminates)) else {
                out.extend_from_slice(&bytes[i..]);
                break;
            };
            out.extend_from_slice(&bytes[i..seq.seq_end]);
            i = seq.seq_end;
        } else {
            // Any other ESC pair — keep.
            out.extend_from_slice(&bytes[i..(i + 2).min(n)]);
            i += 2;
        }
    }
    (out, state)
}

/// State-only variant of [`strip`] — the same net-state simulation over the same sequence walk,
/// without building the stripped output.
///
/// The snapshot composer needs only [`InputModeFinalState::reassert_sequence`] and must not pay a
/// stream-sized output copy for it.
#[must_use]
pub fn final_state(bytes: &[u8]) -> InputModeFinalState {
    let mut state = InputModeFinalState::default();
    let n = bytes.len();
    let mut i = 0;
    while i < n {
        if bytes[i] != ESC || i + 1 >= n {
            i += 1;
            continue;
        }
        let introducer = bytes[i + 1];
        if introducer == b'[' {
            let Some(csi) = parse_csi(bytes, i) else {
                break; // truncated trailing CSI — nothing left to simulate
            };
            process(&csi, &mut state);
            i = csi.end;
        } else if let Some(bel_terminates) = string_introducer(introducer) {
            let Some(seq) = string_sequence_end(bytes, i + 2, Terminators::replay(bel_terminates)) else {
                break;
            };
            i = seq.seq_end;
        } else {
            i += 2;
        }
    }
    state
}

/// Applies one `CSI` to the tracked state.
///
/// `None` KEEPS the sequence verbatim; `Some(bytes)` replaces it — empty to drop it entirely, or a
/// rewritten mixed-param `DECSET` keeping only the untracked params.
fn process(csi: &Csi<'_>, state: &mut InputModeFinalState) -> Option<Vec<u8>> {
    if !csi.intermediates.is_empty() {
        return None; // `$p`, `SP q`… — never ours
    }
    match csi.final_byte {
        b'h' | b'l' => {
            if csi.params.first() != Some(&b'?') {
                return None; // ANSI SM/RM — keep
            }
            let is_set = csi.final_byte == b'h';
            rewrite_tracked(csi, state, |state, mode| state.apply(mode, is_set))
        },
        b's' | b'r' => {
            // XTSAVE / XTRESTORE (`CSI ? Pm s|r`) — a save/restore DOOR into the tracked modes that
            // bypasses h/l: replaying a raw `?1000s … ?1000r` pair can re-arm mouse reporting
            // mid-replay (the exact garbage-input class this pass exists to strip), and an untracked
            // restore desyncs the net-state simulation. A NON-`?` final here is DECSTBM (`r`) /
            // SCOSC-DECSLRM (`s`) — display state, kept verbatim via the guard.
            if csi.params.first() != Some(&b'?') {
                return None;
            }
            let is_save = csi.final_byte == b's';
            rewrite_tracked(csi, state, |state, mode| {
                if is_save {
                    state.save(mode);
                } else {
                    state.restore(mode);
                }
            })
        },
        b'u' => {
            match csi.params.first() {
                Some(&b'>') => {
                    state.kitty_push(leading_int(&csi.params[1..]).unwrap_or(0));
                    Some(Vec::new())
                },
                Some(&b'<') => {
                    state.kitty_pop(leading_int(&csi.params[1..]).unwrap_or(1));
                    Some(Vec::new())
                },
                Some(&b'=') => {
                    let mut fields = csi.params[1..].split(|&b| b == b';');
                    let flags = fields.next().and_then(leading_int).unwrap_or(0);
                    let mode = fields.next().and_then(leading_int).unwrap_or(1);
                    state.kitty_set(flags, mode);
                    Some(Vec::new())
                },
                // `?u` query (the query pass's business), bare `u`… — keep.
                _ => None,
            }
        },
        _ => None,
    }
}

/// Splits a private `CSI`'s params, applies `act` to each TRACKED mode and rebuilds the sequence
/// from whatever is left.
///
/// The rewrite keeps the ORIGINAL final byte: dropping `?2004` out of `?1049;2004h` leaves
/// `?1049h`, and out of `?1049;2004l` leaves `?1049l` — the sequence's sense is not this pass's to
/// change, only its parameter list.
fn rewrite_tracked(
    csi: &Csi<'_>,
    state: &mut InputModeFinalState,
    mut act: impl FnMut(&mut InputModeFinalState, i64),
) -> Option<Vec<u8>> {
    let mut kept: Vec<&[u8]> = Vec::new();
    let mut touched = false;
    for field in csi.params[1..].split(|&b| b == b';') {
        let parsed = std::str::from_utf8(field)
            .ok()
            .and_then(|text| text.parse::<i64>().ok());
        match parsed {
            Some(mode) if is_tracked(mode) => {
                act(state, mode);
                touched = true;
            },
            _ => kept.push(field),
        }
    }
    if !touched {
        return None;
    }
    if kept.is_empty() {
        return Some(Vec::new());
    }
    let mut rewritten = b"\x1b[?".to_vec();
    rewritten.extend_from_slice(&kept.join(&b';'));
    rewritten.push(csi.final_byte);
    Some(rewritten)
}

/// The leading run of ASCII digits, or `None` when there is none.
fn leading_int(bytes: &[u8]) -> Option<i64> {
    let digits = bytes.iter().take_while(|b| b.is_ascii_digit()).count();
    if digits == 0 {
        return None;
    }
    std::str::from_utf8(&bytes[..digits]).ok()?.parse().ok()
}

#[cfg(test)]
mod tests {
    use super::{TRACKED_MODES, final_state, reset_suffix, strip};

    fn stripped(input: &[u8]) -> Vec<u8> {
        strip(input).0
    }

    fn reassert(input: &[u8]) -> Vec<u8> {
        strip(input).1.reassert_sequence()
    }

    #[test]
    fn a_tui_that_exited_leaves_nothing_to_reassert() {
        let stream = b"\x1b[?1000h\x1b[?2004hwork\x1b[?2004l\x1b[?1000l";
        assert_eq!(stripped(stream), b"work");
        assert!(strip(stream).1.is_neutral());
        assert_eq!(reassert(stream), b"");
    }

    #[test]
    fn a_live_tui_nets_to_its_own_modes_in_ascending_order() {
        let stream = b"\x1b[?2004h\x1b[?1000hstill running";
        assert_eq!(stripped(stream), b"still running");
        assert_eq!(reassert(stream), b"\x1b[?1000h\x1b[?2004h");
    }

    /// The mixed-param case: the alt-screen and cursor modes are DISPLAY state the replay needs.
    #[test]
    fn a_mixed_decset_keeps_its_untracked_params() {
        assert_eq!(stripped(b"\x1b[?1049;2004;25h"), b"\x1b[?1049;25h");
        assert_eq!(reassert(b"\x1b[?1049;2004;25h"), b"\x1b[?2004h");
    }

    #[test]
    fn display_modes_pass_through_untouched() {
        for stream in [
            &b"\x1b[?1049h"[..],
            &b"\x1b[?25l"[..],
            &b"\x1b[?7h"[..],
            &b"\x1b[?2026h"[..],
        ] {
            assert_eq!(stripped(stream), stream, "{stream:?} must survive");
        }
    }

    /// ANSI `SM`/`RM` carry no `?` and are a different mode space entirely.
    #[test]
    fn a_non_private_set_mode_is_not_ours() {
        assert_eq!(stripped(b"\x1b[4h"), b"\x1b[4h");
        assert_eq!(stripped(b"\x1b[20l"), b"\x1b[20l");
    }

    #[test]
    fn the_kitty_stack_is_simulated_through_push_pop_and_set() {
        // Push 5, push 3, pop one → the stack nets to [5].
        let stream = b"\x1b[>5u\x1b[>3u\x1b[<1u";
        assert_eq!(stripped(stream), b"");
        assert_eq!(reassert(stream), b"\x1b[>5u");
    }

    #[test]
    fn a_kitty_set_with_no_stack_moves_the_base() {
        assert_eq!(reassert(b"\x1b[=9;1u"), b"\x1b[=9;1u");
        // Mode 2 is OR, mode 3 is AND-NOT.
        assert_eq!(reassert(b"\x1b[=1;1u\x1b[=2;2u"), b"\x1b[=3;1u");
        assert_eq!(reassert(b"\x1b[=3;1u\x1b[=1;3u"), b"\x1b[=2;1u");
    }

    #[test]
    fn a_hostile_push_run_cannot_grow_the_stack_without_bound() {
        let mut stream = Vec::new();
        for _ in 0..1000 {
            stream.extend_from_slice(b"\x1b[>1u");
        }
        let state = strip(&stream).1;
        // 32 entries, each re-asserted as five bytes.
        assert_eq!(state.reassert_sequence().len(), 32 * 5);
    }

    #[test]
    fn a_pop_larger_than_the_stack_empties_it_rather_than_underflowing() {
        assert_eq!(reassert(b"\x1b[>7u\x1b[<99u"), b"");
        // And a pop with nothing pushed at all.
        assert_eq!(reassert(b"\x1b[<5u"), b"");
    }

    /// `XTSAVE`/`XTRESTORE` is the door into the tracked modes that bypasses `h`/`l`.
    #[test]
    fn a_save_restore_pair_is_stripped_and_simulated() {
        let stream = b"\x1b[?1000h\x1b[?1000s\x1b[?1000l\x1b[?1000r";
        assert_eq!(stripped(stream), b"");
        // Saved while ON, restored at the end → nets ON.
        assert_eq!(reassert(stream), b"\x1b[?1000h");
    }

    #[test]
    fn a_restore_with_no_prior_save_yields_the_fresh_terminal_default() {
        let stream = b"\x1b[?1000h\x1b[?1000r";
        assert_eq!(reassert(stream), b"");
    }

    /// `DECSTBM` (`CSI r`) and `SCOSC` (`CSI s`) share the finals but not the `?`.
    #[test]
    fn a_non_private_r_or_s_is_display_state_and_survives() {
        assert_eq!(stripped(b"\x1b[1;24r"), b"\x1b[1;24r");
        assert_eq!(stripped(b"\x1b[s"), b"\x1b[s");
    }

    #[test]
    fn a_mode_change_inside_a_string_body_is_never_parsed() {
        // The OSC body contains what looks like a DECSET; it must ride through untouched.
        let stream = b"\x1b]0;\x1b[?1000h\x07after";
        assert_eq!(stripped(stream), stream);
        assert_eq!(reassert(stream), b"");
    }

    #[test]
    fn a_truncated_trailing_sequence_passes_through_verbatim() {
        assert_eq!(stripped(b"text\x1b[?100"), b"text\x1b[?100");
        assert_eq!(stripped(b"text\x1b]0;unterminated"), b"text\x1b]0;unterminated");
        assert_eq!(stripped(b"text\x1b"), b"text\x1b");
    }

    /// The state-only walk must agree with the full strip on every input, since the composer uses
    /// one and the replay transform the other.
    #[test]
    fn the_state_only_walk_agrees_with_the_full_strip() {
        for stream in [
            &b"\x1b[?1000h\x1b[?2004hwork\x1b[?2004l"[..],
            &b"\x1b[>5u\x1b[=3;2u"[..],
            &b"\x1b[?1049;2004h\x1b[?1000s\x1b[?1000r"[..],
            &b"plain text with no sequences"[..],
            &b"\x1b]0;\x1b[?1000h\x07"[..],
            &b"truncated\x1b[?10"[..],
        ] {
            assert_eq!(
                final_state(stream),
                strip(stream).1,
                "walks disagree on {stream:?}"
            );
        }
    }

    #[test]
    fn an_empty_stream_is_neutral() {
        assert_eq!(stripped(b""), b"");
        assert!(strip(b"").1.is_neutral());
    }

    #[test]
    fn the_reset_backstop_is_built_from_the_set_the_pass_strips_by() {
        let reset = reset_suffix();
        let text = String::from_utf8(reset.clone()).unwrap_or_default();
        assert!(
            text.starts_with("\u{1b}[?1049l"),
            "the alt screen is left first, or the resets land on a TUI's screen"
        );
        for mode in TRACKED_MODES {
            assert!(
                text.contains(&format!("\x1b[?{mode}l")),
                "every tracked mode is reset — {mode} is not"
            );
        }
        assert!(text.contains("\u{1b}[<32u"), "the kitty stack is popped");
        assert!(text.contains("\u{1b}[=0;1u"), "and its flags cleared");
        assert!(
            text.ends_with("\u{1b}[0m\u{1b}[?25h\r\n"),
            "colour off and the cursor back, last"
        );
        assert_eq!(
            strip(&reset).0,
            b"\x1b[?1049l\x1b[0m\x1b[?25h\r\n".to_vec(),
            "and the pass recognises everything it built except what it does not own: the alt screen's \
             leave, the rendition reset and the cursor"
        );
    }
}
