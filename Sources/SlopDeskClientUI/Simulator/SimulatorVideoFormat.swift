// SimulatorVideoFormat — the bridge from the simulator server's H.264 bytes to CoreMedia objects.
//
// Nothing here decodes. `CMVideoFormatDescription`, `CMBlockBuffer` and `CMSampleBuffer` are plain
// data objects — no session, no device, no window server — which is what lets this layer be unit
// tested under the hang-safety rule while the thing that ACTUALLY decodes
// (`AVSampleBufferDisplayLayer`, which spins up its own decompression session on first enqueue) stays
// in the view and out of every test.
//
// Why `AVSampleBufferDisplayLayer` and not a `VTDecompressionSession` + Metal path like the desktop
// video client: that path exists there because the desktop stream needs a client-side compositor —
// zoom, pan-lock, cursor overlay, 1:1 snapping, a pacer. The simulator panel needs none of it. It
// shows one rectangle at whatever size the panel is. Handing CoreMedia the sample buffers directly
// is the whole implementation, it is hardware-accelerated the same way, and it deletes the pacing
// and pixel-buffer-lifetime questions rather than answering them again.
//
// The stream is AVCC — each access unit is a run of `[4-byte BE length][NAL]`, already exactly what
// CoreMedia expects. That is why the URL asks for `format=avcc`: the Annex-B alternative would cost a
// start-code rewrite of every access unit on the hot path, for nothing.

#if os(macOS)
import CoreMedia
import Foundation

enum SimulatorVideoFormat {
    /// Build the format description an avcC record describes.
    ///
    /// The parameter-set pointers must stay valid for the DURATION of the call, which is why the
    /// blobs are copied into one contiguous buffer first and pointed into: handing CoreMedia
    /// `Data`'s bytes through nested `withUnsafeBytes` closures is possible but nests one level per
    /// parameter set, and a stream is free to carry more than the two we have seen.
    static func formatDescription(for configuration: SimulatorWireProtocol
        .AVCConfiguration) -> CMVideoFormatDescription?
    {
        let sets = configuration.parameterSets
        guard !sets.isEmpty else { return nil }

        var flattened: [UInt8] = []
        var ranges: [(offset: Int, count: Int)] = []
        for set in sets {
            ranges.append((flattened.count, set.count))
            flattened.append(contentsOf: set)
        }

        var description: CMVideoFormatDescription?
        let status = flattened.withUnsafeBufferPointer { buffer -> OSStatus in
            guard let base = buffer.baseAddress else { return -1 }
            let pointers = ranges.map { UnsafePointer<UInt8>(base + $0.offset) }
            let sizes = ranges.map(\.count)
            return pointers.withUnsafeBufferPointer { pointerBuffer in
                sizes.withUnsafeBufferPointer { sizeBuffer in
                    guard let pointerBase = pointerBuffer.baseAddress, let sizeBase = sizeBuffer.baseAddress
                    else { return -1 }
                    return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: sets.count,
                        parameterSetPointers: pointerBase,
                        parameterSetSizes: sizeBase,
                        nalUnitHeaderLength: Int32(configuration.nalUnitHeaderLength),
                        formatDescriptionOut: &description,
                    )
                }
            }
        }
        return status == noErr ? description : nil
    }

    /// Wrap one access unit as a sample buffer ready to enqueue.
    ///
    /// Timing is deliberately absent and `DisplayImmediately` set instead. The alternative — real
    /// presentation timestamps against a control timebase — buys smooth playback of a recording, and
    /// costs a frame of buffering to get it. This is an interactive mirror of a device someone is
    /// tapping, where the only thing that matters is that the frame lands as soon as it arrives; the
    /// project's own framing of the video path as a coding tool rather than a game stream applies
    /// here with more force, not less.
    static func sampleBuffer(
        accessUnit: Data, formatDescription: CMVideoFormatDescription, isKeyframe: Bool,
    ) -> CMSampleBuffer? {
        guard !accessUnit.isEmpty else { return nil }

        var blockBuffer: CMBlockBuffer?
        // A block buffer that owns its own memory, then a copy in — rather than pointing at the
        // `Data`'s storage, whose lifetime ends with this call while the sample buffer outlives it.
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

    /// Mark the sample for immediate display, and mark a delta frame as a non-sync sample.
    ///
    /// `NotSync` is what tells the decoder this frame is not a seek point. Getting it wrong does not
    /// break a forward-only stream, but it does mislead anything that later inspects the queue — and
    /// it costs one dictionary write to be honest.
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

    /// The stream's pixel dimensions, for the panel's aspect ratio. Read off the format description
    /// rather than the device's advertised screen size: a scaled stream (`--scale 2`) is smaller than
    /// the device, and it is the FRAME the view has to fit.
    static func dimensions(of formatDescription: CMVideoFormatDescription) -> CGSize {
        let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
        return CGSize(width: Int(dimensions.width), height: Int(dimensions.height))
    }
}
#endif
