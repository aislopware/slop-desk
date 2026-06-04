import Foundation
import RworkProtocol

/// The shared, side-agnostic demux core for ``MuxRouter`` (client) and
/// ``HostChannelRouter`` (host).
///
/// Both sides apply the SAME pure rule to a decoded ``MuxFrame``:
/// - `channelData` for an OPEN channel → deliver the opaque inner bytes upward;
/// - `channelData` for an unknown / closed channel → DROP (a stale or hostile frame
///   must never crash the receiver — same contract as `InputDatagramRouter.drop`);
/// - `channelOpen` / `channelOpenAck` → advance the channel to ``ChannelState/open``;
/// - `channelClose` → record the peer's close (one-step SSH symmetry) and report the
///   resulting state;
/// - `windowAdjust` → no table state change; reported as `lifecycle` with the
///   channel's current state (the actual credit math lives in `FlowCreditPolicy`,
///   owned by the IO layer, not here).
///
/// Factored out so the two routers cannot drift apart: the only thing that differs
/// between client and host is which side allocates ids, not how a frame is demuxed.
enum MuxRoutingCore {
    static func route(_ frame: MuxFrame, in table: inout ChannelTable) -> MuxRoutingDecision {
        let id = frame.channelID

        switch frame {
        case let .channelData(_, payload):
            // Only deliver to a fully-open channel; everything else is dropped (never a crash).
            guard table.isOpen(id) else {
                let known = table.state(of: id) != nil
                return .dropUnknownChannel(
                    channelID: id,
                    reason: known ? "data for non-open channel" : "data for unknown channel"
                )
            }
            return .deliverData(channelID: id, payload: payload)

        case .channelOpen:
            // Responder registers the peer-initiated channel as open. open() is a no-op
            // for a closing/closed id, so a late open cannot resurrect a dead channel.
            table.open(id)
            let state = table.state(of: id) ?? .open
            return .lifecycle(channelID: id, newState: state)

        case let .channelOpenAck(_, accepted):
            // The responder ACCEPTED or REFUSED the open we initiated. ONLY an accept
            // advances the channel to .open; a refusal marks it dead via reject() — never
            // route data to a refused channel (the original bug routed data to a channel
            // the host had refused). The IO layer reads the resulting state to either
            // complete or FAIL the openChannel() caller.
            let state: ChannelState
            if accepted {
                table.open(id)
                state = table.state(of: id) ?? .open
            } else {
                state = table.reject(id)
            }
            return .lifecycle(channelID: id, newState: state)

        case .channelClose:
            // The peer sent CHANNEL_CLOSE: advance the symmetric close machine.
            let newState = table.remoteClose(id)
            return .lifecycle(channelID: id, newState: newState)

        case .windowAdjust:
            // Window credit is owned by the IO layer's FlowCreditPolicy; the table
            // state is unchanged. Report the channel's current state (or .closed if
            // we never knew it — a stale adjust is harmless and not delivered).
            let state = table.state(of: id) ?? .closed
            return .lifecycle(channelID: id, newState: state)
        }
    }
}
