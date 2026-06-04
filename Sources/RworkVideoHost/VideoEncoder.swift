#if os(macOS)
import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo
import OSLog

/// Errors raised by the video encoder.
public enum VideoEncoderError: Error {
    case sessionCreateFailed(OSStatus)
    case notHardwareBacked
    case encodeFailed(OSStatus)
    /// A LATENCY-CRITICAL property failed to set. Carries the property key + the
    /// `OSStatus` so the caller can see exactly which proven low-latency setting did
    /// not apply (a silent failure here corrupts the measured doc-18 config).
    case propertyFailed(key: String, status: OSStatus)
}

/// The two-session HEVC encoder (doc 18 §E — **MEASURED + SOLVED**), built to the
/// EXACT configs validated in `docs/research/spikes/vtbench/encode-decode-bench.swift`.
///
/// ⚠️ **HANG-SAFETY:** `VTCompressionSessionCreate` + encode HW-accelerated HANG
/// without a window-server + Screen-Recording TCC session (RESULTS.md). This type is
/// COMPILED and code-reviewed but is NEVER instantiated in a test — only in a real
/// GUI host app.
///
/// - **Session A (live)** = low-latency-RC (MEASURED p50 7.5ms vs constant-quality
///   24ms → live MUST be low-latency-RC). Specification keys
///   `EnableLowLatencyRateControl=true` + `RequireHardwareAcceleratedVideoEncoder=
///   true`; property keys `RealTime=true`, `ExpectedFrameRate=30`,
///   `PrioritizeEncodingSpeedOverQuality=true`, `AllowFrameReordering=false`,
///   `MaxKeyFrameInterval=INT_MAX`, `AverageBitRate` + `DataRateLimits=[12_000_000/8,
///   1.0]` (12 Mbps hard cap, **/8 not /4**), `SpatialAdaptiveQPLevel=Disable` (BEST-EFFORT —
///   `kVTPropertyNotSupportedErr`/-12900 on encoders without the key; not latency-critical).
///   ProfileLevel OMITTED. HEVC Main 8-bit 4:2:0.
/// - **Session B (on-demand crisp)** = all-intra: `Quality=1.0` +
///   `AllowTemporalCompression=false`. There is NO `Lossless` key (-12900 — do not
///   use it).
///
/// Quirks honoured (RESULTS.md / doc 18 §E,§G):
/// - Do NOT query `UsingHardwareAcceleratedVideoEncoder` while low-latency is on
///   (returns -12900). HW support is gated at creation by
///   `RequireHardwareAcceleratedVideoEncoder=true` instead.
/// - Recreate the session on resize.
/// - Retry create on -12905 (XPC race) with 50-100ms backoff.
public final class VideoEncoder: @unchecked Sendable {
    /// 12 Mbps hard bitrate cap (doc 18 §E). DataRateLimits is `[maxBytes, seconds]`
    /// → `[12_000_000 / 8, 1.0]` = 1.5 MB per 1 s. **/8 (bits→bytes), not /4.**
    public static let bitrateBitsPerSecond = 12_000_000
    public static let dataRateMaxBytes = bitrateBitsPerSecond / 8 // 1_500_000
    /// -12905 (XPC) create-race retry backoff, 50-100ms (doc 18 §G).
    public static let createRetryBackoffNanos: UInt64 = 75_000_000

    /// Which session produced an output (carried to the packetizer's crisp flag).
    public enum Mode: Sendable { case live, crisp }

    /// Emitted for each finished encode: the AVCC bytes, keyframe flag, and which
    /// session produced it.
    public typealias OutputHandler = @Sendable (_ avcc: Data, _ keyframe: Bool, _ mode: Mode) -> Void

    private let log = Logger(subsystem: "rwork.video.host", category: "VideoEncoder")
    private let width: Int32
    private let height: Int32
    private let outputHandler: OutputHandler
    /// Live-session target bitrate (bits/sec). The 12 Mbps spike default is great for video,
    /// but SHARP TEXT (screen sharing) needs more bits or HEVC softens glyph edges — so the
    /// host can raise it (e.g. ~40 Mbps over LAN/NetBird) for crisp text.
    private let bitrate: Int

    private var liveSession: VTCompressionSession?
    private var crispSession: VTCompressionSession?

    public init(width: Int, height: Int, bitrate: Int = bitrateBitsPerSecond, outputHandler: @escaping OutputHandler) {
        self.width = Int32(width)
        self.height = Int32(height)
        self.bitrate = max(1_000_000, bitrate)
        self.outputHandler = outputHandler
    }

    deinit {
        if let liveSession { VTCompressionSessionInvalidate(liveSession) }
        if let crispSession { VTCompressionSessionInvalidate(crispSession) }
    }

    // MARK: Session A — live (low-latency-RC)

    /// Creates Session A exactly per the validated spike config. Throws
    /// ``VideoEncoderError/notHardwareBacked`` if HW is unavailable (gated at
    /// creation, not by querying UsingHW while low-latency is on — that returns
    /// -12900). Retries -12905 once with backoff (doc 18 §G).
    public func createLiveSession() throws {
        // Specification keys go in the CREATE dict, not via SetProperty (doc 17 §3.2).
        let spec: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true,
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true,
        ]

        var session: VTCompressionSession?
        var status = VTCompressionSessionCreate(
            allocator: nil, width: width, height: height,
            codecType: kCMVideoCodecType_HEVC, encoderSpecification: spec as CFDictionary,
            imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &session
        )
        if status == -12905 { // XPC create race — retry once after backoff (doc 18 §G).
            log.notice("live session create -12905, retrying after backoff")
            usleep(useconds_t(Self.createRetryBackoffNanos / 1000))
            status = VTCompressionSessionCreate(
                allocator: nil, width: width, height: height,
                codecType: kCMVideoCodecType_HEVC, encoderSpecification: spec as CFDictionary,
                imageBufferAttributes: nil, compressedDataAllocator: nil,
                outputCallback: nil, refcon: nil, compressionSessionOut: &session
            )
        }
        guard status == noErr, let session else { throw VideoEncoderError.sessionCreateFailed(status) }

        // Property keys (via VTSessionSetProperty). EXACT spike config. The
        // LATENCY-CRITICAL keys THROW on failure — a silent failure here corrupts the
        // proven low-latency config (doc 18 §E). Best-effort keys are set leniently
        // (logged on failure) since they degrade quality, not the latency contract.
        try setCritical(session, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        set(session, kVTCompressionPropertyKey_ExpectedFrameRate, 30 as CFNumber) // best-effort
        set(session, kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, kCFBooleanTrue) // best-effort
        try setCritical(session, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse) // no B-frames — latency-critical
        set(session, kVTCompressionPropertyKey_MaxKeyFrameInterval, Int(Int32.max) as CFNumber) // IDR on-demand (best-effort)
        // AverageBitRate + DataRateLimits together ARE the low-latency rate-control
        // contract — both latency-critical.
        try setCritical(session, kVTCompressionPropertyKey_AverageBitRate, bitrate as CFNumber)
        // DataRateLimits = [maxBytes, seconds]; hard cap at the configured bitrate (/8 not /4).
        try setCritical(session, kVTCompressionPropertyKey_DataRateLimits, [bitrate / 8, 1.0] as CFArray)
        // SpatialAdaptiveQPLevel=Disable is a QP-modulation HINT. The spike host advertised it,
        // but it is kVTPropertyNotSupportedErr (-12900) on HEVC encoders that don't implement
        // the key — and low-latency rate control is ALREADY established by
        // EnableLowLatencyRateControl (spec) + AverageBitRate/DataRateLimits. So set it
        // BEST-EFFORT: apply it where supported, tolerate -12900 elsewhere. (Forcing it as
        // critical aborted the WHOLE encoder on such hardware, leaving PATH 2 unable to produce
        // a single frame — observed via check-video.sh's host diagnostics, 2026-06-02.)
        set(session, kVTCompressionPropertyKey_SpatialAdaptiveQPLevel, kVTQPModulationLevel_Disable as CFNumber)
        // ProfileLevel OMITTED for the low-latency session (doc 18 §E).
        // NOTE: do NOT query UsingHardwareAcceleratedVideoEncoder here — it returns
        // -12900 with low-latency on; HW is already gated by Require...=true above.

        VTCompressionSessionPrepareToEncodeFrames(session)
        self.liveSession = session
    }

    // MARK: Session B — on-demand crisp (all-intra)

    /// Creates Session B: max-quality all-intra for the idle-time dirty-rect refresh
    /// (doc 17 §3.4). `Quality=1.0` + `AllowTemporalCompression=false`; HEVC Main
    /// 8-bit via `kVTProfileLevel_HEVC_Main_AutoLevel`. No `Lossless` key (-12900).
    public func createCrispSession() throws {
        let spec: [CFString: Any] = [
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true,
        ]
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil, width: width, height: height,
            codecType: kCMVideoCodecType_HEVC, encoderSpecification: spec as CFDictionary,
            imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &session
        )
        guard status == noErr, let session else { throw VideoEncoderError.sessionCreateFailed(status) }

        set(session, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        set(session, kVTCompressionPropertyKey_Quality, 1.0 as CFNumber)
        set(session, kVTCompressionPropertyKey_AllowTemporalCompression, kCFBooleanFalse) // all-intra
        set(session, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_HEVC_Main_AutoLevel)

        VTCompressionSessionPrepareToEncodeFrames(session)
        self.crispSession = session
    }

    // MARK: Encode

    /// Encodes a live frame on Session A. `forceKeyframe` sets the IDR frame property
    /// (heartbeat / loss recovery). The pixel buffer is the NV12 `CVPixelBuffer`
    /// handed straight from `WindowCapturer` (zero-copy).
    public func encodeLive(pixelBuffer: CVPixelBuffer, presentationTime: CMTime, forceKeyframe: Bool) throws {
        guard let session = liveSession else { throw VideoEncoderError.sessionCreateFailed(-12903) }
        try encode(session: session, pixelBuffer: pixelBuffer, presentationTime: presentationTime, forceKeyframe: forceKeyframe, mode: .live)
    }

    /// Encodes a crisp (all-intra) frame on Session B for the idle dirty-rect refresh.
    public func encodeCrisp(pixelBuffer: CVPixelBuffer, presentationTime: CMTime) throws {
        guard let session = crispSession else { throw VideoEncoderError.sessionCreateFailed(-12903) }
        // Always a keyframe — Session B is all-intra.
        try encode(session: session, pixelBuffer: pixelBuffer, presentationTime: presentationTime, forceKeyframe: true, mode: .crisp)
    }

    private func encode(session: VTCompressionSession, pixelBuffer: CVPixelBuffer, presentationTime: CMTime, forceKeyframe: Bool, mode: Mode) throws {
        var frameProperties: CFDictionary?
        if forceKeyframe {
            frameProperties = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
        }
        let handler = outputHandler
        let status = VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixelBuffer, presentationTimeStamp: presentationTime,
            duration: .invalid, frameProperties: frameProperties, infoFlagsOut: nil
        ) { status, _, sampleBuffer in
            guard status == noErr, let sampleBuffer else { return }
            Self.deliver(sampleBuffer: sampleBuffer, mode: mode, handler: handler)
        }
        guard status == noErr else { throw VideoEncoderError.encodeFailed(status) }
    }

    /// Extracts the AVCC bytes + keyframe flag from a finished `CMSampleBuffer` and
    /// forwards them. The block buffer holds length-prefixed NAL units (the client
    /// re-prefixes when it reassembles fragments — see RworkVideoProtocol.NALUnit).
    private static func deliver(sampleBuffer: CMSampleBuffer, mode: Mode, handler: OutputHandler) {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &totalLength, dataPointerOut: &dataPointer) == noErr,
              let dataPointer else { return }
        var avcc = Data(bytes: dataPointer, count: totalLength)

        // Keyframe? Absence of the not-sync attachment ⇒ keyframe.
        var keyframe = true
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
           let first = attachments.first,
           let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool {
            keyframe = !notSync
        }

        // CRITICAL: VTCompressionSession keeps the HEVC VPS/SPS/PPS parameter sets in the sample
        // buffer's FORMAT DESCRIPTION, NOT inline in the CMBlockBuffer — so the bytes above are
        // the coded slice ONLY. The client builds its CMVideoFormatDescription from parameter
        // sets it expects to find INLINE ahead of the IDR slice (HEVCParameterSets.extract); with
        // none present it can never decode (`awaitingKeyframe`) and the window stays blank. So on
        // a keyframe we prepend the VPS/SPS/PPS (length-prefixed, same 4-byte AVCC framing) pulled
        // from the format description. (Found via check-video.sh's client decode diagnostics,
        // 2026-06-02 — the prior "host emits parameter sets inline" assumption was wrong.)
        if keyframe, let fmt = CMSampleBufferGetFormatDescription(sampleBuffer),
           let params = hevcParameterSetsAVCC(from: fmt) {
            avcc = params + avcc
        }
        handler(avcc, keyframe, mode)
    }

    /// Extracts the HEVC VPS/SPS/PPS parameter sets from a `CMVideoFormatDescription` and returns
    /// them as length-prefixed (4-byte big-endian) AVCC NAL units, in index order — ready to
    /// prepend to a keyframe's coded slice so the client can build its decode format description.
    /// Returns `nil` if the description carries no parameter sets.
    private static func hevcParameterSetsAVCC(from formatDescription: CMFormatDescription) -> Data? {
        var count = 0
        let probe = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
            formatDescription, parameterSetIndex: 0,
            parameterSetPointerOut: nil, parameterSetSizeOut: nil,
            parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
        guard probe == noErr, count > 0 else { return nil }

        var out = Data()
        for index in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            let status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                formatDescription, parameterSetIndex: index,
                parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            guard status == noErr, let pointer, size > 0 else { return nil }
            var lengthBE = UInt32(size).bigEndian
            withUnsafeBytes(of: &lengthBE) { out.append(contentsOf: $0) }   // 4-byte AVCC length
            out.append(UnsafeBufferPointer(start: pointer, count: size))
        }
        return out
    }

    /// Re-creates both sessions on a window resize (doc 18 §G — recreate on resize).
    /// The caller passes the new dimensions by constructing a fresh `VideoEncoder`.

    /// Drains BOTH compression sessions, blocking until every in-flight frame's output
    /// callback has fired (`VTCompressionSessionCompleteFrames` with an INVALID timestamp = the
    /// documented "complete ALL pending frames" sentinel). Call this before dropping the OLD
    /// encoder on a resize swap: without it the encoder is invalidated (by `deinit`) while frames
    /// are still queued, silently dropping their already-encoded output (FFmpeg videotoolboxenc
    /// CompleteFrames-before-invalidate pattern). Purely ADDITIVE — does NOT touch the hot
    /// `encodeLive` path. Safe to call once; the sessions are not reused afterward.
    public func completeFrames() {
        if let liveSession { VTCompressionSessionCompleteFrames(liveSession, untilPresentationTimeStamp: .invalid) }
        if let crispSession { VTCompressionSessionCompleteFrames(crispSession, untilPresentationTimeStamp: .invalid) }
    }

    /// Sets a LATENCY-CRITICAL property and THROWS ``VideoEncoderError/propertyFailed(key:status:)``
    /// if it does not apply. Used for the proven low-latency rate-control keys
    /// (RealTime, AllowFrameReordering, AverageBitRate, DataRateLimits) where a silent
    /// failure corrupts the measured config (doc 18 §E). The encoder must NOT proceed with a
    /// half-applied low-latency config. (SpatialAdaptiveQPLevel is deliberately NOT here — it
    /// is best-effort; some HEVC encoders return -12900 for it and aborting would yield zero
    /// frames.)
    private func setCritical(_ session: VTCompressionSession, _ key: CFString, _ value: CFTypeRef) throws {
        let status = VTSessionSetProperty(session, key: key, value: value)
        guard status == noErr else {
            log.error("critical VTSessionSetProperty \(key as String) failed: \(status)")
            throw VideoEncoderError.propertyFailed(key: key as String, status: status)
        }
    }

    /// Sets a best-effort property: a failure degrades quality, not the latency
    /// contract, so it is logged and tolerated (e.g. ExpectedFrameRate). Returns the
    /// status for callers that care.
    @discardableResult
    private func set(_ session: VTCompressionSession, _ key: CFString, _ value: CFTypeRef) -> OSStatus {
        let status = VTSessionSetProperty(session, key: key, value: value)
        if status != noErr {
            log.error("VTSessionSetProperty \(key as String) failed (best-effort, tolerated): \(status)")
        }
        return status
    }
}
#endif
