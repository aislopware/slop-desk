//! The laggard rule's OTHER half: who tells the server to close a member's channel, and what this
//! crate is allowed to know about how.
//!
//! [`slopdesk_muxsession::fanout::Fanout`] already decides WHICH members lose — behind the
//! healthiest, over the caller's byte threshold, never with a set of one — and latches each one so
//! the decision fires once. What it cannot do is act on the verdict: a member is a sub-channel pair
//! and four threads, and neither this crate nor the fold holds the connection those ride. So the
//! act is a SEAM, and the crate that owns the sockets installs it.
//!
//! ## The threshold arrives, it is not read
//!
//! `SLOPDESK_SUB_LAG_BYTES` is the server's to read, for the same reason the ring's caps are:
//! [`crate::SessionConfig::replay`] carries a buffer already built with them. A pane hands its
//! threshold in as a number, so a test can set one without an environment and two panes could in
//! principle carry different ones. **Zero disables eviction**, and disables it before any pricing
//! happens — the O(retained history) walk must not be paid to evaluate a rule that is off.
//!
//! ## Firing is DETACHED, and that is a correctness rule rather than a courtesy
//!
//! A laggard is by definition parked inside its own sender's credit window, and both of the places
//! the check runs can be reached from a thread that park is blocking: the ack path can be entered
//! from the doomed member's own relay, and the drain's ship path is what the park is starving.
//! Waking a member means retiring it — which cancels the sender it is parked in — so firing inline
//! would have the ladder wait on the very condition it exists to break. Every implementation of
//! [`EvictionSeam::evict`] is therefore called on a thread of its own.

use std::sync::Arc;

use slopdesk_muxsession::fanout::SubscriberId;

/// Who acts on an eviction verdict.
///
/// A trait rather than a boxed closure for the reason [`crate::SessionLog`] is one: the strict lint
/// set denies a struct with no `Debug`, and a `Box<dyn Fn>` has none to give.
pub trait EvictionSeam: Send + Sync + core::fmt::Debug {
    /// Ends `id`'s attachment — retire the member, then close its channel on the wire with a reason
    /// that says the PANE survived.
    ///
    /// Called on a thread of its own, once per member, and never under a lock this crate holds. It
    /// may block: closing a channel is a round trip, and the whole point of the detached call is
    /// that nothing is waiting for this one.
    ///
    /// It may also find nothing to do. A member can leave between the verdict and this call — a
    /// laggard whose link finally drops is the ordinary case — and the seam is expected to treat an
    /// unknown id as a no-op rather than an error.
    fn evict(&self, id: SubscriberId);
}

/// A seam that evicts nobody, for a caller with no wire to close a channel on.
///
/// Paired with a zero threshold in [`crate::SessionConfig::new`], so a session built by a test or
/// by `slopdesk-ctl` never evicts and never prices — the two defaults say the same thing twice on
/// purpose, because either one alone would leave the other looking like an oversight.
#[derive(Debug, Clone, Copy)]
pub struct IgnoreEviction;

impl EvictionSeam for IgnoreEviction {
    fn evict(&self, _id: SubscriberId) {}
}

/// The laggard policy one pane carries: how far behind is too far, and who acts on the answer.
#[derive(Debug, Clone)]
pub struct Eviction {
    /// The un-acked backlog, in retained bytes, past which a member is dropped rather than buffered
    /// for. `0` disables the rule — see the module note. STRICTLY greater is the fold's comparison:
    /// a member exactly at the threshold is still buffered for.
    pub lag_bytes: u64,
    /// Who ends the attachment once the fold has latched it.
    pub seam: Arc<dyn EvictionSeam>,
}

impl Eviction {
    /// The disabled policy: no threshold, and nobody to act on one.
    #[must_use]
    pub fn off() -> Self {
        Self {
            lag_bytes: 0,
            seam: Arc::new(IgnoreEviction),
        }
    }

    /// Whether the rule is switched off — the early-out both firing sites take before they touch a
    /// lock.
    #[must_use]
    pub const fn disabled(&self) -> bool {
        self.lag_bytes == 0
    }
}
