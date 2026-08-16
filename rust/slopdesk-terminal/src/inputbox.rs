//! A small state machine tying [`TerminalModeTracker`] (mode) and [`InputDedupRing`] (echo
//! suppression) together, and exposing the current input affordance to the UI layer.
//!
//! Pure logic, no UI: it feeds output bytes through the tracker, flips the affordance when the mode
//! changes, and drives the dedup ring **only while in B1 compose mode** — in shell-A mode echo is
//! meant to show, so the ring is bypassed and reset.

use crate::dedup::InputDedupRing;
use crate::mode::{TerminalMode, TerminalModeEvent};
use crate::tracker::TerminalModeTracker;

/// What the external input box should offer the user right now, derived from the terminal mode
/// (docs/14 § external input box, decision **A + B1**).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub enum InputAffordance {
    /// **A — shell command box.** At a shell prompt: the box sends a whole line on Enter and a
    /// block boundary is marked at the prompt (OSC 133). Echo flows normally in the surface
    /// above.
    #[default]
    ShellCommand,
    /// **B1 — TUI compose box.** A fullscreen TUI (Claude Code interactive) owns the screen:
    /// overlay a compose box, write bytes to the PTY on submit with `DelayedEnter`, and dedup
    /// the PTY's echo.
    TuiCompose,
}

impl InputAffordance {
    /// The affordance a given terminal mode calls for.
    #[must_use]
    pub const fn for_mode(mode: TerminalMode) -> Self {
        match mode {
            TerminalMode::ShellPrompt => Self::ShellCommand,
            TerminalMode::AltScreen => Self::TuiCompose,
        }
    }
}

/// What one output chunk produced: the bytes to render, and the markers seen along the way.
///
/// The Swift original delivered the markers through an `onEvent` callback the UI installed. Handing
/// them back with the bytes says the same thing without a stored closure — the caller already has
/// to do something with the return value, and the two are answers to the same chunk.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Ingested {
    /// The bytes to actually render, after echo suppression.
    pub bytes: Vec<u8>,
    /// Every tracker event this chunk produced, in order.
    pub events: Vec<TerminalModeEvent>,
}

/// Mode, affordance, command state and echo suppression for one pane's input surface.
#[derive(Debug, Clone, Default)]
pub struct InputBoxModel {
    tracker: TerminalModeTracker,
    dedup: InputDedupRing,
    affordance: InputAffordance,
    command_running: bool,
    last_exit_code: Option<i64>,
}

impl InputBoxModel {
    /// A model at a shell prompt with an empty dedup ring.
    #[must_use]
    pub const fn new() -> Self {
        Self {
            tracker: TerminalModeTracker::new(),
            dedup: InputDedupRing::new(),
            affordance: InputAffordance::ShellCommand,
            command_running: false,
            last_exit_code: None,
        }
    }

    /// A model whose dedup ring carries an explicit pending-byte bound.
    #[must_use]
    pub const fn with_dedup_capacity(capacity: usize) -> Self {
        Self {
            tracker: TerminalModeTracker::new(),
            dedup: InputDedupRing::with_capacity(capacity),
            affordance: InputAffordance::ShellCommand,
            command_running: false,
            last_exit_code: None,
        }
    }

    /// The current terminal mode (a passthrough for inspection).
    #[must_use]
    pub const fn mode(&self) -> TerminalMode {
        self.tracker.mode()
    }

    /// The current input affordance: [`ShellCommand`](InputAffordance::ShellCommand) while at a
    /// shell prompt, [`TuiCompose`](InputAffordance::TuiCompose) while a fullscreen TUI owns
    /// the alternate screen.
    #[must_use]
    pub const fn affordance(&self) -> InputAffordance {
        self.affordance
    }

    /// Whether a shell command appears to be running (between OSC 133 `C` and `D`). The A-mode
    /// block model reads this; the box may surface a "running" state from it.
    #[must_use]
    pub const fn command_running(&self) -> bool {
        self.command_running
    }

    /// The exit code of the most recently finished shell command, if any.
    #[must_use]
    pub const fn last_exit_code(&self) -> Option<i64> {
        self.last_exit_code
    }

    /// The tracker, for the passive DECSET flags the key encoder and the paste pre-check read.
    #[must_use]
    pub const fn tracker(&self) -> &TerminalModeTracker {
        &self.tracker
    }

    /// Feeds an output chunk through the tracker, updates the affordance and the command state, and
    /// answers the bytes to actually render.
    ///
    /// In **B1 (compose)** mode the dedup ring strips the echo of compose-box input; in **A
    /// (shell)** mode output passes through untouched (echo is meant to show) and the ring is
    /// reset.
    pub fn ingest_output(&mut self, output: &[u8]) -> Ingested {
        let events = self.tracker.consume(output);
        for event in &events {
            self.apply(*event);
        }
        self.affordance = InputAffordance::for_mode(self.tracker.mode());
        let bytes = match self.affordance {
            InputAffordance::TuiCompose => self.dedup.filter(output),
            InputAffordance::ShellCommand => {
                self.dedup.reset();
                output.to_vec()
            },
        };
        Ingested { bytes, events }
    }

    /// Records bytes the compose box wrote to the PTY so their echo can be suppressed. Only
    /// meaningful in [`TuiCompose`](InputAffordance::TuiCompose); a no-op in shell mode, where the
    /// echo is what the user expects to see.
    pub fn record_compose_sent(&mut self, bytes: &[u8]) {
        if self.affordance == InputAffordance::TuiCompose {
            self.dedup.record_sent(bytes);
        }
    }

    /// Returns the model to a fresh session's state: shell prompt, ground parse state, empty ring.
    pub fn reset(&mut self) {
        self.tracker.reset();
        self.dedup.reset();
        self.affordance = InputAffordance::ShellCommand;
        self.command_running = false;
        self.last_exit_code = None;
    }

    fn apply(&mut self, event: TerminalModeEvent) {
        match event {
            // A mode flip clears any half-matched echo state.
            TerminalModeEvent::EnteredAltScreen | TerminalModeEvent::ExitedAltScreen => {
                self.dedup.reset();
            },
            TerminalModeEvent::CommandStarted => self.command_running = true,
            TerminalModeEvent::CommandFinished { exit_code } => {
                self.command_running = false;
                self.last_exit_code = exit_code;
            },
            TerminalModeEvent::PromptStart | TerminalModeEvent::CommandStart => {
                self.command_running = false;
            },
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{InputAffordance, InputBoxModel};
    use crate::mode::{TerminalMode, TerminalModeEvent};

    #[test]
    fn a_fresh_model_offers_the_shell_command_box() {
        let model = InputBoxModel::new();
        assert_eq!(model.affordance(), InputAffordance::ShellCommand);
        assert_eq!(model.mode(), TerminalMode::ShellPrompt);
        assert!(!model.command_running());
        assert_eq!(model.last_exit_code(), None);
    }

    #[test]
    fn entering_the_alt_screen_switches_to_the_compose_box() {
        let mut model = InputBoxModel::new();
        let ingested = model.ingest_output(b"\x1B[?1049h");
        assert_eq!(ingested.events, [TerminalModeEvent::EnteredAltScreen]);
        assert_eq!(model.affordance(), InputAffordance::TuiCompose);
        let ingested = model.ingest_output(b"\x1B[?1049l");
        assert_eq!(ingested.events, [TerminalModeEvent::ExitedAltScreen]);
        assert_eq!(model.affordance(), InputAffordance::ShellCommand);
    }

    #[test]
    fn the_compose_box_echo_is_suppressed_only_in_tui_mode() {
        let mut model = InputBoxModel::new();
        model.ingest_output(b"\x1B[?1049h");
        model.record_compose_sent(b"hello\n");
        assert_eq!(model.ingest_output(b"hello\r\n").bytes, b"");
    }

    #[test]
    fn a_shell_mode_send_is_not_recorded_so_its_echo_still_shows() {
        let mut model = InputBoxModel::new();
        model.record_compose_sent(b"hello\n");
        assert_eq!(model.ingest_output(b"hello\r\n").bytes, b"hello\r\n");
    }

    #[test]
    fn leaving_the_alt_screen_drops_a_half_matched_echo() {
        let mut model = InputBoxModel::new();
        model.ingest_output(b"\x1B[?1049h");
        model.record_compose_sent(b"abcdef");
        assert_eq!(
            model.ingest_output(b"abc").bytes,
            b"",
            "held, awaiting confirmation"
        );
        // The mode flip resets the ring, so the rest of the echo is ordinary output again.
        model.ingest_output(b"\x1B[?1049l");
        assert_eq!(model.ingest_output(b"def").bytes, b"def");
    }

    #[test]
    fn the_command_marks_drive_the_running_flag_and_the_exit_code() {
        let mut model = InputBoxModel::new();
        model.ingest_output(b"\x1B]133;A\x07");
        assert!(!model.command_running());
        model.ingest_output(b"\x1B]133;C\x07");
        assert!(model.command_running());
        model.ingest_output(b"\x1B]133;D;7\x07");
        assert!(!model.command_running());
        assert_eq!(model.last_exit_code(), Some(7));
        // A new prompt clears the running flag but keeps the last code.
        model.ingest_output(b"\x1B]133;A\x07");
        assert_eq!(model.last_exit_code(), Some(7));
    }

    #[test]
    fn shell_mode_output_is_returned_verbatim() {
        let mut model = InputBoxModel::new();
        assert_eq!(model.ingest_output(b"plain $ output").bytes, b"plain $ output");
    }

    #[test]
    fn a_reset_returns_the_model_to_a_fresh_session() {
        let mut model = InputBoxModel::new();
        model.ingest_output(b"\x1B[?1049h\x1B]133;C\x07");
        model.record_compose_sent(b"x");
        model.reset();
        assert_eq!(model.affordance(), InputAffordance::ShellCommand);
        assert_eq!(model.mode(), TerminalMode::ShellPrompt);
        assert!(!model.command_running());
        assert_eq!(
            model.ingest_output(b"x").bytes,
            b"x",
            "the pending echo is gone too"
        );
    }

    #[test]
    fn the_affordance_mapping_is_total() {
        assert_eq!(
            InputAffordance::for_mode(TerminalMode::ShellPrompt),
            InputAffordance::ShellCommand
        );
        assert_eq!(
            InputAffordance::for_mode(TerminalMode::AltScreen),
            InputAffordance::TuiCompose
        );
    }
}
