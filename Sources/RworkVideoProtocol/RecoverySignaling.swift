import Foundation

/// Client→host loss-recovery / acknowledgement messages (doc 17 §3.6).
///
/// Recovery prefers an **LTR refresh** over a forced IDR to avoid the bandwidth /
/// latency spike of a keyframe: the client sends an RFI (reference-frame-invalidate)
/// range naming the frames it failed to receive; the host marks the referenced
/// long-term-reference frame invalid and encodes the next frame against an older,
/// still-valid LTR (`kVTCompressionPropertyKey_EnableLTR` + `ForceLTRRefresh`). If
/// the client gets no usable frame within ~2 RTT it escalates to a forced-IDR
/// request. The invalidation direction is **client→host** (doc 17 §3.6 correction).
///
/// This type models the messages only; the LTR encode wiring lives in
/// `RworkVideoHost.VideoEncoder`.
public enum RecoveryMessage: Equatable, Sendable {
    /// Acknowledge the highest contiguous `streamSeq` durably received. Lets the
    /// host bound its retransmit / LTR-pin window.
    case ack(streamSeq: UInt32)

    /// Request-for-invalidate: the client lost the frames in `[fromFrameID,
    /// toFrameID]` (inclusive) and asks the host to refresh from an earlier LTR
    /// rather than send a full IDR.
    case requestLTRRefresh(fromFrameID: UInt32, toFrameID: UInt32)

    /// Escalation after the ~2-RTT LTR-refresh timeout elapsed without a decodable
    /// frame: demand a forced IDR keyframe.
    case requestIDR

    /// Re-request a cursor SHAPE bitmap the client is missing (doc 17 §3.3 self-heal). A
    /// cursor shape is shipped over the cursor socket ONCE per `shapeID`; a lost (or
    /// over-MTU, IP-fragment-lost) shape datagram would otherwise leave the overlay
    /// permanently wrong/invisible for the whole session (the host strips the real cursor).
    /// When a cursor POSITION update references a `shapeID` not in the client cache, the
    /// client sends this on the EXISTING recovery channel (mirroring ``requestIDR``) and the
    /// host re-emits that shape's bitmap. The cache re-insert is idempotent.
    case requestCursorShape(shapeID: UInt16)

    /// On-wire message-type byte.
    public var messageType: UInt8 {
        switch self {
        case .ack: return 1
        case .requestLTRRefresh: return 2
        case .requestIDR: return 3
        case .requestCursorShape: return 4
        }
    }

    /// Serialises the message: `[UInt8 type][body...]`.
    public func encode() -> Data {
        var out = Data()
        out.append(messageType)
        switch self {
        case .ack(let streamSeq):
            out.appendBE(streamSeq)
        case .requestLTRRefresh(let fromFrameID, let toFrameID):
            out.appendBE(fromFrameID)
            out.appendBE(toFrameID)
        case .requestIDR:
            break
        case .requestCursorShape(let shapeID):
            out.appendBE(shapeID)
        }
        return out
    }

    /// Parses a recovery message. Throws ``VideoProtocolError`` on an unknown type
    /// or short body.
    public static func decode(_ data: Data) throws -> RecoveryMessage {
        var reader = VideoByteReader(data)
        let type = try reader.readUInt8()
        switch type {
        case 1:
            return .ack(streamSeq: try reader.readUInt32())
        case 2:
            let from = try reader.readUInt32()
            let to = try reader.readUInt32()
            return .requestLTRRefresh(fromFrameID: from, toFrameID: to)
        case 3:
            return .requestIDR
        case 4:
            return .requestCursorShape(shapeID: try reader.readUInt16())
        default:
            throw VideoProtocolError.malformed("unknown recovery message type \(type)")
        }
    }
}

/// Models the client-side recovery policy: which message to send for a detected
/// loss, and when to escalate to a forced IDR. Pure decision logic — the timer /
/// transport lives in `RworkVideoClient`.
public struct RecoveryPolicy: Sendable {
    /// Escalate to IDR if no decodable frame arrives within this multiple of the
    /// measured RTT (doc 17 §3.6: "fallback IDR after timeout 2-RTT").
    public let idrTimeoutRTTMultiple: Double

    public init(idrTimeoutRTTMultiple: Double = 2.0) {
        self.idrTimeoutRTTMultiple = idrTimeoutRTTMultiple
    }

    /// The first message to send when frames `[from, to]` are detected lost: prefer
    /// an LTR refresh.
    public func initialRequest(lostFrom: UInt32, lostTo: UInt32) -> RecoveryMessage {
        .requestLTRRefresh(fromFrameID: lostFrom, toFrameID: lostTo)
    }

    /// Whether the client should escalate to a forced IDR given how long it has
    /// waited since the LTR-refresh request, and the current RTT estimate.
    public func shouldEscalateToIDR(elapsedSinceRequest: TimeInterval, rtt: TimeInterval) -> Bool {
        elapsedSinceRequest >= idrTimeoutRTTMultiple * rtt
    }
}
