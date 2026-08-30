// SimulatorLogConnection — the console's socket. Text down, nothing up.
//
// A SECOND websocket beside the frame stream, not a channel on it. The server routes them
// separately (`/logs` against `/stream`), they have opposite lifetimes — the console is opened and
// closed while the stream stays up — and a log subscription that died with a video reconnect would
// lose the output covering exactly the moment someone was investigating. Each is its own
// `slopdesk_device_ws_*` handle with its own reader thread, so a log burst never sits behind a
// video frame.
//
// The socket is opened only while the console is OPEN. `log stream` is a real child process on the
// host per subscriber, so a console left subscribed behind a collapsed panel is a process the user
// cannot see and did not ask for.
//
// What is left in this file is the panel's dialect: which text message is worth an event. The
// parsing is ``SimulatorLogMessage``'s and the socket is `slopdesk-devicelink`'s.

import CSlopDeskFFI
import Foundation

/// What the console learns from its socket. Delivered on the main actor, like the frame stream's.
package enum SimulatorLogEvent {
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
package protocol SimulatorLogStreaming: AnyObject {
    func connect(host: String, port: UInt16, udid: String, level: SimulatorLogLevel)
    func disconnect()
}

@MainActor
package final class SimulatorLogConnection: SimulatorLogStreaming {
    private let sink: (SimulatorLogEvent) -> Void
    private var lane: DeviceWebSocket?
    /// Cleared on teardown so a hop already queued cannot deliver after `.ended`.
    private var events: DeviceSocketSink?

    package init(sink: @escaping (SimulatorLogEvent) -> Void) {
        self.sink = sink
    }

    package func connect(host: String, port: UInt16, udid: String, level: SimulatorLogLevel) {
        disconnect()
        guard let url = SimulatorEndpoints.logs(
            host: host, port: port, udid: udid, level: level.rawValue,
        ) else {
            sink(.ended(reason: "no endpoint"))
            return
        }
        let events = DeviceSocketSink { [weak self] kind, payload in self?.deliver(kind, payload) }
        self.events = events
        lane = DeviceWebSocket(url: url.absoluteString, sink: events)
    }

    package func disconnect() {
        events?.silence()
        events = nil
        lane = nil
    }

    // MARK: Plumbing

    /// This lane's own message dispatch — the one thing the two simulator sockets do not share.
    private func deliver(_ kind: UInt32, _ payload: Data) {
        switch kind {
        case UInt32(SLOPDESK_DEVICE_WS_CONNECTED):
            sink(.connected)
        case UInt32(SLOPDESK_DEVICE_WS_TEXT):
            // swiftlint:disable:next optional_data_string_conversion
            switch SimulatorLogMessage.decode(String(decoding: payload, as: UTF8.self)) {
            case .started: sink(.started)
            case let .lines(lines): sink(.lines(lines))
            case .unknown: break
            }
        case UInt32(SLOPDESK_DEVICE_WS_BINARY):
            // The console's server sends text only; a binary message is a dialect this build has no
            // case for, and dropping it is the same answer the frame stream gives an unknown type.
            break
        default:
            // swiftlint:disable:next optional_data_string_conversion
            let reason = String(decoding: payload, as: UTF8.self)
            sink(.ended(reason: reason.isEmpty ? nil : reason))
            disconnect()
        }
    }
}
