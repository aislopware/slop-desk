// SimulatorLogConnection — the console's socket. Text down, nothing up.
//
// A SECOND websocket beside the frame stream, not a channel on it. The server routes them
// separately (`/logs` against `/stream`), they have opposite lifetimes — the console is opened and
// closed while the stream stays up — and a log subscription that died with a video reconnect would
// lose the output covering exactly the moment someone was investigating.
//
// The socket is opened only while the console is OPEN. `log stream` is a real child process on the
// host per subscriber, so a console left subscribed behind a collapsed panel is a process the user
// cannot see and did not ask for.
//
// Hang-safety: this constructs a real network object, so nothing here may be built in a unit test.
// The parsing it delegates to (``SimulatorLogLine``, ``SimulatorLogMessage``) is pure and is where
// the tests are.

#if os(macOS)
import Foundation
import Network
import SlopDeskTransport

/// What the console learns from its socket. Delivered on the main actor, like the frame stream's.
enum SimulatorLogEvent {
    /// The socket is up. Not the same as `log stream` having started — that is ``started``.
    case connected
    /// The server's child is running; output follows.
    case started
    /// One batch. Already whole lines: the server splits, so nothing here reassembles.
    case lines([String])
    /// The socket ended. `reason` is nil for a clean close.
    case ended(reason: String?)
}

/// The console's socket as its consumer sees it. A protocol so the model can be driven in a test
/// without opening one.
@MainActor
protocol SimulatorLogStreaming: AnyObject {
    func connect(host: String, port: UInt16, udid: String, level: SimulatorLogLevel)
    func disconnect()
}

@MainActor
final class SimulatorLogConnection: SimulatorLogStreaming {
    private var connection: NWConnection?
    private let sink: (SimulatorLogEvent) -> Void
    /// Set on teardown so a receive completion already in flight cannot deliver after `.ended`.
    private var isTornDown = false

    init(sink: @escaping (SimulatorLogEvent) -> Void) {
        self.sink = sink
    }

    func connect(host: String, port: UInt16, udid: String, level: SimulatorLogLevel) {
        disconnect()
        guard let url = SimulatorEndpoints.logs(
            host: host, port: port, udid: udid, level: level.rawValue,
        ) else {
            sink(.ended(reason: "no endpoint"))
            return
        }

        isTornDown = false
        let connection = NWConnection(to: .url(url), using: SimulatorStreamConnection.parameters())
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

    // MARK: Plumbing

    /// Its own queue, not the frame stream's: a log burst must not sit behind a video frame's hop,
    /// and the two sockets have no ordering relationship to preserve.
    private static let queue = DispatchQueue(label: "slopdesk.simulator.logs")

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
            guard let text = String(data: data, encoding: .utf8) else { return }
            switch SimulatorLogMessage.decode(text) {
            case .started: sink(.started)
            case let .lines(lines): sink(.lines(lines))
            case .unknown: break
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

    /// Same explicit pong as the frame stream, for the same measured reason: `autoReplyPing` on an
    /// inserted options object is inert, so a socket without this is dropped on the server's idle
    /// timer minutes in.
    private func replyToPing(_ payload: Data) {
        guard let connection else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .pong)
        let context = NWConnection.ContentContext(identifier: "pong", metadata: [metadata])
        connection.send(content: payload, contentContext: context, completion: .idempotent)
    }
}
#endif
