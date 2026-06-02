import Foundation

// Tiny big-endian read/write helpers, local to RworkVideoProtocol so this target
// stays a leaf with ZERO dependency (it must compile for macOS + iOS and be unit
// testable in isolation, exactly like RworkProtocol). All multi-byte integers on
// the wire are big-endian ("network byte order"). Byte-by-byte assembly keeps the
// code alignment-safe and endian-explicit.

extension Data {
    mutating func appendBE(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }

    mutating func appendBE(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value >> 24))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }

    mutating func appendBE(_ value: Int32) {
        appendBE(UInt32(bitPattern: value))
    }
}

/// Errors raised while decoding video-path wire messages.
public enum VideoProtocolError: Error, Equatable, Sendable {
    /// Not enough bytes remained to satisfy a fixed-size field.
    case truncated
    /// A field held a value outside its permitted range (e.g. an unknown tag).
    case malformed(String)
}

/// A forward-only big-endian reader over a `Data` slice.
///
/// Mirrors `RworkProtocol.BigEndianReader` but lives here so the target stays a
/// leaf. Reads consume from the current offset and throw
/// ``VideoProtocolError/truncated`` when the buffer is exhausted.
struct VideoByteReader {
    private let data: Data
    private var offset = 0

    init(_ data: Data) { self.data = data }

    var bytesRemaining: Int { data.count - offset }

    private mutating func nextByte() throws -> UInt8 {
        guard offset < data.count else { throw VideoProtocolError.truncated }
        let byte = data[data.startIndex + offset]
        offset += 1
        return byte
    }

    mutating func readUInt8() throws -> UInt8 { try nextByte() }

    mutating func readUInt16() throws -> UInt16 {
        let b0 = UInt16(try nextByte())
        let b1 = UInt16(try nextByte())
        return (b0 << 8) | b1
    }

    mutating func readUInt32() throws -> UInt32 {
        var value: UInt32 = 0
        for _ in 0 ..< 4 { value = (value << 8) | UInt32(try nextByte()) }
        return value
    }

    mutating func readInt32() throws -> Int32 {
        Int32(bitPattern: try readUInt32())
    }

    /// Reads a big-endian `Float64` (IEEE 754 bit pattern). Used by the coordinate /
    /// cursor / geometry channels, which carry sub-pixel `Double`s.
    mutating func readFloat64() throws -> Double {
        var bits: UInt64 = 0
        for _ in 0 ..< 8 { bits = (bits << 8) | UInt64(try nextByte()) }
        return Double(bitPattern: bits)
    }

    mutating func readBytes(_ count: Int) throws -> Data {
        guard count >= 0, bytesRemaining >= count else { throw VideoProtocolError.truncated }
        let start = data.startIndex + offset
        let slice = data[start ..< start + count]
        offset += count
        return Data(slice)
    }

    mutating func remaining() -> Data {
        let slice = data[(data.startIndex + offset)...]
        offset = data.count
        return Data(slice)
    }
}

extension Data {
    /// Appends a big-endian `Float64` (IEEE 754 bit pattern).
    mutating func appendBE(_ value: Double) {
        let bits = value.bitPattern
        for shift in stride(from: 56, through: 0, by: -8) {
            append(UInt8(truncatingIfNeeded: bits >> UInt64(shift)))
        }
    }
}
