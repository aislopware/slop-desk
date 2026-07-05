import Foundation

/// Length-prefixed (AVCC / HVCC) NAL-unit iteration.
///
/// VideoToolbox emits a `CMSampleBuffer` whose `CMBlockBuffer` holds one or more
/// NAL units, each preceded by a big-endian length prefix (4 bytes in the configs
/// we ship — see `docs/research/spikes/vtbench/encode-decode-bench.swift`
/// `naluCount`). The macOS-26 "multiple NALUs corrupt video" watch-item was
/// **downgraded** after measurement (1 NALU per buffer, even IDR — RESULTS.md), but
/// we iterate length-prefixed NALUs **defensively anyway** because correct AVCC
/// parsing costs nothing (doc 18, non-blocking watch items).
///
/// This type is the pure, host/client-agnostic parse: the host hands it the raw
/// `CMBlockBuffer` bytes; the client reconstructs the same AVCC byte layout from
/// reassembled fragments before feeding the decoder.
public enum NALUnit {
    /// The length-prefix width, in bytes. AVCC/HVCC use 4 in our encoder configs.
    public static let lengthPrefixSize = 4

    /// Splits an AVCC byte buffer into its individual NAL units (payloads only,
    /// length prefixes stripped).
    ///
    /// Parsing is defensive: a prefix that claims more bytes than remain, or a
    /// non-positive length, terminates iteration without throwing (matches the
    /// spike `naluCount` which simply `break`s on a bad prefix — a truncated tail
    /// is treated as "no more whole NALUs", never a crash).
    public static func split(_ avcc: Data) -> [Data] {
        var units: [Data] = []
        let base = avcc.startIndex
        var offset = 0
        let count = avcc.count
        while offset + lengthPrefixSize <= count {
            let p = base + offset
            let length =
                (Int(avcc[p]) << 24) |
                (Int(avcc[p + 1]) << 16) |
                (Int(avcc[p + 2]) << 8) |
                Int(avcc[p + 3])
            guard length > 0, offset + lengthPrefixSize + length <= count else { break }
            let start = p + lengthPrefixSize
            units.append(Data(avcc[start..<start + length]))
            offset += lengthPrefixSize + length
        }
        return units
    }

    /// Re-assembles NAL-unit payloads back into one AVCC byte buffer (each unit
    /// re-prefixed with its 4-byte big-endian length). Inverse of ``split(_:)``.
    public static func join(_ units: [Data]) -> Data {
        var out = Data()
        for unit in units {
            out.appendBE(UInt32(unit.count))
            out.append(unit)
        }
        return out
    }
}
