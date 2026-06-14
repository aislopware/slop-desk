//! Pure idle-timeout reap decision for a UDP video flow/lane — a port of Swift
//! `IdleReapDecider`.
//!
//! UDP has no FIN, so a client that crashes without a `bye` would pin its flow slot forever.
//! The caller stamps `now` and acts on the returned ids; the side effects (timers, session
//! teardown) stay thin around this decider.
//!
//! ## The never-reap-without-keepalive rule (RFC 7675 §5.1 / RFC 9000 §10.1.2)
//!
//! A flow is reaped ONLY once it has PROVEN it speaks keepalive (`saw_keepalive == true`). A
//! flow that has never delivered a keepalive is NEVER eligible — [`reap`](IdleReapDecider::reap)
//! skips it unconditionally, so a legacy client degrades to no-reap behaviour. `saw_keepalive`
//! is **sticky**: once true it never resets, so a client that sends one keepalive then crashes
//! into true silence is exactly the case we reap. Identity is the `FlowID`, so a reconnect under
//! a fresh id gets a fresh (unproven) record — see [`forget`](IdleReapDecider::forget).

use std::collections::HashMap;
use std::hash::Hash;

/// Per-flow liveness state. `Copy` so [`record`](IdleReapDecider::record) can hand back a value
/// exactly like Swift's value-type `Record`.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Record {
    /// Host time (seconds, monotonic) of the most recent inbound datagram of ANY kind.
    pub last_inbound: f64,
    /// Whether this flow has EVER delivered a keepalive control datagram. Sticky-true.
    pub saw_keepalive: bool,
}

/// Decides which flows have gone idle past `idle_timeout` after proving keepalive.
#[derive(Debug, Clone, Default)]
pub struct IdleReapDecider<FlowID: Eq + Hash> {
    flows: HashMap<FlowID, Record>,
    idle_timeout: f64,
}

impl<FlowID: Eq + Hash + Clone> IdleReapDecider<FlowID> {
    /// Builds a decider with the given idle threshold (seconds), e.g.
    /// [`IDLE_TIMEOUT_SECS`](crate::keepalive::IDLE_TIMEOUT_SECS).
    #[must_use]
    pub fn new(idle_timeout: f64) -> Self {
        Self {
            flows: HashMap::new(),
            idle_timeout,
        }
    }

    /// The configured idle threshold in seconds.
    #[must_use]
    pub const fn idle_timeout(&self) -> f64 {
        self.idle_timeout
    }

    /// Stamps an inbound datagram for `id` at host time `now`. `is_keepalive` latches
    /// `saw_keepalive` STICKY (never clears). Any inbound — keepalive or media/input — refreshes
    /// `last_inbound`. A first-ever inbound creates the record.
    pub fn note_inbound(&mut self, id: FlowID, now: f64, is_keepalive: bool) {
        let rec = self.flows.entry(id).or_insert(Record {
            last_inbound: now,
            saw_keepalive: false,
        });
        rec.last_inbound = now;
        if is_keepalive {
            rec.saw_keepalive = true;
        }
    }

    /// The ids to reap NOW: those that PROVED keepalive AND have been silent ≥ `idle_timeout`.
    /// Pure — does not mutate. The returned order is unspecified (`HashMap` iteration); the caller
    /// sorts if it needs a stable order. The caller tears each id down then calls
    /// [`forget`](Self::forget) so a reaped flow is not re-reported next tick.
    #[must_use]
    pub fn reap(&self, now: f64) -> Vec<FlowID> {
        self.flows
            .iter()
            .filter_map(|(id, rec)| {
                if rec.saw_keepalive && now - rec.last_inbound >= self.idle_timeout {
                    Some(id.clone())
                } else {
                    None
                }
            })
            .collect()
    }

    /// Drops a flow's record (after reaping, or on a clean `bye`). Idempotent; a reused id then
    /// starts a fresh (unproven) record.
    pub fn forget(&mut self, id: &FlowID) {
        self.flows.remove(id);
    }

    /// Test / introspection: the current record for `id`, if any.
    #[must_use]
    pub fn record(&self, id: &FlowID) -> Option<Record> {
        self.flows.get(id).copied()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::keepalive::{IDLE_TIMEOUT_SECS, KEEPALIVE_INTERVAL_SECS, REAPER_TICK_SECS};

    const IDLE_TIMEOUT: f64 = 30.0;

    fn make() -> IdleReapDecider<i32> {
        IdleReapDecider::new(IDLE_TIMEOUT)
    }

    #[test]
    fn reap_after_timeout() {
        let mut d = make();
        d.note_inbound(1, 0.0, true);
        assert_eq!(d.reap(29.9), Vec::<i32>::new());
        assert_eq!(d.reap(30.0), vec![1]);
        assert_eq!(d.reap(100.0), vec![1]);
    }

    #[test]
    fn never_reap_without_keepalive() {
        let mut d = make();
        let mut t = 0.0;
        while t <= 25.0 {
            d.note_inbound(1, t, false);
            t += 5.0;
        }
        assert_eq!(d.reap(1_000.0), Vec::<i32>::new());
        assert!(d.record(&1).is_some());
        assert!(!d.record(&1).unwrap().saw_keepalive);
    }

    #[test]
    fn keepalive_refreshes_and_sticky_flag() {
        let mut d = make();
        d.note_inbound(1, 0.0, true);
        d.note_inbound(1, 25.0, false);
        assert_eq!(d.reap(30.0), Vec::<i32>::new());
        assert_eq!(d.reap(55.001), vec![1]);
    }

    #[test]
    fn reconnect_resets_via_forget() {
        let mut d = make();
        d.note_inbound(1, 0.0, true);
        d.forget(&1);
        assert!(d.record(&1).is_none());
        d.note_inbound(1, 0.0, false);
        assert_eq!(d.reap(1_000.0), Vec::<i32>::new());
    }

    #[test]
    fn multi_lane_independence() {
        let mut d = make();
        d.note_inbound(1, 0.0, true);
        d.note_inbound(2, 0.0, true);
        d.note_inbound(2, 40.0, false);
        d.note_inbound(3, 0.0, false);
        let mut due = d.reap(45.0);
        due.sort_unstable();
        assert_eq!(due, vec![1]);
        d.forget(&1);
        assert!(d.record(&1).is_none());
        assert!(d.record(&2).is_some());
        assert!(d.record(&3).is_some());
    }

    #[test]
    fn forget_dedupes() {
        let mut d = make();
        d.note_inbound(1, 0.0, true);
        assert_eq!(d.reap(40.0), vec![1]);
        d.forget(&1);
        assert_eq!(d.reap(40.0), Vec::<i32>::new());
        d.forget(&1);
        assert_eq!(d.reap(40.0), Vec::<i32>::new());
    }

    #[test]
    fn keepalive_ratio_invariant() {
        let ratio = IDLE_TIMEOUT_SECS / KEEPALIVE_INTERVAL_SECS;
        assert!(ratio >= 3.0);
        assert_eq!(KEEPALIVE_INTERVAL_SECS, 5.0);
        assert_eq!(IDLE_TIMEOUT_SECS, 30.0);
        assert_eq!(REAPER_TICK_SECS, 5.0);
    }

    #[test]
    fn first_inbound_creates_record() {
        let mut d = make();
        assert!(d.record(&7).is_none());
        d.note_inbound(7, 12.5, false);
        assert_eq!(
            d.record(&7),
            Some(Record {
                last_inbound: 12.5,
                saw_keepalive: false,
            })
        );
    }
}
