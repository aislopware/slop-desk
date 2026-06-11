import Foundation

// Tiny big-endian read/write helpers, local to AislopdeskVideoProtocol so this target
// stays a leaf with ZERO dependency (it must compile for macOS + iOS and be unit
// testable in isolation, exactly like AislopdeskProtocol). All multi-byte integers on
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

    /// Appends a `UInt16` byte-length prefix followed by the string's UTF-8 bytes. Used to delimit
    /// multiple variable-length strings in ONE datagram (e.g. the window-list records) — unlike the
    /// single trailing `remaining()` string, a length prefix gives record boundaries. A string whose
    /// UTF-8 exceeds `UInt16.max` bytes is truncated at a byte boundary (window titles are never that
    /// long; this only guards a pathological input).
    mutating func appendLengthPrefixed(_ string: String) {
        var bytes = Array(string.utf8)
        if bytes.count > Int(UInt16.max) { bytes = Array(bytes.prefix(Int(UInt16.max))) }
        appendBE(UInt16(bytes.count))
        append(contentsOf: bytes)
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
/// Mirrors `AislopdeskProtocol.BigEndianReader` but lives here so the target stays a
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

    /// Reads a wire `Float64` and REJECTS non-finite values (NaN / ±infinity).
    ///
    /// Coordinates, sizes, bounds and hotspots arrive as raw IEEE-754 bit patterns off the
    /// (WireGuard-encrypted but otherwise untrusted) UDP wire. A non-finite value is never a
    /// legitimate geometry and is dangerous downstream in BOTH directions: the host's scroll
    /// injector uses the trapping `Int32(Double)` initializer (fatal-errors on NaN/±inf), and the
    /// CLIENT propagates NaN through the aspect-fit / cursor-placement math into a `CALayer` frame —
    /// assigning a NaN layer geometry raises an uncaught `CALayerInvalidGeometry` exception that
    /// kills the process. Treating a non-finite field as malformed lets the router DROP the single
    /// packet (same contract as the reassembler / `InputDatagramRouter.route`) — a corrupt datagram
    /// must never crash the receiver, host- OR client-bound. (Shared by every wire-float codec so
    /// the host- and client-bound paths stay symmetric — see VIDEO cursor-NaN audit finding.)
    mutating func readFiniteFloat64(_ field: String) throws -> Double {
        let value = try readFloat64()
        guard value.isFinite else { throw VideoProtocolError.malformed("non-finite \(field)") }
        return value
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

    /// Reads a `UInt16`-length-prefixed UTF-8 string (the counterpart to ``Data/appendLengthPrefixed(_:)``).
    /// `readBytes` throws ``VideoProtocolError/truncated`` if the datagram is too short for the declared
    /// length, so a corrupt/oversized prefix DROPS the datagram rather than over-reading or crashing.
    /// Invalid UTF-8 decodes lossily (a remote window title must never crash the receiver).
    mutating func readLengthPrefixed() throws -> String {
        let len = Int(try readUInt16())
        let bytes = try readBytes(len)
        return String(decoding: bytes, as: UTF8.self)
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
