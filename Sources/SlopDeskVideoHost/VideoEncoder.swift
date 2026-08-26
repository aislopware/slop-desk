#if os(macOS)
import CoreMedia
import CoreVideo
import CSlopDeskFFI
import Foundation
import SlopDeskVideoProtocol

/// Errors raised by the video encoder.
///
/// Two cases where there were four. `notHardwareBacked` and `propertyFailed` described failures the
/// far side now decides between and reports as one `OSStatus`: a create that could not produce a
/// session, whatever the reason, and an encode the framework refused. Neither had a caller that
/// matched on it — every catch site logged `String(describing:)` — so a distinction nothing read is
/// not a distinction to carry across a boundary.
public enum VideoEncoderError: Error {
    /// The session could not be created, or a latency-critical property was rejected.
    case sessionCreateFailed(OSStatus)
    /// The framework refused this frame.
    case encodeFailed(OSStatus)
}

/// The face of the HEVC encoder. Every decision behind it is Rust's.
///
/// This was 1500 lines, of which roughly 350 called VideoToolbox and the rest were rules nothing
/// could reach — the old header said so itself, because `VTCompressionSessionCreate` hangs without a
/// window server and a Screen-Recording grant, so a constructor nobody could call held a dozen
/// environment parses, three clamps and a seven-field rate-control state machine that no test ever
/// ran a line of.
///
/// Behind `slopdesk_video_encoder_*` now: the session and every property write
/// (`slopdesk-apple-vt`), every knob resolved and clamped (`slopdesk_video::encoder_config`), and
/// the whole state machine — the crisp and compact brackets, the three quantiser regimes, the
/// drop-relief integrator, the deferred restore (`slopdesk_video::encoder_state`). What is left here
/// is the pixel buffer, the timestamp, and turning bytes into a `Data`.
///
/// The frame callback is THE ONE door in `slopdesk_ffi.h` that calls back rather than answering when
/// asked, and its terms are in the header. The two this face must keep: the bytes are borrowed for
/// the duration of the call, and the context must outlive the handle.
public final class VideoEncoder: @unchecked Sendable {
    /// The default target bitrate, in bits per second.
    public static var bitrateBitsPerSecond: Int { Int(slopdesk_video_encoder_default_bitrate()) }

    /// The worst-case quantiser ceiling this process resolved.
    public static var maxAllowedFrameQP: Int { Int(slopdesk_video_encoder_max_allowed_frame_qp()) }

    /// The const-QP seed, or nil when the mode is off. PRESENCE is what engages it, and the door
    /// answers zero for absent — a value the `[1, 51]` range cannot otherwise produce.
    public static var constQP: Int? {
        let seed = slopdesk_video_encoder_const_qp()
        return seed >= 1 ? Int(seed) : nil
    }

    /// One finished frame: the AVCC bytes, whether a decoder may start here, which refresh produced
    /// it, the long-term-reference token it carries, and whether it was anchored on an acknowledged
    /// reference rather than on an intra frame.
    public typealias OutputHandler = @Sendable (
        _ avcc: Data,
        _ keyframe: Bool,
        _ mode: Mode,
        _ ltrToken: Int64?,
        _ ackedAnchored: Bool,
    ) -> Void

    /// Which refresh produced a frame. The wire tags the near-lossless static one differently.
    public enum Mode: Sendable {
        case live
        case crisp
    }

    /// What the C callback's context points at.
    ///
    /// A class, retained across the boundary and released only after the handle is freed, because
    /// the callback runs on a VideoToolbox thread and the handle is what bounds its lifetime.
    private final class Box {
        let handler: OutputHandler
        init(_ handler: @escaping OutputHandler) { self.handler = handler }
    }

    private let width: Int32
    private let height: Int32
    private let bitrate: Int
    private let fps: Int
    private let fullRange: Bool
    private let ltrEnabled: Bool
    private let box: Box
    private var handle: OpaquePointer?
    private var context: UnsafeMutableRawPointer?

    public init(
        width: Int,
        height: Int,
        bitrate: Int = VideoEncoder.bitrateBitsPerSecond,
        fps: Int = 60,
        fullRange: Bool = false,
        ltrEnabled: Bool = false,
        outputHandler: @escaping OutputHandler,
    ) {
        self.width = Int32(clamping: width)
        self.height = Int32(clamping: height)
        self.bitrate = bitrate
        self.fps = max(1, fps)
        self.fullRange = fullRange
        self.ltrEnabled = ltrEnabled
        box = Box(outputHandler)
    }

    deinit {
        // Freeing drains first — a session invalidated with frames still queued silently discards
        // output that was already encoded — so the context cannot be released until it returns.
        if let handle { slopdesk_video_encoder_free(handle) }
        if let context { Unmanaged<Box>.fromOpaque(context).release() }
    }

    /// Creates the hardware session and applies the whole low-latency configuration.
    public func createLiveSession() throws {
        guard handle == nil else { return }
        let retained = Unmanaged.passRetained(box).toOpaque()
        var status: Int32 = 0
        let created = slopdesk_video_encoder_new(
            width,
            height,
            Int64(bitrate),
            Int64(fps),
            fullRange,
            ltrEnabled,
            EnvConfig.boolDefaultOn("SLOPDESK_QP_DECOUPLE"),
            retained,
            { context, avcc, len, keyframe, crisp, ltrToken, hasLTRToken, ackedAnchored in
                guard let context, let avcc else { return }
                // The bytes are borrowed for THIS CALL. `Data(bytes:count:)` is the copy the door's
                // terms require, and it is the only one in the system for an ordinary delta frame —
                // the far side hands those over where the encoder left them.
                let payload = Data(bytes: avcc, count: len)
                let box = Unmanaged<Box>.fromOpaque(context).takeUnretainedValue()
                box.handler(
                    payload,
                    keyframe,
                    crisp ? .crisp : .live,
                    hasLTRToken ? ltrToken : nil,
                    ackedAnchored,
                )
            },
            &status,
        )
        guard let created else {
            Unmanaged<Box>.fromOpaque(retained).release()
            throw VideoEncoderError.sessionCreateFailed(status)
        }
        context = retained
        handle = created
    }

    /// Encodes one live frame from the capturer's NV12 buffer.
    public func encodeLive(
        pixelBuffer: CVPixelBuffer,
        presentationTime: CMTime,
        forceKeyframe: Bool,
        perFrameMaxQP: Int? = nil,
    ) throws {
        try run { handle in
            slopdesk_video_encoder_encode_live(
                handle,
                Unmanaged.passUnretained(pixelBuffer).toOpaque(),
                presentationTime.value,
                presentationTime.timescale,
                forceKeyframe,
                Int32(clamping: perFrameMaxQP ?? 0),
                perFrameMaxQP != nil,
            )
        }
    }

    /// Encodes the near-lossless static refresh: bracketed, drained on both sides, sharp.
    public func encodeLiveCrispKeyframe(pixelBuffer: CVPixelBuffer, presentationTime: CMTime) throws {
        try run { handle in
            slopdesk_video_encoder_encode_crisp(
                handle,
                Unmanaged.passUnretained(pixelBuffer).toOpaque(),
                presentationTime.value,
                presentationTime.timescale,
            )
        }
    }

    /// Encodes a recovery or heartbeat intra frame small enough to survive a burst.
    public func encodeCompactKeyframe(pixelBuffer: CVPixelBuffer, presentationTime: CMTime) throws {
        try run { handle in
            slopdesk_video_encoder_encode_compact(
                handle,
                Unmanaged.passUnretained(pixelBuffer).toOpaque(),
                presentationTime.value,
                presentationTime.timescale,
            )
        }
    }

    /// Encodes a cheap refresh anchored on an acknowledged long-term reference.
    public func encodeLiveLTRRefresh(pixelBuffer: CVPixelBuffer, presentationTime: CMTime) throws {
        try run { handle in
            slopdesk_video_encoder_encode_ltr_refresh(
                handle,
                Unmanaged.passUnretained(pixelBuffer).toOpaque(),
                presentationTime.value,
                presentationTime.timescale,
            )
        }
    }

    /// Actuates the live target bitrate. Returns whether it changed.
    @discardableResult
    public func setLiveBitrate(_ target: Int) -> Bool {
        guard let handle else { return false }
        return slopdesk_video_encoder_set_live_bitrate(handle, Int64(target))
    }

    /// Sets the link controller's constant quantiser. Returns whether it changed.
    @discardableResult
    public func setConstQP(_ q: Int) -> Bool {
        guard let handle else { return false }
        return slopdesk_video_encoder_set_const_qp(handle, Int32(clamping: q))
    }

    /// Records the controller's congestion verdict. Returns whether it changed.
    @discardableResult
    public func setLinkCongested(_ congested: Bool) -> Bool {
        guard let handle else { return false }
        return slopdesk_video_encoder_set_link_congested(handle, congested)
    }

    /// Hints the rate-control window at a new frame rate.
    public func setExpectedFrameRate(_ fps: Int) {
        guard let handle else { return }
        slopdesk_video_encoder_set_expected_frame_rate(handle, Int64(max(1, fps)))
    }

    /// Stages a long-term-reference token the client acknowledged decoding.
    public func stageAcknowledgedToken(_ token: Int64) {
        guard let handle else { return }
        slopdesk_video_encoder_stage_acked_token(handle, token)
    }

    /// Drops every staged token, because a keyframe just shipped and flushed the client's picture
    /// buffer, long-term references included.
    public func clearStagedAckedTokens() {
        guard let handle else { return }
        slopdesk_video_encoder_clear_staged_tokens(handle)
    }

    /// Blocks until every frame presented so far has reached the handler. Call before dropping this
    /// encoder on a resize swap.
    public func completeFrames() {
        guard let handle else { return }
        _ = slopdesk_video_encoder_complete_frames(handle)
    }

    /// Runs one door and turns a non-zero status into the one error an encode can raise.
    private func run(_ body: (OpaquePointer) -> Int32) throws {
        guard let handle else { throw VideoEncoderError.sessionCreateFailed(OSStatus(-12903)) }
        let status = body(handle)
        guard status == noErr else { throw VideoEncoderError.encodeFailed(status) }
    }
}
#endif
