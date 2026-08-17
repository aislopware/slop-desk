import CSlopDeskFFI
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

    /// Header size in bytes, from the crate that writes and reads it.
    public static let size = slopdesk_video_fragment_size(0)
}

/// One fragment datagram = header + payload, encoded/decoded for the wire.
public struct FrameFragment: Equatable, Sendable {
    public var header: FrameFragmentHeader
    public var payload: Data

    public init(header: FrameFragmentHeader, payload: Data) {
        self.header = header
        self.payload = payload
    }

    /// Serialises the datagram (header then payload) through `rust/slopdesk-video`'s codec.
    ///
    /// The declared length comes from the PAYLOAD, not from ``FrameFragmentHeader/payloadLength``,
    /// so a header built by hand can never disagree with the bytes it sizes.
    public func encode() -> Data {
        let needed = FrameFragmentHeader.size + payload.count
        var written = 0
        let bytes = [UInt8](unsafeUninitializedCapacity: needed) { out, count in
            written = payload.withUnsafeBytes { source in
                slopdesk_video_fragment_encode(
                    header.streamSeq, header.frameID, header.fragIndex, header.fragCount,
                    header.flags.rawValue, header.hostSendTsMillis,
                    source.baseAddress, source.count, out.baseAddress, out.count,
                )
            }
            count = Swift.min(written, out.count)
        }
        // The size is arithmetic on both sides — a mismatch means the wire layout moved under us,
        // and a short datagram would be worse on the wire than a loud failure here.
        precondition(written == needed, "the datagram codec and the header size disagree")
        return Data(bytes)
    }

    /// Parses one datagram through the same codec. Throws ``VideoProtocolError/truncated`` on a
    /// short or inconsistent datagram — a corrupt single packet must not crash the receiver, so the
    /// router drops it and reads the next one.
    ///
    /// The payload is sliced out of `datagram` at the offset Rust reports rather than copied across
    /// the boundary: the caller already holds these bytes, and the wire layout stays on one side.
    /// The slice is then rebased, as the byte reader it replaces did — a `Data` with a nonzero
    /// `startIndex` indexes differently AND retains the whole datagram, and neither belongs in a
    /// value handed to the reassembler.
    public static func decode(_ datagram: Data) throws -> Self {
        var parsed = SlopDeskVideoFragmentHeader()
        let ok = datagram.withUnsafeBytes { bytes in
            slopdesk_video_fragment_decode(bytes.baseAddress, bytes.count, &parsed)
        }
        guard ok else { throw VideoProtocolError.truncated }
        let header = FrameFragmentHeader(
            streamSeq: parsed.stream_seq, frameID: parsed.frame_id, fragIndex: parsed.frag_index,
            fragCount: parsed.frag_count, flags: .init(rawValue: parsed.flags),
            payloadLength: parsed.payload_length, hostSendTsMillis: parsed.host_send_ts_millis,
        )
        // Copied out inside the borrow that validated it, for the reason the audio codec gives:
        // two intermediate `Data` values to describe bytes that are copied once anyway.
        let payload = datagram.withUnsafeBytes { bytes -> Data in
            let start = Int(parsed.payload_offset)
            return Data(UnsafeRawBufferPointer(rebasing: bytes[start..<start + Int(parsed.payload_length)]))
        }
        return Self(header: header, payload: payload)
    }
}

/// Fragments a NALU-bearing encoded frame into <=1200-byte datagrams (doc 17 §3.6).
///
/// The MTU split, the per-frame FEC group size, the parity append, the m-aware adaptive-FEC parity,
/// the optional burst-resilient interleave and the 19-byte header stamp all live in
/// `rust/slopdesk-video`'s `packetizer` — this type is the boundary to it, not a second copy of it.
/// `m == 1` (the production codec) is byte-identical to the legacy XOR/length-prefix wire.
///
/// ## Why a handle
/// Two counters outlive a call: `streamSeq` advances per datagram and `frameID` per frame, and the
/// host reads `frameID` BEFORE packetizing so it can record the frame's LTR token against the id the
/// frame is about to carry. They live in Rust, and this object holds the token — the convention
/// `docs/55` §4b describes, and the same one ``ReplayBuffer`` uses. Its obligation comes with it:
/// exactly one free per new (``deinit``), and no two calls on one handle may overlap.
///
/// Kept as a `final class` (not a value `struct`) so `packetize`/`packetizeRaw` are NON-mutating and
/// the host can hold it as a `let`. One per send loop, not thread-safe (the host actor serializes it,
/// which is also what discharges the no-overlap obligation); `@unchecked Sendable` to cross the actor
/// boundary like the prior shell.
public final class VideoPacketizer: @unchecked Sendable {
    /// Max UDP payload size (doc 17 §3.6: "<= 1200 bytes" to stay under typical MTU with WireGuard
    /// overhead). Asked for, not transcribed: every other codec on this socket sizes its own chunk
    /// by subtracting from this budget, so a raised copy here would reach the packetizer and none
    /// of them — and the first symptom is a fragmented datagram on the slowest link.
    public static let maxDatagramSize = slopdesk_video_fragment_size(1)
    /// Max payload bytes per fragment (datagram budget minus the header).
    public static let maxPayloadSize = slopdesk_video_fragment_size(2)

    /// Optional FEC scheme; when set, parity fragments are appended to each frame. Read by the host
    /// for ``FECScheme/groupSize``, and by ``init(fec:)`` for the shape the Rust codec is built at —
    /// the parity itself is computed inside the packetizer, not through this object.
    public let fec: FECScheme?

    /// The Rust packetizer: the MTU split, the parity, the interleave and both counters.
    private let handle: OpaquePointer

    public init(fec: FECScheme? = nil) {
        self.fec = fec
        // A null handle would mean a shape the code cannot exist in (`k + m > 255`), which no
        // configured scheme produces; the force is the assertion that nothing built one.
        guard let handle = slopdesk_video_packetizer_new(fec?.groupSize ?? 1, fec?.parityCount ?? 0)
        else { preconditionFailure("the FEC shape is one the erasure code cannot exist in") }
        self.handle = handle
    }

    deinit { slopdesk_video_packetizer_free(handle) }

    /// The `streamSeq` that the next emitted datagram will carry (for tests / acks). Pure read — does
    /// NOT advance the counter.
    public var peekNextStreamSeq: UInt32 { slopdesk_video_packetizer_peek_stream_seq(handle) }

    /// The `frameID` that the NEXT ``packetize(frame:keyframe:crisp:hostSendTsMillis:fecTier:isLTR:ackedAnchored:interleave:)``
    /// call will assign (mirror of ``peekNextStreamSeq``). The host actor reads this BEFORE
    /// packetizing so it can record the `frameID ↔ LTR-token` mapping for the frame about to be sent
    /// (`packetize` increments `nextFrameID`). Read in encode order on the actor. Pure read — does NOT
    /// advance the counter.
    public var peekNextFrameID: UInt32 { slopdesk_video_packetizer_peek_frame_id(handle) }

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
        // Parsed back out of the finished datagrams rather than built alongside them. The wire form
        // is what the packetizer produces and what the host sends; a second construction path here
        // would be a second implementation, and the two could then disagree. Nothing on the send
        // path takes this entry — it exists for the tools and the tests that want the fields named.
        packetizeRaw(
            frame: frame,
            keyframe: keyframe,
            crisp: crisp,
            hostSendTsMillis: hostSendTsMillis,
            fecTier: fecTier,
            isLTR: isLTR,
            ackedAnchored: ackedAnchored,
            interleave: interleave,
        ).compactMap { try? FrameFragment.decode($0) }
    }

    /// The send path: one encoded frame in, the finished wire datagrams out, in send order.
    ///
    /// The whole frame crosses once and the whole answer comes back once — the datagrams are born
    /// in Rust already stamped, so nothing here builds a payload copy per fragment on the way.
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
        var flags: UInt32 = 0
        if keyframe { flags |= Self.flagKeyframe }
        if crisp { flags |= Self.flagCrisp }
        if isLTR { flags |= Self.flagIsLTR }
        if ackedAnchored { flags |= Self.flagAckedAnchored }
        if interleave { flags |= Self.flagInterleave }
        // One call packetizes and parks the answer; the second copies it out. Splitting them is what
        // lets the answer be sized by the tier ladder rather than guessed at here — and the frame is
        // packetized once either way, so the counters cannot advance twice.
        let needed = frame.withUnsafeBytes { bytes in
            slopdesk_video_packetizer_raw(
                handle, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count,
                hostSendTsMillis, fecTier, flags,
            )
        }
        guard needed > 0 else { return [] }
        var written = 0
        let answer = [UInt8](unsafeUninitializedCapacity: needed) { buffer, count in
            written = slopdesk_video_packetizer_answer(handle, buffer.baseAddress, buffer.count)
            count = Swift.min(written, buffer.count)
        }
        guard written == needed else { return [] }
        return FECBlobList.decodeAll(answer) ?? []
    }

    /// The `flags` bitfield ``slopdesk_video_packetizer_raw`` takes — the booleans of
    /// `PacketizeOptions` (`rust/slopdesk-video/src/packetizer.rs`) on the other side, packed so the
    /// entry point stays one line wide.
    private static let flagKeyframe: UInt32 = 1 << 0
    private static let flagCrisp: UInt32 = 1 << 1
    private static let flagIsLTR: UInt32 = 1 << 2
    private static let flagAckedAnchored: UInt32 = 1 << 3
    private static let flagInterleave: UInt32 = 1 << 4
}
