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
/// - `RequireHardwareAcceleratedVideoDecoder` is version-gated behind `@available
///   (iOS 17)` (doc 18 §F: iOS <=16 HEVC HW-decode is the default on A-series).
/// - Output `CVPixelBuffer` is NV12 + Metal-compatible for the zero-copy renderer.
/// - Reassembled frames arrive as AVCC bytes; we wrap them in a `CMSampleBuffer`
///   against the running format description.
@available(macOS 14.0, iOS 17.0, *)
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
        // RequireHardwareAcceleratedVideoDecoder is version-gated behind the type's
        // @available(macOS 14.0, iOS 17.0) bound (doc 18 §F: iOS <=16 HEVC HW-decode
        // is the default on A-series anyway, so requiring it pre-iOS-17 is needless).
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
    private func makeSampleBuffer(avcc: Data, formatDescription: CMFormatDescription) throws -> CMSampleBuffer {
        var blockBuffer: CMBlockBuffer?
        let mutableData = NSMutableData(data: avcc)
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: mutableData.mutableBytes,
            blockLength: mutableData.length, blockAllocator: kCFAllocatorNull,
            customBlockSource: nil, offsetToData: 0, dataLength: mutableData.length,
            flags: 0, blockBufferOut: &blockBuffer
        )
        guard status == noErr, let blockBuffer else { throw VideoDecoderError.sampleBufferFailed(status) }

        var sampleBuffer: CMSampleBuffer?
        var sampleSize = mutableData.length
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
