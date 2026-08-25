//! Which run of the workspace channel is speaking, what it still owns, and whose presence clock
//! wins.
//!
//! The client end of `channelClass 1` (docs/45 §5.1) is a loop: open → await the ack → subscribe →
//! apply → ack, restarted by the connection layer every time a link comes up. Nearly all of it is
//! I/O and `Task` discipline, and that half stays on the near side — the two ordered drains, the
//! bounded handshake race, the optimistic patch staged into the mirror. What is HERE is the part
//! that is neither: the four scalars three concurrent callers read to decide whether their own work
//! is still wanted.
//!
//! ## The three races this exists to settle
//!
//! **A dying run must not overwrite a live one.** `stop()` and a later `start()` both publish, and
//! the run they superseded is still unwinding somewhere behind an `await`. Every publish from
//! inside a run carries the GENERATION it was born under, and one that no longer matches says
//! nothing. Without it a channel that reconnected in the same turn reports itself `closed` a moment
//! after going live, and nothing reopens it.
//!
//! **A channel must be released exactly once.** Both `stop()` and the run's own exit path release
//! the channel by id, and a second release tears down a pooled connection a reconnect has already
//! rebuilt under the same key. Whoever CLAIMS the id first wins, and the loser does nothing:
//! [`ChannelRun::release_if_owned`] is that claim, and it clears the slot in the same step.
//!
//! **A presence clock must never walk backwards.** The host keeps the newest clock per subscriber
//! and ignores anything older, so two updates minted in one turn and published out of order leave
//! everyone else looking at the view the user already left, permanently. Minting is monotone here;
//! the ORDER they reach the wire in is the single drain's job on the near side, and neither half
//! works without the other.
//!
//! ## What deliberately does not cross
//!
//! No identity, no queue, no task. The presence UPDATE — two pane ids and a viewport — is a value
//! the codec already owns, and the dirty guard that drops an unchanged one is an equality on those
//! very fields, so it stays where they live. The two drain slots are ordering arguments about
//! main-actor hops, not decisions. The mirror's own verdicts are [`crate::mirror_fold`]'s, and
//! re-crossing one to be told which request to write would be a crossing for its own sake.

/// Which rung of the channel's own lifecycle a client is on.
///
/// The `state_num` beside [`RunState::Live`] is part of the VALUE: a client that acks 5 and then
/// acks 6 has changed state, and a publish that de-duplicated on the tag alone would swallow every
/// document frame after the first.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RunState {
    /// Nothing open, nothing tried.
    Idle,
    /// A run is in flight, before the host's open ack.
    Opening,
    /// Subscribed and applying, holding the last acked `stateNum`.
    Live(i64),
    /// The host does not serve this class — a definite answer about THIS connection, so nothing
    /// retries. A deliberate [`ChannelRun::stop`] clears it, because the next `start` may be
    /// against a different host.
    Refused,
    /// The subscription is over. The connection layer decides whether to open another.
    Closed,
}

impl RunState {
    /// The tag and the number the FFI layer carries it as.
    #[must_use]
    pub const fn parts(self) -> (u8, i64) {
        match self {
            Self::Idle => (0, 0),
            Self::Opening => (1, 0),
            Self::Live(state_num) => (2, state_num),
            Self::Refused => (3, 0),
            Self::Closed => (4, 0),
        }
    }

    /// The inverse of [`Self::parts`]. An unknown tag is [`Self::Idle`], which is the state that
    /// admits a fresh `start` — the safe reading of a byte no version of this enum wrote.
    #[must_use]
    pub const fn from_parts(tag: u8, state_num: i64) -> Self {
        match tag {
            1 => Self::Opening,
            2 => Self::Live(state_num),
            3 => Self::Refused,
            4 => Self::Closed,
            _ => Self::Idle,
        }
    }
}

/// What a [`ChannelRun::finish`] leaves for the caller to do.
///
/// Two DIFFERENT things hide behind "publish nothing", and the near side owes them different
/// endings: a superseded run must leave the live run's task slot alone, while a current run whose
/// state simply did not move has still ENDED and must clear its own slot — otherwise the next
/// `start` sees a run in flight forever and the client never reopens.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FinishVerdict {
    /// A dying run under an older generation. It owns nothing any more: say nothing, touch nothing.
    Stale,
    /// The current run ended on the state it was already in. Retire its task, announce nothing.
    Quiet,
    /// The current run ended somewhere new. Retire its task and announce.
    News,
}

impl FinishVerdict {
    /// The byte the FFI layer carries it as.
    #[must_use]
    pub const fn tag(self) -> u8 {
        match self {
            Self::Stale => 0,
            Self::Quiet => 1,
            Self::News => 2,
        }
    }
}

/// What a [`ChannelRun::stop`] leaves for the caller to do.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct StopVerdict {
    /// The channel id this stop CLAIMED, if it still held one. The run task's own exit path will
    /// find the slot empty and release nothing, which is what keeps the release single.
    pub release: Option<u32>,
    /// Whether `.closed` is news. `false` when the client was already closed, in which case the
    /// near side must not fire its state-change callback.
    pub publish: bool,
}

/// The scalars of one client's channel loop.
///
/// Single-threaded by construction — every caller is on the main actor — but held behind a handle
/// so the near side cannot read one of the four and act on another that has since moved.
///
/// `Copy`, like every other all-scalar value in this crate: the one thing holding the LIVE state is
/// the FFI handle the near side owns, and every mutation here runs through a `&mut` borrow of it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ChannelRun {
    state: RunState,
    generation: u64,
    channel: Option<u32>,
    presence_clock: i64,
}

impl Default for ChannelRun {
    fn default() -> Self {
        Self::new()
    }
}

impl ChannelRun {
    /// A client that has never opened anything.
    #[must_use]
    pub const fn new() -> Self {
        Self {
            state: RunState::Idle,
            generation: 0,
            channel: None,
            presence_clock: 0,
        }
    }

    /// The state the near side publishes and binds to.
    #[must_use]
    pub const fn state(&self) -> RunState {
        self.state
    }

    /// Whether this client can carry an intent right now — `.live` and nothing else. Opening,
    /// refused and closed all drop an intent on the floor rather than queueing it for a channel
    /// that may never exist.
    #[must_use]
    pub const fn may_send_intent(&self) -> bool {
        matches!(self.state, RunState::Live(_))
    }

    /// The channel id this client still owns, if any.
    #[must_use]
    pub const fn channel(&self) -> Option<u32> {
        self.channel
    }

    /// The generation the newest run was born under.
    #[must_use]
    pub const fn generation(&self) -> u64 {
        self.generation
    }

    /// Admits a run and hands it the generation it must quote in every later publish.
    ///
    /// `None` for a client that already has a run in flight (`run_in_flight`, which the near side
    /// reads off its own `Task` slot) and for one the host has REFUSED — a refusal is a fact about
    /// this host, not a transient failure, so a retry loop must not be able to spin on it.
    ///
    /// The admitted run is `Opening` before this returns: a `stop` arriving mid-handshake has to
    /// find a client that is not idle, or it publishes nothing and the run publishes `closed` into
    /// a state nobody is expecting.
    pub fn start(&mut self, run_in_flight: bool) -> Option<u64> {
        if run_in_flight || self.state == RunState::Refused {
            return None;
        }
        self.generation = self.generation.wrapping_add(1);
        self.state = RunState::Opening;
        Some(self.generation)
    }

    /// Retires every run in flight and claims the channel for release.
    ///
    /// The generation is bumped FIRST, which is what makes this the last word: the run behind an
    /// `await` wakes up holding a stale number and says nothing. A stop also clears a refusal,
    /// since the next `start` may be against a different host or the same one restarted.
    pub fn stop(&mut self) -> StopVerdict {
        self.generation = self.generation.wrapping_add(1);
        let release = self.channel.take();
        let publish = self.publish(RunState::Closed);
        StopVerdict { release, publish }
    }

    /// Records the channel a run just opened, so a `stop` arriving mid-handshake knows there is
    /// something to release.
    pub const fn claim(&mut self, channel: u32) {
        self.channel = Some(channel);
    }

    /// Claims `channel` for release, but only while this client still owns it.
    ///
    /// `true` for the caller that must close it — and the slot is cleared in the same step, so the
    /// other caller's own release finds nothing. `false` for a stop that already took it.
    pub fn release_if_owned(&mut self, channel: u32) -> bool {
        if self.channel != Some(channel) {
            return false;
        }
        self.channel = None;
        true
    }

    /// Publishes `next` on behalf of the run born under `generation`.
    ///
    /// A superseded run is [`FinishVerdict::Stale`], and it is not merely de-duplicated: `stop()`
    /// published `closed` and a later `start()` published `opening`, and letting the dying loop
    /// write `closed` over that is exactly how a live channel reports itself dead.
    pub fn finish(&mut self, next: RunState, generation: u64) -> FinishVerdict {
        if generation != self.generation {
            return FinishVerdict::Stale;
        }
        if self.publish(next) {
            FinishVerdict::News
        } else {
            FinishVerdict::Quiet
        }
    }

    /// Moves to `next` and answers whether that is news.
    ///
    /// Used directly for the transitions that belong to no run — the loopback client that is born
    /// live against an in-process document, and the `opening` a fresh `start` announces.
    pub fn publish(&mut self, next: RunState) -> bool {
        if self.state == next {
            return false;
        }
        self.state = next;
        true
    }

    /// Mints the next presence clock. Monotone within a connection, and the near side must never
    /// restart it below what it has already sent.
    pub const fn mint_presence_clock(&mut self) -> i64 {
        self.presence_clock = self.presence_clock.saturating_add(1);
        self.presence_clock
    }

    /// The clock last minted. `0` for a client that has never published a view.
    #[must_use]
    pub const fn presence_clock(&self) -> i64 {
        self.presence_clock
    }
}

#[cfg(test)]
mod tests {
    use super::{ChannelRun, FinishVerdict, RunState, StopVerdict};

    #[test]
    fn a_fresh_client_is_idle_and_carries_nothing() {
        let run = ChannelRun::new();
        assert_eq!(run.state(), RunState::Idle);
        assert_eq!(run.channel(), None);
        assert_eq!(run.presence_clock(), 0);
        assert!(!run.may_send_intent());
    }

    #[test]
    fn start_admits_one_run_and_announces_opening() {
        let mut run = ChannelRun::new();
        assert_eq!(run.start(false), Some(1));
        assert_eq!(run.state(), RunState::Opening);
        assert_eq!(run.start(true), None, "a run already in flight is not restarted");
    }

    #[test]
    fn a_refusal_stops_every_later_start() {
        let mut run = ChannelRun::new();
        assert_eq!(run.start(false), Some(1));
        assert_eq!(run.finish(RunState::Refused, 1), FinishVerdict::News);
        assert_eq!(run.start(false), None);
        assert_eq!(run.state(), RunState::Refused);
    }

    #[test]
    fn a_deliberate_stop_clears_a_refusal() {
        let mut run = ChannelRun::new();
        assert_eq!(run.start(false), Some(1));
        run.finish(RunState::Refused, 1);
        assert_eq!(run.stop(), StopVerdict {
            release: None,
            publish: true
        });
        assert_eq!(run.start(false), Some(3), "the next host gets a fresh run");
    }

    #[test]
    fn a_superseded_run_publishes_nothing() {
        let mut run = ChannelRun::new();
        assert_eq!(run.start(false), Some(1), "the run that is about to die");
        run.stop();
        assert_eq!(run.start(false), Some(3), "the run that replaces it");
        assert_eq!(
            run.finish(RunState::Closed, 1),
            FinishVerdict::Stale,
            "the dying run must not report the live one dead"
        );
        assert_eq!(run.state(), RunState::Opening);
        assert_eq!(run.finish(RunState::Live(0), 3), FinishVerdict::News);
    }

    #[test]
    fn a_current_run_that_moved_nowhere_is_quiet_not_stale() {
        let mut run = ChannelRun::new();
        assert_eq!(run.start(false), Some(1));
        assert_eq!(run.finish(RunState::Closed, 1), FinishVerdict::News);
        assert_eq!(run.start(false), Some(2), "closed still admits a fresh run");
        assert_eq!(
            run.finish(RunState::Opening, 2),
            FinishVerdict::Quiet,
            "the run ended where it started: nothing to announce, but it HAS ended"
        );
        assert_eq!(
            run.start(false),
            Some(3),
            "the near side retired its task on Quiet, so this is not a run in flight"
        );
    }

    #[test]
    fn publish_de_duplicates_by_value_not_by_tag() {
        let mut run = ChannelRun::new();
        assert!(run.publish(RunState::Live(5)));
        assert!(
            !run.publish(RunState::Live(5)),
            "the same stateNum twice is not news"
        );
        assert!(
            run.publish(RunState::Live(6)),
            "every acked document frame moves the state"
        );
    }

    #[test]
    fn only_the_first_claimant_releases_the_channel() {
        let mut run = ChannelRun::new();
        run.start(false);
        run.claim(7);
        assert_eq!(run.stop(), StopVerdict {
            release: Some(7),
            publish: true
        });
        assert!(
            !run.release_if_owned(7),
            "the run's own exit path finds the slot empty"
        );
    }

    #[test]
    fn a_run_that_outlives_no_stop_releases_its_own_channel() {
        let mut run = ChannelRun::new();
        run.start(false);
        run.claim(9);
        assert!(run.release_if_owned(9));
        assert_eq!(run.channel(), None);
        assert!(
            !run.release_if_owned(9),
            "releasing twice would close a rebuilt connection"
        );
    }

    #[test]
    fn a_release_of_somebody_elses_channel_does_nothing() {
        let mut run = ChannelRun::new();
        run.claim(3);
        assert!(!run.release_if_owned(4));
        assert_eq!(run.channel(), Some(3), "the claim it does hold stands");
    }

    #[test]
    fn stopping_an_already_closed_client_is_not_news() {
        let mut run = ChannelRun::new();
        run.start(false);
        assert!(run.stop().publish);
        assert!(!run.stop().publish);
    }

    #[test]
    fn the_presence_clock_only_climbs() {
        let mut run = ChannelRun::new();
        assert_eq!(run.mint_presence_clock(), 1);
        assert_eq!(run.mint_presence_clock(), 2);
        run.stop();
        assert_eq!(
            run.mint_presence_clock(),
            3,
            "a reconnect must not restart below what the host has kept"
        );
    }

    #[test]
    fn only_a_live_client_carries_an_intent() {
        let mut run = ChannelRun::new();
        run.start(false);
        assert!(!run.may_send_intent(), "opening drops it on the floor");
        run.publish(RunState::Live(0));
        assert!(run.may_send_intent());
        run.publish(RunState::Closed);
        assert!(!run.may_send_intent());
    }

    #[test]
    fn every_state_survives_the_ffi_round_trip() {
        for state in [
            RunState::Idle,
            RunState::Opening,
            RunState::Live(0),
            RunState::Live(-1),
            RunState::Live(i64::MAX),
            RunState::Refused,
            RunState::Closed,
        ] {
            let (tag, state_num) = state.parts();
            assert_eq!(RunState::from_parts(tag, state_num), state);
        }
        assert_eq!(
            RunState::from_parts(200, 4),
            RunState::Idle,
            "a tag no version wrote reads as the state that admits a start"
        );
    }
}
