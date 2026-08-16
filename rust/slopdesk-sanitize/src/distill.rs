//! Raw cold-reattach scrollback → clean transcript.
//!
//! The transient in-line line-editor churn that lives between the `OSC 133` `B` (command-input
//! start) and `C` (output start) marks — tab-completion menus, zsh-autosuggestions ghost text,
//! syntax-highlight repaints, per-keystroke `\r`-redraws — is DROPPED and replaced by the single
//! authoritative committed command line (the `133;E` preexec command text). Everything else passes
//! through VERBATIM: the prompt (`A`→`B`), the command OUTPUT (`C`→`D`, colours intact), and any
//! bytes outside the marks.
//!
//! ## Why
//! The scrollback ring stores the raw wire bytes. Those `B`→`C` editing bytes are only visually
//! correct against the LIVE terminal's cursor and geometry: a completion menu is drawn BELOW the
//! line, then erased with cursor-RELATIVE motion (`\r`, cursor-up, `ESC [ J`). Replayed LINEARLY
//! into a fresh empty terminal the erase lands on the wrong rows and menu/suggestion fragments
//! survive as garbage. Collapsing `B`→`C` to the committed command removes the churn while keeping
//! full history AND the live output formatting — exactly what a coding tool's scrollback wants.
//!
//! ## Safety / fallback
//! When NO `133;E` command text was seen for a `B`→`C` span (a non-zsh shell, an older shim, or a
//! dropped `E`), that span is passed through VERBATIM — this pass NEVER invents a command line. The
//! worst case is therefore "no cleaner than the raw replay", never lost output. A pathologically
//! large editing span (a huge paste) overflows a buffer cap and also falls back to verbatim
//! passthrough for that span.
//!
//! This is a display-only transform of the COLD-reattach scrollback copy; the live byte stream and
//! the un-acked resume tail are untouched.
//!
//! ## Relationship to the segmenter
//! The `OSC 133` detection here is the same shape as hostd's `CommandBlockSegmenter` — the marks
//! and the `133;E` unescape are byte-identical — but the two answer different questions: that one
//! emits block METADATA over the wire from the live stream, this one emits a byte stream from a
//! replayed one. They are not the same capability in two places; they are two consumers of one
//! grammar.

use crate::vtscan::{BEL, ESC};

/// Payload cap for a single `OSC` sequence — an `OSC` that exceeds it is discarded to its
/// terminator so a never-terminated `OSC` cannot grow unbounded.
const OSC_CAP: usize = 4096;

/// Cap on the buffered `B`→`C` editing span used ONLY for the no-`E` verbatim fallback. Beyond this
/// the span is flushed and passed through (a giant editing span will not collapse cleanly anyway).
const INPUT_SPAN_CAP: usize = 256 * 1024;

const BACKSLASH: u8 = 0x5C;
const RIGHT_BRACKET: u8 = 0x5D;
const SEMICOLON: u8 = 0x3B;

/// Parser state — the minimal `OSC`-aware skimmer.
///
/// `CSI` and two-byte escapes are NOT tracked as distinct states: they can never be confused with
/// an `OSC` start (which requires the exact `ESC` `]` adjacency), so in a passthrough phase they
/// flow through byte-by-byte and in a suppressed phase they are buffered/dropped byte-by-byte — no
/// final-byte parsing needed.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum State {
    Ground,
    /// Last byte was `ESC` — decide `OSC` vs. other escape on the next byte.
    AfterEsc,
    /// Inside an `OSC` string (after `ESC ]`).
    Osc,
    /// Inside an `OSC`, last byte was `ESC` — looking for `\` (ST).
    OscEsc,
    /// `OSC` over the cap — swallow to the terminator.
    OscDiscard,
    OscDiscardEsc,
    /// Inside a `DCS`/`SOS`/`PM`/`APC` string body: its bytes PASS THROUGH verbatim (honouring
    /// phase) but are NEVER parsed for marks — an embedded `ESC ] 133 ; …` there cannot flip phase.
    StringConsume,
    /// Inside a string body, last byte was `ESC` — looking for `\` (ST).
    StringConsumeEsc,
}

/// How the current `B`→`C` command-input span is being handled.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum InputMode {
    /// Accumulating raw bytes for the no-`E` verbatim fallback.
    Buffering,
    /// The span overflowed the cap — emit raw directly (fallback).
    Passthrough,
}

/// Everything the byte loop mutates, gathered so the `OSC` handlers can be methods rather than a
/// nest of closures capturing eight locals (which is what the Swift original had to be).
struct Distiller {
    out: Vec<u8>,
    /// The in-progress escape/`OSC` sequence (from `ESC`), decided at its end.
    pending: Vec<u8>,
    /// Just the `OSC` body (between `ESC ]` and the terminator).
    osc_payload: Vec<u8>,
    state: State,
    /// Whether the `B`→`C` span is currently suppressing.
    suppress: bool,
    input_mode: InputMode,
    /// Raw `B`→`C` bytes retained for the no-`E` fallback.
    input_buffer: Vec<u8>,
    /// The `133;E` committed command line for the current span.
    command: Option<Vec<u8>>,
}

impl Distiller {
    fn new(capacity: usize) -> Self {
        Self {
            out: Vec::with_capacity(capacity),
            pending: Vec::new(),
            osc_payload: Vec::new(),
            state: State::Ground,
            suppress: false,
            input_mode: InputMode::Buffering,
            input_buffer: Vec::new(),
            command: None,
        }
    }

    /// Emits a NORMAL (non-escape) content byte honouring the current phase.
    fn emit_content(&mut self, byte: u8) {
        if !self.suppress || self.input_mode == InputMode::Passthrough {
            self.out.push(byte);
            return;
        }
        self.input_buffer.push(byte);
        self.spill_if_over_cap();
    }

    /// Emits (or buffers) a completed NON-133 escape/`OSC` sequence held in `pending`.
    fn emit_pending(&mut self) {
        if self.pending.is_empty() {
            return;
        }
        if !self.suppress || self.input_mode == InputMode::Passthrough {
            self.out.extend_from_slice(&self.pending);
        } else {
            self.input_buffer.extend_from_slice(&self.pending);
            self.spill_if_over_cap();
        }
        self.pending.clear();
    }

    /// Overflowing the fallback cap flushes what is buffered and passes the rest of the span
    /// through: a giant editing span is not going to collapse cleanly, and never losing output
    /// outranks tidiness.
    fn spill_if_over_cap(&mut self) {
        if self.input_buffer.len() > INPUT_SPAN_CAP {
            self.out.append(&mut self.input_buffer);
            self.input_mode = InputMode::Passthrough;
        }
    }

    /// Closes an OPEN `B`→`C` command-input span that ended WITHOUT a `C` — an empty-Enter line, a
    /// Ctrl-C'd command, or a defensive `A`/`D` mid-span.
    ///
    /// FLUSHES its buffered raw bytes rather than dropping them (the accept-line CRLF echo / the
    /// cancelled command text is real scrollback), honouring the "never lost output" guarantee. A
    /// no-op when idle or already in passthrough (bytes were emitted live).
    fn flush_open_input_span(&mut self) {
        if !self.suppress {
            return;
        }
        if self.input_mode == InputMode::Buffering && !self.input_buffer.is_empty() {
            self.out.append(&mut self.input_buffer);
        }
        self.input_buffer.clear();
        self.command = None;
        self.suppress = false;
    }

    /// Acts on a completed `OSC` (payload in `osc_payload`, full raw bytes in `pending`).
    ///
    /// A `133` mark is CONSUMED — it drives the phase and is never emitted, being zero-width. Any
    /// other `OSC` is emitted verbatim.
    fn finish_osc(&mut self) {
        let handled = self.classify_osc();
        if !handled {
            self.emit_pending();
        }
        self.pending.clear();
        self.osc_payload.clear();
    }

    /// Returns whether the `OSC` was a `133` mark this pass consumed.
    fn classify_osc(&mut self) -> bool {
        let Some(sep) = self.osc_payload.iter().position(|&b| b == SEMICOLON) else {
            return false;
        };
        if self.osc_payload.get(..sep) != Some(b"133".as_slice()) {
            return false;
        }
        match self.osc_payload.get(sep + 1).copied() {
            // 'A' — prompt start → idle (end any command span defensively).
            Some(b'A') => {
                // Flush any open (no-`C`) span so its bytes are not lost, then RE-EMIT the prompt
                // mark: libghostty counts one prompt per `133;A`, and the client's block/prompt
                // jumps re-anchor by that count — so the distilled cold-reattach scrollback must
                // carry one `133;A` per prompt to keep the count identical to the live stream.
                self.flush_open_input_span();
                self.out.extend_from_slice(&self.pending);
            },
            // 'B' — command-input start (or a prompt REDRAW re-firing B).
            Some(b'B') => {
                self.suppress = true;
                self.input_mode = InputMode::Buffering;
                self.input_buffer.clear();
                self.command = None;
            },
            // 'E' — explicit committed command line (slopdesk extension).
            Some(b'E') => {
                self.command = Some(parse_command_field(&self.osc_payload, sep));
                // Tolerate an `E` that arrives without a preceding `B` (a mid-stream join).
                if !self.suppress {
                    self.suppress = true;
                    self.input_mode = InputMode::Buffering;
                    self.input_buffer.clear();
                }
            },
            // 'C' — output start: close the command span.
            Some(b'C') => {
                if self.suppress {
                    let committed = self.command.take().filter(|command| !command.is_empty());
                    if self.input_mode == InputMode::Buffering {
                        match committed {
                            Some(command) => {
                                self.out.extend_from_slice(&command);
                                self.out.push(0x0D); // CR
                                self.out.push(0x0A); // LF
                            },
                            // No committed command text — fall back to the raw B→C bytes verbatim.
                            None => self.out.extend_from_slice(&self.input_buffer),
                        }
                    }
                    self.input_buffer.clear();
                    self.command = None;
                    self.suppress = false;
                }
            },
            // 'D' — command finished → idle. Flush any open (no-`C`) span so its echoed bytes (the
            // empty-Enter CRLF, a Ctrl-C'd command line) reach the transcript instead of vanishing.
            Some(b'D') => self.flush_open_input_span(),
            // Some other 133 subcommand — not a phase mark; drop the (zero-width) mark.
            _ => {},
        }
        true
    }

    /// Advances the machine by one byte.
    ///
    /// Split out of [`distill`] so the loop reads as a loop: every arm here is a state transition,
    /// and the entry point is then only the two end-of-stream flushes around it.
    fn step(&mut self, byte: u8) {
        match self.state {
            State::Ground => {
                if byte == ESC {
                    self.pending.clear();
                    self.pending.push(ESC);
                    self.state = State::AfterEsc;
                } else {
                    self.emit_content(byte);
                }
            },

            State::AfterEsc => self.handle_after_esc(byte),

            State::StringConsume => {
                match byte {
                    // BEL terminates the string body.
                    BEL => {
                        self.emit_content(byte);
                        self.state = State::Ground;
                    },
                    // Possible ST (`ESC \`) — hold the ESC and decide on the next byte.
                    ESC => {
                        self.pending.clear();
                        self.pending.push(ESC);
                        self.state = State::StringConsumeEsc;
                    },
                    // Opaque string-body byte — pass through verbatim (never parsed for marks).
                    _ => self.emit_content(byte),
                }
            },

            State::StringConsumeEsc => {
                match byte {
                    // `ESC \` = ST terminator — emit it and resume ground.
                    BACKSLASH => {
                        self.pending.push(byte);
                        self.emit_pending();
                        self.state = State::Ground;
                    },
                    // Another ESC — the held one was body; emit it and keep waiting for ST.
                    ESC => {
                        self.emit_pending();
                        self.pending.push(ESC);
                    },
                    // Lone ESC inside the body — emit `ESC <b>` and keep consuming the string.
                    _ => {
                        self.pending.push(byte);
                        self.emit_pending();
                        self.state = State::StringConsume;
                    },
                }
            },

            State::Osc => {
                match byte {
                    // BEL terminator.
                    BEL => {
                        self.pending.push(byte);
                        self.finish_osc();
                        self.state = State::Ground;
                    },
                    ESC => {
                        self.pending.push(byte);
                        self.state = State::OscEsc;
                    },
                    _ => {
                        self.pending.push(byte);
                        self.osc_payload.push(byte);
                        if self.osc_payload.len() > OSC_CAP {
                            self.osc_payload.clear();
                            self.pending.clear();
                            self.state = State::OscDiscard;
                        }
                    },
                }
            },

            State::OscEsc => {
                if byte == BACKSLASH {
                    // ST = `ESC \` terminator.
                    self.pending.push(byte);
                    self.finish_osc();
                    self.state = State::Ground;
                } else {
                    // ESC not followed by `\`: the OSC is terminated by the bare ESC; that ESC
                    // starts a new escape. Finish the OSC (without the trailing ESC), then reprocess
                    // from AfterEsc.
                    self.finish_osc();
                    self.pending.clear();
                    self.pending.push(ESC);
                    self.handle_after_esc(byte);
                }
            },

            State::OscDiscard => {
                match byte {
                    BEL => self.state = State::Ground,
                    ESC => self.state = State::OscDiscardEsc,
                    // Discarded over-cap payload byte.
                    _ => {},
                }
            },

            State::OscDiscardEsc => {
                if byte == BACKSLASH {
                    self.state = State::Ground;
                } else {
                    self.pending.clear();
                    self.pending.push(ESC);
                    self.handle_after_esc(byte);
                }
            },
        }
    }

    /// Classifies the byte AFTER an `ESC` (the introducer already pushed onto `pending`).
    ///
    /// `]` → `OSC`; `P`/`X`/`^`/`_` → a `DCS`/`SOS`/`PM`/`APC` string body; a second `ESC` →
    /// re-introduce; anything else is a `CSI` or short escape flushed to ground. Shared by the main
    /// `AfterEsc` arm and the two stray-`ESC` re-entry arms so all three treat string introducers
    /// identically.
    fn handle_after_esc(&mut self, byte: u8) {
        self.pending.push(byte);
        match byte {
            // `ESC ]` — OSC begins.
            RIGHT_BRACKET => {
                self.state = State::Osc;
                self.osc_payload.clear();
            },
            // A string sequence: emit the introducer verbatim (honouring phase), then pass the body
            // through in `StringConsume` WITHOUT parsing marks.
            b'P' | b'X' | b'^' | b'_' => {
                self.emit_pending();
                self.state = State::StringConsume;
            },
            // Consecutive ESC — flush the first, keep this one as the new introducer.
            ESC => {
                self.pending.pop();
                self.emit_pending();
                self.pending.push(ESC);
                self.state = State::AfterEsc;
            },
            // CSI (`ESC [`) or a short escape — not an OSC; flush it and resume ground.
            _ => {
                self.emit_pending();
                self.state = State::Ground;
            },
        }
    }
}

/// Distils `bytes`, returning the cleaned byte stream.
///
/// Never longer in the common case; a rare no-`E` span is byte-for-byte the input. Empty input →
/// empty output.
#[must_use]
pub fn distill(bytes: &[u8]) -> Vec<u8> {
    if bytes.is_empty() {
        return Vec::new();
    }
    let mut distiller = Distiller::new(bytes.len());

    for &byte in bytes {
        distiller.step(byte);
    }

    // End of stream: flush any dangling escape (unterminated CSI/OSC) honouring phase — a trailing
    // partial sequence is emitted (pass) / buffered (suppress) rather than dropped.
    if !distiller.pending.is_empty() {
        distiller.emit_pending();
    }
    // A never-closed B→C span (no `C` at end-of-buffer) in the buffering fallback: emit its raw
    // bytes so no output is lost (it is the tail of the live command line being edited when the ring
    // ended).
    if distiller.suppress
        && distiller.input_mode == InputMode::Buffering
        && !distiller.input_buffer.is_empty()
    {
        distiller.out.append(&mut distiller.input_buffer);
    }
    distiller.out
}

/// Extracts and unescapes the `133;E;<escaped>` command field.
///
/// `sep` is the index of the `;` after `133`; the command field is everything after the SECOND `;`.
fn parse_command_field(payload: &[u8], sep: usize) -> Vec<u8> {
    let after_mark = sep + 1; // points at 'E'
    let Some(rest) = payload.get(after_mark..) else {
        return Vec::new();
    };
    let Some(offset) = rest.iter().position(|&b| b == SEMICOLON) else {
        return Vec::new();
    };
    crate::escape::unescape_command(rest.get(offset + 1..).unwrap_or_default())
}

#[cfg(test)]
mod tests {
    use super::{INPUT_SPAN_CAP, distill};

    /// The headline case: per-keystroke redraw churn replaced by the committed command line.
    #[test]
    fn the_editing_span_collapses_to_the_committed_command() {
        let stream = b"\x1b]133;A\x07$ \x1b]133;B\x07l\rls\rls -\rls -la\
            \x1b]133;E;ls -la\x07\x1b]133;C\x07total 4\r\n\x1b]133;D;0\x07";
        let out = distill(stream);
        let text = String::from_utf8_lossy(&out).into_owned();
        assert!(text.contains("ls -la\r\n"), "committed command missing: {text:?}");
        assert!(!text.contains("ls -\r"), "editing churn survived: {text:?}");
        assert!(text.contains("total 4"), "output must survive verbatim: {text:?}");
    }

    /// The safety contract: with no `E`, the span is passed through rather than invented.
    #[test]
    fn a_span_with_no_committed_command_passes_through_verbatim() {
        let stream = b"\x1b]133;B\x07raw editing bytes\x1b]133;C\x07out";
        assert_eq!(distill(stream), b"raw editing bytesout");
    }

    /// libghostty counts one prompt per `133;A`, and the client's block jumps re-anchor by it.
    #[test]
    fn the_prompt_start_mark_is_re_emitted_so_the_prompt_count_survives() {
        let out = distill(b"\x1b]133;A\x07$ \x1b]133;B\x07x\x1b]133;E;x\x07\x1b]133;C\x07");
        assert_eq!(out.windows(8).filter(|w| *w == b"\x1b]133;A\x07").count(), 1);
    }

    /// The other 133 marks are zero-width phase drivers and are consumed.
    #[test]
    fn the_phase_marks_other_than_a_are_consumed() {
        let out = distill(b"\x1b]133;B\x07e\x1b]133;E;e\x07\x1b]133;C\x07o\x1b]133;D;0\x07");
        let text = String::from_utf8_lossy(&out).into_owned();
        assert!(!text.contains("133;B"), "{text:?}");
        assert!(!text.contains("133;C"), "{text:?}");
        assert!(!text.contains("133;D"), "{text:?}");
        assert!(!text.contains("133;E"), "{text:?}");
    }

    /// An empty Enter or a Ctrl-C leaves the span open — its echo is real scrollback.
    #[test]
    fn a_span_closed_by_d_instead_of_c_flushes_its_bytes() {
        let stream = b"\x1b]133;B\x07\r\n\x1b]133;D\x07next";
        assert_eq!(distill(stream), b"\r\nnext");
    }

    #[test]
    fn a_span_closed_by_a_defensive_a_flushes_its_bytes_and_keeps_the_mark() {
        let stream = b"\x1b]133;B\x07cancelled\x1b]133;A\x07";
        assert_eq!(distill(stream), b"cancelled\x1b]133;A\x07");
    }

    /// A mid-stream join: the ring's head cut away the `B`.
    #[test]
    fn an_e_with_no_preceding_b_still_starts_a_span() {
        let stream = b"\x1b]133;E;echo hi\x07leftover\x1b]133;C\x07out";
        assert_eq!(distill(stream), b"echo hi\r\nout");
    }

    #[test]
    fn a_never_closed_span_flushes_at_end_of_stream() {
        assert_eq!(distill(b"\x1b]133;B\x07half typed"), b"half typed");
    }

    #[test]
    fn the_command_field_is_unescaped() {
        let stream = b"\x1b]133;B\x07\x1b]133;E;echo \\x3b \\x5c\x07\x1b]133;C\x07";
        assert_eq!(distill(stream), b"echo ; \\\r\n");
    }

    #[test]
    fn a_lone_backslash_in_the_command_field_survives_literally() {
        let stream = b"\x1b]133;B\x07\x1b]133;E;a\\b\x07\x1b]133;C\x07";
        assert_eq!(distill(stream), b"a\\b\r\n");
    }

    #[test]
    fn an_ordinary_osc_rides_through_in_both_phases() {
        assert_eq!(distill(b"\x1b]0;title\x07"), b"\x1b]0;title\x07");
        // Inside a no-`E` span the OSC is buffered and flushed with the rest.
        let stream = b"\x1b]133;B\x07\x1b]0;title\x07\x1b]133;C\x07";
        assert_eq!(distill(stream), b"\x1b]0;title\x07");
    }

    /// A `133` mark inside a `DCS` body must never flip the phase.
    #[test]
    fn a_mark_inside_a_string_body_is_opaque() {
        let stream = b"\x1bP\x1b]133;B\x07\x1b\\after";
        assert_eq!(distill(stream), stream);
    }

    #[test]
    fn both_osc_terminators_are_accepted() {
        assert_eq!(distill(b"\x1b]133;B\x1b\\x\x1b]133;C\x1b\\"), b"x");
        assert_eq!(distill(b"\x1b]133;B\x07x\x1b]133;C\x07"), b"x");
    }

    /// A bare `ESC` terminates the `OSC` and introduces the next sequence.
    #[test]
    fn an_osc_ended_by_a_bare_esc_still_drives_the_phase() {
        let stream = b"\x1b]133;B\x1b[31mred\x1b]133;C\x07out";
        assert_eq!(distill(stream), b"\x1b[31mredout");
    }

    #[test]
    fn an_over_cap_osc_is_discarded_to_its_terminator() {
        let mut stream = b"\x1b]".to_vec();
        stream.extend(std::iter::repeat_n(b'x', 5000));
        stream.push(0x07);
        stream.extend_from_slice(b"after");
        assert_eq!(distill(&stream), b"after");
    }

    #[test]
    fn a_span_over_the_fallback_cap_falls_back_to_passthrough() {
        let mut stream = b"\x1b]133;B\x07".to_vec();
        let huge = vec![b'p'; INPUT_SPAN_CAP + 16];
        stream.extend_from_slice(&huge);
        // An `E` arrives AFTER the overflow — too late to collapse, and the raw bytes must survive.
        stream.extend_from_slice(b"\x1b]133;E;short\x07\x1b]133;C\x07tail");
        let out = distill(&stream);
        assert!(out.len() > INPUT_SPAN_CAP, "the raw span must not be lost");
        assert!(out.ends_with(b"tail"));
    }

    #[test]
    fn a_stream_with_no_marks_is_returned_unchanged() {
        let stream = b"plain \x1b[1mbold\x1b[0m\r\noutput";
        assert_eq!(distill(stream), stream);
    }

    #[test]
    fn a_dangling_escape_at_end_of_stream_is_emitted_not_dropped() {
        assert_eq!(distill(b"text\x1b"), b"text\x1b");
        assert_eq!(distill(b"text\x1b["), b"text\x1b[");
    }

    #[test]
    fn an_empty_stream_stays_empty() {
        assert_eq!(distill(b""), b"");
    }
}
