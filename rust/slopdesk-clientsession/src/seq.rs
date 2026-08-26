//! What a client does with an output seq the host has just handed it.
//!
//! The pane's client keeps three numbers about the host's `output` stream and one flag about what
//! it owes back. Every reconnect decision in the session driver is a question about those four:
//!
//! - `highest_fed` is the DEDUP bound. A replayed tail arrives as seqs the surface has already
//!   rendered, and dropping exactly those is what makes a resume splice in gap-free and dup-free.
//! - `highest_contiguous` is what the client ACKS, and what the next `channelOpen` presents as
//!   `lastReceivedSeq`. Never ack a seq that was not delivered — correctness over cadence
//!   (`docs/20` §5).
//! - `presented_resume_seq` is the reference the RESUME VERDICT is read against: the
//!   `lastReceivedSeq` this client presented in the connection currently running.
//! - `ack_pending` is the coalescing flag the background ticker flushes.
//!
//! ## What is NOT here
//! The bytes. `deliver` answers whether a seq is new, and the near side owns the inbox those bytes
//! go into, the surface they are fed to and the window credit they are worth — a `Data` never
//! crosses to be told it is a duplicate. Likewise the transport, the tasks and the clock: this is
//! the arithmetic those effects are chosen by, and nothing it decides needs a descriptor.

/// What the CURRENT connection turned out to be, resolved from the first `output` seq it delivers.
///
/// The host's per-channel seq stream is monotonic across a reattach — the replay buffer survives
/// with the shell and only ever emits `seq > lastReceivedSeq` — while a fresh shell mints a new
/// buffer whose first output is seq 1. So, having presented `lastReceivedSeq = N`: a first seq past
/// `N` (with `N > 0`) is the SAME shell, and anything else is a new one.
///
/// The verdict gates a one-shot surface wipe, which is why it is a verdict rather than a guess: a
/// warm reattach must NOT wipe the screen and scrollback the host will never re-send.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
#[repr(u8)]
pub enum ResumeOutcome {
    /// No output delivered on the current connection yet, or the link is down.
    #[default]
    Undetermined = 0,
    /// The seq stream restarted — the host spawned a FRESH shell.
    FreshShell = 1,
    /// The seq stream continued past the presented `lastReceivedSeq` — the host reattached the
    /// SAME live shell and resumes byte-exact.
    ResumedSession = 2,
}

impl ResumeOutcome {
    /// The byte the near side reads this verdict as.
    #[must_use]
    pub const fn code(self) -> u8 {
        self as u8
    }

    /// The verdict `code` names, or [`Undetermined`](Self::Undetermined) for a byte this build
    /// cannot read — the reading that establishes nothing, which is the honest answer to a byte
    /// nobody here can interpret.
    #[must_use]
    pub const fn from_code(code: u8) -> Self {
        match code {
            1 => Self::FreshShell,
            2 => Self::ResumedSession,
            _ => Self::Undetermined,
        }
    }
}

/// What [`Session::deliver`] decided about one inbound `output`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum Delivery {
    /// Already fed — DROP the bytes, and still credit them. They crossed the wire and were fully
    /// processed by being discarded; withholding the credit leaks window capacity on every replay.
    Duplicate = 0,
    /// New — feed it to the surface and the inbox, and an ack is now pending.
    Accepted = 1,
}

impl Delivery {
    /// The byte the near side reads this verdict as.
    #[must_use]
    pub const fn code(self) -> u8 {
        self as u8
    }
}

/// What [`Session::adopt`] did to the marks when a connection was adopted.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum Adoption {
    /// The host honoured a real resume, so the seeded marks were KEPT — resetting them would make
    /// the replayed tail arrive as new and print twice.
    MarksKept = 0,
    /// The host spawned a fresh shell (or reattached for a cold client), so the marks were CLEARED
    /// — otherwise that shell's seq-1 output is dropped as a duplicate of a session that is gone.
    ///
    /// The near side has one thing to do about it: any output still sitting un-consumed in its
    /// inbox must have its WIRE CREDIT zeroed, because the new channel's peer never sent those
    /// bytes and crediting them back would over-grant its window. The bytes themselves stay — they
    /// are the only copy, and dropping them is a permanent scrollback gap.
    MarksReset = 1,
}

impl Adoption {
    /// The byte the near side reads this verdict as.
    #[must_use]
    pub const fn code(self) -> u8 {
        self as u8
    }
}

/// The four numbers one pane's client keeps about the host's output stream.
///
/// Copied by value in and out of every call: there is nothing to own, and a Swift `struct` copied
/// by value cannot be a handle without two owners silently aliasing one allocation (`docs/55` §4b).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Session {
    /// Highest seq actually fed to the surface — the dedup high-water bound.
    pub highest_fed: i64,
    /// Highest CONTIGUOUS seq delivered — what is acked and what the next open presents.
    pub highest_contiguous: i64,
    /// The `lastReceivedSeq` presented by the connection currently running.
    pub presented_resume_seq: i64,
    /// The resume verdict for that connection.
    pub outcome: ResumeOutcome,
    /// Whether a contiguous advance is waiting for the coalescing ack ticker.
    pub ack_pending: bool,
}

impl Session {
    /// The session a RESTORED pane starts from: both marks already at the seq it last rendered, so
    /// the first `channelOpen` presents that seq and the host replays only what follows.
    #[must_use]
    pub const fn seeded(last_seq: i64) -> Self {
        Self {
            highest_fed: last_seq,
            highest_contiguous: last_seq,
            presented_resume_seq: 0,
            outcome: ResumeOutcome::Undetermined,
            ack_pending: false,
        }
    }

    /// Adopts a connection that has completed its handshake.
    ///
    /// `presented_resume_seq` is the `lastReceivedSeq` that connection's `channelOpen` carried —
    /// captured BEFORE this call, because the reset below is allowed to clear the mark it came
    /// from. `resume_from_seq` is the HOST-AUTHORITATIVE answer from the open ack, and it is the
    /// only correct signal: the client-side "returning client" flag is true on every reconnect, so
    /// gating the reset on it would skip the reset exactly when it is needed.
    pub const fn adopt(&mut self, presented_resume_seq: i64, resume_from_seq: i64) -> Adoption {
        let verdict = if resume_from_seq == 0 {
            self.highest_fed = 0;
            self.highest_contiguous = 0;
            self.ack_pending = false;
            Adoption::MarksReset
        } else {
            Adoption::MarksKept
        };
        // Armed strictly before the pump can deliver, so the verdict below is resolved against the
        // seq THIS connection presented rather than a dead one's.
        self.presented_resume_seq = presented_resume_seq;
        self.outcome = ResumeOutcome::Undetermined;
        verdict
    }

    /// Folds one inbound `output` seq.
    ///
    /// The resume verdict resolves FIRST, before the dedup guard: a replayed tail is exactly the
    /// case the verdict exists to recognise, so a duplicate still answers the question. After that
    /// the guard drops anything already fed, and an accepted seq advances both marks and arms the
    /// ack.
    ///
    /// The contiguous mark takes any forward seq rather than only `previous + 1`. The two are the
    /// same under the transport's in-order guarantee, and where they would differ the rule is that
    /// the client must never ack less than it delivered and never more than it holds.
    pub const fn deliver(&mut self, seq: i64) -> Delivery {
        if matches!(self.outcome, ResumeOutcome::Undetermined) {
            self.outcome = if self.presented_resume_seq > 0 && seq > self.presented_resume_seq {
                ResumeOutcome::ResumedSession
            } else {
                ResumeOutcome::FreshShell
            };
        }
        if seq <= self.highest_fed {
            return Delivery::Duplicate;
        }
        self.highest_fed = seq;
        if seq > self.highest_contiguous {
            self.highest_contiguous = seq;
        }
        self.ack_pending = true;
        Delivery::Accepted
    }

    /// What the coalescing ticker should ack, or `None` for nothing to say.
    ///
    /// The pending flag clears whether or not a seq comes back: a flush with nothing delivered has
    /// answered the tick, and re-arming it would spin the ticker against a mark that cannot move on
    /// its own.
    pub const fn ack(&mut self) -> Option<i64> {
        if !self.ack_pending {
            return None;
        }
        self.ack_pending = false;
        if self.highest_contiguous > 0 {
            Some(self.highest_contiguous)
        } else {
            None
        }
    }

    /// Re-arms the ack after a send failed — the next live transport says it instead.
    pub const fn ack_failed(&mut self) {
        self.ack_pending = true;
    }

    /// The inbound stream ended. The dead connection's verdict must not survive it: a stale
    /// `ResumedSession` read between the drop and the next connect would let the surface skip a
    /// wipe the NEXT session needs. Unconditional — a deliberate close invalidates it just as much.
    pub const fn stream_ended(&mut self) {
        self.outcome = ResumeOutcome::Undetermined;
    }
}

#[cfg(test)]
mod tests {
    use super::{Adoption, Delivery, ResumeOutcome, Session};

    /// A cold client accepts the fresh shell's first seq and arms an ack for it.
    #[test]
    fn a_cold_client_accepts_seq_one() {
        let mut session = Session::default();
        assert_eq!(session.deliver(1), Delivery::Accepted);
        assert_eq!(session.highest_fed, 1);
        assert_eq!(session.highest_contiguous, 1);
        assert!(session.ack_pending);
        assert_eq!(session.outcome, ResumeOutcome::FreshShell);
    }

    /// The replayed tail is exactly the seqs already rendered — every one drops, and the marks do
    /// not move backwards behind them.
    #[test]
    fn a_replayed_tail_is_dropped_without_moving_the_marks() {
        let mut session = Session::seeded(7);
        for seq in 1..=7 {
            assert_eq!(session.deliver(seq), Delivery::Duplicate, "seq {seq}");
        }
        assert_eq!(session.highest_fed, 7);
        assert_eq!(session.highest_contiguous, 7);
        assert!(!session.ack_pending, "a dropped duplicate owes no ack");
        assert_eq!(session.deliver(8), Delivery::Accepted);
        assert_eq!(session.highest_contiguous, 8);
    }

    /// The verdict resolves on the FIRST seq of the connection even when that seq is a duplicate —
    /// a replayed tail is the case it exists to recognise, so the dedup guard may not pre-empt it.
    #[test]
    fn a_duplicate_still_resolves_the_verdict() {
        let mut session = Session::seeded(7);
        session.adopt(7, 8);
        assert_eq!(session.deliver(3), Delivery::Duplicate);
        assert_eq!(session.outcome, ResumeOutcome::FreshShell, "seq 3 is not past 7");

        let mut resumed = Session::seeded(7);
        resumed.adopt(7, 8);
        assert_eq!(resumed.deliver(8), Delivery::Accepted);
        assert_eq!(resumed.outcome, ResumeOutcome::ResumedSession);
    }

    /// A client that presented nothing cannot have resumed anything.
    #[test]
    fn nothing_presented_is_always_a_fresh_shell() {
        let mut session = Session::default();
        session.adopt(0, 0);
        assert_eq!(session.deliver(9_000), Delivery::Accepted);
        assert_eq!(session.outcome, ResumeOutcome::FreshShell);
    }

    /// The verdict is resolved ONCE per connection: a later seq cannot revise it.
    #[test]
    fn the_verdict_is_resolved_once_per_connection() {
        let mut session = Session::seeded(5);
        session.adopt(5, 6);
        session.deliver(6);
        assert_eq!(session.outcome, ResumeOutcome::ResumedSession);
        session.deliver(2);
        assert_eq!(
            session.outcome,
            ResumeOutcome::ResumedSession,
            "a late duplicate revises nothing"
        );
    }

    /// A host that spawned a fresh shell resets the marks; one that honoured a resume keeps them.
    /// Getting this backwards is a pane that either eats its first screen or prints it twice.
    #[test]
    fn the_reset_follows_the_hosts_answer_not_the_clients_flag() {
        let mut fresh = Session::seeded(42);
        fresh.ack_pending = true;
        assert_eq!(fresh.adopt(42, 0), Adoption::MarksReset);
        assert_eq!(fresh.highest_fed, 0);
        assert_eq!(fresh.highest_contiguous, 0);
        assert!(!fresh.ack_pending);
        assert_eq!(
            fresh.presented_resume_seq, 42,
            "the probe still remembers what was presented"
        );

        let mut warm = Session::seeded(42);
        assert_eq!(warm.adopt(42, 43), Adoption::MarksKept);
        assert_eq!(warm.highest_fed, 42);
        assert_eq!(warm.highest_contiguous, 42);
    }

    /// Adopting re-arms the probe, so a dead connection's verdict never gates the next one.
    #[test]
    fn adopting_re_arms_the_probe() {
        let mut session = Session::seeded(5);
        session.adopt(5, 6);
        session.deliver(6);
        assert_eq!(session.outcome, ResumeOutcome::ResumedSession);
        session.adopt(6, 0);
        assert_eq!(session.outcome, ResumeOutcome::Undetermined);
    }

    /// The ack gate: nothing pending says nothing, a pending advance says the contiguous mark, and
    /// a pending flag with nothing delivered still clears rather than spinning the ticker.
    #[test]
    fn the_ack_gate_answers_only_what_was_delivered() {
        let mut session = Session::default();
        assert_eq!(session.ack(), None, "nothing pending");

        session.deliver(1);
        assert_eq!(session.ack(), Some(1));
        assert_eq!(session.ack(), None, "the flag cleared with the answer");

        let mut empty = Session {
            ack_pending: true,
            ..Session::default()
        };
        assert_eq!(empty.ack(), None, "seq 0 is never acked");
        assert!(!empty.ack_pending, "…and the tick is still answered");
    }

    /// A failed send re-arms, so the next live transport carries the ack.
    #[test]
    fn a_failed_ack_is_re_armed() {
        let mut session = Session::default();
        session.deliver(4);
        assert_eq!(session.ack(), Some(4));
        session.ack_failed();
        assert_eq!(session.ack(), Some(4), "the same mark, on the next transport");
    }

    /// A stream end drops the verdict and nothing else — the marks are what the NEXT open presents.
    #[test]
    fn a_stream_end_drops_the_verdict_and_keeps_the_marks() {
        let mut session = Session::seeded(11);
        session.adopt(11, 12);
        session.deliver(12);
        session.stream_ended();
        assert_eq!(session.outcome, ResumeOutcome::Undetermined);
        assert_eq!(session.highest_contiguous, 12);
        assert!(session.ack_pending, "what was delivered is still owed");
    }

    /// Every verdict byte round-trips, and an unreadable one establishes nothing.
    #[test]
    fn the_verdict_bytes_round_trip() {
        for outcome in [
            ResumeOutcome::Undetermined,
            ResumeOutcome::FreshShell,
            ResumeOutcome::ResumedSession,
        ] {
            assert_eq!(ResumeOutcome::from_code(outcome.code()), outcome);
        }
        assert_eq!(ResumeOutcome::from_code(200), ResumeOutcome::Undetermined);
        assert_eq!(Delivery::Duplicate.code(), 0);
        assert_eq!(Delivery::Accepted.code(), 1);
        assert_eq!(Adoption::MarksKept.code(), 0);
        assert_eq!(Adoption::MarksReset.code(), 1);
    }
}
