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

#if os(macOS)
import CoreMedia
import Foundation

enum AndroidVideoFormat {
    /// Builds the format description a config packet's parameter sets describe.
    ///
    /// The parameter-set pointers must stay valid for the DURATION of the call, which is why the
    /// blobs are flattened into one contiguous buffer and pointed into rather than handed over
    /// through nested `withUnsafeBytes` closures — HEVC carries three sets (VPS/SPS/PPS) and a
    /// stream is free to carry more.
    static func formatDescription(
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

    /// Wraps one AVCC access unit as a sample buffer ready to enqueue.
    ///
    /// Timing is deliberately absent and `DisplayImmediately` set instead — the simulator panel's
    /// reasoning applies unchanged: real presentation timestamps against a control timebase buy
    /// smooth playback of a recording and cost a frame of buffering, and this is an interactive
    /// mirror of a device someone is tapping.
    static func sampleBuffer(
        accessUnit: Data, formatDescription: CMVideoFormatDescription, isKeyframe: Bool,
    ) -> CMSampleBuffer? {
        guard !accessUnit.isEmpty else { return nil }

        var blockBuffer: CMBlockBuffer?
        // A block buffer that owns its memory, then a copy in — rather than pointing at the `Data`'s
        // storage, whose lifetime ends with this call while the sample buffer outlives it.
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: accessUnit.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: accessUnit.count,
            flags: 0,
            blockBufferOut: &blockBuffer,
        ) == noErr, let blockBuffer else { return nil }

        let copied = accessUnit.withUnsafeBytes { bytes -> OSStatus in
            guard let base = bytes.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(
                with: base, blockBuffer: blockBuffer, offsetIntoDestination: 0,
                dataLength: accessUnit.count,
            )
        }
        guard copied == noErr else { return nil }

        var sampleBuffer: CMSampleBuffer?
        var sampleSize = accessUnit.count
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 0,
            sampleTimingArray: nil,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer,
        ) == noErr, let sampleBuffer else { return nil }

        annotate(sampleBuffer, isKeyframe: isKeyframe)
        return sampleBuffer
    }

    /// Marks the sample for immediate display, and a delta frame as a non-sync sample.
    private static func annotate(_ sampleBuffer: CMSampleBuffer, isKeyframe: Bool) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer, createIfNecessary: true,
        ), CFArrayGetCount(attachments) > 0 else { return }
        let raw = CFArrayGetValueAtIndex(attachments, 0)
        let dictionary = unsafeBitCast(raw, to: CFMutableDictionary.self)
        CFDictionarySetValue(
            dictionary,
            Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
            Unmanaged.passUnretained(kCFBooleanTrue).toOpaque(),
        )
        if !isKeyframe {
            CFDictionarySetValue(
                dictionary,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque(),
            )
        }
    }

    /// The stream's pixel dimensions, for the panel's aspect ratio.
    ///
    /// Read off the FORMAT DESCRIPTION rather than the session header, and the difference is real:
    /// the bridge asks the device for `max_size`, so the encoded frame is smaller than the device's
    /// own display, and it is the frame the view has to fit. The session header agrees today; the
    /// format description is the one that cannot disagree.
    static func dimensions(of formatDescription: CMVideoFormatDescription) -> CGSize {
        let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
        return CGSize(width: Int(dimensions.width), height: Int(dimensions.height))
    }
}
#endif
