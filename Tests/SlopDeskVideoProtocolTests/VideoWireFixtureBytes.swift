import Foundation
@testable import SlopDeskVideoProtocol

// Big-endian byte helpers for building HOSTILE datagrams — a length prefix that lies, a count with
// no records behind it, a fragment header whose payload never arrives. Every codec in
// `SlopDeskVideoProtocol` decodes through `slopdesk-ffi` now, so these exist only to hand it input
// no encoder would produce, and they live in the test target on purpose: in `Sources` they would be
// a second speller of the wire, one refactor away from being a second implementation of it.
//
// Nothing here may be used to build an EXPECTED datagram. A test that wants to pin bytes writes the
// bytes.

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

    mutating func appendBE(_ value: UInt64) {
        appendBE(UInt32(truncatingIfNeeded: value >> 32))
        appendBE(UInt32(truncatingIfNeeded: value))
    }

    /// Appends a big-endian `Float64` (IEEE 754 bit pattern) — the coordinate channels' float shape,
    /// including the non-finite bit patterns a decoder has to refuse.
    mutating func appendBE(_ value: Double) {
        let bits = value.bitPattern
        for shift in stride(from: 56, through: 0, by: -8) {
            append(UInt8(truncatingIfNeeded: bits >> UInt64(shift)))
        }
    }
}

/// A forward-only big-endian reader, kept for the two tests that assert what a SLICE-relative read
/// does: the transports hand every decoder a tag-stripped slice with a nonzero `startIndex`, and
/// that contract is worth a test of its own.
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

    mutating func readUInt16() throws -> UInt16 {
        let b0 = try UInt16(nextByte())
        let b1 = try UInt16(nextByte())
        return (b0 << 8) | b1
    }

    mutating func readUInt32() throws -> UInt32 {
        var value: UInt32 = 0
        for _ in 0..<4 { value = try (value << 8) | UInt32(nextByte()) }
        return value
    }

    /// Consumes and returns everything after the current offset, start-index-relative.
    mutating func remaining() -> Data {
        let slice = data[(data.startIndex + offset)...]
        offset = data.count
        return slice
    }
}
