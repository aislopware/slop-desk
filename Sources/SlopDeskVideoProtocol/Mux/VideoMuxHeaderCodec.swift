import Foundation

/// UDP-side mux foundation for the GUI video path (PATH 2): a `UInt32` BE channelID
/// PREFIX that lets several logical lanes share one physical UDP datagram socket the
/// way ``MuxEnvelopeCodec`` lets several channels share one TCP connection.
///
/// This is a **NEW, additive** type living BESIDE the existing
/// ``FrameFragmentHeader`` / ``FrameFragment`` (15-byte header) — it does NOT replace
/// them. The 15→19-byte header swap (folding the channelID into the per-fragment
/// header) is a LATER gated migration stage; for now nothing on the live transport
/// constructs these types, so a single-pane run is byte-identical to today.
///
/// Two shapes are provided, both reusing the existing
/// ``Data/appendBE(_:)-(UInt32)`` writer + ``VideoByteReader`` reader so the bytes are
/// alignment-safe and endian-explicit, exactly like ``FrameFragment``:
///
/// 1. ``VideoMuxHeaderCodec`` — a bare `[UInt32 BE channelID][rest...]` prefix for the
///    non-video media lanes (control / geometry) and the cursor socket. The `rest` is
///    an opaque payload carried verbatim — the codec never inspects it (mirroring
///    `MuxEnvelopeCodec.channelData`, which carries its inner ``WireMessage`` opaquely).
/// 2. ``MuxFrameFragmentHeader`` — the existing ``FrameFragmentHeader`` fields PLUS a
///    `channelID` at offset 0, for the high-rate video lane that wants the channel id
///    folded into the per-fragment header rather than a separate prefix. Layout:
///    ```
///    off 0:  UInt32 channelID   — the logical lane this fragment belongs to
///    off 4:  UInt32 streamSeq   — monotonic per-datagram sequence number
///    off 8:  UInt32 frameID     — groups fragments of one encoded video frame
///    off12:  UInt16 fragIndex   — 0-based index of this fragment within the frame
///    off14:  UInt16 fragCount   — total fragments in the frame
///    off16:  UInt8  flags       — bit0 keyframe(IDR), bit1 parity(FEC), bit2 crisp
///    off17:  UInt16 payloadLen  — bytes of payload that follow
///    ```
///    = **19-byte header** (the existing 15 + the 4-byte channelID prefix).
public enum VideoMuxHeaderCodec {
    /// Length of the big-endian `UInt32` channelID prefix that fronts a muxed datagram.
    public static let channelIDLength = 4

    /// Prepends `channelID` to an opaque media/cursor payload:
    /// `[UInt32 BE channelID][payload...]`. The `payload` is carried verbatim.
    public static func encode(channelID: UInt32, payload: Data) -> Data {
        var out = Data(capacity: channelIDLength + payload.count)
        out.appendBE(channelID)
        out.append(payload)
        return out
    }

    /// Splits a muxed datagram into its leading `channelID` and the opaque remainder.
    ///
    /// - Throws: ``VideoProtocolError/truncated`` if fewer than 4 bytes are present (a
    ///   corrupt single datagram must never crash the receiver — same contract as
    ///   ``FrameFragment/decode(_:)``).
    public static func decode(_ datagram: Data) throws -> (channelID: UInt32, payload: Data) {
        var reader = VideoByteReader(datagram)
        let channelID = try reader.readUInt32()
        return (channelID, reader.remaining())
    }
}

/// A ``FrameFragmentHeader`` carrying its logical lane's `channelID` at offset 0.
///
/// This is the muxed (19-byte) sibling of the existing 15-byte
/// ``FrameFragmentHeader``; the non-channelID fields and their meanings are identical
/// (reused verbatim so the two stay in lock-step). It is additive: the live video
/// transport still emits the 15-byte header until the gated migration flips over.
public struct MuxFrameFragmentHeader: Equatable, Sendable {
    /// The logical lane this fragment belongs to (offset 0).
    public var channelID: UInt32
    public var streamSeq: UInt32
    public var frameID: UInt32
    public var fragIndex: UInt16
    public var fragCount: UInt16
    public var flags: FrameFragmentHeader.Flags
    public var payloadLength: UInt16

    public init(
        channelID: UInt32,
        streamSeq: UInt32,
        frameID: UInt32,
        fragIndex: UInt16,
        fragCount: UInt16,
        flags: FrameFragmentHeader.Flags,
        payloadLength: UInt16,
    ) {
        self.channelID = channelID
        self.streamSeq = streamSeq
        self.frameID = frameID
        self.fragIndex = fragIndex
        self.fragCount = fragCount
        self.flags = flags
        self.payloadLength = payloadLength
    }

    /// Header size in bytes = the existing ``FrameFragmentHeader/size`` (15) plus the
    /// 4-byte channelID prefix = **19**.
    public static let size = VideoMuxHeaderCodec.channelIDLength + FrameFragmentHeader.size

    /// Max payload bytes per fragment when the channelID is folded into the header
    /// (datagram budget minus the 19-byte header). Mirrors
    /// ``VideoPacketizer/maxPayloadSize`` but against the larger muxed header.
    public static let maxPayloadSize = VideoPacketizer.maxDatagramSize - size

    /// Serialises `header + payload` (channelID first, then the existing field order).
    public func encode(payload: Data) -> Data {
        var out = Data(capacity: Self.size + payload.count)
        out.appendBE(channelID)
        out.appendBE(streamSeq)
        out.appendBE(frameID)
        out.appendBE(fragIndex)
        out.appendBE(fragCount)
        out.append(flags.rawValue)
        out.appendBE(UInt16(payload.count))
        out.append(payload)
        return out
    }

    /// Parses one muxed datagram into `(header, payload)`. Throws
    /// ``VideoProtocolError/truncated`` on a short/inconsistent datagram (a corrupt
    /// single packet must not crash the receiver — same contract as
    /// ``FrameFragment/decode(_:)``).
    public static func decode(_ datagram: Data) throws -> (header: Self, payload: Data) {
        var reader = VideoByteReader(datagram)
        let channelID = try reader.readUInt32()
        let streamSeq = try reader.readUInt32()
        let frameID = try reader.readUInt32()
        let fragIndex = try reader.readUInt16()
        let fragCount = try reader.readUInt16()
        let flags = try FrameFragmentHeader.Flags(rawValue: reader.readUInt8())
        let payloadLength = try reader.readUInt16()
        let payload = try reader.readBytes(Int(payloadLength))
        let header = Self(
            channelID: channelID, streamSeq: streamSeq, frameID: frameID,
            fragIndex: fragIndex, fragCount: fragCount, flags: flags, payloadLength: payloadLength,
        )
        return (header, payload)
    }
}
