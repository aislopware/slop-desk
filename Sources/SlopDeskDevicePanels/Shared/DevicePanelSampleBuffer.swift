import CoreMedia
import Foundation

/// The CoreMedia half both device panels share: an AVCC access unit becoming a `CMSampleBuffer` that
/// `AVSampleBufferDisplayLayer` will show immediately.
///
/// Nothing here decodes. `CMBlockBuffer` and `CMSampleBuffer` are plain data objects — no session,
/// no device, no window server — which is what lets this layer be unit tested under the hang-safety
/// rule while the thing that ACTUALLY decodes stays in the view and out of every test.
///
/// What is NOT here is the format description, and that is the one real difference between the two
/// panels: the simulator server is asked for `format=avcc` and hands over an avcC record to parse;
/// `scrcpy` forwards raw `MediaCodec` output, so the parameter sets arrive as Annex-B NALs and
/// `CMVideoFormatDescriptionCreateFromH264ParameterSets` wants exactly those. Each panel keeps its
/// own `formatDescription`; from the access unit onwards there was never anything to tell apart, and
/// the two copies of THAT were identical down to the `-1` returned for a null base address.
package enum DevicePanelSampleBuffer {
    /// Wraps one AVCC access unit as a sample buffer ready to enqueue.
    ///
    /// Timing is deliberately ABSENT and `DisplayImmediately` set instead. Real presentation
    /// timestamps against a control timebase buy smooth playback of a recording and cost a frame of
    /// buffering; both of these panels are an interactive mirror of a device someone is tapping, so
    /// the frame is worth more than the smoothing.
    ///
    /// The block buffer OWNS its memory and the access unit is copied in, rather than pointing at
    /// the `Data`'s storage — that storage's lifetime ends with this call and the sample buffer
    /// outlives it. Getting that backwards is a use-after-free that looks like corrupted video.
    /// The stream's pixel dimensions, for the panel's aspect ratio.
    ///
    /// Read off the FORMAT DESCRIPTION rather than the device's advertised screen size, and on both
    /// panels for the same reason: the encoded frame is smaller than the device (`--scale 2` on the
    /// simulator, `max_size` on the bridge), and it is the FRAME the view has to fit. A session
    /// header that agrees today is a header that can disagree tomorrow.
    package static func dimensions(of formatDescription: CMVideoFormatDescription) -> CGSize {
        let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
        return CGSize(width: Int(dimensions.width), height: Int(dimensions.height))
    }

    package static func sampleBuffer(
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
    package static func annotate(_ sampleBuffer: CMSampleBuffer, isKeyframe: Bool) {
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
}
