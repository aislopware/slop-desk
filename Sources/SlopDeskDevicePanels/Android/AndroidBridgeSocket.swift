// AndroidBridgeSocket — one connection to the host's Android bridge, in the shape all four of its
// operations share.
//
// Every bridge connection is the same two phases: write ONE JSON request line, read ONE JSON reply
// line, and then — depending on the operation — either stop, or keep the socket and treat everything
// after that newline as a byte stream. That split lives here so `list`, `boot`, `logcat` and `open`
// do not each re-implement the framing, and so the one subtle part of it exists exactly once.
//
// The subtle part: the reply line and the first bytes of the stream arrive in the SAME receive.
// `logcat` starts printing and the encoder starts emitting the moment the host acks, so a
// read-until-newline that discards its remainder loses the head of the stream — for `open`, that is
// the codec id and the parameter sets, which is the difference between a picture and a permanently
// black rectangle. ``consume(_:)`` therefore splits at the newline and forwards the tail.
//
// `NWConnection` over ``TransportParameters/makeTCP()`` rather than a raw socket, for the reason
// every other socket in this project is: that is the single place TCP parameters are decided, and
// `TCP_NODELAY` is the one that matters. Upstream traffic here is the definition of what Nagle
// ruins — a 32-byte touch message every few milliseconds during a drag.
//
// Hang-safety: this constructs a real network object, so nothing here may be built in a unit test.
// The framing it performs is delegated to ``consume(_:)``, which is pure and directly testable.

#if os(macOS)
import Foundation
import Network
import SlopDeskTransport

/// A bridge connection's reply, as its caller sees it.
///
/// The success case carries the reply line's RAW bytes rather than a decoded dictionary, for two
/// reasons that happen to agree: `[String: Any]` is not `Sendable` and cannot cross the hop a
/// continuation makes, and handing the bytes on means the one decoder that knows the wire shape
/// (``AndroidDevice/decodeList(_:)``) reads them directly instead of a second copy of its field rules
/// picking through a dictionary.
package enum AndroidBridgeReply: Equatable {
    /// The host acked, and this is the whole reply object as it arrived.
    case ok(Data)
    /// The host refused, with its own sentence. Surfaced rather than swallowed: a missing `adb`, an
    /// AVD that will not boot, a device that vanished mid-request all say so here and nowhere else.
    case failed(String)
}

@MainActor
package final class AndroidBridgeSocket {
    /// Where the ack goes. Called at most once.
    private var onReply: ((AndroidBridgeReply) -> Void)?
    /// Where post-ack bytes go. `nil` for the one-shot operations.
    private let onBytes: ((Data) -> Void)?
    /// Called once when the socket ends, cleanly (`nil`) or not.
    private var onEnd: ((String?) -> Void)?

    private var connection: NWConnection?
    /// Bytes seen before the reply line was complete. Bounded — a peer that never sends a newline is
    /// a bounded mistake rather than an unbounded allocation.
    private var pending = Data()
    private var hasReplied = false
    /// Set on teardown so a receive completion already in flight cannot resurrect a cancelled
    /// connection or deliver an event after the end.
    private var isTornDown = false

    /// The request line, held until the connection is ready. `NWConnection.send` before `.ready`
    /// queues, but holding it keeps the failure path from writing into a socket that never opened.
    private let request: Data

    package static let replyLimit = 1 << 20

    /// One shared queue. Each connection carries one device's traffic and its receive handler does
    /// nothing but hop to the main actor.
    private static let queue = DispatchQueue(label: "slopdesk.android.bridge")

    package init?(
        request: [String: Any],
        onReply: @escaping (AndroidBridgeReply) -> Void,
        onBytes: ((Data) -> Void)? = nil,
        onEnd: ((String?) -> Void)? = nil,
    ) {
        // `isValidJSONObject` FIRST, and not as belt-and-braces: `data(withJSONObject:)` raises an
        // Objective-C exception on a value it cannot encode rather than throwing a Swift error, so
        // `try?` does not catch it and the failable initializer's nil path would be unreachable — a
        // typo in a request dictionary would take the app down instead of failing the call.
        guard JSONSerialization.isValidJSONObject(request),
              var encoded = try? JSONSerialization.data(withJSONObject: request)
        else { return nil }
        encoded.append(UInt8(ascii: "\n"))
        self.request = encoded
        self.onReply = onReply
        self.onBytes = onBytes
        self.onEnd = onEnd
    }

    package func connect(host: String, port: UInt16) {
        guard let port = NWEndpoint.Port(rawValue: port) else {
            finish(reason: "no endpoint")
            return
        }
        let connection = NWConnection(
            host: NWEndpoint.Host(host), port: port, using: TransportParameters.makeTCP(),
        )
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in self?.handle(state) }
        }
        connection.start(queue: Self.queue)
    }

    /// Send bytes upstream. Silently dropped before the socket is up — a gesture fired during a
    /// connect is not worth queueing, and delivering it late replays a tap the user has moved on
    /// from.
    package func send(_ data: Data) {
        guard let connection, connection.state == .ready, !data.isEmpty else { return }
        connection.send(content: data, completion: .idempotent)
    }

    package func close() {
        isTornDown = true
        connection?.cancel()
        connection = nil
        onReply = nil
        onEnd = nil
    }

    // MARK: Plumbing

    private func handle(_ state: NWConnection.State) {
        guard !isTornDown else { return }
        switch state {
        case .ready:
            connection?.send(content: request, completion: .idempotent)
            receive()
        case let .failed(error):
            finish(reason: error.localizedDescription)
        case .cancelled:
            finish(reason: nil)
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
        // A wide window: video access units run to tens of kilobytes and a per-frame receive of 4 KiB
        // would multiply the hops without changing what arrives.
        connection
            .receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
                Task { @MainActor in
                    guard let self, !self.isTornDown else { return }
                    if let data, !data.isEmpty { self.consume(data) }
                    if let error {
                        self.finish(reason: error.localizedDescription)
                        return
                    }
                    if isComplete {
                        self.finish(reason: nil)
                        return
                    }
                    self.receive()
                }
            }
    }

    /// Split the ack line off the front of the stream and forward the rest.
    ///
    /// Written as its own method, and not folded into the receive handler, because this is the part
    /// worth pinning: everything after the newline in the SAME chunk belongs to the stream.
    package func consume(_ data: Data) {
        guard !hasReplied else {
            onBytes?(data)
            return
        }
        pending.append(data)
        guard let newline = pending.firstIndex(of: UInt8(ascii: "\n")) else {
            if pending.count > Self.replyLimit { finish(reason: "The host's reply made no sense.") }
            return
        }
        let line = pending[pending.startIndex..<newline]
        // Re-base: a `Data` slice keeps its parent's indices, and a consumer that reads it from 0
        // would trap. The same rule ``AndroidStreamParser`` follows.
        let tail = Data(pending[pending.index(after: newline)...])
        pending = Data()
        hasReplied = true
        deliverReply(Data(line))
        if !tail.isEmpty { onBytes?(tail) }
    }

    private func deliverReply(_ line: Data) {
        let reply = onReply
        onReply = nil
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            reply?(.failed("The host's reply made no sense."))
            return
        }
        guard object["ok"] as? Bool == true else {
            reply?(.failed(object["error"] as? String ?? "The host refused."))
            return
        }
        reply?(.ok(line))
    }

    /// One exit, whatever the cause. A socket that dies BEFORE the ack reports the failure through
    /// the reply channel as well — otherwise a caller awaiting a reply waits forever for a
    /// connection that is already gone.
    private func finish(reason: String?) {
        guard !isTornDown else { return }
        isTornDown = true
        let reply = onReply
        let end = onEnd
        onReply = nil
        onEnd = nil
        connection?.cancel()
        connection = nil
        reply?(.failed(reason ?? "The host closed the connection."))
        end?(reason)
    }
}
#endif
