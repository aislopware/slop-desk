import CSlopDeskFFI
import Foundation

/// The inspector's own wire message set for NWConnection #2 (doc 00 ③ / doc 16 §3).
///
/// **Separate namespace from the terminal `WireMessage`** — the inspector channel is
/// independent of the PTY byte pipeline and must not pollute it. It deliberately reuses
/// the *framing style* (a `UInt32` big-endian length prefix + a 1-byte type tag) from
/// `SlopDeskProtocol` rather than the message type itself, so the two protocols share a
/// proven framing shape without coupling.
///
/// Unlike the terminal hot path (manual binary, no JSON), the inspector payload is
/// **JSON**: the event rate is low (per-turn / per-tool, not per-keystroke) and the
/// schema is rich + evolving, so JSON's flexibility wins and its cost is irrelevant.
/// Doc 16 explicitly calls for "length-prefixed JSON frames".
/// A frame the CLIENT receives (host → client). Tags `1` and `2`.
///
/// The client's one outbound frame — `subscribe`, tag `3` — has no case here: it is written by
/// ``InspectorCodec/encodeSubscribe(fromSeq:)`` and is never decoded on this side. That split is
/// the ONE-IMPLEMENTATION rule applied to a protocol's two ends (`CLAUDE.md`): `slopdesk-inspectord`
/// encodes what this end decodes and decodes what it encodes, each written once.
public enum InspectorWireMessage: Sendable, Equatable {
    /// One event's JSON body, UNREAD. The whole read-only stream.
    ///
    /// Carried as bytes rather than as a decoded tree because this side no longer has a tree to
    /// decode into: `slopdesk_inspectord::store` folds the body, and it is the only reader. Deciding
    /// WHICH frame arrived is framing and stays here; deciding what the body SAYS is one job, and
    /// `docs/66` gave it to the one end that does it.
    case event(Data)
    /// Heartbeat / liveness, so a quiet workflow run is not mistaken for a dead connection.
    case keepAlive
}

/// The Swift face of the inspector's frame format, whose every byte lives in
/// `rust/slopdesk-inspectord`'s `wire` module and is reached through `rust/slopdesk-ffi`.
///
/// Frame layout:
/// ```
/// [ UInt32 BE payloadLength ][ UInt8 typeTag ][ body... ]
/// ```
/// `payloadLength` counts `typeTag + body` (excludes the 4 prefix bytes), capped at 16 MiB — the
/// terminal protocol's ceiling, spelled once in the crate. The `.event` body is JSON, `.keepAlive`
/// has an empty body, and a `subscribe` body is one big-endian `Int64`.
///
/// **Nothing about the body stays here.** `decode_client` answers WHICH frame arrived and WHERE its
/// body sits; the body itself is handed on as bytes. This doc used to claim the event was a
/// two-ENDS document — one the daemon writes and this end reads — and that was wrong: both ends
/// deserialised the SAME document against two declarations of one taxonomy, which is one capability
/// written twice. `docs/66` deleted this side's declaration.
public enum InspectorCodec {
    /// Errors distinct from `SlopDeskProtocol.SlopDeskError` (decode-time, inspector frames).
    ///
    /// Three, not four: a `malformedBody` case was here while this side parsed the JSON, and left
    /// with the parse. A body that does not decode is now the STORE's answer — `apply` returns
    /// `false` — because the store is what would have been wrong about it.
    public enum CodecError: Error, Equatable, Sendable {
        case frameTooLarge(Int)
        case truncated
        case unknownType(UInt8)
    }

    /// The largest payload a frame may claim, READ from the crate rather than respelled here.
    ///
    /// Counts `typeTag + body` and excludes the 4 prefix bytes. Its readers are the two suites that
    /// drive a length prefix PAST the cap and assert the stream fails stop rather than buffering —
    /// which is the inspector's OWN ceiling, so it is asked of the inspector's own vending door.
    /// They used to reach for the terminal protocol's `SlopDesk.maxFramePayloadLength`: the two
    /// numbers happen to be equal, but a test that borrows another protocol's constant goes green
    /// for the wrong reason the day one of them moves. `docs/63` §G.4 deleted that namespace along
    /// with the Swift byte codec it belonged to.
    static let maxFramePayloadLength = Int(slopdesk_inspector_constant(0))

    // swiftlint:disable unused_declaration
    /// The frame's length-prefix width, READ from the crate rather than respelled here.
    ///
    /// No Swift caller ON PURPOSE: `slopdesk-invariants` pins this reading, so the face is what
    /// stops the next reader from writing the number down on this side.
    static let prefixLength = Int(slopdesk_inspector_constant(1))
    // swiftlint:enable unused_declaration

    // MARK: Encode (client → host: subscribe only)

    /// The `subscribe` / replay-from control (doc 16 §3): the client asks the daemon to (re)send
    /// events. `fromSeq == 0` = full replay; a higher value = resume after a reconnect. This is
    /// read-only — it influences *what events the client receives*, never the agent.
    ///
    /// Non-throwing: the frame is always 13 bytes, so the 16 MiB cap cannot be reached.
    public static func encodeSubscribe(fromSeq: Int64) -> Data {
        let needed = slopdesk_inspector_encode_subscribe(fromSeq, nil, 0)
        var out = Data(count: needed)
        out.withUnsafeMutableBytes { buffer in
            let written = slopdesk_inspector_encode_subscribe(
                fromSeq, buffer.baseAddress?.assumingMemoryBound(to: UInt8.self), needed,
            )
            precondition(written == needed, "the inspector codec sized a subscribe differently than it wrote it")
        }
        return out
    }

    // MARK: Decode (host → client: one whole payload, type tag included)

    public static func decode(payload: Data) throws -> InspectorWireMessage {
        var record = SlopDeskInspectorFrame()
        let verdict = payload.withUnsafeBytes { bytes in
            slopdesk_inspector_decode_payload(
                bytes.baseAddress?.assumingMemoryBound(to: UInt8.self), bytes.count, &record,
            )
        }
        guard verdict == SLOPDESK_INSPECTOR_OK else { throw error(verdict, record.detail) }
        return message(record, payload)
    }

    // MARK: Shared with the frame splitter

    /// The message a decoded record names, taking an event's JSON out of `buffer` in place.
    static func message(_ record: SlopDeskInspectorFrame, _ buffer: Data) -> InspectorWireMessage {
        guard record.tag == 1 else { return .keepAlive }
        let start = buffer.startIndex + Int(record.body_offset)
        // `Data.SubSequence` IS `Data`, so the body travels as a view onto the payload the caller
        // already holds — no copy to hand it over.
        return .event(buffer[start..<start + Int(record.body_length)])
    }

    /// The error a non-OK verdict names.
    static func error(_ verdict: UInt32, _ detail: UInt64) -> CodecError {
        switch verdict {
        case SLOPDESK_INSPECTOR_UNKNOWN_TYPE: .unknownType(UInt8(truncatingIfNeeded: detail))
        case SLOPDESK_INSPECTOR_FRAME_TOO_LARGE: .frameTooLarge(Int(detail))
        default: .truncated
        }
    }
}

/// Streaming frame decoder for the inspector channel — a handle onto the splitter in
/// `rust/slopdesk-inspectord`, which is the same one the daemon reads its own inbound frames with.
///
/// Partial reads return `nil` (not an error); a full frame decodes to one ``InspectorWireMessage``.
/// Consumed frames are not removed per parse — a front-removal memmoves the whole tail forward, O(n)
/// per frame and O(n²) for a chunk of many small ones, exactly the shape a full-history replay
/// produces on reconnect — so a cursor advances and the head is compacted lazily.
///
/// A reference type, intentionally NOT `Sendable`: it owns one Rust splitter driven by a single
/// per-connection receive loop.
public final class InspectorFrameDecoder {
    /// Where a frame's payload is read to, REUSED across calls and grown only when a frame does not
    /// fit. Sizing it from what the splitter has BUFFERED instead would allocate and zero the whole
    /// backlog once per frame, which on the shape that matters — a reconnect replaying the daemon's
    /// history as one chunk packed with small frames — is the backlog re-zeroed once per frame in
    /// it. It starts empty so a connection that never receives anything allocates nothing; the
    /// first frame grows it to at least ``bodyFloor``, which holds every event this channel carries.
    private var body: [UInt8] = []

    /// What the first growth rounds up to, so a stream of ordinary events grows the buffer once.
    private static let bodyFloor = 4096

    private let handle: OpaquePointer

    public init() {
        guard let handle = slopdesk_inspector_decoder_new() else {
            preconditionFailure("the inspector splitter could not be built")
        }
        self.handle = handle
    }

    deinit { slopdesk_inspector_decoder_free(handle) }

    public func append(_ data: Data) {
        guard !data.isEmpty else { return }
        data.withUnsafeBytes { bytes in
            slopdesk_inspector_decoder_append(
                handle, bytes.baseAddress?.assumingMemoryBound(to: UInt8.self), bytes.count,
            )
        }
    }

    /// The next complete message, or `nil` when a whole frame is not yet buffered.
    public func nextMessage() throws -> InspectorWireMessage? {
        while true {
            var record = SlopDeskInspectorFrame()
            let verdict = body.withUnsafeMutableBufferPointer { buffer in
                slopdesk_inspector_decoder_next(handle, &record, buffer.baseAddress, buffer.count)
            }
            switch verdict {
            case SLOPDESK_INSPECTOR_PENDING:
                return nil
            case SLOPDESK_INSPECTOR_AGAIN:
                // Nothing was consumed: the frame is still there, so grow once and ask again.
                body = [UInt8](repeating: 0, count: Swift.max(Int(record.detail), Self.bodyFloor))
            case SLOPDESK_INSPECTOR_OK:
                guard record.tag == 1 else { return .keepAlive }
                let run = Int(record.body_offset)..<Int(record.body_offset + record.body_length)
                // Copied out on purpose: `body` is REUSED by the next call, so the body a caller
                // holds cannot be a view onto it.
                return .event(body.withUnsafeBytes { Data(UnsafeRawBufferPointer(rebasing: $0[run])) })
            default:
                throw InspectorCodec.error(verdict, record.detail)
            }
        }
    }
}
