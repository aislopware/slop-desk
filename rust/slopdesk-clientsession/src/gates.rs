//! The four questions a pane's client session answers with a yes or a no.
//!
//! Each of them guards an EFFECT — opening a channel, adopting a transport, announcing a drop,
//! running a retry campaign — and each is a conjunction of flags the driver already holds. They are
//! here rather than beside their effects because getting one wrong is not a wrong pixel: it is a
//! shell forked for a pane the host has reaped, a live transport leaked with its pumps still
//! spinning, or a pane parked at "reconnecting" forever.
//!
//! The four terminal states are deliberately NOT one flag. They differ in what may happen ABOVE the
//! client — a closed client is retired, an exited child wants an explicit re-dial, an evicted
//! subscriber may be re-attached by a NEW client — so the driver keeps them apart and the gates ask
//! about all of them.

/// Why a client refuses to open a channel.
///
/// Each arm is TERMINAL for this client instance. A recovery that is allowed builds a new one.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum Refusal {
    /// The client was permanently retired by its owner.
    Closed = 1,
    /// The remote child exited. The output wake stream is finished and cannot be re-armed, so a
    /// shell spawned now would write into an inbox no consumer will ever drain.
    ChildExited = 2,
    /// The host closed this pane's channel. Re-opening under the same client would re-use a session
    /// id the host may no longer hold.
    HostClosed = 3,
}

impl Refusal {
    /// The byte the near side reads this refusal as. `0` is the absence of one.
    #[must_use]
    pub const fn code(self) -> u8 {
        self as u8
    }

    /// The refusal `code` names, or `None` for `0` and for a byte this build cannot read.
    #[must_use]
    pub const fn from_code(code: u8) -> Option<Self> {
        match code {
            1 => Some(Self::Closed),
            2 => Some(Self::ChildExited),
            3 => Some(Self::HostClosed),
            _ => None,
        }
    }

    /// What the thrown error says. One sentence per arm, spelled once.
    #[must_use]
    pub const fn reason(self) -> &'static str {
        match self {
            Self::Closed => "connect after close",
            Self::ChildExited => "connect after child exit",
            Self::HostClosed => "connect after host closed the channel",
        }
    }
}

/// Whether a `connect` may proceed, and why not when it may not.
///
/// The order is the order the driver has always asked in, and it is the order of how much is over:
/// the whole client, then the child, then this attachment.
#[must_use]
pub const fn connect_refusal(closed: bool, child_exited: bool, host_closed: bool) -> Option<Refusal> {
    if closed {
        Some(Refusal::Closed)
    } else if child_exited {
        Some(Refusal::ChildExited)
    } else if host_closed {
        Some(Refusal::HostClosed)
    } else {
        None
    }
}

/// Whether a freshly-handshaken transport may be ADOPTED.
///
/// The driver's actor is reentrant at every await, so between building this transport and reaching
/// the assignment the client may have been closed, paused, cancelled, or superseded by a newer
/// connect that claimed a higher generation. Adopting anyway assigns over a transport that is still
/// live WITHOUT tearing it down — two sockets, an inbound pump, an ack ticker and a registry
/// refcount, leaked for as long as the process runs.
///
/// A refusal is not an error. The caller closes what it built and RETURNS: throwing would make the
/// retry campaign fight whichever connect legitimately won.
#[must_use]
#[expect(
    clippy::fn_params_excessive_bools,
    reason = "the four are the four reentrancy windows, each named; folding them would hide which one fired"
)]
pub const fn adopts(closed: bool, paused: bool, cancelled: bool, superseded: bool) -> bool {
    !closed && !paused && !cancelled && !superseded
}

/// Whether the end of an inbound stream is announced as a real drop.
///
/// Three ends are EXPECTED and must stay silent. A deliberate close is the owner's own doing; a
/// teardown is this driver replacing its own transport, and the old pump's end is self-inflicted; a
/// post-exit FIN follows an `.exit` that already said the session is over. Announcing any of them
/// queues a retry campaign against a client that does not want one.
#[must_use]
pub const fn announces_drop(closed: bool, tearing_down: bool, child_exited: bool) -> bool {
    !closed && !tearing_down && !child_exited
}

/// Whether a reconnect campaign may start, or take another turn.
///
/// Asked both before the first attempt and at the top of every retry, because all four states can
/// arrive DURING a campaign: the app backgrounds, the user closes the pane, a freshly respawned
/// shell exits at once, or the host closes the channel under it.
///
/// The campaign asks only WHETHER the host closed, never why. Every host close ends this client;
/// the reason decides what the layer above may build next, which is a different question.
#[must_use]
#[expect(
    clippy::fn_params_excessive_bools,
    reason = "the four terminal states differ in what may happen above the client, so they stay apart"
)]
pub const fn campaign_runs(paused: bool, closed: bool, child_exited: bool, host_closed: bool) -> bool {
    !paused && !closed && !child_exited && !host_closed
}

#[cfg(test)]
mod tests {
    use super::{Refusal, adopts, announces_drop, campaign_runs, connect_refusal};

    /// A client nothing has ended may connect.
    #[test]
    fn an_open_client_connects() {
        assert_eq!(connect_refusal(false, false, false), None);
    }

    /// Each terminal state refuses, and the order is stable when more than one holds — the reason a
    /// caller is shown should not depend on which flag was set first.
    #[test]
    fn each_terminal_state_refuses_in_a_stable_order() {
        assert_eq!(connect_refusal(true, false, false), Some(Refusal::Closed));
        assert_eq!(connect_refusal(false, true, false), Some(Refusal::ChildExited));
        assert_eq!(connect_refusal(false, false, true), Some(Refusal::HostClosed));
        assert_eq!(connect_refusal(true, true, true), Some(Refusal::Closed));
        assert_eq!(connect_refusal(false, true, true), Some(Refusal::ChildExited));
    }

    /// Every refusal byte round-trips, `0` is the absence of one, and each carries its own
    /// sentence.
    #[test]
    fn the_refusal_bytes_round_trip_with_their_reasons() {
        for refusal in [Refusal::Closed, Refusal::ChildExited, Refusal::HostClosed] {
            assert_eq!(Refusal::from_code(refusal.code()), Some(refusal));
            assert!(refusal.reason().starts_with("connect after "));
        }
        assert_eq!(Refusal::from_code(0), None);
        assert_eq!(Refusal::from_code(9), None);
        assert_eq!(Refusal::Closed.reason(), "connect after close");
        assert_eq!(Refusal::ChildExited.reason(), "connect after child exit");
        assert_eq!(
            Refusal::HostClosed.reason(),
            "connect after host closed the channel"
        );
    }

    /// Adoption needs all four to be false — any one of them means the transport in hand is not the
    /// one this client should be running.
    #[test]
    fn adoption_needs_every_reason_to_be_absent() {
        assert!(adopts(false, false, false, false));
        assert!(!adopts(true, false, false, false));
        assert!(!adopts(false, true, false, false));
        assert!(!adopts(false, false, true, false));
        assert!(!adopts(false, false, false, true), "a newer connect won");
    }

    /// A real drop is announced; the three expected ends are not.
    #[test]
    fn only_an_unexpected_end_is_announced() {
        assert!(announces_drop(false, false, false));
        assert!(!announces_drop(true, false, false), "a deliberate close");
        assert!(!announces_drop(false, true, false), "our own teardown");
        assert!(!announces_drop(false, false, true), "the post-exit FIN");
    }

    /// A campaign runs only for a client that still wants to be connected.
    #[test]
    fn a_campaign_runs_only_for_a_client_that_wants_one() {
        assert!(campaign_runs(false, false, false, false));
        assert!(!campaign_runs(true, false, false, false));
        assert!(!campaign_runs(false, true, false, false));
        assert!(!campaign_runs(false, false, true, false));
        assert!(!campaign_runs(false, false, false, true));
    }
}
