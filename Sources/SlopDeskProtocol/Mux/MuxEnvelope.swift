import Foundation

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
/// Like ``WireMessage`` this is a manual big-endian binary codec (never JSON /
/// `Codable`) reusing the same ``Data/appendBE(_:)-(UInt32)`` helpers and
/// ``BigEndianReader``. `channelData` bodies are carried byte-for-byte: the codec
/// never inspects them.
public enum MuxEnvelopeCodec {
    /// Length of the big-endian `UInt32` mux-frame-length prefix.
    static let prefixLength = 4
    /// Length of the big-endian `UInt32` channelID field.
    static let channelIDLength = 4
    /// Number of bytes occupied by a session UUID on the wire (its 16 raw bytes),
    /// matching ``WireMessage/sessionIDByteCount``.
    static let sessionIDByteCount = 16
    /// Smallest legal `muxFrameLength`: channelID (4) + muxType (1). The shortest
    /// frames (`channelClose`) have an empty body.
    static let minMuxFrameLength = channelIDLength + 1

    /// Encodes a frame into the complete mux envelope, ready to write to a socket:
    /// `[UInt32 BE muxFrameLength][UInt32 BE channelID][UInt8 muxType][body...]`.
    ///
    /// `muxFrameLength` counts `channelID` + `muxType` + `body` and excludes the
    /// 4-byte prefix — exactly what ``MuxFrameDecoder`` expects.
    public static func encode(_ frame: MuxFrame) -> Data {
        // Build the whole envelope in ONE buffer: a 4-byte muxFrameLength placeholder, then the inner
        // run [channelID][muxType][body…], then BACK-PATCH the prefix. A separate `inner` Data would
        // force an extra whole-payload copy — the up-to-128 KiB `.channelData` payload under a flood
        // would get memcpy'd twice (once into `inner`, once into the final buffer) for no reason.
        var out = Data()
        out.append(contentsOf: [0, 0, 0, 0]) // muxFrameLength placeholder (back-patched below)
        out.appendBE(frame.channelID)
        out.append(frame.muxType.rawValue)

        switch frame {
        case let .channelOpen(_, sessionID, lastReceivedSeq, channelClass, initialCwd):
            out.append(sessionID.dataBytes)
            out.appendBE(lastReceivedSeq)
            out.append(channelClass)
            if let initialCwd {
                let cwdBytes = clampedUTF8(initialCwd)
                out.appendBE(UInt16(cwdBytes.count))
                out.append(contentsOf: cwdBytes)
            }

        case let .channelOpenAck(_, accepted, resumeFromSeq):
            out.append(accepted ? 1 : 0)
            out.appendBE(resumeFromSeq)

        case let .channelData(_, payload):
            out.append(payload) // opaque — carried verbatim

        case let .channelClose(_, reason):
            // `.retired` is the ABSENT body — the empty-bodied close every peer has always sent, so
            // the default path stays byte-identical and only a close that means something else
            // costs a byte. The decoder reads the absence back as `.retired`.
            if reason != .retired { out.append(reason.rawValue) }

        case let .windowAdjust(_, bytesToAdd):
            out.appendBE(bytesToAdd)
        }

        // muxFrameLength counts the inner run [channelID][muxType][body] — everything after the 4-byte
        // prefix.
        let innerLength = UInt32(out.count - prefixLength)
        let s = out.startIndex
        out[s] = UInt8(truncatingIfNeeded: innerLength >> 24)
        out[s + 1] = UInt8(truncatingIfNeeded: innerLength >> 16)
        out[s + 2] = UInt8(truncatingIfNeeded: innerLength >> 8)
        out[s + 3] = UInt8(truncatingIfNeeded: innerLength)
        return out
    }

    /// Decodes a frame from a **complete inner run** (`[channelID][muxType][body...]`,
    /// without the length prefix — framing is handled by ``MuxFrameDecoder``).
    ///
    /// - Throws: ``SlopDeskError/truncated`` if the body is shorter than the mux type
    ///   requires, ``SlopDeskError/unknownMessageType(_:)`` for an unrecognized mux-type
    ///   byte, or ``SlopDeskError/malformedBody(_:)`` for a right-length-but-invalid body
    ///   (e.g. bad sessionID bytes).
    public static func decode(inner: Data) throws -> MuxFrame {
        var reader = BigEndianReader(inner)
        let channelID = try reader.readUInt32()
        let typeByte = try reader.readUInt8()
        guard let type = MuxFrameType(rawValue: typeByte) else {
            throw SlopDeskError.unknownMessageType(typeByte)
        }

        switch type {
        case .channelOpen:
            let idBytes = try reader.readBytes(sessionIDByteCount)
            let lastReceivedSeq = try reader.readInt64()
            let channelClass = try reader.readUInt8()
            guard let sessionID = UUID(dataBytes: idBytes) else {
                throw SlopDeskError.malformedBody("channelOpen: invalid sessionID bytes")
            }
            let initialCwd: String?
            if reader.bytesRemaining == 0 {
                initialCwd = nil
            } else {
                let length = try Int(reader.readUInt16())
                let bytes = try reader.readBytes(length)
                guard reader.bytesRemaining == 0 else {
                    throw SlopDeskError.malformedBody("channelOpen: trailing cwd bytes")
                }
                if length == 0 {
                    initialCwd = nil
                } else if let decoded = String(data: bytes, encoding: .utf8) {
                    initialCwd = decoded
                } else {
                    throw SlopDeskError.malformedBody("channelOpen: invalid cwd UTF-8")
                }
            }
            return .channelOpen(
                channelID: channelID,
                sessionID: sessionID,
                lastReceivedSeq: lastReceivedSeq,
                channelClass: channelClass,
                initialCwd: initialCwd,
            )

        case .channelOpenAck:
            let acceptedByte = try reader.readUInt8()
            // `resumeFromSeq` is decode-optional (the `channelOpen` cwd discipline): absent
            // (a pre-resume encoder / old golden vector) reads as 0 — "nothing resumed".
            let resumeFromSeq: Int64
            if reader.bytesRemaining == 0 {
                resumeFromSeq = 0
            } else {
                resumeFromSeq = try reader.readInt64()
                guard reader.bytesRemaining == 0 else {
                    throw SlopDeskError.malformedBody("channelOpenAck: trailing bytes")
                }
            }
            return .channelOpenAck(
                channelID: channelID,
                accepted: acceptedByte != 0,
                resumeFromSeq: resumeFromSeq,
            )

        case .channelData:
            // Body is an opaque WireMessage frame — consume the rest verbatim.
            return .channelData(channelID: channelID, payload: reader.remaining())

        case .channelClose:
            // A close must always CLOSE: the reason only advises what may happen afterwards, so
            // neither an absent body (the default `.retired` encoding) nor an unrecognised byte may
            // throw and leave the channel open — both read as `.retired`, the reading that
            // withholds an automatic re-dial. Trailing bytes past the reason are still malformed.
            guard reader.bytesRemaining > 0 else { return .channelClose(channelID: channelID, reason: .retired) }
            let reasonByte = try reader.readUInt8()
            guard reader.bytesRemaining == 0 else {
                throw SlopDeskError.malformedBody("channelClose: trailing bytes")
            }
            return .channelClose(
                channelID: channelID,
                reason: MuxCloseReason(rawValue: reasonByte) ?? .retired,
            )

        case .windowAdjust:
            let bytesToAdd = try reader.readUInt32()
            return .windowAdjust(channelID: channelID, bytesToAdd: bytesToAdd)
        }
    }

    private static func clampedUTF8(_ string: String) -> Data {
        let full = Data(string.utf8)
        guard full.count > Int(UInt16.max) else { return full }
        var out = Data()
        for scalar in string.unicodeScalars {
            let bytes = Data(String(scalar).utf8)
            if out.count + bytes.count > Int(UInt16.max) { break }
            out.append(bytes)
        }
        return out
    }
}
