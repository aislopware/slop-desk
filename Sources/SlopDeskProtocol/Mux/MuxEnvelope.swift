import CSlopDeskFFI
import Foundation
import SlopDeskArena

/// The frame types carried by the TCP mux envelope.
///
/// The mux layer multiplexes many logical channels over one physical TCP
/// connection (SSH-style: `CHANNEL_OPEN` / `CHANNEL_DATA` / `CHANNEL_CLOSE` /
/// `CHANNEL_WINDOW_ADJUST`). One byte selects the frame's meaning; the body layout
/// depends on the type. See ``MuxEnvelopeCodec`` for the wire layout.
public enum MuxFrameType: UInt8, Sendable, Equatable, CaseIterable {
    /// Initiator asks to open a new logical channel. Body =
    /// `[16-byte sessionUUID][Int64 BE lastReceivedSeq][UInt8 channelClass][optional UInt16 cwdLen][cwd UTF-8]`.
    case channelOpen = 1
    /// Responder accepts (or refuses) a channel open. Body =
    /// `[UInt8 accepted][Int64 BE resumeFromSeq]` — `resumeFromSeq` is the HOST-authoritative
    /// resume verdict (0 = fresh shell / nothing resumed; > 0 = the SAME live session was
    /// reattached and the replay starts after this seq). Decode tolerates the field's absence
    /// (pre-resume encoders) as 0.
    case channelOpenAck = 2
    /// Opaque application payload for an open channel. Body is a passed-through
    /// ``WireMessage`` frame — the mux layer does **not** parse it.
    case channelData = 3
    /// One side is done sending on the channel (SSH `CHANNEL_CLOSE`). Body =
    /// `[optional UInt8 reason]` — a ``MuxCloseReason``, absent for the default `.retired`.
    case channelClose = 4
    /// Replenish a channel's flow-control window (SSH `CHANNEL_WINDOW_ADJUST`).
    /// Body = `[UInt32 BE bytesToAdd]`.
    case windowAdjust = 5
}

/// WHY a peer closed one channel — the half of a `channelClose` that decides what the other end may
/// do next.
///
/// Above the transport a close is a stream that ended, and the two reasons a host closes a PANE
/// channel demand opposite answers. `MuxSubChannel.closedByPeer` records that the FRAME arrived;
/// this records what the frame meant, and it has to ride the wire because only the sender knows.
///
/// The reason is ADVICE about recovery, never permission to skip the teardown: every value closes
/// the channel identically. So an absent body and an unrecognised byte both read as ``retired`` —
/// the conservative reading, which withholds the automatic re-dial rather than inventing one.
public enum MuxCloseReason: UInt8, Sendable, Equatable, CaseIterable {
    /// The channel names something the peer no longer has: the document reaped the pane, or this
    /// side is done with it. Re-opening under the same session id is a fresh SPAWN, so nothing
    /// automatic may dial it again — recovery is an explicit user re-dial.
    case retired = 0
    /// Only THIS subscriber's attachment ended — the pane, its shell and its other members are
    /// untouched (`HostServer.wireSubscriberEviction`: a laggard removed to protect the session).
    /// Re-opening resumes a session the host still holds, so it is a reattach rather than a spawn;
    /// what it must not be is a reflex, because an instant re-dial re-joins to be evicted again.
    case subscriberEvicted = 1
}

/// One decoded TCP mux frame.
///
/// Wire layout of a mux frame is
/// `[UInt32 BE muxFrameLength][UInt32 BE channelID][UInt8 muxType][body...]`
/// where `muxFrameLength` counts `channelID` + `muxType` + `body` (it excludes the
/// 4-byte length prefix). All multi-byte integers are big-endian. This mirrors the
/// terminal ``WireMessage`` frame (`[UInt32 BE payloadLength][UInt8 messageType][body]`)
/// one level up: the mux envelope is the OUTER frame, and a `channelData` body is an
/// INNER ``WireMessage`` frame that is carried opaquely.
///
/// `MuxFrame` is `Sendable` so decoded frames can cross actor / task boundaries (the
/// TCP receive loop hands them to per-channel consumers).
public enum MuxFrame: Equatable, Sendable {
    /// `channelOpen`: open `channelID` carrying a resume hint, class selector, and optional initial cwd.
    case channelOpen(
        channelID: UInt32,
        sessionID: UUID,
        lastReceivedSeq: Int64,
        channelClass: UInt8,
        initialCwd: String?,
    )
    /// `channelOpenAck`: `accepted` true if the responder will service the channel;
    /// `resumeFromSeq` is the host-authoritative resume verdict (see ``MuxFrameType/channelOpenAck``).
    case channelOpenAck(channelID: UInt32, accepted: Bool, resumeFromSeq: Int64)
    /// `channelData`: OPAQUE inner ``WireMessage`` frame bytes for `channelID`.
    case channelData(channelID: UInt32, payload: Data)
    /// `channelClose`: this side will send no more frames on `channelID`. `reason` is the peer's
    /// statement of WHY (see ``MuxCloseReason``); it defaults to `.retired`, which is the shape and
    /// the bytes a close has always had.
    case channelClose(channelID: UInt32, reason: MuxCloseReason = .retired)
    /// `windowAdjust`: grant `bytesToAdd` more flow-control credit on `channelID`.
    case windowAdjust(channelID: UInt32, bytesToAdd: UInt32)

    /// The logical channel this frame addresses.
    public var channelID: UInt32 {
        switch self {
        case let .channelOpen(channelID, _, _, _, _): channelID
        case let .channelOpenAck(channelID, _, _): channelID
        case let .channelData(channelID, _): channelID
        case let .channelClose(channelID, _): channelID
        case let .windowAdjust(channelID, _): channelID
        }
    }

    /// The on-wire mux-type byte for this frame.
    public var muxType: MuxFrameType {
        switch self {
        case .channelOpen: .channelOpen
        case .channelOpenAck: .channelOpenAck
        case .channelData: .channelData
        case .channelClose: .channelClose
        case .windowAdjust: .windowAdjust
        }
    }
}

/// Encodes / decodes the TCP mux envelope
/// (`[UInt32 BE muxFrameLength][UInt32 BE channelID][UInt8 muxType][body...]`).
///
/// The layout lives in `rust/slopdesk-wire`'s `mux::envelope`, which the video path, the golden
/// corpus and this door all read from. What is here is the flattening: a `MuxFrame` becomes one
/// `#[repr(C)]` struct plus, at most, a cwd — and `channelData`'s payload is passed WHOLE, never
/// through the struct, because it is the one field a copy is felt on.
public enum MuxEnvelopeCodec {
    /// Length of the big-endian `UInt32` mux-frame-length prefix.
    static let prefixLength = slopdesk_mux_envelope_constant(1)

    /// Encodes a frame into the complete mux envelope, ready to write to a socket:
    /// `[UInt32 BE muxFrameLength][UInt32 BE channelID][UInt8 muxType][body...]`.
    ///
    /// `muxFrameLength` counts `channelID` + `muxType` + `body` and excludes the
    /// 4-byte prefix — exactly what ``MuxFrameDecoder`` expects.
    public static func encode(_ frame: MuxFrame) -> Data {
        var flat = SlopDeskMuxFrame()
        var arena = Data()
        let payload = frame.flatten(into: &flat, arena: &arena)
        return withUnsafePointer(to: flat) { frame in
            arena.spanning { pool, poolLength in
                payload.spanning { body, bodyLength in
                    let bound = slopdesk_mux_frame_byte_count(frame, pool, poolLength, bodyLength)
                    precondition(bound > 0, "the mux codec refused a frame this type can express")
                    return WireBuffer.filled(bound) { out in
                        let written = slopdesk_mux_frame_encode(
                            frame, pool, poolLength, body, bodyLength, out, bound,
                        )
                        precondition(written == bound, "the mux codec sized a frame differently than it wrote it")
                    }
                }
            }
        }
    }

    /// Decodes a frame from a **complete inner run** (`[channelID][muxType][body...]`,
    /// without the length prefix — framing is handled by ``MuxFrameDecoder``).
    ///
    /// - Throws: ``SlopDeskError/truncated`` if the body is shorter than the mux type
    ///   requires, ``SlopDeskError/unknownMessageType(_:)`` for an unrecognized mux-type
    ///   byte, or ``SlopDeskError/malformedBody(_:)`` for a right-length-but-invalid body
    ///   (e.g. bad sessionID bytes).
    public static func decode(inner: Data) throws -> MuxFrame {
        // A cwd is the only text a mux envelope carries, and a path fits this. The retry is not a
        // guess: a refusal reports what would have fitted.
        if let frame = try attempt(inner, room: 1024) { return frame }
        guard let frame = try attempt(inner, room: reportedRoom) else { throw SlopDeskError.truncated }
        return frame
    }

    /// How much arena the last refusal asked for. Written and read on the one thread a decode runs
    /// on — a retry immediately follows its own refusal.
    private nonisolated(unsafe) static var reportedRoom = 0

    /// One decode into an arena of `room` bytes; `nil` means the arena was too small and
    /// ``reportedRoom`` now holds the size that fits.
    private static func attempt(_ inner: Data, room: Int) throws -> MuxFrame? {
        var flat = SlopDeskMuxFrame()
        var verdict = UInt32(SLOPDESK_WIRE_DECODE_OK)
        var built: MuxFrame?
        try inner.spanning { bytes, length in
            withUnsafeTemporaryAllocation(byteCount: max(room, 1), alignment: 1) { arena in
                verdict = slopdesk_mux_frame_decode(
                    bytes?.assumingMemoryBound(to: UInt8.self), length,
                    &flat, arena.baseAddress?.assumingMemoryBound(to: UInt8.self), arena.count,
                )
                guard verdict == UInt32(SLOPDESK_WIRE_DECODE_OK) else { return }
                // The payload span points into the run the caller passed in, so the copy this path
                // makes is the one Foundation makes lazily: a `Data` built from a slice of another
                // `Data` shares its backing. Copying the bytes eagerly into a fresh buffer measured
                // 1.16 µs against 879 ns at 32 KiB — the eager copy is a copy the caller may never
                // need.
                let start = inner.startIndex + Int(flat.payload_offset)
                let payload = flat.payload_length > 0
                    ? Data(inner[start..<start + Int(flat.payload_length)])
                    : Data()
                built = MuxFrame.build(flat, UnsafeRawBufferPointer(arena), payload)
            }
            if verdict == UInt32(SLOPDESK_WIRE_DECODE_AGAIN) {
                // The refusal carries no length of its own: the frame is whole, so the cwd cannot be
                // longer than the run that held it.
                reportedRoom = length
                return
            }
            try throwIfFaulted(verdict, in: inner)
        }
        return built
    }

    /// Turns a decode verdict into the error the Swift callers already catch. The type byte is read
    /// out of the run rather than the struct: a refused frame is a frame that was never built.
    private static func throwIfFaulted(_ verdict: UInt32, in inner: Data) throws {
        let typeIndex = inner.startIndex + prefixLength
        let type = inner.indices.contains(typeIndex) ? inner[typeIndex] : 0
        switch verdict {
        case UInt32(SLOPDESK_WIRE_DECODE_TRUNCATED):
            throw SlopDeskError.truncated
        case UInt32(SLOPDESK_WIRE_DECODE_UNKNOWN_TYPE):
            throw SlopDeskError.unknownMessageType(type)
        case UInt32(SLOPDESK_WIRE_DECODE_MALFORMED):
            throw SlopDeskError.malformedBody("mux type \(type): body is not what its type declares")
        default:
            break
        }
    }
}

// MARK: - Crossing

extension MuxFrame {
    /// Spreads the frame onto the flat struct plus, at most, a cwd — and hands the opaque payload
    /// back rather than interning it, so a `.channelData` body crosses as itself.
    func flatten(into flat: inout SlopDeskMuxFrame, arena: inout Data) -> Data {
        flat.channel_id = channelID
        flat.mux_type = muxType.rawValue
        switch self {
        case let .channelOpen(_, sessionID, lastReceivedSeq, channelClass, initialCwd):
            flat.session_id = sessionID.uuid
            flat.last_received_seq = lastReceivedSeq
            flat.channel_class = channelClass
            if let initialCwd {
                arena = Data(initialCwd.utf8)
                flat.has_cwd = true
                flat.cwd_length = UInt32(arena.count)
            }
        case let .channelOpenAck(_, accepted, resumeFromSeq):
            flat.accepted = accepted
            flat.resume_from_seq = resumeFromSeq
        case let .channelData(_, payload):
            return payload
        case let .channelClose(_, reason):
            flat.reason = reason.rawValue
        case let .windowAdjust(_, bytesToAdd):
            flat.bytes_to_add = bytesToAdd
        }
        return Data()
    }

    /// Rebuilds a frame from the flat struct, its arena, and the opaque payload already lifted out
    /// of wherever it sat. Unknown mux types never reach here — the decode refused them.
    static func build(
        _ flat: SlopDeskMuxFrame, _ arena: UnsafeRawBufferPointer, _ payload: Data,
    ) -> MuxFrame? {
        let channelID = flat.channel_id
        switch flat.mux_type {
        case MuxFrameType.channelOpen.rawValue:
            return .channelOpen(
                channelID: channelID,
                sessionID: UUID(uuid: flat.session_id),
                lastReceivedSeq: flat.last_received_seq,
                channelClass: flat.channel_class,
                initialCwd: flat.has_cwd
                    ? text(arena, flat.cwd_offset, flat.cwd_length)
                    : nil,
            )
        case MuxFrameType.channelOpenAck.rawValue:
            return .channelOpenAck(
                channelID: channelID, accepted: flat.accepted, resumeFromSeq: flat.resume_from_seq,
            )
        case MuxFrameType.channelData.rawValue:
            return .channelData(channelID: channelID, payload: payload)
        case MuxFrameType.channelClose.rawValue:
            return .channelClose(
                channelID: channelID, reason: MuxCloseReason(rawValue: flat.reason) ?? .retired,
            )
        default:
            return .windowAdjust(channelID: channelID, bytesToAdd: flat.bytes_to_add)
        }
    }

    /// A text field, read out of the arena the decode filled.
    private static func text(_ arena: UnsafeRawBufferPointer, _ offset: UInt32, _ length: UInt32) -> String {
        ArenaText.text(arena, offset, length)
    }
}
