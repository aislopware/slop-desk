//! What the near side observes, and the one trait it implements to observe it.
//!
//! ## Two shapes, not twenty
//!
//! The Swift `SlopDeskClient.Event` had twenty cases and seventeen of them were one inbound
//! `WireMessage` re-typed: `.title(String)` for a `Title`, `.bell` for a `Bell`, `.cwd(String)` for
//! a `Cwd`. That re-typing was the price of an enum the UI could `switch` on without importing the
//! wire — a price paid inside the driver, on the byte path, once per message.
//!
//! Here the message crosses AS a message. [`Event::Message`] lends the decoded
//! [`WireMessage`] and the near side does its own mapping, which is what the FFI door already does
//! for `docs/63` G.3's inbound record: one flat record, one arena, one borrowed run. Minting a
//! second flat spelling of a message the door can already lend would be the marshalling face this
//! stage exists to delete.
//!
//! The other shape is the session's own lifecycle — a drop, a resume, a round-trip reading, the
//! progress of a retry campaign. None of those is on the wire, so each is a case here.
//!
//! ## Everything is lent, nothing is owned
//!
//! Every field is a borrow that ends when [`Observer::event`] returns, which is `docs/55` §4b's
//! lend-for-the-call term stated one layer up so the door does not have to re-state it. An observer
//! that keeps a payload copies it.

use slopdesk_wire::WireMessage;

/// One thing the near side is told, lent for the duration of the call.
#[derive(Debug)]
#[non_exhaustive]
pub enum Event<'a> {
    /// A host→client message, verbatim.
    ///
    /// Three message types never reach here, because the driver consumes them rather than
    /// forwarding them: `Output` goes to the inbox after the dedup fold, `Pong` becomes
    /// [`Self::RoundTrip`], and everything a client SENDS is refused by the wire's own direction.
    /// `Exit` DOES reach here — it is terminal for the session and the near side needs to see it —
    /// and the driver has already recorded it by the time the observer runs.
    Message(&'a WireMessage),

    /// A fresh smoothed application-layer round trip, in milliseconds.
    ///
    /// Emitted only when a pong produced a reading; a hostile echo from the future of its own
    /// arrival leaves the previous value standing and says nothing.
    RoundTrip(f64),

    /// The channel ended in a way that was not asked for, and what it looked like.
    ///
    /// The three EXPECTED ends — a deliberate close, this driver replacing its own transport, and
    /// the FIN that follows a child's exit — are silent, by
    /// [`announces_drop`](slopdesk_clientsession::gates::announces_drop). A retry campaign follows
    /// this event only when one is configured and the session still wants to be connected.
    Disconnected {
        /// One sentence about the end, for a log line.
        reason: &'a str,
    },

    /// A connection that presented an existing session id completed its handshake.
    Reconnected {
        /// The session the host acknowledged.
        session_id: [u8; 16],
        /// The host-authoritative seq it will resume from. `0` is a fresh shell.
        resume_from_seq: i64,
    },

    /// A retry campaign is about to make an attempt, or has scheduled the next one.
    ///
    /// `delay_ms == 0` means the attempt fires now; a non-zero value is the wait BEFORE the next
    /// one, so the near side can render a countdown. It crosses as a duration rather than as an
    /// instant because the two sides do not share a clock epoch and the near side has its own.
    Retry {
        /// The 1-based attempt this campaign is on.
        attempt: u32,
        /// How long until the next attempt, or `0` for "now".
        delay_ms: u64,
    },

    /// A campaign exhausted its attempts. The pane is unreachable rather than reconnecting.
    GaveUp {
        /// How many attempts were made.
        attempts: u32,
    },

    /// A diagnostic line, already worded.
    ///
    /// The sentences are here rather than on the near side for the reason every refusal reason is:
    /// they describe a ladder this crate owns, and a second wording would drift from it.
    Log(&'a str),
}

/// Where a driver's events and output wakes land.
///
/// Called from whichever thread produced the fact: the supervisor for a lifecycle event, a
/// forwarder for a message or an output wake. Never concurrently with itself for events on one
/// lane, and an implementation that touches shared state protects it.
pub trait Observer: Send + Sync + 'static {
    /// One event, lent for the call.
    fn event(&self, event: &Event<'_>);

    /// The output inbox has bytes waiting.
    ///
    /// Called once per accepted `output`, which is what the Swift
    /// `outputWakeContinuation.yield(())` did: the coalescing lives in the near side's one-slot
    /// wake stream, where a wake that nobody is waiting on replaces the previous one rather
    /// than queueing behind it. Doing it here instead would need this crate to know whether a
    /// consumer is parked, which is the one fact it cannot see.
    fn output_ready(&self);
}
