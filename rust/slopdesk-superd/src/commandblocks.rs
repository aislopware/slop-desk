//! Segmenting the outbound PTY stream into one record per command.
//!
//! Everything here rides on the OSC 133 shell-integration marks and nothing else — no screen
//! extraction, no heuristics about where a prompt ends:
//!
//! - `A` — prompt start
//! - `B` — command start, which is also prompt end: the user begins typing here
//! - `E` — the explicit command line, a slopdesk extension emitted by the shim's `preexec`
//! - `C` — output start: the command was entered and began running
//! - `D[;exit[;k=v…]]` — the command finished
//!
//! So within one `A`→`D` cycle the bytes between `B` and `C` are the typed line and the bytes
//! between `C` and `D` are the output. The exit code rides on `D`, and the duration is measured
//! from `C` to `D` by the caller's clock.
//!
//! ## The parser is the same shape as the screen's
//!
//! A byte-at-a-time OSC machine: `ESC ]` opens, `BEL` or `ST` closes, an over-cap payload is
//! discarded to its terminator, and a DCS/SOS/PM/APC string swallows its whole body — so an
//! `ESC ] 133 ; …` embedded in such a string can NOT forge a mark. That last one is a security
//! property, not a nicety: without it any program that prints a crafted string sequence could
//! fabricate command boundaries and exit codes in someone else's transcript.
//!
//! ## What it does with output, and the cap
//!
//! Output is captured RAW with control sequences preserved, because a block that cannot be
//! re-rendered or copied faithfully is not worth capturing. The typed command line is the opposite:
//! escapes are stripped, since the marks inside it are detection bytes rather than text. A
//! per-block output cap bounds memory, so a runaway `yes` cannot exhaust the host — past it, bytes
//! are dropped and the block is flagged truncated, while the `A`→`D` machine keeps running so the
//! block still closes cleanly.

use slopdesk_sanitize::escape::unescape_command;

use crate::autoprogress;

/// Per-block output ceiling, 256 KiB.
pub const DEFAULT_OUTPUT_CAP: usize = 256 * 1024;

/// Payload ceiling for a general OSC, matching the screen parser's.
const OSC_CAP: usize = 4096;

/// Payload ceiling for a 133 mark, and also the bound on echoed command bytes.
const CMD_OSC_CAP: usize = 256;

const ESC: u8 = 0x1B;
const BEL: u8 = 0x07;
const LEFT_BRACKET: u8 = b'[';
const RIGHT_BRACKET: u8 = b']';
const BACKSLASH: u8 = b'\\';
const SEMICOLON: u8 = b';';

/// One segmented command: a whole `A`→`D` cycle, or a still-running block.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct CommandBlock {
    /// 0-based index in emission order over this segmenter's lifetime.
    pub index: u64,
    /// The typed command line: escape-stripped and with the shell's echoed trailing newline gone.
    /// Empty when the user entered a blank line.
    pub command_text: String,
    /// The raw output bytes between `C` and `D`, control sequences preserved, capped.
    pub output: Vec<u8>,
    /// The command's `$?` from the `D` payload, when the shell reported one.
    pub exit_code: Option<i32>,
    /// The measured `C`→`D` wall-clock milliseconds, absent while still running.
    pub duration_ms: Option<u32>,
    /// Set once the matching `D` arrived.
    pub complete: bool,
    /// Set when output hit the cap and bytes past it were dropped.
    pub output_truncated: bool,
    /// The 1-based count of prompt CYCLES seen when this block's cycle began — its prompt-row
    /// ordinal in the terminal, and the anchor an outline jump lands on.
    ///
    /// Counts every PRIMARY prompt start, including the empty-Enter and Ctrl-C cycles that never
    /// become a block, so it stays 1:1 with the terminal's own prompt rows. Redraw-immune, because
    /// `A` fires once per cycle from `precmd` while only the `B` inside `$PROMPT` re-fires on a
    /// repaint. `0` means unknown — no `A` was seen before the block opened.
    pub prompt_ordinal: u64,
}

/// A synthetic progress badge the segmenter decided to drive.
///
/// The segmenter does not build wire frames; it says WHAT happened and the owner turns that into
/// one. Keeping the wire vocabulary out of here is what lets this crate stay the byte reader rather
/// than a second place the protocol is spelled.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum SyntheticProgress {
    /// A slow command started — show an indeterminate spinner.
    Indeterminate,
    /// Its block closed — clear the spinner.
    Clear,
}

/// The escape-parser state.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
enum State {
    #[default]
    Ground,
    Escape,
    Csi,
    Osc,
    OscEscape,
    OscDiscard,
    OscDiscardEscape,
    StringConsume,
    StringConsumeEscape,
}

/// Which span the current bytes belong to.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
enum Phase {
    /// Outside any command — before a `B`, or after a `D`. Prompts and banners land here and are
    /// attributed to no block.
    #[default]
    Idle,
    /// Between `B` and `C`: the user is typing.
    Command,
    /// Between `C` and `D`: the command's output.
    Output,
}

/// The per-command segmenter.
#[expect(
    clippy::struct_excessive_bools,
    reason = "the escape parser's position is already a State and the span is already a Phase; these four \
              are independent latches — a block is open, its output hit the cap, a synthetic spinner is up, \
              the program drove its own. Folding them into an enum would assert relationships between them \
              that the mark stream does not have"
)]
#[derive(Debug, Clone)]
pub struct CommandBlockSegmenter {
    output_cap: usize,
    auto_progress_prefixes: Vec<String>,

    state: State,
    osc_buffer: Vec<u8>,
    phase: Phase,

    next_index: u64,
    open_command_bytes: Vec<u8>,
    /// The command line the `133;E` mark reported, when one arrived for this block. Immune to the
    /// line-editor repaints — autosuggestion ghost text, syntax re-colouring, transient prompts —
    /// that turn an echo-reconstructed command into a soup of every glyph painted in the region.
    open_command_explicit: Option<Vec<u8>>,
    open_output_bytes: Vec<u8>,
    open_output_truncated: bool,
    has_open_block: bool,
    running_since_ms: Option<i64>,
    prompt_cycle_count: u64,
    open_prompt_ordinal: u64,

    /// Whether a synthetic spinner is up for the open block, so its clear is emitted exactly once.
    synthetic_spinner_active: bool,
    /// Whether the PROGRAM drove its own OSC 9;4 in this block. A real one suppresses the synthetic
    /// pair so the two never fight over the badge — the program owns it then.
    saw_real_progress_this_block: bool,
    pending_progress: Vec<SyntheticProgress>,
}

impl Default for CommandBlockSegmenter {
    fn default() -> Self {
        Self::new(DEFAULT_OUTPUT_CAP, Vec::new())
    }
}

impl CommandBlockSegmenter {
    /// A fresh segmenter.
    ///
    /// A non-positive `output_cap` means "capture nothing", which no caller can plausibly want, so
    /// `0` falls back to [`DEFAULT_OUTPUT_CAP`] rather than silently disabling capture. An empty
    /// prefix list turns auto-progress off.
    #[must_use]
    pub const fn new(output_cap: usize, auto_progress_prefixes: Vec<String>) -> Self {
        Self {
            output_cap: if output_cap == 0 {
                DEFAULT_OUTPUT_CAP
            } else {
                output_cap
            },
            auto_progress_prefixes,
            state: State::Ground,
            osc_buffer: Vec::new(),
            phase: Phase::Idle,
            next_index: 0,
            open_command_bytes: Vec::new(),
            open_command_explicit: None,
            open_output_bytes: Vec::new(),
            open_output_truncated: false,
            has_open_block: false,
            running_since_ms: None,
            prompt_cycle_count: 0,
            open_prompt_ordinal: 0,
            synthetic_spinner_active: false,
            saw_real_progress_this_block: false,
            pending_progress: Vec::new(),
        }
    }

    /// Segments a stream already fully in hand, in one shot.
    #[must_use]
    pub fn segment(stream: &[u8], now_ms: i64, output_cap: usize) -> Vec<CommandBlock> {
        let mut segmenter = Self::new(output_cap, Vec::new());
        let mut blocks = segmenter.ingest(stream, now_ms);
        blocks.extend(segmenter.finish());
        blocks
    }

    /// Feeds a chunk and answers the blocks that CLOSED in it, in order.
    ///
    /// `now_ms` is the caller's clock reading for this chunk, in milliseconds on whatever epoch it
    /// keeps; the module never reads a clock itself, so a mis-segmentation is reproducible from a
    /// transcript plus the timestamps. State persists across calls, so a stream split at any byte
    /// boundary yields the same blocks as the whole stream at once.
    pub fn ingest(&mut self, bytes: &[u8], now_ms: i64) -> Vec<CommandBlock> {
        let mut completed = Vec::new();
        let mut cursor = 0;
        while let Some(rest) = bytes.get(cursor..) {
            if rest.is_empty() {
                break;
            }
            if self.state != State::Ground {
                // A buffering or classifying state — every byte matters, so step one at a time.
                if let Some(&byte) = rest.first() {
                    self.step(byte, now_ms, &mut completed);
                }
                cursor += 1;
                continue;
            }
            // In ground, a run of non-ESC bytes is a run of content appends with no state change:
            // find it once and append it in one go. Byte-for-byte equivalent to stepping each one,
            // and each byte is examined by at most one scan, so escape-dense input stays linear.
            let run = rest.iter().position(|&byte| byte == ESC).unwrap_or(rest.len());
            if let Some(content) = rest.get(..run).filter(|content| !content.is_empty()) {
                self.append_run(content);
            }
            cursor += run;
            if run < rest.len() {
                self.step(ESC, now_ms, &mut completed);
                cursor += 1;
            }
        }
        completed
    }

    /// Flushes a still-open block as INCOMPLETE — the command is still running, so the caller can
    /// show its partial output. Leaves the segmenter ready for a fresh block.
    pub fn finish(&mut self) -> Vec<CommandBlock> {
        self.take_open_block(false, None, None).into_iter().collect()
    }

    /// A NON-destructive snapshot of the open block, for a metadata update about a running command.
    ///
    /// Only a block that actually STARTED EXECUTING is surfaced. A block still in the command phase
    /// is the current prompt waiting for input, not a running command, and surfacing it puts a
    /// "(no command) running…" row at the top of the panel forever — one per resize, since `B`
    /// re-fires on every prompt redraw. The snapshot carries the index the block WILL get when it
    /// closes.
    #[must_use]
    pub fn peek_open_block(&self) -> Option<CommandBlock> {
        if !self.has_open_block || self.phase != Phase::Output {
            return None;
        }
        Some(CommandBlock {
            index: self.next_index,
            command_text: decode_command(self.current_command_bytes()),
            output: self.open_output_bytes.clone(),
            exit_code: None,
            duration_ms: None,
            complete: false,
            output_truncated: self.open_output_truncated,
            prompt_ordinal: self.open_prompt_ordinal,
        })
    }

    /// The index the next closed block will get, which is also the open block's future index.
    #[must_use]
    pub const fn next_block_index(&self) -> u64 {
        self.next_index
    }

    /// Drains the synthetic badge changes queued at the `C` and `D` marks.
    pub fn drain_auto_progress(&mut self) -> Vec<SyntheticProgress> {
        core::mem::take(&mut self.pending_progress)
    }

    fn step(&mut self, byte: u8, now_ms: i64, completed: &mut Vec<CommandBlock>) {
        match self.state {
            State::Ground => {
                if byte == ESC {
                    self.state = State::Escape;
                } else {
                    self.append_byte(byte);
                }
            },
            State::Escape => {
                match byte {
                    LEFT_BRACKET => {
                        // A colourised command line wraps the typed text in SGR runs, so the WHOLE CSI
                        // — introducer, parameters and final byte — has to be tracked and stripped from
                        // the command text. Returning to ground after the introducer would leak the
                        // `32m`/`0m` bytes as content. Output keeps the sequence verbatim.
                        if self.phase == Phase::Output {
                            self.append_byte(ESC);
                            self.append_byte(byte);
                        }
                        self.state = State::Csi;
                    },
                    RIGHT_BRACKET => {
                        self.state = State::Osc;
                        self.osc_buffer.clear();
                    },
                    // DCS, SOS, PM, APC — swallow the whole body so an embedded 133 cannot forge a
                    // mark. The introducer bytes are not content.
                    b'P' | b'X' | b'^' | b'_' => self.state = State::StringConsume,
                    ESC => self.state = State::Escape,
                    _ => {
                        // Some other escape — a two-byte or nF form. Opaque VT, preserved for output so
                        // the capture stays a faithful stream, stripped from the command span.
                        if self.phase == Phase::Output {
                            self.append_byte(ESC);
                            self.append_byte(byte);
                        }
                        self.state = State::Ground;
                    },
                }
            },
            State::Csi => {
                if self.phase == Phase::Output {
                    self.append_byte(byte);
                }
                match byte {
                    0x40..=0x7E => self.state = State::Ground,
                    // A stray ESC aborts the CSI, exactly as a conformant terminal treats it. The
                    // byte just appended for output is the abort marker, which is faithful.
                    ESC => self.state = State::Escape,
                    _ => {},
                }
            },
            State::Osc => {
                match byte {
                    BEL => {
                        self.finish_osc(now_ms, completed);
                        self.state = State::Ground;
                    },
                    ESC => self.state = State::OscEscape,
                    _ => {
                        self.osc_buffer.push(byte);
                        if self.osc_buffer.len() > OSC_CAP {
                            self.osc_buffer.clear();
                            self.state = State::OscDiscard;
                        }
                    },
                }
            },
            State::OscEscape => {
                self.finish_osc(now_ms, completed);
                if byte == BACKSLASH {
                    self.state = State::Ground;
                } else {
                    self.state = State::Escape;
                    self.step(byte, now_ms, completed);
                }
            },
            State::OscDiscard => {
                match byte {
                    BEL => self.state = State::Ground,
                    ESC => self.state = State::OscDiscardEscape,
                    _ => {},
                }
            },
            State::OscDiscardEscape => {
                if byte == BACKSLASH {
                    self.state = State::Ground;
                } else {
                    self.state = State::Escape;
                    self.step(byte, now_ms, completed);
                }
            },
            State::StringConsume => {
                match byte {
                    BEL => self.state = State::Ground,
                    ESC => self.state = State::StringConsumeEscape,
                    _ => {},
                }
            },
            State::StringConsumeEscape => {
                match byte {
                    BACKSLASH => self.state = State::Ground,
                    ESC => self.state = State::StringConsumeEscape,
                    _ => self.state = State::StringConsume,
                }
            },
        }
    }

    /// Routes one opaque content byte to the current span.
    fn append_byte(&mut self, byte: u8) {
        match self.phase {
            Phase::Idle => {},
            Phase::Command => {
                // A command line is small by nature; the same 256-byte bound the 133 payload uses
                // keeps a pathological stream that never sends `C` from growing it without limit.
                if self.open_command_bytes.len() < CMD_OSC_CAP {
                    self.open_command_bytes.push(byte);
                }
            },
            Phase::Output => {
                if self.open_output_bytes.len() < self.output_cap {
                    self.open_output_bytes.push(byte);
                } else {
                    self.open_output_truncated = true;
                }
            },
        }
    }

    /// The bulk form, reproducing the per-byte rule exactly rather than approximating it.
    ///
    /// The per-byte version appends while under the cap and raises the truncation flag for every
    /// byte it drops, so this appends what fits and raises the flag if anything did not. The
    /// command span has no truncation flag — it stops silently at the cap — and that asymmetry
    /// is kept.
    fn append_run(&mut self, run: &[u8]) {
        match self.phase {
            Phase::Idle => {},
            Phase::Command => {
                let room = CMD_OSC_CAP.saturating_sub(self.open_command_bytes.len());
                if let Some(fits) = run.get(..room.min(run.len())) {
                    self.open_command_bytes.extend_from_slice(fits);
                }
            },
            Phase::Output => {
                let room = self.output_cap.saturating_sub(self.open_output_bytes.len());
                if let Some(fits) = run.get(..room.min(run.len())) {
                    self.open_output_bytes.extend_from_slice(fits);
                }
                if run.len() > room {
                    self.open_output_truncated = true;
                }
            },
        }
    }

    fn finish_osc(&mut self, now_ms: i64, completed: &mut Vec<CommandBlock>) {
        let buffer = core::mem::take(&mut self.osc_buffer);
        let Some(separator) = buffer.iter().position(|&byte| byte == SEMICOLON) else {
            return;
        };
        let ps = buffer
            .get(..separator)
            .and_then(|raw| core::str::from_utf8(raw).ok());
        // Notice a program-emitted OSC 9;4 so the synthetic spinner stands down: the program is
        // driving the badge itself. An allocation-free probe for a body of `4` or `4;…`.
        if ps == Some("9") {
            if buffer.get(separator + 1) == Some(&b'4')
                && matches!(buffer.get(separator + 2), None | Some(&SEMICOLON))
            {
                self.saw_real_progress_this_block = true;
            }
            return;
        }
        if ps != Some("133") {
            return;
        }
        let Ok(payload) = core::str::from_utf8(&buffer) else {
            return;
        };
        let fields: Vec<&str> = payload.split(';').collect();
        let Some(&verb) = fields.get(1) else {
            return;
        };
        // The screen parser ignores a 133 payload over 256 bytes, so a hostile oversized mark is
        // dropped here too. The EXPLICIT command line is the one exception: it legitimately carries
        // a long command and the screen parser ignores `E` entirely, so it is bounded only by the
        // general OSC cap the parser already enforced.
        if verb != "E" && buffer.len() > CMD_OSC_CAP {
            return;
        }

        match verb {
            "A" => self.on_prompt_start(&fields, now_ms, completed),
            "B" => self.on_command_start(now_ms, completed),
            "E" => {
                // Normally `E` arrives with the block already open from `B`; a mid-stream join is
                // tolerated by opening one, so the following `C` still captures output against the
                // reported command.
                if !self.has_open_block {
                    self.start_open_block();
                    self.phase = Phase::Command;
                }
                self.open_command_explicit = Some(
                    fields
                        .get(2)
                        .map(|field| unescape_command(field.as_bytes()))
                        .unwrap_or_default(),
                );
            },
            "C" => self.on_output_start(now_ms),
            "D" => self.on_command_finished(&fields, now_ms, completed),
            _ => {},
        }
    }

    /// `A` — prompt start.
    ///
    /// A block still open here re-prompted without a `D`. Close it as incomplete ONLY if it started
    /// executing: that is a real running command interrupted by a fresh prompt, from a nested shell
    /// or an `ssh` emitting its own marks. A block still in the command phase never ran — an empty
    /// prompt, an empty Enter, a Ctrl-C line abort — so it is DISCARDED and leaves no phantom. The
    /// incomplete close stamps the elapsed time, which is what makes it a distinct final update
    /// rather than one the client keeps showing as running.
    fn on_prompt_start(&mut self, fields: &[&str], now_ms: i64, completed: &mut Vec<CommandBlock>) {
        self.close_or_discard_open(now_ms, completed);
        self.phase = Phase::Idle;
        // Counted AFTER closing the interrupted block, which keeps its own ordinal. A continuation,
        // secondary or right prompt starts no new prompt row, so it consumes no ordinal either.
        if is_primary_prompt_start(fields) {
            self.prompt_cycle_count += 1;
        }
    }

    /// `B` — command start, which is also prompt end.
    ///
    /// The `B` mark lives inside `$PROMPT` as a zero-width sequence, so the shell reprints it on
    /// every prompt redraw — and a remote pane redraws constantly: splits, sidebar toggles, window
    /// drags, transient-prompt hooks. Such a redraw re-fires `B` while still AT the prompt, with
    /// the open block never having seen a `C`. That is the same prompt, not a new command;
    /// closing it would pile up one forever-running "(no command)" phantom per resize.
    ///
    /// So a re-fired `B` in the command phase RE-ARMS the open block: the partial command bytes go
    /// (the redraw reprints the prompt, which was captured as stray command bytes, then re-echoes
    /// the input buffer, which is recaptured cleanly) and the block keeps its identity and index.
    fn on_command_start(&mut self, now_ms: i64, completed: &mut Vec<CommandBlock>) {
        if self.has_open_block && self.phase == Phase::Command {
            self.open_command_bytes.clear();
            return;
        }
        // A `B` with no preceding `A` is tolerated. As in the `A` arm, only a block that executed is
        // closed as incomplete; one that never did is discarded rather than turned into a phantom.
        self.close_or_discard_open(now_ms, completed);
        self.start_open_block();
        self.phase = Phase::Command;
    }

    /// `C` — output start.
    ///
    /// A `C` with no `B` — the very first prompt, or a mid-command join — still opens a block so
    /// the output is captured, with an empty command text.
    fn on_output_start(&mut self, now_ms: i64) {
        if !self.has_open_block {
            self.start_open_block();
        }
        self.running_since_ms = Some(now_ms);
        self.phase = Phase::Output;
        if !self.synthetic_spinner_active
            && !self.saw_real_progress_this_block
            && autoprogress::matches(
                &decode_command(self.current_command_bytes()),
                &self.auto_progress_prefixes,
            )
        {
            self.pending_progress.push(SyntheticProgress::Indeterminate);
            self.synthetic_spinner_active = true;
        }
    }

    /// `D` — command finished.
    ///
    /// Only a block that STARTED EXECUTING is closed. The shim emits `D;$?` from `precmd` on EVERY
    /// prompt cycle, including an empty Enter and a Ctrl-C line abort: those run `precmd` but not
    /// `preexec`, so no `C` fired and the open block still holds the PREVIOUS command's exit code.
    /// Minting a completed block from that would put a red failed "(no command)" row in the panel
    /// every time someone hits Enter on an empty line. It is dropped silently instead, and the
    /// unexecuted block is discarded so a following `A`/`B` opens a fresh one.
    fn on_command_finished(&mut self, fields: &[&str], now_ms: i64, completed: &mut Vec<CommandBlock>) {
        if !self.has_open_block || self.phase != Phase::Output {
            if self.has_open_block {
                self.discard_open_block();
            }
            self.phase = Phase::Idle;
            return;
        }
        let exit = parse_exit(fields);
        let duration = self.running_since_ms.map(|started| duration_ms(started, now_ms));
        self.running_since_ms = None;
        if let Some(block) = self.take_open_block(true, exit, duration) {
            completed.push(block);
        }
        self.phase = Phase::Idle;
    }

    /// Closes an open block that executed, or discards one that did not — the shared arm of `A` and
    /// `B`.
    fn close_or_discard_open(&mut self, now_ms: i64, completed: &mut Vec<CommandBlock>) {
        if !self.has_open_block {
            return;
        }
        if self.phase == Phase::Output {
            let duration = self.running_since_ms.map(|started| duration_ms(started, now_ms));
            if let Some(block) = self.take_open_block(false, None, duration) {
                completed.push(block);
            }
        } else {
            self.discard_open_block();
        }
    }

    fn start_open_block(&mut self) {
        self.open_command_bytes.clear();
        self.open_command_explicit = None;
        self.open_output_bytes.clear();
        self.open_output_truncated = false;
        self.has_open_block = true;
        self.open_prompt_ordinal = self.prompt_cycle_count;
        // Spinner suppression is strictly per-block.
        self.synthetic_spinner_active = false;
        self.saw_real_progress_this_block = false;
    }

    /// Drops the open block WITHOUT emitting it and WITHOUT consuming an index.
    ///
    /// For a prompt cycle that never executed. Such a cycle is no command at all, so it must leave
    /// no phantom — neither a completed one nor a forever-running incomplete one — and it claims no
    /// block index, so the next real command reuses the slot.
    fn discard_open_block(&mut self) {
        // A block that never reached `C` never armed the spinner, so no clear is owed; the flags are
        // reset anyway so the next block starts clean.
        self.synthetic_spinner_active = false;
        self.saw_real_progress_this_block = false;
        self.has_open_block = false;
        self.running_since_ms = None;
        self.open_command_bytes.clear();
        self.open_command_explicit = None;
        self.open_output_bytes.clear();
        self.open_output_truncated = false;
    }

    /// Materialises and clears the open block.
    fn take_open_block(
        &mut self,
        complete: bool,
        exit_code: Option<i32>,
        duration_ms: Option<u32>,
    ) -> Option<CommandBlock> {
        if !self.has_open_block {
            return None;
        }
        // Clear a synthetic spinner as its block closes — completed or interrupted — unless the
        // program drove its own badge, in which case the program owns the clear too.
        if self.synthetic_spinner_active && !self.saw_real_progress_this_block {
            self.pending_progress.push(SyntheticProgress::Clear);
        }
        self.synthetic_spinner_active = false;
        self.saw_real_progress_this_block = false;
        let index = self.next_index;
        self.next_index += 1;
        let block = CommandBlock {
            index,
            command_text: decode_command(self.current_command_bytes()),
            output: core::mem::take(&mut self.open_output_bytes),
            exit_code,
            duration_ms,
            complete,
            output_truncated: self.open_output_truncated,
            prompt_ordinal: self.open_prompt_ordinal,
        };
        self.has_open_block = false;
        self.running_since_ms = None;
        self.open_command_bytes.clear();
        self.open_command_explicit = None;
        self.open_output_truncated = false;
        Some(block)
    }

    /// The command bytes to surface: the explicit `133;E` line when there was one, else the echoed
    /// `B`→`C` bytes as a fallback for a shell without the shim, an older shim, or a dropped mark.
    fn current_command_bytes(&self) -> &[u8] {
        self.open_command_explicit
            .as_deref()
            .unwrap_or(&self.open_command_bytes)
    }
}

/// Whether a `133;A[;k=…]` starts a PRIMARY prompt — the only kind that begins a new prompt row.
///
/// Kind absent, or `k=i`. A continuation (`k=c`), a secondary/PS2 (`k=s`) and a right prompt
/// (`k=r`) all sit on an existing row, so none of them consumes an ordinal.
fn is_primary_prompt_start(fields: &[&str]) -> bool {
    fields
        .iter()
        .skip(2)
        .find(|field| field.starts_with("k="))
        .is_none_or(|kind| *kind == "k=i")
}

/// Decodes the typed command line: strict UTF-8, with the shell's echoed trailing CR/LF removed.
///
/// A non-UTF-8 line decodes to nothing rather than to replacement characters — the same answer the
/// screen parser gives, and the right one, since a command line that is not text is a hostile
/// stream rather than a command.
fn decode_command(bytes: &[u8]) -> String {
    let trimmed = bytes
        .iter()
        .rposition(|&byte| byte != b'\n' && byte != b'\r')
        .map_or(0, |last| last + 1);
    bytes
        .get(..trimmed)
        .and_then(|raw| core::str::from_utf8(raw).ok())
        .unwrap_or_default()
        .to_owned()
}

/// The exit code from `133;D[;<exit>[;k=v…]]`, tolerating a trailing `=value`.
///
/// Shared with the sniffer, which reads the SAME mark off the same stream: two readers quietly
/// disagreeing about what an exit field means is exactly the drift worth spending a `pub` on.
#[must_use]
pub fn parse_exit(fields: &[&str]) -> Option<i32> {
    let raw = fields.get(2)?;
    let head = raw.split('=').next().unwrap_or(raw);
    // The low 32 bits, reinterpreted — a shell that reports an out-of-range `$?` gets truncated
    // rather than dropped, because the field WAS reported and losing it entirely would read as
    // "the shell said nothing".
    let truncated = u32::try_from(head.parse::<i64>().ok()?.cast_unsigned() & 0xFFFF_FFFF).ok()?;
    Some(truncated.cast_signed())
}

/// The non-negative elapsed milliseconds, clamped at both ends.
///
/// A clock that went backwards reports `0` rather than a wrapped duration, and a command running
/// longer than 49 days saturates rather than folding over — in both cases the wrong-but-bounded
/// answer beats a number the UI would render as nonsense.
#[must_use]
pub fn duration_ms(start_ms: i64, end_ms: i64) -> u32 {
    u32::try_from(end_ms.saturating_sub(start_ms).max(0)).unwrap_or(u32::MAX)
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use super::{CommandBlock, CommandBlockSegmenter, DEFAULT_OUTPUT_CAP, SyntheticProgress, decode_command};

    /// A full cycle: prompt, typed line, output, finish.
    fn cycle(command: &str, output: &str, exit: i32) -> String {
        format!(
            "\u{1B}]133;A\u{7}$ \
             \u{1B}]133;B\u{7}{command}\r\n\u{1B}]133;C\u{7}{output}\u{1B}]133;D;{exit}\u{7}"
        )
    }

    fn segment(stream: &str) -> Vec<CommandBlock> {
        CommandBlockSegmenter::segment(stream.as_bytes(), 0, DEFAULT_OUTPUT_CAP)
    }

    #[test]
    fn one_cycle_yields_one_block_with_its_command_output_and_exit() {
        let blocks = segment(&cycle("ls -la", "a\nb\n", 0));
        assert_eq!(blocks.len(), 1);
        let block = blocks.first().expect("one block");
        assert_eq!(block.index, 0);
        assert_eq!(block.command_text, "ls -la");
        assert_eq!(block.output, b"a\nb\n");
        assert_eq!(block.exit_code, Some(0));
        assert!(block.complete);
        assert!(!block.output_truncated);
        assert_eq!(block.prompt_ordinal, 1);
    }

    #[test]
    fn splitting_the_stream_at_every_byte_yields_identical_blocks() {
        let stream = format!("{}{}", cycle("echo hi", "hi\n", 0), cycle("false", "", 1));
        let whole = segment(&stream);
        let mut segmenter = CommandBlockSegmenter::new(DEFAULT_OUTPUT_CAP, Vec::new());
        let mut piecewise = Vec::new();
        for byte in stream.as_bytes() {
            piecewise.extend(segmenter.ingest(&[*byte], 0));
        }
        piecewise.extend(segmenter.finish());
        assert_eq!(whole, piecewise);
        assert_eq!(whole.len(), 2);
    }

    #[test]
    fn the_exit_code_survives_a_trailing_key_value_and_a_negative_value() {
        let blocks = segment(&format!(
            "{}{}",
            "\u{1B}]133;C\u{7}x\u{1B}]133;D;130;k=v\u{7}", "\u{1B}]133;C\u{7}y\u{1B}]133;D;-1\u{7}"
        ));
        let codes: Vec<Option<i32>> = blocks.iter().map(|block| block.exit_code).collect();
        assert_eq!(codes, vec![Some(130), Some(-1)]);
        // A `D` with no code at all reports none rather than guessing zero.
        let none = segment("\u{1B}]133;C\u{7}z\u{1B}]133;D\u{7}");
        assert_eq!(none.first().and_then(|block| block.exit_code), None);
    }

    #[test]
    fn control_sequences_are_preserved_in_output_and_stripped_from_the_command() {
        let stream = "\u{1B}]133;A\u{7}\u{1B}]133;B\u{7}\u{1B}[32mgit\u{1B}[0m \
                      status\r\n\u{1B}]133;C\u{7}\u{1B}[1mbold\u{1B}[0m\u{1B}]133;D;0\u{7}";
        let blocks = segment(stream);
        let block = blocks.first().expect("one block");
        assert_eq!(block.command_text, "git status");
        assert_eq!(block.output, b"\x1B[1mbold\x1B[0m");
    }

    #[test]
    fn an_embedded_mark_inside_a_string_sequence_cannot_forge_a_block() {
        // The same bytes, wrapped in an APC body and not. Unwrapped they open a block and close it;
        // wrapped, the body is swallowed to its terminator and the marks never happen.
        let marks = "\u{1B}]133;C\u{1B}\\stolen\u{1B}]133;D;0\u{7}";
        assert_eq!(segment(marks).len(), 1, "the same bytes DO segment in the open");
        assert!(segment(&format!("\u{1B}_{marks}")).is_empty());
        // And the parser is still live for a real cycle afterwards.
        assert_eq!(segment(&format!("\u{1B}_{marks}{}", cycle("ok", "", 0))).len(), 1);
    }

    #[test]
    fn an_oversized_mark_is_ignored_but_an_explicit_command_line_may_be_long() {
        let padding = "x".repeat(400);
        // A >256-byte A/B/C/D mark is dropped, so nothing segments.
        assert!(segment(&format!("\u{1B}]133;C;{padding}\u{7}out\u{1B}]133;D;0\u{7}")).is_empty());
        // `E` is the exception: it legitimately carries a long command.
        let long_command = "echo ".to_owned() + &padding;
        let blocks = segment(&format!(
            "\u{1B}]133;B\u{7}\u{1B}]133;E;{long_command}\u{7}\u{1B}]133;C\u{7}o\u{1B}]133;D;0\u{7}"
        ));
        assert_eq!(
            blocks.first().map(|block| block.command_text.as_str()),
            Some(long_command.as_str())
        );
    }

    #[test]
    fn the_explicit_mark_beats_the_echo_which_a_redraw_would_have_polluted() {
        let stream = "\u{1B}]133;A\u{7}\u{1B}]133;B\u{7}gi\u{8} \u{8}git stat\u{1B}[Kus\r\n\u{1B}]133;E;git \
                      status\u{7}\u{1B}]133;C\u{7}\u{1B}]133;D;0\u{7}";
        let blocks = segment(stream);
        assert_eq!(
            blocks.first().map(|block| block.command_text.as_str()),
            Some("git status")
        );
    }

    #[test]
    fn an_empty_enter_leaves_no_phantom_block() {
        // `precmd` fires `D` with the PREVIOUS exit code, but `preexec` never ran, so no `C`.
        let stream = format!(
            "{}\u{1B}]133;D;0\u{7}\u{1B}]133;A\u{7}\u{1B}]133;B\u{7}\u{1B}]133;D;7\u{7}",
            cycle("ls", "out\n", 0)
        );
        let blocks = segment(&stream);
        assert_eq!(blocks.len(), 1, "only the real command: {blocks:?}");
        assert_eq!(blocks.first().map(|block| block.exit_code), Some(Some(0)));
    }

    #[test]
    fn a_prompt_redraw_re_arms_the_open_block_instead_of_minting_one_per_resize() {
        let mut stream = "\u{1B}]133;A\u{7}$ \u{1B}]133;B\u{7}par".to_owned();
        for _ in 0..20 {
            stream.push_str("\u{1B}]133;B\u{7}$ partial");
        }
        stream.push_str("\u{1B}]133;C\u{7}o\u{1B}]133;D;0\u{7}");
        let blocks = segment(&stream);
        assert_eq!(blocks.len(), 1, "{} phantoms", blocks.len().saturating_sub(1));
        let block = blocks.first().expect("one block");
        assert_eq!(block.index, 0, "the redraws consumed no index");
        assert_eq!(block.command_text, "$ partial");
    }

    #[test]
    fn a_running_command_interrupted_by_a_fresh_prompt_closes_incomplete_with_a_duration() {
        let mut segmenter = CommandBlockSegmenter::new(DEFAULT_OUTPUT_CAP, Vec::new());
        segmenter.ingest(b"\x1B]133;A\x07\x1B]133;B\x07ssh box\x1B]133;C\x07partial", 1_000);
        let closed = segmenter.ingest(b"\x1B]133;A\x07", 1_250);
        assert_eq!(closed.len(), 1);
        let block = closed.first().expect("one block");
        assert!(!block.complete, "no D arrived");
        assert_eq!(block.duration_ms, Some(250), "stamped, so it is a final update");
        assert_eq!(block.output, b"partial");
    }

    #[test]
    fn the_prompt_ordinal_counts_every_primary_cycle_and_no_continuation() {
        let stream = format!(
            "{}\u{1B}]133;A;k=c\u{7}\u{1B}]133;A;k=s\u{7}\u{1B}]133;A;k=r\u{7}{}",
            cycle("first", "", 0),
            cycle("second", "", 0)
        );
        let ordinals: Vec<u64> = segment(&stream)
            .iter()
            .map(|block| block.prompt_ordinal)
            .collect();
        assert_eq!(ordinals, vec![1, 2], "the three secondary marks counted none");
        // An explicit primary kind still counts.
        let explicit = segment("\u{1B}]133;A;k=i\u{7}\u{1B}]133;B\u{7}x\u{1B}]133;C\u{7}\u{1B}]133;D;0\u{7}");
        assert_eq!(explicit.first().map(|block| block.prompt_ordinal), Some(1));
    }

    #[test]
    fn a_mid_stream_join_captures_output_with_no_command_and_an_unknown_ordinal() {
        let blocks = segment("\u{1B}]133;C\u{7}late output\u{1B}]133;D;0\u{7}");
        let block = blocks.first().expect("one block");
        assert_eq!(block.command_text, "");
        assert_eq!(block.output, b"late output");
        assert_eq!(block.prompt_ordinal, 0, "unknown, so the jump is skipped");
    }

    #[test]
    fn output_past_the_cap_is_dropped_and_the_block_still_closes() {
        let flood = "y\n".repeat(200);
        let mut segmenter = CommandBlockSegmenter::new(16, Vec::new());
        segmenter.ingest(b"\x1B]133;B\x07yes\x1B]133;C\x07", 0);
        segmenter.ingest(flood.as_bytes(), 0);
        let closed = segmenter.ingest(b"\x1B]133;D;0\x07", 0);
        let block = closed.first().expect("the block still closes");
        assert_eq!(block.output.len(), 16);
        assert!(block.output_truncated);
        assert!(block.complete);
    }

    #[test]
    fn the_cap_is_the_same_whether_the_bytes_arrive_in_a_run_or_one_at_a_time() {
        let body = "abcdefghijklmnop".repeat(4);
        let framed = format!("\u{1B}]133;C\u{7}{body}\u{1B}]133;D;0\u{7}");
        let bulk = CommandBlockSegmenter::segment(framed.as_bytes(), 0, 20);
        let mut segmenter = CommandBlockSegmenter::new(20, Vec::new());
        let mut drip = Vec::new();
        for byte in framed.as_bytes() {
            drip.extend(segmenter.ingest(&[*byte], 0));
        }
        assert_eq!(bulk, drip);
        assert_eq!(bulk.first().map(|block| block.output.len()), Some(20));
        assert_eq!(bulk.first().map(|block| block.output_truncated), Some(true));
    }

    #[test]
    fn a_zero_cap_falls_back_to_the_default_rather_than_capturing_nothing() {
        let mut segmenter = CommandBlockSegmenter::new(0, Vec::new());
        let blocks = segmenter.ingest(b"\x1B]133;C\x07hello\x1B]133;D;0\x07", 0);
        assert_eq!(
            blocks.first().map(|block| block.output.as_slice()),
            Some(&b"hello"[..])
        );
    }

    #[test]
    fn peeking_surfaces_only_a_command_that_is_actually_running() {
        let mut segmenter = CommandBlockSegmenter::new(DEFAULT_OUTPUT_CAP, Vec::new());
        segmenter.ingest(b"\x1B]133;A\x07\x1B]133;B\x07sle", 0);
        assert_eq!(segmenter.peek_open_block(), None, "still at the prompt");
        segmenter.ingest(b"ep 10\x1B]133;C\x07so far", 0);
        let peeked = segmenter.peek_open_block().expect("running now");
        assert_eq!(peeked.index, segmenter.next_block_index());
        assert_eq!(peeked.command_text, "sleep 10");
        assert_eq!(peeked.output, b"so far");
        assert!(!peeked.complete);
        assert_eq!(peeked.duration_ms, None);
        // Peeking does not disturb segmentation.
        let closed = segmenter.ingest(b" done\x1B]133;D;0\x07", 0);
        assert_eq!(
            closed.first().map(|block| block.output.as_slice()),
            Some(&b"so far done"[..])
        );
    }

    #[test]
    fn finishing_flushes_a_running_block_as_incomplete_and_only_once() {
        let mut segmenter = CommandBlockSegmenter::new(DEFAULT_OUTPUT_CAP, Vec::new());
        segmenter.ingest(b"\x1B]133;B\x07top\x1B]133;C\x07frame", 0);
        let flushed = segmenter.finish();
        assert_eq!(flushed.len(), 1);
        assert_eq!(flushed.first().map(|block| block.complete), Some(false));
        assert!(segmenter.finish().is_empty());
    }

    #[test]
    fn a_matching_command_drives_a_synthetic_spinner_and_exactly_one_clear() {
        let mut segmenter = CommandBlockSegmenter::new(DEFAULT_OUTPUT_CAP, vec!["git push".to_owned()]);
        segmenter.ingest(b"\x1B]133;B\x07git push origin\x1B]133;C\x07", 0);
        assert_eq!(segmenter.drain_auto_progress(), vec![
            SyntheticProgress::Indeterminate
        ]);
        assert!(segmenter.drain_auto_progress().is_empty(), "the drain clears it");
        segmenter.ingest(b"done\x1B]133;D;0\x07", 0);
        assert_eq!(segmenter.drain_auto_progress(), vec![SyntheticProgress::Clear]);
    }

    #[test]
    fn a_program_driving_its_own_badge_suppresses_the_synthetic_pair() {
        let mut segmenter = CommandBlockSegmenter::new(DEFAULT_OUTPUT_CAP, vec!["curl".to_owned()]);
        // The real 9;4 arrives before `C`, so the segmenter stands down entirely.
        segmenter.ingest(b"\x1B]133;B\x07curl x\x1B]9;4;1;30\x07\x1B]133;C\x07", 0);
        assert!(segmenter.drain_auto_progress().is_empty());
        segmenter.ingest(b"\x1B]133;D;0\x07", 0);
        assert!(
            segmenter.drain_auto_progress().is_empty(),
            "no orphan clear either"
        );
    }

    #[test]
    fn an_unmatched_command_and_an_empty_prefix_list_both_emit_nothing() {
        for prefixes in [vec!["git push".to_owned()], Vec::new()] {
            let mut segmenter = CommandBlockSegmenter::new(DEFAULT_OUTPUT_CAP, prefixes);
            segmenter.ingest(b"\x1B]133;B\x07ls\x1B]133;C\x07\x1B]133;D;0\x07", 0);
            assert!(segmenter.drain_auto_progress().is_empty());
        }
    }

    #[test]
    fn an_interrupted_spinner_block_still_gets_its_clear() {
        let mut segmenter = CommandBlockSegmenter::new(DEFAULT_OUTPUT_CAP, vec!["rsync".to_owned()]);
        segmenter.ingest(b"\x1B]133;B\x07rsync a b\x1B]133;C\x07", 0);
        assert_eq!(segmenter.drain_auto_progress(), vec![
            SyntheticProgress::Indeterminate
        ]);
        segmenter.ingest(b"\x1B]133;A\x07", 0);
        assert_eq!(segmenter.drain_auto_progress(), vec![SyntheticProgress::Clear]);
    }

    #[test]
    fn the_command_line_drops_its_echoed_newline_and_a_non_utf8_line_entirely() {
        assert_eq!(decode_command(b"ls -la\r\n"), "ls -la");
        assert_eq!(decode_command(b"\r\n"), "");
        assert_eq!(decode_command(b""), "");
        assert_eq!(
            decode_command(b"echo \xFF\xFE"),
            "",
            "hostile bytes are not a command"
        );
    }

    #[test]
    fn an_st_terminated_mark_segments_the_same_as_a_bel_terminated_one() {
        let bel = segment(&cycle("ls", "x", 0));
        let st = segment(
            "\u{1B}]133;A\u{1B}\\$ \u{1B}]133;B\u{1B}\\ls\r\n\u{1B}]133;C\u{1B}\\x\u{1B}]133;D;0\u{1B}\\",
        );
        assert_eq!(bel, st);
    }

    #[test]
    fn an_over_cap_osc_is_discarded_to_its_terminator_without_wedging_the_parser() {
        let flood = "t".repeat(5000);
        let stream = format!("\u{1B}]0;{flood}\u{7}{}", cycle("ls", "x", 0));
        assert_eq!(segment(&stream).len(), 1);
    }

    #[test]
    fn a_title_or_an_unknown_subcommand_segments_nothing() {
        assert!(segment("\u{1B}]0;a title\u{7}plain output").is_empty());
        assert!(segment("\u{1B}]133;Z\u{7}\u{1B}]133;Q;9\u{7}").is_empty());
        assert!(segment("no escapes at all").is_empty());
    }
}
