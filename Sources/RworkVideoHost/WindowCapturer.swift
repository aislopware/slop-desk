#if os(macOS)
import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import OSLog

/// Captures a single GUI window via ScreenCaptureKit, configured to the MEASURED
/// spike configs (doc 02 §3.1, doc 17 §3.1, doc 18 §D).
///
/// ⚠️ **HANG-SAFETY:** an `SCStream` cannot start without a window-server +
/// Screen-Recording TCC session (docs/research/spikes/vtbench/RESULTS.md). This type
/// is COMPILED and code-reviewed but its `start()` is NEVER called from a test or a
/// headless context — only from a real GUI host app with the TCC grant.
///
/// Config rationale (each cites the measured spike / doc):
/// - `pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange` (NV12) →
///   zero-copy hand-off to `VTCompressionSession`, no BGRA→NV12 step (doc 02 §3.1).
/// - `showsCursor = false` + `showsMouseClicks = false` → the cursor is stripped
///   from per-window capture (MEASURED PASS, RESULTS.md "D — cursor strip"); the
///   client renders it from the side-channel (doc 17 §3.3).
/// - `minimumFrameInterval = CMTime(1, 30)` → cap ~30fps (macOS 15+ silently
///   defaults to 1/60; must set explicitly — doc 02 §3.1).
/// - `queueDepth = 3` → low-latency 2-3 frames in flight (doc 02 §3.1); release the
///   `CMSampleBuffer` surface IMMEDIATELY after handing the `CVPixelBuffer` to the
///   encoder, within `minimumFrameInterval × (queueDepth − 1)` (WWDC22 s10155).
/// - Idle-skip: `SCStreamFrameInfo.status == .idle` → return immediately, no encode,
///   no send (doc 17 §3.5). >90% of coding frames are static.
/// - Heartbeat IDR ~1s so a reconnecting/loss-recovering client catches a frame.
public final class WindowCapturer: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    /// Heartbeat IDR cadence: force a keyframe ~every second on an idle window
    /// (doc 17 §3.5) so a late-joining / loss-recovering client gets a decode anchor.
    public static let heartbeatIDRInterval: TimeInterval = 1.0

    /// Called for each captured frame with its NV12 `CVPixelBuffer` and whether the
    /// encoder should force a keyframe (heartbeat or first frame). The handler MUST
    /// hand the pixel buffer to the encoder and return promptly so the
    /// `CMSampleBuffer` surface can be released within the queue-depth deadline.
    public typealias FrameHandler = @Sendable (_ pixelBuffer: CVPixelBuffer, _ presentationTime: CMTime, _ forceKeyframe: Bool) -> Void

    private let log = Logger(subsystem: "rwork.video.host", category: "WindowCapturer")
    private let frameQueue = DispatchQueue(label: "rwork.video.capture", qos: .userInteractive)
    private var stream: SCStream?
    private let frameHandler: FrameHandler

    /// Last time we forced a heartbeat IDR (uptime seconds).
    private var lastHeartbeat: TimeInterval = 0
    private var hasEmittedFirstFrame = false

    /// Latched when the client requests a forced IDR (loss recovery, doc 17 §3.6). The
    /// next delivered frame forces a keyframe and clears it. Guarded because the
    /// orchestrator actor sets it off the capture queue. Plain `os_unfair_lock`-free:
    /// an `NSLock` is enough here (set rarely, read once per frame).
    private let keyframeLock = NSLock()
    private var pendingForcedKeyframe = false

    /// Requests a forced IDR on the next captured frame (client loss-recovery →
    /// ``RecoveryMessage/requestIDR``). Thread-safe; called from the orchestrator actor.
    public func requestKeyframe() {
        keyframeLock.lock(); pendingForcedKeyframe = true; keyframeLock.unlock()
    }

    /// Atomically reads + clears the pending-forced-keyframe latch.
    private func takePendingForcedKeyframe() -> Bool {
        keyframeLock.lock(); defer { keyframeLock.unlock() }
        let pending = pendingForcedKeyframe
        pendingForcedKeyframe = false
        return pending
    }

    public init(frameHandler: @escaping FrameHandler) {
        self.frameHandler = frameHandler
        super.init()
    }

    /// Builds the MEASURED-config `SCStreamConfiguration` for a single window.
    ///
    /// `width`/`height` are the window's POINT dimensions. Capture is point-resolution
    /// by design: the negotiated `captureWidth`/`captureHeight` (the `helloAck`), the
    /// `SCStreamConfiguration` size, and therefore the decoded `CVPixelBuffer` size all
    /// agree in points, so the client's `VideoScaleMath` denominator and cursor
    /// placement stay correct without a separate pixel-scale axis. (On a Retina host
    /// this means remoted windows render at point resolution, not backing pixels — a
    /// quality trade chosen for a single, consistent capture-size source of truth.)
    public static func makeConfiguration(width: Int, height: Int) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange // NV12 zero-copy (doc 02 §3.1)
        config.showsCursor = false                                          // client-side cursor (RESULTS.md D)
        // showMouseClicks gates the click "ripple" overlay (default NO; only applies
        // to BGRA capture per the SDK header — a no-op for our NV12 path, set for
        // intent).
        config.showMouseClicks = false
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)       // cap ~30fps (doc 02 §3.1)
        config.queueDepth = 3                                               // 2-3 for low latency (doc 02 §3.1)
        config.width = width
        config.height = height
        config.colorSpaceName = CGColorSpace.sRGB
        return config
    }

    /// Creates the content filter for one desktop-independent window. Captures the
    /// window's backing store at origin (0,0) so in-window coordinates are direct
    /// (doc 18 §B note).
    public static func makeFilter(window: SCWindow) -> SCContentFilter {
        SCContentFilter(desktopIndependentWindow: window)
    }

    /// Starts capturing the given window at an explicit PIXEL size (`pixelWidth`×`pixelHeight`).
    /// Passing the window's backing-pixel size (points × display scale) captures at native
    /// Retina resolution — sharp text — instead of the soft point-resolution default. ⚠️
    /// Requires a window-server + Screen-Recording TCC session — NEVER call from a test.
    public func start(window: SCWindow, pixelWidth: Int, pixelHeight: Int) async throws {
        let config = Self.makeConfiguration(width: pixelWidth, height: pixelHeight)
        let filter = Self.makeFilter(window: window)
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: frameQueue)
        try await stream.startCapture()
        self.stream = stream
        log.info("WindowCapturer started for window \(window.windowID)")
    }

    public func stop() async {
        guard let stream else { return }
        try? await stream.stopCapture()
        self.stream = nil
    }

    // MARK: SCStreamOutput

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }

        // Idle-skip (doc 17 §3.5): read SCStreamFrameInfo.status; on .idle return
        // immediately — no IOSurface touch, no encode, no send. This keeps the
        // encoder slot free for the next real (keystroke-driven) frame.
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first,
              let statusRaw = info[.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRaw) else {
            return
        }
        guard status == .complete else {
            // .idle / .blank / .suspended / .started → nothing new to encode.
            return
        }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        // Heartbeat IDR ~1s, plus a forced keyframe on the very first delivered frame,
        // plus any client-requested IDR (loss recovery, doc 17 §3.6).
        let now = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1_000_000_000.0
        var forceKeyframe = takePendingForcedKeyframe()
        if !hasEmittedFirstFrame {
            forceKeyframe = true
            hasEmittedFirstFrame = true
            lastHeartbeat = now
        } else if now - lastHeartbeat >= Self.heartbeatIDRInterval {
            forceKeyframe = true
            lastHeartbeat = now
        }
        if forceKeyframe { lastHeartbeat = now } // re-anchor cadence on a recovery IDR

        // Hand the CVPixelBuffer to the encoder. The pixel buffer is retained by the
        // encoder for the duration of the encode; when this callback returns the
        // CMSampleBuffer (and its surface) is released — within the queue-depth
        // deadline minimumFrameInterval × (queueDepth − 1) (WWDC22 s10155).
        frameHandler(pixelBuffer, pts, forceKeyframe)
    }

    // MARK: SCStreamDelegate

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        log.error("SCStream stopped with error: \(error.localizedDescription)")
    }
}
#endif
