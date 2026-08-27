//! screend, as the two doors a session asks its screen questions through.
//!
//! [`slopdesk_hostsession`] declares both as traits and implements neither, for one reason stated
//! twice in its own source: a session that linked the screen client would SPAWN A DAEMON the moment
//! a test constructed one. So the socket lives here, where a process already exists to own it, and
//! a session handed `None` for either simply does less — raw replay, no scan loop — rather than
//! failing.
//!
//! ## Two questions, two verbs, one connection pool
//! `compose` renders a screen; `detect` folds bytes into a resident grid and runs the rule ladder
//! over it. Both go to the same daemon over the same pooled connection, which is why both doors
//! take the same [`ScreenClient`] rather than each opening its own — forty panes scanning is forty
//! callers, not forty sockets.
//!
//! ## The two `Verdict`s are not the same type, and that is the boundary working
//! [`slopdesk_screenwire::Verdict`] is what came off a socket and [`slopdesk_agent::Verdict`] is
//! what a rule ladder reasons about. They carry the same nine facts today; giving either crate a
//! `From` for the other would make the wire's shape the domain's shape for ever, so the copy lives
//! HERE, in the one crate that has both in scope — the same rule `peer.rs` follows for the sixteen
//! bytes of a connection id.

use std::sync::Arc;

use slopdesk_agent::screen::{AgentScreenDetection, AgentScreenState};
use slopdesk_hostsession::{ScreenOracle, ScreenRequest, SnapshotPolicy};
use slopdesk_screenclient::{DetectFlags, ScreenClient};
use slopdesk_screenwire::State;

/// The default warm-reattach threshold: below this many pending bytes, replay raw.
///
/// Four megabytes, the Swift's number. It is a floor on being WORTH it rather than a limit on what
/// is possible: under it, byte-exact continuation beats a wipe and a re-render, and that describes
/// every ordinary reconnect.
const DEFAULT_WARM_THRESHOLD_BYTES: usize = 4 * 1024 * 1024;

/// The state-transfer composer: history in, the screen it produces out.
#[derive(Debug)]
pub struct ScreendSnapshot {
    client: Arc<ScreenClient>,
    warm_threshold_bytes: usize,
}

impl ScreendSnapshot {
    /// The production policy, or `None` when `SLOPDESK_SCROLLBACK_SNAPSHOT=0` turned it off.
    ///
    /// The threshold is `SLOPDESK_SNAPSHOT_WARM_BYTES`; anything that will not parse as a byte
    /// count leaves the default in place rather than disabling the composer, because a typo in
    /// a tuning knob should not silently cost every reattach its state transfer.
    #[must_use]
    pub fn from_environment(client: &Arc<ScreenClient>) -> Option<Self> {
        if std::env::var("SLOPDESK_SCROLLBACK_SNAPSHOT").is_ok_and(|value| value == "0") {
            return None;
        }
        let warm_threshold_bytes = std::env::var("SLOPDESK_SNAPSHOT_WARM_BYTES")
            .ok()
            .and_then(|raw| raw.parse().ok())
            .unwrap_or(DEFAULT_WARM_THRESHOLD_BYTES);
        Some(Self {
            client: Arc::clone(client),
            warm_threshold_bytes,
        })
    }
}

impl SnapshotPolicy for ScreendSnapshot {
    fn warm_threshold_bytes(&self) -> usize {
        self.warm_threshold_bytes
    }

    /// The rendered screen, or `history` unchanged when screend could not answer.
    ///
    /// Falling back to the RAW bytes rather than to nothing is what makes a screend outage cost
    /// latency instead of scrollback: the caller ships them as an ordinary replay, and the client
    /// sees the history it would have seen before the composer existed.
    ///
    /// `reassert_input_modes` is TRUE here and false on the journal path (`transcripts.rs`), and
    /// the difference is what the bytes front: this screen fronts a LIVE session that may still
    /// be inside a TUI, so the modes it was left in have to be re-established after the render
    /// — nothing in a rendered grid says `?1002h`.
    fn compose(&self, history: &[u8], rows: u16, cols: u16) -> Vec<u8> {
        self.client
            .compose(history, usize::from(rows), usize::from(cols), true)
            .unwrap_or_else(|_| history.to_vec())
    }
}

/// The scan door: one pane's newest bytes folded into its resident grid, and the ladder's answer.
#[derive(Debug)]
pub struct ScreendOracle {
    client: Arc<ScreenClient>,
}

impl ScreendOracle {
    /// Asks `client` every scan question.
    #[must_use]
    pub fn new(client: &Arc<ScreenClient>) -> Self {
        Self {
            client: Arc::clone(client),
        }
    }
}

impl ScreenOracle for ScreendOracle {
    /// screend's verdict, or `None` for an exchange that failed.
    ///
    /// `None` is NOT a fallback verdict, and the session is explicit that it folds the absence as a
    /// failed scan rather than as "nothing on screen": a detection read off a grid whose last fold
    /// was lost is how a dismissed dialog gets reported as a live one.
    fn detect(&self, request: &ScreenRequest<'_>) -> Option<slopdesk_agent::Verdict> {
        let answered = self
            .client
            .detect(
                request.pane,
                request.agent,
                request.raw,
                usize::from(request.rows),
                usize::from(request.cols),
                DetectFlags {
                    reset: request.reset,
                    rebuild_replay: request.rebuild_replay,
                    agent_changed: request.agent_changed,
                },
            )
            .ok()?;
        Some(slopdesk_agent::Verdict {
            detection: AgentScreenDetection {
                state: domain_state(answered.state),
                skip_state_update: answered.skip_state_update,
                visible_idle: answered.visible_idle,
                visible_blocker: answered.visible_blocker,
                visible_working: answered.visible_working,
                matched_rule_id: answered.matched_rule_id,
                fallback_reason: answered.fallback_reason,
            },
            frame_open: answered.frame_open,
            frame_generation: answered.frame_generation,
        })
    }
}

/// The wire's four-way state as the domain's.
///
/// Exhaustive on purpose rather than a numeric cast: the two enums agree today, and a variant added
/// to one of them should stop this compiling instead of quietly landing as a neighbour.
const fn domain_state(state: State) -> AgentScreenState {
    match state {
        State::Idle => AgentScreenState::Idle,
        State::Working => AgentScreenState::Working,
        State::Blocked => AgentScreenState::Blocked,
        State::Unknown => AgentScreenState::Unknown,
    }
}
