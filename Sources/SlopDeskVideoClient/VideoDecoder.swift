#if canImport(VideoToolbox)
import CoreVideo
import CSlopDeskFFI
import Foundation
import SlopDeskVideoProtocol

/// Errors raised by the video decoder.
///
/// Two cases where there were five. `sessionCreateFailed`, `formatDescriptionFailed`,
/// `sampleBufferFailed` and `decodeFailed` all described a step of the same thing — the framework
/// refused — and no caller ever matched on which: every catch site logged `String(describing:)` and
/// ran the same recovery. `awaitingKeyframe` survives because a caller DOES match on it, and must:
/// it asks the host for an anchor without tearing the session down.
public enum VideoDecoderError: Error {
    /// The framework refused. The caller invalidates, then asks for a keyframe.
    case decodeFailed(OSStatus)
    /// Nothing can be decoded until a keyframe arrives. The session, if any, stays up.
    case awaitingKeyframe
}

/// The face of the HEVC decoder. Every decision behind it is Rust's.
///
/// Behind `slopdesk_video_decoder_*`: the session, the format description and the sample buffer
/// (`slopdesk-apple-vt`), and every rule that drives them (`slopdesk_video::decoder_state`) — when a
/// keyframe is worth rebuilding for, what an empty frame means, how the decode wall folds into the
/// stats HUD's average. What is left here is a `Data`, a `Bool`, and turning four outcome codes into
/// the two a caller acts on.
///
/// This door's callback differs from the encoder's in ONE term, and it is the term that matters:
/// pixels arrive at **+1**, and `takeRetainedValue()` below is the release the contract requires. It
/// hands over rather than lending because the consumer is a display-link pacer that holds the buffer
/// until the next vsync — always after the callback returns.
public final class VideoDecoder: @unchecked Sendable {
    /// Emits a decoded NV12 `CVPixelBuffer` for the renderer to draw at vsync.
    public typealias DecodedFrameHandler = @Sendable (CVImageBuffer) -> Void

    /// What the C callback's context points at.
    ///
    /// A class, retained across the boundary and released only after the handle is freed. The decode
    /// is synchronous so the callback cannot outlive a call, but the handle is still what bounds the
    /// context's lifetime and the ordering in `deinit` says so.
    private final class Box {
        let handler: DecodedFrameHandler
        init(_ handler: @escaping DecodedFrameHandler) { self.handler = handler }
    }

    private let context: UnsafeMutableRawPointer
    private let handle: OpaquePointer?

    /// Requests the FULL-RANGE NV12 output variant rather than the video-range one.
    ///
    /// Set from the stream's negotiated `helloAck.fullRange` before any media arrives. The two
    /// variants share a plane layout, so the renderer's texture creation is unaffected; what differs
    /// is the range, and therefore the shader coefficients the renderer pairs with it.
    public var outputFullRange = false {
        didSet {
            guard let handle else { return }
            slopdesk_video_decoder_set_full_range(handle, outputFullRange)
        }
    }

    public init(decodedFrameHandler: @escaping DecodedFrameHandler) {
        context = Unmanaged.passRetained(Box(decodedFrameHandler)).toOpaque()
        handle = slopdesk_video_decoder_new(context) { context, imageBuffer in
            guard let context, let imageBuffer else { return }
            // +1: the door's terms make this side the owner, and `takeRetainedValue` IS the release.
            let image = Unmanaged<CVImageBuffer>.fromOpaque(imageBuffer).takeRetainedValue()
            Unmanaged<Box>.fromOpaque(context).takeUnretainedValue().handler(image)
        }
    }

    deinit {
        // The handle first: it owns the session, and the context must outlive it.
        if let handle { slopdesk_video_decoder_free(handle) }
        Unmanaged<Box>.fromOpaque(context).release()
    }

    /// Decodes one reassembled AVCC frame synchronously and hands the pixels to the handler.
    ///
    /// Self-configuring: a keyframe carries its VPS/SPS/PPS inline and one whose sets DIFFER from the
    /// running session's rebuilds before decoding, which covers both the first IDR and a mid-stream
    /// resolution change. One whose sets MATCH — the heartbeat IDR, about once a second — reuses the
    /// session, because a teardown and warmup that often is a stall on a healthy stream.
    public func decode(_ frame: ReassembledFrame) throws {
        guard let handle else { throw VideoDecoderError.awaitingKeyframe }
        var status: Int32 = noErr
        let outcome = frame.avcc.withUnsafeBytes { raw in
            slopdesk_video_decoder_decode(
                handle,
                raw.bindMemory(to: UInt8.self).baseAddress,
                raw.count,
                frame.keyframe,
                &status,
            )
        }
        switch outcome {
        case SLOPDESK_DECODE_DELIVERED,
             SLOPDESK_DECODE_DROPPED:
            return
        case SLOPDESK_DECODE_NEEDS_KEYFRAME: throw VideoDecoderError.awaitingKeyframe
        default: throw VideoDecoderError.decodeFailed(status)
        }
    }

    /// Force-tears the live session down so the NEXT keyframe — even a byte-identical one — rebuilds.
    ///
    /// Called by the session's decode `catch` before `requestIDR()`. Without it, a hard failure on a
    /// fixed-capture-size stream is unrecoverable: the recovery IDR carries byte-identical parameter
    /// sets, so the same malfunctioning session would be reused forever and the pane would freeze on
    /// the last good frame.
    public func invalidateSession() {
        guard let handle else { return }
        slopdesk_video_decoder_invalidate(handle)
    }

    /// The decode-wall EWMA in milliseconds (`0` = nothing decoded yet), for the stats HUD's
    /// client-local decode axis. Callable from any thread.
    public func decodeMillisEWMA() -> Double {
        guard let handle else { return 0 }
        return slopdesk_video_decoder_millis_ewma(handle)
    }
}
#endif
