import Foundation
import AislopdeskProtocol

/// The inspector's own wire message set for NWConnection #2 (doc 00 ③ / doc 16 §3).
///
/// **Separate namespace from the terminal `WireMessage`** — the inspector channel is
/// independent of the PTY byte pipeline and must not pollute it. We deliberately reuse
/// the *framing style* (a `UInt32` big-endian length prefix + a 1-byte type tag) from
/// `AislopdeskProtocol` rather than the message type itself, so the two protocols share a
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
        case .event: return 1
        case .keepAlive: return 2
        case .subscribe: return 3
        }
    }
}

/// Encodes/decodes ``InspectorWireMessage`` to/from the length-prefixed frame format.
///
/// Frame layout (mirrors `AislopdeskProtocol` framing style, separate namespace):
/// ```
/// [ UInt32 BE payloadLength ][ UInt8 typeTag ][ body... ]
/// ```
/// `payloadLength` counts `typeTag + body` (excludes the 4 prefix bytes), capped at
/// `Aislopdesk.maxFramePayloadLength` (16 MiB) — reusing the terminal protocol's ceiling.
/// `.event` and `.subscribe` bodies are JSON; `.keepAlive` has an empty body.
public enum InspectorCodec {
    /// Errors distinct from `AislopdeskProtocol.AislopdeskError` (decode-time, inspector frames).
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
            body.append(try JSONEncoder().encode(event))
        case .keepAlive:
            break
        case let .subscribe(fromSeq):
            body.appendBESeq(fromSeq)
        }

        guard body.count <= Aislopdesk.maxFramePayloadLength else {
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
/// `AislopdeskProtocol.FrameDecoder`, separate namespace). Reassembles whole frames from
/// arbitrary byte chunks: partial reads return `nil` (not an error); a full frame
/// decodes to one ``InspectorWireMessage``.
public struct InspectorFrameDecoder {
    private var buffer = Data()

    public init() {}

    public mutating func append(_ data: Data) {
        buffer.append(data)
    }

    public mutating func nextMessage() throws -> InspectorWireMessage? {
        guard buffer.count >= InspectorCodec.prefixLength else { return nil }
        let payloadLength = Int(buffer.readBELength())
        guard payloadLength <= Aislopdesk.maxFramePayloadLength else {
            throw InspectorCodec.CodecError.frameTooLarge(payloadLength)
        }
        let frameLength = InspectorCodec.prefixLength + payloadLength
        guard buffer.count >= frameLength else { return nil }

        let start = buffer.startIndex
        let payloadStart = start + InspectorCodec.prefixLength
        let payload = Data(buffer[payloadStart ..< start + frameLength])
        buffer.removeSubrange(start ..< start + frameLength)
        return try InspectorCodec.decode(payload: payload)
    }
}

// MARK: - Local big-endian helpers (self-contained; the AislopdeskProtocol ones are internal)

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

    /// Reads the 4-byte BE length prefix at the front WITHOUT consuming it.
    func readBELength() -> UInt32 {
        var value: UInt32 = 0
        for i in 0 ..< 4 { value = (value << 8) | UInt32(self[startIndex + i]) }
        return value
    }

    /// Reads an 8-byte BE Int64 from the front of this (exactly-8-byte) slice.
    func readBESeq() -> Int64 {
        var bits: UInt64 = 0
        for i in 0 ..< 8 { bits = (bits << 8) | UInt64(self[startIndex + i]) }
        return Int64(bitPattern: bits)
    }
}
