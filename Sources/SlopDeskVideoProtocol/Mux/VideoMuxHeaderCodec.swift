import CSlopDeskFFI
import Foundation

/// UDP-side mux foundation for the GUI video path (PATH 2): a `UInt32` BE channelID
/// PREFIX that lets several logical lanes share one physical UDP datagram socket the
/// way PATH-1's envelope prefix lets several channels share one TCP connection (that codec is
/// `rust/slopdesk-wire`'s `mux::envelope` — `docs/63` G.3 took the Swift one).
///
/// This is a **NEW, additive** type living BESIDE the existing
/// ``FrameFragmentHeader`` / ``FrameFragment`` (19-byte header) — it does NOT replace
/// them. The channelID fold (moving the lane into the per-fragment header) is a LATER
/// gated migration stage; for now nothing on the live transport constructs
/// ``MuxFrameFragmentHeader``, so a single-pane run is byte-identical to today.
///
/// Two shapes, both `rust/slopdesk-video`'s `mux_header`:
///
/// 1. ``VideoMuxHeaderCodec`` — a bare `[UInt32 BE channelID][rest...]` prefix for the
///    non-video media lanes (control / geometry) and the cursor socket. The `rest` is
///    an opaque payload carried verbatim — the codec never inspects it (mirroring
///    PATH-1's `channelData`, which carries its inner ``WireMessage`` opaquely).
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
///    = **19 bytes**, the same width as ``FrameFragmentHeader`` and a DIFFERENT layout:
///    that one spends its last four bytes on `hostSendTsMillis`, this one spends its
///    first four on the lane. Reading either with the other's decoder parses cleanly and
///    produces nonsense, so the widths matching is a coincidence, not a compatibility.
///
/// The framing is written straight into the buffer that carries it: the answer is the
/// payload with four bytes in front, so an encoder that built its own would copy every
/// datagram twice to prepend a lane.
public enum VideoMuxHeaderCodec {
    /// Length of the big-endian `UInt32` channelID prefix that fronts a muxed datagram.
    public static let channelIDLength = slopdesk_mux_constant(0)

    /// Prepends `channelID` to an opaque media/cursor payload:
    /// `[UInt32 BE channelID][payload...]`. The `payload` is carried verbatim.
    public static func encode(channelID: UInt32, payload: Data) -> Data {
        frame(channelID: channelID, tag: nil, payload: payload)
    }

    /// Frames a MEDIA-socket datagram in ONE allocation:
    /// `[UInt32 BE channelID][UInt8 tag][payload...]`.
    ///
    /// Byte-identical to `encode(channelID:payload:)` over an intermediate
    /// `[tag][payload]` buffer (the shape both transports previously built by hand),
    /// minus that intermediate copy — the `payload` bytes are appended exactly once.
    /// Pinned against independent manual construction in
    /// `VideoMuxHeaderCodecTests.testMediaSendShapePinsManualWireBytes`.
    public static func encodeMedia(channelID: UInt32, tag: UInt8, payload: Data) -> Data {
        frame(channelID: channelID, tag: tag, payload: payload)
    }

    /// Both shapes, which differ by one byte in one place. The size is known before the call — a
    /// lane, maybe a tag, then the payload — so the buffer is allocated once and filled once.
    private static func frame(channelID: UInt32, tag: UInt8?, payload: Data) -> Data {
        let needed = channelIDLength + (tag == nil ? 0 : 1) + payload.count
        var out = Data(count: needed)
        let written = out.withUnsafeMutableBytes { buffer in
            payload.withUnsafeBytes { source in
                slopdesk_mux_encode(
                    channelID, tag != nil, tag ?? 0,
                    source.baseAddress, source.count,
                    buffer.baseAddress, buffer.count,
                )
            }
        }
        precondition(written == needed, "the mux codec and its own prefix width disagree")
        return out
    }

    /// Splits a muxed datagram into its leading `channelID` and the opaque remainder.
    ///
    /// - Throws: ``VideoProtocolError/truncated`` if fewer than 4 bytes are present (a
    ///   corrupt single datagram must never crash the receiver — same contract as
    ///   ``FrameFragment/decode(_:)``).
    public static func decode(_ datagram: Data) throws -> (channelID: UInt32, payload: Data) {
        var channelID: UInt32 = 0
        let offset = datagram.withUnsafeBytes { bytes in
            slopdesk_mux_decode(bytes.baseAddress, bytes.count, &channelID)
        }
        guard offset > 0 else { throw VideoProtocolError.truncated }
        // Rebased, not sliced: a `Data` slice indexes from the parent's start and holds the parent
        // buffer alive, and this payload outlives the datagram it came out of.
        return (channelID, Data(datagram.dropFirst(offset)))
    }
}

/// A ``FrameFragmentHeader`` carrying its logical lane's `channelID` at offset 0.
///
/// This is the muxed sibling of the existing ``FrameFragmentHeader``; the non-channelID
/// fields and their meanings are identical (shared verbatim so the two stay in
/// lock-step). It is additive: the live video transport still emits the plain header
/// until the gated migration flips over.
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

    /// Header size in bytes: channelID(4) + streamSeq(4) + frameID(4) + fragIndex(2)
    /// + fragCount(2) + flags(1) + payloadLen(2) = **19**. It does NOT carry
    /// ``FrameFragmentHeader/hostSendTsMillis`` — see the layout in the type doc above.
    /// Vended by the codec that writes it, so there is no second place to get it wrong.
    public static let size = slopdesk_mux_constant(1)

    /// Max payload bytes per fragment when the channelID is folded into the header
    /// (datagram budget minus the 19-byte header). Mirrors
    /// ``VideoPacketizer/maxPayloadSize`` but against the muxed header.
    public static let maxPayloadSize = slopdesk_mux_constant(2)

    /// Serialises `header + payload` (channelID first, then the existing field order).
    public func encode(payload: Data) -> Data {
        let needed = Self.size + payload.count
        var out = Data(count: needed)
        let written = out.withUnsafeMutableBytes { buffer in
            payload.withUnsafeBytes { source in
                slopdesk_mux_fragment_encode(
                    channelID, streamSeq, frameID, fragIndex, fragCount, flags.rawValue,
                    source.baseAddress, source.count, buffer.baseAddress, buffer.count,
                )
            }
        }
        precondition(written == needed, "the muxed codec and its own header size disagree")
        return out
    }

    /// Parses one muxed datagram into `(header, payload)`. Throws
    /// ``VideoProtocolError/truncated`` on a short/inconsistent datagram (a corrupt
    /// single packet must not crash the receiver — same contract as
    /// ``FrameFragment/decode(_:)``).
    public static func decode(_ datagram: Data) throws -> (header: Self, payload: Data) {
        var parsed = SlopDeskMuxFragmentHeader()
        let ok = datagram.withUnsafeBytes { bytes in
            slopdesk_mux_fragment_decode(bytes.baseAddress, bytes.count, &parsed)
        }
        guard ok else { throw VideoProtocolError.truncated }
        let header = Self(
            channelID: parsed.channel_id, streamSeq: parsed.stream_seq, frameID: parsed.frame_id,
            fragIndex: parsed.frag_index, fragCount: parsed.frag_count,
            flags: FrameFragmentHeader.Flags(rawValue: parsed.flags),
            payloadLength: parsed.payload_length,
        )
        // Rebased for the same reason `VideoMuxHeaderCodec.decode` rebases.
        let span = datagram.dropFirst(Int(parsed.payload_offset)).prefix(Int(parsed.payload_length))
        return (header, Data(span))
    }
}
