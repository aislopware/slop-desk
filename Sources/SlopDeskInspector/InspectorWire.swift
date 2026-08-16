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
/// **JSON** (`InspectorEvent` is `Codable`): the event rate is low (per-turn /
/// per-tool, not per-keystroke) and the schema is rich + evolving, so JSON's
/// flexibility wins and its cost is irrelevant. Doc 16 explicitly calls for
/// "length-prefixed JSON frames".
/// A frame the CLIENT receives (host → client). Tags `1` and `2`.
///
/// The client's one outbound frame — `subscribe`, tag `3` — has no case here: it is written by
/// ``InspectorCodec/encodeSubscribe(fromSeq:)`` and is never decoded on this side. That split is
/// the ONE-IMPLEMENTATION rule applied to a protocol's two ends (`CLAUDE.md`): `slopdesk-inspectord`
/// encodes what this end decodes and decodes what it encodes, each written once.
public enum InspectorWireMessage: Sendable, Equatable {
    /// A structured inspector event. The whole read-only stream.
    case event(InspectorEvent)
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
/// **What stays here is the JSON, and only the JSON.** `decode_client` answers WHICH frame arrived
/// and WHERE its body sits, never what the body says; `InspectorEvent` is a document the daemon
/// writes and this end reads, which is the two-ENDS shape rather than one capability written twice.
public enum InspectorCodec {
    /// Errors distinct from `SlopDeskProtocol.SlopDeskError` (decode-time, inspector frames).
    public enum CodecError: Error, Equatable, Sendable {
        case frameTooLarge(Int)
        case truncated
        case unknownType(UInt8)
        case malformedBody(String)
    }

    static let prefixLength = Int(slopdesk_inspector_constant(1))

    /// The tag of the client's only outbound frame.
    static let subscribeTag = UInt8(truncatingIfNeeded: slopdesk_inspector_constant(2))

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
        return try message(record, payload)
    }

    // MARK: Shared with the frame splitter

    /// The message a decoded record names, reading an event's JSON out of `buffer` in place.
    static func message(_ record: SlopDeskInspectorFrame, _ buffer: Data) throws -> InspectorWireMessage {
        guard record.tag == 1 else { return .keepAlive }
        let start = buffer.startIndex + Int(record.body_offset)
        // `Data.SubSequence` IS `Data`, so the body reaches the parser as a view onto the payload
        // the caller already holds — no copy to hand it over.
        return try event(buffer[start..<start + Int(record.body_length)])
    }

    /// The event `json` describes, or the malformed-body error naming why it is not one.
    static func event(_ json: Data) throws -> InspectorWireMessage {
        do {
            return try .event(JSONDecoder().decode(InspectorEvent.self, from: json))
        } catch {
            throw CodecError.malformedBody("event JSON: \(error)")
        }
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
                let json = body.withUnsafeBytes { Data(UnsafeRawBufferPointer(rebasing: $0[run])) }
                return try InspectorCodec.event(json)
            default:
                throw InspectorCodec.error(verdict, record.detail)
            }
        }
    }
}
