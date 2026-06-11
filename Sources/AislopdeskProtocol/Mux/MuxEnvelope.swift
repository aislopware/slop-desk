import Foundation

/// The frame types carried by the TCP mux envelope.
///
/// The mux layer multiplexes many logical channels over one physical TCP
/// connection (SSH-style: `CHANNEL_OPEN` / `CHANNEL_DATA` / `CHANNEL_CLOSE` /
/// `CHANNEL_WINDOW_ADJUST`). One byte selects the frame's meaning; the body layout
/// depends on the type. See ``MuxEnvelopeCodec`` for the wire layout.
public enum MuxFrameType: UInt8, Sendable, Equatable, CaseIterable {
    /// Initiator asks to open a new logical channel. Body =
    /// `[16-byte sessionUUID][Int64 BE lastReceivedSeq][UInt8 channelClass]`.
    case channelOpen = 1
    /// Responder accepts (or refuses) a channel open. Body = `[UInt8 accepted]`.
    case channelOpenAck = 2
    /// Opaque application payload for an open channel. Body is a passed-through
    /// ``WireMessage`` frame — the mux layer does **not** parse it.
    case channelData = 3
    /// One side is done sending on the channel (SSH `CHANNEL_CLOSE`). Body = empty.
    case channelClose = 4
    /// Replenish a channel's flow-control window (SSH `CHANNEL_WINDOW_ADJUST`).
    /// Body = `[UInt32 BE bytesToAdd]`.
    case windowAdjust = 5
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
    /// `channelOpen`: open `channelID` carrying a resume hint and a class selector.
    case channelOpen(channelID: UInt32, sessionID: UUID, lastReceivedSeq: Int64, channelClass: UInt8)
    /// `channelOpenAck`: `accepted` true if the responder will service the channel.
    case channelOpenAck(channelID: UInt32, accepted: Bool)
    /// `channelData`: OPAQUE inner ``WireMessage`` frame bytes for `channelID`.
    case channelData(channelID: UInt32, payload: Data)
    /// `channelClose`: this side will send no more frames on `channelID`.
    case channelClose(channelID: UInt32)
    /// `windowAdjust`: grant `bytesToAdd` more flow-control credit on `channelID`.
    case windowAdjust(channelID: UInt32, bytesToAdd: UInt32)

    /// The logical channel this frame addresses.
    public var channelID: UInt32 {
        switch self {
        case let .channelOpen(channelID, _, _, _): return channelID
        case let .channelOpenAck(channelID, _): return channelID
        case let .channelData(channelID, _): return channelID
        case let .channelClose(channelID): return channelID
        case let .windowAdjust(channelID, _): return channelID
        }
    }

    /// The on-wire mux-type byte for this frame.
    public var muxType: MuxFrameType {
        switch self {
        case .channelOpen: return .channelOpen
        case .channelOpenAck: return .channelOpenAck
        case .channelData: return .channelData
        case .channelClose: return .channelClose
        case .windowAdjust: return .windowAdjust
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
        // run [channelID][muxType][body…], then BACK-PATCH the prefix. This avoids the intermediate
        // `inner` Data and the extra whole-payload copy it forced — the up-to-128 KiB `.channelData`
        // payload under a flood was previously memcpy'd into `inner` and then again into `frameData`.
        var out = Data()
        out.append(contentsOf: [0, 0, 0, 0]) // muxFrameLength placeholder (back-patched below)
        out.appendBE(frame.channelID)
        out.append(frame.muxType.rawValue)

        switch frame {
        case let .channelOpen(_, sessionID, lastReceivedSeq, channelClass):
            out.append(sessionID.dataBytes)
            out.appendBE(lastReceivedSeq)
            out.append(channelClass)

        case let .channelOpenAck(_, accepted):
            out.append(accepted ? 1 : 0)

        case let .channelData(_, payload):
            out.append(payload) // opaque — carried verbatim

        case .channelClose:
            break // empty body

        case let .windowAdjust(_, bytesToAdd):
            out.appendBE(bytesToAdd)
        }

        // muxFrameLength counts the inner run [channelID][muxType][body] — everything after the 4-byte
        // prefix — exactly the value the old `UInt32(inner.count)` carried.
        let innerLength = UInt32(out.count - prefixLength)
        let s = out.startIndex
        out[s]     = UInt8(truncatingIfNeeded: innerLength >> 24)
        out[s + 1] = UInt8(truncatingIfNeeded: innerLength >> 16)
        out[s + 2] = UInt8(truncatingIfNeeded: innerLength >> 8)
        out[s + 3] = UInt8(truncatingIfNeeded: innerLength)
        return out
    }

    /// Decodes a frame from a **complete inner run** (`[channelID][muxType][body...]`,
    /// without the length prefix — framing is handled by ``MuxFrameDecoder``).
    ///
    /// - Throws: ``AislopdeskError/truncated`` if the body is shorter than the mux type
    ///   requires, ``AislopdeskError/unknownMessageType(_:)`` for an unrecognized mux-type
    ///   byte, or ``AislopdeskError/malformedBody(_:)`` for a right-length-but-invalid body
    ///   (e.g. bad sessionID bytes).
    public static func decode(inner: Data) throws -> MuxFrame {
        var reader = BigEndianReader(inner)
        let channelID = try reader.readUInt32()
        let typeByte = try reader.readUInt8()
        guard let type = MuxFrameType(rawValue: typeByte) else {
            throw AislopdeskError.unknownMessageType(typeByte)
        }

        switch type {
        case .channelOpen:
            let idBytes = try reader.readBytes(sessionIDByteCount)
            let lastReceivedSeq = try reader.readInt64()
            let channelClass = try reader.readUInt8()
            guard let sessionID = UUID(dataBytes: idBytes) else {
                throw AislopdeskError.malformedBody("channelOpen: invalid sessionID bytes")
            }
            return .channelOpen(
                channelID: channelID,
                sessionID: sessionID,
                lastReceivedSeq: lastReceivedSeq,
                channelClass: channelClass
            )

        case .channelOpenAck:
            let acceptedByte = try reader.readUInt8()
            return .channelOpenAck(channelID: channelID, accepted: acceptedByte != 0)

        case .channelData:
            // Body is an opaque WireMessage frame — consume the rest verbatim.
            return .channelData(channelID: channelID, payload: reader.remaining())

        case .channelClose:
            return .channelClose(channelID: channelID)

        case .windowAdjust:
            let bytesToAdd = try reader.readUInt32()
            return .windowAdjust(channelID: channelID, bytesToAdd: bytesToAdd)
        }
    }
}
