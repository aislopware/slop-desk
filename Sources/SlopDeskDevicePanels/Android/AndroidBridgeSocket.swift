// AndroidBridgeSocket — one connection to the host's Android bridge, in the shape all four of its
// operations share.
//
// Every bridge connection is the same two phases: write ONE JSON request line, read ONE JSON reply
// line, and then — depending on the operation — either stop, or keep the socket and treat everything
// after that newline as a byte stream. That split is `slopdesk_devicelink::bridge`'s now, and so is
// the subtle part of it: the reply line and the first bytes of the stream arrive in the SAME
// receive, so a read-until-newline that discards its remainder loses the head of the stream — for
// `open`, the codec id and the parameter sets, which is the difference between a picture and a
// permanently black rectangle. The crate's `split` is that rule and its tests are where the
// framing is pinned.
//
// `TCP_NODELAY` went with it. It is the parameter that matters on this path — upstream traffic is a
// 32-byte touch message every few milliseconds during a drag — and `slopdesk_devicelink::session`
// sets it on the dial and reads it back off a real socket in a test.
//
// The two LINES are `slopdesk_devicepanel::android_bridge`'s: ``AndroidBridgeRequest`` writes the
// request and ``AndroidBridgeReply/decode(_:)`` reads the ack. The grammar behind both is
// `slopdesk_androidd::protocol`, which is the daemon's decoder for the same object.

import CSlopDeskFFI
import Foundation
import SlopDeskWorkspaceModel

/// The request lines the bridge accepts, written by `slopdesk_android_bridge_request`.
///
/// `nil` is a request that CANNOT be built, which is one thing rather than two: a required field
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

    private var call: DeviceBridgeCall?
    /// Cleared on teardown so a hop already queued cannot deliver after the end.
    private var events: DeviceSocketSink?
    private var hasReplied = false

    /// The request line, held until ``connect(host:port:)``. ``AndroidBridgeRequest`` built it, and
    /// it is the only thing that can refuse to build one, so this initializer cannot fail.
    private let request: Data

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
        let events = DeviceSocketSink { [weak self] kind, payload in self?.deliver(kind, payload) }
        self.events = events
        call = DeviceBridgeCall(host: host, port: port, request: request, sink: events)
    }

    /// Send bytes upstream. Dropped before the socket is up — a gesture fired during a connect is
    /// not worth queueing, and delivering it late replays a tap the user has moved on from.
    package func send(_ data: Data) {
        call?.send(data)
    }

    package func close() {
        events?.silence()
        events = nil
        call = nil
        onReply = nil
        onEnd = nil
    }

    // MARK: Plumbing

    private func deliver(_ kind: UInt32, _ payload: Data) {
        switch kind {
        case UInt32(SLOPDESK_DEVICE_BRIDGE_REPLY):
            guard !hasReplied else { return }
            hasReplied = true
            let reply = onReply
            onReply = nil
            reply?(AndroidBridgeReply.decode(payload))
        case UInt32(SLOPDESK_DEVICE_BRIDGE_BYTES):
            onBytes?(payload)
        default:
            let end = onEnd
            onEnd = nil
            onReply = nil
            let reason = String(decoding: payload, as: UTF8.self)
            end?(reason.isEmpty ? nil : reason)
        }
    }
}
