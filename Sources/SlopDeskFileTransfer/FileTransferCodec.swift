import Foundation

/// Manual big-endian encode/decode for ``FileTransferMessage`` — the PATH-4 body that rides inside
/// each `[UInt32 BE length][payload]` frame. No JSON/Codable on the wire (house rule); multi-byte
/// ints are big-endian; strings are `[UInt16 BE byteLength][UTF-8]`.
///
/// Decode is validate-then-drop: every read is length-checked before it slices, unknown types and
/// truncated bodies throw rather than force-unwrap, and no attacker-chosen length drives an
/// allocation before it is bounded by the already-capped frame payload.
public enum FileTransferCodec {
    public enum DecodeError: Error, Equatable, Sendable {
        case empty
        case unknownType(UInt8)
        case truncated
        case badUTF8
    }

    // MARK: - Encode

    /// The full framed bytes for `message`: `[UInt32 BE payloadLength][UInt8 type][body]`.
    public static func encodeFrame(_ message: FileTransferMessage) -> Data {
        let payload = encodePayload(message)
        var out = Data(capacity: 4 + payload.count)
        appendBE(&out, UInt32(payload.count))
        out.append(payload)
        return out
    }

    /// The payload only (`[UInt8 type][body]`), for callers that frame separately (e.g. tests).
    public static func encodePayload(_ message: FileTransferMessage) -> Data {
        var out = Data()
        switch message {
        case let .hello(version):
            out.append(1)
            out.append(version)
        case let .offer(transferId, fileSize, name):
            out.append(2)
            appendBE(&out, transferId)
            appendBE(&out, fileSize)
            appendString(&out, name)
        case let .chunk(transferId, data):
            out.append(3)
            appendBE(&out, transferId)
            out.append(data)
        case let .finish(transferId):
            out.append(4)
            appendBE(&out, transferId)
        case let .cancel(transferId):
            out.append(5)
            appendBE(&out, transferId)
        case let .helloAck(accepted):
            out.append(6)
            out.append(accepted ? 1 : 0)
        case let .accept(transferId):
            out.append(7)
            appendBE(&out, transferId)
        case let .complete(transferId):
            out.append(8)
            appendBE(&out, transferId)
        case let .failed(transferId, reason):
            out.append(9)
            appendBE(&out, transferId)
            appendString(&out, reason)
        }
        return out
    }

    // MARK: - Decode

    /// Decodes one payload (`[UInt8 type][body]`) into a message. Throws on empty, unknown type, a
    /// truncated body, or invalid UTF-8 — the caller drops the frame (and typically the connection).
    public static func decodePayload(_ payload: Data) throws -> FileTransferMessage {
        guard !payload.isEmpty else { throw DecodeError.empty }
        var reader = ByteReader(payload)
        let type = try reader.readUInt8()
        switch type {
        case 1:
            return try .hello(version: reader.readUInt8())
        case 2:
            let transferId = try reader.readUInt32()
            let fileSize = try reader.readUInt64()
            let name = try reader.readString()
            return .offer(transferId: transferId, fileSize: fileSize, name: name)
        case 3:
            let transferId = try reader.readUInt32()
            // The rest of the payload is the raw body chunk (may be empty on a zero-length flush).
            return .chunk(transferId: transferId, data: reader.rest())
        case 4:
            return try .finish(transferId: reader.readUInt32())
        case 5:
            return try .cancel(transferId: reader.readUInt32())
        case 6:
            return try .helloAck(accepted: reader.readUInt8() != 0)
        case 7:
            return try .accept(transferId: reader.readUInt32())
        case 8:
            return try .complete(transferId: reader.readUInt32())
        case 9:
            let transferId = try reader.readUInt32()
            let reason = try reader.readString()
            return .failed(transferId: transferId, reason: reason)
        default:
            throw DecodeError.unknownType(type)
        }
    }
}

// MARK: - Big-endian append helpers

private func appendBE(_ data: inout Data, _ value: UInt32) {
    data.append(UInt8((value >> 24) & 0xFF))
    data.append(UInt8((value >> 16) & 0xFF))
    data.append(UInt8((value >> 8) & 0xFF))
    data.append(UInt8(value & 0xFF))
}

private func appendBE(_ data: inout Data, _ value: UInt64) {
    for shift in stride(from: 56, through: 0, by: -8) {
        data.append(UInt8((value >> UInt64(shift)) & 0xFF))
    }
}

private func appendBE(_ data: inout Data, _ value: UInt16) {
    data.append(UInt8((value >> 8) & 0xFF))
    data.append(UInt8(value & 0xFF))
}

/// `[UInt16 BE byteLength][UTF-8]`. A name/reason longer than 65535 UTF-8 bytes is truncated to the
/// prefix's capacity — filenames never approach this, and a reason string is short by construction.
private func appendString(_ data: inout Data, _ string: String) {
    var bytes = Array(string.utf8)
    if bytes.count > Int(UInt16.max) { bytes = Array(bytes.prefix(Int(UInt16.max))) }
    appendBE(&data, UInt16(bytes.count))
    data.append(contentsOf: bytes)
}

// MARK: - ByteReader (length-checked cursor)

/// A forward-only cursor over a `Data` that length-checks every read. Every accessor throws
/// ``FileTransferCodec/DecodeError/truncated`` rather than trap when the buffer runs short — the
/// validate-then-drop contract for untrusted bytes.
private struct ByteReader {
    private let data: Data
    private var index: Int

    init(_ data: Data) {
        self.data = data
        index = data.startIndex
    }

    private var remaining: Int { data.endIndex - index }

    mutating func readUInt8() throws -> UInt8 {
        guard remaining >= 1 else { throw FileTransferCodec.DecodeError.truncated }
        defer { index += 1 }
        return data[index]
    }

    mutating func readUInt16() throws -> UInt16 {
        guard remaining >= 2 else { throw FileTransferCodec.DecodeError.truncated }
        var value: UInt16 = 0
        for _ in 0..<2 { value = (value << 8) | UInt16(data[index])
            index += 1
        }
        return value
    }

    mutating func readUInt32() throws -> UInt32 {
        guard remaining >= 4 else { throw FileTransferCodec.DecodeError.truncated }
        var value: UInt32 = 0
        for _ in 0..<4 { value = (value << 8) | UInt32(data[index])
            index += 1
        }
        return value
    }

    mutating func readUInt64() throws -> UInt64 {
        guard remaining >= 8 else { throw FileTransferCodec.DecodeError.truncated }
        var value: UInt64 = 0
        for _ in 0..<8 { value = (value << 8) | UInt64(data[index])
            index += 1
        }
        return value
    }

    mutating func readString() throws -> String {
        let length = try Int(readUInt16())
        guard remaining >= length else { throw FileTransferCodec.DecodeError.truncated }
        let slice = data[index..<index + length]
        index += length
        guard let string = String(data: Data(slice), encoding: .utf8) else {
            throw FileTransferCodec.DecodeError.badUTF8
        }
        return string
    }

    /// Consumes and returns the remaining bytes (the trailing raw body of a `chunk`).
    mutating func rest() -> Data {
        let slice = Data(data[index..<data.endIndex])
        index = data.endIndex
        return slice
    }
}
