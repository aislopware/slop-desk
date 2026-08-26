//! Who is running in this pane, and what they are doing — the three loops that answer it.
//!
//! Nothing here DECIDES. `slopdesk-agent` owns the status machine, the alias table, the screen rule
//! ladder and the hold that keeps a working→idle flip from flapping; `slopdesk-muxsession` owns the
//! echo latch and its warm-up gate. What is here is the driving: when to probe, what to hand each
//! fold, and where the messages it answers with go.
//!
//! ## Three drivers, and why they are not one
//!
//! - **The foreground poll** is a low-rate `tcgetpgrp`+`proc_pidpath` pair. It is the PRIMARY
//!   presence signal, it carries the clock TICK that decays a finished turn back to idle, and it
//!   rides a backstop for the echo edge. It is cheap enough to run on every pane, always.
//! - **The screen scan** feeds the pane's bytes to screend's resident grid and runs the rule ladder
//!   over what comes back. It is the expensive one — a socket round trip — so it skips entirely on
//!   a pane that has said nothing, and its cadence is [`ScanOutput::next_interval`]'s to choose.
//! - **The input fold** runs inline on whoever wrote to the PTY. It is the cancel/keystroke edge,
//!   and it has to be synchronous with the write or a `Ctrl-C` would be seen after the output it
//!   interrupted.
//!
//! ## One lock for the detector, and it is the truths lock
//!
//! The detector is folded from FOUR contexts — the poll thread, the scan thread, the hook feed and
//! any input writer — and every readout that pairs a status with a latched truth has to see them
//! agree. So it lives inside [`Folds`](crate::shared::Folds), under the same acquisition, exactly
//! as `MuxChannelSession` kept `agentDetector` under `truthsLock`. Two handles never hold each
//! other: what crosses the lock boundary is an [`Emission`], and the send happens outside.
//!
//! ## The screen scan holds TWO locks, and that is the point
//!
//! The pending-byte buffer is appended by the READ LOOP, and the read loop may not queue behind a
//! fold that is talking to screend. So the buffer, the dirty mark and the content sequence are
//! their own tiny lock ([`Screen`]), taken and released before the exchange starts — never held
//! across it.
//!
//! The scan STATE is the other half, and it has the opposite requirement: `plan` and `finish` are
//! one logical operation with the round trip in the middle, and a second tick landing between them
//! would answer the previous tick's question. So [`PaneScan`] gets a lock of its own that IS held
//! across the exchange, and holding it costs nothing because the single scan thread is the only
//! thing that ever takes it. One mutex could not satisfy both rules; two do.

use std::sync::{Arc, Condvar, Mutex, PoisonError};
use std::time::Duration;

use slopdesk_agent::{
    AgentDetectionHold, AgentKind, AgentScreenDetection, Emission, Outcome, PaneScan, ScanInput, Verdict,
};
use slopdesk_hostpane::PtyProcess;
use slopdesk_wire::message::WireMessage;

use crate::clock;
use crate::probe::Foreground;
use crate::shared::Shared;

/// The grid a scan assumes when the PTY will not answer its size.
const FALLBACK_ROWS: u16 = 24;
/// See [`FALLBACK_ROWS`].
const FALLBACK_COLS: u16 = 80;

/// The most retained history one rebuild hands screend.
///
/// A rebuild replays the ring so the resident grid can be reconstructed at a new size; past this
/// much, only the NEWEST bytes are sent. A full-screen program repaints, so a truncated prefix
/// converges after one redraw cycle — the same property the ring's own truncation relies on.
const REBUILD_CAP_BYTES: usize = 8 * 1024 * 1024;

/// One screen exchange, in the terms screend's `detect` verb takes.
#[derive(Debug, Clone, Copy)]
pub struct ScreenRequest<'tick> {
    /// screend's key for this pane's resident model.
    pub pane: &'tick str,
    /// The identified agent's label, or EMPTY when this tick may not publish — screend folds the
    /// bytes and runs no rule for an answer nobody will read.
    pub agent: &'tick str,
    /// The bytes to fold: the rebuild replay first, then whatever arrived since the last tick.
    pub raw: &'tick [u8],
    /// The pane's current row count.
    pub rows: u16,
    /// The pane's current column count.
    pub cols: u16,
    /// The grid has not landed a fold at the current size.
    pub reset: bool,
    /// `raw` opens with a ring replay rather than live output.
    pub rebuild_replay: bool,
    /// The foreground agent changed, so screend's retained OSC evidence is stale.
    pub agent_changed: bool,
}

/// Where a screen scan's question goes.
///
/// A trait this crate never implements, for the reason [`SnapshotPolicy`](crate::SnapshotPolicy) is
/// one: the answer comes from a screend socket, and a session that linked the client would spawn a
/// daemon the moment a test constructed one. hostd wires the screend-backed implementation; a
/// session handed `None` runs no scan loop at all, which is precisely what a pane with screen
/// detection disabled should do.
pub trait ScreenOracle: Send + Sync + core::fmt::Debug {
    /// screend's verdict, or `None` for an exchange that failed or would not decode.
    ///
    /// A failure is NOT a fallback verdict. The scan folds `None` as [`Outcome::Failed`], which
    /// publishes nothing and marks the grid stale — a detection read off a screen whose last fold
    /// was lost is how a dismissed dialog gets reported as a live one.
    fn detect(&self, request: &ScreenRequest<'_>) -> Option<Verdict>;
}

/// What a session needs to know before it starts detecting.
#[derive(Clone)]
pub struct DetectConfig {
    /// Whether the foreground poll runs at all. `false` leaves the byte pipeline byte-identical,
    /// which is what a headless pane wants.
    pub foreground: bool,
    /// How often that poll samples.
    pub poll_interval: Duration,
    /// Where a screen scan's question goes, or `None` for no scan loop.
    pub screen: Option<Arc<dyn ScreenOracle>>,
    /// screend's key for this pane's resident model.
    pub pane_key: String,
    /// How long a finished turn stays `done` before it decays to `idle`.
    pub done_to_idle: f64,
}

impl core::fmt::Debug for DetectConfig {
    fn fmt(&self, formatter: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        formatter
            .debug_struct("DetectConfig")
            .field("foreground", &self.foreground)
            .field("poll_interval", &self.poll_interval)
            .field("screen", &self.screen.is_some())
            .field("pane_key", &self.pane_key)
            .field("done_to_idle", &self.done_to_idle)
            .finish()
    }
}

impl DetectConfig {
    /// A pane that detects nothing: no poll, no scan.
    ///
    /// The default a test wants, and the correct production shape for a pane whose gate is off.
    #[must_use]
    pub fn off() -> Self {
        Self {
            foreground: false,
            poll_interval: Duration::from_millis(750),
            screen: None,
            pane_key: String::new(),
            done_to_idle: 8.0,
        }
    }
}

/// The screen engine's side of the READ LOOP: what has arrived, and whether the grid still stands.
///
/// Deliberately holds no scan state. This lock is taken by superd's reader thread on every chunk,
/// so nothing that waits on a socket may ever be done while it is held — see [`Detect::scan`] for
/// the half that is.
#[derive(Debug, Default)]
struct Screen {
    /// Bytes the read loop has appended since the last tick.
    pending: Vec<u8>,
    /// The resident grid no longer describes this pane — the next tick rebuilds from the ring.
    dirty: bool,
    /// Bumped per non-empty chunk. A tick whose sequence is unchanged asks screend nothing.
    seq: u64,
}

/// A sleep the teardown can end.
///
/// `Task.sleep` was cancellable and a `thread::sleep` is not, so a loop that slept its interval
/// would hold the teardown for up to that interval per pane — and the scan's interval is chosen by
/// the engine, not by this crate. So the wait is a condvar the stop signals, and the loops park on
/// it.
#[derive(Debug, Default)]
struct Ticker {
    stopped: Mutex<bool>,
    changed: Condvar,
}

impl Ticker {
    /// Sleeps `interval`, or returns EARLY and `false` when the loops have been stopped.
    fn rest(&self, interval: Duration) -> bool {
        let stopped = self.stopped.lock().unwrap_or_else(PoisonError::into_inner);
        if *stopped {
            return false;
        }
        let (stopped, _timeout) = self
            .changed
            .wait_timeout(stopped, interval)
            .unwrap_or_else(PoisonError::into_inner);
        !*stopped
    }

    /// Ends every parked loop, and refuses every future rest.
    fn stop(&self) {
        *self.stopped.lock().unwrap_or_else(PoisonError::into_inner) = true;
        self.changed.notify_all();
    }
}

/// One pane's detection: the probes, the scan state and the wake the teardown pulls.
#[derive(Debug)]
pub(crate) struct Detect {
    config: DetectConfig,
    foreground: Foreground,
    /// The read loop's side. Taken per chunk, held for a copy and nothing else.
    screen: Mutex<Screen>,
    /// The SCAN thread's side, and the lock that is held across screend's round trip.
    ///
    /// Its own lock rather than a field of [`Screen`] for exactly that reason: `plan` and `finish`
    /// are one logical operation with the exchange in the middle, and a second tick interleaved
    /// between them would answer the previous tick's question — but holding the read loop's lock
    /// for that window would park superd's reader thread on a socket. Uncontended in practice:
    /// there is ONE scan thread, and nothing else takes this.
    scan: Mutex<PaneScan>,
    ticker: Ticker,
}

impl Detect {
    /// Detection for a pane that has not started yet.
    pub(crate) fn new(config: DetectConfig) -> Self {
        Self {
            config,
            foreground: Foreground::default(),
            screen: Mutex::new(Screen::default()),
            scan: Mutex::new(PaneScan::new()),
            ticker: Ticker::default(),
        }
    }

    /// Whether the foreground poll is wanted on this pane.
    pub(crate) const fn polls(&self) -> bool {
        self.config.foreground
    }

    /// Whether a screen scan loop is wanted on this pane.
    pub(crate) const fn scans(&self) -> bool {
        self.config.screen.is_some()
    }

    /// Ends both loops. Idempotent, and safe from inside one of them.
    pub(crate) fn stop(&self) {
        self.ticker.stop();
    }

    // ------------------------------------------------------------------ the read loop's taps

    /// Records one chunk for the next scan tick. Runs on the READ LOOP, so it does nothing but
    /// copy.
    ///
    /// The copy is the price of not blocking the reader: screend's exchange takes as long as it
    /// takes, and borrowing the frame across it would hold superd's reader thread for that whole
    /// window. A pane with no scan loop skips even that.
    pub(crate) fn note_output(&self, payload: &[u8]) {
        if payload.is_empty() || !self.scans() {
            return;
        }
        let mut screen = self.screen.lock().unwrap_or_else(PoisonError::into_inner);
        screen.pending.extend_from_slice(payload);
        screen.seq = screen.seq.wrapping_add(1);
    }

    /// Marks the resident grid stale — a resize, or any geometry change.
    ///
    /// The pending buffer is DROPPED with it, deliberately: those bytes were painted for the old
    /// grid, and the rebuild replays the ring at the new size instead. It is also what makes the
    /// scan's "the repaint has landed" test work — the rebuild tick itself carries no live output.
    pub(crate) fn mark_screen_dirty(&self) {
        if !self.scans() {
            return;
        }
        let mut screen = self.screen.lock().unwrap_or_else(PoisonError::into_inner);
        screen.pending = Vec::new();
        screen.dirty = true;
    }

    // ------------------------------------------------------------------------------ the folds

    /// One foreground sample, plus the clock tick that decays a finished turn.
    ///
    /// The tick is load-bearing rather than incidental: nothing else advances the host machine's
    /// clock, so without it a `done` pane would stay `done` for ever.
    pub(crate) fn sample_foreground(shared: &Shared, pty: &PtyProcess) {
        let now = clock::stamps().uptime;
        let name = Foreground::name(pty);
        let emission = shared.with_folds(|folds| folds.detector.sample(&name, now));
        publish(shared, &emission);
        let ticked = shared.with_folds(|folds| folds.detector.tick(now));
        publish(shared, &ticked);
        // The echo edge rides this poll as a BACKSTOP — the primary driver is the probe right after
        // a client's own write, where `ECHO` flips fastest around a password prompt. A no-echo
        // prompt that appears with no keystroke before it has only this.
        Self::sample_echo(shared, pty);
    }

    /// One termios `ECHO` sample, folded through the warm-up-gated latch.
    pub(crate) fn sample_echo(shared: &Shared, pty: &PtyProcess) {
        let echo_on = pty.echo_enabled();
        let message = shared.with_folds(|folds| folds.truths.fold_echo(echo_on, is_edge));
        if let Some(enabled) = message {
            shared.broadcast_control(&[WireMessage::InputEcho { enabled }]);
        }
    }

    /// The echo truth as a JOINING member must hear it — the re-anchor, not the fold.
    ///
    /// Answers the message to send rather than sending it, because a re-assert is addressed to one
    /// subscriber and this module does not know which.
    pub(crate) fn reassert_echo(shared: &Shared, pty: &PtyProcess) -> Option<WireMessage> {
        let echo_on = pty.echo_enabled();
        shared
            .with_folds(|folds| folds.truths.reanchor_echo(echo_on, is_edge))
            .map(|enabled| WireMessage::InputEcho { enabled })
    }

    /// The bytes a client typed, as the cancel/keystroke edge.
    ///
    /// Cheap on the steady path — the detector bails on its own status check before it looks at a
    /// single byte — which is why this may sit inline on the write path.
    pub(crate) fn fold_input(&self, shared: &Shared, bytes: &[u8]) {
        if !self.polls() {
            return;
        }
        let now = clock::stamps().uptime;
        let emission = shared.with_folds(|folds| folds.detector.user_input(bytes, now));
        publish(shared, &emission);
    }

    // ---------------------------------------------------------------------------- the scan tick

    /// One screen scan, start to finish. Answers how long until the next one.
    ///
    /// Runs ONLY on the scan thread, which is what lets [`PaneScan`] be `&mut` behind a lock nobody
    /// else contends for at exchange time: the plan and the finish are one logical operation, and a
    /// second tick interleaved between them would answer the previous tick's question.
    pub(crate) fn scan_once(&self, shared: &Shared, pty: &PtyProcess) -> Duration {
        let Some(ref oracle) = self.config.screen else {
            return Duration::from_secs_f64(AgentDetectionHold::SCAN_INTERVAL);
        };
        let now = clock::stamps().uptime;
        let grid = pty.window_size();
        let rows = grid.map_or(FALLBACK_ROWS, |grid| grid.rows);
        let cols = grid.map_or(FALLBACK_COLS, |grid| grid.cols);
        let agent = self.foreground.agent(pty, now);

        let (pending, needs_rebuild, seq) = {
            let mut screen = self.screen.lock().unwrap_or_else(PoisonError::into_inner);
            let pending = core::mem::take(&mut screen.pending);
            let dirty = screen.dirty;
            screen.dirty = false;
            (pending, dirty, screen.seq)
        };
        // Taken OUTSIDE the scan lock: the ring has its own. A chunk that lands between the flag
        // flip above and this snapshot is folded twice — tolerated, because the grid converges on
        // the next repaint, which is the same property a mid-ring start relies on.
        let rebuild = needs_rebuild.then(|| newest_history(shared, REBUILD_CAP_BYTES));

        let mut raw = rebuild.clone().unwrap_or_default();
        raw.extend_from_slice(&pending);

        // The SCAN lock, not the read loop's: it is held across the exchange below, and the read
        // loop must never wait on a socket. Nothing but this thread ever takes it.
        let mut scan = self.scan.lock().unwrap_or_else(PoisonError::into_inner);
        let plan = scan.plan(&ScanInput {
            payload_empty: raw.is_empty(),
            rebuild_replay: rebuild.is_some(),
            rows,
            cols,
            agent: agent.map(AgentKind::label),
            content_seq: seq,
            now,
        });
        let outcome = if plan.exchange {
            let label = if plan.label_suppressed {
                ""
            } else {
                agent.map_or("", AgentKind::label)
            };
            oracle
                .detect(&ScreenRequest {
                    pane: &self.config.pane_key,
                    agent: label,
                    raw: &raw,
                    rows,
                    cols,
                    reset: plan.reset,
                    rebuild_replay: rebuild.is_some(),
                    agent_changed: plan.agent_changed,
                })
                .map_or(Outcome::Failed, Outcome::Answered)
        } else {
            Outcome::Skipped
        };
        let output = scan.finish(&outcome);
        drop(scan);

        if let Some(detection) = output.publish {
            Self::fold_screen(shared, detection, now);
        }
        Duration::from_secs_f64(output.next_interval)
    }

    /// Folds one published screen detection and sends what it emits.
    fn fold_screen(shared: &Shared, detection: AgentScreenDetection, now: f64) {
        let emission = shared.with_folds(|folds| folds.detector.screen(detection, now));
        publish(shared, &emission);
    }

    // ---------------------------------------------------------------------------- the two loops

    /// The foreground poll, until the ticker is stopped.
    pub(crate) fn poll_loop(&self, shared: &Shared, pty: &PtyProcess) {
        while self.ticker.rest(self.config.poll_interval) {
            Self::sample_foreground(shared, pty);
        }
    }

    /// The screen scan, at whatever cadence the engine last asked for.
    pub(crate) fn scan_loop(&self, shared: &Shared, pty: &PtyProcess) {
        let mut interval = Duration::from_secs_f64(AgentDetectionHold::SCAN_INTERVAL);
        while self.ticker.rest(interval) {
            interval = self.scan_once(shared, pty);
        }
    }
}

/// The echo dedupe, spelled once: a sample is an edge iff it differs from what was last emitted.
///
/// Asked of the caller by [`Truths::fold_echo`](slopdesk_muxsession::truths::Truths::fold_echo)
/// rather than restated inside it, so the warm-up gate and the comparison stay separable.
const fn is_edge(sample: bool, last: bool) -> bool {
    sample != last
}

/// Sends whatever one fold emitted, in the order the detector chose.
///
/// Broadcast, not addressed: every message here describes an edge the PANE just crossed, and every
/// member that was attached for it must hear it. The re-asserts a joiner needs are a different
/// ladder — see [`Detect::reassert_echo`] and [`crate::session::PaneSession`]'s arrival paths.
fn publish(shared: &Shared, emission: &Emission) {
    if emission.is_empty() {
        return;
    }
    shared.broadcast_control(&emitted(emission));
}

/// One emission as the frames it spells, in the order the detector chose.
///
/// Separate from [`publish`] because the arrival ladder needs the SAME list addressed to one member
/// rather than broadcast — and a second spelling of this mapping is how a re-asserted status and a
/// live one come to disagree about a field.
pub(crate) fn emitted(emission: &Emission) -> Vec<WireMessage> {
    let mut messages = Vec::with_capacity(emission.slots().count_ones() as usize);
    if let Some(ref name) = emission.foreground {
        messages.push(WireMessage::ForegroundProcess { name: name.clone() });
    }
    if let Some(ref triple) = emission.status {
        messages.push(WireMessage::ClaudeStatus {
            state: triple.state,
            kind: triple.kind,
            label: triple.label.clone(),
        });
    }
    if let Some(ref intent) = emission.intent {
        messages.push(WireMessage::AgentSessionIntent(intent.clone()));
    }
    // An empty type-21 is the RETIREMENT, unambiguously: the sniffer drops empty OSC 0/2 bodies, so
    // nothing else on this wire spells one.
    if emission.title_retired {
        messages.push(WireMessage::Title(String::new()));
    }
    messages
}

/// The newest `cap` bytes of retained history — the rebuild's input.
///
/// Truncated from the FRONT, keeping the newest: a rebuild exists to reconstruct the CURRENT
/// screen, and the oldest bytes are the ones a repaint has already overwritten.
fn newest_history(shared: &Shared, cap: usize) -> Vec<u8> {
    let mut history = shared.snapshot_source(0).history;
    if history.len() > cap {
        history.drain(..history.len() - cap);
    }
    history
}

#[cfg(test)]
mod tests {
    use std::time::Instant;

    use slopdesk_agent::{Emission, StatusTriple};
    use slopdesk_wire::message::WireMessage;

    use super::{DetectConfig, Ticker, emitted};

    /// The stop is what a teardown pulls, and it has to be felt IMMEDIATELY — a loop that slept its
    /// interval would hold the teardown for as long as the engine last asked for.
    #[test]
    fn a_stopped_ticker_returns_at_once_and_stays_stopped() {
        let ticker = Ticker::default();
        ticker.stop();
        let began = Instant::now();
        assert!(
            !ticker.rest(std::time::Duration::from_secs(30)),
            "a rest after the stop returns false rather than parking",
        );
        assert!(
            began.elapsed() < std::time::Duration::from_secs(1),
            "and it does not wait out the interval to say so",
        );
        assert!(
            !ticker.rest(std::time::Duration::from_millis(1)),
            "the stop is permanent"
        );
    }

    /// A rest that nobody stops sleeps its interval and answers that the loop may go on.
    #[test]
    fn an_undisturbed_ticker_rests_and_keeps_the_loop_running() {
        let ticker = Ticker::default();
        assert!(ticker.rest(std::time::Duration::from_millis(5)));
    }

    /// The four slots, in the ORDER the detector chose: presence, then the richer status, then the
    /// intent, then the title retirement — which is a display consequence of the status dropping
    /// and so cannot precede it.
    #[test]
    fn an_emission_spells_its_slots_in_the_detectors_order() {
        let messages = emitted(&Emission {
            foreground: Some(String::from("claude")),
            status: Some(StatusTriple {
                state: 3,
                kind: 0,
                label: String::from("working"),
            }),
            intent: Some(String::from("fix the flake")),
            title_retired: true,
        });
        assert_eq!(messages, vec![
            WireMessage::ForegroundProcess {
                name: String::from("claude"),
            },
            WireMessage::ClaudeStatus {
                state: 3,
                kind: 0,
                label: String::from("working"),
            },
            WireMessage::AgentSessionIntent(String::from("fix the flake")),
            // Empty IS the retirement: the sniffer drops empty OSC 0/2 bodies, so nothing else on
            // this wire spells one.
            WireMessage::Title(String::new()),
        ]);
    }

    /// An emission that filled no slot spells nothing — which is what keeps an idle pane's control
    /// stream byte-identical to one with detection off.
    #[test]
    fn an_empty_emission_spells_nothing() {
        assert!(emitted(&Emission::default()).is_empty());
    }

    /// The off configuration is the one a test and a gated-off pane share, and both of its loops
    /// must read as absent — a scan loop with no oracle would tick for ever answering nothing.
    #[test]
    fn the_off_configuration_asks_for_neither_loop() {
        let detect = super::Detect::new(DetectConfig::off());
        assert!(!detect.polls());
        assert!(!detect.scans());
    }

    /// A pane with no scan loop does not pay for the screen tap: `note_output` copies nothing and
    /// the dirty mark is a branch. Stated as a behaviour rather than a benchmark — the read loop
    /// runs this per chunk on every pane in the host.
    #[test]
    fn a_pane_with_no_scan_loop_buffers_no_bytes() {
        let detect = super::Detect::new(DetectConfig::off());
        detect.note_output(b"a full screen of output");
        detect.mark_screen_dirty();
        let screen = detect
            .screen
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        assert!(screen.pending.is_empty(), "nothing was copied");
        assert!(!screen.dirty, "and nothing was marked");
        assert_eq!(screen.seq, 0, "so the idle-scan skip still reads unchanged");
    }
}
