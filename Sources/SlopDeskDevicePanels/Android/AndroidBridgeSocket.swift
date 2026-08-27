// AndroidBridgeSocket — one connection to the host's Android bridge, in the shape all four of its
// operations share.
//
// Every bridge connection is the same two phases: write ONE JSON request line, read ONE JSON reply
// line, and then — depending on the operation — either stop, or keep the socket and treat everything
// after that newline as a byte stream. That split lives here so `list`, `boot`, `logcat` and `open`
// do not each re-implement the framing, and so the one subtle part of it exists exactly once.
//
// The two LINES are `slopdesk_devicepanel::android_bridge`'s: ``AndroidBridgeRequest`` writes the
// request and ``AndroidBridgeReply/decode(_:)`` reads the ack. The grammar behind both is
// `slopdesk_androidd::protocol`, which is the daemon's decoder for the same object — it was a Rust
// decoder facing a Swift encoder, with the op names, the field names and the `{"ok":…}` envelope
// spelled once on each side and nothing that could fail if one of them gained a field.
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

import CSlopDeskFFI
import Foundation
import Network
import SlopDeskTransport
import SlopDeskWorkspaceModel

/// The request lines the bridge accepts, written by `slopdesk_android_bridge_request`.
///
/// `nil` is a request that CANNOT be built, which is now one thing rather than two: a required field
/// that is empty. `adb -s "" shell` is a different command from the one that was meant, so the
/// daemon treats an empty field as absent, and a request it would refuse is one this side should
/// not have sent. The old failure — a `[String: Any]` the JSON encoder could not take — is gone with
/// the dictionary: `JSONSerialization.data(withJSONObject:)` raises an Objective-C exception rather
/// than throwing, so `try?` never caught it and a typo in a request literal took the app down.
package enum AndroidBridgeRequest {
    /// Every device the host can see, running or merely defined.
    package static var list: Data? { line(op: SLOPDESK_ANDROID_BRIDGE_OP_LIST) }

    /// Start an AVD by name. The one request that names no serial — there is not one yet.
    package static func boot(avd: String) -> Data? {
        line(op: SLOPDESK_ANDROID_BRIDGE_OP_BOOT, argument: avd)
    }

    /// Stop a running device.
    package static func shutdown(serial: String) -> Data? {
        line(op: SLOPDESK_ANDROID_BRIDGE_OP_SHUTDOWN, serial: serial)
    }

    /// One emulator-console command, answered in the reply's `output`.
    package static func console(_ command: String, serial: String) -> Data? {
        line(op: SLOPDESK_ANDROID_BRIDGE_OP_CONSOLE, serial: serial, argument: command)
    }

    /// One PNG capture: the reply names a byte count and the bytes follow it.
    package static func screenshot(serial: String) -> Data? {
        line(op: SLOPDESK_ANDROID_BRIDGE_OP_SCREENSHOT, serial: serial)
    }

    /// `logcat` at a priority, streamed until the client hangs up.
    package static func logcat(serial: String, level: AndroidLogLevel) -> Data? {
        line(op: SLOPDESK_ANDROID_BRIDGE_OP_LOGCAT, serial: serial, argument: level.rawValue)
    }

    /// The scrcpy mirror: video down, control up, verbatim after the ack.
    package static func open(serial: String, maxSize: Int) -> Data? {
        line(op: SLOPDESK_ANDROID_BRIDGE_OP_OPEN, serial: serial, maxSize: maxSize)
    }

    /// One crossing per request, with docs/55 §4's retry. The line arrives with its own terminating
    /// newline: the framing is the door's, so nothing here appends one.
    private static func line(
        op: some BinaryInteger, serial: String = "", argument: String = "", maxSize: Int = 0,
    ) -> Data? {
        let bytes = devicePanelLend(serial) { serialBytes, serialLength in
            devicePanelLend(argument) { argumentBytes, argumentLength in
                wsAnswerBytes { out, cap in
                    slopdesk_android_bridge_request(
                        UInt8(truncatingIfNeeded: op),
                        serialBytes, serialLength,
                        argumentBytes, argumentLength,
                        Int64(maxSize),
                        out, cap,
                    )
                }
            }
        }
        return bytes.isEmpty ? nil : Data(bytes)
    }
}

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

    /// One reply line, as `slopdesk_android_bridge_reply_failure` reads it.
    ///
    /// The door answers `0` for an ack and a SENTENCE for everything else, which is why there is no
    /// verdict byte to pair with it: a refusal that named no reason — or named an empty one — comes
    /// back as the panel's own "The host refused." rather than as a blank dialog, so no failure this
    /// can answer is the empty string.
    package static func decode(_ line: Data) -> Self {
        let failure = devicePanelLend(line) { bytes, length in
            wsAnswerBytes { out, cap in
                slopdesk_android_bridge_reply_failure(bytes, length, out, cap)
            }
        }
        // swiftlint:disable:next optional_data_string_conversion
        return failure.isEmpty ? .ok(line) : .failed(String(decoding: failure, as: UTF8.self))
    }
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

    /// `request` is a whole line, newline included — ``AndroidBridgeRequest`` built it, and it is
    /// the only thing that can refuse to build one. This initializer therefore cannot fail: there
    /// is nothing left in it that could.
    package init(
        request: Data,
        onReply: @escaping (AndroidBridgeReply) -> Void,
        onBytes: ((Data) -> Void)? = nil,
        onEnd: ((String?) -> Void)? = nil,
    ) {
        self.request = request
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
        reply?(AndroidBridgeReply.decode(line))
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
