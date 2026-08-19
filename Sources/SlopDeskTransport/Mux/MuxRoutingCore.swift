import Foundation
import SlopDeskProtocol

/// The demux face behind ``MuxRouter``, the CLIENT's side of the mux.
///
/// It was side-agnostic when the host was Swift too, and the name still says so; the host's half
/// went to Rust with the rest of hostd. The RULE has now followed it: `slopdesk_wire`'s
/// `ChannelTable::route` decides, and ``ChannelTable/route(kind:id:accepted:)`` is the door.
///
/// ## Why the rule left and this file did not
///
/// Every branch of the decision read a state off the table and then wrote one back — six calls
/// across the FFI boundary to reach a table that was already Rust, with the rule that reasons about
/// it living on this side. That is the shape CLAUDE.md's "one implementation, never two languages"
/// is about: nothing forced the two apart, and a rule kept apart from its own state is a rule that
/// can be edited on one side only. The decision is one thing now, beside the map and the ring it
/// walks.
///
/// What is left here is genuinely this side's, and it is two things:
///
/// - **The payload.** The bytes never cross. A verdict names a channel; the `Data` this layer is
///   already holding is attached to it here, which is why ``MuxRoutingDecision/deliverData`` carries
///   one and the rule's own answer does not.
/// - **The wording.** `ChannelDropReason` is the rule's distinction — a late frame on a real channel
///   is not the same event as a frame for an id nobody ever issued. The human sentence each one gets
///   is presentation, and presentation is the caller's, the same way `StatusPresentation` decides a
///   mark and the renderers spell it.
enum MuxRoutingCore {
    static func route(_ frame: MuxFrame, in table: ChannelTable) -> MuxRoutingDecision {
        // Read for the open-ack alone; every other kind ignores it, so `false` is not a default
        // standing in for a missing answer — it is the absence of a question.
        let accepted = if case let .channelOpenAck(_, ack, _) = frame { ack } else { false }

        switch table.route(kind: frame.muxType, id: frame.channelID, accepted: accepted) {
        case let .deliver(channelID):
            // The one case that needs this side at all: the rule said WHERE, and the bytes are here.
            guard case let .channelData(_, payload) = frame else {
                // Unreachable by construction — `deliver` is only ever answered for a data frame —
                // and it is a drop rather than a trap because this is the receive path for bytes a
                // peer chose. A router that can be crashed by a frame is the defect the whole drop
                // vocabulary exists to avoid.
                return .dropUnknownChannel(channelID: channelID, reason: "deliver for a non-data frame")
            }
            return .deliverData(channelID: channelID, payload: payload)

        case let .lifecycle(channelID, state):
            return .lifecycle(channelID: channelID, newState: state)

        case let .drop(channelID, reason):
            return .dropUnknownChannel(channelID: channelID, reason: sentence(for: reason))
        }
    }

    /// The log line for a refusal. One sentence per reason, spelled once — the strings were inline
    /// at the two `return` sites they belonged to, which is exactly how two readings of one
    /// distinction start.
    private static func sentence(for reason: ChannelDropReason) -> String {
        switch reason {
        case .nonOpenChannel: "data for non-open channel"
        case .unknownChannel: "data for unknown channel"
        }
    }
}
