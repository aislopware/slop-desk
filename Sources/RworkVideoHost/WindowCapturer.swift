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
    /// Heartbeat IDR cadence (seconds): force a keyframe periodically so a late-joining / loss-recovering
    /// client gets a decode anchor. Raised 1.0 → 2.5 (F2 flicker fix, 2026-06-08): on a never-idle window
    /// every heartbeat is a full 50-135 KB IDR burst (the crisp path never fires) that risks burst loss for
    /// ZERO visual benefit to an already-in-sync client — ~2.5 s removes most of those periodic bursts
    /// while keeping a prompt insurance anchor (DETECTED loss recovers via the recovery channel, not this
    /// heartbeat). Env A/B `RWORK_HEARTBEAT_S`, clamped [0.25, 60].
    public static let heartbeatIDRInterval: TimeInterval = {
        if let s = ProcessInfo.processInfo.environment["RWORK_HEARTBEAT_S"], let v = Double(s), v >= 0.25, v <= 60 { return v }
        return 2.5
    }()
    /// CAD-3 (2026-06-09 smoothness): whether to force a periodic heartbeat IDR on the LIVE (active-motion)
    /// path. DEFAULT OFF. On a never-idle window the heartbeat is a 50-135 KB IDR through
    /// `encodeCompactKeyframe`, whose two synchronous `VTCompressionSessionCompleteFrames` calls BLOCK the
    /// capture queue ~15 ms → a dropped capture + a big frame every `heartbeatIDRInterval` (2.5s) = a
    /// PERIODIC cadence hitch during a long scroll ("vuốt lâu thì khựng"). As the heartbeat comment notes,
    /// it is "ZERO visual benefit to an already-in-sync client" and DETECTED loss recovers via the recovery
    /// channel (requestIDR), not this heartbeat. The STATIC-window timer (`onIDRTimerTick`) still re-anchors
    /// with a crisp IDR the instant motion pauses, and a late-joining/decode-failed client still requests an
    /// IDR — so suppressing the motion heartbeat removes the hitch with no resilience loss on a low-loss
    /// link. `RWORK_MOTION_HEARTBEAT=1` restores the periodic motion IDR (for a genuinely lossy WAN).
    static let motionHeartbeatEnabled = ProcessInfo.processInfo.environment["RWORK_MOTION_HEARTBEAT"] == "1"

    /// Called for each captured frame with its NV12 `CVPixelBuffer`, whether the encoder should
    /// force a keyframe (heartbeat or first frame), and whether this frame should be a CRISP
    /// near-lossless intra refresh (`crisp`). `crisp` is true ONLY on the static-IDR timer path
    /// (the window is at rest → re-encode the cached frame near-lossless for razor-sharp text);
    /// every live motion frame passes `crisp == false` so motion stays low-latency. The handler
    /// MUST hand the pixel buffer to the encoder and return promptly so the `CMSampleBuffer`
    /// surface can be released within the queue-depth deadline.
    /// `compact` is true ONLY for a forced IDR on the LIVE (active) path that is a recovery or
    /// heartbeat (NOT the first frame, NOT the static-timer crisp path) — the handler should encode it
    /// SMALL+coarse (``VideoEncoder/encodeCompactKeyframe``) so it survives a UDP burst and does not
    /// re-trigger the recovery-IDR loop. `crisp` and `compact` are mutually exclusive.
    /// `ltrRefresh` (WF-8) is true ONLY on the LIVE path when the host chose a cheap LTR-refresh
    /// recovery (``VideoEncoder/encodeLiveLTRRefresh(pixelBuffer:presentationTime:)``) — a small
    /// P-frame against an ACKNOWLEDGED long-term reference, NOT a keyframe. It is mutually exclusive
    /// with `forceKeyframe`/`crisp`/`compact` (a keyframe is a superset recovery and wins) and is never
    /// set on the static-timer path (which re-anchors with a crisp/compact IDR instead). Always false
    /// when `RWORK_LTR` is off ⇒ byte-identical handler behaviour.
    public typealias FrameHandler = @Sendable (_ pixelBuffer: CVPixelBuffer, _ presentationTime: CMTime, _ forceKeyframe: Bool, _ crisp: Bool, _ compact: Bool, _ ltrRefresh: Bool) -> Void

    /// Whether the static-IDR timer upgrades its re-encode to a CRISP near-lossless frame
    /// (Design A, ``VideoEncoder/encodeLiveCrispKeyframe``). Default on; set `RWORK_CRISP=0` to
    /// A/B back to a plain (live-QP) heartbeat IDR with no rebuild. Read once (static screen
    /// behaviour only; HW-verified path, not unit-tested).
    private static let crispWhenStatic = ProcessInfo.processInfo.environment["RWORK_CRISP"] != "0"

    /// SELF-HEAL cadence (2026-06-11, Parsec-style ack-anchored healing — HW-validated in
    /// `rwork-loopback-validate --ack-ref` arms L/M/N/O): every `selfHealEvery`-th LIVE delta is
    /// encoded as a `ForceLTRRefresh` P-frame, which VideoToolbox anchors to the newest LTR the
    /// client has ACKNOWLEDGED (proven: burst-killing the 5 frames before a refresh leaves the
    /// refresh pixel-clean — it references the older acked LTR, MAD 0.2 vs noise floor 4.6). So ANY
    /// whole-frame wire loss self-heals at the next cadence frame — ≤K frames, NO recovery
    /// round-trip, no IDR cannon, and it works even when the loss ALSO ate the client's recovery
    /// request (the weather-burst case the FPT↔Viettel path actually produces). Measured cost: a
    /// refresh is ~1.49× a 1-back delta on full motion ⇒ +8.2% stream bytes at K=6 (vs FEC's +20%),
    /// and a few hundred bytes on low motion. Safety: VT emits an IDR instead if no LTR is acked
    /// (its own contract, arm N) and the cadence is additionally GATED on ``setSelfHealEligible(_:)``
    /// (the session arms it only while client acks are flowing) so a stalled client can never turn
    /// the cadence into a surprise-IDR-every-K stream. `RWORK_SELF_HEAL` overrides K (frames,
    /// clamp 2…120); `0` disables. Requires `RWORK_LTR` (the session never arms eligibility
    /// otherwise — acks don't flow when LTR is off).
    static let selfHealEvery: Int = {
        if let s = ProcessInfo.processInfo.environment["RWORK_SELF_HEAL"], let v = Int(s) {
            if v == 0 { return 0 }
            return min(120, max(2, v))
        }
        return 6
    }()

    private let log = Logger(subsystem: "rwork.video.host", category: "WindowCapturer")
    private let frameQueue = DispatchQueue(label: "rwork.video.capture", qos: .userInteractive)
    private var stream: SCStream?
    private let frameHandler: FrameHandler

    /// Last time we forced a heartbeat IDR (uptime seconds).
    private var lastHeartbeat: TimeInterval = 0
    private var hasEmittedFirstFrame = false
    /// Uptime seconds of the last EMITTED keyframe (any reason) — drives the F1 recovery-IDR cooldown.
    /// frameQueue-owned (set on both the live path and the timer path, both on frameQueue).
    private var lastKeyframeEmit: TimeInterval = 0
    /// F1 (flicker fix, 2026-06-08): minimum spacing (seconds) between RECOVERY-driven (latch) IDRs, to
    /// collapse a self-sustaining recovery-IDR storm (each big IDR is a UDP burst → loss → another recovery
    /// request → another IDR). A latch-only force within this window of the last emitted keyframe ships a
    /// P-frame instead: the recent keyframe already re-anchored the client, and the client's 2·RTT
    /// escalation re-requests later (OUTSIDE the window) if that one was also lost — so recovery is
    /// de-bursted, never dropped. NEVER gates the first-frame or heartbeat IDR. 0 disables. Env
    /// `RWORK_MIN_IDR_MS` (default 500 ms).
    private static let minRecoveryIDRInterval: TimeInterval = {
        if let s = ProcessInfo.processInfo.environment["RWORK_MIN_IDR_MS"], let v = Double(s), v >= 0, v <= 5_000 { return v / 1000.0 }
        return 0.5
    }()

    /// Latched when the client requests a forced IDR (loss recovery, doc 17 §3.6). The
    /// next delivered frame forces a keyframe and clears it. Guarded because the
    /// orchestrator actor sets it off the capture queue. Plain `os_unfair_lock`-free:
    /// an `NSLock` is enough here (set rarely, read once per frame).
    private let keyframeLock = NSLock()
    private var pendingForcedKeyframe = false
    /// WF-8: latched when the host chose an LTR-refresh recovery (``RworkVideoHostSession`` `.refreshLTR`
    /// → ``requestLTRRefresh()``) instead of a forced IDR. The next LIVE frame encodes a cheap
    /// ForceLTRRefresh P-frame and clears it; on a STATIC window the timer drains it and re-anchors
    /// with a crisp/compact IDR instead (an LTR refresh has no live delta to ride). Distinct from
    /// `pendingForcedKeyframe` so an LTR refresh never forces a keyframe (it is the cheap alternative).
    /// Under the same `keyframeLock`. Never set when `RWORK_LTR` is off (the actor folds .refreshLTR to
    /// requestKeyframe()) ⇒ always-false drain ⇒ byte-identical.
    private var pendingLTRRefresh = false
    /// SELF-HEAL eligibility — armed by the session actor while client LTR acks are flowing
    /// (``setSelfHealEligible(_:)``), disarmed on every encoder rebuild (fresh VT session = zero
    /// acked LTRs; a cadence refresh would then be VT's IDR fallback every K frames). Under
    /// `keyframeLock` (set rarely off-queue, read once per frame — same discipline as the latches).
    private var selfHealEligible = false
    /// LIVE frames since the last re-anchor (keyframe or LTR refresh) — drives the self-heal
    /// cadence. frameQueue-owned (only touched in the SCStream callback).
    private var framesSinceAnchor = 0

    // VIDEO-HOST-1 static-IDR (always on). All of these are touched ONLY on `frameQueue`
    // (the SCStream callback queue + the timer queue are the same), or — for the latch —
    // under `keyframeLock`.
    private var staticIDRDecider: StaticIDRDecider
    private var idrTimer: DispatchSourceTimer?
    private var cachedPixelBuffer: CVPixelBuffer?   // deep COPY, frameQueue-owned (see copyPixelBuffer)
    /// KHỰNG-ladder stage 1 (RWORK_VIDEO_DEBUG): last DELIVERED-frame time, frameQueue-owned.
    static let dbgGapEnabled = ProcessInfo.processInfo.environment["RWORK_VIDEO_DEBUG"] != nil
    private var lastDeliveredAt: Double = 0
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

    /// WF-8: requests a cheap LTR refresh on the next captured frame (host `.refreshLTR` recovery
    /// decision when the ACKED-ONLY gate holds). Thread-safe; called from the orchestrator actor.
    public func requestLTRRefresh() {
        keyframeLock.lock(); pendingLTRRefresh = true; keyframeLock.unlock()
    }

    /// SELF-HEAL gate. The session actor arms this when a client LTR ack folds (acks are flowing ⇒
    /// VT holds an acknowledged LTR ⇒ a cadence `ForceLTRRefresh` is a small loss-immune P-frame)
    /// and disarms it whenever a fresh encoder is installed (``RworkVideoHostSession`` resets the
    /// LTR controller at the same sites). Thread-safe.
    public func setSelfHealEligible(_ eligible: Bool) {
        keyframeLock.lock(); selfHealEligible = eligible; keyframeLock.unlock()
    }

    private func selfHealIsEligible() -> Bool {
        keyframeLock.lock(); defer { keyframeLock.unlock() }
        return selfHealEligible
    }

    /// Atomically reads + clears the pending-forced-keyframe latch.
    private func takePendingForcedKeyframe() -> Bool {
        keyframeLock.lock(); defer { keyframeLock.unlock() }
        let pending = pendingForcedKeyframe
        pendingForcedKeyframe = false
        return pending
    }

    /// WF-8: atomically reads + clears the pending-LTR-refresh latch.
    private func takePendingLTRRefresh() -> Bool {
        keyframeLock.lock(); defer { keyframeLock.unlock() }
        let pending = pendingLTRRefresh
        pendingLTRRefresh = false
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
        let forcedKeyframe = takePendingForcedKeyframe()  // drain the keyframe latch
        // WF-8: a STATIC window has no live delta to ride an LTR refresh, so on this path an LTR
        // request degrades to the same crisp/compact re-anchor as a forced keyframe — drain it and
        // fold it into `forced` (but the frameHandler is still called with ltrRefresh=false: the
        // static path never issues an actual ForceLTRRefresh, it re-encodes the cached frame crisp).
        // Always false when RWORK_LTR is off ⇒ `forced` is byte-identical to today.
        let forcedLTR = takePendingLTRRefresh()
        let forced = forcedKeyframe || forcedLTR
        guard staticIDRDecider.shouldReencode(now: now,
                                              forcedLatched: forced,
                                              hasRetainedBuffer: cachedPixelBuffer != nil),
              let buf = cachedPixelBuffer else {
            // If we drained a recovery request but decided not to fire (quiet window — the live path
            // will service it), DON'T lose it: re-latch each kind we took.
            if forcedKeyframe || forcedLTR {
                keyframeLock.lock()
                if forcedKeyframe { pendingForcedKeyframe = true }
                if forcedLTR { pendingLTRRefresh = true }
                keyframeLock.unlock()
            }
            return
        }
        staticIDRDecider.recordSynthetic(now: now)
        lastKeyframeEmit = now   // F1: the timer ALWAYS emits a keyframe → anchor the recovery cooldown
        // The window is at rest (the live path is quiet — that is why this timer fired), so upgrade
        // the re-encode to a CRISP near-lossless intra refresh for razor-sharp static text (Design A,
        // same live session → no client decoder rebuild). `RWORK_CRISP=0` falls back to a plain IDR.
        // Static (at-rest) path: crisp (sharp) when enabled, never compact — at rest there is no live
        // delta competing for the wire, so the larger near-lossless IDR is not a burst-loss risk.
        frameHandler(buf, syntheticPTS(), true, Self.crispWhenStatic, false, false) // force IDR, same hand-off as live path (never an LTR refresh on the static path)
    }

    /// One 90 kHz tick past the last emitted PTS → strictly monotonic, collision-free with
    /// any real frame (§5). frameQueue-owned.
    private func syntheticPTS() -> CMTime {
        let next = CMTimeAdd(lastEmittedPTS, CMTime(value: 1, timescale: Self.ptsTimescale))
        lastEmittedPTS = next
        return next
    }

    /// Capture frame-rate cap (fps). Default 60 for smooth scroll/motion; idle-skip keeps a static
    /// window near-zero regardless. Used to build the `minimumFrameInterval`.
    private let fps: Int
    /// Capture pixel scale (window points × this = the output buffer pixels). Needed to express
    /// `sourceRect` in POINTS (`pixelDim / captureScale`) — the source crop is point-space while
    /// `config.width/height` are pixel-space.
    private let captureScale: Double
    /// WF-6 (#8): capture NV12 in the FULL-RANGE pixel-format variant when true (else the VideoRange
    /// variant — today). Threaded into ``makeConfiguration``; default false ⇒ byte-identical capture.
    private let fullRange: Bool

    public init(
        fps: Int = 60,
        captureScale: Double = 1.0,
        fullRange: Bool = false,
        frameHandler: @escaping FrameHandler
    ) {
        self.fps = max(1, fps)
        self.captureScale = max(1.0, captureScale)
        self.fullRange = fullRange
        self.frameHandler = frameHandler
        // Cap quietWindow at 1s (F2): the decider's quietWindow gates shouldReencode, so a longer
        // heartbeat must NOT stretch the timer-path recovery-suppression window — recovery stays responsive.
        self.staticIDRDecider = StaticIDRDecider(heartbeat: Self.heartbeatIDRInterval, quietWindow: min(1.0, Self.heartbeatIDRInterval))
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
    public static func makeConfiguration(width: Int, height: Int, fps: Int = 60, captureScale: Double = 1.0, fullRange: Bool = false) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        // NV12 zero-copy (doc 02 §3.1). WF-6 (#8): the luma RANGE is carried by the pixel-format
        // VARIANT (FullRange vs VideoRange) — THIS is the capture-side range knob; VT reads it to
        // stamp the SPS `video_full_range_flag`. R8/RG8 plane layout is identical for both NV12
        // variants, so the client's makeTexture is unaffected. Default VideoRange ⇒ today, byte-identical.
        config.pixelFormat = fullRange
            ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.showsCursor = false                                          // client-side cursor (RESULTS.md D)
        // showMouseClicks gates the click "ripple" overlay (default NO; only applies
        // to BGRA capture per the SDK header — a no-op for our NV12 path, set for
        // intent).
        config.showMouseClicks = false
        // Cap at `fps` (default 60 — Parsec-class smoothness for scroll/motion; 30 was visibly
        // steppier). macOS 15+ silently defaults to 1/60; idle-skip keeps a static window near-zero
        // regardless of the cap (doc 02 §3.1).
        // LAT (2026-06-10, env RWORK_CAPTURE_HZ): the capture min-interval normally matches the
        // encode fps, which QUANTIZES when SCK may deliver a fresh composite (a change landing
        // just after a slot waits out the rest of it). A HIGHER capture ceiling lets SCK hand
        // over a changed frame sooner WITHOUT raising the encode rate (delivery stays
        // content-driven; idle windows still deliver nothing). NOTE: `--fps 120` (raising BOTH)
        // measured WORSE glass-to-glass (+18ms p50) — only decouple the capture side.
        // DEFAULT 2× the encode fps since 2026-06-11 (HW-validated): at a 60Hz ceiling SCK's slot
        // quantization beat against the source compositor's commit time ate ~3fps (framewatch: eff
        // 57.2 → 60.0fps, p99 cadence 24.2 → 19.8ms) and the live host log showed 144-161 clustered
        // ~30ms double-slot capture gaps per scroll session — ZERO after the raise (14.6k-frame
        // user session). Capture-side only: encode fps (and thus bitrate) unchanged.
        let captureHz = ProcessInfo.processInfo.environment["RWORK_CAPTURE_HZ"].flatMap(Int.init).map { min(240, max(15, $0)) } ?? min(240, max(1, fps) * 2)
        config.minimumFrameInterval = CMTime(value: 1, timescale: Int32(captureHz))
        config.queueDepth = 3                                               // 2-3 for low latency (doc 02 §3.1)
        config.width = width
        config.height = height
        config.colorSpaceName = CGColorSpace.sRGB
        // ── BLUR-ON-TOOLTIP FIX (HW-root-caused 2026-06-08) ────────────────────────────────
        // With `SCContentFilter(desktopIndependentWindow:)`, SCK composites the target window's
        // CHILD/associated windows into the captured BOUNDING rect (SCStreamFrameInfoBoundingRect =
        // "smallest box containing all captured windows"). Chrome's link-URL status bubble is a
        // child window that pops up at the bottom-left and EXTENDS that rect past the window frame.
        // Because `config.width/height` are pinned to the window's own point size, SCK hardware-scales
        // the now-larger union rect DOWN to fit the fixed buffer (contentScale drops below 1.0) — so
        // the ENTIRE composited frame, all static text included, is sampled into fewer pixels and the
        // whole pane goes soft, snapping back to sharp the instant the bubble hides. This is upstream
        // of the encoder, which is why neither raising the live bitrate (12→40 Mbps, keyframes stayed
        // a constant ~52 KB) nor lowering the QP ceiling (32→22) had ANY effect — the detail was gone
        // before encode (HW A/B confirmed).
        //
        // We KEEP child windows (so the URL tooltip / popovers still render) but PIN the sampled
        // region to the window's own frame via `sourceRect`: SCK then maps exactly (0,0,W,H) points
        // 1:1 into the fixed pixel buffer no matter how far a child window pushes the union rect, so
        // contentScale stays at 1.0 (sharp). A child window that overlaps the frame is shown; the part
        // (if any) below the frame edge is simply cropped — never downscaled. `sourceRect` is in
        // POINTS, so divide the pixel dims by `captureScale`.
        // NOTE (HW 2026-06-08): with child windows included, the crop anchors a couple points off the
        // window's own top-left (a child window's geometry nudges the capture origin), so the image
        // sits a hair to the right. The user chose to keep this (tooltip + tiny shift) over a pixel-
        // perfect-but-tooltip-less capture (`includeChildWindows = false`); the offset is well under a
        // glyph and not worth the dynamic re-anchoring it would take to chase.
        let pointW = Double(width) / max(1.0, captureScale)
        let pointH = Double(height) / max(1.0, captureScale)
        config.sourceRect = CGRect(x: 0, y: 0, width: pointW, height: pointH)
        if #available(macOS 14.0, *) {
            config.ignoreShadowsSingleWindow = true     // don't let the window's drop-shadow pad the rect
            config.ignoreGlobalClipSingleWindow = true  // don't pad the rect to the global clip
        }
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
        let config = Self.makeConfiguration(width: pixelWidth, height: pixelHeight, fps: fps, captureScale: captureScale, fullRange: fullRange)
        var filter = Self.makeFilter(window: window)
        // DISPLAY-CAPTURE (2026-06-10 loopback latency hunt, env RWORK_DISPLAY_CAPTURE=1):
        // SCK's per-window composite path (`desktopIndependentWindow`) measured ~5ms SLOWER
        // p50 than a display capture cropped to the same rect (framewatch signed A/B, n=51).
        // When enabled, capture the DISPLAY containing the window with `sourceRect` pinned to
        // the window's frame (display-local points). ⚠️ Anything overlapping that rect is
        // captured too — intended for the VD path, where the window is parked alone at the
        // display origin; default OFF.
        if ProcessInfo.processInfo.environment["RWORK_DISPLAY_CAPTURE"] == "1" {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            let center = CGPoint(x: window.frame.midX, y: window.frame.midY)
            if let display = content.displays.first(where: { CGDisplayBounds($0.displayID).contains(center) }) {
                let db = CGDisplayBounds(display.displayID)
                config.sourceRect = CGRect(x: window.frame.minX - db.minX, y: window.frame.minY - db.minY,
                                           width: Double(pixelWidth) / max(1.0, captureScale),
                                           height: Double(pixelHeight) / max(1.0, captureScale))
                filter = SCContentFilter(display: display, excludingWindows: [])
                log.notice("display-capture mode: display \(display.displayID) sourceRect \(Int(config.sourceRect.origin.x)),\(Int(config.sourceRect.origin.y)) \(Int(config.sourceRect.width))x\(Int(config.sourceRect.height))pt")
            } else {
                log.error("display-capture: no display contains window center — falling back to window filter")
            }
        }
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: frameQueue)
        try await stream.startCapture()
        self.stream = stream
        log.info("WindowCapturer started for window \(window.windowID)")

        // VIDEO-HOST-1: a heartbeat timer on `frameQueue` so every tick is serialized against
        // the SCStream callback — no lock needed for `cachedPixelBuffer` / the decider. On a
        // static window (only `.idle` frames) this is the ONLY path that can produce an IDR for
        // a joining / loss-recovering client.
        //
        // Fixed 0.25s poll, DECOUPLED from the heartbeat (F2): with a multi-second heartbeat the timer
        // must still poll the recovery latch + service a truly-idle window promptly. The decider only
        // EMITS when >= heartbeat has elapsed, so sub-cadence ticks are cheap no-ops; a fixed small tick
        // keeps recovery/idle latency low regardless of the (now longer) heartbeat cadence.
        let tick = 0.25
        let timer = DispatchSource.makeTimerSource(queue: frameQueue)
        timer.schedule(deadline: .now() + tick, repeating: tick, leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in self?.onIDRTimerTick() }
        timer.resume()
        self.idrTimer = timer
    }

    public func stop() async {
        guard let stream else { return }
        // VIDEO-HOST-1: cancel the timer + release the cached copy on `frameQueue` (the timer's
        // queue) BEFORE stopping capture, so no tick can race teardown. `cachedPixelBuffer = nil`
        // is sufficient — ARC releases the managed copy; no manual CVPixelBufferRelease.
        frameQueue.sync {
            idrTimer?.cancel(); idrTimer = nil
            cachedPixelBuffer = nil
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
            // freezes on the last good frame. FIX (see StaticIDRDecider): `start()` arms a
            // heartbeat timer on `frameQueue` that re-encodes the cached last-`.complete` COPY
            // (`copyPixelBuffer`) as a forced IDR via `onIDRTimerTick`, so the latch + heartbeat
            // have a second drainer while the live path is quiet. The ON path needs Mac Studio
            // bring-up (real GUI + TCC) — the SCStream IOSurface / queue-depth interaction is
            // unobservable headlessly; only the pure decider/PTS pieces are unit-tested.
            return
        }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        // `now` (computed here for both the heartbeat block and the static-IDR caching below).
        let now = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1_000_000_000.0

        // KHỰNG LADDER stage 1 (2026-06-10, RWORK_VIDEO_DEBUG): a >28ms gap between two DELIVERED
        // frames during continuous motion means SCK itself stalled (or idle-skipped a changing
        // frame) — anything downstream can only inherit this hole. Idle pages legitimately gap;
        // read these lines only against a continuous-motion test (testufo).
        if Self.dbgGapEnabled {
            if lastDeliveredAt > 0, now - lastDeliveredAt > 0.028 {
                FileHandle.standardError.write(Data("rwork-videohostd[gap]: capture gap \(Int((now - lastDeliveredAt) * 1000))ms\n".utf8))
            }
            lastDeliveredAt = now
        }

        // VIDEO-HOST-1: cache a deep COPY of this real frame so the timer can re-encode it as a
        // forced IDR while the window is static, anchor the decider's live clock, and advance the
        // synthetic-PTS high-water mark so a later synthetic frame stays strictly past every real
        // frame (§5). All on `frameQueue`. >90% of frames are idle, so this copy lands only on the
        // rare real frame that already pays for an encode.
        cachedPixelBuffer = Self.copyPixelBuffer(pixelBuffer)
        staticIDRDecider.onCompleteFrame(now: now)
        let pts90k = CMTimeConvertScale(pts, timescale: Self.ptsTimescale, method: .default)
        // Clamp the value ACTUALLY handed to the encoder up to the high-water mark — not just
        // the tracker — so a real frame can never reverse a prior synthetic IDR's PTS (the
        // live session has AllowFrameReordering=false), and both paths feed VT a single uniform
        // 90 kHz timescale (review finding, VIDEO-HOST-1 §5).
        lastEmittedPTS = CMTimeMaximum(lastEmittedPTS, pts90k)
        let encodePTS = lastEmittedPTS

        // Heartbeat IDR ~1s, plus a forced keyframe on the very first delivered frame,
        // plus any client-requested IDR (loss recovery, doc 17 §3.6).
        let latched = takePendingForcedKeyframe()
        // WF-8: drain the LTR-refresh latch too (always false when RWORK_LTR is off ⇒ byte-identical).
        let ltrLatched = takePendingLTRRefresh()
        var forceKeyframe = latched
        var isFirstFrame = false
        var isHeartbeat = false
        if !hasEmittedFirstFrame {
            forceKeyframe = true
            isFirstFrame = true
            hasEmittedFirstFrame = true
        } else if Self.motionHeartbeatEnabled, now - lastHeartbeat >= Self.heartbeatIDRInterval {
            // CAD-3: the periodic motion-heartbeat IDR is gated OFF by default (it was the 2.5s scroll
            // hitch — see `motionHeartbeatEnabled`). When off, `lastHeartbeat` is anchored only on the
            // first-frame + recovery IDRs (below), and the static-timer re-anchors on motion pause.
            forceKeyframe = true
            isHeartbeat = true
        }
        // F1: collapse a recovery-IDR storm. If the ONLY reason is the recovery latch AND a keyframe was
        // emitted < cooldown ago, ship a P-frame instead — the recent keyframe already re-anchored the
        // client; if it was ALSO lost, the client's 2·RTT escalation re-requests later (outside the
        // cooldown) and is honored. Never gates the first-frame or heartbeat IDR. The dropped force is NOT
        // re-latched (takePendingForcedKeyframe already cleared it) so it cannot deferred-storm.
        if forceKeyframe, latched, !isFirstFrame, !isHeartbeat,
           Self.minRecoveryIDRInterval > 0, now - lastKeyframeEmit < Self.minRecoveryIDRInterval {
            forceKeyframe = false
        }
        // Anchor BOTH the heartbeat cadence and the recovery cooldown on ANY actually-emitted keyframe.
        if forceKeyframe { lastHeartbeat = now; lastKeyframeEmit = now }
        // COMPACT IDR (2026-06-08 motion-smoothness): a forced IDR on the LIVE (active) path — recovery
        // (client-requested after loss) or heartbeat — is encoded SMALL+coarse (encodeCompactKeyframe)
        // so it survives a UDP burst instead of re-triggering the recovery-IDR loop that shows as a
        // periodic motion hitch. The FIRST frame stays full quality (one-time, no loop); the static
        // timer path stays CRISP. `compact ⟹ forceKeyframe` by construction.
        let compact = forceKeyframe && !isFirstFrame
        // WF-8: send a cheap LTR refresh ONLY when we are NOT already sending a keyframe — a keyframe
        // (first/heartbeat/recovery IDR) is a superset recovery and wins, so an LTR refresh latched
        // alongside it is simply consumed (the keyframe re-anchors the client). If `forceKeyframe`
        // ended up false but an LTR refresh was latched, ship the small ForceLTRRefresh P-frame.
        // Always false when RWORK_LTR is off (the latch is never set) ⇒ byte-identical.
        var ltrRefresh = ltrLatched && !forceKeyframe
        // SELF-HEAL cadence: every `selfHealEvery`-th live delta becomes an acked-LTR-anchored
        // refresh (see the `selfHealEvery` doc — HW-validated loss self-healing). Counted against
        // the last RE-ANCHOR (keyframe or any refresh) so a recovery-latched refresh restarts the
        // window. Gated on eligibility (acks flowing) — ineligible frames don't advance the
        // counter past the threshold meaninglessly; they keep counting so healing starts at most
        // one frame after eligibility arms.
        if Self.selfHealEvery > 0, !forceKeyframe, !ltrRefresh {
            framesSinceAnchor += 1
            if framesSinceAnchor >= Self.selfHealEvery, selfHealIsEligible() {
                ltrRefresh = true
            }
        }
        if forceKeyframe || ltrRefresh { framesSinceAnchor = 0 }

        // Hand the CVPixelBuffer to the encoder. The pixel buffer is retained by the
        // encoder for the duration of the encode; when this callback returns the
        // CMSampleBuffer (and its surface) is released — within the queue-depth
        // deadline minimumFrameInterval × (queueDepth − 1) (WWDC22 s10155).
        // A live (motion) frame is NEVER crisp — motion must stay low-latency; only the static
        // timer above upgrades to a crisp refresh.
        frameHandler(pixelBuffer, encodePTS, forceKeyframe, false, compact, ltrRefresh)
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
