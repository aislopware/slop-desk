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
    /// A non-keyframe arrived before any IDR established the format description, so we
    /// cannot decode it (the client drops it and waits for / requests a keyframe).
    case awaitingKeyframe
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
    /// The parameter sets the running ``session`` was configured from, cached so a
    /// byte-identical keyframe (the ~1s heartbeat IDR, every forced-recovery IDR) does
    /// NOT tear down + recreate the `VTDecompressionSession` (BUG-I): teardown/warmup
    /// every second stalled an otherwise-healthy stream. Reconfigure only when the
    /// extracted sets actually DIFFER (a real resolution / SPS change). `nil` until the
    /// first keyframe configures the session.
    private var currentParameterSets: HEVCParameterSets.ParameterSets?

    /// Test seam (FIX #3): the parameter sets the live session is currently built from,
    /// or `nil` if there is no session (e.g. after ``invalidateSession()``). Lets a unit
    /// test assert the cache state — and therefore that the NEXT byte-identical keyframe
    /// would reconfigure (`needsReconfigure(current: nil, ...) == true`) after a hard
    /// failure — WITHOUT creating a real `VTDecompressionSession` or driving a decode.
    var cachedParameterSetsForTesting: HEVCParameterSets.ParameterSets? { currentParameterSets }

    /// Test seam (FIX #3): seeds the cached parameter sets WITHOUT building a real
    /// `VTDecompressionSession`, so a unit test can model a healthy, configured decoder
    /// and then verify that ``invalidateSession()`` (the hard-failure path) clears the
    /// cache — forcing the next byte-identical keyframe to reconfigure. Never used in
    /// production; the live path sets the cache only via a successful `configure`.
    func seedCachedParameterSetsForTesting(_ sets: HEVCParameterSets.ParameterSets) {
        currentParameterSets = sets
    }

    public init(decodedFrameHandler: @escaping DecodedFrameHandler) {
        self.decodedFrameHandler = decodedFrameHandler
    }

    deinit {
        if let session {
            // iOS background-suspend hang mitigation (doc 18 §F): invalidate async.
            VTDecompressionSessionInvalidate(session)
        }
    }

    /// Builds the HEVC `CMVideoFormatDescription` from the VPS/SPS/PPS parameter sets
    /// the host streams inline ahead of an IDR slice (the host ships raw AVCC, no
    /// out-of-band parameter sets — see ``HEVCParameterSets``) and (re)creates the
    /// session. Recreate on a resolution change (a fresh IDR carries fresh sets).
    public func configure(parameterSets: HEVCParameterSets.ParameterSets) throws {
        let sets = parameterSets.ordered
        var formatDescription: CMFormatDescription?
        let status: OSStatus = sets.withUnsafeParameterSetPointers { pointers, sizes in
            CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: kCFAllocatorDefault,
                parameterSetCount: pointers.count,
                parameterSetPointers: pointers,
                parameterSetSizes: sizes,
                nalUnitHeaderLength: Int32(NALUnit.lengthPrefixSize),
                extensions: nil,
                formatDescriptionOut: &formatDescription
            )
        }
        guard status == noErr, let formatDescription else {
            throw VideoDecoderError.formatDescriptionFailed(status)
        }
        try configure(formatDescription: formatDescription)
        // Cache the sets the live session is now built from so a byte-identical keyframe
        // can reuse the session instead of recreating it (BUG-I). Set AFTER a successful
        // configure so a throw leaves the cache matching the still-running session.
        currentParameterSets = parameterSets
    }

    /// Whether a keyframe's parameter sets require rebuilding the decode session: there
    /// is no session yet, or the incoming sets differ byte-for-byte from the ones the
    /// running session was built from. Pure (only compares `Equatable` value types) so
    /// the "identical IDR does not reconfigure" decision is unit-testable with ZERO
    /// VideoToolbox dependency. The session-reuse fix for BUG-I.
    public static func needsReconfigure(
        current: HEVCParameterSets.ParameterSets?,
        incoming: HEVCParameterSets.ParameterSets
    ) -> Bool {
        current != incoming
    }

    /// Force-tears the live `VTDecompressionSession` down so the NEXT keyframe — even one
    /// whose VPS/SPS/PPS are byte-identical to the current ones — re-runs `configure()`
    /// and builds a FRESH session (FIX #3). Without this, a HARD decode failure on a
    /// fixed-capture-size stream was unrecoverable: the forced-recovery IDR carries
    /// byte-identical parameter sets, so
    /// `needsReconfigure` returned `false` and the SAME malfunctioning session was reused
    /// forever, freezing the pane permanently. The caller (``RworkVideoClientSession``'s
    /// decode `catch`) invokes this BEFORE `requestIDR()` so the next keyframe rebuilds.
    ///
    /// Clears `currentParameterSets` too, so the byte-identical recovery keyframe is seen
    /// as a reconfigure (`current == nil` ⇒ `needsReconfigure == true`). This is ONLY
    /// called on a decode FAILURE — the healthy heartbeat-IDR reuse path (BUG-I) keeps
    /// the cached sets on a SUCCESSFUL decode and is untouched.
    public func invalidateSession() {
        if let session {
            VTDecompressionSessionInvalidate(session)
            self.session = nil
        }
        currentParameterSets = nil
    }

    /// Sets the format description and (re)creates the session. Must precede the first
    /// `decode`. Recreate on resolution change.
    public func configure(formatDescription: CMFormatDescription) throws {
        if let session { VTDecompressionSessionInvalidate(session); self.session = nil }
        self.formatDescription = formatDescription
        // This path builds the session from a raw format description, not parameter
        // sets, so drop any cached sets — a later identical-sets keyframe must rebuild
        // rather than wrongly reuse a session that wasn't built from those sets. The
        // `configure(parameterSets:)` path re-populates the cache after this returns.
        currentParameterSets = nil

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
    ///
    /// Self-configuring: a **keyframe** carries its VPS/SPS/PPS inline, so we
    /// (re)build the format description + session from it before decoding (handling
    /// the first IDR AND a mid-stream resolution change). A non-keyframe that arrives
    /// before any IDR cannot be decoded — it throws ``VideoDecoderError/awaitingKeyframe``
    /// so the caller drops it and requests recovery.
    public func decode(_ frame: ReassembledFrame) throws {
        if frame.keyframe, let sets = HEVCParameterSets.extract(from: frame.avcc) {
            // Only rebuild the VTDecompressionSession when the parameter sets actually
            // changed (BUG-I). The heartbeat IDR (~1×/sec) and every forced-recovery IDR
            // carry byte-identical VPS/SPS/PPS on a steady stream — recreating the
            // session for each one caused a teardown/warmup stall once a second. A
            // matching keyframe keeps the existing session and just decodes below.
            if Self.needsReconfigure(current: currentParameterSets, incoming: sets) {
                try configure(parameterSets: sets)
            }
        }
        guard let session, let formatDescription else { throw VideoDecoderError.awaitingKeyframe }
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

private extension Array where Element == Data {
    /// Exposes parallel base-pointer + size arrays for the parameter-set bytes, valid
    /// only for the duration of `body` (the pointers reference the `Data`'s storage).
    /// `CMVideoFormatDescriptionCreateFromHEVCParameterSets` copies the bytes, so the
    /// scoped lifetime is sufficient.
    func withUnsafeParameterSetPointers<R>(
        _ body: ([UnsafePointer<UInt8>], [Int]) -> R
    ) -> R {
        func recurse(index: Int, pointers: [UnsafePointer<UInt8>], sizes: [Int]) -> R {
            if index == count { return body(pointers, sizes) }
            return self[index].withUnsafeBytes { raw -> R in
                let base = raw.bindMemory(to: UInt8.self).baseAddress!
                return recurse(index: index + 1, pointers: pointers + [base], sizes: sizes + [self[index].count])
            }
        }
        return recurse(index: 0, pointers: [], sizes: [])
    }
}
#endif
