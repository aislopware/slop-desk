import Foundation

/// Per-datagram header for the video stream (UDP). Fixed 19 bytes, big-endian.
///
/// Concrete layout (`fragCount` is a `UInt16` so it can exceed 255):
/// ```
/// off 0: UInt32 streamSeq        — monotonic per-datagram sequence number (loss/order)
/// off 4: UInt32 frameID          — groups fragments of one encoded video frame
/// off 8: UInt16 fragIndex        — 0-based index of this fragment within the frame
/// off10: UInt16 fragCount        — total fragments in the frame
/// off12: UInt8  flags            — bit0 keyframe(IDR), bit1 parity(FEC), bit2 crisp(static refresh)
/// off13: UInt32 hostSendTsMillis — host-monotonic ms since the host SESSION START (relative;
///                                  0 = telemetry off / unstamped). ALWAYS present, fixed width.
///                                  The client echoes it back verbatim in a NetworkStats report so
///                                  the host can compute RTT in its OWN clock (no cross-machine skew).
/// off17: UInt16 payloadLen       — bytes of payload that follow (defensive; UDP also bounds it).
///                                  Kept IMMEDIATELY before the payload it sizes.
/// off19: payload[payloadLen]
/// ```
/// = **19-byte header**. The MTU budget (`VideoPacketizer.maxDatagramSize` = 1200,
/// doc 17 §3.6 "datagrams <= 1200 bytes") minus the header gives the payload cap.
public struct FrameFragmentHeader: Equatable, Sendable {
    public struct Flags: OptionSet, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        /// This frame is a keyframe (IDR) — a fresh decode anchor.
        public static let keyframe = Flags(rawValue: 1 << 0)
        /// This fragment is an FEC parity fragment, not original data.
        public static let parity = Flags(rawValue: 1 << 1)
        /// This frame is a CRISP near-lossless static refresh (a QP-bumped keyframe from the live
        /// session, emitted when the window is at rest — Design A). Informational on the wire; the
        /// client treats it as an ordinary keyframe.
        public static let crisp = Flags(rawValue: 1 << 2)

        // WF-4 ADAPTIVE FEC: a 3-bit FEC tier index packed into bits 3,4,5 of the (otherwise
        // 3-bit-used) flags byte — NO new header field, NO size change. The tier signals the
        // per-frame XOR group size (``AdaptiveFECPolicy.groupSize(forTier:default:)``) so the
        // client splits data/parity identically to the host. EVERY fragment of a frame carries
        // the SAME tier; parity fragments additionally set `.parity` (bit 1, independent). Bits
        // 6,7 stay reserved. Tier 0 leaves all three bits zero → byte-identical to the pre-WF-4
        // wire. These coexist with `.keyframe`/`.parity`/`.crisp` (disjoint bit masks).
        public static let tierShift: UInt8 = 3
        public static let tierMask: UInt8 = 0b0011_1000 // bits 3,4,5

        /// WF-8 LTR-FRAME MARKER (bit 6): this frame is a Long-Term-Reference frame — the encoder
        /// emitted it carrying `kVTSampleAttachmentKey_RequireLTRAcknowledgementToken`, so a client
        /// that DECODES it must reply `RecoveryMessage.ack(frameID)` to tell the host it now holds
        /// that LTR (the ACKED-ONLY recovery invariant). Disjoint from keyframe/parity/crisp/tier;
        /// bit 7 stays reserved. Set only when the host has `AISLOPDESK_LTR` on AND the frame carried a
        /// token, so the OFF path leaves bit 6 zero → byte-identical wire.
        public static let isLTR = Flags(rawValue: 1 << 6)

        /// The 3-bit FEC tier (0..7) read from bits 3-5 — masks out keyframe/parity/crisp + bits 6,7.
        public var fecTier: UInt8 { (rawValue & Self.tierMask) >> Self.tierShift }

        /// Sets the 3-bit FEC tier in bits 3-5, preserving every other flag bit. `t` is masked to
        /// 3 bits, so this can never disturb keyframe/parity/crisp or the reserved bits.
        public mutating func setFECTier(_ t: UInt8) {
            self = Flags(rawValue: (rawValue & ~Self.tierMask) | ((t & 0b111) << Self.tierShift))
        }
    }

    public var streamSeq: UInt32
    public var frameID: UInt32
    public var fragIndex: UInt16
    public var fragCount: UInt16
    public var flags: Flags
    /// Host-monotonic milliseconds since the host session start (relative; 0 = telemetry off /
    /// unstamped). Carried on EVERY fragment of a frame (all share one stamp). The client never
    /// compares it against its own clock — it echoes the newest value it saw back to the host, which
    /// subtracts it from its OWN clock to derive RTT, so there is zero cross-machine clock skew.
    public var hostSendTsMillis: UInt32
    public var payloadLength: UInt16

    public init(streamSeq: UInt32, frameID: UInt32, fragIndex: UInt16, fragCount: UInt16, flags: Flags, payloadLength: UInt16, hostSendTsMillis: UInt32 = 0) {
        self.streamSeq = streamSeq
        self.frameID = frameID
        self.fragIndex = fragIndex
        self.fragCount = fragCount
        self.flags = flags
        self.hostSendTsMillis = hostSendTsMillis
        self.payloadLength = payloadLength
    }

    /// Header size in bytes.
    public static let size = 19
}

/// One fragment datagram = header + payload, encoded/decoded for the wire.
public struct FrameFragment: Equatable, Sendable {
    public var header: FrameFragmentHeader
    public var payload: Data

    public init(header: FrameFragmentHeader, payload: Data) {
        self.header = header
        self.payload = payload
    }

    /// Serialises the datagram (header then payload).
    public func encode() -> Data {
        var out = Data(capacity: FrameFragmentHeader.size + payload.count)
        out.appendBE(header.streamSeq)
        out.appendBE(header.frameID)
        out.appendBE(header.fragIndex)
        out.appendBE(header.fragCount)
        out.append(header.flags.rawValue)
        out.appendBE(header.hostSendTsMillis)
        out.appendBE(UInt16(payload.count))
        out.append(payload)
        return out
    }

    /// Parses one datagram. Throws ``VideoProtocolError`` on a short/inconsistent
    /// datagram (a corrupt single packet must not crash the receiver).
    public static func decode(_ datagram: Data) throws -> FrameFragment {
        var reader = VideoByteReader(datagram)
        let streamSeq = try reader.readUInt32()
        let frameID = try reader.readUInt32()
        let fragIndex = try reader.readUInt16()
        let fragCount = try reader.readUInt16()
        let flags = FrameFragmentHeader.Flags(rawValue: try reader.readUInt8())
        // Auto-bounds-checked (VideoByteReader throws .truncated on underflow): a datagram shorter
        // than the 19-byte header throws → the router drops the single packet, never crashes.
        let hostSendTsMillis = try reader.readUInt32()
        let payloadLength = try reader.readUInt16()
        let payload = try reader.readBytes(Int(payloadLength))
        let header = FrameFragmentHeader(
            streamSeq: streamSeq, frameID: frameID, fragIndex: fragIndex,
            fragCount: fragCount, flags: flags, payloadLength: payloadLength, hostSendTsMillis: hostSendTsMillis
        )
        return FrameFragment(header: header, payload: payload)
    }
}

/// Fragments a NALU-bearing encoded frame into <=1200-byte datagrams (doc 17 §3.6).
///
/// The packetizer is stateful only in that it hands out a monotonic per-datagram
/// `streamSeq` (the 4-byte sequence number used for ordering / loss detection) and
/// a per-frame `frameID`. It is a value type owned by the single send loop.
public struct VideoPacketizer {
    /// Max UDP payload size (doc 17 §3.6: "<= 1200 bytes" to stay under typical MTU
    /// with WireGuard overhead).
    public static let maxDatagramSize = 1200
    /// Max payload bytes per fragment (datagram budget minus the header).
    public static let maxPayloadSize = maxDatagramSize - FrameFragmentHeader.size

    private var nextStreamSeq: UInt32 = 0
    private var nextFrameID: UInt32 = 0

    /// Optional FEC scheme; when set, parity fragments are appended to each frame.
    public let fec: FECScheme?

    public init(fec: FECScheme? = nil) {
        self.fec = fec
    }

    /// The `streamSeq` that the next emitted datagram will carry (for tests / acks).
    public var peekNextStreamSeq: UInt32 { nextStreamSeq }

    /// The `frameID` that the NEXT ``packetize(frame:keyframe:crisp:hostSendTsMillis:fecTier:isLTR:)``
    /// call will assign (mirror of ``peekNextStreamSeq``). WF-8: the host actor reads this BEFORE
    /// packetizing so it can record the `frameID ↔ LTR-token` mapping for the frame about to be sent
    /// (the packetizer increments `nextFrameID` inside `packetize`). Read in encode order on the actor.
    public var peekNextFrameID: UInt32 { nextFrameID }

    /// Fragments one encoded frame (an AVCC byte buffer) into data fragments,
    /// followed by FEC parity fragments if a scheme is configured.
    ///
    /// - Parameters:
    ///   - frame: the AVCC bytes (length-prefixed NAL units) of one encoded frame.
    ///   - keyframe: whether this is an IDR (sets the keyframe flag).
    ///   - crisp: whether this is a crisp near-lossless static refresh keyframe (informational).
    ///   - hostSendTsMillis: host-monotonic ms since session start, stamped on EVERY fragment of this
    ///     frame (the actor supplies it so this value type stays clockless). 0 = telemetry off.
    ///   - fecTier: WF-4 adaptive-FEC tier (default tier 0 = the endpoint's configured group size).
    ///     Selects the per-frame XOR group size via ``AdaptiveFECPolicy/groupSize(forTier:default:)``
    ///     (nil = OFF → no parity) and is stamped into every fragment's flags so the client splits
    ///     data/parity with the SAME group size. Default tier 0 → no flag bits set, no parity-shape
    ///     change → byte-identical to the pre-WF-4 path.
    ///   - isLTR: WF-8 — whether this frame is a Long-Term-Reference frame (carried the encoder's
    ///     `RequireLTRAcknowledgementToken`). Sets ``FrameFragmentHeader/Flags/isLTR`` (bit 6) on
    ///     EVERY fragment so the client knows to ack it after a successful decode. Default false →
    ///     bit 6 stays zero → byte-identical to the pre-WF-8 wire.
    /// - Returns: data fragments + parity fragments, in send order.
    public mutating func packetize(frame: Data, keyframe: Bool, crisp: Bool = false, hostSendTsMillis: UInt32 = 0, fecTier: UInt8 = AdaptiveFECPolicy.defaultTier, isLTR: Bool = false) -> [FrameFragment] {
        let frameID = nextFrameID
        nextFrameID &+= 1

        // Split into MTU-bounded payloads.
        var payloads: [Data] = []
        var offset = frame.startIndex
        let end = frame.endIndex
        if offset == end {
            payloads = [Data()] // a zero-byte frame still occupies one fragment
        } else {
            while offset < end {
                let upper = frame.index(offset, offsetBy: Self.maxPayloadSize, limitedBy: end) ?? end
                payloads.append(Data(frame[offset ..< upper]))
                offset = upper
            }
        }

        // WF-4: the per-frame group size comes from the tier (nil = OFF → no parity). Tier 0 maps to
        // the configured `fec.groupSize` (5 in prod) so parity shape is identical to the pre-WF-4 path.
        let groupSize = AdaptiveFECPolicy.groupSize(forTier: fecTier, default: fec?.groupSize ?? 1)
        let parityPayloads = (groupSize != nil ? fec?.parity(forDataFragments: payloads, groupSize: groupSize!) : nil) ?? []
        let fragCount = UInt16(payloads.count + parityPayloads.count)

        var baseFlags: FrameFragmentHeader.Flags = []
        if keyframe { baseFlags.insert(.keyframe) }
        if crisp { baseFlags.insert(.crisp) }
        if isLTR { baseFlags.insert(.isLTR) }   // WF-8 bit 6 — disjoint from keyframe/crisp/tier
        // Stamp the tier into bits 3-5 BEFORE forking data/parity flags. Tier 0 leaves them zero.
        baseFlags.setFECTier(fecTier)

        var fragments: [FrameFragment] = []
        fragments.reserveCapacity(payloads.count + parityPayloads.count)
        var fragIndex: UInt16 = 0
        for payload in payloads {
            fragments.append(makeFragment(frameID: frameID, fragIndex: fragIndex, fragCount: fragCount, flags: baseFlags, payload: payload, hostSendTsMillis: hostSendTsMillis))
            fragIndex += 1
        }
        for payload in parityPayloads {
            var flags = baseFlags
            flags.insert(.parity)
            fragments.append(makeFragment(frameID: frameID, fragIndex: fragIndex, fragCount: fragCount, flags: flags, payload: payload, hostSendTsMillis: hostSendTsMillis))
            fragIndex += 1
        }
        return fragments
    }

    private mutating func makeFragment(frameID: UInt32, fragIndex: UInt16, fragCount: UInt16, flags: FrameFragmentHeader.Flags, payload: Data, hostSendTsMillis: UInt32) -> FrameFragment {
        let seq = nextStreamSeq
        nextStreamSeq &+= 1
        let header = FrameFragmentHeader(
            streamSeq: seq, frameID: frameID, fragIndex: fragIndex,
            fragCount: fragCount, flags: flags, payloadLength: UInt16(payload.count), hostSendTsMillis: hostSendTsMillis
        )
        return FrameFragment(header: header, payload: payload)
    }
}
