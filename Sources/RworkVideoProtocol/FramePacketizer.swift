import Foundation

/// Per-datagram header for the video stream (UDP). Fixed 12 bytes, big-endian.
///
/// Wire layout:
/// ```
/// [UInt32 streamSeq][UInt32 frameID][UInt16 fragIndex][UInt8 flags][UInt8 fragCount-hi/lo...]
/// ```
/// To keep `fragCount` able to exceed 255 we spend a `UInt16` on it as well, so the
/// concrete layout is:
/// ```
/// off 0: UInt32 streamSeq   — monotonic per-datagram sequence number (loss/order)
/// off 4: UInt32 frameID     — groups fragments of one encoded video frame
/// off 8: UInt16 fragIndex   — 0-based index of this fragment within the frame
/// off10: UInt16 fragCount   — total fragments in the frame
/// off12: UInt8  flags       — bit0 keyframe(IDR), bit1 parity(FEC), bit2 crisp(Session B)
/// off13: UInt16 payloadLen  — bytes of payload that follow (defensive; UDP also bounds it)
/// ```
/// = **15-byte header**. The MTU budget (`VideoPacketizer.maxDatagramSize` = 1200,
/// doc 17 §3.6 "datagrams <= 1200 bytes") minus the header gives the payload cap.
public struct FrameFragmentHeader: Equatable, Sendable {
    public struct Flags: OptionSet, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        /// This frame is a keyframe (IDR) — a fresh decode anchor.
        public static let keyframe = Flags(rawValue: 1 << 0)
        /// This fragment is an FEC parity fragment, not original data.
        public static let parity = Flags(rawValue: 1 << 1)
        /// This frame came from the on-demand crisp encoder (Session B, all-intra).
        public static let crisp = Flags(rawValue: 1 << 2)
    }

    public var streamSeq: UInt32
    public var frameID: UInt32
    public var fragIndex: UInt16
    public var fragCount: UInt16
    public var flags: Flags
    public var payloadLength: UInt16

    public init(streamSeq: UInt32, frameID: UInt32, fragIndex: UInt16, fragCount: UInt16, flags: Flags, payloadLength: UInt16) {
        self.streamSeq = streamSeq
        self.frameID = frameID
        self.fragIndex = fragIndex
        self.fragCount = fragCount
        self.flags = flags
        self.payloadLength = payloadLength
    }

    /// Header size in bytes.
    public static let size = 15
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
        let payloadLength = try reader.readUInt16()
        let payload = try reader.readBytes(Int(payloadLength))
        let header = FrameFragmentHeader(
            streamSeq: streamSeq, frameID: frameID, fragIndex: fragIndex,
            fragCount: fragCount, flags: flags, payloadLength: payloadLength
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

    /// Fragments one encoded frame (an AVCC byte buffer) into data fragments,
    /// followed by FEC parity fragments if a scheme is configured.
    ///
    /// - Parameters:
    ///   - frame: the AVCC bytes (length-prefixed NAL units) of one encoded frame.
    ///   - keyframe: whether this is an IDR (sets the keyframe flag).
    ///   - crisp: whether this frame is from the crisp Session-B encoder.
    /// - Returns: data fragments + parity fragments, in send order.
    public mutating func packetize(frame: Data, keyframe: Bool, crisp: Bool = false) -> [FrameFragment] {
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

        let parityPayloads = fec?.parity(forDataFragments: payloads) ?? []
        let fragCount = UInt16(payloads.count + parityPayloads.count)

        var baseFlags: FrameFragmentHeader.Flags = []
        if keyframe { baseFlags.insert(.keyframe) }
        if crisp { baseFlags.insert(.crisp) }

        var fragments: [FrameFragment] = []
        fragments.reserveCapacity(payloads.count + parityPayloads.count)
        var fragIndex: UInt16 = 0
        for payload in payloads {
            fragments.append(makeFragment(frameID: frameID, fragIndex: fragIndex, fragCount: fragCount, flags: baseFlags, payload: payload))
            fragIndex += 1
        }
        for payload in parityPayloads {
            var flags = baseFlags
            flags.insert(.parity)
            fragments.append(makeFragment(frameID: frameID, fragIndex: fragIndex, fragCount: fragCount, flags: flags, payload: payload))
            fragIndex += 1
        }
        return fragments
    }

    private mutating func makeFragment(frameID: UInt32, fragIndex: UInt16, fragCount: UInt16, flags: FrameFragmentHeader.Flags, payload: Data) -> FrameFragment {
        let seq = nextStreamSeq
        nextStreamSeq &+= 1
        let header = FrameFragmentHeader(
            streamSeq: seq, frameID: frameID, fragIndex: fragIndex,
            fragCount: fragCount, flags: flags, payloadLength: UInt16(payload.count)
        )
        return FrameFragment(header: header, payload: payload)
    }
}
