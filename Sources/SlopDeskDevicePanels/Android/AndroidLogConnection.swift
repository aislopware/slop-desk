// AndroidLogConnection — the console's own socket.
//
// A SEPARATE connection from the mirror, for the reason `docs/47` gives for keeping the simulator's
// log socket apart from its stream: the console opens and closes while the stream stays up, and a
// subscription that died with a video reconnect would lose exactly the output covering the moment
// being investigated.
//
// Unlike the mirror, this direction is pure text and one-way. The bridge acks, then writes `logcat`'s
// stdout through verbatim until the client hangs up — so all this class does is split a byte stream
// into lines, which is the one part that has to be right: a chunk boundary lands mid-line constantly
// on a busy device, and a naive per-chunk split turns one line into two half-rows several times a
// second.
//
// That split is `slopdesk_devicepanel::android_bridge::LogLineSplitter`, reached through the handle
// below. It is a handle and not a function for `AndroidStreamParser`'s reason at a smaller size: the
// half-line left over from one receive is what the next one completes, so a caller holding that tail
// is a caller holding the rule.

import CSlopDeskFFI
import Foundation

package enum AndroidLogEvent {
    /// The host has `logcat` running. Worth its own case: it is the only signal separating "connected
    /// but the device is quiet" from "connected and nothing works".
    case started
    case lines([String])
    case ended(reason: String?)
}

@MainActor
package protocol AndroidLogStreaming: AnyObject {
    func connect(host: String, port: UInt16, serial: String, level: AndroidLogLevel)
    func disconnect()
}

/// The console's byte stream, split into lines by `slopdesk_android_log_lines_*`.
///
/// A CLASS, for ``AndroidStreamParser``'s reason: the splitter is one buffer per subscription with
/// a lifetime, which is what `deinit` is for. Copying it would either double-free the handle or
/// silently share it, and neither is a thing a `struct` can prevent. No two calls on it overlap —
/// the one receive loop that drives it is the only caller.
package final class AndroidLogLines {
    private let handle: OpaquePointer

    package init() {
        guard let handle = slopdesk_android_log_lines_new() else {
            preconditionFailure("the android log line splitter could not be built")
        }
        self.handle = handle
    }

    deinit { slopdesk_android_log_lines_free(handle) }

    /// Folds one freshly received chunk in and answers every line it completed.
    ///
    /// The whole chunk's lines come back in ONE array rather than one at a time, for the reason the
    /// simulator's server batches: a busy device prints thousands of lines a minute, and a view
    /// update per line is a view update per line.
    package func push(_ data: Data) -> [String] {
        let needed = devicePanelLend(data) { bytes, length in
            slopdesk_android_log_lines_push(handle, bytes, length)
        }
        guard needed > 0 else { return [] }
        var blob = DevicePanelBlob { out, cap in
            slopdesk_android_log_lines_answer(handle, out, cap)
        }
        let count = blob.count32()
        return blob.texts(count)
    }
}

@MainActor
package final class AndroidLogConnection: AndroidLogStreaming {
    private let sink: (AndroidLogEvent) -> Void
    private var socket: AndroidBridgeSocket?
    /// The tail of the last chunk lives inside this, not here.
    private var lines = AndroidLogLines()

    package init(sink: @escaping (AndroidLogEvent) -> Void) {
        self.sink = sink
    }

    package func connect(host: String, port: UInt16, serial: String, level: AndroidLogLevel) {
        disconnect()
        // A re-opened subscription is a new splitter: the previous one's half-line belongs to a
        // stream that has ended. Dropping the handle IS the reset, which is why the door has none.
        lines = AndroidLogLines()
        guard let request = AndroidBridgeRequest.logcat(serial: serial, level: level) else {
            // The panel's own sentence, and the crate's: `AndroidBridgeRefusal` names it
            // separately from the ordinary unbuildable request because this one is read where
            // nothing else is on screen — see that case's note.
            sink(.ended(reason: AndroidBridgeRefusal.unbuildableLogcat.message))
            return
        }
        let socket = AndroidBridgeSocket(
            request: request,
            onReply: { [weak self] reply in
                switch reply {
                case .ok: self?.sink(.started)
                case let .failed(message): self?.sink(.ended(reason: message))
                }
            },
            onBytes: { [weak self] data in self?.ingest(data) },
            onEnd: { [weak self] reason in self?.sink(.ended(reason: reason)) },
        )
        self.socket = socket
        socket.connect(host: host, port: port)
    }

    package func disconnect() {
        socket?.close()
        socket = nil
    }

    private func ingest(_ data: Data) {
        let rows = lines.push(data)
        if !rows.isEmpty { sink(.lines(rows)) }
    }
}
