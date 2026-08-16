#if os(macOS)
import Foundation
import Network

/// The websocket lifecycle both simulator sockets run: the state machine, the one-message-at-a-time
/// receive loop, and the explicit pong.
///
/// The two lanes carry different things — one frames, one log lines — and their `deliver` and their
/// event enums stay their own. What they never differed in is the socket: `ready` starts receiving,
/// `failed` reports and tears down, `cancelled` reports a clean end, and every other state is a
/// step on the way.
///
/// ## The pong is the reason this is worth sharing
///
/// `autoReplyPing` is deliberately NOT set, and both files carried the same measured paragraph
/// explaining why: inserting an options object into `defaultProtocolStack.applicationProtocols`
/// stores a COPY — `stack.first === options` is false — and the copy reads the flag back as its
/// default. Setting it LOOKS like keepalive handling while providing none, and the failure is a
/// socket the server drops on its own idle timer minutes into a session for no visible reason.
/// ``replyToPing(_:)`` does the job explicitly. A trap that subtle, discovered by measurement, is
/// exactly the thing that must not exist in two places for one of them to lose.
@MainActor
protocol SimulatorWebSocketLane: AnyObject, Sendable {
    /// The live socket, or `nil` once torn down.
    var connection: NWConnection? { get set }
    /// Set by `disconnect()`; every callback returns early once it is true.
    var isTornDown: Bool { get }

    /// The lane's own "the socket is up" event.
    func noteConnected()
    /// The lane's own "the socket is over" event. `reason` is `nil` for a clean close.
    func noteEnded(reason: String?)
    /// One websocket message, in whatever the lane's protocol makes of it.
    func deliver(_ data: Data?, context: NWConnection.ContentContext?)
    /// Tears the socket down. Implemented by the lane because only it knows what else to release.
    func disconnect()
}

extension SimulatorWebSocketLane {
    /// The connection state machine.
    func handle(_ state: NWConnection.State) {
        guard !isTornDown else { return }
        switch state {
        case .ready:
            noteConnected()
            receive()
        case let .failed(error):
            noteEnded(reason: error.localizedDescription)
            disconnect()
        case .cancelled:
            noteEnded(reason: nil)
        case .setup,
             .preparing,
             .waiting:
            break
        @unknown default:
            break
        }
    }

    /// One message at a time, re-armed after each. `receiveMessage` hands back whole websocket
    /// messages already reassembled from frames, which is why there is no defragmentation here.
    func receive() {
        guard let connection else { return }
        connection.receiveMessage { [weak self] data, context, _, error in
            Task { @MainActor in
                guard let self, !self.isTornDown else { return }
                if let error {
                    self.noteEnded(reason: error.localizedDescription)
                    self.disconnect()
                    return
                }
                self.deliver(data, context: context)
                self.receive()
            }
        }
    }

    /// The explicit pong. See the type comment for why it is not `autoReplyPing`.
    func replyToPing(_ payload: Data) {
        guard let connection else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .pong)
        let context = NWConnection.ContentContext(identifier: "pong", metadata: [metadata])
        connection.send(content: payload, contentContext: context, completion: .idempotent)
    }
}
#endif
