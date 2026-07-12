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

        // ADAPTIVE FEC: a 3-bit FEC tier index packed into bits 3,4,5 of the (otherwise
        // 3-bit-used) flags byte — NO new header field, NO size change. The tier signals the
        // per-frame XOR group size (``AdaptiveFECPolicy.groupSize(forTier:default:)``) so the
        // client splits data/parity identically to the host. EVERY fragment of a frame carries
        // the SAME tier; parity fragments additionally set `.parity` (bit 1, independent). Bits
        // 6,7 stay reserved. Tier 0 leaves all three bits zero → byte-identical to the plain
        // wire. These coexist with `.keyframe`/`.parity`/`.crisp` (disjoint bit masks).
        public static let tierShift: UInt8 = 3
        public static let tierMask: UInt8 = 0b0011_1000 // bits 3,4,5

        /// LTR-FRAME MARKER (bit 6): this frame is a Long-Term-Reference frame — the encoder
        /// emitted it carrying `kVTSampleAttachmentKey_RequireLTRAcknowledgementToken`, so a client
        /// that DECODES it must reply `RecoveryMessage.ack(frameID)` to tell the host it now holds
        /// that LTR (the ACKED-ONLY recovery invariant). Disjoint from keyframe/parity/crisp/tier;
        /// bit 7 stays reserved. Set only when the host has `SLOPDESK_LTR` on AND the frame carried a
        /// token, so the OFF path leaves bit 6 zero → byte-identical wire.
        public static let isLTR = Self(rawValue: 1 << 6)

        /// ACKED-ANCHORED MARKER (bit 7): this frame was encoded via `ForceLTRRefresh`
        /// — it references ONLY long-term references the client ACKNOWLEDGED (decoded), so it is
        /// decodable even when the recent short-term chain is broken. This is the client decode
        /// gate's ONLY non-keyframe re-anchor admission: `isLTR` (bit 6) cannot serve — VT
        /// surfaces an ack token on virtually EVERY frame once LTR is enabled (measured live:
        /// 7865/7874 frames), so bit 6 says "ack me", not "safe to decode past a loss". Set by
        /// the host exactly when the encode call carried `kVTEncodeFrameOptionKey_ForceLTRRefresh`
        /// (recovery refresh + self-heal cadence). An otherwise-unused bit, so senders that don't
        /// set it leave it zero (byte-identical wire when unused).
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
/// The MTU split, the per-frame FEC group size, the parity append, the m-aware adaptive-FEC parity,
/// the optional burst-resilient interleave, and the 19-byte header stamp are all NATIVE Swift — the
/// SINGLE SOURCE OF TRUTH for the send path (the symmetric counterpart of ``FrameReassembler``).
/// Reuses the native ``FECScheme`` for parity, ``FragmentInterleaver`` for the transmit reorder, and
/// the ``FrameFragment`` header codec. `m == 1` (the production codec) is byte-identical to the legacy
/// XOR/length-prefix wire.
///
/// Kept as a `final class` (not a value `struct`) so `packetize`/`packetizeRaw` are NON-mutating and
/// the host can hold it as a `let` — the monotonic per-datagram `streamSeq` and per-frame `frameID`
/// counters live as native stored fields. One per send loop, not thread-safe (the host actor
/// serializes it); `@unchecked Sendable` to cross the actor boundary like the prior shell.
public final class VideoPacketizer: @unchecked Sendable {
    /// Max UDP payload size (doc 17 §3.6: "<= 1200 bytes" to stay under typical MTU
    /// with WireGuard overhead).
    public static let maxDatagramSize = 1200
    /// Max payload bytes per fragment (datagram budget minus the header).
    public static let maxPayloadSize = maxDatagramSize - FrameFragmentHeader.size

    /// Optional FEC scheme; when set, parity fragments are appended to each frame. Also read by the
    /// host for ``FECScheme/groupSize``. The live parity engine is this very scheme (native Swift).
    public let fec: FECScheme?

    /// Next monotonic per-datagram `streamSeq` (4-byte sequence for ordering / loss detection).
    private var nextStreamSeq: UInt32 = 0
    /// Next per-frame `frameID` (groups one encoded frame's fragments).
    private var nextFrameID: UInt32 = 0

    public init(fec: FECScheme? = nil) {
        self.fec = fec
    }

    /// The `streamSeq` that the next emitted datagram will carry (for tests / acks). Pure read — does
    /// NOT advance the counter.
    public var peekNextStreamSeq: UInt32 { nextStreamSeq }

    /// The `frameID` that the NEXT ``packetize(frame:keyframe:crisp:hostSendTsMillis:fecTier:isLTR:ackedAnchored:interleave:)``
    /// call will assign (mirror of ``peekNextStreamSeq``). The host actor reads this BEFORE
    /// packetizing so it can record the `frameID ↔ LTR-token` mapping for the frame about to be sent
    /// (`packetize` increments `nextFrameID`). Read in encode order on the actor. Pure read — does NOT
    /// advance the counter.
    public var peekNextFrameID: UInt32 { nextFrameID }

    /// Fragments one encoded frame (an AVCC byte buffer) into data fragments, followed by FEC parity
    /// fragments if a scheme is configured, optionally interleaved for burst resilience.
    ///
    /// - Parameters:
    ///   - frame: the AVCC bytes (length-prefixed NAL units) of one encoded frame.
    ///   - keyframe: whether this is an IDR (sets the keyframe flag).
    ///   - crisp: whether this is a crisp near-lossless static refresh keyframe (informational).
    ///   - hostSendTsMillis: host-monotonic ms since session start, stamped on EVERY fragment of this
    ///     frame (the actor supplies it). 0 = telemetry off.
    ///   - fecTier: adaptive-FEC tier (default tier 0 = the endpoint's configured group size).
    ///     Selects the per-frame group size via ``AdaptiveFECPolicy/groupSize(forTier:default:)`` and
    ///     the per-frame parity multiplicity `m` via the adaptive-m ladder, and is stamped into every
    ///     fragment's flags so the client splits data/parity with the SAME group size + `m`. Default
    ///     tier 0 → no flag bits set, no parity-shape change → byte-identical.
    ///   - isLTR: whether this frame is a Long-Term-Reference frame; sets bit 6 on EVERY
    ///     fragment so the client acks it after decode. Default false → byte-identical.
    ///   - ackedAnchored: `ForceLTRRefresh` product (bit 7). Default false → byte-identical.
    ///   - interleave: run the burst-resilient column-major transmit reorder (keyed by the per-frame
    ///     group size; m-aware). Default false → data then parity in index order, the pre-port order.
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
        let fragments = packetizeFragments(
            frame: frame,
            keyframe: keyframe,
            crisp: crisp,
            hostSendTsMillis: hostSendTsMillis,
            fecTier: fecTier,
            isLTR: isLTR,
            ackedAnchored: ackedAnchored,
        )
        guard interleave else { return fragments }
        // Interleave is keyed by the SAME per-frame group size the parity used (`groupSize(forTier:)`,
        // OFF tier → 1 ⇒ a no-op). m-aware — `FragmentInterleaver` derives `m` from the parity count.
        let interleaveGroup = AdaptiveFECPolicy.groupSize(
            forTier: fecTier, default: fec?.groupSize ?? 1,
        ) ?? 1
        return FragmentInterleaver.interleave(fragments, groupSize: interleaveGroup)
    }

    /// Send-path fast path: the finished wire datagrams as raw `[Data]`, skipping the
    /// `FrameFragment` parse + re-encode the host send never needs. Byte-identical to
    /// `packetize(...).map { $0.encode() }` — pinned by `PacketizeRawByteIdentityTests`.
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
        packetize(
            frame: frame,
            keyframe: keyframe,
            crisp: crisp,
            hostSendTsMillis: hostSendTsMillis,
            fecTier: fecTier,
            isLTR: isLTR,
            ackedAnchored: ackedAnchored,
            interleave: interleave,
        ).map { $0.encode() }
    }

    // MARK: - Core fragment build (data then parity, in send order BEFORE any interleave)

    /// Builds the frame's fragments (data, then parity), assigning the per-frame `frameID` and the
    /// monotonic `streamSeq` per datagram. Shared by ``packetize`` / ``packetizeRaw`` so the counters
    /// advance once per frame regardless of which entry the caller used.
    private func packetizeFragments(
        frame: Data,
        keyframe: Bool,
        crisp: Bool,
        hostSendTsMillis: UInt32,
        fecTier: UInt8,
        isLTR: Bool,
        ackedAnchored: Bool,
    ) -> [FrameFragment] {
        let frameID = nextFrameID
        nextFrameID &+= 1

        // Split into MTU-bounded payloads. A zero-byte frame still occupies one fragment.
        var payloads: [Data] = []
        var offset = frame.startIndex
        let end = frame.endIndex
        if offset == end {
            payloads = [Data()]
        } else {
            // Pre-size to the exact data-fragment count (ceil division over the MTU budget) so the
            // append loop never grows the backing buffer. Identical split, identical bytes.
            payloads.reserveCapacity((frame.count + Self.maxPayloadSize - 1) / Self.maxPayloadSize)
            while offset < end {
                let upper = frame.index(offset, offsetBy: Self.maxPayloadSize, limitedBy: end) ?? end
                payloads.append(Data(frame[offset..<upper]))
                offset = upper
            }
        }

        // Per-frame group size from the tier (nil = OFF → no parity). Tier 0 maps to the codec's
        // configured `groupSize` (`k`) so parity shape is identical to the plain path.
        let defaultGroup = fec?.groupSize ?? 1
        let groupSize = AdaptiveFECPolicy.groupSize(forTier: fecTier, default: defaultGroup)
        // ADAPTIVE-m: the per-frame parity multiplicity is ALSO derived from the tier. For tier 0-4
        // (and 5/6/7 on a single-parity codec) this resolves to the codec's own `parityCount`, so the
        // default scheme's `parity(forDataFragments:groupSize:)` is byte-for-byte correct (golden-stable);
        // only the new m-tiers (5/6/7 on a multi-loss codec) need a different `m`, for which a per-frame
        // codec at the requested `m` is built.
        let parityPayloads: [Data]
        if let g = groupSize, let scheme = fec {
            let m = Self.parityCount(forTier: fecTier, default: scheme.parityCount)
            parityPayloads = Self.parity(
                scheme: scheme, dataFragments: payloads, groupSize: g, m: m,
            )
        } else {
            parityPayloads = []
        }

        let fragCount = UInt16(payloads.count + parityPayloads.count)

        var baseFlags: FrameFragmentHeader.Flags = []
        if keyframe { baseFlags.insert(.keyframe) }
        if crisp { baseFlags.insert(.crisp) }
        if isLTR { baseFlags.insert(.isLTR) } // bit 6 — disjoint from keyframe/crisp/tier
        if ackedAnchored { baseFlags.insert(.ackedAnchored) } // bit 7 — ForceLTRRefresh product
        // Stamp the tier into bits 3-5 BEFORE forking data/parity flags. Tier 0 leaves them zero.
        baseFlags.setFECTier(fecTier)

        var fragments: [FrameFragment] = []
        fragments.reserveCapacity(payloads.count + parityPayloads.count)
        var fragIndex: UInt16 = 0
        for payload in payloads {
            fragments.append(makeFragment(
                frameID: frameID, fragIndex: fragIndex, fragCount: fragCount,
                flags: baseFlags, payload: payload, hostSendTsMillis: hostSendTsMillis,
            ))
            fragIndex += 1
        }
        for payload in parityPayloads {
            var flags = baseFlags
            flags.insert(.parity)
            fragments.append(makeFragment(
                frameID: frameID, fragIndex: fragIndex, fragCount: fragCount,
                flags: flags, payload: payload, hostSendTsMillis: hostSendTsMillis,
            ))
            fragIndex += 1
        }
        return fragments
    }

    private func makeFragment(
        frameID: UInt32,
        fragIndex: UInt16,
        fragCount: UInt16,
        flags: FrameFragmentHeader.Flags,
        payload: Data,
        hostSendTsMillis: UInt32,
    ) -> FrameFragment {
        let seq = nextStreamSeq
        nextStreamSeq &+= 1
        let header = FrameFragmentHeader(
            streamSeq: seq, frameID: frameID, fragIndex: fragIndex,
            fragCount: fragCount, flags: flags, payloadLength: UInt16(payload.count),
            hostSendTsMillis: hostSendTsMillis,
        )
        return FrameFragment(header: header, payload: payload)
    }

    // MARK: - m-aware parity (adaptive-FEC parity-count ladder)

    /// Per-frame parity computed at the per-frame multiplicity `m`. When `m` equals the scheme's own
    /// configured ``FECScheme/parityCount`` (tier 0-4, and 5/6/7 on a single-parity codec), this is
    /// exactly `scheme.parity(forDataFragments:groupSize:)` — byte-identical / golden-stable. Only the
    /// new m-tiers (5/6/7 on a multi-loss codec) request a different `m`, for which a per-frame
    /// ``RustReedSolomonFEC`` at the requested `(k = groupSize, m)` produces the right parity shards.
    private static func parity(
        scheme: FECScheme, dataFragments: [Data], groupSize: Int, m: Int,
    ) -> [Data] {
        if m == scheme.parityCount {
            return scheme.parity(forDataFragments: dataFragments, groupSize: groupSize)
        }
        // Adaptive-m: a fresh codec at the requested multiplicity. `m >= 2` here (the ladder only
        // emits 2/3/5 and the != branch is unreachable for m == 1 since any single-parity scheme has
        // parityCount == 1), so the Cauchy encoder clamps the per-call group to its own `k == groupSize`.
        let codec = RustReedSolomonFEC(groupSize: groupSize, parityCount: m)
        return codec.parity(forDataFragments: dataFragments, groupSize: groupSize)
    }

    /// Maps a wire tier index to the parity-shards-per-group `m` the host emits this frame. Mirrors
    /// the Rust `adaptive_fec::parity_count` table EXACTLY (and the receive side):
    ///
    /// - tier 1 (OFF) → 1 (no parity is sent, so `m` is moot; pinned to the byte-identical 1).
    /// - tiers 5/6/7, only when `default >= 2` → 2 / 3 / 5 (the adaptive ladder's clean/normal/burst).
    /// - every other tier (and 5/6/7 when `default == 1`) → `default` (the codec's configured `m`).
    ///
    /// TOTAL over every `UInt8` — a malformed tier off a corrupt fragment can never trap. With the
    /// production single-parity codec (`default == 1`) EVERY tier resolves to 1, so the m-tier slots
    /// are byte-identical → no mixed-fleet hazard.
    private static func parityCount(forTier tier: UInt8, default defaultM: Int) -> Int {
        switch tier {
        case 1: 1 // OFF — no parity; pin to byte-identical 1
        case AdaptiveFECPolicy.parityTierClean where defaultM >= 2: 2
        case AdaptiveFECPolicy.parityTierNormal where defaultM >= 2: 3
        case AdaptiveFECPolicy.parityTierBurst where defaultM >= 2: 5
        default: defaultM
        }
    }
}
