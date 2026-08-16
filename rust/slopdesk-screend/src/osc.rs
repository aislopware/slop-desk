//! Passive OSC capture for the detection engine: the latest OSC 0/2 window title and the latest
//! OSC 9 progress payload, retained across chunks.
//!
//! Ported from Swift `AgentOscTracker` (herdr `AgentOscStateTracker` + `OscStreamCollector`).
//! It moved for the same reason the grid did: it reads the SAME PTY bytes the grid is fed, and
//! hostd was walking every chunk three times — once through this socket, once here, and once in
//! the sync-frame tracker. Now one request carries the bytes and all three walks happen on this
//! side of it.
//!
//! Nothing here affects rendering: the title is evidence about the agent, not screen state.

/// Bound on one OSC body (herdr `MAX_BODY_BYTES`).
const MAX_BODY_BYTES: usize = 4096;
/// Retained-string cap in `char`s (herdr `AGENT_OSC_MAX_CHARS`).
const MAX_CHARS: usize = 256;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum State {
    Ground,
    Escape,
    Body,
    BodyEscape,
    IgnoringString,
    IgnoringStringEscape,
    Discarding,
    DiscardingEscape,
}

/// The retained OSC evidence for one pane.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OscTracker {
    state: State,
    body: Vec<u8>,
    title: String,
    progress: String,
}

impl Default for OscTracker {
    fn default() -> Self {
        Self::new()
    }
}

impl OscTracker {
    /// A tracker that has seen nothing.
    #[must_use]
    pub const fn new() -> Self {
        Self {
            state: State::Ground,
            body: Vec::new(),
            title: String::new(),
            progress: String::new(),
        }
    }

    /// The last non-empty OSC 0/2 title, or `""`. An explicitly empty title clears it.
    #[must_use]
    pub fn title(&self) -> &str {
        &self.title
    }

    /// The last OSC 9 payload after the `9;`, sanitised, or `""`.
    #[must_use]
    pub fn progress(&self) -> &str {
        &self.progress
    }

    /// Drops the retained title/progress so a NEW foreground agent cannot inherit the previous
    /// process's OSC evidence. In-flight parse state is kept on purpose: a sequence spanning the
    /// change finalises normally, attributed to the new agent.
    pub fn clear_retained(&mut self) {
        self.title.clear();
        self.progress.clear();
    }

    /// Folds one chunk of raw PTY output.
    pub fn observe(&mut self, bytes: &[u8]) {
        for &byte in bytes {
            self.step(byte);
        }
    }

    fn step(&mut self, byte: u8) {
        match self.state {
            State::Ground => {
                if byte == 0x1B {
                    self.state = State::Escape;
                }
            },
            State::Escape => {
                match byte {
                    b']' => {
                        self.body.clear();
                        self.state = State::Body;
                    },
                    0x1B => self.state = State::Escape,
                    b'P' | b'X' | b'^' | b'_' => self.state = State::IgnoringString,
                    _ => self.state = State::Ground,
                }
            },
            State::Body => {
                match byte {
                    0x07 => self.finish(),
                    0x1B => self.state = State::BodyEscape,
                    _ => self.push(byte),
                }
            },
            State::BodyEscape => self.step_body_escape(byte),
            State::IgnoringString => {
                if byte == 0x1B {
                    self.state = State::IgnoringStringEscape;
                }
            },
            State::IgnoringStringEscape => {
                if byte == b'\\' {
                    self.state = State::Ground;
                } else if byte != 0x1B {
                    self.state = State::IgnoringString;
                }
            },
            State::Discarding => {
                if byte == 0x07 {
                    self.state = State::Ground;
                } else if byte == 0x1B {
                    self.state = State::DiscardingEscape;
                }
            },
            State::DiscardingEscape => {
                if byte == b'\\' {
                    self.state = State::Ground;
                } else if byte != 0x1B {
                    self.state = State::Discarding;
                }
            },
        }
    }

    /// `ESC` inside a body: `\` closes it (ST), anything else is a literal `ESC` in the payload.
    /// `push` can flip the state to `Discarding` on overflow, so every branch re-reads it.
    fn step_body_escape(&mut self, byte: u8) {
        match byte {
            b'\\' => self.finish(),
            0x07 => {
                self.push(0x1B);
                if self.state == State::Body {
                    self.finish();
                } else {
                    self.state = State::Ground;
                }
            },
            0x1B => {
                self.push(0x1B);
                if self.state == State::Body {
                    self.state = State::BodyEscape;
                } else if self.state == State::Discarding {
                    self.state = State::DiscardingEscape;
                }
            },
            _ => {
                self.push(0x1B);
                if self.state == State::Body {
                    self.push(byte);
                }
            },
        }
    }

    fn push(&mut self, byte: u8) {
        self.body.push(byte);
        if self.body.len() > MAX_BODY_BYTES {
            self.body.clear();
            self.state = State::Discarding;
        } else {
            self.state = State::Body;
        }
    }

    fn finish(&mut self) {
        let body = std::mem::take(&mut self.body);
        self.state = State::Ground;
        // Split at the first ';' → (command, payload). No ';' at all is not an agent OSC.
        let Some(separator) = body.iter().position(|&byte| byte == b';') else {
            return;
        };
        let (command, payload) = body.split_at(separator);
        let payload = &payload[1..];
        if command == b"0" || command == b"2" {
            self.title = sanitize(payload);
        } else if command == b"9" {
            self.progress = sanitize(payload);
        }
    }
}

/// Lossy UTF-8 decode, control chars dropped, capped at [`MAX_CHARS`] chars.
///
/// Lossy on purpose (upstream `from_utf8_lossy` parity): a failable decode would drop a whole
/// title over one bad byte, and a title is evidence we would rather have partially.
fn sanitize(payload: &[u8]) -> String {
    String::from_utf8_lossy(payload)
        .chars()
        .filter(|c| !c.is_control())
        .take(MAX_CHARS)
        .collect()
}

#[cfg(test)]
mod tests {
    use super::{MAX_BODY_BYTES, MAX_CHARS, OscTracker};

    #[test]
    fn a_bel_terminated_title_is_retained() {
        let mut tracker = OscTracker::new();
        tracker.observe(b"\x1b]0;\xe2\x9c\xb3 Claude\x07");
        assert_eq!(tracker.title(), "✳ Claude");
        assert_eq!(tracker.progress(), "");
    }

    #[test]
    fn an_st_terminated_title_is_retained_too() {
        let mut tracker = OscTracker::new();
        tracker.observe(b"\x1b]2;window\x1b\\");
        assert_eq!(tracker.title(), "window");
    }

    #[test]
    fn a_sequence_split_across_chunks_reassembles() {
        let mut tracker = OscTracker::new();
        tracker.observe(b"\x1b]0;par");
        assert_eq!(tracker.title(), "", "nothing until the terminator");
        tracker.observe(b"tial\x07");
        assert_eq!(tracker.title(), "partial");
    }

    #[test]
    fn osc_nine_lands_in_progress_and_leaves_the_title_alone() {
        let mut tracker = OscTracker::new();
        tracker.observe(b"\x1b]0;title\x07\x1b]9;4;0;\x07");
        assert_eq!(tracker.title(), "title");
        assert_eq!(tracker.progress(), "4;0;");
    }

    #[test]
    fn an_explicitly_empty_title_clears_the_retained_one() {
        let mut tracker = OscTracker::new();
        tracker.observe(b"\x1b]0;busy\x07");
        tracker.observe(b"\x1b]0;\x07");
        assert_eq!(tracker.title(), "");
    }

    #[test]
    fn a_body_with_no_semicolon_is_not_an_agent_osc() {
        let mut tracker = OscTracker::new();
        tracker.observe(b"\x1b]0;kept\x07\x1b]nonsense\x07");
        assert_eq!(tracker.title(), "kept");
    }

    #[test]
    fn dcs_and_friends_are_skipped_opaquely() {
        let mut tracker = OscTracker::new();
        // A `]0;fake` INSIDE a DCS body must not become a title.
        tracker.observe(b"\x1bP\x1b]0;fake\x07\x1b\\");
        assert_eq!(tracker.title(), "");
        tracker.observe(b"\x1b]0;real\x07");
        assert_eq!(tracker.title(), "real");
    }

    #[test]
    fn an_oversized_body_is_discarded_without_growing() {
        let mut tracker = OscTracker::new();
        let mut hostile = b"\x1b]0;".to_vec();
        hostile.extend(std::iter::repeat_n(b'x', MAX_BODY_BYTES + 100));
        hostile.push(0x07);
        tracker.observe(&hostile);
        assert_eq!(tracker.title(), "", "the overflowing sequence is dropped whole");
        // …and the parser recovers for the next one.
        tracker.observe(b"\x1b]0;after\x07");
        assert_eq!(tracker.title(), "after");
    }

    #[test]
    fn a_retained_string_is_capped_in_chars_and_control_free() {
        let mut tracker = OscTracker::new();
        let mut sequence = b"\x1b]0;".to_vec();
        sequence.extend(std::iter::repeat_n(b'y', MAX_CHARS + 50));
        sequence.push(0x07);
        tracker.observe(&sequence);
        assert_eq!(tracker.title().chars().count(), MAX_CHARS);

        tracker.observe(b"\x1b]0;a\x01b\x07");
        assert_eq!(tracker.title(), "ab");
    }

    #[test]
    fn clearing_retained_keeps_the_in_flight_parse() {
        let mut tracker = OscTracker::new();
        tracker.observe(b"\x1b]0;old\x07\x1b]0;spa");
        tracker.clear_retained();
        assert_eq!(tracker.title(), "");
        tracker.observe(b"nning\x07");
        assert_eq!(tracker.title(), "spanning", "the split sequence still finalises");
    }

    #[test]
    fn invalid_utf8_degrades_rather_than_dropping_the_title() {
        let mut tracker = OscTracker::new();
        tracker.observe(b"\x1b]0;a\xffb\x07");
        assert_eq!(tracker.title(), "a\u{fffd}b");
    }
}
