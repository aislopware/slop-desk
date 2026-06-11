import Foundation

// Tiny big-endian read/write helpers. ALL multi-byte integers are big-endian
// ("network byte order") on the wire. We do byte-by-byte assembly rather than
// `withUnsafeBytes`/`loadUnaligned` so the code is alignment-safe, endian-explicit,
// and free of any third-party dependency.

extension Data {
    // MARK: Append (encode)

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

    mutating func appendBE(_ value: Int64) {
        appendBE(UInt64(bitPattern: value))
    }

    mutating func appendBE(_ value: UInt64) {
        for shift in stride(from: 56, through: 0, by: -8) {
            append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
        }
    }
}

/// A forward-only big-endian reader over a `Data` slice.
///
/// All reads consume from the current offset and throw ``AislopdeskError/truncated``
/// if there are not enough bytes left. After parsing fixed fields, ``remaining``
/// returns the rest of the buffer (used for variable-length payloads such as PTY
/// bytes and UTF-8 titles).
struct BigEndianReader {
    private let data: Data
    /// Offset relative to `data.startIndex` (Data slices may not be zero-based).
    private var offset: Int = 0

    init(_ data: Data) {
        self.data = data
    }

    /// Bytes not yet consumed.
    var bytesRemaining: Int { data.count - offset }

    private mutating func nextByte() throws -> UInt8 {
        guard offset < data.count else { throw AislopdeskError.truncated }
        let byte = data[data.startIndex + offset]
        offset += 1
        return byte
    }

    mutating func readUInt8() throws -> UInt8 {
        try nextByte()
    }

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

    mutating func readUInt64() throws -> UInt64 {
        var value: UInt64 = 0
        for _ in 0 ..< 8 { value = (value << 8) | UInt64(try nextByte()) }
        return value
    }

    mutating func readInt32() throws -> Int32 {
        Int32(bitPattern: try readUInt32())
    }

    mutating func readInt64() throws -> Int64 {
        Int64(bitPattern: try readUInt64())
    }

    /// Reads exactly `count` raw bytes, returned as a fresh zero-based `Data`.
    mutating func readBytes(_ count: Int) throws -> Data {
        guard count >= 0, bytesRemaining >= count else { throw AislopdeskError.truncated }
        let start = data.startIndex + offset
        let slice = data[start ..< start + count]
        offset += count
        return Data(slice)
    }

    /// Consumes and returns all remaining bytes as a fresh zero-based `Data`.
    mutating func remaining() -> Data {
        let slice = data[(data.startIndex + offset)...]
        offset = data.count
        return Data(slice)
    }
}
