//! Which connect attempt still owns the pane, and what a `.disconnected` edge MEANS.
//!
//! One pane's client is dialled from four places — the user's "Reconnect Pane", the leaf's
//! connect-on-remount `.task`, `WorkspaceStore::redialDisconnectedPanes` when the app connection
//! comes back, and the reconnect campaign — while the host may end the same channel underneath for
//! two entirely different reasons. The near side owns the tasks, the teardown and the FIFO; what is
//! HERE is the four scalars every one of those paths reads before deciding whether its own work is
//! still wanted.
//!
//! ## The generation
//!
//! `connect()` captures a number before the handshake `await` and re-checks it after. A teardown, a
//! reconnect or a second connect landing during that suspension means the post-await status writes
//! belong to an attempt nobody is waiting for any more. Without the check, the `do` branch paints
//! an already-torn-down pane `.connected` and overwrites its session id — a green dot over a dead
//! transport, which is the failure this codebase keeps closing.
//!
//! ## The three latches, and why they are three
//!
//! A `.disconnected` event says nothing about WHY, and the three whys need three different endings:
//!
//! - **A deliberate close.** The user asked. Nothing dials, nothing spins, and a `.reconnected`
//!   still buffered in the broadcaster must not whitewash the pane back to green.
//! - **A reap** ([`CloseCause::Retired`]) — the host deleted the PANE, and answers `channelClose`
//!   FIRST, document frame SECOND. In that window this client still has the pane on screen with a
//!   dead channel under it, and every AUTOMATIC dial path would re-open it — which for a session
//!   the host no longer holds is a fresh SPAWN. So the automatic paths are gated until an EXPLICIT
//!   dial.
//! - **An eviction** ([`CloseCause::Evicted`]) — the host dropped this SUBSCRIBER from a pane that
//!   is still running. Nothing will ever remove that pane from this client's topology, so gating
//!   the automatic paths on it strands the pane undiallable for the process lifetime. The asymmetry
//!   is the decision: an eviction reads `.disconnected` (the campaign's instant re-dial would
//!   re-join only to be evicted again, billing the host a state transfer every lap) but it does NOT
//!   gate the coarse one-shot paths, which are exactly the moments this client is likely healthy
//!   again.
//!
//! Two latches that look alike and clear on different events is what makes this worth a type: the
//! near side asks [`ConnectRun::may_auto_dial`] and [`ConnectRun::disconnect_is_quiet`] rather than
//! spelling the boolean algebra out at each of the four call sites.
//!
//! ## What deliberately does not cross
//!
//! The chained `connectTask`, the teardown order, the OUT FIFO and its single drain. Those are
//! ordering arguments about main-actor hops and task lifetimes, and a `Task` slot is not a number.

/// Why the host ended the channel, as the near side learns it from `hostChannelCloseReason`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CloseCause {
    /// The link died. Nothing was said about this pane, so the campaign is free to retry.
    Link,
    /// The host reaped the PANE under this channel.
    Retired,
    /// The host evicted this subscriber from a pane that is still running.
    Evicted,
}

impl CloseCause {
    /// The tag the FFI layer carries it as. An unknown tag reads as [`Self::Link`] — the cause that
    /// latches nothing, which is the safe reading of a byte no version of this enum wrote.
    #[must_use]
    pub const fn from_tag(tag: u8) -> Self {
        match tag {
            1 => Self::Retired,
            2 => Self::Evicted,
            _ => Self::Link,
        }
    }
}

/// The scalars of one pane client's connect ladder.
///
/// `Copy`, like every other all-scalar value in this crate: the LIVE state is the one the near
/// side's FFI handle owns, and every mutation runs through a `&mut` borrow of it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct ConnectRun {
    generation: u64,
    deliberately_closed: bool,
    retired_by_host: bool,
    evicted_by_host: bool,
}

impl ConnectRun {
    /// A pane that has never dialled.
    #[must_use]
    pub const fn new() -> Self {
        Self {
            generation: 0,
            deliberately_closed: false,
            retired_by_host: false,
            evicted_by_host: false,
        }
    }

    /// Opens an EXPLICIT attempt and answers the generation it must quote after the handshake.
    ///
    /// Clears all three latches in the same step: an explicit re-dial overrides either host close,
    /// because the user is asking for a shell on this pane and the near side builds a client that
    /// carries none of the old one's state. Generations start at 1, so zero is never a live one.
    pub const fn begin(&mut self) -> u64 {
        self.deliberately_closed = false;
        self.retired_by_host = false;
        self.evicted_by_host = false;
        self.generation = self.generation.wrapping_add(1);
        self.generation
    }

    /// Whether the attempt born under `generation` is still the one that owns this pane.
    ///
    /// The near side pairs this with its own client-identity check: the same attempt with a
    /// REPLACED client is superseded too, and object identity is not a number.
    #[must_use]
    pub const fn is_current(&self, generation: u64) -> bool {
        self.generation != 0 && self.generation == generation
    }

    /// The generation the newest attempt was born under.
    #[must_use]
    pub const fn generation(&self) -> u64 {
        self.generation
    }

    /// Latches a deliberate close, so a trailing `.disconnected` is not read as a drop to retry and
    /// a buffered `.reconnected` cannot paint the pane green again.
    ///
    /// Does NOT supersede on its own: the pane VM's `disconnect()` tears the client down and has no
    /// in-flight handshake to disown, while the app connection's does — it calls
    /// [`Self::supersede`] in the same breath. Two verbs, because they are two facts.
    pub const fn close_deliberately(&mut self) {
        self.deliberately_closed = true;
    }

    /// Retires every attempt in flight WITHOUT saying the close was deliberate.
    ///
    /// This is the iOS background unpin: the supervisor must stop cleanly, but the app did not
    /// choose to disconnect and the next foreground `resume()` must not be read as a re-dial after
    /// a user's Cancel.
    pub const fn supersede(&mut self) {
        self.generation = self.generation.wrapping_add(1);
    }

    /// Clears the deliberate-close latch without opening an attempt.
    ///
    /// One caller: the video-only automation seam, which declares the app connected against a host
    /// that serves UDP and has no mux to pin. Nothing dialled, so nothing may be superseded.
    pub const fn admit_without_dialling(&mut self) {
        self.deliberately_closed = false;
    }

    /// Latches what the host said on a `.disconnected` edge. [`CloseCause::Link`] latches nothing.
    pub const fn note_host_close(&mut self, cause: CloseCause) {
        match cause {
            CloseCause::Link => {},
            CloseCause::Retired => self.retired_by_host = true,
            CloseCause::Evicted => self.evicted_by_host = true,
        }
    }

    /// Whether an AUTOMATIC dial path may proceed — the remount `.task` and the app-connection
    /// fan-out.
    ///
    /// A reap gates them; an eviction deliberately does not. See this module's header for why the
    /// two host closes answer differently.
    #[must_use]
    pub const fn may_auto_dial(&self) -> bool {
        !self.retired_by_host
    }

    /// Whether a `.disconnected` edge should read as a definite disconnect rather than as the start
    /// of a reconnect campaign.
    ///
    /// True for all three latches: both host closes ARE deliberate, just decided at the other end,
    /// and no campaign follows either — showing "reconnecting" would be a spinner for a retry
    /// nobody is making. That an eviction is recoverable does not make it a retry: what
    /// recovers it is the fan-out or the user.
    #[must_use]
    pub const fn disconnect_is_quiet(&self) -> bool {
        self.deliberately_closed || self.retired_by_host || self.evicted_by_host
    }

    /// Whether a `.reconnected` event may still be acted on.
    ///
    /// A late one can be drained from the broadcaster buffer AFTER a deliberate disconnect — a
    /// buffered element is delivered even post-cancel — and applying it wedges the pane at
    /// `.connected` with a stale session id over a dead transport.
    #[must_use]
    pub const fn reconnect_is_welcome(&self) -> bool {
        !self.deliberately_closed
    }

    /// Whether the near side closed this pane on purpose, for the reconnect fold that takes it as
    /// an input of its own.
    #[must_use]
    pub const fn was_closed_deliberately(&self) -> bool {
        self.deliberately_closed
    }
}

#[cfg(test)]
mod tests {
    use super::{CloseCause, ConnectRun};

    #[test]
    fn a_fresh_pane_owns_no_attempt_and_dials_freely() {
        let run = ConnectRun::new();
        assert_eq!(run.generation(), 0);
        assert!(!run.is_current(0), "zero is never a live generation");
        assert!(run.may_auto_dial());
        assert!(!run.disconnect_is_quiet());
        assert!(run.reconnect_is_welcome());
    }

    #[test]
    fn a_superseded_attempt_stops_owning_the_pane() {
        let mut run = ConnectRun::new();
        let first = run.begin();
        assert!(run.is_current(first));
        let second = run.begin();
        assert!(
            !run.is_current(first),
            "the handshake it is still inside is stale"
        );
        assert!(run.is_current(second));
    }

    #[test]
    fn a_reap_gates_the_automatic_paths_and_an_eviction_does_not() {
        let mut reaped = ConnectRun::new();
        reaped.begin();
        reaped.note_host_close(CloseCause::Retired);
        assert!(
            !reaped.may_auto_dial(),
            "an automatic dial would SPAWN a fresh session"
        );
        assert!(reaped.disconnect_is_quiet());

        let mut evicted = ConnectRun::new();
        evicted.begin();
        evicted.note_host_close(CloseCause::Evicted);
        assert!(
            evicted.may_auto_dial(),
            "the pane is still running and the fan-out is the way back"
        );
        assert!(
            evicted.disconnect_is_quiet(),
            "but the campaign's instant retry would only be evicted again"
        );
    }

    #[test]
    fn a_dead_link_latches_nothing() {
        let mut run = ConnectRun::new();
        run.begin();
        run.note_host_close(CloseCause::Link);
        assert!(run.may_auto_dial());
        assert!(
            !run.disconnect_is_quiet(),
            "a fresh drop is what the campaign is for"
        );
    }

    #[test]
    fn an_explicit_dial_clears_either_host_close() {
        let mut run = ConnectRun::new();
        run.begin();
        run.note_host_close(CloseCause::Retired);
        run.note_host_close(CloseCause::Evicted);
        run.close_deliberately();
        run.begin();
        assert!(run.may_auto_dial());
        assert!(!run.disconnect_is_quiet());
        assert!(run.reconnect_is_welcome());
    }

    #[test]
    fn superseding_stops_the_supervisor_without_claiming_the_user_asked() {
        let mut run = ConnectRun::new();
        let attempt = run.begin();
        run.supersede();
        assert!(!run.is_current(attempt), "the in-flight establish is disowned");
        assert!(
            !run.was_closed_deliberately(),
            "a background unpin is not a Cancel, and the next resume must not read as one"
        );
    }

    #[test]
    fn the_automation_seam_admits_without_disowning_an_attempt() {
        let mut run = ConnectRun::new();
        let attempt = run.begin();
        run.close_deliberately();
        run.admit_without_dialling();
        assert!(
            run.is_current(attempt),
            "nothing was dialled, so nothing is superseded"
        );
        assert!(!run.was_closed_deliberately());
    }

    #[test]
    fn a_deliberate_close_refuses_a_buffered_reconnect() {
        let mut run = ConnectRun::new();
        run.begin();
        run.close_deliberately();
        assert!(!run.reconnect_is_welcome());
        assert!(run.was_closed_deliberately());
        assert!(
            run.may_auto_dial(),
            "the user may dial again; only the HOST's reap gates the automatic paths"
        );
    }

    #[test]
    fn an_unknown_close_tag_latches_nothing() {
        assert_eq!(CloseCause::from_tag(0), CloseCause::Link);
        assert_eq!(CloseCause::from_tag(1), CloseCause::Retired);
        assert_eq!(CloseCause::from_tag(2), CloseCause::Evicted);
        assert_eq!(CloseCause::from_tag(200), CloseCause::Link);
    }
}
