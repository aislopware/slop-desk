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
        public static let keyframe = Self(rawValue: 1 << 0)
        /// This fragment is an FEC parity fragment, not original data.
        public static let parity = Self(rawValue: 1 << 1)
        /// This frame is a CRISP near-lossless static refresh (a QP-bumped keyframe from the live
        /// session, emitted when the window is at rest — Design A). Informational on the wire; the
        /// client treats it as an ordinary keyframe.
        public static let crisp = Self(rawValue: 1 << 2)

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
        public static let isLTR = Self(rawValue: 1 << 6)

        /// ACKED-ANCHORED MARKER (bit 7, 2026-06-12): this frame was encoded via `ForceLTRRefresh`
        /// — it references ONLY long-term references the client ACKNOWLEDGED (decoded), so it is
        /// decodable even when the recent short-term chain is broken. This is the client decode
        /// gate's ONLY non-keyframe re-anchor admission: `isLTR` (bit 6) cannot serve — VT
        /// surfaces an ack token on virtually EVERY frame once LTR is enabled (measured live:
        /// 7865/7874 frames), so bit 6 says "ack me", not "safe to decode past a loss". Set by
        /// the host exactly when the encode call carried `kVTEncodeFrameOptionKey_ForceLTRRefresh`
        /// (recovery refresh + self-heal cadence). Previously-reserved bit ⇒ old senders leave it
        /// zero (byte-identical wire when unused).
        public static let ackedAnchored = Self(rawValue: 1 << 7)

        /// The 3-bit FEC tier (0..7) read from bits 3-5 — masks out keyframe/parity/crisp + bits 6,7.
        public var fecTier: UInt8 { (rawValue & Self.tierMask) >> Self.tierShift }

        /// Sets the 3-bit FEC tier in bits 3-5, preserving every other flag bit. `t` is masked to
        /// 3 bits, so this can never disturb keyframe/parity/crisp or the reserved bits.
        public mutating func setFECTier(_ t: UInt8) {
            self = Self(rawValue: (rawValue & ~Self.tierMask) | ((t & 0b111) << Self.tierShift))
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

    public init(
        streamSeq: UInt32,
        frameID: UInt32,
        fragIndex: UInt16,
        fragCount: UInt16,
        flags: Flags,
        payloadLength: UInt16,
        hostSendTsMillis: UInt32 = 0,
    ) {
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
    public static func decode(_ datagram: Data) throws -> Self {
        var reader = VideoByteReader(datagram)
        let streamSeq = try reader.readUInt32()
        let frameID = try reader.readUInt32()
        let fragIndex = try reader.readUInt16()
        let fragCount = try reader.readUInt16()
        let flags = try FrameFragmentHeader.Flags(rawValue: reader.readUInt8())
        // Auto-bounds-checked (VideoByteReader throws .truncated on underflow): a datagram shorter
        // than the 19-byte header throws → the router drops the single packet, never crashes.
        let hostSendTsMillis = try reader.readUInt32()
        let payloadLength = try reader.readUInt16()
        let payload = try reader.readBytes(Int(payloadLength))
        let header = FrameFragmentHeader(
            streamSeq: streamSeq, frameID: frameID, fragIndex: fragIndex,
            fragCount: fragCount, flags: flags, payloadLength: payloadLength, hostSendTsMillis: hostSendTsMillis,
        )
        return Self(header: header, payload: payload)
    }
}

/// Fragments a NALU-bearing encoded frame into <=1200-byte datagrams (doc 17 §3.6).
///
/// The MTU split, the per-frame FEC group size, the parity append, and the 19-byte header stamp all
/// live in the Rust core (`aislopdesk_core::fragment::VideoPacketizer`), driven over the
/// `aisd_packetize` C ABI — the SINGLE SOURCE OF TRUTH for the send path (the symmetric counterpart
/// of ``FrameReassembler``). The previous native Swift packetize/header-stamping/FEC-append logic is
/// DELETED; this is a thin Rust-backed shell that keeps the public API (and the ``FrameFragment``
/// wire type) so the host send path is unchanged. `m == 1` is byte-identical to the pre-port wire.
///
/// Owns a Rust packetizer handle (which OWNS its own NEON-backed Reed-Solomon codec — no second FEC
/// handle, no double-FEC), so this is a `final class` with a `deinit` that frees it. Stateful only in
/// that the core hands out a monotonic per-datagram `streamSeq` and a per-frame `frameID`; one per
/// send loop, not thread-safe (the host actor serializes it).
public final class VideoPacketizer: @unchecked Sendable {
    /// Max UDP payload size (doc 17 §3.6: "<= 1200 bytes" to stay under typical MTU
    /// with WireGuard overhead).
    public static let maxDatagramSize = 1200
    /// Max payload bytes per fragment (datagram budget minus the header).
    public static let maxPayloadSize = maxDatagramSize - FrameFragmentHeader.size

    /// The configured FEC scheme (kept so the host can read ``FECScheme/groupSize`` for interleave),
    /// or `nil` for a no-FEC packetizer. The live parity engine is the core codec the Rust packetizer
    /// owns internally — this reference is metadata only.
    public let fec: FECScheme?
    /// The owned Rust packetizer handle (`AisdVideoPacketizer *`). Freed in `deinit`.
    private let handle: OpaquePointer

    public init(fec: FECScheme? = nil) {
        self.fec = fec
        // Build the core packetizer with the scheme's (k, m). A nil scheme (or a 1×1 default) is a
        // no-FEC packetizer (k == 0). `aisd_video_packetizer_new` returns null ONLY for an invalid
        // (k, m), which a real ``FECScheme`` rules out (k>=1, m>=1, k+m<=255) — so the unwrap is
        // total for any valid scheme.
        let k = fec?.groupSize ?? 0
        let m = fec?.parityCount ?? 0
        guard let handle = RustVideoFFI.packetizerNew(k: k, m: m) else {
            preconditionFailure("aisd_video_packetizer_new returned null for (k=\(k), m=\(m))")
        }
        self.handle = handle
    }

    deinit { RustVideoFFI.packetizerFree(handle) }

    /// The `streamSeq` that the next emitted datagram will carry (for tests / acks).
    public var peekNextStreamSeq: UInt32 { RustVideoFFI.packetizerPeekNextStreamSeq(handle) }

    /// The `frameID` that the NEXT ``packetize(frame:keyframe:crisp:hostSendTsMillis:fecTier:isLTR:ackedAnchored:interleave:)``
    /// call will assign (mirror of ``peekNextStreamSeq``). WF-8: the host actor reads this BEFORE
    /// packetizing so it can record the `frameID ↔ LTR-token` mapping for the frame about to be sent
    /// (the core increments its `nextFrameID` inside `packetize`). Read in encode order on the actor.
    public var peekNextFrameID: UInt32 { RustVideoFFI.packetizerPeekNextFrameID(handle) }

    /// Fragments one encoded frame (an AVCC byte buffer) into data fragments, followed by FEC parity
    /// fragments if a scheme is configured — entirely in the Rust core.
    ///
    /// - Parameters:
    ///   - frame: the AVCC bytes (length-prefixed NAL units) of one encoded frame.
    ///   - keyframe: whether this is an IDR (sets the keyframe flag).
    ///   - crisp: whether this is a crisp near-lossless static refresh keyframe (informational).
    ///   - hostSendTsMillis: host-monotonic ms since session start, stamped on EVERY fragment of this
    ///     frame (the actor supplies it). 0 = telemetry off.
    ///   - fecTier: WF-4 adaptive-FEC tier (default tier 0 = the endpoint's configured group size).
    ///     Selects the per-frame group size via ``AdaptiveFECPolicy/groupSize(forTier:default:)`` and
    ///     is stamped into every fragment's flags so the client splits data/parity with the SAME
    ///     group size. Default tier 0 → no flag bits set, no parity-shape change → byte-identical.
    ///   - isLTR: WF-8 — whether this frame is a Long-Term-Reference frame; sets bit 6 on EVERY
    ///     fragment so the client acks it after decode. Default false → byte-identical.
    ///   - ackedAnchored: `ForceLTRRefresh` product (bit 7). Default false → byte-identical.
    ///   - interleave: run the burst-resilient column-major transmit reorder in the SAME core call
    ///     (keyed by the per-frame group size; m-aware). Default false → data then parity in index
    ///     order, the pre-port send order.
    /// - Returns: data fragments + parity fragments, in send order.
    public func packetize(
        frame: Data,
        keyframe: Bool,
        crisp: Bool = false,
        hostSendTsMillis: UInt32 = 0,
        fecTier: UInt8 = AdaptiveFECPolicy.defaultTier,
        isLTR: Bool = false,
        ackedAnchored: Bool = false,
        interleave: Bool = false,
    ) -> [FrameFragment] {
        // Pass the codec's RAW default group size (`k`) as the tier-0 default; the Rust core does the
        // ONE tier→group-size resolution internally (`AdaptiveFECPolicy.groupSize(forTier:default:)`)
        // and keys the interleave by the same value. Passing the already-resolved size here would
        // double-apply the table — `0` ⇒ the codec's configured `k`, which is exactly this default.
        RustVideoFFI.packetize(handle, frame: frame, opts: RustVideoFFI.PacketizeOptions(
            keyframe: keyframe,
            crisp: crisp,
            hostSendTsMillis: hostSendTsMillis,
            fecTier: fecTier,
            isLTR: isLTR,
            ackedAnchored: ackedAnchored,
            fecGroupSize: fec?.groupSize ?? 0,
            interleave: interleave,
        ))
    }

    /// Send-path fast path: the finished wire datagrams as raw `[Data]`, skipping the
    /// `FrameFragment` parse + re-encode the host send never needs (see
    /// ``RustVideoFFI/packetizeRaw(_:frame:opts:)``). Byte-identical to `packetize(...).map { $0.encode() }`
    /// — pinned by `PacketizeRawByteIdentityTests`.
    public func packetizeRaw(
        frame: Data,
        keyframe: Bool,
        crisp: Bool = false,
        hostSendTsMillis: UInt32 = 0,
        fecTier: UInt8 = AdaptiveFECPolicy.defaultTier,
        isLTR: Bool = false,
        ackedAnchored: Bool = false,
        interleave: Bool = false,
    ) -> [Data] {
        RustVideoFFI.packetizeRaw(handle, frame: frame, opts: RustVideoFFI.PacketizeOptions(
            keyframe: keyframe,
            crisp: crisp,
            hostSendTsMillis: hostSendTsMillis,
            fecTier: fecTier,
            isLTR: isLTR,
            ackedAnchored: ackedAnchored,
            fecGroupSize: fec?.groupSize ?? 0,
            interleave: interleave,
        ))
    }
}
