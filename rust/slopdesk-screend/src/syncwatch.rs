//! Whether the bytes fed so far end INSIDE an open synchronized update (DEC private mode 2026).
//!
//! Ported from Swift `AgentSyncFrameTracker`. Distinct from [`crate::syncframe`], which COLLAPSES
//! completed frames out of a replay stream: this one answers a different question about a live
//! stream — is the grid the program has drawn a finished frame, or half of one?
//!
//! ## Why detection needs it
//! An inline TUI repaints by rewriting its widget region in place, erasing lines (`CSI K`) before
//! it writes their replacement. Mode 2026 is the program SAYING SO. The detection scan reads the
//! grid on a ~300 ms timer against whatever bytes the PTY read loop happened to hand over, which
//! lands mid-frame whenever a repaint spans a chunk boundary — and the rule ladder then reads a
//! dialog with its footer momentarily missing and calls a blocked pane IDLE. (User-reported
//! 2026-08-11: Tab-switching between `AskUserQuestion` questions walked the mark idle ↔ blocked,
//! once per press.)
//!
//! Deferring costs nothing: the model is cumulative, so the next scan sees the closed frame.
//!
//! 2026 is a FLAG, not a counter — the spec does not define nesting and terminals treat the last
//! `h`/`l` as the state. `ESC c` (RIS) closes any open frame.

// `params[1..]` behind a check that a first parameter was parsed.
#![expect(
    clippy::indexing_slicing,
    reason = "the first parameter is known present before the cut"
)]

/// Bound on one CSI's collected parameter bytes, so a hostile stream cannot grow this.
const MAX_PARAM_BYTES: usize = 64;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum State {
    Ground,
    Escape,
    /// Collecting a CSI's parameter + intermediate bytes.
    Csi,
    /// Inside an OSC/DCS/SOS/PM/APC body, skipped opaquely.
    Str,
    /// Saw `ESC` inside a string body — a `\` completes ST.
    StrEscape,
}

/// The open/closed frame state for one pane.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SyncFrameTracker {
    state: State,
    params: Vec<u8>,
    /// TRUE while the CSI being collected overflowed [`MAX_PARAM_BYTES`] (its final byte is then
    /// ignored — a truncated parameter list must not be read as a mode set).
    params_overflowed: bool,
    /// TRUE when the current string body is an OSC (BEL also terminates it).
    string_is_osc: bool,
    frame_open: bool,
    generation: u64,
}

impl Default for SyncFrameTracker {
    fn default() -> Self {
        Self::new()
    }
}

impl SyncFrameTracker {
    /// A tracker that has seen nothing.
    #[must_use]
    pub const fn new() -> Self {
        Self {
            state: State::Ground,
            params: Vec::new(),
            params_overflowed: false,
            string_is_osc: false,
            frame_open: false,
            generation: 0,
        }
    }

    /// TRUE while the bytes observed so far end inside an OPEN synchronized update.
    #[must_use]
    pub const fn is_frame_open(&self) -> bool {
        self.frame_open
    }

    /// Bumped every time a frame OPENS.
    ///
    /// Two scans that both see a frame open are looking at the SAME frame only if this matches.
    /// A caller timing out an over-long frame must key its deadline on this, or a continuous
    /// repaint stream — each scan a different, perfectly well-formed frame — reads as one frame
    /// stuck open and trips the timeout forever after.
    #[must_use]
    pub const fn generation(&self) -> u64 {
        self.generation
    }

    /// Drops parse + frame state. A grid REBUILD replays a fresh stream, and the old parser
    /// position describes bytes the model no longer holds.
    pub fn reset(&mut self) {
        *self = Self::new();
    }

    /// Folds one chunk of raw PTY output — exactly the bytes the screen model was fed, in order.
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
                    b'[' => {
                        self.params.clear();
                        self.params_overflowed = false;
                        self.state = State::Csi;
                    },
                    b']' => {
                        self.string_is_osc = true;
                        self.state = State::Str;
                    },
                    b'P' | b'X' | b'^' | b'_' => {
                        self.string_is_osc = false;
                        self.state = State::Str;
                    },
                    // RIS — a full reset ends any repaint in progress.
                    b'c' => {
                        self.frame_open = false;
                        self.state = State::Ground;
                    },
                    0x1B => self.state = State::Escape,
                    _ => self.state = State::Ground,
                }
            },
            State::Csi => self.step_csi(byte),
            State::Str => {
                if self.string_is_osc && byte == 0x07 {
                    self.state = State::Ground;
                } else if byte == 0x1B {
                    self.state = State::StrEscape;
                }
            },
            State::StrEscape => {
                if byte == b'\\' {
                    self.state = State::Ground;
                } else if byte != 0x1B {
                    self.state = State::Str;
                }
            },
        }
    }

    fn step_csi(&mut self, byte: u8) {
        // Parameter (0x30–0x3F) and intermediate (0x20–0x2F) bytes precede the final byte
        // (0x40–0x7E). Anything else is malformed — drop back to ground.
        if (0x30..=0x3F).contains(&byte) || (0x20..=0x2F).contains(&byte) {
            if self.params.len() < MAX_PARAM_BYTES {
                self.params.push(byte);
            } else {
                self.params_overflowed = true;
            }
        } else if (0x40..=0x7E).contains(&byte) {
            self.apply_csi_final(byte);
            self.state = State::Ground;
        } else if byte == 0x1B {
            // ⚠️ ESC ABORTS the sequence and BEGINS the next one (the VT500 parser's
            // anywhere-transition). Falling to ground here would EAT this ESC, so the `[` after it
            // reads as a plain byte and the whole `CSI ? 2026 h` that follows an aborted sequence
            // goes unseen — a repaint that never registers as a frame.
            self.params.clear();
            self.params_overflowed = false;
            self.state = State::Escape;
        } else {
            self.state = State::Ground;
        }
    }

    /// A DECSET/DECRST (`?…h` / `?…l`) whose parameter list contains mode 2026 opens / closes the
    /// frame. Everything else is ignored.
    fn apply_csi_final(&mut self, final_byte: u8) {
        let params = std::mem::take(&mut self.params);
        let overflowed = std::mem::replace(&mut self.params_overflowed, false);
        if overflowed || (final_byte != b'h' && final_byte != b'l') || params.first() != Some(&b'?') {
            return;
        }
        let rest = &params[1..];
        // No intermediates: a `?…$p` (DECRQM) must not be read as a mode SET.
        if rest.iter().any(|byte| (0x20..=0x2F).contains(byte)) {
            return;
        }
        let contains_2026 = String::from_utf8_lossy(rest)
            .split(';')
            .filter_map(|field| field.parse::<i64>().ok())
            .any(|mode| mode == 2026);
        if !contains_2026 {
            return;
        }
        let open = final_byte == b'h';
        // A re-`h` inside an already-open frame is not a new frame.
        if open && !self.frame_open {
            self.generation = self.generation.wrapping_add(1);
        }
        self.frame_open = open;
    }
}

#[cfg(test)]
mod tests {
    use super::{MAX_PARAM_BYTES, SyncFrameTracker};

    #[test]
    fn a_frame_opens_and_closes() {
        let mut tracker = SyncFrameTracker::new();
        assert!(!tracker.is_frame_open());
        tracker.observe(b"\x1b[?2026h");
        assert!(tracker.is_frame_open());
        assert_eq!(tracker.generation(), 1);
        tracker.observe(b"repaint\x1b[?2026l");
        assert!(!tracker.is_frame_open());
    }

    #[test]
    fn a_sequence_split_across_chunks_still_registers() {
        let mut tracker = SyncFrameTracker::new();
        tracker.observe(b"\x1b[?20");
        tracker.observe(b"26h");
        assert!(
            tracker.is_frame_open(),
            "the split is exactly what causes the tear"
        );
    }

    #[test]
    fn the_generation_moves_once_per_frame_not_once_per_h() {
        let mut tracker = SyncFrameTracker::new();
        tracker.observe(b"\x1b[?2026h\x1b[?2026h");
        assert_eq!(tracker.generation(), 1, "2026 is a flag, not a counter");
        tracker.observe(b"\x1b[?2026l\x1b[?2026h");
        assert_eq!(tracker.generation(), 2);
    }

    #[test]
    fn mode_2026_is_found_among_other_modes() {
        let mut tracker = SyncFrameTracker::new();
        tracker.observe(b"\x1b[?1049;2026;1002h");
        assert!(tracker.is_frame_open());
        tracker.observe(b"\x1b[?1002l");
        assert!(
            tracker.is_frame_open(),
            "an unrelated mode leaves the frame alone"
        );
    }

    #[test]
    fn a_decrqm_query_is_not_a_mode_set() {
        let mut tracker = SyncFrameTracker::new();
        tracker.observe(b"\x1b[?2026$p");
        assert!(!tracker.is_frame_open());
    }

    #[test]
    fn ris_closes_an_open_frame() {
        let mut tracker = SyncFrameTracker::new();
        tracker.observe(b"\x1b[?2026h\x1bc");
        assert!(!tracker.is_frame_open());
    }

    #[test]
    fn an_escape_inside_a_csi_aborts_it_and_starts_the_next() {
        let mut tracker = SyncFrameTracker::new();
        // The aborted `CSI 12` must not eat the ESC that begins the real frame open.
        tracker.observe(b"\x1b[12\x1b[?2026h");
        assert!(tracker.is_frame_open());
    }

    #[test]
    fn an_embedded_2026_inside_a_string_body_cannot_open_a_frame() {
        let mut tracker = SyncFrameTracker::new();
        tracker.observe(b"\x1b]0;\x1b[?2026h\x07");
        assert!(!tracker.is_frame_open());
        tracker.observe(b"\x1bP\x1b[?2026h\x1b\\");
        assert!(!tracker.is_frame_open());
    }

    #[test]
    fn an_overflowing_parameter_list_is_ignored() {
        let mut tracker = SyncFrameTracker::new();
        let mut hostile = b"\x1b[?".to_vec();
        hostile.extend(std::iter::repeat_n(b'1', MAX_PARAM_BYTES + 10));
        hostile.extend_from_slice(b";2026h");
        tracker.observe(&hostile);
        assert!(
            !tracker.is_frame_open(),
            "a truncated parameter list decides nothing"
        );
        // …and the parser recovers.
        tracker.observe(b"\x1b[?2026h");
        assert!(tracker.is_frame_open());
    }

    #[test]
    fn a_reset_drops_frame_and_parse_state() {
        let mut tracker = SyncFrameTracker::new();
        tracker.observe(b"\x1b[?2026h\x1b[?20");
        tracker.reset();
        assert!(!tracker.is_frame_open());
        assert_eq!(tracker.generation(), 0);
        tracker.observe(b"26h");
        assert!(
            !tracker.is_frame_open(),
            "the half-parsed sequence went with the reset"
        );
    }
}
