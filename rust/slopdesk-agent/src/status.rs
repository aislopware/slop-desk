//! The rolled-up per-pane status, and the wire QUALIFIER byte that rides beside it.

/// The per-pane agent status the sidebar and pane chrome consume (docs/41 §4.3, docs/42 W7).
///
/// Glyphs (docs/42 W7): `None ⚪ | Idle 🟢 | Working 🟡 | Done 🔵 | NeedsPermission 🔴`.
/// [`NeedsPermission`](Self::NeedsPermission) is the "blocked" state — the agent is stalled on a
/// human. herdr and Warp call it *blocked*; this names it for the dominant cause and exposes
/// [`is_blocked`](Self::is_blocked) for the rollup vocabulary.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub enum ClaudeStatus {
    /// No agent here — no foreground process, session ended, or never started. ⚪
    #[default]
    None,
    /// Present and at rest: an empty compose box awaiting a fresh prompt. 🟢
    Idle,
    /// Actively working a turn — a prompt was submitted, or a tool is running. 🟡
    Working,
    /// Finished a turn and waiting to be seen; decays to [`Idle`](Self::Idle). 🔵
    Done,
    /// BLOCKED on a human: a permission prompt, an approval UI, a waiting-for-input dialog. 🔴
    NeedsPermission,
}

impl ClaudeStatus {
    /// Every status, in declaration order.
    pub const ALL: [Self; 5] = [
        Self::None,
        Self::Idle,
        Self::Working,
        Self::Done,
        Self::NeedsPermission,
    ];

    /// True when this status demands human attention (the "blocked" bucket).
    #[must_use]
    pub const fn is_blocked(self) -> bool {
        matches!(self, Self::NeedsPermission)
    }

    /// A short human label — the sidebar activity-summary fallback and the status-dot tooltip read
    /// this ONE source so they cannot drift. [`None`](Self::None) reads "idle" so a fallback
    /// summary is never the literal word *none*.
    #[must_use]
    pub const fn display_label(self) -> &'static str {
        match self {
            Self::None | Self::Idle => "idle",
            Self::Working => "working",
            Self::Done => "done",
            Self::NeedsPermission => "needs permission",
        }
    }

    /// Rollup priority — STRICTLY increasing urgency, and a total order:
    /// `None(0) < Idle(1) < Done(2) < Working(3) < NeedsPermission(4)`.
    ///
    /// This byte, not the enum, is what crosses the wire (type 27), so the codec need not depend on
    /// this crate.
    #[must_use]
    pub const fn urgency(self) -> u8 {
        match self {
            Self::None => 0,
            Self::Idle => 1,
            Self::Done => 2,
            Self::Working => 3,
            Self::NeedsPermission => 4,
        }
    }

    /// The inverse of [`urgency`](Self::urgency): the wire byte read back on the client.
    ///
    /// FORWARD-TOLERANT (validate-then-repair): an unknown or future byte degrades to
    /// [`None`](Self::None) rather than failing, so a hostile or newer datagram can never take a
    /// client down. `0..=4` round-trip exactly.
    #[must_use]
    pub const fn from_urgency(urgency: u8) -> Self {
        match urgency {
            1 => Self::Idle,
            2 => Self::Done,
            3 => Self::Working,
            4 => Self::NeedsPermission,
            _ => Self::None,
        }
    }

    /// The status TOKEN — the spelling that travels over the JSON control plane, where the byte
    /// does not.
    ///
    /// The binary wire carries [`urgency`](Self::urgency); the control socket's `agent-status`
    /// reply and the `ctl report` verb carry this string instead, because that surface is
    /// hand-typed by agents and a name survives a human reading it. The two spellings are the same
    /// enum, which is the point of both living here.
    #[must_use]
    pub const fn token(self) -> &'static str {
        match self {
            Self::None => "none",
            Self::Idle => "idle",
            Self::Working => "working",
            Self::Done => "done",
            Self::NeedsPermission => "needsPermission",
        }
    }

    /// The inverse of [`token`](Self::token), forward-tolerant in the same way
    /// [`from_urgency`](Self::from_urgency) is: an unknown or future token degrades to
    /// [`None`](Self::None) — "no agent here" — rather than failing, so a newer host cannot break
    /// an older client. Every token this crate emits round-trips exactly.
    #[must_use]
    pub fn from_token(token: &str) -> Self {
        match token {
            "idle" => Self::Idle,
            "working" => Self::Working,
            "done" => Self::Done,
            "needsPermission" => Self::NeedsPermission,
            _ => Self::None,
        }
    }

    /// Most-urgent rollup over a set of per-pane statuses (the sidebar and tab dot).
    ///
    /// Empty is [`None`](Self::None). Commutative, and ties are impossible because
    /// [`urgency`](Self::urgency) is a total order.
    pub fn rollup(statuses: impl IntoIterator<Item = Self>) -> Self {
        let mut winner = Self::None;
        for status in statuses {
            if status.urgency() > winner.urgency() {
                winner = status;
            }
        }
        winner
    }
}

/// Ordered by [`urgency`](ClaudeStatus::urgency), so `max` over a pane set IS the rollup.
impl PartialOrd for ClaudeStatus {
    fn partial_cmp(&self, other: &Self) -> Option<core::cmp::Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for ClaudeStatus {
    fn cmp(&self, other: &Self) -> core::cmp::Ordering {
        self.urgency().cmp(&other.urgency())
    }
}

/// The `kind` byte of the wire type-27 `claudeStatus` frame — the QUALIFIER on the status byte.
///
/// Historically it carried only the last hook `Notification` class, meaningful while the pane is
/// blocked and `0` otherwise; [`Quiet`](Self::Quiet) reuses that spare capacity on a NON-blocked
/// status to say something the state byte cannot.
///
/// The mapping is FORWARD-TOLERANT — an unknown or future byte degrades to [`None`](Self::None)
/// rather than failing — which is also what makes `Quiet` additive: an older client that never
/// heard of `4` reads it as a plain unqualified status and behaves exactly as before.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub enum AgentStatusKind {
    /// No qualifier — the common case, every status that is not a live block.
    #[default]
    None,
    /// `permission_prompt`: the block is an approval request.
    Permission,
    /// The block is a waiting-for-input prompt, `AskUserQuestion` included.
    WaitingForInput,
    /// Any other `Notification` class (informational).
    Other,
    /// QUIET: this status change is BOOKKEEPING, not news — deliver it to the dots and the chrome,
    /// but raise NO attention (no toast, no banner, no sound, no unread badge).
    ///
    /// The producers today are the `/compact` boundary, an interrupted turn, an Esc-cancelled
    /// dialog and the dissent watchdog correcting itself. All four land on an edge the client would
    /// otherwise read as a finished turn (`Working → Idle`, `NeedsPermission → Idle`), and all four
    /// are things the human did while looking at the pane.
    Quiet,
}

impl AgentStatusKind {
    /// The raw wire byte.
    #[must_use]
    pub const fn wire_byte(self) -> u8 {
        match self {
            Self::None => 0,
            Self::Permission => 1,
            Self::WaitingForInput => 2,
            Self::Other => 3,
            Self::Quiet => 4,
        }
    }

    /// Maps a raw wire byte, degrading an unknown or future value to [`None`](Self::None).
    #[must_use]
    pub const fn from_wire_byte(byte: u8) -> Self {
        match byte {
            1 => Self::Permission,
            2 => Self::WaitingForInput,
            3 => Self::Other,
            4 => Self::Quiet,
            _ => Self::None,
        }
    }

    /// TRUE when the qualified status change must raise no attention.
    #[must_use]
    pub const fn is_quiet(self) -> bool {
        matches!(self, Self::Quiet)
    }
}

#[cfg(test)]
mod tests {
    use super::{AgentStatusKind, ClaudeStatus};

    #[test]
    fn the_urgency_byte_round_trips_every_status() {
        for status in ClaudeStatus::ALL {
            assert_eq!(ClaudeStatus::from_urgency(status.urgency()), status);
        }
    }

    #[test]
    fn an_unknown_urgency_degrades_rather_than_failing() {
        for byte in [5_u8, 6, 42, 255] {
            assert_eq!(ClaudeStatus::from_urgency(byte), ClaudeStatus::None, "{byte}");
        }
    }

    #[test]
    fn the_rollup_is_the_most_urgent_pane() {
        assert_eq!(ClaudeStatus::rollup([]), ClaudeStatus::None);
        assert_eq!(
            ClaudeStatus::rollup([ClaudeStatus::Idle, ClaudeStatus::Working, ClaudeStatus::Done]),
            ClaudeStatus::Working
        );
        assert_eq!(
            ClaudeStatus::rollup([ClaudeStatus::NeedsPermission, ClaudeStatus::Working]),
            ClaudeStatus::NeedsPermission
        );
        // Commutative.
        assert_eq!(
            ClaudeStatus::rollup([ClaudeStatus::Working, ClaudeStatus::NeedsPermission]),
            ClaudeStatus::NeedsPermission
        );
    }

    #[test]
    fn the_order_is_the_urgency_order_so_max_is_the_rollup() {
        let mut ladder = ClaudeStatus::ALL;
        ladder.sort_unstable();
        assert_eq!(ladder, [
            ClaudeStatus::None,
            ClaudeStatus::Idle,
            ClaudeStatus::Done,
            ClaudeStatus::Working,
            ClaudeStatus::NeedsPermission,
        ]);
        assert_eq!(ladder.into_iter().max(), Some(ClaudeStatus::NeedsPermission));
    }

    #[test]
    fn nothing_ever_reads_as_the_literal_word_none() {
        assert_eq!(ClaudeStatus::None.display_label(), "idle");
        assert!(ClaudeStatus::NeedsPermission.is_blocked());
        assert!(!ClaudeStatus::Working.is_blocked());
    }

    #[test]
    fn the_kind_byte_round_trips_and_tolerates_the_future() {
        for byte in 0_u8..=4 {
            assert_eq!(AgentStatusKind::from_wire_byte(byte).wire_byte(), byte);
        }
        assert_eq!(AgentStatusKind::from_wire_byte(9), AgentStatusKind::None);
        assert!(AgentStatusKind::Quiet.is_quiet());
        assert!(!AgentStatusKind::Permission.is_quiet());
    }
}
