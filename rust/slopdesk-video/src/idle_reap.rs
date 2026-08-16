//! Deciding when a silent UDP video flow is dead rather than merely quiet.
//!
//! No socket and no wall clock: the caller stamps `now` and acts on the returned ids, so the
//! `DispatchSourceTimer`, the flow reset and the session teardown all stay outside — the same
//! decider-beside-the-actor shape the rest of the host policies take.
//!
//! ## The never-reap-without-keepalive rule
//!
//! A flow is reaped ONLY once it has PROVEN it speaks keepalive. A flow that never delivered one —
//! a legacy client that does not send them — is never eligible, so it degrades to no-reap
//! behaviour rather than being torn down mid-session. That is a property of the per-flow record,
//! not of the timer, which is why it survives every timer change. The proof is STICKY: once true it
//! never clears for the life of the record, because a client that sent one keepalive and then went
//! truly silent is exactly the case worth reaping. Identity is the flow id, so a reconnect under a
//! fresh channel id gets a fresh record and has to prove itself again.

use std::collections::BTreeMap;

/// One flow's liveness record.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct FlowRecord {
    /// Monotonic host time, in seconds, of the most recent inbound datagram of ANY kind.
    pub last_inbound: f64,
    /// Whether this flow has EVER delivered a keepalive control datagram. Sticky-true.
    pub saw_keepalive: bool,
}

/// The idle-reap decider for a set of flows keyed by `F` — the channel id for the mux lanes.
#[derive(Debug, Clone, PartialEq)]
pub struct IdleReapDecider<F: Ord> {
    /// The live flow records.
    flows: BTreeMap<F, FlowRecord>,
    /// The idle threshold in seconds, normally [`crate::keepalive::IDLE_TIMEOUT_SECONDS`].
    idle_timeout: f64,
}

impl<F: Ord + Clone> IdleReapDecider<F> {
    /// A decider with no flows and the given idle threshold.
    #[must_use]
    pub const fn new(idle_timeout: f64) -> Self {
        Self {
            flows: BTreeMap::new(),
            idle_timeout,
        }
    }

    /// The idle threshold this decider reaps at.
    #[must_use]
    pub const fn idle_timeout(&self) -> f64 {
        self.idle_timeout
    }

    /// Stamps an inbound datagram for `id`.
    ///
    /// `is_keepalive` latches the proof STICKY. Any inbound at all — keepalive or media or input —
    /// refreshes the silence clock, because a client actively typing is obviously alive between
    /// keepalives. A first-ever inbound creates the record.
    pub fn note_inbound(&mut self, id: F, now: f64, is_keepalive: bool) {
        let record = self.flows.entry(id).or_insert(FlowRecord {
            last_inbound: now,
            saw_keepalive: false,
        });
        record.last_inbound = now;
        record.saw_keepalive |= is_keepalive;
    }

    /// The ids to reap now: those that proved keepalive AND have been silent for the threshold.
    ///
    /// Pure — the caller tears each id down and then calls [`Self::forget`], so a reaped flow is
    /// not reported again on the next tick.
    #[must_use]
    pub fn reap(&self, now: f64) -> Vec<F> {
        self.flows
            .iter()
            .filter(|(_, record)| record.saw_keepalive && now - record.last_inbound >= self.idle_timeout)
            .map(|(id, _)| id.clone())
            .collect()
    }

    /// Drops a flow's record — after reaping, on a clean `bye`, or on an explicit retire — so it is
    /// neither re-reported nor leaked, and a reused id starts fresh. Idempotent.
    pub fn forget(&mut self, id: &F) {
        self.flows.remove(id);
    }

    /// The current record for `id`, for tests and introspection.
    #[must_use]
    pub fn record(&self, id: &F) -> Option<FlowRecord> {
        self.flows.get(id).copied()
    }
}

#[cfg(test)]
mod tests {
    use super::IdleReapDecider;

    #[test]
    fn a_flow_that_never_spoke_keepalive_is_never_reaped() {
        let mut decider = IdleReapDecider::new(30.0);
        decider.note_inbound(7_u32, 10.0, false);
        assert!(
            decider.reap(10_000.0).is_empty(),
            "a legacy client degrades to no-reap"
        );
    }

    #[test]
    fn a_proven_flow_is_reaped_once_it_falls_silent_for_the_threshold() {
        let mut decider = IdleReapDecider::new(30.0);
        decider.note_inbound(7_u32, 10.0, true);
        assert!(decider.reap(39.9).is_empty(), "not yet silent long enough");
        assert_eq!(decider.reap(40.0), vec![7], "the threshold itself reaps");
    }

    #[test]
    fn any_inbound_refreshes_the_silence_clock() {
        let mut decider = IdleReapDecider::new(30.0);
        decider.note_inbound(7_u32, 10.0, true);
        // Media or input, not a keepalive: a client actively typing is alive.
        decider.note_inbound(7_u32, 35.0, false);
        assert!(decider.reap(60.0).is_empty());
        assert_eq!(decider.reap(65.0), vec![7]);
    }

    #[test]
    fn the_keepalive_proof_is_sticky() {
        let mut decider = IdleReapDecider::new(30.0);
        decider.note_inbound(7_u32, 10.0, true);
        decider.note_inbound(7_u32, 11.0, false);
        assert_eq!(
            decider.record(&7).map(|record| record.saw_keepalive),
            Some(true),
            "a later non-keepalive must not un-prove the flow",
        );
    }

    #[test]
    fn a_forgotten_flow_starts_over_unproven() {
        let mut decider = IdleReapDecider::new(30.0);
        decider.note_inbound(7_u32, 10.0, true);
        decider.forget(&7);
        assert_eq!(decider.record(&7), None);
        decider.forget(&7); // idempotent
        decider.note_inbound(7_u32, 100.0, false);
        assert!(
            decider.reap(1_000.0).is_empty(),
            "a reused id has to prove itself again"
        );
    }

    #[test]
    fn flows_are_judged_independently() {
        let mut decider = IdleReapDecider::new(30.0);
        decider.note_inbound(1_u32, 10.0, true);
        decider.note_inbound(2_u32, 10.0, true);
        decider.note_inbound(2_u32, 50.0, false);
        assert_eq!(decider.reap(55.0), vec![1]);
    }
}
