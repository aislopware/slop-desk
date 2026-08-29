//! What a mux connection lets past its door, and what a channel-ending event tears down.
//!
//! [`channels`](super::channels) answers where a frame GOES once the connection has agreed to
//! reason about it at all. This module is the two questions on either side of that one: whether the
//! frame is admissible in the first place, and — once a channel ends, however it ends — which of
//! the two sub-channels and which of the two tables the ending reaches.
//!
//! ## Why the ladder is a rule rather than four `if`s
//! Every guard here exists because a frame a well-behaved peer never sends costs the receiver
//! something unbounded, and the cost is different for each:
//!
//! - An over-cap `channelOpen` grows the router table forever. The EXPENSIVE half — the fork — is
//!   bounded already; the table is not, so the refusal has to come BEFORE the table advances.
//! - A `channelOpen` on the CONTROL link opens a phantom entry in the control table that nothing
//!   ever closes, because the close path is keyed off the DATA link.
//! - A `channelOpen` arriving at the CLIENT is the same phantom in the client's own data table, and
//!   the terminal ring only bounds ids that reached a terminal state — an id that never opens
//!   legitimately never reaches one.
//! - A `channelOpen` re-presenting an id that already finished is one fresh PTY per open/close
//!   cycle on a SINGLE id. The live-channel cap never trips, because the live count stays at one.
//!
//! None of the four fails a build, none of them is visible in a passing test that does not think to
//! send the frame, and the ORDER between them is load-bearing: swap the cap check past the table
//! advance and the cap stops bounding the thing it was written to bound. That is the class docs/55
//! §8 names — a precedence that is only ever a comment — so the precedence is [`admit`] and its
//! tests, not a comment.
//!
//! ## Why the teardown is a rule too
//! A pane is ONE session behind TWO sub-channels, so a channel that ends on one link has to reach
//! the other. Hand-written, that was two nearly-identical branches per event, mirrored per role,
//! and each mirror had a way to leave a zombie: a poisoned CONTROL channel whose DATA sibling is
//! never reaped keeps a shell alive with no close trigger left, and a peer close on DATA alone
//! leaks the CONTROL sub-channel plus an `Open` control-table entry that the eviction ring — which
//! only walks terminal ids — will never collect.
//!
//! [`poisoned`] and [`peer_close`] are those two branches as one total function each, and the two
//! differ in exactly one place, which is the point of writing them side by side: a poisoned channel
//! is closed by THIS side, so both tables step locally; a peer close was already applied to the
//! arriving link's table by the router, so only the SIBLING steps, and it steps remotely.
//!
//! No socket, no task, no payload — the caller holds the sub-channels and finishes them.

use super::channels::{ChannelState, FrameKind};
use super::flow::MuxFlowControl;

/// Which end of the connection is asking.
///
/// The mux is asymmetric on purpose: the client allocates ids and initiates every open, the host
/// only ever responds. Half the ladder below is that asymmetry stated once.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum Role {
    /// Allocates odd ids and initiates opens.
    Client = 0,
    /// Registers the ids it is shown, and owns the PTY behind each.
    Host = 1,
}

impl Role {
    /// Whether this end is the one that allocates ids and SENDS `channelOpen`.
    ///
    /// The same fact [`admit`] spends when it drops an open arriving at the initiator, offered as a
    /// question because a transport needs it on the sending side too: refusing to open a channel
    /// from a responder is a guard on an outbound frame, and [`admit`] judges arrivals only. Two
    /// callers, one rule — and a test below pins them to each other, so a future asymmetry cannot
    /// land in one and not the other.
    #[must_use]
    pub const fn initiates_opens(self) -> bool {
        matches!(self, Self::Client)
    }
}

/// Which of the two physical links a frame arrived on.
///
/// The split is the reason a `resize` is never stuck behind a megabyte of `output`; here it also
/// means a frame's link is part of whether the frame makes sense at all.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum Link {
    /// Small frames: opens, acks, closes, resizes, window grants.
    Control = 0,
    /// PTY bytes, and the link an open is initiated on.
    Data = 1,
}

/// Everything the ladder reads about one arriving frame.
///
/// Deliberately not the frame: no payload crosses, and no id either except as the caller's own
/// lookup key. What is here is the six facts the four guards are functions of.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Arrival {
    /// Which end received it.
    pub role: Role,
    /// Which link it came in on.
    pub link: Link,
    /// The envelope's type byte, already resolved.
    pub kind: FrameKind,
    /// Whether this end already has a DATA sub-channel registered for the frame's id. A
    /// retransmitted open for a live id is legitimate and must NOT be refused — it is suppressed
    /// later, by the caller, so the second open does not fork a second shell.
    pub registered: bool,
    /// How many DATA channels are live on this connection right now.
    pub live_channels: usize,
    /// The DATA table's state for the frame's id, or `None` when the table has never heard of it.
    pub prior_data_state: Option<ChannelState>,
}

/// Why an open is being refused with `accepted: false` rather than dropped.
///
/// A refusal is an ANSWER — the initiator is waiting on one, and a silent drop would hang it — so
/// the two cases that can refuse are the two where somebody is listening.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum Refusal {
    /// This connection already carries as many channels as it may.
    OverCap = 0,
    /// The id already reached a terminal state here. Ids are monotonic and never reused, so this is
    /// a stale retransmit or a peer trying to spend one id on many shells.
    Reopen = 1,
}

/// Why a frame is being dropped without an answer.
///
/// Both cases are frames a correct peer cannot send, so there is nobody legitimate to answer TO;
/// an ack for either would be an ack on a link or a role that does not carry acks.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum Ignored {
    /// An open on the CONTROL link. Opens are initiated on DATA, always.
    OpenOnControlLink = 0,
    /// An open arriving at the CLIENT, which is the only side that initiates them.
    OpenAtInitiator = 1,
}

/// What the connection does with a frame before the routing decision runs.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Admission {
    /// Hand it to the router.
    Proceed,
    /// Send a refusing `channelOpenAck` on the DATA link and advance nothing.
    Refuse(Refusal),
    /// Advance nothing and say nothing.
    Drop(Ignored),
}

/// The precedence the four guards run in, and the whole of it.
///
/// Ordered as the failures are ranked, not as the code reads: the cap is first because it is the
/// only guard that bounds MEMORY against a peer that is otherwise well-formed, and the link and
/// role drops precede the reopen refusal because a frame on the wrong link has no id worth looking
/// up — the table it would be looked up in is the one the drop exists to protect.
#[must_use]
pub fn admit(arrival: &Arrival) -> Admission {
    if !matches!(arrival.kind, FrameKind::ChannelOpen) {
        return Admission::Proceed;
    }
    let responder_on_data = arrival.role == Role::Host && arrival.link == Link::Data;

    if responder_on_data
        && !arrival.registered
        && arrival.live_channels >= MuxFlowControl::MAX_CHANNELS_PER_CONNECTION
    {
        return Admission::Refuse(Refusal::OverCap);
    }
    if arrival.link == Link::Control {
        return Admission::Drop(Ignored::OpenOnControlLink);
    }
    if arrival.role.initiates_opens() {
        return Admission::Drop(Ignored::OpenAtInitiator);
    }
    if responder_on_data
        && matches!(
            arrival.prior_data_state,
            Some(ChannelState::Closed | ChannelState::HalfClosed)
        )
    {
        return Admission::Refuse(Refusal::Reopen);
    }
    Admission::Proceed
}

/// How a table advances as part of a teardown.
///
/// [`Hold`](TableStep::Hold) is not "nothing happened" — it is "the router already did this one",
/// which is the entire difference between the two teardown events and the reason this is a
/// three-state value rather than a `bool` beside a `bool`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
#[repr(u8)]
pub enum TableStep {
    /// Leave it alone.
    #[default]
    Hold = 0,
    /// `local_close` — this side is ending the channel.
    Local = 1,
    /// `remote_close` — the peer ended it.
    Remote = 2,
}

/// What one channel-ending event reaches.
///
/// Five fields and no id: the caller knows which channel it is asking about, and every field is an
/// instruction about the pair of sub-channels it already holds.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub struct Teardown {
    /// Unregister the DATA sub-channel and drop its receive-window accounting.
    pub drop_data: bool,
    /// Unregister the CONTROL sub-channel.
    pub drop_control: bool,
    /// How the DATA table advances.
    pub data_table: TableStep,
    /// How the CONTROL table advances.
    pub control_table: TableStep,
    /// Fire — or buffer, if it is not installed yet — the host's close hook, which reaps the PTY.
    /// Never true on the client, which has no PTY to reap.
    pub reap: bool,
}

/// A sub-channel's own inner framing faulted while the rest of the connection is healthy.
///
/// THIS side is ending the channel, so both tables step locally, and on the host the sibling goes
/// with it: the pair anchors one shell, and the peer — whose side is already finished — is not
/// going to send a close that would reap it.
#[must_use]
pub const fn poisoned(role: Role, link: Link) -> Teardown {
    let host = matches!(role, Role::Host);
    let on_data = matches!(link, Link::Data);
    let data = on_data || host;
    let control = !on_data || host;
    Teardown {
        drop_data: data,
        drop_control: control,
        data_table: if data { TableStep::Local } else { TableStep::Hold },
        control_table: if control {
            TableStep::Local
        } else {
            TableStep::Hold
        },
        reap: host,
    }
}

/// The peer closed this channel on this link.
///
/// The arriving link's table was already advanced by the router — that is what produced the
/// lifecycle decision this is the reaction to — so it [`Hold`](TableStep::Hold)s here, and only the
/// sibling steps. A well-behaved client closes on BOTH links, which makes the sibling step a
/// harmless no-op; a client that closes on DATA only is the case this exists for.
#[must_use]
pub const fn peer_close(role: Role, link: Link) -> Teardown {
    let host_on_data = matches!(role, Role::Host) && matches!(link, Link::Data);
    Teardown {
        drop_data: matches!(link, Link::Data),
        drop_control: matches!(link, Link::Control) || host_on_data,
        data_table: TableStep::Hold,
        control_table: if host_on_data {
            TableStep::Remote
        } else {
            TableStep::Hold
        },
        reap: host_on_data,
    }
}

#[cfg(test)]
mod tests {
    use super::{
        Admission, Arrival, ChannelState, FrameKind, Ignored, Link, MuxFlowControl, Refusal, Role, TableStep,
        admit, peer_close, poisoned,
    };

    fn open_at(role: Role, link: Link) -> Arrival {
        Arrival {
            role,
            link,
            kind: FrameKind::ChannelOpen,
            registered: false,
            live_channels: 0,
            prior_data_state: None,
        }
    }

    #[test]
    fn every_frame_that_is_not_an_open_walks_straight_through() {
        // The ladder is entirely about opens; a data frame at the cap is a frame on a channel that
        // was already admitted, and gating it would stall a live pane rather than bound anything.
        for kind in [
            FrameKind::ChannelOpenAck,
            FrameKind::ChannelData,
            FrameKind::ChannelClose,
            FrameKind::WindowAdjust,
        ] {
            let arrival = Arrival {
                kind,
                live_channels: MuxFlowControl::MAX_CHANNELS_PER_CONNECTION + 9,
                prior_data_state: Some(ChannelState::Closed),
                ..open_at(Role::Host, Link::Data)
            };
            assert_eq!(admit(&arrival), Admission::Proceed, "{kind:?}");
        }
    }

    #[test]
    fn a_new_open_at_the_cap_is_refused_and_one_under_it_is_not() {
        let at_cap = Arrival {
            live_channels: MuxFlowControl::MAX_CHANNELS_PER_CONNECTION,
            ..open_at(Role::Host, Link::Data)
        };
        assert_eq!(admit(&at_cap), Admission::Refuse(Refusal::OverCap));

        let under_cap = Arrival {
            live_channels: MuxFlowControl::MAX_CHANNELS_PER_CONNECTION - 1,
            ..at_cap
        };
        assert_eq!(admit(&under_cap), Admission::Proceed);
    }

    #[test]
    fn a_retransmitted_open_for_a_live_channel_is_not_refused_by_the_cap() {
        // The id is already counted in `live_channels`, so a registered open at the cap is the
        // incumbent's own retransmit. Refusing it would tell a healthy pane its channel was denied.
        let again = Arrival {
            registered: true,
            live_channels: MuxFlowControl::MAX_CHANNELS_PER_CONNECTION,
            ..open_at(Role::Host, Link::Data)
        };
        assert_eq!(admit(&again), Admission::Proceed);
    }

    #[test]
    fn the_cap_is_checked_before_the_table_can_be_advanced() {
        // The precedence, stated as the only thing that could disprove it: an over-cap open whose
        // id ALSO reads as a stale reopen still answers OverCap. If the reopen guard ran first the
        // cap would be reached only by ids with no history, which is every id a flooder mints.
        let both = Arrival {
            live_channels: MuxFlowControl::MAX_CHANNELS_PER_CONNECTION,
            prior_data_state: Some(ChannelState::Closed),
            ..open_at(Role::Host, Link::Data)
        };
        assert_eq!(admit(&both), Admission::Refuse(Refusal::OverCap));
    }

    #[test]
    fn an_open_on_the_control_link_is_dropped_at_either_end() {
        for role in [Role::Client, Role::Host] {
            assert_eq!(
                admit(&open_at(role, Link::Control)),
                Admission::Drop(Ignored::OpenOnControlLink),
                "{role:?}",
            );
        }
    }

    #[test]
    fn an_open_arriving_at_the_client_is_dropped() {
        assert_eq!(
            admit(&open_at(Role::Client, Link::Data)),
            Admission::Drop(Ignored::OpenAtInitiator),
        );
    }

    /// The sending side's guard and the receiving side's drop are the SAME fact, so they are pinned
    /// to each other rather than each to a literal. A transport asks `initiates_opens` before it
    /// sends an open; `admit` drops one that arrives at that end. If a future change ever made a
    /// second role initiate, one of the two would otherwise keep the old answer.
    #[test]
    fn the_role_that_initiates_is_the_role_an_arriving_open_is_dropped_at() {
        for role in [Role::Client, Role::Host] {
            assert_eq!(
                admit(&open_at(role, Link::Data)) == Admission::Drop(Ignored::OpenAtInitiator),
                role.initiates_opens(),
                "{role:?}",
            );
        }
    }

    #[test]
    fn an_id_that_already_finished_is_refused_rather_than_reopened() {
        for state in [ChannelState::Closed, ChannelState::HalfClosed] {
            let stale = Arrival {
                prior_data_state: Some(state),
                ..open_at(Role::Host, Link::Data)
            };
            assert_eq!(admit(&stale), Admission::Refuse(Refusal::Reopen), "{state:?}");
        }
        // Idle and Open are not terminal: the first is an allocated id that has not carried data,
        // the second is the retransmit case above.
        for state in [ChannelState::Idle, ChannelState::Open] {
            let live = Arrival {
                prior_data_state: Some(state),
                ..open_at(Role::Host, Link::Data)
            };
            assert_eq!(admit(&live), Admission::Proceed, "{state:?}");
        }
    }

    #[test]
    fn a_poisoned_channel_reaps_its_sibling_on_the_host_from_either_link() {
        for link in [Link::Control, Link::Data] {
            let verdict = poisoned(Role::Host, link);
            assert!(verdict.drop_data && verdict.drop_control, "{link:?}");
            assert_eq!(verdict.data_table, TableStep::Local, "{link:?}");
            assert_eq!(verdict.control_table, TableStep::Local, "{link:?}");
            assert!(verdict.reap, "{link:?}");
        }
    }

    #[test]
    fn a_poisoned_channel_on_the_client_touches_only_its_own_link() {
        let control = poisoned(Role::Client, Link::Control);
        assert_eq!(
            (control.drop_data, control.drop_control, control.reap),
            (false, true, false),
        );
        assert_eq!(control.data_table, TableStep::Hold);
        assert_eq!(control.control_table, TableStep::Local);

        let data = poisoned(Role::Client, Link::Data);
        assert_eq!(
            (data.drop_data, data.drop_control, data.reap),
            (true, false, false),
        );
        assert_eq!(data.data_table, TableStep::Local);
        assert_eq!(data.control_table, TableStep::Hold);
    }

    #[test]
    fn a_peer_close_never_re_advances_the_link_it_arrived_on() {
        // The router applied it already. Stepping it again would drive a half-closed channel to
        // closed on one side's say-so and evict an id the peer may still be sending on.
        for role in [Role::Client, Role::Host] {
            assert_eq!(peer_close(role, Link::Data).data_table, TableStep::Hold);
            assert_eq!(peer_close(role, Link::Control).control_table, TableStep::Hold,);
        }
    }

    #[test]
    fn a_peer_close_on_data_takes_the_control_sibling_with_it_on_the_host() {
        let verdict = peer_close(Role::Host, Link::Data);
        assert!(verdict.drop_data && verdict.drop_control);
        assert_eq!(verdict.control_table, TableStep::Remote);
        assert!(verdict.reap);
    }

    #[test]
    fn a_peer_close_on_control_reaps_nothing() {
        // The reap is keyed off the DATA link so it fires exactly once per channel; a client that
        // closes both links must not fork the hook twice.
        for role in [Role::Client, Role::Host] {
            let verdict = peer_close(role, Link::Control);
            assert!(!verdict.reap, "{role:?}");
            assert!(!verdict.drop_data, "{role:?}");
            assert!(verdict.drop_control, "{role:?}");
        }
    }
}
