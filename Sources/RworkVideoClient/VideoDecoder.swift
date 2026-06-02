#if canImport(VideoToolbox)
import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo
import OSLog
import RworkVideoProtocol

/// Errors raised by the video decoder.
public enum VideoDecoderError: Error {
    case sessionCreateFailed(OSStatus)
    case formatDescriptionFailed(OSStatus)
    case sampleBufferFailed(OSStatus)
    case decodeFailed(OSStatus)
}

/// Decodes reassembled HEVC frames with `VTDecompressionSession` (doc 04, doc 18 §F).
///
/// ⚠️ **HANG-SAFETY:** decode was MEASURED safe (~0.9-1.1ms synchronous,
/// single-frame, RESULTS.md "F") but to honour the hang-safety rule this type is
/// COMPILED + reviewed and its `decode` is NEVER called from a test — only from a
/// real client app. The session is created lazily from the first frame's format
/// description.
///
/// Configs (cited):
/// - `decodeFlags = []` → **synchronous single-frame** decode (MEASURED 0.9-1.1ms,
///   NOT 2-frame-buffered — RESULTS.md F / doc 18 §F).
/// - `RequireHardwareAcceleratedVideoDecoder = true` is set unconditionally.
/// - Output `CVPixelBuffer` is NV12 + Metal-compatible for the zero-copy renderer.
/// - Reassembled frames arrive as AVCC bytes; we wrap them in a `CMSampleBuffer`
///   against the running format description.
public final class VideoDecoder: @unchecked Sendable {
    /// Emits a decoded NV12 `CVPixelBuffer` for the renderer to draw at vsync.
    public typealias DecodedFrameHandler = @Sendable (CVImageBuffer) -> Void

    private let log = Logger(subsystem: "rwork.video.client", category: "VideoDecoder")
    private let decodedFrameHandler: DecodedFrameHandler

    private var session: VTDecompressionSession?
    private var formatDescription: CMFormatDescription?

    public init(decodedFrameHandler: @escaping DecodedFrameHandler) {
        self.decodedFrameHandler = decodedFrameHandler
    }

    deinit {
        if let session {
            // iOS background-suspend hang mitigation (doc 18 §F): invalidate async.
            VTDecompressionSessionInvalidate(session)
        }
    }

    /// Sets the format description (from the IDR's parameter sets) and (re)creates
    /// the session. Must precede the first `decode`. Recreate on resolution change.
    public func configure(formatDescription: CMFormatDescription) throws {
        if let session { VTDecompressionSessionInvalidate(session); self.session = nil }
        self.formatDescription = formatDescription

        let imageBufferAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, // NV12 (doc 04)
            kCVPixelBufferMetalCompatibilityKey: true,                                          // zero-copy to Metal
            kCVPixelBufferIOSurfacePropertiesKey: [:],
        ]
        var spec: [CFString: Any] = [:]
        // Require HW-accelerated HEVC decode (set unconditionally).
        spec[kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder] = true

        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: nil, formatDescription: formatDescription,
            decoderSpecification: spec as CFDictionary,
            imageBufferAttributes: imageBufferAttributes as CFDictionary,
            outputCallback: nil, decompressionSessionOut: &session
        )
        guard status == noErr, let session else { throw VideoDecoderError.sessionCreateFailed(status) }
        self.session = session
    }

    /// Decodes one reassembled AVCC frame synchronously (`decodeFlags = []`,
    /// MEASURED single-frame ~1ms). Hands the resulting NV12 buffer to the renderer.
    public func decode(_ frame: ReassembledFrame) throws {
        guard let session, let formatDescription else { throw VideoDecoderError.sessionCreateFailed(-12903) }
        let sampleBuffer = try makeSampleBuffer(avcc: frame.avcc, formatDescription: formatDescription)
        let handler = decodedFrameHandler
        let status = VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sampleBuffer, flags: [], infoFlagsOut: nil
        ) { status, _, imageBuffer, _, _ in
            guard status == noErr, let imageBuffer else { return }
            handler(imageBuffer) // NV12 CVPixelBuffer → MetalVideoRenderer at vsync
        }
        guard status == noErr else { throw VideoDecoderError.decodeFailed(status) }
    }

    /// Wraps AVCC bytes (length-prefixed NAL units — see RworkVideoProtocol.NALUnit)
    /// in a `CMSampleBuffer` against the running format description.
    ///
    /// Core Media OWNS the backing bytes: the block buffer is allocated with
    /// `kCFAllocatorDefault` + `memoryBlock: nil` (so it allocates `dataLength` bytes
    /// itself), then the AVCC bytes are COPIED in via `CMBlockBufferReplaceDataBytes`.
    /// We deliberately do NOT use `kCFAllocatorNull` over a local `NSMutableData`'s
    /// pointer — that only references the raw bytes without retaining them, a latent
    /// use-after-free if the local is freed (or its lifetime shortened by the optimizer)
    /// while the returned `CMSampleBuffer` still points at them. Copying makes the
    /// buffer self-contained and correct regardless of sync/async decode.
    private func makeSampleBuffer(avcc: Data, formatDescription: CMFormatDescription) throws -> CMSampleBuffer {
        let dataLength = avcc.count
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: dataLength, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: dataLength,
            flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &blockBuffer
        )
        guard status == noErr, let blockBuffer else { throw VideoDecoderError.sampleBufferFailed(status) }

        // Copy the AVCC bytes into the block buffer's own (Core Media-owned) storage.
        status = avcc.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return noErr } // empty frame: nothing to copy
            return CMBlockBufferReplaceDataBytes(
                with: base, blockBuffer: blockBuffer,
                offsetIntoDestination: 0, dataLength: dataLength
            )
        }
        guard status == noErr else { throw VideoDecoderError.sampleBufferFailed(status) }

        var sampleBuffer: CMSampleBuffer?
        var sampleSize = dataLength
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: blockBuffer,
            formatDescription: formatDescription, sampleCount: 1,
            sampleTimingEntryCount: 0, sampleTimingArray: nil,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else { throw VideoDecoderError.sampleBufferFailed(status) }
        return sampleBuffer
    }
}
#endif
