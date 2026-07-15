#if canImport(VideoToolbox)
import CoreMedia
import XCTest
@testable import SlopDeskVideoClient

/// The Parsec-parity present-on-decode stamp (``VideoDecoder/stampDisplayImmediately(_:)``). Proves
/// the clone actually mutates the buffer: `kCMSampleAttachmentKey_DisplayImmediately` is ABSENT on a
/// freshly-built sample buffer and PRESENT (== true) after the stamp — the exact attachment parsecd
/// sets before every synchronous decode so no frame is held in the DPB for reorder. CoreMedia only
/// (no `VTDecompressionSession`), so this is hang-safe and runs headlessly in CI.
final class DisplayImmediateStampTests: XCTestCase {
    /// Builds a minimal ready HEVC sample buffer (dummy format description + 1-byte block buffer) the
    /// same shape ``VideoDecoder/makeSampleBuffer`` produces — enough for the attachment array to
    /// carry one per-sample dictionary. No hardware session is created.
    private func makeSampleBuffer() throws -> CMSampleBuffer {
        var formatDescription: CMFormatDescription?
        var status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, codecType: kCMVideoCodecType_HEVC,
            width: 16, height: 16, extensions: nil, formatDescriptionOut: &formatDescription,
        )
        try XCTSkipUnless(status == noErr, "format description create failed: \(status)")
        let fmt = try XCTUnwrap(formatDescription)

        var blockBuffer: CMBlockBuffer?
        let length = 1
        status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: length, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &blockBuffer,
        )
        try XCTSkipUnless(status == noErr, "block buffer create failed: \(status)")
        let block = try XCTUnwrap(blockBuffer)

        var sampleBuffer: CMSampleBuffer?
        var sampleSize = length
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: fmt,
            sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &sampleBuffer,
        )
        try XCTSkipUnless(status == noErr, "sample buffer create failed: \(status)")
        return try XCTUnwrap(sampleBuffer)
    }

    /// Reads the DisplayImmediately flag off the first per-sample attachment (nil if the array or key
    /// is absent) — the exact bridge the codebase uses to READ sample attachments.
    private func displayImmediately(_ sb: CMSampleBuffer) -> Bool? {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sb, createIfNecessary: false,
        ) as? [[CFString: Any]], let first = attachments.first else { return nil }
        return first[kCMSampleAttachmentKey_DisplayImmediately] as? Bool
    }

    // Prove-fail-before-fix: a freshly-built buffer has NO DisplayImmediately attachment, and the
    // stamp SETS it to true. Without the stamp the flag would stay absent — so this assert is not
    // tautological (the pre-condition is checked).
    func testStampAddsDisplayImmediatelyTrue() throws {
        let sb = try makeSampleBuffer()
        XCTAssertNil(displayImmediately(sb), "a fresh sample buffer must not already carry the flag")
        VideoDecoder.stampDisplayImmediately(sb)
        XCTAssertEqual(displayImmediately(sb), true, "stamp must set DisplayImmediately = true")
    }

    // Idempotent: stamping twice keeps it true (the decode path builds one buffer per frame, but the
    // stamp must never toggle or clear on a second application).
    func testStampIsIdempotent() throws {
        let sb = try makeSampleBuffer()
        VideoDecoder.stampDisplayImmediately(sb)
        VideoDecoder.stampDisplayImmediately(sb)
        XCTAssertEqual(displayImmediately(sb), true)
    }
}
#endif
