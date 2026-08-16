import CSlopDeskFFI
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
/// The parse itself is `rust/slopdesk-video`'s `nal_unit`, host/client-agnostic there as it was
/// here: the host hands it the raw `CMBlockBuffer` bytes; the client reconstructs the same AVCC
/// byte layout from reassembled fragments before feeding the decoder.
public enum NALUnit {
    /// The length-prefix width, in bytes. AVCC/HVCC use 4 in our encoder configs.
    public static let lengthPrefixSize = slopdesk_nal_constant(0)

    /// Splits an AVCC byte buffer into its individual NAL units (payloads only,
    /// length prefixes stripped).
    ///
    /// Parsing is defensive on the Rust side: a prefix that claims more bytes than remain, or a
    /// non-positive length, terminates iteration without throwing — a truncated tail is "no more
    /// whole NALUs", never a crash.
    ///
    /// What crosses is where each unit SITS, not its bytes: an IDR's units are most of a frame and
    /// this side is already holding it. The copy then happens once, inside the borrow that has the
    /// pointer.
    public static func split(_ avcc: Data) -> [Data] {
        avcc.withUnsafeBytes { bytes -> [Data] in
            withUnsafeTemporaryAllocation(of: SlopDeskNalSpan.self, capacity: scratchSpans) { scratch in
                let count = slopdesk_nal_split(bytes.baseAddress, bytes.count, scratch.baseAddress, scratch.count)
                guard count > scratch.count else { return units(of: bytes, at: scratch.baseAddress, count: count) }
                // A frame with more units than the scratch holds: ask again with room for them all.
                var spans = [SlopDeskNalSpan](repeating: SlopDeskNalSpan(), count: count)
                let filled = spans.withUnsafeMutableBufferPointer { buffer in
                    slopdesk_nal_split(bytes.baseAddress, bytes.count, buffer.baseAddress, buffer.count)
                }
                return spans.withUnsafeBufferPointer { units(of: bytes, at: $0.baseAddress, count: filled) }
            }
        }
    }

    /// Re-assembles NAL-unit payloads back into one AVCC byte buffer (each unit
    /// re-prefixed with its 4-byte big-endian length). Inverse of ``split(_:)``.
    ///
    /// The units travel as the §4d blob list the FEC boundary already uses, because separately
    /// allocated payloads cannot cross as one span any other way.
    public static func join(_ units: [Data]) -> Data {
        let packed = FECBlobList.encode(units.map(\.self))
        let bound = units.reduce(0) { $0 + lengthPrefixSize + $1.count }
        let avcc = packed.withUnsafeBufferPointer { list in
            FECBlobList.call(bound: bound) { out, cap in
                slopdesk_nal_join(list.baseAddress, list.count, out, cap)
            }
        }
        return Data(avcc)
    }

    /// Copies each answered span out of the buffer the split walked.
    private static func units(
        of bytes: UnsafeRawBufferPointer, at spans: UnsafePointer<SlopDeskNalSpan>?, count: Int,
    ) -> [Data] {
        guard let spans, count > 0 else { return [] }
        return (0..<count).map { index in
            let span = spans[index]
            let start = Int(span.offset)
            return Data(UnsafeRawBufferPointer(rebasing: bytes[start..<start + Int(span.length)]))
        }
    }

    /// Stack room for the span list. Our encoder configs emit one NAL unit per buffer and a
    /// parameter-set frame carries a handful, so this is the answer every real frame fits in; too
    /// small would only ever cost a second walk.
    private static let scratchSpans = 16
}
