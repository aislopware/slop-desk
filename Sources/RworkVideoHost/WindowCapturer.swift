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

    // VIDEO-HOST-1 static-IDR (env-gated RWORK_VIDEO_STATICIDR, default OFF). All of these
    // are touched ONLY on `frameQueue` (the SCStream callback queue + the timer queue are the
    // same), or — for the latch — under `keyframeLock`. With the gate OFF none are ever used.
    private let staticIDREnabled: Bool
    private var staticIDRDecider: StaticIDRDecider
    private var idrTimer: DispatchSourceTimer?
    private var cachedPixelBuffer: CVPixelBuffer?   // deep COPY, frameQueue-owned (see copyPixelBuffer)
    /// Highest PTS handed to the encoder by EITHER path, in the 90 kHz synthetic timescale,
    /// so a synthetic IDR is strictly monotonic and a later real frame never reverses it.
    private var lastEmittedPTS: CMTime = .zero
    /// Standard MPEG 90 kHz timescale for the monotonic synthetic-PTS counter (§5; Sunshine
    /// "counter, not clock" discipline expressed in CMTime).
    private static let ptsTimescale: CMTimeScale = 90_000

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

    /// VIDEO-HOST-1 timer tick — runs on `frameQueue` (serialized against the SCStream
    /// callback), so it reads `cachedPixelBuffer` + mutates `staticIDRDecider`/`lastEmittedPTS`
    /// directly with no lock. Re-encodes the cached last-`.complete` buffer as a forced IDR
    /// when the pure decider says the live path has gone quiet and a heartbeat/recovery is due.
    /// The hand-off is the SAME synchronous `frameHandler` call as the live path — NO `Task`,
    /// so FIFO + monotonic PTS w.r.t. real frames is preserved.
    private func onIDRTimerTick() {
        let now = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1_000_000_000.0
        let forced = takePendingForcedKeyframe()          // drain the SAME NSLock latch
        guard staticIDRDecider.shouldReencode(now: now,
                                              forcedLatched: forced,
                                              hasRetainedBuffer: cachedPixelBuffer != nil),
              let buf = cachedPixelBuffer else {
            // If we drained `forced` but decided not to fire (quiet window — the live path
            // will service it), DON'T lose the recovery request: re-latch it.
            if forced { keyframeLock.lock(); pendingForcedKeyframe = true; keyframeLock.unlock() }
            return
        }
        staticIDRDecider.recordSynthetic(now: now)
        frameHandler(buf, syntheticPTS(), true)            // force IDR, same hand-off as live path
    }

    /// One 90 kHz tick past the last emitted PTS → strictly monotonic, collision-free with
    /// any real frame (§5). frameQueue-owned.
    private func syntheticPTS() -> CMTime {
        let next = CMTimeAdd(lastEmittedPTS, CMTime(value: 1, timescale: Self.ptsTimescale))
        lastEmittedPTS = next
        return next
    }

    public init(
        frameHandler: @escaping FrameHandler,
        staticIDREnabled: Bool = StaticIDRGate.enabledFromEnvironment()
    ) {
        self.frameHandler = frameHandler
        self.staticIDREnabled = staticIDREnabled
        self.staticIDRDecider = StaticIDRDecider(heartbeat: Self.heartbeatIDRInterval)
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

        // VIDEO-HOST-1 (gated ON only): a heartbeat timer on `frameQueue` so every tick is
        // serialized against the SCStream callback — no lock needed for `cachedPixelBuffer` /
        // the decider. On a static window (only `.idle` frames) this is the ONLY path that can
        // produce an IDR for a joining / loss-recovering client.
        if staticIDREnabled {
            // Tick at half the heartbeat cadence: the decider only emits when >= heartbeat has
            // elapsed, so sub-cadence ticks are cheap no-ops, but they halve the phase-misalignment
            // penalty (worst-case effective heartbeat ~1.5s instead of ~2s) and the recovery-IDR
            // latency on a static window (review finding, VIDEO-HOST-1).
            let tick = Self.heartbeatIDRInterval / 2
            let timer = DispatchSource.makeTimerSource(queue: frameQueue)
            timer.schedule(deadline: .now() + tick, repeating: tick, leeway: .milliseconds(50))
            timer.setEventHandler { [weak self] in self?.onIDRTimerTick() }
            timer.resume()
            self.idrTimer = timer
        }
    }

    public func stop() async {
        guard let stream else { return }
        // VIDEO-HOST-1 (gated ON only): cancel the timer + release the cached copy on
        // `frameQueue` (the timer's queue) BEFORE stopping capture, so no tick can race
        // teardown. `cachedPixelBuffer = nil` is sufficient — ARC releases the managed copy;
        // no manual CVPixelBufferRelease.
        if staticIDREnabled {
            frameQueue.sync {
                idrTimer?.cancel(); idrTimer = nil
                cachedPixelBuffer = nil
            }
        }
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
            // .idle / .blank / .suspended / .started → no NEW pixels to encode, so skip.
            // ⚠️ VIDEO-HOST-1 (audit — docs/25 §4): on a STATIC window only `.idle` frames
            // arrive, so the forced-keyframe latch (`takePendingForcedKeyframe`) AND the ~1s
            // heartbeat IDR — BOTH below this guard — never run, and a client that requests
            // loss-recovery (or joins) while the host window is unchanging gets no IDR and
            // freezes on the last good frame. FIX (env-gated `RWORK_VIDEO_STATICIDR`, default
            // OFF — see StaticIDRGate / StaticIDRDecider): when ON, `start()` arms a heartbeat
            // timer on `frameQueue` that re-encodes the cached last-`.complete` COPY
            // (`copyPixelBuffer`) as a forced IDR via `onIDRTimerTick`, so the latch + heartbeat
            // have a second drainer while the live path is quiet. With the gate OFF this `.idle`
            // return is byte-identical to what ships today. The ON path needs Mac Studio bring-up
            // (real GUI + TCC) — the SCStream IOSurface / queue-depth interaction is unobservable
            // headlessly; only the pure decider/gate/PTS pieces are unit-tested.
            return
        }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        // `now` (computed here for both the existing heartbeat block and the static-IDR
        // caching below — pure reordering of a local read with no side effect; OFF path value
        // and behaviour unchanged).
        let now = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1_000_000_000.0

        // VIDEO-HOST-1 (gated ON only): cache a deep COPY of this real frame so the timer can
        // re-encode it as a forced IDR while the window is static, anchor the decider's live
        // clock, and advance the synthetic-PTS high-water mark so a later synthetic frame stays
        // strictly past every real frame (§5). All on `frameQueue`. >90% of frames are idle, so
        // this copy lands only on the rare real frame that already pays for an encode.
        let encodePTS: CMTime
        if staticIDREnabled {
            cachedPixelBuffer = Self.copyPixelBuffer(pixelBuffer)
            staticIDRDecider.onCompleteFrame(now: now)
            let pts90k = CMTimeConvertScale(pts, timescale: Self.ptsTimescale, method: .default)
            // Clamp the value ACTUALLY handed to the encoder up to the high-water mark — not just
            // the tracker — so a real frame can never reverse a prior synthetic IDR's PTS (the
            // live session has AllowFrameReordering=false), and both paths feed VT a single uniform
            // 90 kHz timescale (review finding, VIDEO-HOST-1 §5).
            lastEmittedPTS = CMTimeMaximum(lastEmittedPTS, pts90k)
            encodePTS = lastEmittedPTS
        } else {
            encodePTS = pts   // OFF path: byte-identical to today (native SCStream PTS).
        }

        // Heartbeat IDR ~1s, plus a forced keyframe on the very first delivered frame,
        // plus any client-requested IDR (loss recovery, doc 17 §3.6).
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
        frameHandler(pixelBuffer, encodePTS, forceKeyframe)
    }

    // MARK: SCStreamDelegate

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        log.error("SCStream stopped with error: \(error.localizedDescription)")
    }

    // MARK: VIDEO-HOST-1 pixel-buffer copy

    /// Deep-copies an NV12 `CVPixelBuffer` into a fresh IOSurface-backed buffer the capturer
    /// owns indefinitely, so the SCStream-delivered surface can be returned to the pool
    /// immediately (queueDepth=3, WWDC22 s10155 — permanently retaining one would shrink the
    /// live pool to 2 and risk a capture stall). Returns nil on alloc/lock failure (caller then
    /// simply has no cached buffer → the decider returns false, no synthetic IDR — safe). The
    /// copy is IOSurface-backed so the synthetic re-encode stays zero-copy into VT, like live.
    private static func copyPixelBuffer(_ src: CVPixelBuffer) -> CVPixelBuffer? {
        let w = CVPixelBufferGetWidth(src), h = CVPixelBufferGetHeight(src)
        let fmt = CVPixelBufferGetPixelFormatType(src)
        let attrs: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary, // IOSurface-backed → VT zero-copy on re-encode
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var dst: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, w, h, fmt, attrs as CFDictionary, &dst) == kCVReturnSuccess,
              let dst else { return nil }
        // Propagate the source's color attachments (YCbCr matrix / primaries / transfer +
        // chroma location): CVPixelBufferCreate yields a buffer with NONE, and VT derives the
        // encoded color metadata from the input buffer — so without this the synthetic IDR would
        // encode with default color and a decoding client could see a brief tone shift versus the
        // surrounding live frames (review finding, VIDEO-HOST-1).
        if let attachments = CVBufferCopyAttachments(src, .shouldPropagate) {
            CVBufferSetAttachments(dst, attachments, .shouldPropagate)
        }
        CVPixelBufferLockBaseAddress(src, .readOnly)
        CVPixelBufferLockBaseAddress(dst, [])
        defer {
            CVPixelBufferUnlockBaseAddress(dst, [])
            CVPixelBufferUnlockBaseAddress(src, .readOnly)
        }
        let planes = CVPixelBufferGetPlaneCount(src)  // NV12 = 2 (Y, CbCr)
        for p in 0..<planes {
            guard let s = CVPixelBufferGetBaseAddressOfPlane(src, p),
                  let d = CVPixelBufferGetBaseAddressOfPlane(dst, p) else { return nil }
            let sb = CVPixelBufferGetBytesPerRowOfPlane(src, p)
            let db = CVPixelBufferGetBytesPerRowOfPlane(dst, p)
            let rows = CVPixelBufferGetHeightOfPlane(src, p)
            if sb == db {
                memcpy(d, s, sb * rows)
            } else {                                  // stride mismatch → row-by-row
                let copyBytes = min(sb, db)
                for r in 0..<rows { memcpy(d + r * db, s + r * sb, copyBytes) }
            }
        }
        return dst
    }
}
#endif
