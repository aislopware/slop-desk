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

@MainActor
package final class AndroidLogConnection: AndroidLogStreaming {
    private let sink: (AndroidLogEvent) -> Void
    private var socket: AndroidBridgeSocket?
    /// The tail of the last chunk, up to the point where a line was still incomplete.
    private var partial = Data()

    /// A single line's ceiling. A device can print a stack trace as one line, but a line that never
    /// ends is a stream that has gone wrong, and holding it costs memory the panel will never show.
    package static let lineLimit = 1 << 16

    package init(sink: @escaping (AndroidLogEvent) -> Void) {
        self.sink = sink
    }

    package func connect(host: String, port: UInt16, serial: String, level: AndroidLogLevel) {
        disconnect()
        partial = Data()
        let socket = AndroidBridgeSocket(
            request: ["op": "logcat", "serial": serial, "level": level.rawValue],
            onReply: { [weak self] reply in
                switch reply {
                case .ok: self?.sink(.started)
                case let .failed(message): self?.sink(.ended(reason: message))
                }
            },
            onBytes: { [weak self] data in self?.ingest(data) },
            onEnd: { [weak self] reason in self?.sink(.ended(reason: reason)) },
        )
        guard let socket else {
            sink(.ended(reason: "The logcat request could not be encoded."))
            return
        }
        self.socket = socket
        socket.connect(host: host, port: port)
    }

    package func disconnect() {
        socket?.close()
        socket = nil
    }

    /// Split on newlines, keeping the incomplete tail for the next chunk.
    ///
    /// The whole chunk's lines are delivered in ONE event rather than one event each, for the reason
    /// the simulator's server batches: a busy device prints thousands of lines a minute, and a view
    /// update per line is a view update per line.
    private func ingest(_ data: Data) {
        partial.append(data)
        guard partial.count <= Self.lineLimit || partial.contains(UInt8(ascii: "\n")) else {
            partial = Data()
            return
        }
        var lines: [String] = []
        while let newline = partial.firstIndex(of: UInt8(ascii: "\n")) {
            let line = Data(partial[partial.startIndex..<newline])
            partial = Data(partial[partial.index(after: newline)...])
            // Lossy rather than a `guard`: `logcat` passes through whatever bytes an app logged,
            // including invalid UTF-8, and a dropped line is a hole in a console nobody can explain.
            // The failable initializer the lint rule prefers returns nil on exactly those bytes, which
            // is the drop this contract forbids.
            // swiftlint:disable:next optional_data_string_conversion
            var text = String(decoding: line, as: UTF8.self)
            if text.hasSuffix("\r") { text.removeLast() }
            lines.append(text)
        }
        if !lines.isEmpty { sink(.lines(lines)) }
    }
}
