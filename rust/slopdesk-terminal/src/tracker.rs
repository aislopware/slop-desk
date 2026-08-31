//! The terminal-mode tracker: a byte-at-a-time parser over the host→client OUTPUT stream.
//!
//! It tracks the mode ([`ShellPrompt`](TerminalMode::ShellPrompt) vs
//! [`AltScreen`](TerminalMode::AltScreen)) and emits OSC 133 command-boundary events.
//!
//! ## Why a hand-rolled mini-parser (not a full VT parser)
//! The deleted libghostty fork's SURFACE was opaque — there was no parsed grid or alt-screen action
//! to read through it (docs/14 §"Open questions libghostty", which already flagged that the
//! underlying `libghostty-vt` DOES carry an active-screen fact the surface never exposed). This
//! crate stays `forbid(unsafe_code)` with no engine dependency at all (see `lib.rs`'s guarantees),
//! so even with `libghostty-vt` now the engine (`docs/68`), there is still no engine handle here to
//! query — we sniff the byte stream ourselves for the handful of markers we need (DECSET/DECRST
//! 1049/47/1047 + OSC 133 A/B/C/D) and treat everything else as opaque content, confirmed still the
//! plan in `docs/68` §5.3. We deliberately do **not** model the full screen.
//!
//! ## Robustness to split sequences (the #1 thing that silently breaks)
//! This is a true byte-at-a-time state machine. An escape sequence may be split across arbitrary
//! chunk boundaries (mid-`ESC`, mid-`CSI`, mid-`OSC`) — TCP gives us no alignment. The machine
//! holds its partial state between [`consume`](TerminalModeTracker::consume) calls and only fires a
//! marker once the full sequence has arrived, so feeding the same stream one byte at a time
//! produces byte-for-byte identical events to feeding it in one chunk.
//!
//! ## Tolerance
//! Unknown CSI / OSC sequences are consumed cleanly up to their terminator and ignored — they never
//! break mode tracking. Arbitrary content (including high-bit / UTF-8 bytes) passes through. We
//! never misclassify a partial sequence as content and we never get "stuck": an unterminated OSC is
//! bounded by a sane cap so a malformed stream cannot wedge the parser forever.
//!
//! ## Fast path (the terminal-output ingest hot path)
//! In the two "skim" states the fast path scans to the next byte that can change anything and
//! routes ONLY that byte through the transition table — it decides WHICH bytes reach the table, it
//! never replaces a transition. The scan itself is WORD-at-a-time (see [`skim`]), which is not a
//! detail: a ground chunk carries no `ESC` at all in the common case, so deciding that IS what
//! `consume` costs. Measured through the door on a 3 177-byte ground chunk, a byte loop spent
//! **1.06 µs of a 1.12 µs call** inside this scan; the word skim takes that call to **0.172 µs**,
//! a 6.5× (docs/55 §4c). In [`Ground`](State::Ground) the only interesting byte is `ESC`
//! (this grammar ignores a ground `BEL` — content is skipped wholesale); in
//! [`StringConsume`](State::StringConsume) it is `ESC` or `BEL` (terminator), with the `BEL` scan
//! bounded to the prefix before the next `ESC` (the measured O(n²) guard: total scanned bytes stay
//! ≤ 2× the input on escape-dense streams). All other states are buffering / classification states
//! where every byte matters — they step per-byte.

use crate::mode::{TerminalMode, TerminalModeEvent};

const ESC: u8 = 0x1B;
const BEL: u8 = 0x07;
const LEFT_BRACKET: u8 = b'[';
const RIGHT_BRACKET: u8 = b']';
const BACKSLASH: u8 = b'\\';
// String-sequence introducers: DCS `ESC P`, SOS `ESC X`, PM `ESC ^`, APC `ESC _`.
const DCS: u8 = b'P';
const SOS: u8 = b'X';
const PM: u8 = b'^';
const APC: u8 = b'_';

/// Hard cap on a buffered CSI run. The markers we care about are tiny; anything longer is not one
/// of ours, and an unbounded buffer is what a hostile stream would aim at.
const CSI_CAP: usize = 64;

/// Hard cap on a buffered OSC payload, for the same reason.
const OSC_CAP: usize = 256;

/// Where the byte-at-a-time machine currently is.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
enum State {
    /// Outside any escape sequence (passing through opaque content).
    #[default]
    Ground,
    /// Saw `ESC` (`0x1B`); waiting for the next byte to classify.
    Escape,
    /// Inside a CSI sequence (`ESC[`). Collecting parameter/intermediate bytes until a final byte
    /// in `0x40..=0x7E`.
    Csi,
    /// Inside an OSC sequence (`ESC]`). Collecting the payload until `BEL` or `ST` (`ESC\`).
    Osc,
    /// Inside an OSC and the previous byte was `ESC` — waiting to see if it is the `\` that
    /// completes an `ST` terminator, or a new sequence start.
    OscEscape,
    /// Inside a DCS/SOS/PM/APC string sequence: swallow the body to ST/BEL, tracking nothing. An
    /// embedded `ESC[?1049h` / `ESC]133;…` in a string body must NOT flip the mode — a conformant
    /// terminal treats the whole string as opaque. Unlike OSC, an embedded non-`\` ESC stays INSIDE
    /// the string (it does not start a new sequence), so this never re-classifies.
    StringConsume,
    /// Inside a string sequence and the previous byte was `ESC` (possible `ST` = `ESC\`).
    StringConsumeEscape,
}

/// The incremental parser: feed it output chunks, read the mode, take the events.
#[derive(Debug, Clone, Default)]
pub struct TerminalModeTracker {
    mode: TerminalMode,
    bracketed_paste_active: bool,
    cursor_keys_application: bool,
    state: State,
    /// Accumulated bytes of the CSI parameter/intermediate run (without the leading `ESC[`).
    /// Bounded; an overlong CSI is abandoned.
    csi_buffer: Vec<u8>,
    /// Accumulated OSC payload bytes (without the leading `ESC]` or the terminator). Bounded; an
    /// overlong OSC is abandoned (we only care about the short `133;…`).
    osc_buffer: Vec<u8>,
}

impl TerminalModeTracker {
    /// A tracker at a shell prompt, in ground state, with empty buffers.
    #[must_use]
    pub const fn new() -> Self {
        Self {
            mode: TerminalMode::ShellPrompt,
            bracketed_paste_active: false,
            cursor_keys_application: false,
            state: State::Ground,
            csi_buffer: Vec::new(),
            osc_buffer: Vec::new(),
        }
    }

    /// The current terminal mode.
    #[must_use]
    pub const fn mode(&self) -> TerminalMode {
        self.mode
    }

    /// TRUE while the foreground program has bracketed-paste mode (DECSET `?2004h`) enabled — set
    /// on `ESC[?2004h`, cleared on `ESC[?2004l`.
    ///
    /// Independent of [`mode`](Self::mode) (a shell prompt enables it; a TUI may too). It emits NO
    /// event, unlike alt-screen: it is a passive flag the paste-protection pre-check reads to skip
    /// the confirmation sheet when the program frames the paste as an inert bracketed block
    /// (matching `ghostty`'s own `clipboard-paste-bracketed-safe`).
    #[must_use]
    pub const fn bracketed_paste_active(&self) -> bool {
        self.bracketed_paste_active
    }

    /// TRUE while the foreground program has DECCKM (application cursor keys, DECSET `?1h`)
    /// enabled.
    ///
    /// Same passive-flag contract as [`bracketed_paste_active`](Self::bracketed_paste_active). Read
    /// by the iOS hand-rolled key encoder to pick SS3 (`ESC O A`) over CSI (`ESC [ A`) arrows. The
    /// deleted libghostty fork's macOS surface owned true DECCKM state itself and never needed this
    /// flag (docs/29) — that is why only iOS reads it here.
    #[must_use]
    pub const fn cursor_keys_application(&self) -> bool {
        self.cursor_keys_application
    }

    /// Returns the tracker to its initial state, emitting no events.
    ///
    /// Call at a SESSION boundary: a reconnect always brings a fresh host shell, so a mode (or
    /// partial-sequence parse state) carried over from the dead session is a lie — a session that
    /// dropped inside vim leaves [`AltScreen`](TerminalMode::AltScreen) latched (a fresh shell
    /// never emits DECRST 1049), and a drop mid-DCS leaves the string-consume state swallowing
    /// the new session's real markers.
    pub fn reset(&mut self) {
        self.state = State::Ground;
        self.mode = TerminalMode::ShellPrompt;
        self.bracketed_paste_active = false;
        self.cursor_keys_application = false;
        self.csi_buffer = Vec::new();
        self.osc_buffer = Vec::new();
    }

    /// Feeds a chunk of output bytes and returns the marker events it produced, in order. Safe to
    /// call with chunks split at any byte boundary.
    pub fn consume(&mut self, bytes: &[u8]) -> Vec<TerminalModeEvent> {
        let mut events = Vec::new();
        let mut index = 0;
        while index < bytes.len() {
            match self.state {
                State::Ground => {
                    // FAST PATH: in ground only ESC can change anything — content (including BEL)
                    // is ignored for mode tracking. Skip to the next ESC.
                    match find(bytes, index, bytes.len(), ESC) {
                        Some(offset) => {
                            self.step(ESC, &mut events); // ground ESC → Escape
                            index = offset + 1;
                        },
                        None => index = bytes.len(),
                    }
                },
                State::StringConsume => {
                    // FAST PATH: only ESC (possible ST start) and BEL (terminator) matter; every
                    // other byte is opaque string body. Route only the FIRST interesting byte
                    // through the table. The BEL scan is bounded to the prefix
                    // BEFORE the next ESC — an unbounded scan re-run on every
                    // re-entry degrades to O(n²) on escape-dense streams.
                    let escape_at = find(bytes, index, bytes.len(), ESC).unwrap_or(bytes.len());
                    if let Some(bell_at) = find(bytes, index, escape_at, BEL) {
                        self.step(BEL, &mut events); // terminator → Ground
                        index = bell_at + 1;
                    } else if escape_at < bytes.len() {
                        self.step(ESC, &mut events); // → StringConsumeEscape
                        index = escape_at + 1;
                    } else {
                        index = bytes.len();
                    }
                },
                // Buffering / classification states: every byte matters — step per-byte.
                State::Escape | State::Csi | State::Osc | State::OscEscape | State::StringConsumeEscape => {
                    if let Some(&byte) = bytes.get(index) {
                        self.step(byte, &mut events);
                    }
                    index += 1;
                },
            }
        }
        events
    }

    fn step(&mut self, byte: u8, events: &mut Vec<TerminalModeEvent>) {
        match self.state {
            State::Ground => {
                if byte == ESC {
                    self.state = State::Escape;
                }
                // else: opaque content byte — ignored for mode tracking.
            },
            State::Escape => {
                match byte {
                    LEFT_BRACKET => {
                        self.state = State::Csi;
                        self.csi_buffer.clear();
                    },
                    RIGHT_BRACKET => {
                        self.state = State::Osc;
                        self.osc_buffer.clear();
                    },
                    // A DCS/SOS/PM/APC string body is opaque to a conformant terminal — swallow it to
                    // ST/BEL so an embedded `ESC[?1049h` / `ESC]133;…` cannot flip the tracked mode.
                    DCS | SOS | PM | APC => self.state = State::StringConsume,
                    // `ESC ESC` — stay in escape, waiting to classify the second ESC.
                    ESC => self.state = State::Escape,
                    // Some other 2-byte / nF escape (e.g. `ESC c`, `ESC (B`). Not a marker we track;
                    // return to ground. Single-byte intermediates are rare and not load-bearing here.
                    _ => self.state = State::Ground,
                }
            },
            State::Csi => {
                // The final byte of a CSI is in `0x40..=0x7E`; everything before it is a parameter
                // (`0x30..=0x3F`) or intermediate (`0x20..=0x2F`) byte.
                self.csi_buffer.push(byte);
                if (0x40..=0x7E).contains(&byte) {
                    self.handle_csi(events);
                    self.state = State::Ground;
                } else if self.csi_buffer.len() > CSI_CAP {
                    // Overlong — not one of ours; abandon and resync at ground. We do not
                    // re-interpret the overflow byte; a real terminator resets us and worst case we
                    // drop one bogus CSI, never a tracked marker.
                    self.state = State::Ground;
                }
            },
            State::Osc => {
                match byte {
                    BEL => {
                        self.handle_osc(events);
                        self.state = State::Ground;
                    },
                    // Possible start of an `ST` terminator (`ESC\`).
                    ESC => self.state = State::OscEscape,
                    _ => {
                        self.osc_buffer.push(byte);
                        if self.osc_buffer.len() > OSC_CAP {
                            self.state = State::Ground;
                        }
                    },
                }
            },
            State::OscEscape => {
                // Either way the OSC is over: `ESC\` is a real ST, and a stray ESC terminates it
                // too.
                self.handle_osc(events);
                if byte == BACKSLASH {
                    self.state = State::Ground;
                } else {
                    // The `ESC` was not an ST terminator, and the ESC we already consumed may
                    // itself introduce a NEW escape sequence — so re-enter
                    // Escape (not Ground) and classify this byte as that
                    // sequence's introducer. Returning to Ground here would orphan
                    // the ESC and let the next marker's introducer (`[` / `]`) be parsed as plain
                    // content, losing the whole following sequence.
                    self.state = State::Escape;
                    self.step(byte, events);
                }
            },
            State::StringConsume => {
                match byte {
                    // Terminators are ST/BEL; an embedded ESC that is not `\` stays INSIDE the opaque
                    // string (it never starts a new tracked sequence).
                    BEL => self.state = State::Ground,
                    ESC => self.state = State::StringConsumeEscape,
                    _ => {},
                }
            },
            State::StringConsumeEscape => {
                match byte {
                    BACKSLASH => self.state = State::Ground,
                    // Another ESC — could still begin ST; keep waiting.
                    ESC => self.state = State::StringConsumeEscape,
                    // A lone ESC inside the body — swallow it and keep consuming.
                    _ => self.state = State::StringConsume,
                }
            },
        }
    }

    /// CSI handling — DECSET/DECRST private modes 1049 / 47 / 1047, plus the two passive flags.
    fn handle_csi(&mut self, events: &mut Vec<TerminalModeEvent>) {
        // We only care about `?<n>h` / `?<n>l` (DEC private set/reset).
        let Some(&final_byte) = self.csi_buffer.last() else {
            return;
        };
        if final_byte != b'h' && final_byte != b'l' {
            return;
        }
        if self.csi_buffer.first() != Some(&b'?') {
            return;
        }
        // Parameters between `?` and the final byte, split on `;`.
        let end = self.csi_buffer.len().saturating_sub(1);
        let parameter_bytes = self.csi_buffer.get(1..end).unwrap_or_default();
        // A LOSSY decode is required: the machine appends arbitrary (including non-UTF-8) bytes to
        // the buffer, and a failable decode would return nothing on such bytes — dropping
        // parameters that a lossy decode still yields.
        let text = String::from_utf8_lossy(parameter_bytes);
        let parameters: Vec<i64> = text
            .split(';')
            .filter(|field| !field.is_empty())
            .filter_map(|field| field.parse::<i64>().ok())
            .collect();

        let is_set = final_byte == b'h';
        // DECSET/DECRST 2004 — bracketed paste. A passive flag only (no event). Handled
        // independently of alt-screen: a single CSI can carry both (e.g. `?1049;2004h`).
        if parameters.contains(&2004) {
            self.bracketed_paste_active = is_set;
        }
        // DECSET/DECRST 1 — DECCKM application cursor keys. Same passive-flag contract.
        if parameters.contains(&1) {
            self.cursor_keys_application = is_set;
        }
        // One alt-screen marker per CSI is enough; the three modes are equivalent here.
        if !parameters.iter().any(|mode| matches!(*mode, 1049 | 47 | 1047)) {
            return;
        }
        if is_set {
            if self.mode != TerminalMode::AltScreen {
                self.mode = TerminalMode::AltScreen;
                events.push(TerminalModeEvent::EnteredAltScreen);
            }
        } else if self.mode != TerminalMode::ShellPrompt {
            self.mode = TerminalMode::ShellPrompt;
            events.push(TerminalModeEvent::ExitedAltScreen);
        }
    }

    /// OSC handling — the OSC 133 prompt marks.
    fn handle_osc(&self, events: &mut Vec<TerminalModeEvent>) {
        // Lossy for the same reason as the CSI parameters.
        let payload = String::from_utf8_lossy(&self.osc_buffer);
        // Expected: `133;A` | `133;B` | `133;C` | `133;D` | `133;D;<exit>` (+ extra `;k=v`).
        let fields: Vec<&str> = payload.split(';').collect();
        if fields.len() < 2 || fields.first() != Some(&"133") {
            return;
        }
        match fields.get(1).copied() {
            Some("A") => events.push(TerminalModeEvent::PromptStart),
            Some("B") => events.push(TerminalModeEvent::CommandStart),
            Some("C") => events.push(TerminalModeEvent::CommandStarted),
            Some("D") => {
                // `;D` or `;D;<exit>[;…]`. The exit code, if present, is the third field — and only
                // its first non-empty `=`-separated part, so a `k=v` annotation reads as `k` and
                // simply fails to parse rather than being mistaken for a code.
                let exit_code = fields.get(2).and_then(|field| {
                    field
                        .split('=')
                        .find(|part| !part.is_empty())
                        .unwrap_or(field)
                        .parse::<i64>()
                        .ok()
                });
                events.push(TerminalModeEvent::CommandFinished { exit_code });
            },
            // Unknown OSC 133 subcommand — ignored cleanly.
            _ => {},
        }
    }
}

/// The index of `needle` in `haystack[from..to]`, or `None`. The bounded form is what keeps the
/// string-consume `BEL` scan from re-walking the same suffix on every re-entry.
fn find(haystack: &[u8], from: usize, to: usize, needle: u8) -> Option<usize> {
    let window = haystack.get(from..to.min(haystack.len()))?;
    skim(window, needle).map(|at| from + at)
}

/// A byte of a `u64` word, repeated — the low bit of each lane.
const LANE_ONES: u128 = 0x0101_0101_0101_0101_0101_0101_0101_0101;

/// The high bit of each lane.
const LANE_HIGHS: u128 = 0x8080_8080_8080_8080_8080_8080_8080_8080;

/// How many bytes the skim tests per step.
const LANES: usize = 16;

/// The offset of the first `needle` in `window`, or `None` — a WORD-at-a-time skim.
///
/// This is the whole cost of the ingest hot path and it is worth saying why it is not a byte loop.
/// A ground-state chunk contains no `ESC` at all in the overwhelmingly common case, so `consume`
/// spends essentially all of its time here deciding that; `iter().position` does not vectorise
/// (its early exit is per element), so a plain byte loop ran the hot path at a MEASURED 3.0 GB/s.
/// Testing sixteen lanes at once with the classic zero-byte identity — `(w - ones) & !w & highs` is
/// non-zero exactly when some lane of `w` is zero, and `w` here is the word XOR the needle in every
/// lane — reaches 18.2 GB/s on the same bytes, a measured 6.1×, in safe Rust with no dependency.
///
/// A hit inside a word falls back to a byte scan OF THAT WORD, so the identity is allowed to be
/// conservative: an over-eager word simply costs sixteen comparisons and the skim continues. Under
/// `LANES` bytes there are no words at all and this is the byte loop it replaced, which is what
/// keeps the escape-dense `StringConsume` re-entry no slower than before.
fn skim(window: &[u8], needle: u8) -> Option<usize> {
    let lanes = u128::from_ne_bytes([needle; LANES]);
    let (words, tail) = window.as_chunks::<LANES>();
    for (index, word) in words.iter().enumerate() {
        let xored = u128::from_ne_bytes(*word) ^ lanes;
        if xored.wrapping_sub(LANE_ONES) & !xored & LANE_HIGHS != 0
            && let Some(at) = word.iter().position(|&byte| byte == needle)
        {
            return Some(index * LANES + at);
        }
    }
    tail.iter()
        .position(|&byte| byte == needle)
        .map(|at| words.len() * LANES + at)
}

#[cfg(test)]
mod tests {
    use super::TerminalModeTracker;
    use crate::mode::{TerminalMode, TerminalModeEvent};

    fn events(stream: &str) -> Vec<TerminalModeEvent> {
        TerminalModeTracker::new().consume(stream.as_bytes())
    }

    /// Feeds the same stream one byte at a time — the chunking-invariance oracle.
    fn events_byte_at_a_time(stream: &str) -> (Vec<TerminalModeEvent>, TerminalMode) {
        let mut tracker = TerminalModeTracker::new();
        let mut produced = Vec::new();
        for byte in stream.as_bytes() {
            produced.extend(tracker.consume(&[*byte]));
        }
        (produced, tracker.mode())
    }

    #[test]
    fn plain_content_produces_nothing_and_stays_at_the_shell_prompt() {
        let mut tracker = TerminalModeTracker::new();
        assert!(tracker.consume(b"hello world\n$ ").is_empty());
        assert_eq!(tracker.mode(), TerminalMode::ShellPrompt);
    }

    #[test]
    fn entering_and_leaving_the_alt_screen_fires_once_each() {
        let mut tracker = TerminalModeTracker::new();
        assert_eq!(tracker.consume(b"\x1B[?1049h"), [
            TerminalModeEvent::EnteredAltScreen
        ]);
        assert_eq!(tracker.mode(), TerminalMode::AltScreen);
        // A repeat set is not a transition.
        assert!(tracker.consume(b"\x1B[?1049h").is_empty());
        assert_eq!(tracker.consume(b"\x1B[?1049l"), [
            TerminalModeEvent::ExitedAltScreen
        ]);
        assert_eq!(tracker.mode(), TerminalMode::ShellPrompt);
        assert!(tracker.consume(b"\x1B[?1049l").is_empty());
    }

    #[test]
    fn the_legacy_alt_screen_modes_are_equivalent() {
        for sequence in ["\u{1B}[?47h", "\u{1B}[?1047h", "\u{1B}[?1049h"] {
            assert_eq!(
                events(sequence),
                [TerminalModeEvent::EnteredAltScreen],
                "{sequence}"
            );
        }
    }

    #[test]
    fn a_mixed_parameter_csi_carries_both_the_flag_and_the_mode() {
        let mut tracker = TerminalModeTracker::new();
        assert_eq!(tracker.consume(b"\x1B[?1049;2004h"), [
            TerminalModeEvent::EnteredAltScreen
        ]);
        assert!(tracker.bracketed_paste_active());
        assert_eq!(tracker.consume(b"\x1B[?2004l"), []);
        assert!(!tracker.bracketed_paste_active());
        assert_eq!(
            tracker.mode(),
            TerminalMode::AltScreen,
            "2004 alone never moves the mode"
        );
    }

    #[test]
    fn the_passive_flags_emit_no_events() {
        let mut tracker = TerminalModeTracker::new();
        assert!(tracker.consume(b"\x1B[?1h").is_empty());
        assert!(tracker.cursor_keys_application());
        assert!(tracker.consume(b"\x1B[?1l").is_empty());
        assert!(!tracker.cursor_keys_application());
    }

    #[test]
    fn every_osc_133_mark_decodes() {
        assert_eq!(events("\u{1B}]133;A\u{07}"), [TerminalModeEvent::PromptStart]);
        assert_eq!(events("\u{1B}]133;B\u{07}"), [TerminalModeEvent::CommandStart]);
        assert_eq!(events("\u{1B}]133;C\u{07}"), [TerminalModeEvent::CommandStarted]);
        assert_eq!(events("\u{1B}]133;D\u{07}"), [
            TerminalModeEvent::CommandFinished { exit_code: None }
        ]);
        assert_eq!(events("\u{1B}]133;D;0\u{07}"), [
            TerminalModeEvent::CommandFinished { exit_code: Some(0) }
        ]);
        assert_eq!(events("\u{1B}]133;D;127;aid=7\u{07}"), [
            TerminalModeEvent::CommandFinished { exit_code: Some(127) }
        ]);
        // An annotation where the code belongs reads as its key and simply fails to parse.
        assert_eq!(events("\u{1B}]133;D;aid=7\u{07}"), [
            TerminalModeEvent::CommandFinished { exit_code: None }
        ]);
        // An unknown subcommand is ignored cleanly.
        assert!(events("\u{1B}]133;Z\u{07}").is_empty());
        // A non-133 OSC is not ours.
        assert!(events("\u{1B}]0;a title\u{07}").is_empty());
    }

    #[test]
    fn an_osc_terminated_by_st_decodes_like_one_terminated_by_bel() {
        assert_eq!(events("\u{1B}]133;A\u{1B}\\"), [TerminalModeEvent::PromptStart]);
    }

    #[test]
    fn a_stray_escape_inside_an_osc_does_not_orphan_the_next_sequence() {
        // The OSC is terminated by the stray ESC, and the ESC still introduces the CSI that follows
        // — returning to ground here would parse `[` as content and lose the whole
        // alt-screen marker.
        assert_eq!(events("\u{1B}]133;A\u{1B}[?1049h"), [
            TerminalModeEvent::PromptStart,
            TerminalModeEvent::EnteredAltScreen
        ]);
    }

    #[test]
    fn a_string_sequence_body_is_opaque() {
        for introducer in ['P', 'X', '^', '_'] {
            let stream = format!("\u{1B}{introducer}\u{1B}[?1049h\u{1B}\\");
            assert!(events(&stream).is_empty(), "{introducer}");
        }
        // …and a BEL terminates one too.
        assert!(events("\u{1B}P\u{1B}]133;A\u{07}").is_empty());
    }

    #[test]
    fn a_string_body_that_ends_lets_the_next_marker_through() {
        assert_eq!(events("\u{1B}Pq junk \u{1B}\\\u{1B}[?1049h"), [
            TerminalModeEvent::EnteredAltScreen
        ]);
    }

    #[test]
    fn an_overlong_csi_is_abandoned_rather_than_buffered() {
        let padding = "1;".repeat(super::CSI_CAP);
        let mut tracker = TerminalModeTracker::new();
        assert!(
            tracker
                .consume(format!("\u{1B}[?{padding}1049h").as_bytes())
                .is_empty()
        );
        // …and the parser is not wedged: the next real marker still fires.
        assert_eq!(tracker.consume(b"\x1B[?1049h"), [
            TerminalModeEvent::EnteredAltScreen
        ]);
    }

    #[test]
    fn an_overlong_osc_is_abandoned_rather_than_buffered() {
        let padding = "x".repeat(super::OSC_CAP + 1);
        let mut tracker = TerminalModeTracker::new();
        assert!(
            tracker
                .consume(format!("\u{1B}]133;A{padding}\u{07}").as_bytes())
                .is_empty()
        );
        assert_eq!(tracker.consume(b"\x1B]133;A\x07"), [
            TerminalModeEvent::PromptStart
        ]);
    }

    #[test]
    fn feeding_one_byte_at_a_time_produces_identical_events() {
        let stream = "before\u{1B}[?1049h\u{1B}]133;A\u{07}mid\u{1B}]133;D;3\u{1B}\\\u{1B}Popaque\u{1B}[?\
                      1049l\u{1B}\\tail\u{1B}[?1049l";
        let (streamed, streamed_mode) = events_byte_at_a_time(stream);
        let mut whole = TerminalModeTracker::new();
        let bulk = whole.consume(stream.as_bytes());
        assert_eq!(streamed, bulk);
        assert_eq!(streamed_mode, whole.mode());
        assert_eq!(bulk, [
            TerminalModeEvent::EnteredAltScreen,
            TerminalModeEvent::PromptStart,
            TerminalModeEvent::CommandFinished { exit_code: Some(3) },
            TerminalModeEvent::ExitedAltScreen,
        ]);
    }

    #[test]
    fn every_split_point_of_a_marker_decodes_identically() {
        let stream = "a\u{1B}[?1049hb\u{1B}]133;D;9\u{07}c";
        let bulk = events(stream);
        for split in 0..=stream.len() {
            let mut tracker = TerminalModeTracker::new();
            let Some((head, tail)) = stream.as_bytes().split_at_checked(split) else {
                continue;
            };
            let mut produced = tracker.consume(head);
            produced.extend(tracker.consume(tail));
            assert_eq!(produced, bulk, "split at {split}");
        }
    }

    #[test]
    fn a_reset_forgets_the_mode_and_the_partial_sequence() {
        let mut tracker = TerminalModeTracker::new();
        tracker.consume(b"\x1B[?1049h\x1BP half a string");
        assert_eq!(tracker.mode(), TerminalMode::AltScreen);
        tracker.reset();
        assert_eq!(tracker.mode(), TerminalMode::ShellPrompt);
        // The half-open string body is gone, so the next marker is seen rather than swallowed.
        assert_eq!(tracker.consume(b"\x1B]133;A\x07"), [
            TerminalModeEvent::PromptStart
        ]);
    }

    #[test]
    fn a_ground_bel_is_content_not_a_terminator() {
        let mut tracker = TerminalModeTracker::new();
        assert!(tracker.consume(b"ding\x07dong").is_empty());
        assert_eq!(tracker.consume(b"\x1B[?1049h"), [
            TerminalModeEvent::EnteredAltScreen
        ]);
    }

    #[test]
    fn non_utf8_bytes_pass_through_without_wedging_the_parser() {
        let mut tracker = TerminalModeTracker::new();
        assert!(tracker.consume(&[0xFF, 0xFE, 0x80, 0x00]).is_empty());
        assert_eq!(tracker.consume(b"\x1B[?1049h"), [
            TerminalModeEvent::EnteredAltScreen
        ]);
        // A non-UTF-8 parameter run decodes lossily and simply names no mode.
        assert!(tracker.consume(&[0x1B, b'[', b'?', 0xFF, b'h']).is_empty());
    }

    #[test]
    fn a_doubled_escape_still_classifies_the_sequence_that_follows() {
        assert_eq!(events("\u{1B}\u{1B}[?1049h"), [
            TerminalModeEvent::EnteredAltScreen
        ]);
    }

    #[test]
    fn a_partial_sequence_at_the_end_of_a_chunk_never_misfires() {
        let mut tracker = TerminalModeTracker::new();
        assert!(tracker.consume(b"\x1B[?10").is_empty());
        assert_eq!(tracker.mode(), TerminalMode::ShellPrompt);
        assert_eq!(tracker.consume(b"49h"), [TerminalModeEvent::EnteredAltScreen]);
        assert_eq!(tracker.mode(), TerminalMode::AltScreen);
    }

    #[test]
    fn unknown_csi_sequences_do_not_break_tracking() {
        let stream = concat!(
            "\u{1B}[2J",        // clear screen
            "\u{1B}[38;5;201m", // 256-colour SGR
            "\u{1B}[1;31;42m",  // SGR combo
            "\u{1B}[?2004h",    // bracketed paste ON — DEC private, NOT alt-screen
            "\u{1B}[?25l",      // hide cursor — DEC private, NOT alt-screen
            "\u{1B}[?1049h",    // the one we DO track
        );
        let mut tracker = TerminalModeTracker::new();
        assert_eq!(tracker.consume(stream.as_bytes()), [
            TerminalModeEvent::EnteredAltScreen
        ]);
        assert_eq!(tracker.mode(), TerminalMode::AltScreen);
    }

    #[test]
    fn an_unterminated_osc_abutting_a_csi_does_not_swallow_it() {
        // `ESC]133` with no terminator, directly followed by `ESC[?1049h`. The stray ESC ends the
        // bogus OSC, but it ALSO introduces the alt-screen CSI — that marker must not be dropped.
        let stream = "\u{1B}]133\u{1B}[?1049h";
        assert_eq!(events(stream), [TerminalModeEvent::EnteredAltScreen]);
        // …at every chunk boundary.
        for split in 0..=stream.len() {
            let mut tracker = TerminalModeTracker::new();
            let Some((head, tail)) = stream.as_bytes().split_at_checked(split) else {
                continue;
            };
            let mut produced = tracker.consume(head);
            produced.extend(tracker.consume(tail));
            assert_eq!(
                produced,
                [TerminalModeEvent::EnteredAltScreen],
                "split at {split}"
            );
            assert_eq!(tracker.mode(), TerminalMode::AltScreen, "split at {split}");
        }
    }

    #[test]
    fn an_unterminated_osc_abutting_another_osc_does_not_swallow_it() {
        assert_eq!(events("\u{1B}]133;A\u{1B}]133;B\u{07}"), [
            TerminalModeEvent::PromptStart,
            TerminalModeEvent::CommandStart
        ]);
    }

    #[test]
    fn an_unterminated_osc_then_a_string_introducer_then_a_bell_fires_once() {
        // `ESC]133;A` then `ESC X` (SOS) then `BEL`. The A-mark fires when the stray ESC ends the
        // OSC; the SOS body is then terminated by the BEL. No spurious or dropped markers.
        let mut tracker = TerminalModeTracker::new();
        assert_eq!(tracker.consume(b"\x1B]133;A\x1BX\x07"), [
            TerminalModeEvent::PromptStart
        ]);
        assert_eq!(tracker.mode(), TerminalMode::ShellPrompt);
    }

    #[test]
    fn a_double_escape_then_a_backslash_still_terminates_the_string() {
        // `ESC]133;A` then `ESC ESC \`. The first ESC enters osc-escape; the second (not `\`) ends
        // the OSC and re-enters escape; the `\` is then a lone nF-escape final, consumed cleanly.
        assert_eq!(events("\u{1B}]133;A\u{1B}\u{1B}\\"), [
            TerminalModeEvent::PromptStart
        ]);
    }

    #[test]
    fn a_string_body_cannot_flip_the_passive_flags_either() {
        let mut tracker = TerminalModeTracker::new();
        tracker.consume(b"\x1BP\x1B[?1h\x1B[?2004h\x1B\\");
        assert!(!tracker.cursor_keys_application());
        assert!(!tracker.bracketed_paste_active());
    }

    /// The word-at-a-time skim against the byte loop it replaced, at EVERY length across the lane
    /// boundary and EVERY needle position within each.
    ///
    /// This is the differential the optimisation owes. The two halves it can get wrong are both
    /// off-by-a-lane: an offset reported relative to the word rather than the window, and a tail
    /// shorter than `LANES` whose bytes are never tested at all. Walking the whole cross product is
    /// affordable here — 200 lengths × their positions is a few tens of thousands of scans — and it
    /// is the only form that pins BOTH, because a fixed-length case agrees with itself whichever
    /// lane width the constant later becomes.
    #[test]
    fn the_word_skim_answers_exactly_what_a_byte_loop_would() {
        const CANARY: u8 = b'.';
        for length in 0..(super::LANES * 8 + 3) {
            let clean = vec![CANARY; length];
            assert_eq!(
                super::skim(&clean, super::ESC),
                clean.iter().position(|&byte| byte == super::ESC),
                "no needle at all, length {length}"
            );
            for at in 0..length {
                let mut haystack = clean.clone();
                // A second needle AFTER the first: the answer is the FIRST, and a skim that tested
                // lanes without ordering them could return either.
                haystack
                    .iter_mut()
                    .skip(at)
                    .step_by(3)
                    .for_each(|byte| *byte = super::ESC);
                assert_eq!(
                    super::skim(&haystack, super::ESC),
                    haystack.iter().position(|&byte| byte == super::ESC),
                    "length {length}, first needle at {at}"
                );
            }
        }
    }

    /// The bounded form's two offsets are the window's, not the buffer's.
    ///
    /// `find` is called with a `from` the ground scan has already advanced past and a `to` the
    /// string-consume scan clamps to the next `ESC`; a skim that answered in window coordinates
    /// would place every marker `from` bytes early, and one that ignored `to` would find the `BEL`
    /// of the NEXT sequence.
    #[test]
    fn the_bounded_find_answers_in_the_haystacks_own_coordinates() {
        let haystack = b"................\x07................\x1B\x07";
        assert_eq!(super::find(haystack, 0, haystack.len(), super::BEL), Some(16));
        assert_eq!(super::find(haystack, 17, haystack.len(), super::BEL), Some(34));
        assert_eq!(
            super::find(haystack, 17, 33, super::BEL),
            None,
            "the bound excludes the later BEL"
        );
        assert_eq!(
            super::find(haystack, 0, usize::MAX, super::ESC),
            Some(33),
            "a `to` past the end clamps rather than reading past it"
        );
        assert_eq!(
            super::find(haystack, haystack.len() + 1, usize::MAX, super::ESC),
            None
        );
    }
}
