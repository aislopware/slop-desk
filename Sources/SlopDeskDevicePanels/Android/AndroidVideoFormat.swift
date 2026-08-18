// AndroidVideoFormat — the bridge from the device's H.264/H.265 bytes to CoreMedia objects.
//
// The same shape as ``SimulatorVideoFormat`` and for the same reasons: nothing here decodes,
// `CMVideoFormatDescription` / `CMBlockBuffer` / `CMSampleBuffer` are plain data objects with no
// session and no device behind them, and that is what lets this layer be unit-tested under the
// hang-safety rule while the thing that actually decodes — `AVSampleBufferDisplayLayer`, which spins
// up its own decompression session on first enqueue — stays in the view and out of every test.
//
// The one real difference is the input. The simulator server is asked for `format=avcc` and hands
// over an avcC record; `scrcpy` forwards raw `MediaCodec` output, so the parameter sets arrive as
// Annex-B NALs and there is no record to parse. That is strictly simpler here —
// `CMVideoFormatDescriptionCreateFromH264ParameterSets` wants exactly those NALs — and the cost is
// paid on the frames instead, where every access unit is rewritten with 4-byte lengths
// (``AndroidAnnexB/avccAccessUnit(from:)``).

import CoreMedia
import Foundation

package enum AndroidVideoFormat {
    /// Builds the format description a config packet's parameter sets describe.
    ///
    /// The parameter-set pointers must stay valid for the DURATION of the call, which is why the
    /// blobs are flattened into one contiguous buffer and pointed into rather than handed over
    /// through nested `withUnsafeBytes` closures — HEVC carries three sets (VPS/SPS/PPS) and a
    /// stream is free to carry more.
    package static func formatDescription(
        parameterSets sets: [Data], codec: AndroidVideoCodec,
    ) -> CMVideoFormatDescription? {
        guard !sets.isEmpty else { return nil }

        var flattened: [UInt8] = []
        var ranges: [(offset: Int, count: Int)] = []
        for set in sets where !set.isEmpty {
            ranges.append((flattened.count, set.count))
            flattened.append(contentsOf: set)
        }
        guard !ranges.isEmpty else { return nil }

        var description: CMVideoFormatDescription?
        let status = flattened.withUnsafeBufferPointer { buffer -> OSStatus in
            guard let base = buffer.baseAddress else { return -1 }
            let pointers = ranges.map { UnsafePointer<UInt8>(base + $0.offset) }
            let sizes = ranges.map(\.count)
            return pointers.withUnsafeBufferPointer { pointerBuffer in
                sizes.withUnsafeBufferPointer { sizeBuffer in
                    guard let pointerBase = pointerBuffer.baseAddress,
                          let sizeBase = sizeBuffer.baseAddress else { return -1 }
                    switch codec {
                    case .h264:
                        return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: ranges.count,
                            parameterSetPointers: pointerBase,
                            parameterSetSizes: sizeBase,
                            // Always 4: ``AndroidAnnexB/avccAccessUnit(from:)`` is what writes the
                            // prefixes this description describes, and it writes four bytes.
                            nalUnitHeaderLength: 4,
                            formatDescriptionOut: &description,
                        )
                    case .h265:
                        return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: ranges.count,
                            parameterSetPointers: pointerBase,
                            parameterSetSizes: sizeBase,
                            nalUnitHeaderLength: 4,
                            extensions: nil,
                            formatDescriptionOut: &description,
                        )
                    }
                }
            }
        }
        return status == noErr ? description : nil
    }

    /// One AVCC access unit as a sample buffer ready to enqueue —
    /// ``DevicePanelSampleBuffer/sampleBuffer(accessUnit:formatDescription:isKeyframe:)``, which both
    /// device panels share. Only the format description above differs between them.
    package static func sampleBuffer(
        accessUnit: Data, formatDescription: CMVideoFormatDescription, isKeyframe: Bool,
    ) -> CMSampleBuffer? {
        DevicePanelSampleBuffer.sampleBuffer(
            accessUnit: accessUnit, formatDescription: formatDescription, isKeyframe: isKeyframe,
        )
    }

    /// The stream's pixel dimensions, for the panel's aspect ratio.
    ///
    /// Read off the FORMAT DESCRIPTION rather than the session header, and the difference is real:
    /// the bridge asks the device for `max_size`, so the encoded frame is smaller than the device's
    /// own display, and it is the frame the view has to fit. The session header agrees today; the
    /// format description is the one that cannot disagree.
    package static func dimensions(of formatDescription: CMVideoFormatDescription) -> CGSize {
        DevicePanelSampleBuffer.dimensions(of: formatDescription)
    }
}
