import Foundation
import SlopDeskProtocol

/// The inspector's own wire message set for NWConnection #2 (doc 00 ③ / doc 16 §3).
///
/// **Separate namespace from the terminal `WireMessage`** — the inspector channel is
/// independent of the PTY byte pipeline and must not pollute it. We deliberately reuse
/// the *framing style* (a `UInt32` big-endian length prefix + a 1-byte type tag) from
/// `SlopDeskProtocol` rather than the message type itself, so the two protocols share a
/// proven framing shape without coupling.
///
/// Unlike the terminal hot path (manual binary, no JSON), the inspector payload is
/// **JSON** (`InspectorEvent` is `Codable`): the event rate is low (per-turn /
/// per-tool, not per-keystroke) and the schema is rich + evolving, so JSON's
/// flexibility wins and its cost is irrelevant. Doc 16 explicitly calls for
/// "length-prefixed JSON frames".
public enum InspectorWireMessage: Sendable, Equatable {
    // host → client
    /// A structured inspector event (host → client). The whole read-only stream.
    case event(InspectorEvent)
    /// Heartbeat / liveness (host → client), so a quiet workflow run is not mistaken
    /// for a dead connection.
    case keepAlive

    // client → host (lightweight control ONLY — never agent-driving)
    /// Subscribe / replay-from control (doc 16 §3): the client asks the host to
    /// (re)send events. `fromSeq == 0` = full replay; a higher value = resume after a
    /// reconnect. This is read-only: it influences *what events the client receives*,
    /// never the agent.
    case subscribe(fromSeq: Int64)

    /// The 1-byte type tag (its own namespace; values overlap the terminal protocol's
    /// but are decoded by a different decoder, so there is no collision).
    var typeTag: UInt8 {
        switch self {
        case .event: 1
        case .keepAlive: 2
        case .subscribe: 3
        }
    }
}

/// Encodes/decodes ``InspectorWireMessage`` to/from the length-prefixed frame format.
///
/// Frame layout (mirrors `SlopDeskProtocol` framing style, separate namespace):
/// ```
/// [ UInt32 BE payloadLength ][ UInt8 typeTag ][ body... ]
/// ```
/// `payloadLength` counts `typeTag + body` (excludes the 4 prefix bytes), capped at
/// `SlopDesk.maxFramePayloadLength` (16 MiB) — reusing the terminal protocol's ceiling.
/// `.event` and `.subscribe` bodies are JSON; `.keepAlive` has an empty body.
public enum InspectorCodec {
    /// Errors distinct from `SlopDeskProtocol.SlopDeskError` (decode-time, inspector frames).
    public enum CodecError: Error, Equatable, Sendable {
        case frameTooLarge(Int)
        case truncated
        case unknownType(UInt8)
        case malformedBody(String)
    }

    static let prefixLength = 4

    // MARK: Encode

    public static func encode(_ message: InspectorWireMessage) throws -> Data {
        var body = Data()
        body.append(message.typeTag)
        switch message {
        case let .event(event):
            try body.append(JSONEncoder().encode(event))
        case .keepAlive:
            break
        case let .subscribe(fromSeq):
            body.appendBESeq(fromSeq)
        }

        guard body.count <= SlopDesk.maxFramePayloadLength else {
            throw CodecError.frameTooLarge(body.count)
        }

        var frame = Data()
        frame.appendBELength(UInt32(body.count))
        frame.append(body)
        return frame
    }

    // MARK: Decode (one whole payload, type tag included)

    public static func decode(payload: Data) throws -> InspectorWireMessage {
        guard let tag = payload.first else { throw CodecError.truncated }
        let body = payload.dropFirst()
        switch tag {
        case 1:
            do {
                let event = try JSONDecoder().decode(InspectorEvent.self, from: Data(body))
                return .event(event)
            } catch {
                throw CodecError.malformedBody("event JSON: \(error)")
            }
        case 2:
            return .keepAlive
        case 3:
            guard body.count == 8 else { throw CodecError.truncated }
            return .subscribe(fromSeq: Data(body).readBESeq())
        default:
            throw CodecError.unknownType(tag)
        }
    }
}

/// Streaming frame decoder for the inspector channel (the analogue of
/// `SlopDeskProtocol.FrameDecoder`, separate namespace). Reassembles whole frames from
/// arbitrary byte chunks: partial reads return `nil` (not an error); a full frame
/// decodes to one ``InspectorWireMessage``.
public struct InspectorFrameDecoder {
    /// Reclaim the consumed prefix once the read cursor has advanced past this many bytes, so the
    /// buffer's wasted head stays bounded during a long burst — the same idiom as
    /// `SlopDeskProtocol.FrameDecoder`/`MuxFrameDecoder`. 64 KiB == the max single `recv` chunk, so in
    /// the common case compaction happens at most once per received chunk.
    private static let compactionThreshold = 64 * 1024

    /// Received bytes. Completed frames are NOT removed per-parse (that front-removal memmoves the
    /// entire tail forward — O(n) per frame, O(n²) for a chunk of many small frames, exactly the shape
    /// an `InspectorReplayLog` full-history replay produces on reconnect). Instead a ``readOffset``
    /// cursor advances past consumed frames and the head is compacted LAZILY (on a drain that returns
    /// `nil`, or when the cursor crosses ``compactionThreshold``), amortizing total work to O(bytes).
    /// All indexing is relative to `buffer.startIndex + readOffset`.
    private var buffer = Data()

    /// Number of leading bytes in ``buffer`` already consumed by completed frames but not yet
    /// physically removed (reclaimed by ``compactConsumed()``).
    private var readOffset = 0

    public init() {}

    public mutating func append(_ data: Data) {
        buffer.append(data)
    }

    public mutating func nextMessage() throws -> InspectorWireMessage? {
        // Bytes not yet consumed by a completed frame.
        let available = buffer.count - readOffset
        // Need at least the length prefix to know how big the frame is.
        guard available >= InspectorCodec.prefixLength else { compactConsumed()
            return nil
        }

        let payloadLength = Int(readPrefix())
        guard payloadLength <= SlopDesk.maxFramePayloadLength else {
            throw InspectorCodec.CodecError.frameTooLarge(payloadLength)
        }

        // Wait until the whole payload has arrived (partial read — not an error).
        let frameLength = InspectorCodec.prefixLength + payloadLength
        guard available >= frameLength else { compactConsumed()
            return nil
        }

        // Slice out the payload (after the prefix) and ADVANCE the cursor past the frame (no per-frame
        // front-removal). `base` is the absolute index of this frame's first byte.
        let base = buffer.startIndex + readOffset
        let payloadStart = base + InspectorCodec.prefixLength
        let payload = Data(buffer[payloadStart..<base + frameLength])
        readOffset += frameLength
        // Bound the wasted head mid-burst; a drain that returns nil reclaims the rest.
        if readOffset >= Self.compactionThreshold { compactConsumed() }

        return try InspectorCodec.decode(payload: payload)
    }

    /// Physically drops the consumed prefix (`readOffset` bytes) from the front of the buffer ONCE,
    /// resetting the cursor — the single O(remaining) memmove that replaces the per-frame one.
    private mutating func compactConsumed() {
        guard readOffset > 0 else { return }
        buffer.removeSubrange(buffer.startIndex..<buffer.startIndex + readOffset)
        readOffset = 0
    }

    /// Reads the 4-byte big-endian length prefix at the cursor without consuming it. (The cursor
    /// advances in ``nextMessage()`` once the full frame is confirmed present, so an incomplete frame
    /// leaves the prefix in place for the next call.)
    private func readPrefix() -> UInt32 {
        let base = buffer.startIndex + readOffset
        var value: UInt32 = 0
        for i in 0..<InspectorCodec.prefixLength {
            value = (value << 8) | UInt32(buffer[base + i])
        }
        return value
    }
}

// MARK: - Local big-endian helpers (self-contained; the SlopDeskProtocol ones are internal)

private extension Data {
    mutating func appendBELength(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value >> 24))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }

    mutating func appendBESeq(_ value: Int64) {
        let bits = UInt64(bitPattern: value)
        for shift in stride(from: 56, through: 0, by: -8) {
            append(UInt8(truncatingIfNeeded: bits >> UInt64(shift)))
        }
    }

    /// Reads an 8-byte BE Int64 from the front of this (exactly-8-byte) slice.
    func readBESeq() -> Int64 {
        var bits: UInt64 = 0
        for i in 0..<8 { bits = (bits << 8) | UInt64(self[startIndex + i]) }
        return Int64(bitPattern: bits)
    }
}
