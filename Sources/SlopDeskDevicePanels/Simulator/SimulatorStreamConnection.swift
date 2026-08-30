// SimulatorStreamConnection — the one socket the simulator panel holds: H.264 down, gestures up.
//
// The socket itself is `slopdesk-devicelink`'s (`slopdesk_device_ws_*`). What is left here is the
// panel's own dialect: which downstream message is worth an event, and what a gesture looks like
// going up. ONE socket carries both directions because the server defines it that way — binary
// frames down, JSON text up — which is also why there is no separate input connection to keep in
// sync: a gesture cannot outlive the stream it belongs to, and both die together on disconnect.
//
// Three things this file used to hold and no longer does, each for the same reason — they were the
// SOCKET rather than the panel:
//
//   * the `NWConnection` state machine, shared with the console through a protocol extension;
//   * `TCP_NODELAY`, which the upstream gesture path depends on. `slopdesk_devicelink::session`
//     sets it on the dial and pins it with a test that reads the option back off a real socket;
//   * the explicit pong, and the measured paragraph about `autoReplyPing` storing a COPY of its
//     options object. That trap belonged to `Network.framework`; the crate answers every ping in
//     its read loop and carries the history in its own header.

import CSlopDeskFFI
import Foundation

/// What the panel learns from the socket. Delivered on the main actor — the consumer is a view
/// model, and hopping once at the boundary is cheaper than making every observer thread-safe.
package enum SimulatorStreamEvent {
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

/// The stream as its consumer sees it — three verbs, no transport types. The model holds one of
/// these rather than the concrete class so a test can drive the whole panel (select, frames,
/// teardown) without a socket.
@MainActor
package protocol SimulatorStreaming: AnyObject {
    func connect(host: String, port: UInt16, udid: String)
    func disconnect()
    func send(_ envelope: SimulatorInputEnvelope)
}

@MainActor
package final class SimulatorStreamConnection: SimulatorStreaming {
    private let sink: (SimulatorStreamEvent) -> Void
    private var lane: DeviceWebSocket?
    /// Cleared on teardown so a hop already queued cannot deliver an event after `.ended`.
    private var events: DeviceSocketSink?

    package init(sink: @escaping (SimulatorStreamEvent) -> Void) {
        self.sink = sink
    }

    /// Open the stream for `udid`. Calling this on a live connection tears the old one down first —
    /// selecting a second device must not leave the first one decoding into nothing.
    package func connect(host: String, port: UInt16, udid: String) {
        disconnect()
        guard let url = SimulatorEndpoints.stream(host: host, port: port, udid: udid) else {
            sink(.ended(reason: "no endpoint"))
            return
        }
        // A URL, not host+port: the handshake's request line comes from it, and `format`/`version`
        // ride the QUERY STRING. Dialling host+port would open a socket to the right machine and ask
        // it for the server's default dialect.
        let events = DeviceSocketSink { [weak self] kind, payload in self?.deliver(kind, payload) }
        self.events = events
        lane = DeviceWebSocket(url: url.absoluteString, sink: events)
    }

    package func disconnect() {
        events?.silence()
        events = nil
        lane = nil
    }

    /// Send one input envelope. Silently dropped when the socket is not up — a gesture fired during
    /// a reconnect is not worth queueing, and delivering it late would replay a tap the user has
    /// already moved on from.
    package func send(_ envelope: SimulatorInputEnvelope) {
        guard let json = envelope.json else { return }
        lane?.sendText(json)
    }

    // MARK: Plumbing

    /// This lane's own message dispatch — the one thing the two simulator sockets do not share.
    private func deliver(_ kind: UInt32, _ payload: Data) {
        switch kind {
        case UInt32(SLOPDESK_DEVICE_WS_CONNECTED):
            sink(.connected)
        case UInt32(SLOPDESK_DEVICE_WS_TEXT):
            // swiftlint:disable:next optional_data_string_conversion
            sink(.text(String(decoding: payload, as: UTF8.self)))
        case UInt32(SLOPDESK_DEVICE_WS_BINARY):
            // An unknown type byte is dropped here rather than forwarded: a message this build has
            // no case for is not an event the panel can act on.
            if let message = SimulatorWireProtocol.decode(payload), !message.isUnknown {
                sink(.message(message))
            }
        default:
            // swiftlint:disable:next optional_data_string_conversion
            let reason = String(decoding: payload, as: UTF8.self)
            sink(.ended(reason: reason.isEmpty ? nil : reason))
            disconnect()
        }
    }
}

package extension SimulatorStreamMessage {
    var isUnknown: Bool {
        if case .unknown = self { return true }
        return false
    }
}
