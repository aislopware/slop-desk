// SimulatorStreamConnection — the one socket the simulator panel holds: H.264 down, gestures up.
//
// `NWProtocolWebSocket` rather than `URLSessionWebSocketTask`, for the reason every other socket in
// this project is an `NWConnection`: ``TransportParameters/makeTCP()`` is the single place TCP
// parameters are decided, and `TCP_NODELAY` is the one that matters here. The upstream traffic is
// the definition of what Nagle ruins — a `touch1-move` every few milliseconds during a drag, each
// one a ~60-byte write. Coalesced into a delayed-ACK stall, a drag arrives as a stutter.
//
// ONE socket carries both directions because the server defines it that way: binary frames down,
// JSON text up. That is also why there is no separate input connection to keep in sync — a gesture
// cannot outlive the stream it belongs to, and both die together on disconnect.
//
// Hang-safety: this constructs a real network object, so nothing here may be built in a unit test.
// Everything it decides is delegated to pure code that is (``SimulatorWireProtocol``,
// ``SimulatorInputEnvelope``, ``SimulatorEndpoints``); this file is the plumbing between them.

#if os(macOS)
import Foundation
import Network
import SlopDeskTransport

/// What the panel learns from the socket. Delivered on the main actor — the consumer is a view
/// model, and hopping once here is cheaper than making every observer thread-safe.
enum SimulatorStreamEvent {
    /// The socket is up. No frames yet; the server sends the JPEG seed first.
    case connected
    /// A decoded downstream message worth acting on. `unknown` types never reach here.
    case message(SimulatorStreamMessage)
    /// The server said something on the text channel — errors, mostly. Surfaced rather than
    /// swallowed: a device that refuses to stream says so here and nowhere else.
    case text(String)
    /// The socket ended. `reason` is nil for a clean close.
    case ended(reason: String?)
}

/// The stream as its consumer sees it — three verbs, no network types. The model holds one of these
/// rather than the concrete class so a test can drive the whole panel (select, frames, teardown)
/// without a socket: constructing an `NWConnection` in a unit test is exactly the hang-safety rule
/// this project keeps.
@MainActor
protocol SimulatorStreaming: AnyObject {
    func connect(host: String, port: UInt16, udid: String)
    func disconnect()
    func send(_ envelope: SimulatorInputEnvelope)
}

@MainActor
final class SimulatorStreamConnection: SimulatorStreaming {
    private var connection: NWConnection?
    private let sink: (SimulatorStreamEvent) -> Void
    /// Set on teardown so a receive completion that was already in flight cannot resurrect a
    /// cancelled connection or deliver an event after `.ended`.
    private var isTornDown = false

    init(sink: @escaping (SimulatorStreamEvent) -> Void) {
        self.sink = sink
    }

    /// Open the stream for `udid`. Calling this on a live connection tears the old one down first —
    /// selecting a second device must not leave the first one decoding into nothing.
    func connect(host: String, port: UInt16, udid: String) {
        disconnect()
        guard let url = SimulatorEndpoints.stream(host: host, port: port, udid: udid) else {
            sink(.ended(reason: "no endpoint"))
            return
        }

        isTornDown = false
        // A URL endpoint, not host+port: the websocket handshake's request line comes from it, and
        // `format`/`version` ride the QUERY STRING. Dialling host+port would open a socket to the
        // right machine and ask it for the server's default dialect.
        let connection = NWConnection(to: .url(url), using: Self.parameters())
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in self?.handle(state) }
        }
        connection.start(queue: Self.queue)
    }

    func disconnect() {
        isTornDown = true
        connection?.cancel()
        connection = nil
    }

    /// Send one input envelope. Silently dropped when the socket is not up — a gesture fired during
    /// a reconnect is not worth queueing, and delivering it late would replay a tap the user has
    /// already moved on from.
    func send(_ envelope: SimulatorInputEnvelope) {
        guard let connection, connection.state == .ready, let json = envelope.json else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "input", metadata: [metadata])
        connection.send(content: Data(json.utf8), contentContext: context, completion: .idempotent)
    }

    // MARK: Plumbing

    /// One shared queue: a single socket carrying one device's frames has no head-of-line problem to
    /// solve, and the receive handler does nothing but hop to the main actor.
    private static let queue = DispatchQueue(label: "slopdesk.simulator.stream")

    /// The websocket runs over ``TransportParameters/makeTCP()`` so it inherits `TCP_NODELAY` —
    /// reaching for `NWParameters.tcp` here would silently restore Nagle on the gesture path.
    /// `autoReplyPing` keeps the connection alive without a keepalive of our own.
    /// `nonisolated` because it reads no state — which is also what makes it directly testable
    /// without hopping an actor to build a value object.
    ///
    /// `autoReplyPing` is deliberately NOT set. Measured: inserting an options object into
    /// `defaultProtocolStack.applicationProtocols` stores a COPY (`stack.first === options` is
    /// false) and the copy reads the flag back as its default. So setting it would look like
    /// keepalive handling while providing none — the failure mode being a socket the server drops on
    /// its own idle timer, minutes into a session, for no visible reason. ``replyToPing(_:)`` does
    /// the job explicitly instead, where it can be read and reasoned about.
    nonisolated static func parameters() -> NWParameters {
        let parameters = TransportParameters.makeTCP()
        parameters.defaultProtocolStack.applicationProtocols.insert(NWProtocolWebSocket.Options(), at: 0)
        return parameters
    }

    private func handle(_ state: NWConnection.State) {
        guard !isTornDown else { return }
        switch state {
        case .ready:
            sink(.connected)
            receive()
        case let .failed(error):
            sink(.ended(reason: error.localizedDescription))
            disconnect()
        case .cancelled:
            sink(.ended(reason: nil))
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
    private func receive() {
        guard let connection else { return }
        connection.receiveMessage { [weak self] data, context, _, error in
            Task { @MainActor in
                guard let self, !self.isTornDown else { return }
                if let error {
                    self.sink(.ended(reason: error.localizedDescription))
                    self.disconnect()
                    return
                }
                self.deliver(data, context: context)
                self.receive()
            }
        }
    }

    private func deliver(_ data: Data?, context: NWConnection.ContentContext?) {
        guard let data, !data.isEmpty else { return }
        let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
        switch (metadata as? NWProtocolWebSocket.Metadata)?.opcode {
        case .text:
            if let text = String(data: data, encoding: .utf8) { sink(.text(text)) }
        case .binary:
            // An unknown type byte is dropped here rather than forwarded: a message this build has
            // no case for is not an event the panel can act on.
            if let message = SimulatorWireProtocol.decode(data), !message.isUnknown {
                sink(.message(message))
            }
        case .ping:
            replyToPing(data)
        case .close:
            sink(.ended(reason: nil))
            disconnect()
        default:
            break
        }
    }

    /// Echo a ping back as a pong, payload included — RFC 6455 requires the same application data.
    /// This is the whole keepalive: the server pings, we answer, the socket stays up.
    private func replyToPing(_ payload: Data) {
        guard let connection else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .pong)
        let context = NWConnection.ContentContext(identifier: "pong", metadata: [metadata])
        connection.send(content: payload, contentContext: context, completion: .idempotent)
    }
}

extension SimulatorStreamMessage {
    var isUnknown: Bool {
        if case .unknown = self { return true }
        return false
    }
}
#endif
