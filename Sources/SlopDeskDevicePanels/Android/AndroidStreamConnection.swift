// AndroidStreamConnection — the one socket a mirrored device holds: video down, input up.
//
// ONE connection carries both directions because `scrcpy` defines it that way and the host relays it
// verbatim: the server's video socket writes frames, its control socket reads messages, and the
// bridge pumps each into the corresponding direction of this TCP connection. That is also why there
// is no separate input connection to keep in sync — a gesture cannot outlive the stream it belongs
// to, and both die together on disconnect.
//
// The full-duplex arrangement is only sound while the control direction is strictly one-way, which is
// what `clipboard_autosync=false` buys host-side. ``AndroidControlMessage`` documents which messages
// are therefore unsendable; sending one would make the device write a clipboard reply into a byte
// stream this class is parsing as H.264.
//
// Hang-safety: this constructs a real network object. Everything it decides is delegated to pure code
// (``AndroidStreamParser``, ``AndroidAnnexB``); this file is the plumbing between them.

import Foundation

/// What the panel learns from the stream. Delivered on the main actor — the consumer is a view
/// model, and hopping once here is cheaper than making every observer thread-safe.
package enum AndroidStreamEvent {
    /// The host acked the mirror. No frames yet; the encoder starts after this.
    case opened
    /// The device named its stream geometry. Arrives before the first frame and AGAIN whenever the
    /// screen rotates or the app resizes it — `scrcpy` restarts its encoder rather than signalling a
    /// rotation, so this is the only notice a turn gives.
    case size(width: Int, height: Int)
    /// Parameter sets, ready for a format description.
    case parameterSets([Data], codec: AndroidVideoCodec)
    /// One access unit, already rewritten from Annex-B into the length-prefixed form CoreMedia wants.
    case accessUnit(Data, isKeyframe: Bool)
    /// The stream ended. `reason` is nil for a clean close.
    case ended(reason: String?)
}

/// The stream as its consumer sees it — three verbs, no network types. The model holds one of these
/// rather than the concrete class so a test can drive the panel without a socket.
@MainActor
package protocol AndroidStreaming: AnyObject {
    func connect(host: String, port: UInt16, serial: String, maxSize: Int)
    func disconnect()
    func send(_ message: Data)
}

@MainActor
package final class AndroidStreamConnection: AndroidStreaming {
    private let sink: (AndroidStreamEvent) -> Void
    private var socket: AndroidBridgeSocket?
    private var parser = AndroidStreamParser()
    /// The codec, learned from the stream's first four bytes. Held because the parameter sets that
    /// follow have to be split by NAL type, and the types differ between H.264 and HEVC.
    private var codec: AndroidVideoCodec = .h264

    package init(sink: @escaping (AndroidStreamEvent) -> Void) {
        self.sink = sink
    }

    /// Open a mirror for `serial`. Calling this on a live stream tears the old one down first —
    /// selecting a second device must not leave the first one encoding into nothing, and on a phone
    /// that encoder is a real power draw.
    package func connect(host: String, port: UInt16, serial: String, maxSize: Int) {
        disconnect()
        parser = AndroidStreamParser()
        codec = .h264
        guard let request = AndroidBridgeRequest.open(serial: serial, maxSize: maxSize) else {
            sink(.ended(reason: "The mirror request could not be encoded."))
            return
        }
        let socket = AndroidBridgeSocket(
            request: request,
            onReply: { [weak self] reply in
                switch reply {
                case .ok: self?.sink(.opened)
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

    package func send(_ message: Data) {
        socket?.send(message)
    }

    // MARK: Decoding

    private func ingest(_ data: Data) {
        for message in parser.consume(data) {
            switch message {
            case let .codec(name):
                // An identifier the door refuses ENDS the stream. It used to fall back to H.264,
                // which contradicted the only reason ``AndroidVideoCodec`` exists: the enum omits
                // AV1 precisely so the panel never configures a decode session for a stream this
                // Mac cannot decode, and defaulting produced exactly the black rectangle that
                // omission is there to prevent — an H.264 NAL-type reading applied to AV1
                // parameter sets, handed to `VTDecompressionSession` as a mis-typed format
                // description. Nothing logs, nothing fails, and the panel shows nothing.
                //
                // `slopdesk_android_stream_decodable_codec` already answers "this cannot be
                // displayed", so the near side's job is to say so rather than to overrule it. The
                // teardown is the one below's, for the one below's reason: an identifier this build
                // cannot serve does not become serviceable by reading more of the stream.
                guard let decodable = AndroidVideoCodec(streamIdentifier: name) else {
                    disconnect()
                    sink(.ended(reason: "The device is streaming a video codec this Mac cannot decode."))
                    return
                }
                codec = decodable
            case let .session(width, height):
                sink(.size(width: width, height: height))
            case let .configuration(payload):
                let sets = AndroidAnnexB.parameterSets(inConfiguration: payload, codec: codec)
                if !sets.isEmpty { sink(.parameterSets(sets, codec: codec)) }
            case let .accessUnit(payload, isKeyframe):
                guard let rewritten = AndroidAnnexB.avccAccessUnit(from: payload) else { continue }
                sink(.accessUnit(rewritten, isKeyframe: isKeyframe))
            }
        }
        // A parser that has lost sync cannot recover on its own — the frame lengths it reads from
        // then on are arbitrary. Tearing the socket down turns that into a reconnect, which is the
        // only thing that fixes it.
        if parser.isCorrupt {
            disconnect()
            sink(.ended(reason: "The video stream lost sync."))
        }
    }
}
