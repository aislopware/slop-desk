import CSlopDeskFFI
import SlopDeskProtocol

/// Which end of a mux connection this is.
///
/// The mux is asymmetric: the client allocates odd ids and initiates every open, the host only ever
/// responds. Half of ``MuxDoorman/admit(role:link:frame:registered:liveChannels:priorDataState:)``
/// is that asymmetry, which is why it is a fact the rule reads rather than a branch each call site
/// writes.
public enum MuxEnd: UInt32, Sendable, Equatable {
    /// Allocates ids and initiates opens.
    case client = 0
    /// Registers the ids it is shown, and owns the PTY behind each.
    case host = 1
}

/// Which of the two physical links a frame arrived on.
public enum MuxLink: UInt32, Sendable, Equatable {
    /// Small frames: opens, acks, closes, resizes, window grants.
    case control = 0
    /// PTY bytes, and the link an open is initiated on.
    case data = 1
}

/// Why an open is refused with `accepted: false` rather than dropped silently.
public enum MuxRefusal: Sendable, Equatable {
    /// The connection already carries as many channels as it may.
    case overCap
    /// The id already reached a terminal state here — a stale retransmit, or a peer trying to spend
    /// one id on many shells.
    case reopen
}

/// Why a frame is dropped with no answer at all.
public enum MuxIgnored: Sendable, Equatable {
    /// An open on the CONTROL link. Opens are initiated on DATA, always.
    case openOnControlLink
    /// An open arriving at the CLIENT, which is the only side that initiates them.
    case openAtInitiator
}

/// What a connection does with an arriving frame before the routing decision runs.
public enum MuxAdmission: Sendable, Equatable {
    /// Hand it to ``ChannelTable/route(kind:id:accepted:)``.
    case proceed
    /// Send a refusing `channelOpenAck` on the DATA link and advance nothing.
    case refuse(MuxRefusal)
    /// Advance nothing and say nothing.
    case drop(MuxIgnored)
}

/// How a channel table advances as part of a teardown.
public enum MuxTableStep: Sendable, Equatable {
    /// Leave it alone — which for a peer close means the router already advanced it, not that
    /// nothing happened.
    case hold
    /// `localClose` — this side is ending the channel.
    case localClose
    /// `remoteClose` — the peer ended it.
    case remoteClose
}

/// What one channel-ending event reaches.
///
/// No channel id: the caller knows which channel it asked about, and every field is an instruction
/// about the pair of sub-channels it is already holding.
public struct MuxTeardown: Sendable, Equatable {
    /// Unregister the DATA sub-channel and drop its receive-window accounting.
    public let dropData: Bool
    /// Unregister the CONTROL sub-channel.
    public let dropControl: Bool
    /// Fire — or buffer, if it is not installed yet — the host's close hook, which reaps the PTY.
    /// Never true on the client.
    public let reap: Bool
    /// How the DATA table advances.
    public let dataTable: MuxTableStep
    /// How the CONTROL table advances.
    public let controlTable: MuxTableStep
}

/// The face over `slopdesk_wire`'s `mux::admission` — the guards in front of the demux rule, and
/// the two teardowns behind it.
///
/// ## Why the ladder left Swift
/// Four guards stood between an arriving frame and ``MuxRoutingCore/route(_:in:)``, and each one
/// existed because a frame a correct peer never sends costs this side something unbounded: a router
/// table grown forever, a phantom control-table entry nothing closes, one fresh PTY per open/close
/// cycle on a single reused id. None of the four fails a build. Worse, the ORDER between them is
/// load-bearing — a cap checked after the table advances is a cap that stopped bounding the table
/// it was written to bound — and an order is exactly what docs/55 §8 names as the thing a comment
/// cannot hold. It is `admission::admit` and its tests now.
///
/// ## Why the teardowns came with it
/// A pane is ONE session behind TWO sub-channels, so a channel that ends on one link has to reach
/// the other. Written by hand that was two nearly-identical branches per event, mirrored per role,
/// and each mirror had its own way to leave a zombie shell. They are two total functions now, and
/// they are worth reading side by side: a poisoned channel is closed by THIS side, so both tables
/// step locally; a peer close was already applied to the arriving link's table by the router, so
/// only the sibling steps, and it steps remotely.
///
/// ## What stays here
/// Everything with a lifetime. The sub-channels, the tasks, the `Data`, the refusing ack and the
/// close hook are all the caller's — a verdict names WHAT, and the connection does it.
public enum MuxDoorman {
    /// Whether the connection reasons about this frame at all.
    ///
    /// `priorDataState` is the DATA table's state for the frame's id; `nil` for an id the table has
    /// never heard of. `registered` is whether this end already holds a DATA sub-channel for it —
    /// a retransmitted open for a live channel is legitimate and must not be refused by the cap,
    /// because its id is already counted in `liveChannels`.
    public static func admit(
        role: MuxEnd,
        link: MuxLink,
        frame: MuxFrameType,
        registered: Bool,
        liveChannels: Int,
        priorDataState: ChannelState?,
    ) -> MuxAdmission {
        let verdict = slopdesk_mux_admit(
            role.rawValue,
            link.rawValue,
            frame.rawValue,
            registered,
            UInt32(clamping: liveChannels),
            priorDataState?.rawValue ?? SLOPDESK_CHANNEL_UNKNOWN,
        )
        switch verdict {
        case SLOPDESK_MUX_ADMISSION_REFUSE_OVER_CAP: return .refuse(.overCap)
        case SLOPDESK_MUX_ADMISSION_REFUSE_REOPEN: return .refuse(.reopen)
        case SLOPDESK_MUX_ADMISSION_DROP_OPEN_ON_CONTROL: return .drop(.openOnControlLink)
        case SLOPDESK_MUX_ADMISSION_DROP_OPEN_AT_INITIATOR: return .drop(.openAtInitiator)
        default:
            // PROCEED, and every ordinal the door has not spoken. Failing OPEN here is right where
            // the routing rule's own default fails closed: past this point the frame still has to
            // satisfy `ChannelTable::route`, which drops what it cannot place. An unrecognised
            // ordinal read as a refusal would answer a peer's legitimate open with a denial.
            return .proceed
        }
    }

    /// What a sub-channel's own inner decode fault tears down, the rest of the mux being healthy.
    public static func poisoned(role: MuxEnd, link: MuxLink) -> MuxTeardown {
        teardown(slopdesk_mux_teardown_poisoned(role.rawValue, link.rawValue))
    }

    /// What the peer's close on this link tears down.
    public static func peerClose(role: MuxEnd, link: MuxLink) -> MuxTeardown {
        teardown(slopdesk_mux_teardown_peer_close(role.rawValue, link.rawValue))
    }

    private static func teardown(_ verdict: SlopDeskMuxTeardown) -> MuxTeardown {
        MuxTeardown(
            dropData: verdict.drop_data,
            dropControl: verdict.drop_control,
            reap: verdict.reap,
            dataTable: step(verdict.data_table),
            controlTable: step(verdict.control_table),
        )
    }

    /// A table step, read back. An ordinal the door has not spoken reads as ``MuxTableStep/hold``:
    /// advancing a table on a verdict nobody wrote would drive a half-closed channel to closed on
    /// one side's say-so and evict an id the peer may still be sending on.
    private static func step(_ ordinal: UInt8) -> MuxTableStep {
        switch UInt32(ordinal) {
        case SLOPDESK_MUX_TABLE_LOCAL: .localClose
        case SLOPDESK_MUX_TABLE_REMOTE: .remoteClose
        default: .hold
        }
    }
}
