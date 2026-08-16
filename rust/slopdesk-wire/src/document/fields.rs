//! The field vocabulary of each object kind, and the two verdicts that ride on it.
//!
//! These bytes are RAW WIRE VALUES, frozen the moment a golden vector carries one. They live beside
//! [`WorkspaceObjectKind`](super::WorkspaceObjectKind) because the host writes them and the client
//! reads them, and neither may guess: a field number invented independently on two sides is a
//! silent divergence with NO decoder to catch it. Every value is length-prefixed, so a mis-numbered
//! field decodes perfectly cleanly into the wrong meaning.
//!
//! Nothing in the codec maps THROUGH these constants. An unknown field byte is kept verbatim, just
//! like an unknown kind tag — they are a naming discipline for the two ends, not a validation gate.

/// Fields of the singleton ROOT object, addressed by [`super::ROOT_OBJECT_ID`].
pub mod root {
    /// The order sessions appear in.
    pub const SESSION_ORDER: u8 = 0;
    /// Which session is selected.
    pub const ACTIVE_SESSION_ID: u8 = 1;
    /// The host's display name.
    pub const HOST_DISPLAY_NAME: u8 = 2;
    /// The saved canvas layouts.
    pub const LAYOUT_PRESETS: u8 = 3;
    /// The saved launch configurations.
    pub const LAUNCH_PRESETS: u8 = 4;
    /// The saved project profiles.
    pub const SESSION_TEMPLATES: u8 = 5;
    /// The reopen-closed-tab ring.
    pub const CLOSED_TAB_RING: u8 = 6;
    /// The host-owned session that parents panes with no client — the ones a `ctl` verb spawned.
    pub const UNATTACHED_SESSION_ID: u8 = 7;
}

/// Fields of a SESSION.
pub mod session {
    /// Its display name.
    pub const NAME: u8 = 0;
    /// The order its tabs appear in.
    pub const TAB_ORDER: u8 = 1;
    /// Which tab is selected.
    pub const ACTIVE_TAB_ID: u8 = 2;
    /// The panes detached from every tab.
    pub const DETACHED_PANES: u8 = 3;
    /// The focus history, most recent first.
    pub const FOCUS_MRU: u8 = 4;
}

/// Fields of a TAB.
pub mod tab {
    /// Its title.
    pub const TITLE: u8 = 0;
    /// The session it belongs to.
    pub const SESSION_ID: u8 = 1;
    /// The split tree's SHAPE. The divider weights are deliberately not in it.
    pub const LAYOUT_STRUCTURE: u8 = 2;
    /// Which pane has focus.
    pub const ACTIVE_PANE_ID: u8 = 3;
    /// The zoomed pane, if any.
    pub const ZOOMED_PANE_ID: u8 = 4;
    /// Whether typing is broadcast to every pane.
    pub const SYNC_INPUT_ARMED: u8 = 5;
    /// Whether the person renamed it explicitly.
    pub const USER_RENAMED: u8 = 6;
}

/// Fields of a PANE, addressed by the host-minted pane id.
///
/// Split by OWNERSHIP, and the split is load-bearing:
///
/// - **Topology** — [`KIND`](pane::KIND), [`TITLE`](pane::TITLE),
///   [`USER_RENAMED`](pane::USER_RENAMED), [`VIDEO_TARGET`](pane::VIDEO_TARGET) and
///   [`SPAWN_CWD`](pane::SPAWN_CWD) — is written by an intent and PERSISTED.
/// - **Liveness** — everything else — is derived from a running process, republished after every
///   host restart, and deliberately NOT persisted. Restoring "a command is running" for a process
///   that no longer exists is the fake-live render the whole document exists to prevent.
pub mod pane {
    /// What the pane is.
    pub const KIND: u8 = 0;
    /// Its persisted title.
    pub const TITLE: u8 = 1;
    /// Whether the person renamed it explicitly.
    pub const USER_RENAMED: u8 = 2;
    /// The title the shell last asserted over OSC.
    pub const LIVE_TITLE: u8 = 3;
    /// The HOST's verdict on whether the live title still describes what is on screen.
    pub const TITLE_FRESH: u8 = 4;
    /// Its working directory.
    pub const CWD: u8 = 5;
    /// The project the directory belongs to.
    pub const PROJECT_KEY: u8 = 6;
    /// The foreground process's name.
    pub const FOREGROUND_PROCESS: u8 = 7;
    /// The host's own open command block — what lets the host render a sidebar row for a client
    /// that has materialized zero bytes.
    pub const RUNNING_COMMAND: u8 = 8;
    /// `[u8 state][u8 kind]` — the agent's urgency and its notification class.
    pub const AGENT_STATE: u8 = 9;
    /// The agent's label.
    pub const AGENT_LABEL: u8 = 10;
    /// What the agent says it is doing.
    pub const AGENT_INTENT: u8 = 11;
    /// `[u8 state][u8 percent]` — the OSC 9;4 progress pair.
    pub const PROGRESS: u8 = 12;
    /// Whether a command is running right now.
    pub const COMMAND_RUNNING: u8 = 13;
    /// The last command's exit code.
    pub const LAST_EXIT_CODE: u8 = 14;
    /// How long the last command took, in milliseconds.
    pub const LAST_DURATION_MS: u8 = 15;
    /// `[u16 cols][u16 rows]` — published so a client not contributing to the size fold letterboxes
    /// instead of guessing.
    pub const GRID: u8 = 16;
    /// How real the pane's process is. ALWAYS emitted: its presence is the pane's existence.
    pub const LIVENESS: u8 = 17;
    /// A monotone counter bumped on every working-to-done edge.
    ///
    /// The host holds ZERO per-client acknowledgement state; each viewer compares this against its
    /// own device-local mark, which is what makes "have I seen this finish" a client question.
    pub const COMPLETION_EPOCH: u8 = 18;
    /// Milliseconds since the epoch at the last observed activity. Zero is never.
    pub const LAST_ACTIVITY_MS: u8 = 19;
    /// Which remote display or window a video pane streams.
    pub const VIDEO_TARGET: u8 = 20;
    /// Where the host should spawn the PTY.
    pub const SPAWN_CWD: u8 = 21;
}

/// Fields of one DIVIDER, addressed by its split-node id.
///
/// A weight is its own object rather than part of the tab's layout blob so two clients dragging two
/// different dividers write two different keys and cannot clobber each other.
pub mod split_node {
    /// Its share of the parent axis.
    pub const WEIGHT: u8 = 0;
}

/// Fields of a PROJECT, addressed by a id derived from its key.
pub mod project {
    /// The project key itself.
    pub const KEY: u8 = 0;
    /// The git summary verbatim, so a client that has never seen this host renders the git line
    /// immediately instead of waiting for the first filesystem edge.
    pub const GIT_SUMMARY: u8 = 1;
}

/// How real a pane's process is.
///
/// The distinction a client cannot make for itself: after a host restart the topology is restored
/// from disk while the detached-session store is in-process and empty, so every restored pane is
/// [`Dead`](PaneLivenessState::Dead) — and must render STALE rather than fake-live.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub enum PaneLivenessState {
    /// A live PTY with a client attached.
    #[default]
    Attached = 0,
    /// A live PTY with no client attached. The shell keeps running.
    Detached = 1,
    /// No process: restored from disk, evicted from the store, or the child exited.
    Dead = 2,
}

impl PaneLivenessState {
    /// Every state, in wire order.
    pub const ALL: [Self; 3] = [Self::Attached, Self::Detached, Self::Dead];

    /// The state a byte names.
    ///
    /// An unknown byte from a NEWER host reads as [`Dead`](Self::Dead). Rendering a live pane as
    /// stale is a cosmetic miss; rendering a dead pane as live is the fake-live bug — so the
    /// unknown case degrades toward the safe side rather than toward the pretty one.
    #[must_use]
    pub const fn from_byte(byte: u8) -> Self {
        match byte {
            0 => Self::Attached,
            1 => Self::Detached,
            _ => Self::Dead,
        }
    }

    /// The on-wire byte.
    #[must_use]
    pub const fn as_byte(self) -> u8 {
        self as u8
    }

    /// Whether a process exists at all.
    #[must_use]
    pub const fn is_live(self) -> bool {
        matches!(self, Self::Attached | Self::Detached)
    }
}

/// Whether a pane's live title still describes what is on screen.
///
/// A pure function of two host-owned stamps, in seconds on the host's own timeline. It is the HOST
/// that ships the verdict rather than the two stamps, because the client-side comparison this
/// replaces failed permanently whenever either of its in-memory stamp tables was empty — which is
/// every cold client start.
///
/// The four rules, in order:
///
/// 1. A DEAD pane has no fresh title. Its restored title describes a process that no longer exists,
///    and without this rule the next rule would trust it forever: restored scrollback is appended
///    without control bytes, so a replayed escape can never regenerate the title push that would
///    correct it.
/// 2. No title at all is not a freshness question.
/// 3. No open command block means TRUST. A shell with no block markers never opens one, and must
///    not lose its title for it.
/// 4. Otherwise the title is fresh exactly when it was stamped at or after the current command
///    started — before that, it describes whatever ran previously.
#[must_use]
pub fn title_is_fresh(
    title_stamped_at: Option<f64>,
    command_started_at: Option<f64>,
    liveness: PaneLivenessState,
) -> bool {
    if !liveness.is_live() {
        return false;
    }
    let Some(stamped) = title_stamped_at else {
        return false;
    };
    let Some(started) = command_started_at else {
        return true;
    };
    stamped >= started
}

#[cfg(test)]
mod tests {
    use super::{PaneLivenessState, pane, root, title_is_fresh};

    #[test]
    fn an_unknown_liveness_byte_degrades_to_dead() {
        assert_eq!(PaneLivenessState::from_byte(0), PaneLivenessState::Attached);
        assert_eq!(PaneLivenessState::from_byte(2), PaneLivenessState::Dead);
        assert_eq!(
            PaneLivenessState::from_byte(99),
            PaneLivenessState::Dead,
            "rendering a dead pane live is the bug; rendering a live one stale is cosmetic",
        );
    }

    #[test]
    fn every_liveness_state_round_trips_its_byte() {
        for state in PaneLivenessState::ALL {
            assert_eq!(PaneLivenessState::from_byte(state.as_byte()), state);
        }
    }

    #[test]
    fn a_dead_pane_never_has_a_fresh_title() {
        assert!(
            !title_is_fresh(Some(100.0), None, PaneLivenessState::Dead),
            "the restored title describes a process that no longer exists",
        );
    }

    #[test]
    fn a_shell_with_no_command_block_keeps_its_title() {
        assert!(title_is_fresh(Some(100.0), None, PaneLivenessState::Attached));
    }

    #[test]
    fn a_title_stamped_before_the_current_command_is_stale() {
        assert!(!title_is_fresh(
            Some(90.0),
            Some(100.0),
            PaneLivenessState::Attached
        ));
        assert!(title_is_fresh(
            Some(100.0),
            Some(100.0),
            PaneLivenessState::Attached
        ));
        assert!(title_is_fresh(
            Some(110.0),
            Some(100.0),
            PaneLivenessState::Attached
        ));
    }

    #[test]
    fn no_title_is_not_a_freshness_question() {
        assert!(!title_is_fresh(None, None, PaneLivenessState::Attached));
    }

    #[test]
    fn the_field_numbers_are_the_ones_on_the_wire() {
        assert_eq!(root::SESSION_ORDER, 0);
        assert_eq!(pane::KIND, 0);
        assert_eq!(pane::LIVENESS, 17);
        assert_eq!(pane::SPAWN_CWD, 21);
    }
}
