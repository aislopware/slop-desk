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
/// `AislopdeskVideoHost.VideoEncoder`.
///
/// A client→host **NetworkStats** report (the network-feedback telemetry channel) rides this same
/// `.recovery` channel. It is a fixed-width, all-`UInt32` body, so a malformed/truncated report
/// throws on decode → the router drops the single datagram → the host never crashes on hostile
/// stats input. All six fields are RELATIVE (windowed counters / a host-stamp echo / client-local
/// deltas), so the host can derive RTT in its own clock without any cross-machine clock skew.
public struct NetworkStatsReport: Equatable, Sendable {
    /// Complete frames the client received in this report window.
    public var framesReceived: UInt32
    /// Of those, how many were completed via FEC recovery (a data hole the parity filled).
    public var fecRecovered: UInt32
    /// Frames the client declared unrecoverably lost in this window (the loss numerator).
    public var unrecovered: UInt32
    /// The newest `hostSendTsMillis` the client has OBSERVED on a video fragment (0 = none /
    /// telemetry off). The host echoes it against its own clock to compute RTT.
    public var latestHostSendTs: UInt32
    /// Client-LOCAL elapsed ms since it observed `latestHostSendTs` (a relative delta in the
    /// client's own monotonic clock — NEVER an absolute client timestamp). The host subtracts it
    /// from `(hostNow − latestHostSendTs)` so the client-side processing hold is removed from RTT.
    public var clientHoldMs: UInt32
    /// Inter-arrival jitter (microseconds) from the client's OWN clock, RFC3550 2nd-difference form
    /// (relative deltas only) — fully clock-skew-immune.
    public var owdJitterMicros: UInt32

    public init(framesReceived: UInt32, fecRecovered: UInt32, unrecovered: UInt32, latestHostSendTs: UInt32, clientHoldMs: UInt32, owdJitterMicros: UInt32) {
        self.framesReceived = framesReceived
        self.fecRecovered = fecRecovered
        self.unrecovered = unrecovered
        self.latestHostSendTs = latestHostSendTs
        self.clientHoldMs = clientHoldMs
        self.owdJitterMicros = owdJitterMicros
    }
}

public enum RecoveryMessage: Equatable, Sendable {
    /// Acknowledge the highest contiguous `streamSeq` durably received. Lets the
    /// host bound its retransmit / LTR-pin window.
    ///
    /// WF-8 REUSE (single-user repo, no backcompat): the client now sends this after a SUCCESSFUL
    /// decode of an LTR-flagged frame (``FrameFragmentHeader/Flags/isLTR``), carrying that frame's
    /// `frameID` in the `streamSeq` field (the field name is historical — the host's `.ack` arm feeds
    /// it to ``LTRController/ackFrame(frameID:)``, NOT as a streamSeq). This is the ACKED-ONLY signal:
    /// the host learns the client holds that long-term reference and may `ForceLTRRefresh` against it.
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

    /// Periodic client→host network-feedback telemetry (the network-feedback channel). Carries a
    /// ``NetworkStatsReport`` (windowed loss/FEC counters + the newest observed host-send-ts echo +
    /// the client-local hold + inter-arrival jitter) so the host can MAINTAIN+LOG a clock-skew-free
    /// RTT/loss/jitter estimate. Telemetry only — it does not change stream behaviour this phase.
    case networkStats(NetworkStatsReport)

    /// On-wire message-type byte.
    public var messageType: UInt8 {
        switch self {
        case .ack: return 1
        case .requestLTRRefresh: return 2
        case .requestIDR: return 3
        case .requestCursorShape: return 4
        case .networkStats: return 5
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
        case .networkStats(let r):
            out.appendBE(r.framesReceived)
            out.appendBE(r.fecRecovered)
            out.appendBE(r.unrecovered)
            out.appendBE(r.latestHostSendTs)
            out.appendBE(r.clientHoldMs)
            out.appendBE(r.owdJitterMicros)
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
        case 5:
            // Six fixed-width UInt32s; each read is bounds-checked, so a body < 24 bytes throws
            // .truncated → the router drops the datagram (no OOB / overflow / force-unwrap surface).
            let framesReceived = try reader.readUInt32()
            let fecRecovered = try reader.readUInt32()
            let unrecovered = try reader.readUInt32()
            let latestHostSendTs = try reader.readUInt32()
            let clientHoldMs = try reader.readUInt32()
            let owdJitterMicros = try reader.readUInt32()
            return .networkStats(NetworkStatsReport(
                framesReceived: framesReceived, fecRecovered: fecRecovered, unrecovered: unrecovered,
                latestHostSendTs: latestHostSendTs, clientHoldMs: clientHoldMs, owdJitterMicros: owdJitterMicros))
        default:
            throw VideoProtocolError.malformed("unknown recovery message type \(type)")
        }
    }
}

/// Models the client-side recovery policy: which message to send for a detected
/// loss, and when to escalate to a forced IDR. Pure decision logic — the timer /
/// transport lives in `AislopdeskVideoClient`.
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
