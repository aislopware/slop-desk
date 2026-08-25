//! One pane's screen-detection TICK — the temporal layer over screend's rule ladder.
//!
//! ## The line, restated
//! **screend owns everything that reads the BYTES; the pane's scanner owns everything that reads
//! the CLOCK.** That split is unchanged by this module; what changed is the language the clock half
//! is written in. Every deadline here — the startup grace, the idle-scan skip, the working→idle
//! hold, the visible-blocker heartbeat, the cap on an open synchronized frame — is a decision about
//! time, and none of them needs a byte of the pane's output.
//!
//! ## Why the tick is TWO calls and not one
//! A tick may have to ask screend a question, and the socket is the caller's: hostd already holds a
//! `ScreenClient` with its own connection, reconnect and framing, and a second dialler in this
//! crate would be the cross-language mirror the tree forbids. So the tick is split exactly where
//! the socket is:
//!
//! 1. [`PaneScan::plan`] folds the tick's timing facts and answers whether the exchange is worth
//!    making, with which flags, and whether the ladder should run at all;
//! 2. the caller performs (or skips, or fails) that one exchange;
//! 3. [`PaneScan::finish`] takes the outcome and answers what to publish and when to look again.
//!
//! Everything remembered between the two halves — the pending suppression, whether the label went
//! over empty — is held HERE, in [`Pending`], so the caller carries no scan state at all. A caller
//! that skips step 2 says so with [`Outcome::Skipped`]; one whose socket failed says
//! [`Outcome::Failed`], and that answer is deliberately NOT "publish the last verdict": a grid
//! whose last fold was lost is behind the pane by an unknown amount, and a detection read off a
//! stale screen is how a dismissed dialog gets reported as a live one.
//!
//! ## Absent screend costs the pane its screen tier and nothing else
//! Hook and ctl `report` evidence is authoritative anyway (`docs/50`) and never passes through
//! here, so a pane whose exchanges all fail keeps its status from those and simply stops learning
//! from its screen.

use crate::hold::AgentDetectionHold;
use crate::screen::{AgentScreenDetection, AgentScreenState};

/// One tick's inputs, in the terms this module decides with.
///
/// The pane's BYTES are deliberately absent: the caller sends them to screend itself, and all this
/// side needs to know is whether there were any ([`payload_empty`](Self::payload_empty)) — that is
/// the whole of the fold decision.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ScanInput<'a> {
    /// TRUE when the pending output AND the rebuild replay are both empty — nothing to fold.
    pub payload_empty: bool,
    /// TRUE when this tick carries a ring replay: the model is stale and is being rebuilt.
    pub rebuild_replay: bool,
    /// The pane's current row count.
    pub rows: u16,
    /// The pane's current column count.
    pub cols: u16,
    /// The identified foreground agent's label, or `None` (plain shell / unknown program).
    pub agent: Option<&'a str>,
    /// Monotonic content sequence — bumped per non-empty PTY chunk (the idle-scan skip).
    pub content_seq: u64,
    /// The scan clock, in seconds.
    pub now: f64,
}

/// What [`PaneScan::plan`] asks the caller to do with its socket.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
#[expect(
    clippy::struct_excessive_bools,
    reason = "the exchange's own flags, one field each — screend's verb spells them as four"
)]
pub struct ScanPlan {
    /// FALSE when the tick has nothing to fold and nothing new to ask: the grid, the OSC evidence
    /// and the agent are all unchanged, so the cached verdict is still the answer to the same
    /// question. The caller skips the socket entirely and reports [`Outcome::Skipped`].
    pub exchange: bool,
    /// The `reset` flag for the exchange — the grid has not landed a fold at the current size.
    pub reset: bool,
    /// The `agent_changed` flag for the exchange, which clears screend's retained OSC evidence.
    pub agent_changed: bool,
    /// TRUE when the agent label must go over EMPTY: this tick could not publish whatever came
    /// back, so screend folds the bytes and runs no rule. The grid and the trackers still advance,
    /// which is the whole point of the upkeep, and no rule is evaluated for an answer nobody reads.
    pub label_suppressed: bool,
}

/// What became of the exchange [`ScanPlan`] asked for.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Outcome {
    /// The plan did not ask for one.
    Skipped,
    /// screend answered.
    Answered(Verdict),
    /// The exchange failed — no reply, or one that would not decode.
    Failed,
}

/// screend's reply, in the fields the clock half reads.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Verdict {
    /// The rule ladder's verdict, or a default one on a tick that named no agent.
    pub detection: AgentScreenDetection,
    /// The bytes folded so far end inside an OPEN synchronized update.
    pub frame_open: bool,
    /// Bumped every time a frame OPENS — two scans see the SAME frame only if this matches.
    pub frame_generation: u64,
}

/// The tick's answer.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct ScanOutput {
    /// A detection worth folding into the pane's status machine, or `None`.
    pub publish: Option<AgentScreenDetection>,
    /// Seconds until the next scan (tightens to 100 ms while an idle hold is pending).
    pub next_interval: f64,
}

impl ScanOutput {
    /// Nothing to publish, look again in `next_interval`.
    const fn quiet(next_interval: f64) -> Self {
        Self {
            publish: None,
            next_interval,
        }
    }
}

/// What [`PaneScan::plan`] decided that [`PaneScan::finish`] still needs.
#[derive(Debug, Clone, Copy, PartialEq, Default)]
struct Pending {
    now: f64,
    agent_changed: bool,
    /// The interval to answer with when this tick cannot publish at all.
    suppression: Option<f64>,
    /// Whether the label went over empty — a reply that carries no ladder verdict.
    label_suppressed: bool,
}

/// One pane's scan state. Created per pane, dropped with it.
#[derive(Debug, Clone, Default)]
pub struct PaneScan {
    /// TRUE until a fold has landed on a grid of the CURRENT size — the next request carries the
    /// reset flag. Set by a rebuild request, a geometry change, and any failed exchange.
    grid_is_stale: bool,
    grid_rows: u16,
    grid_cols: u16,
    /// The last verdict screend answered for the CURRENT agent and the CURRENT screen, or `None`
    /// when the ladder has not run against them.
    ///
    /// Reused verbatim on a tick that folds no bytes: the verdict is a pure function of (grid, OSC
    /// evidence, agent), so with none of the three changed there is nothing to ask.
    cached: Option<AgentScreenDetection>,
    hold: AgentDetectionHold,
    /// The last PUBLISHED detection (herdr's `previous` — held stable through a pending hold).
    last_published: Option<AgentScreenDetection>,
    last_published_at: Option<f64>,
    last_agent: Option<String>,
    agent_since: Option<f64>,
    last_scan_seq: u64,
    /// TRUE between a ring REBUILD and the first output that lands on the rebuilt grid — while it
    /// stands, the ladder is not even asked to run.
    ///
    /// A rebuild re-feeds the RAW scrollback ring into a grid of the CURRENT size, and a resize is
    /// the reason a rebuild happens at all. Claude Code (like every inline TUI) dismisses its
    /// dialogs with RELATIVE motion — `CSI nA` + `CSI J` for a row count it measured at the OLD
    /// width — so replaying those bytes at the NEW width lands the erase in the wrong place and
    /// leaves the top of a long-dismissed permission dialog sitting in the visible rows. The ladder
    /// reads that faithfully and calls the pane BLOCKED, which is how switching tabs conjured a
    /// "waiting for your input" banner for a pane sitting quietly at its prompt.
    ///
    /// The grid is trustworthy again only once the program has repainted at the new size — the
    /// SIGWINCH the resize already delivered is what makes that arrive. So the reconstruction stays
    /// a WARM GUESS: good enough to fold, never good enough to publish. Nothing is lost by waiting
    /// — the last published verdict stands, and a resize changes what is on screen, not what the
    /// agent is doing.
    awaiting_repaint_after_rebuild: bool,
    /// Whether the bytes folded so far end inside an OPEN synchronized update, as screend last
    /// reported it. Carried between ticks because a tick that folds no bytes cannot have changed
    /// it.
    frame_open: bool,
    frame_generation: u64,
    /// The scan time at which the currently-open synchronized frame was first OBSERVED open
    /// (`None` when no frame is open). Anchors [`PaneScan::SYNC_FRAME_HOLD_CAP`].
    sync_frame_open_since: Option<f64>,
    /// The [`Verdict::frame_generation`] that
    /// [`sync_frame_open_since`](Self::sync_frame_open_since) anchors.
    ///
    /// ⚠️ The cap is per FRAME, and a busy TUI opens a new one every few milliseconds — anchoring
    /// on "a frame was open last time too" would let one second of ordinary repainting retire
    /// the hold permanently, and every scan after that reads a torn grid. Held together they
    /// say what is meant: THIS frame has been open too long.
    sync_frame_anchor_generation: Option<u64>,
    pending: Pending,
}

impl PaneScan {
    /// Ceiling on how long an open synchronized frame may suppress publishing. A frame is one
    /// repaint — milliseconds — so any frame still open a second later is a program that died
    /// mid-paint or a stream that lost its closer, and detection must not be frozen by it.
    /// (Terminal emulators bound the mode the same way, for the same reason.)
    pub const SYNC_FRAME_HOLD_CAP: f64 = 1.0;

    /// A scanner whose grid has never been folded.
    #[must_use]
    pub fn new() -> Self {
        Self {
            grid_is_stale: true,
            ..Self::default()
        }
    }

    /// Fold this tick's timing facts and answer what to ask screend.
    ///
    /// Advances every piece of state that does not depend on the reply, so a caller that never
    /// calls [`finish`](Self::finish) has still recorded the geometry, the sequence and the agent —
    /// but it has NOT published anything, which is the correct reading of a tick that was
    /// abandoned.
    pub fn plan(&mut self, input: &ScanInput<'_>) -> ScanPlan {
        let agent_changed = input.agent != self.last_agent.as_deref();
        if agent_changed {
            self.last_agent = input.agent.map(ToOwned::to_owned);
            self.agent_since = Some(input.now);
            self.last_published = None;
            self.last_published_at = None;
            self.cached = None;
            self.hold = AgentDetectionHold::new();
        }

        // Grid upkeep runs regardless of agent — the model must be warm when one appears.
        if input.rows != self.grid_rows || input.cols != self.grid_cols {
            // A VT grid cannot be reflowed, so a size change is not an adjustment, it is a
            // different grid. screend resets on a geometry change of its own accord; the flag is
            // what stops this side trusting the OLD verdict in the meantime.
            self.grid_is_stale = true;
            self.grid_rows = input.rows;
            self.grid_cols = input.cols;
        }
        if input.rebuild_replay {
            self.grid_is_stale = true;
            // A reconstruction is not an observation — hold publishing until the program repaints
            // onto it. The hold goes with it: a pending working→idle confirmation was counting
            // reads of a grid that no longer exists.
            self.awaiting_repaint_after_rebuild = true;
            self.hold = AgentDetectionHold::new();
        }

        let seq_unchanged = input.content_seq == self.last_scan_seq;
        self.last_scan_seq = input.content_seq;
        // Output landing AFTER the rebuild is the repaint the guess was waiting for. The rebuild
        // tick itself never clears the flag: marking the model dirty drops the pending buffer, so
        // the bytes replayed there are the ring's, not the resized program's.
        if self.awaiting_repaint_after_rebuild && !input.rebuild_replay && !seq_unchanged {
            self.awaiting_repaint_after_rebuild = false;
        }

        let suppression = self.suppression(input, agent_changed, seq_unchanged);
        // The label goes over empty whenever this tick could not publish what came back — and,
        // trivially, when there is no agent to name.
        let label_suppressed = suppression.is_some() || input.agent.is_none();
        let must_fold = !input.payload_empty || self.grid_is_stale || agent_changed;
        let must_ask = !label_suppressed && self.cached.is_none();
        self.pending = Pending {
            now: input.now,
            agent_changed,
            suppression,
            label_suppressed,
        };
        ScanPlan {
            exchange: must_fold || must_ask,
            reset: self.grid_is_stale,
            agent_changed,
            label_suppressed,
        }
    }

    /// Take the exchange's outcome and answer the tick.
    ///
    /// # Panics
    /// Never — but calling this without a preceding [`plan`](Self::plan) answers against a default
    /// [`Pending`], which reads as "no suppression, at time zero". Callers pair the two.
    pub fn finish(&mut self, outcome: &Outcome) -> ScanOutput {
        let pending = self.pending;
        match outcome {
            Outcome::Skipped => {},
            Outcome::Answered(verdict) => {
                self.grid_is_stale = false;
                self.frame_open = verdict.frame_open;
                self.frame_generation = verdict.frame_generation;
                self.cached = if pending.label_suppressed {
                    None
                } else {
                    Some(verdict.detection.clone())
                };
            },
            Outcome::Failed => {
                // A grid whose last fold was lost is behind the pane by an unknown amount, and a
                // detection read off a stale screen is how a dismissed dialog gets reported as a
                // live one. Publish NOTHING — not the fallback the empty screen would produce.
                self.grid_is_stale = true;
                self.cached = None;
                return ScanOutput::quiet(AgentDetectionHold::SCAN_INTERVAL);
            },
        }
        self.anchor_open_frame(pending.now);

        if let Some(interval) = pending.suppression {
            return ScanOutput::quiet(interval);
        }
        // Mid-repaint the grid is HALF a frame: the program said so with mode 2026, and it erases
        // lines before it rewrites them. Wait for the closer rather than read a screen that shows a
        // dialog with its footer missing. Recheck fast — the frame closes in milliseconds — and
        // never wait past the cap.
        if self.frame_open
            && self
                .sync_frame_open_since
                .is_some_and(|since| pending.now - since < Self::SYNC_FRAME_HOLD_CAP)
        {
            return ScanOutput::quiet(AgentDetectionHold::PENDING_IDLE_RECHECK);
        }
        let Some(detection) = self.cached.clone() else {
            return ScanOutput::quiet(AgentDetectionHold::SCAN_INTERVAL);
        };
        // A freeze rule (transcript viewer / model picker) publishes nothing — the machine holds
        // its previous status.
        if detection.skip_state_update {
            return ScanOutput::quiet(AgentDetectionHold::SCAN_INTERVAL);
        }
        let previous = self
            .last_published
            .clone()
            .unwrap_or_else(|| AgentScreenDetection::plain(AgentScreenState::Unknown));
        let publish_now = self.hold.decide(
            &previous,
            &detection,
            pending.agent_changed,
            false,
            self.last_published_at,
            pending.now,
        );
        let interval = if self.hold.is_holding_idle() {
            AgentDetectionHold::PENDING_IDLE_RECHECK
        } else {
            AgentDetectionHold::SCAN_INTERVAL
        };
        if !publish_now {
            return ScanOutput::quiet(interval);
        }
        self.last_published = Some(detection.clone());
        self.last_published_at = Some(pending.now);
        ScanOutput {
            publish: Some(detection),
            next_interval: interval,
        }
    }

    /// The interval to answer with when this tick cannot publish, or `None` when it can.
    fn suppression(&self, input: &ScanInput<'_>, agent_changed: bool, seq_unchanged: bool) -> Option<f64> {
        // No agent, nothing to publish about — the grid still folds, at the steady cadence.
        if input.agent.is_none() {
            return Some(AgentDetectionHold::SCAN_INTERVAL);
        }
        // Startup grace: suppress detection while the TUI paints its splash.
        if self
            .agent_since
            .is_some_and(|since| input.now - since < AgentDetectionHold::STARTUP_GRACE_WINDOW)
        {
            return Some(AgentDetectionHold::SCAN_INTERVAL);
        }
        // Idle-scan skip: a quiescent idle pane with no new bytes asks no question.
        if self
            .last_published
            .as_ref()
            .is_some_and(|published| matches!(published.state, AgentScreenState::Idle))
            && seq_unchanged
            && !self.hold.is_holding_idle()
            && !agent_changed
        {
            return Some(AgentDetectionHold::SCAN_INTERVAL);
        }
        // The rebuilt grid is a guess until the program repaints onto it — fold it, never read it.
        if self.awaiting_repaint_after_rebuild {
            return Some(AgentDetectionHold::SCAN_INTERVAL);
        }
        None
    }

    /// Anchors the open frame the first scan that sees THIS frame open; drops the anchor when it
    /// closes, and re-arms when the generation moves (a different frame is a fresh deadline).
    fn anchor_open_frame(&mut self, now: f64) {
        if !self.frame_open {
            self.sync_frame_open_since = None;
            self.sync_frame_anchor_generation = None;
            return;
        }
        if self.sync_frame_open_since.is_none()
            || self.sync_frame_anchor_generation != Some(self.frame_generation)
        {
            self.sync_frame_open_since = Some(now);
            self.sync_frame_anchor_generation = Some(self.frame_generation);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{Outcome, PaneScan, ScanInput, ScanOutput, ScanPlan, Verdict};
    use crate::hold::AgentDetectionHold;
    use crate::screen::{AgentScreenDetection, AgentScreenState};

    /// A tick with an agent, a steady 24×80 grid and bytes to fold.
    fn tick(seq: u64, now: f64) -> ScanInput<'static> {
        ScanInput {
            payload_empty: false,
            rebuild_replay: false,
            rows: 24,
            cols: 80,
            agent: Some("claude"),
            content_seq: seq,
            now,
        }
    }

    fn verdict(state: AgentScreenState) -> Outcome {
        Outcome::Answered(Verdict {
            detection: AgentScreenDetection::visible(state),
            ..Verdict::default()
        })
    }

    /// Plan, answer with `state`, finish — one whole tick.
    fn run(scan: &mut PaneScan, input: &ScanInput<'_>, outcome: &Outcome) -> ScanOutput {
        let _plan: ScanPlan = scan.plan(input);
        scan.finish(outcome)
    }

    #[test]
    fn the_startup_grace_suppresses_the_first_three_seconds_of_an_agent() {
        let mut scan = PaneScan::new();
        let early = run(&mut scan, &tick(1, 0.0), &verdict(AgentScreenState::Working));
        assert!(early.publish.is_none(), "the TUI is still painting its splash");
        let late = run(&mut scan, &tick(2, 3.5), &verdict(AgentScreenState::Working));
        assert_eq!(
            late.publish.map(|detection| detection.state),
            Some(AgentScreenState::Working)
        );
    }

    #[test]
    fn an_unchanged_verdict_does_not_republish() {
        let mut scan = PaneScan::new();
        run(&mut scan, &tick(1, 0.0), &verdict(AgentScreenState::Working));
        run(&mut scan, &tick(2, 3.5), &verdict(AgentScreenState::Working));
        let again = run(&mut scan, &tick(3, 4.0), &verdict(AgentScreenState::Working));
        assert!(again.publish.is_none());
    }

    /// The suppressed tick still ASKS for the exchange — the grid has to stay warm — but it sends
    /// no label, so screend folds the bytes and runs no rule.
    #[test]
    fn a_suppressed_tick_still_folds_but_names_no_agent() {
        let mut scan = PaneScan::new();
        let plan = scan.plan(&tick(1, 0.0));
        assert!(plan.exchange, "the grid must be warm before the grace ends");
        assert!(plan.label_suppressed, "no rule runs for an answer nobody reads");
        assert!(plan.reset, "the first fold of a fresh grid");
    }

    /// A quiescent idle pane with no new bytes asks nothing at all — no socket, no ladder.
    #[test]
    fn a_quiescent_idle_pane_skips_the_socket_entirely() {
        let mut scan = PaneScan::new();
        run(&mut scan, &tick(1, 0.0), &verdict(AgentScreenState::Idle));
        run(&mut scan, &tick(2, 3.5), &verdict(AgentScreenState::Idle));
        let quiet = ScanInput {
            payload_empty: true,
            ..tick(2, 4.0)
        };
        let plan = scan.plan(&quiet);
        assert!(
            !plan.exchange,
            "same grid, same evidence, same agent — same answer"
        );
        let output = scan.finish(&Outcome::Skipped);
        assert!(output.publish.is_none());
        assert!((output.next_interval - AgentDetectionHold::SCAN_INTERVAL).abs() < f64::EPSILON);
    }

    /// A failed exchange publishes NOTHING and re-arms the reset — never the last verdict.
    #[test]
    fn a_failed_exchange_publishes_nothing_and_marks_the_grid_stale() {
        let mut scan = PaneScan::new();
        run(&mut scan, &tick(1, 0.0), &verdict(AgentScreenState::Blocked));
        run(&mut scan, &tick(2, 3.5), &verdict(AgentScreenState::Blocked));
        let lost = run(&mut scan, &tick(3, 4.0), &Outcome::Failed);
        assert!(lost.publish.is_none(), "a stale screen is not evidence");
        assert!(scan.plan(&tick(4, 4.3)).reset, "the next fold rebuilds the grid");
    }

    /// A rebuild replay is a warm GUESS: folded, never read, until the program draws on it.
    #[test]
    fn a_rebuilt_grid_is_not_published_until_the_program_repaints() {
        let mut scan = PaneScan::new();
        run(&mut scan, &tick(1, 0.0), &verdict(AgentScreenState::Working));
        run(&mut scan, &tick(2, 3.5), &verdict(AgentScreenState::Working));
        let rebuild = ScanInput {
            rebuild_replay: true,
            ..tick(3, 4.0)
        };
        let guess = run(&mut scan, &rebuild, &verdict(AgentScreenState::Blocked));
        assert!(guess.publish.is_none(), "a reconstruction is not an observation");
        // Any byte from the program IS the repaint the guess was waiting for.
        let repainted = run(&mut scan, &tick(4, 4.4), &verdict(AgentScreenState::Blocked));
        assert_eq!(
            repainted.publish.map(|detection| detection.state),
            Some(AgentScreenState::Blocked)
        );
    }

    /// Mid-repaint the grid is half a frame — recheck fast, publish nothing.
    #[test]
    fn an_open_synchronized_frame_defers_the_verdict() {
        let mut scan = PaneScan::new();
        run(&mut scan, &tick(1, 0.0), &verdict(AgentScreenState::Blocked));
        run(&mut scan, &tick(2, 3.5), &verdict(AgentScreenState::Blocked));
        let torn = Outcome::Answered(Verdict {
            detection: AgentScreenDetection::visible(AgentScreenState::Idle),
            frame_open: true,
            frame_generation: 1,
        });
        let output = run(&mut scan, &tick(3, 4.0), &torn);
        assert!(output.publish.is_none(), "the program said it was mid-paint");
        assert!(
            (output.next_interval - AgentDetectionHold::PENDING_IDLE_RECHECK).abs() < f64::EPSILON,
            "the frame closes in milliseconds",
        );
    }

    /// The cap retires ONE frame's hold, not the guard: a stream of well-formed frames re-anchors
    /// on every generation bump, so a two-second repaint burst never publishes a torn grid.
    #[test]
    fn a_continuous_repaint_stream_re_anchors_the_cap_on_every_frame() {
        let mut scan = PaneScan::new();
        run(&mut scan, &tick(1, 0.0), &verdict(AgentScreenState::Blocked));
        run(&mut scan, &tick(2, 3.5), &verdict(AgentScreenState::Blocked));
        let mut now = 4.0;
        for generation in 1..=20 {
            let torn = Outcome::Answered(Verdict {
                detection: AgentScreenDetection::visible(AgentScreenState::Idle),
                frame_open: true,
                frame_generation: generation,
            });
            let output = run(&mut scan, &tick(2 + generation, now), &torn);
            assert!(
                output.publish.is_none(),
                "a torn grid is never published, however long the burst runs",
            );
            now += 0.1;
        }
        assert!(
            now - 4.0 > PaneScan::SYNC_FRAME_HOLD_CAP,
            "well past the cap, and still holding",
        );
    }

    /// …but ONE frame left open forever stops suppressing at the cap. A program that died
    /// mid-paint must not pin the pane's status.
    #[test]
    fn one_unclosed_frame_stops_suppressing_at_the_cap() {
        let mut scan = PaneScan::new();
        run(&mut scan, &tick(1, 0.0), &verdict(AgentScreenState::Working));
        run(&mut scan, &tick(2, 3.5), &verdict(AgentScreenState::Working));
        let stuck = Outcome::Answered(Verdict {
            detection: AgentScreenDetection::visible(AgentScreenState::Blocked),
            frame_open: true,
            frame_generation: 7,
        });
        assert!(run(&mut scan, &tick(3, 4.0), &stuck).publish.is_none());
        assert!(
            run(&mut scan, &tick(4, 4.5), &stuck).publish.is_none(),
            "still inside the cap",
        );
        let believed = run(&mut scan, &tick(5, 5.1), &stuck);
        assert_eq!(
            believed.publish.map(|detection| detection.state),
            Some(AgentScreenState::Blocked),
            "detection resumes; it is never frozen",
        );
    }

    /// A freeze rule holds the previous status rather than publishing this one.
    #[test]
    fn a_freeze_rule_publishes_nothing() {
        let mut scan = PaneScan::new();
        run(&mut scan, &tick(1, 0.0), &verdict(AgentScreenState::Working));
        run(&mut scan, &tick(2, 3.5), &verdict(AgentScreenState::Working));
        let frozen = Outcome::Answered(Verdict {
            detection: AgentScreenDetection {
                state: AgentScreenState::Idle,
                skip_state_update: true,
                ..AgentScreenDetection::default()
            },
            ..Verdict::default()
        });
        assert!(run(&mut scan, &tick(3, 4.0), &frozen).publish.is_none());
    }

    /// An agent change re-enters the grace and forgets what the previous agent published.
    #[test]
    fn a_new_agent_re_enters_its_own_startup_grace() {
        let mut scan = PaneScan::new();
        run(&mut scan, &tick(1, 0.0), &verdict(AgentScreenState::Working));
        run(&mut scan, &tick(2, 3.5), &verdict(AgentScreenState::Working));
        let codex = ScanInput {
            agent: Some("codex"),
            ..tick(3, 4.0)
        };
        let plan = scan.plan(&codex);
        assert!(plan.agent_changed, "screend must drop the retained OSC evidence");
        assert!(scan.finish(&verdict(AgentScreenState::Idle)).publish.is_none());
        let later = ScanInput {
            agent: Some("codex"),
            ..tick(4, 8.0)
        };
        let settled = run(&mut scan, &later, &verdict(AgentScreenState::Idle));
        assert_eq!(
            settled.publish.map(|detection| detection.state),
            Some(AgentScreenState::Idle)
        );
    }

    /// A pane with no agent keeps its grid warm and names nobody.
    #[test]
    fn a_pane_with_no_agent_folds_and_publishes_nothing() {
        let mut scan = PaneScan::new();
        let shell = ScanInput {
            agent: None,
            ..tick(1, 0.0)
        };
        let plan = scan.plan(&shell);
        assert!(plan.exchange, "the model must be warm when an agent appears");
        assert!(plan.label_suppressed);
        assert!(scan.finish(&verdict(AgentScreenState::Blocked)).publish.is_none());
    }

    /// A working → plain idle is held until three reads confirm it, and the cadence tightens.
    #[test]
    fn a_working_to_plain_idle_is_held_until_confirmed() {
        let mut scan = PaneScan::new();
        run(&mut scan, &tick(1, 0.0), &verdict(AgentScreenState::Working));
        run(&mut scan, &tick(2, 3.5), &verdict(AgentScreenState::Working));
        let plain = Outcome::Answered(Verdict {
            detection: AgentScreenDetection::plain(AgentScreenState::Idle),
            ..Verdict::default()
        });
        let held = run(&mut scan, &tick(3, 4.0), &plain);
        assert!(held.publish.is_none());
        assert!((held.next_interval - AgentDetectionHold::PENDING_IDLE_RECHECK).abs() < f64::EPSILON,);
        assert!(run(&mut scan, &tick(4, 4.1), &plain).publish.is_none());
        assert!(run(&mut scan, &tick(5, 4.2), &plain).publish.is_none());
        let released = run(&mut scan, &tick(6, 4.3), &plain);
        assert_eq!(
            released.publish.map(|detection| detection.state),
            Some(AgentScreenState::Idle)
        );
        assert!((released.next_interval - AgentDetectionHold::SCAN_INTERVAL).abs() < f64::EPSILON);
    }
}
