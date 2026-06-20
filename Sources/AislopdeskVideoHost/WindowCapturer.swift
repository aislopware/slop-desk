#if os(macOS)
import AislopdeskVideoProtocol
import CoreMedia
import CoreVideo
import Foundation
import OSLog
import ScreenCaptureKit

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
    /// heartbeat). Env A/B `AISLOPDESK_HEARTBEAT_S`, clamped [0.25, 60].
    public static let heartbeatIDRInterval: TimeInterval = {
        if let s = ProcessInfo.processInfo.environment["AISLOPDESK_HEARTBEAT_S"], let v = Double(s), v >= 0.25,
           v <= 60 { return v }
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
    /// link. `AISLOPDESK_MOTION_HEARTBEAT=1` restores the periodic motion IDR (for a genuinely lossy WAN).
    static let motionHeartbeatEnabled = ProcessInfo.processInfo.environment["AISLOPDESK_MOTION_HEARTBEAT"] == "1"

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
    /// when `AISLOPDESK_LTR` is off ⇒ byte-identical handler behaviour.
    public typealias FrameHandler = @Sendable (
        _ pixelBuffer: CVPixelBuffer,
        _ presentationTime: CMTime,
        _ forceKeyframe: Bool,
        _ crisp: Bool,
        _ compact: Bool,
        _ ltrRefresh: Bool,
        // ADAPTIVE-QP: the per-frame `MaxAllowedFrameQP` ceiling for the LIVE delta encode (sharp on a
        // small change, graded blur on a burst), or nil to leave the configured ceiling. Set only on
        // the live delta path; nil on the crisp/compact/static-timer paths (they own their own QP).
        _ perFrameMaxQP: Int?,
    ) -> Void

    /// Whether the static-IDR timer upgrades its re-encode to a CRISP near-lossless frame
    /// (Design A, ``VideoEncoder/encodeLiveCrispKeyframe``). Default on; set `AISLOPDESK_CRISP=0` to
    /// A/B back to a plain (live-QP) heartbeat IDR with no rebuild. Read once (static screen
    /// behaviour only; HW-verified path, not unit-tested).
    private static let crispWhenStatic = ProcessInfo.processInfo.environment["AISLOPDESK_CRISP"] != "0"

    /// STATIC-FRAME SUPPRESSION (default OFF). When enabled, each `.complete` frame's locked NV12
    /// planes are hashed (the native ``FrameHasher/hashNV12(y:yStride:width:height:cbcr:cbcrStride:)``
    /// NEON kernel) and compared to the
    /// last submitted frame's hash; a pixel-identical re-delivery with no forced obligation pending
    /// is DROPPED before the encoder (HEVC + SCK idle-skip handle most static content — this catches
    /// the residual `.complete` re-deliveries that are byte-identical). DEFAULT OFF ⇒ no hash is
    /// computed, nothing is suppressed, and the capture path is byte-identical to today. Needs a
    /// real GUI + TCC session to exercise (the SCStream path hangs headlessly); only the pure
    /// decider + the hash kernel are unit-tested. `AISLOPDESK_STATIC_SUPPRESS=1` enables it.
    private static let staticSuppressEnabled =
        ProcessInfo.processInfo.environment["AISLOPDESK_STATIC_SUPPRESS"] == "1"

    /// EVENT-DRIVEN CRISP RE-ANCHOR (default OFF; 2026-06-16 latency-first reframe). When enabled, each
    /// `.complete` frame's NV12 planes are hashed (NEON) and `stillCrispThreshold` consecutive byte-
    /// identical frames trigger the crisp re-anchor IMMEDIATELY (``StillnessCrispDecider``) instead of
    /// waiting the full ~300ms wall-clock quiet window — re-sharpen lands ~1-2 frames after motion visibly
    /// stops WHEN SCK re-delivers the static frame (otherwise the StaticIDRDecider quiet-window timer is
    /// the fallback). DEFAULT OFF: it adds a per-`.complete`-frame hash on the userInteractive capture
    /// queue, and P1 input latency must not pay unmeasured hot-path work — flip ON only after a HW A/B
    /// confirms the hash cost is negligible (the NEON kernel is built to be). `AISLOPDESK_STILL_CRISP=1`
    /// enables; `AISLOPDESK_STILL_CRISP_FRAMES` overrides the threshold (default 2, clamp 1…30).
    private static let stillCrispEnabled =
        ProcessInfo.processInfo.environment["AISLOPDESK_STILL_CRISP"] == "1"
    private static let stillCrispThreshold: Int = {
        if let s = ProcessInfo.processInfo.environment["AISLOPDESK_STILL_CRISP_FRAMES"], let v = Int(s) {
            return min(30, max(1, v))
        }
        return 2
    }()

    /// SCROLL REPROJECTION (default OFF). When enabled, each `.complete` frame's content scroll vs the
    /// PREVIOUS frame is MEASURED (NEON per-row hash + the pure shift estimator) and the offset is sent
    /// to the client, which warps the last frame by it between codec frames so editor scroll looks local
    /// (``ScrollReprojector``). DEFAULT OFF ⇒ no measurement, byte-identical. `AISLOPDESK_SCROLL_REPROJECT=1`
    /// (set on BOTH host + client). Confidence-gated so typing / non-scroll motion never reprojects.
    private static let scrollReprojectEnabled =
        ProcessInfo.processInfo.environment["AISLOPDESK_SCROLL_REPROJECT"] == "1"

    /// SCROLL-SHIFT QUANTIZE (default 3). Right-shifts each luma byte by this many bits before the
    /// per-row hash, so real capture noise (resample / dither / ±LSB) no longer breaks the EXACT row
    /// match the estimator relies on. Without it the host detects no scroll on real content (the
    /// `measureScrollOffset == 0 every frame` bug); 3 tolerates ±3 of per-pixel noise. `0` restores the
    /// exact byte-for-byte match. Clamped to 0...7. `AISLOPDESK_SCROLL_QUANTIZE`.
    private static let scrollQuantizeShift: UInt8 = {
        let v = ProcessInfo.processInfo.environment["AISLOPDESK_SCROLL_QUANTIZE"].flatMap(Int.init) ?? 3
        return UInt8(max(0, min(7, v)))
    }()

    /// ADAPTIVE-QP (default OFF). When enabled, each `.complete` frame's CHANGE magnitude vs the
    /// previous frame (NEON per-row hash → changed-row fraction) drives the live frame's
    /// `MaxAllowedFrameQP` ceiling: a small change (caret move, few chars) is pinned to a LOW (sharp)
    /// ceiling RC cannot coarsen past — even under a tight WAN budget — while a burst rides up to the
    /// configured ceiling (graded blur). Generalizes the crisp-on-FULL-static refresh to the common
    /// "almost-static editing" case. DEFAULT OFF ⇒ no measurement, byte-identical. Host-only, no wire.
    /// `AISLOPDESK_ADAPTIVE_QP=1`; `AISLOPDESK_AQP_SHARP` (sharp ceiling, default 22),
    /// `AISLOPDESK_AQP_BLO_MILLI`/`_BHI_MILLI` (change-fraction band ×1000, default 20/300).
    private static let adaptiveQPEnabled =
        ProcessInfo.processInfo.environment["AISLOPDESK_ADAPTIVE_QP"] == "1"
    private static let adaptiveQPSharp: Int = {
        if let s = ProcessInfo.processInfo.environment["AISLOPDESK_AQP_SHARP"], let v = Int(s) {
            return min(51, max(1, v))
        }
        return 22
    }()

    /// The motion-end QP ceiling the adaptive law ramps UP to on a burst (the sharp end is
    /// ``adaptiveQPSharp``). Defaults to the static drop-avoidance ceiling
    /// (``VideoEncoder/maxAllowedFrameQP``, e.g. 51); `AISLOPDESK_AQP_MAX` overrides so motion
    /// coarsening can be capped well below it (e.g. 36) — keeps a scroll frame readable while still
    /// shrinking it ~80 KB → ~15-25 KB. Under const-QP (motion-keyed band) this is the upper end of the
    /// `[floor, AQP_MAX]` range a scroll frame may coarsen into.
    private static let adaptiveQPMax: Int = {
        if let s = ProcessInfo.processInfo.environment["AISLOPDESK_AQP_MAX"], let v = Int(s), v >= 1, v <= 51 {
            return v
        }
        return VideoEncoder.maxAllowedFrameQP
    }()

    /// How fast the smoothed QP eases UP toward a coarser target on motion onset: the per-frame step is
    /// `(rawQP - smoothed) / N`. `N == 1` (default) ⇒ INSTANT — the QP jumps to the motion target on
    /// the very first scroll frame, so a quick push-scroll's burst-START frames are already coarse
    /// (small) instead of fat (the slow ease-up left the first ~6 frames sharp ⇒ ~80 KB ⇒ scroll
    /// "nặng"). Re-sharpen on STOP is always instant (the snap-down is unconditional). A larger `N`
    /// (`AISLOPDESK_AQP_UP_RAMP=2/3`) trades responsiveness for less QP shimmer if the coarsen-snap
    /// ever looks abrupt. Clamped ≥ 1.
    private static let adaptiveQPUpRamp: Int = {
        if let s = ProcessInfo.processInfo.environment["AISLOPDESK_AQP_UP_RAMP"], let v = Int(s), v >= 1 {
            return v
        }
        return 1
    }()

    /// How fast the smoothed QP eases DOWN toward the sharp floor when motion STOPS: at most this many
    /// QP per frame. A straight snap-to-floor (40→24 in one frame) re-encodes the whole settled
    /// viewport SHARP in a single ~80 KB frame — the scroll-STOP "khựng". Stepping down by a few QP
    /// spreads that re-sharpen over a handful of small frames (no hitch) while still reaching full
    /// sharpness within ~60-80 ms (imperceptible). `AISLOPDESK_AQP_DOWN_STEP` overrides; `≥ 51` (or a
    /// huge value) restores the old instant snap-down. Clamped ≥ 1.
    private static let adaptiveQPDownStep: Int = {
        if let s = ProcessInfo.processInfo.environment["AISLOPDESK_AQP_DOWN_STEP"], let v = Int(s), v >= 1 {
            return v
        }
        return 4
    }()

    private static let adaptiveQPBLoMilli: UInt32 = {
        if let s = ProcessInfo.processInfo.environment["AISLOPDESK_AQP_BLO_MILLI"], let v = UInt32(s) {
            return min(1000, v)
        }
        return 20
    }()

    private static let adaptiveQPBHiMilli: UInt32 = {
        if let s = ProcessInfo.processInfo.environment["AISLOPDESK_AQP_BHI_MILLI"], let v = UInt32(s) {
            return min(1000, v)
        }
        return 300
    }()

    /// TRUE IDLE-SKIP (default OFF). Parsec sends ZERO packets when the screen is static; on our
    /// VD/`displayIncluding` capture path SCK sometimes re-delivers byte-identical `.complete` frames
    /// that SCK does NOT mark `.idle`, so without this they get re-encoded + re-sent — a wasteful drip
    /// Parsec never pays. When enabled, a frame the adaptive-QP NEON measurement reports as TRULY idle
    /// (`measured && changeMilli == 0`, i.e. every row-hash identical to the previous frame) and that
    /// carries no pending obligation (keyframe / recovery / heartbeat — peeked, never drained) is
    /// dropped before the encode hand-off. CRITICAL: a skipped frame does NOT re-anchor
    /// `staticIDRDecider` (the quiet-window clock is allowed to go stale) so the ~300ms crisp refresh
    /// still fires on a genuinely-static window — the exact invariant the retired `STATIC_SUPPRESS`
    /// gate violated (it re-anchored on every dropped duplicate → the quiet window never opened → the
    /// stream froze). REUSES the adaptive-QP measurement, so it needs `AISLOPDESK_ADAPTIVE_QP=1` too.
    /// Gate OFF ⇒ `idleSkip` is always false ⇒ byte-identical to today. `AISLOPDESK_IDLE_SKIP=1`.
    private static let idleSkipEnabled =
        ProcessInfo.processInfo.environment["AISLOPDESK_IDLE_SKIP"] == "1"

    /// Pure eligibility for an idle-skip: a REAL measurement (`measured`) with zero changed rows.
    /// The `measured` guard rejects the FFI's degenerate-frame fallback (which also reports change 0
    /// but on an unmeasurable frame) so a genuinely-unknown frame is never mistaken for idle.
    static func idleSkipEligible(measured: Bool, changeMilli: UInt32) -> Bool {
        measured && changeMilli == 0
    }

    /// SCROLL-FPS CAP (default OFF, `AISLOPDESK_SCROLL_FPS`=N): during sustained FAST scroll (changed-row
    /// fraction ≥ `scrollMotionThresholdMilli`) encode only ~N of the 60 captured fps (even Bresenham
    /// decimation), so the HW encoder never overruns the 16.7 ms frame budget — the involuntary-VT-drop
    /// source at higher capture scales. Even pacing at a lower rate beats stuttery 60-with-random-drops.
    /// REQUIRES the change measurement (`AISLOPDESK_ADAPTIVE_QP=1` or idle-skip). Only ordinary live
    /// frames decimate; a pending forced/recovery/heartbeat always passes. Slow scroll / caret (low
    /// `changeMilli`) NEVER triggers (no slow-scroll regression). No rebuild ⇒ no hitch. `0` ⇒ disabled.
    static let scrollFps: Int = {
        guard let s = ProcessInfo.processInfo.environment["AISLOPDESK_SCROLL_FPS"], let v = Int(s), v > 0
        else { return 0 }
        return v
    }()

    /// Changed-row fraction (milli, 0–1000) at/above which a frame counts as FAST scroll for the
    /// scroll-fps cap. Default 120 (≈12% of rows changed) — well above caret/typing, around real scroll.
    static let scrollMotionThresholdMilli: UInt32 = {
        guard let s = ProcessInfo.processInfo.environment["AISLOPDESK_SCROLL_MOTION_MILLI"], let v = UInt32(s)
        else { return 120 }
        return v
    }()

    /// Consecutive fast-scroll frames required before decimation engages (debounce — a single flick
    /// frame is never dropped).
    static let scrollMotionSustainFrames = 2

    /// SCStream `queueDepth` (default 5, was 3). The VT encode runs synchronously on the capture
    /// sample-handler queue, so a deeper SCK surface queue prevents a single slow (fat scroll-burst)
    /// encode from stalling the next capture delivery (the measured capture-gap). `AISLOPDESK_CAPTURE_QUEUE_DEPTH`
    /// overrides (clamp 2…12).
    static let captureQueueDepth: Int = {
        if let s = ProcessInfo.processInfo.environment["AISLOPDESK_CAPTURE_QUEUE_DEPTH"], let v = Int(s) {
            return min(12, max(2, v))
        }
        return 5
    }()

    /// ENCODE DECOUPLING (default OFF, A/B via `AISLOPDESK_ENCODE_OFFQUEUE=1`). The VT encode runs
    /// SYNCHRONOUSLY in the SCStream sample handler, so during heavy scroll a per-frame encode that
    /// spikes past the ~16ms budget makes the handler fall progressively behind → SCStream holds
    /// surfaces → the measured 150–230ms capture gaps (the frame-smoothness "giật"). When ON, the
    /// handler instead COPIES the frame (~1ms) and hands the encode to a dedicated serial queue, then
    /// returns immediately → SCStream delivers at a steady 60Hz; encode runs in parallel, in PTS order.
    /// A bounded pending count drops ordinary deltas (never forced/recovery frames) if the encoder
    /// can't keep up — congestion-dropping at the encoder, not stalling capture (the P-chain stays
    /// intact, so no client decode break). `AISLOPDESK_ENCODE_QUEUE_MAX` overrides the bound (clamp 1…12).
    static let encodeOffQueueEnabled =
        ProcessInfo.processInfo.environment["AISLOPDESK_ENCODE_OFFQUEUE"] == "1"
    /// DIAGNOSTIC (overnight capture-cadence root-cause): force a compact recovery IDR every Nth live
    /// frame, so the loss-driven recovery-IDR storm is reproducible deterministically on localhost
    /// (no real loss needed). `AISLOPDESK_FORCE_COMPACT_EVERY=N`; 0/unset = off (byte-identical).
    static let forceCompactEvery: Int = {
        if let s = ProcessInfo.processInfo.environment["AISLOPDESK_FORCE_COMPACT_EVERY"], let v = Int(s), v > 0 {
            return v
        }
        return 0
    }()

    private var forceCompactCounter = 0

    static let maxEncodePending: Int = {
        if let s = ProcessInfo.processInfo.environment["AISLOPDESK_ENCODE_QUEUE_MAX"], let v = Int(s) {
            return min(12, max(1, v))
        }
        return 3
    }()

    /// SELF-HEAL cadence (2026-06-11, Parsec-style ack-anchored healing — HW-validated in
    /// `aislopdesk-loopback-validate --ack-ref` arms L/M/N/O): every `selfHealEvery`-th LIVE delta is
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
    /// the cadence into a surprise-IDR-every-K stream. `AISLOPDESK_SELF_HEAL` overrides K (frames,
    /// clamp 2…120); `0` disables. Requires `AISLOPDESK_LTR` (the session never arms eligibility
    /// otherwise — acks don't flow when LTR is off).
    static let selfHealEvery: Int = {
        if let s = ProcessInfo.processInfo.environment["AISLOPDESK_SELF_HEAL"], let v = Int(s) {
            if v == 0 { return 0 }
            return min(120, max(2, v))
        }
        // Default raised 6 → 30 (2026-06-16 latency-first reframe). Self-heal protects in-MOTION frames,
        // which the coding reframe deliberately lets blur/drop and re-sharpen — so heal far less often
        // (~+1.6% stream bytes at K=30 vs +8.2% at K=6). The static-window crisp re-anchor (~300ms,
        // StaticIDRDecider) already covers the "stop and read" case faster; a lost motion frame just
        // waits at most K frames (~1s @30fps) for the next refresh, which is acceptable while moving.
        return 30
    }()

    private let log = Logger(subsystem: "aislopdesk.video.host", category: "WindowCapturer")
    private let frameQueue = DispatchQueue(label: "aislopdesk.video.capture", qos: .userInteractive)
    private var stream: SCStream?
    private let frameHandler: FrameHandler

    /// Moves a single-owner `CVPixelBuffer` copy across the encode-queue hop. `CVPixelBuffer` is not
    /// `Sendable`; the copy has exactly one owner (just allocated), so the transfer is safe.
    private struct SendableBuffer: @unchecked Sendable { let value: CVPixelBuffer }

    /// ENCODE DECOUPLING (gated): a dedicated SERIAL queue the encode runs on when
    /// `encodeOffQueueEnabled`, so the capture handler returns immediately (no synchronous encode
    /// blocking SCStream delivery). nil ⇒ inline encode on the capture queue (legacy). `userInteractive`
    /// to match the capture queue's priority.
    private lazy var encodeQueue: DispatchQueue? =
        Self.encodeOffQueueEnabled ? DispatchQueue(label: "com.aislopdesk.encode", qos: .userInteractive) : nil
    /// Frames dispatched to `encodeQueue` but not yet encoded (lock-guarded — incremented on the
    /// capture queue, decremented on the encode queue). Caps the encode backlog.
    private let encodePendingLock = NSLock()
    private var encodePending = 0
    private var encodeBacklogDropped = 0

    /// Hand a frame to the encoder — inline (legacy) or, when `encodeOffQueueEnabled`, COPIED and
    /// dispatched to the serial `encodeQueue` so capture delivery is never blocked by encode time.
    /// Ordinary deltas are DROPPED when the encode backlog is full (`maxEncodePending`); a forced
    /// keyframe/crisp/compact/LTR-refresh is always submitted (recovery/sharpness anchor).
    private func handOffToEncoder(
        _ buffer: CVPixelBuffer,
        pts: CMTime,
        forceKeyframe: Bool,
        crisp: Bool,
        compact: Bool,
        ltrRefresh: Bool,
        perFrameMaxQP: Int?,
    ) {
        guard let encodeQueue else {
            frameHandler(buffer, pts, forceKeyframe, crisp, compact, ltrRefresh, perFrameMaxQP)
            return
        }
        let forced = forceKeyframe || crisp || compact || ltrRefresh
        encodePendingLock.lock()
        if !forced, encodePending >= Self.maxEncodePending {
            encodePendingLock.unlock()
            encodeBacklogDropped += 1
            if encodeBacklogDropped.isMultiple(of: 600) {
                let dropped = encodeBacklogDropped
                log.notice("encode-offqueue: \(dropped) deltas dropped (encoder backlog full)")
            }
            return // encoder can't keep up — drop this delta (P-chain intact), never stall capture
        }
        encodePending += 1
        encodePendingLock.unlock()
        guard let copy = Self.copyPixelBuffer(buffer) else {
            encodePendingLock.lock()
            encodePending -= 1
            encodePendingLock.unlock()
            return
        }
        let handler = frameHandler
        // The copy is a fresh single-owner buffer; moving it to the serial encode queue is safe.
        let boxed = SendableBuffer(value: copy)
        encodeQueue.async { [weak self] in
            handler(boxed.value, pts, forceKeyframe, crisp, compact, ltrRefresh, perFrameMaxQP)
            guard let self else { return }
            encodePendingLock.lock()
            encodePending -= 1
            encodePendingLock.unlock()
        }
    }

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
    /// `AISLOPDESK_MIN_IDR_MS`.
    ///
    /// COMPONENT 2 (delivery-keyed cooldown, 2026-06-11): with `AISLOPDESK_RECOVERY_IDR_V2` ON (the
    /// default) this legacy SENT-keyed gate is INERT (0) — the session actor's ``RecoveryIDRPolicy``
    /// (delivery-keyed + casualty bypass + token bucket) is the single admission authority, and it
    /// suppresses BEFORE latching, so a granted latch is never dropped here (the forced-frame
    /// invariant). `AISLOPDESK_RECOVERY_IDR_V2=0` restores today's 500 ms behaviour byte-for-byte. An
    /// EXPLICIT `AISLOPDESK_MIN_IDR_MS` always wins — even with V2 on (a valid belt-and-suspenders
    /// double-gating A/B configuration).
    private static let minRecoveryIDRInterval: TimeInterval = {
        if let s = ProcessInfo.processInfo.environment["AISLOPDESK_MIN_IDR_MS"], let v = Double(s), v >= 0,
           v <= 5000 { return v / 1000.0 }
        return ProcessInfo.processInfo.environment["AISLOPDESK_RECOVERY_IDR_V2"] != "0" ? 0 : 0.5
    }()

    /// Latched when the client requests a forced IDR (loss recovery, doc 17 §3.6). The
    /// next delivered frame forces a keyframe and clears it. Guarded because the
    /// orchestrator actor sets it off the capture queue. Plain `os_unfair_lock`-free:
    /// an `NSLock` is enough here (set rarely, read once per frame).
    private let keyframeLock = NSLock()
    private var pendingForcedKeyframe = false
    /// WF-8: latched when the host chose an LTR-refresh recovery (``AislopdeskVideoHostSession`` `.refreshLTR`
    /// → ``requestLTRRefresh()``) instead of a forced IDR. The next LIVE frame encodes a cheap
    /// ForceLTRRefresh P-frame and clears it; on a STATIC window the timer drains it and re-anchors
    /// with a crisp/compact IDR instead (an LTR refresh has no live delta to ride). Distinct from
    /// `pendingForcedKeyframe` so an LTR refresh never forces a keyframe (it is the cheap alternative).
    /// Under the same `keyframeLock`. Never set when `AISLOPDESK_LTR` is off (the actor folds .refreshLTR to
    /// requestKeyframe()) ⇒ always-false drain ⇒ byte-identical.
    private var pendingLTRRefresh = false
    /// SELF-HEAL eligibility — armed by the session actor while client LTR acks are flowing
    /// (``setSelfHealEligible(_:)``), disarmed on every encoder rebuild (fresh VT session = zero
    /// acked LTRs; a cadence refresh would then be VT's IDR fallback every K frames). Under
    /// `keyframeLock` (set rarely off-queue, read once per frame — same discipline as the latches).
    private var selfHealEligible = false
    /// FPS-GOVERNOR (2026-06-11): the governed encode fps the session actor latches via
    /// ``setGovernedFPS(_:)``. Equals `fps` (ungoverned, gate inert) until the governor steps.
    /// Under `keyframeLock` (set rarely off-queue, read once per frame — the `setSelfHealEligible`
    /// discipline). SCStream delivery stays at the FULL capture rate either way — the governor
    /// actuates at the capture→encode hand-off (``EncodeCadenceGate``), never by reconfiguring
    /// `minimumFrameInterval` (a governed 30 fps against a 60 Hz ceiling is exactly the slot-beat
    /// trap the 2× capture ceiling was raised to kill).
    private var governedFPS: Int
    /// FPS-GOVERNOR: the schedule-anchored regular-cadence admit gate. frameQueue-owned (only
    /// touched in the SCStream callback).
    private var cadenceGate = EncodeCadenceGate()
    /// GATED-TAIL FLUSH (2026-06-11): one-shot encode of the cached latest frame at the gate's
    /// next slot boundary, armed when a delivery is REJECTED by the cadence gate. Without it the
    /// LAST frame of a motion burst that lands on a gated slot waits for the ~1-1.25 s static
    /// crisp refresh — a visible stale tail at scroll end. frameQueue-owned (armed in the SCStream
    /// callback, fired on `frameQueue` via `asyncAfter`, replaced by any fresh `.complete`
    /// delivery, cancelled in ``stop()``'s `frameQueue.sync` teardown).
    private var pendingGatedFlush: DispatchWorkItem?
    /// LIVE frames since the last re-anchor (keyframe or LTR refresh) — drives the self-heal
    /// cadence. frameQueue-owned (only touched in the SCStream callback).
    private var framesSinceAnchor = 0

    // VIDEO-HOST-1 static-IDR (always on). All of these are touched ONLY on `frameQueue`
    // (the SCStream callback queue + the timer queue are the same), or — for the latch —
    // under `keyframeLock`.
    private var staticIDRDecider: StaticIDRDecider
    private var idrTimer: DispatchSourceTimer?
    private var cachedPixelBuffer: CVPixelBuffer? // deep COPY, frameQueue-owned (see copyPixelBuffer)

    // STATIC-FRAME SUPPRESSION (gated on `staticSuppressEnabled`). frameQueue-owned (only touched in
    // the SCStream callback). Inert when the gate is OFF (the hash is never computed).
    private let staticSuppressDecider = StaticFrameSuppressionDecider()
    /// Hash of the last frame ACTUALLY handed to the encoder, or nil before the first one. A new
    /// frame whose hash equals this — and that owes no forced obligation — is a duplicate to drop.
    private var lastSubmittedFrameHash: UInt64?
    /// Count of `.complete` frames suppressed as pixel-identical duplicates; logged periodically so
    /// a HW session can measure the re-delivery rate. frameQueue-owned.
    private var completeButDuplicateCount: UInt64 = 0
    /// Count of `.complete` frames dropped by the true-idle-skip gate (`idleSkipEnabled`); logged
    /// periodically so a HW session can confirm zero-on-static. frameQueue-owned.
    private var idleSkippedCount: UInt64 = 0
    /// Scroll-fps-cap state (frameQueue-owned): `scrollMotionRun` counts consecutive fast-scroll frames
    /// (debounce); `scrollPhase` is the Bresenham accumulator that keeps ~`scrollFps` of `fps`;
    /// `scrollDecimatedCount` logs how many motion frames were dropped to hold the cap.
    private var scrollMotionRun = 0
    private var scrollPhase = 0
    private var scrollDecimatedCount: UInt64 = 0
    /// Previous frame's FULL NV12 hash (luma+chroma) for the chroma-aware idle-skip drop. frameQueue-owned.
    private var lastIdleFullHash: UInt64?
    /// EVENT-DRIVEN CRISP state (gated on `stillCrispEnabled`). frameQueue-owned (the capture callback +
    /// the IDR timer run on the same queue), so no lock. Inert when the gate is OFF (no hash computed).
    private var stillnessDecider = StillnessCrispDecider()
    /// Hash of the immediately previous `.complete` frame, for the stillness count, or nil before the
    /// first. Distinct from `lastSubmittedFrameHash` (which tracks the last SUBMITTED frame for dedup).
    private var lastStillnessHash: UInt64?
    /// SCROLL REPROJECTION callback (gated on `scrollReprojectEnabled`): called on `frameQueue` with the
    /// measured per-frame offset (normalized ×10000, signed) + the moving-content vertical band
    /// (`bandTop`/`bandBottom`, ten-thousandths of height; `0,0` ⇒ no band) when scrolling — the session
    /// sends it as a `ScrollOffset` control message. `nil` ⇒ no send. frameQueue-confined.
    var onScrollOffset: (@Sendable (Int16, Int16, UInt16, UInt16) -> Void)?
    /// True while the last sent scroll offset was non-zero — so exactly one `(0,0)` is emitted when
    /// scroll stops (arming the client reprojector's decay) instead of spamming it on every static frame.
    private var lastScrollWasNonZero = false
    /// ADAPTIVE-QP (gated on `adaptiveQPEnabled`): the per-frame QP ceiling computed from this frame's
    /// change magnitude, staged here and read at the live encode hand-off. frameQueue-owned.
    private var pendingAdaptiveQP: Int?
    /// Asymmetric-EMA'd adaptive QP ceiling — snaps DOWN to a sharper ceiling instantly, eases UP to a
    /// blurrier one over ~3 frames (avoids QP shimmer on borderline activity). frameQueue-owned.
    private var adaptiveQPSmoothed: Int?
    /// KHỰNG-ladder stage 1 (AISLOPDESK_VIDEO_DEBUG): last DELIVERED-frame time, frameQueue-owned.
    static let dbgGapEnabled = ProcessInfo.processInfo.environment["AISLOPDESK_VIDEO_DEBUG"] != nil
    private var lastDeliveredAt: Double = 0
    /// Highest PTS handed to the encoder by EITHER path, in the 90 kHz synthetic timescale,
    /// so a synthetic IDR is strictly monotonic and a later real frame never reverses it.
    private var lastEmittedPTS: CMTime = .zero
    /// Standard MPEG 90 kHz timescale for the monotonic synthetic-PTS counter (§5; Sunshine
    /// "counter, not clock" discipline expressed in CMTime).
    private static let ptsTimescale: CMTimeScale = 90000

    /// Requests a forced IDR on the next captured frame (client loss-recovery →
    /// ``RecoveryMessage/requestIDR``). Thread-safe; called from the orchestrator actor.
    public func requestKeyframe() {
        keyframeLock.lock()
        pendingForcedKeyframe = true
        keyframeLock.unlock()
    }

    /// WF-8: requests a cheap LTR refresh on the next captured frame (host `.refreshLTR` recovery
    /// decision when the ACKED-ONLY gate holds). Thread-safe; called from the orchestrator actor.
    public func requestLTRRefresh() {
        keyframeLock.lock()
        pendingLTRRefresh = true
        keyframeLock.unlock()
    }

    /// SELF-HEAL gate. The session actor arms this when a client LTR ack folds (acks are flowing ⇒
    /// VT holds an acknowledged LTR ⇒ a cadence `ForceLTRRefresh` is a small loss-immune P-frame)
    /// and disarms it whenever a fresh encoder is installed (``AislopdeskVideoHostSession`` resets the
    /// LTR controller at the same sites). Thread-safe.
    public func setSelfHealEligible(_ eligible: Bool) {
        keyframeLock.lock()
        selfHealEligible = eligible
        keyframeLock.unlock()
    }

    private func selfHealIsEligible() -> Bool {
        keyframeLock.lock()
        defer { keyframeLock.unlock() }
        return selfHealEligible
    }

    /// FPS-GOVERNOR: latch the governed encode fps (clamped to `[1, fps]` — the governor never
    /// exceeds the base rate). Thread-safe; called from the orchestrator actor on every governed
    /// step (and re-applied after a resize installs a fresh capturer).
    public func setGovernedFPS(_ newFps: Int) {
        let clamped = min(fps, max(1, newFps))
        keyframeLock.lock()
        governedFPS = clamped
        keyframeLock.unlock()
    }

    private func currentGovernedFPS() -> Int {
        keyframeLock.lock()
        defer { keyframeLock.unlock() }
        return governedFPS
    }

    /// FPS-GOVERNOR: PEEK (without clearing) whether a recovery latch is pending — the cadence
    /// gate's `forced` bypass. The actual drain (`takePending…`) stays BELOW the gate, so the
    /// cooldown/latch logic sees an unchanged forced-frame stream and recovery latency stays
    /// ≤1 DELIVERY interval (deliveries continue at full rate), not 1 governed interval.
    private func peekPendingRecoveryLatches() -> Bool {
        keyframeLock.lock()
        defer { keyframeLock.unlock() }
        return pendingForcedKeyframe || pendingLTRRefresh
    }

    /// PEEK (without clearing) the pending-forced-keyframe latch — for the static-suppression
    /// decider's `forcedKeyframePending` input, so a suppressed duplicate never drains the latch
    /// (it drains on the next ENCODED frame).
    private func peekPendingForcedKeyframe() -> Bool {
        keyframeLock.lock()
        defer { keyframeLock.unlock() }
        return pendingForcedKeyframe
    }

    /// PEEK (without clearing) the pending-LTR-refresh latch — the static-suppression decider's
    /// `recoveryPending` input (an LTR refresh is the cheap recovery alternative to a forced IDR).
    private func peekPendingLTRRefresh() -> Bool {
        keyframeLock.lock()
        defer { keyframeLock.unlock() }
        return pendingLTRRefresh
    }

    /// Whether a periodic motion-heartbeat IDR is DUE this frame (only when the motion heartbeat is
    /// enabled — default OFF). Pure read of the heartbeat clock; the static-suppression decider must
    /// not suppress a frame that owes the periodic insurance IDR. frameQueue-owned read.
    private func peekHeartbeatDue(now: TimeInterval) -> Bool {
        Self.motionHeartbeatEnabled && now - lastHeartbeat >= Self.heartbeatIDRInterval
    }

    /// Atomically reads + clears the pending-forced-keyframe latch.
    private func takePendingForcedKeyframe() -> Bool {
        keyframeLock.lock()
        defer { keyframeLock.unlock() }
        let pending = pendingForcedKeyframe
        pendingForcedKeyframe = false
        return pending
    }

    /// WF-8: atomically reads + clears the pending-LTR-refresh latch.
    private func takePendingLTRRefresh() -> Bool {
        keyframeLock.lock()
        defer { keyframeLock.unlock() }
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
        // EVENT-DRIVEN crisp (gated): if a run of byte-identical .complete frames already proved the
        // screen is at rest, fire the crisp re-anchor NOW without waiting the wall-clock quiet window.
        // A crisp keyframe is a superset of any pending recovery latch, so drain those too (satisfied);
        // recordSynthetic re-anchors the normal static cadence so this never double-emits.
        if Self.stillCrispEnabled,
           stillnessDecider.shouldFireCrisp(restThreshold: Self.stillCrispThreshold),
           let buf = cachedPixelBuffer
        {
            _ = takePendingForcedKeyframe()
            _ = takePendingLTRRefresh()
            stillnessDecider.noteCrispFired()
            staticIDRDecider.recordSynthetic(now: now)
            lastKeyframeEmit = now
            handOffToEncoder(
                buf, pts: syntheticPTS(), forceKeyframe: true, crisp: Self.crispWhenStatic,
                compact: false, ltrRefresh: false, perFrameMaxQP: nil,
            )
            return
        }
        let forcedKeyframe = takePendingForcedKeyframe() // drain the keyframe latch
        // WF-8: a STATIC window has no live delta to ride an LTR refresh, so on this path an LTR
        // request degrades to the same crisp/compact re-anchor as a forced keyframe — drain it and
        // fold it into `forced` (but the frameHandler is still called with ltrRefresh=false: the
        // static path never issues an actual ForceLTRRefresh, it re-encodes the cached frame crisp).
        // Always false when AISLOPDESK_LTR is off ⇒ `forced` is byte-identical to today.
        let forcedLTR = takePendingLTRRefresh()
        let forced = forcedKeyframe || forcedLTR
        guard staticIDRDecider.shouldReencode(
            now: now,
            forcedLatched: forced,
            hasRetainedBuffer: cachedPixelBuffer != nil,
        ),
            let buf = cachedPixelBuffer
        else {
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
        lastKeyframeEmit = now // F1: the timer ALWAYS emits a keyframe → anchor the recovery cooldown
        // The window is at rest (the live path is quiet — that is why this timer fired), so upgrade
        // the re-encode to a CRISP near-lossless intra refresh for razor-sharp static text (Design A,
        // same live session → no client decoder rebuild). `AISLOPDESK_CRISP=0` falls back to a plain IDR.
        // Static (at-rest) path: crisp (sharp) when enabled, never compact — at rest there is no live
        // delta competing for the wire, so the larger near-lossless IDR is not a burst-loss risk.
        handOffToEncoder(
            buf,
            pts: syntheticPTS(),
            forceKeyframe: true,
            crisp: Self.crispWhenStatic,
            compact: false,
            ltrRefresh: false,
            perFrameMaxQP: nil, // static-timer crisp path owns its own QP (crisp bracket) — no adaptive ceiling
        ) // force IDR, same hand-off as live path (never an LTR refresh on the static path)
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
    /// The resolved SCStream delivery ceiling (Hz) — see ``resolveCaptureHz(envValue:fps:)``.
    /// Stored so the cadence gate's tolerance (half a delivery slot) matches the actual config.
    private let captureHz: Int
    /// Capture pixel scale (window points × this = the output buffer pixels). Needed to express
    /// `sourceRect` in POINTS (`pixelDim / captureScale`) — the source crop is point-space while
    /// `config.width/height` are pixel-space.
    private let captureScale: Double
    /// WF-6 (#8): capture NV12 in the FULL-RANGE pixel-format variant when true (else the VideoRange
    /// variant — today). Threaded into ``makeConfiguration``; default false ⇒ byte-identical capture.
    private let fullRange: Bool
    /// Prefer display-anchored capture (`.displayIncluding`) over the per-window compositor
    /// (`.window`) when no env override is set — see ``resolveCaptureMode(envValue:preferDisplayAnchored:)``.
    /// The live session passes `true`: display-anchored is ≈15ms lower glass-to-glass (one 60Hz slot)
    /// AND occlusion-proof (composites only the target window + children), so it is the default for
    /// every served window. `AISLOPDESK_DISPLAY_CAPTURE=window` forces the old per-window path; the
    /// init default stays `false` so the bare check-video CLI keeps `.window`.
    private let preferDisplayAnchored: Bool

    public init(
        fps: Int = 30,
        captureScale: Double = 1.0,
        fullRange: Bool = false,
        preferDisplayAnchored: Bool = false,
        frameHandler: @escaping FrameHandler,
    ) {
        self.preferDisplayAnchored = preferDisplayAnchored
        self.fps = max(1, fps)
        captureHz = Self.resolveCaptureHz(
            envValue: ProcessInfo.processInfo.environment["AISLOPDESK_CAPTURE_HZ"],
            fps: max(1, fps),
        )
        governedFPS = max(1, fps)
        self.captureScale = max(1.0, captureScale)
        self.fullRange = fullRange
        self.frameHandler = frameHandler
        // Quiet window gates shouldReencode (the crisp re-anchor): coding-tool reframe defaults it to
        // 300ms (was 1.0s) so text re-sharpens fast after motion stops, clamped to the heartbeat so a
        // longer heartbeat never stretches the timer-path recovery-suppression window. AISLOPDESK_QUIET_MS.
        staticIDRDecider = StaticIDRDecider(
            heartbeat: Self.heartbeatIDRInterval,
            quietWindow: Self.resolveQuietWindow(
                envValue: ProcessInfo.processInfo.environment["AISLOPDESK_QUIET_MS"],
                heartbeat: Self.heartbeatIDRInterval,
            ),
        )
        super.init()
    }

    /// Builds the MEASURED-config `SCStreamConfiguration` for a single window.
    ///
    /// ⚠️ `width`/`height` are PIXEL dimensions (window points × `captureScale`) — they become
    /// `config.width`/`config.height` directly, and `sourceRect` is derived back in POINTS by
    /// dividing by `captureScale`. So at `captureScale = 2` (the VD-parked path) the buffer is the
    /// window's Retina backing size and the crop is the window's point rect (contentScale = 2 → sharp).
    /// At `captureScale = 1` (the default / off-VD path) pixels == points. The `helloAck`
    /// captureWidth/Height and the cursor mapping stay in POINTS (= pixels / captureScale), so the
    /// client's `VideoScaleMath` denominator is correct. A caller passing POINTS here with
    /// `captureScale = 2` would crop only the top-left quarter — pass PIXELS.
    public static func makeConfiguration(
        width: Int,
        height: Int,
        fps: Int = 30,
        captureScale: Double = 1.0,
        fullRange: Bool = false,
    ) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        // NV12 zero-copy (doc 02 §3.1). WF-6 (#8): the luma RANGE is carried by the pixel-format
        // VARIANT (FullRange vs VideoRange) — THIS is the capture-side range knob; VT reads it to
        // stamp the SPS `video_full_range_flag`. R8/RG8 plane layout is identical for both NV12
        // variants, so the client's makeTexture is unaffected. Default VideoRange ⇒ today, byte-identical.
        config.pixelFormat = fullRange
            ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.showsCursor = false // client-side cursor (RESULTS.md D)
        // showMouseClicks gates the click "ripple" overlay (default NO; only applies
        // to BGRA capture per the SDK header — a no-op for our NV12 path, set for
        // intent).
        config.showMouseClicks = false
        // Cap at `fps` (default 30 — a coding tool, not a game stream; 60 reachable via --fps for
        // smoother motion). NOTE the capture ceiling stays at 2× the encode fps (≈60Hz @ fps=30 — see
        // resolveCaptureHz) so a changed frame (e.g. a typed character) is still picked up within ~16ms
        // and not quantized to the 33ms encode slot; only the ENCODE rate (and thus bitrate) drops.
        // macOS 15+ silently defaults to 1/60; idle-skip keeps a static window near-zero regardless (doc 02 §3.1).
        // LAT (2026-06-10, env AISLOPDESK_CAPTURE_HZ): the capture min-interval normally matches the
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
        let captureHz = resolveCaptureHz(
            envValue: ProcessInfo.processInfo.environment["AISLOPDESK_CAPTURE_HZ"],
            fps: fps,
        )
        config.minimumFrameInterval = CMTime(value: 1, timescale: Int32(captureHz))
        // queueDepth 3 → 5 (2026-06-17): the encode runs SYNCHRONOUSLY on this SCStream sample-handler
        // queue, so one fat scroll-burst frame's `VTCompressionSessionEncodeFrame` blocked the next
        // capture delivery once it over-ran ~`interval × (depth−1)` → the measured 61ms capture-gap.
        // A deeper queue lets SCK buffer more surfaces while an encode is in flight, so a single slow
        // frame becomes a brief blur instead of a capture freeze. `AISLOPDESK_CAPTURE_QUEUE_DEPTH` overrides.
        config.queueDepth = Self.captureQueueDepth
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
        // sits a hair to the right while the child is up. This residual only applies to `.window`
        // mode: since 2026-06-12 a VD-parked window defaults to `.displayIncluding`, whose crop is
        // DISPLAY-anchored — HW-probed dx=+1px here vs dx=0 there, tooltip kept (see ``CaptureMode``).
        let pointW = Double(width) / max(1.0, captureScale)
        let pointH = Double(height) / max(1.0, captureScale)
        config.sourceRect = CGRect(x: 0, y: 0, width: pointW, height: pointH)
        if #available(macOS 14.0, *) {
            config.ignoreShadowsSingleWindow = true // don't let the window's drop-shadow pad the rect
            config.ignoreGlobalClipSingleWindow = true // don't pad the rect to the global clip
        }
        return config
    }

    /// PURE capture-ceiling resolution (refactored out of ``makeConfiguration`` so it is
    /// unit-testable): `AISLOPDESK_CAPTURE_HZ` overrides, clamped [15, 240]; default 2× the encode
    /// fps, ceilinged at 240 (see the LAT note above — decouple the capture side only).
    static func resolveCaptureHz(envValue: String?, fps: Int) -> Int {
        if let envValue, let v = Int(envValue) { return min(240, max(15, v)) }
        return min(240, max(1, fps) * 2)
    }

    /// PURE quiet-window resolution (CRISP re-sharpen latency, 2026-06-16 latency-first reframe).
    ///
    /// How long after the last real `.complete` frame the static-IDR timer waits before emitting the
    /// crisp near-lossless re-anchor. Lower = text sharpens sooner after a scroll/motion burst stops
    /// ("vừa dừng là nét"); too low risks firing crisp during a one-frame pause mid-motion. The coding
    /// reframe drops it 1.0s → 300ms (the explicit re-sharpen target). `AISLOPDESK_QUIET_MS` overrides
    /// (MILLISECONDS), clamped [50ms, heartbeat] — never longer than the heartbeat (a longer window would
    /// stretch the timer-path recovery suppression; see `StaticIDRDecider`).
    static func resolveQuietWindow(envValue: String?, heartbeat: TimeInterval) -> TimeInterval {
        let floor = 0.05
        let ceil = max(floor, heartbeat)
        if let envValue, let ms = Double(envValue) {
            return min(ceil, max(floor, ms / 1000.0))
        }
        return min(ceil, max(floor, 0.3))
    }

    /// PURE static-IDR poll-tick resolution. The frameQueue timer polls the decider (recovery latch +
    /// idle service + the crisp re-anchor) every tick; the decider only EMITS when due, so sub-cadence
    /// ticks are cheap no-ops. Tightened 250ms → 80ms (2026-06-16) so worst-case time-to-crisp ≈
    /// quietWindow + tick ≈ 0.38s. `AISLOPDESK_IDR_TICK_MS` overrides (MILLISECONDS), clamped [20ms, 1s].
    static func resolveIDRPollTick(envValue: String?) -> TimeInterval {
        let floor = 0.02
        let ceil = 1.0
        if let envValue, let ms = Double(envValue) {
            return min(ceil, max(floor, ms / 1000.0))
        }
        return 0.08
    }

    /// Creates the content filter for one desktop-independent window. Captures the
    /// window's backing store at origin (0,0) so in-window coordinates are direct
    /// (doc 18 §B note).
    public static func makeFilter(window: SCWindow) -> SCContentFilter {
        SCContentFilter(desktopIndependentWindow: window)
    }

    /// How the SCStream sources the window's pixels.
    public enum CaptureMode: Equatable, Sendable {
        /// `SCContentFilter(desktopIndependentWindow:)` — follows the window anywhere, but the
        /// capture is anchored to the BOUNDING rect (window ∪ child windows), so a child window
        /// (Chrome's link-URL bubble) that overhangs the frame nudges the crop origin and the
        /// whole image shifts ~1px while the child is up (the 2026-06-08 sourceRect-pin tradeoff).
        case window
        /// `SCContentFilter(display:excludingWindows:[])` cropped to the window frame
        /// (display-local points). Immune to the child-window nudge, ~5ms faster p50 (framewatch
        /// signed A/B, n=51, 2026-06-10) — but EVERYTHING overlapping the rect is captured, so it
        /// is only correct when the window is alone on the display.
        case displayExcluding
        /// `SCContentFilter(display:including:[window])` cropped to the window frame. The crop is
        /// display-anchored (no child-window nudge) AND only the target window + its children are
        /// composited (occlusion-proof — N windows stacked on the shared VD can't bleed). Child
        /// windows ride along per the SDK ("display bound windows… Child windows are included by
        /// default"), kept explicit via `includeChildWindows`. Non-included area is empty per the
        /// SDK ("Display including content filters do not contain the desktop and dock").
        /// LATENCY (framewatch flasher, Studio loopback VD 2×, 2026-06-12, 3×~92 paired flips):
        /// glass-to-glass p50 35.8/36.0ms vs `.window` 50.7/51.2ms (≈ one 60Hz slot saved — the
        /// per-window composite path costs it), p90 equal (~53ms); matches `.displayExcluding`
        /// (35.7ms) — the include-list adds nothing measurable.
        case displayIncluding
    }

    /// PURE mode resolution (unit-tested). `AISLOPDESK_DISPLAY_CAPTURE` forces a mode for A/B:
    /// `window`/`0` → `.window`, `1`/`display` → `.displayExcluding`, `include` → `.displayIncluding`.
    /// Unset: `.displayIncluding` when the daemon parked the window on the virtual display
    /// (`preferDisplayAnchored` — HW-verified 2026-06-12: kills the tooltip 1px shift, keeps the
    /// tooltip, no multi-window bleed), else `.window` (off-VD the window may move/overlap freely).
    static func resolveCaptureMode(envValue: String?, preferDisplayAnchored: Bool) -> CaptureMode {
        switch envValue {
        case "window",
             "0": .window
        case "1",
             "display": .displayExcluding
        case "include",
             "display-include": .displayIncluding
        default: preferDisplayAnchored ? .displayIncluding : .window
        }
    }

    /// Display-anchor state for `.displayExcluding`/`.displayIncluding` (nil in `.window` mode):
    /// the crop is a FIXED display-local rect, so a window MOVE makes it stale — the session feeds
    /// geometry-watcher moves to ``updateDisplayAnchoredOrigin(windowFrameCG:)`` to re-anchor.
    /// Guarded by `anchorLock` (set on start's executor, read from the session actor's geometry path).
    private struct DisplayAnchor { let displayBounds: CGRect
        let config: SCStreamConfiguration
        let isUnion: Bool
    }

    private var displayAnchor: DisplayAnchor?
    private let anchorLock = NSLock()
    /// Serialize + coalesce display-anchor re-origins. The session fires a fresh `Task` per geometry
    /// message, so without this several could read/mutate the shared `DisplayAnchor.config` and call
    /// `updateConfiguration` on one SCStream concurrently (a check-then-act race + torn config writes).
    /// `reanchorInFlight` admits exactly one driver; newer frames overwrite `reanchorPending` so the
    /// driver always converges to the LATEST position. Guarded by `anchorLock`.
    private var reanchorInFlight = false
    private var reanchorPending: CGRect?

    /// An explicit display-anchored capture region (the DIALOG-EXPAND feature): when set, the crop
    /// is `displayLocalRect` (points) on `displayID` instead of the live window frame, so the
    /// captured surface spans the window ∪ its associated dialog. `globalRect` is the same region in
    /// global points — the session uses it to re-origin the input/cursor mapping into the dialog
    /// area. Built by ``CaptureRegionMath`` and threaded through ``start(window:pixelWidth:pixelHeight:region:)``.
    public struct CaptureRegionOverride: Sendable {
        public let displayID: CGDirectDisplayID
        public let displayLocalRect: CGRect
        public let globalRect: CGRect
        public init(displayID: CGDirectDisplayID, displayLocalRect: CGRect, globalRect: CGRect) {
            self.displayID = displayID
            self.displayLocalRect = displayLocalRect
            self.globalRect = globalRect
        }
    }

    /// Starts capturing the given window at an explicit PIXEL size (`pixelWidth`×`pixelHeight`).
    /// Passing the window's backing-pixel size (points × display scale) captures at native
    /// Retina resolution — sharp text — instead of the soft point-resolution default. ⚠️
    /// Requires a window-server + Screen-Recording TCC session — NEVER call from a test.
    ///
    /// `region` (DIALOG-EXPAND): when non-nil, the display-anchored crop is pinned to that explicit
    /// union rect (window ∪ dialog) instead of the live window frame — `pixelWidth`/`pixelHeight`
    /// must already match `region.globalRect.size × captureScale`. nil ⇒ the normal window-frame crop.
    public func start(
        window: SCWindow,
        pixelWidth: Int,
        pixelHeight: Int,
        region: CaptureRegionOverride? = nil,
    ) async throws {
        let config = Self.makeConfiguration(
            width: pixelWidth,
            height: pixelHeight,
            fps: fps,
            captureScale: captureScale,
            fullRange: fullRange,
        )
        var filter = Self.makeFilter(window: window)
        // A union region only makes sense in the display-including mode (it relies on
        // includeChildWindows compositing the dialog); force that mode when a region is supplied.
        let mode: CaptureMode = region != nil ? .displayIncluding
            // W12: resolve through `EnvConfig` (ProcessInfo env → overlay) so a GUI setting can force
            // the capture filter; an EMPTY overlay is byte-identical to the previous `ProcessInfo` read.
            : Self.resolveCaptureMode(
                envValue: EnvConfig.string("AISLOPDESK_DISPLAY_CAPTURE"),
                preferDisplayAnchored: preferDisplayAnchored,
            )
        if mode != .window {
            // Re-resolve the SCWindow by id: the mint flow AX-moves the window onto the VD AFTER
            // the `window` passed here was enumerated, so its `.frame` is the PRE-move one — the
            // display-local crop must come from the live (post-move) frame.
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            let liveWindow = content.windows.first(where: { $0.windowID == window.windowID }) ?? window
            // Region override carries its own display; else pick the display under the window centre.
            let display: SCDisplay?
            if let region {
                display = content.displays.first(where: { $0.displayID == region.displayID })
            } else {
                let center = CGPoint(x: liveWindow.frame.midX, y: liveWindow.frame.midY)
                display = content.displays.first(where: { CGDisplayBounds($0.displayID).contains(center) })
            }
            if let display {
                let db = CGDisplayBounds(display.displayID)
                if let region {
                    config.sourceRect = region.displayLocalRect
                } else {
                    config.sourceRect = CGRect(
                        x: liveWindow.frame.minX - db.minX,
                        y: liveWindow.frame.minY - db.minY,
                        width: Double(pixelWidth) / max(1.0, captureScale),
                        height: Double(pixelHeight) / max(1.0, captureScale),
                    )
                }
                switch mode {
                case .displayExcluding:
                    filter = SCContentFilter(display: display, excludingWindows: [])
                case .displayIncluding:
                    filter = SCContentFilter(display: display, including: [liveWindow])
                    if #available(macOS 14.2, *) { config.includeChildWindows = true }
                case .window:
                    break
                }
                anchorLock.withLock { displayAnchor = DisplayAnchor(
                    displayBounds: db,
                    config: config,
                    isUnion: region != nil,
                ) }
                log
                    .notice(
                        "capture mode \(String(describing: mode))\(region != nil ? " [union]" : ""): display \(display.displayID) sourceRect \(Int(config.sourceRect.origin.x)),\(Int(config.sourceRect.origin.y)) \(Int(config.sourceRect.width))x\(Int(config.sourceRect.height))pt",
                    )
            } else {
                log.error("display-anchored capture: no display contains window center — falling back to window filter")
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
        // Small poll, DECOUPLED from the heartbeat (F2): with a multi-second heartbeat the timer must
        // still poll the recovery latch + service a truly-idle window promptly. The decider only EMITS
        // when due, so sub-cadence ticks are cheap no-ops. Tightened 0.25s → 80ms (2026-06-16) so the
        // crisp re-anchor lands ≈ quietWindow + tick (~0.38s) after motion stops. AISLOPDESK_IDR_TICK_MS.
        let tick = Self.resolveIDRPollTick(envValue: ProcessInfo.processInfo.environment["AISLOPDESK_IDR_TICK_MS"])
        let leewayMs = max(8, Int((tick * 1000.0) / 4.0))
        let timer = DispatchSource.makeTimerSource(queue: frameQueue)
        timer.schedule(deadline: .now() + tick, repeating: tick, leeway: .milliseconds(leewayMs))
        timer.setEventHandler { [weak self] in self?.onIDRTimerTick() }
        timer.resume()
        idrTimer = timer
    }

    /// Re-anchors a display-anchored crop after the window MOVED (geometry-watcher feed from the
    /// session). No-op in `.window` mode (nil anchor) or for sub-half-point deltas. The crop jump
    /// lands mid-GOP as a whole-frame delta, so force a keyframe right after for a clean re-anchor.
    /// Rare + user-driven (a title-bar drag), never per-frame.
    public func updateDisplayAnchoredOrigin(windowFrameCG frame: CGRect) async {
        // Coalesce + serialize: record the latest frame, and only the FIRST caller becomes the driver
        // that applies updates — overlapping callers just hand off their frame and return. The driver
        // loops until no newer frame is pending, so we always converge to the latest position without
        // racing on the shared `DisplayAnchor.config` or issuing concurrent `updateConfiguration`s.
        let shouldDrive = anchorLock.withLock { () -> Bool in
            reanchorPending = frame
            if reanchorInFlight { return false }
            reanchorInFlight = true
            return true
        }
        guard shouldDrive else { return }
        while true {
            let next: CGRect? = anchorLock.withLock {
                let pending = reanchorPending
                reanchorPending = nil
                if pending == nil { reanchorInFlight = false }
                return pending
            }
            guard let f = next else { break }
            await applyReanchor(windowFrameCG: f)
        }
    }

    /// The actual single-threaded re-anchor (only ever run by the `updateDisplayAnchoredOrigin`
    /// driver, so the shared `DisplayAnchor.config` mutation + `updateConfiguration` are race-free).
    private func applyReanchor(windowFrameCG frame: CGRect) async {
        let anchor = anchorLock.withLock { displayAnchor }
        guard let anchor, let stream else { return }
        // In union mode the crop spans window ∪ dialog and is owned by the session's union poller —
        // a plain window-frame re-origin would drop the dialog. Skip; the poller re-targets instead.
        guard !anchor.isUnion else { return }
        let newOrigin = CGPoint(
            x: frame.minX - anchor.displayBounds.minX,
            y: frame.minY - anchor.displayBounds.minY,
        )
        let current = anchor.config.sourceRect.origin
        guard abs(newOrigin.x - current.x) >= 0.5 || abs(newOrigin.y - current.y) >= 0.5 else { return }
        anchor.config.sourceRect = CGRect(origin: newOrigin, size: anchor.config.sourceRect.size)
        do {
            try await stream.updateConfiguration(anchor.config)
            requestKeyframe()
            log.notice("display-anchored crop re-anchored to \(Int(newOrigin.x)),\(Int(newOrigin.y))pt (window moved)")
        } catch {
            log.error("display-anchored re-anchor failed: \(String(describing: error))")
        }
    }

    /// True when this capturer crops a DISPLAY (`.displayIncluding`/`.displayExcluding`) — i.e. it
    /// owns a live `DisplayAnchor` config that an in-place `updateConfiguration` size change can drive.
    /// `.window` mode (nil anchor) returns false. Read from the session actor; `anchorLock`-guarded.
    public var isDisplayAnchored: Bool { anchorLock.withLock { displayAnchor != nil } }

    /// True when the crop is a DIALOG-EXPAND union region (poller-owned) — an in-place resize must
    /// NOT touch it (the poller re-targets); the caller restart-fallbacks instead. `anchorLock`-guarded.
    public var isUnionAnchored: Bool { anchorLock.withLock { displayAnchor?.isUnion ?? false } }

    /// PURE gate (unit-tested): an in-place `updateConfiguration` resize is allowed only when the flag
    /// is on, the capture is display-anchored (the live default, with a serialized config driver), and
    /// the crop is NOT a poller-owned union. Everything else restart-fallbacks. Widen per-mode after HW proof.
    static func canResizeInPlace(flagEnabled: Bool, isDisplayAnchored: Bool, isUnion: Bool) -> Bool {
        flagEnabled && isDisplayAnchored && !isUnion
    }

    /// Why an in-place resize was refused — the caller restart-fallbacks on any of these.
    public enum CannotResizeInPlace: Error { case noStream, notDisplayAnchored, unionOwned }

    /// IN-PLACE resize: reconfigure the LIVE SCStream to `pixelWidth`×`pixelHeight` via
    /// `updateConfiguration` — NO restart, so SCK's ~120ms `startCapture` spin-up is avoided. Rebuilds
    /// the config at the new size, preserves the live display-anchored crop ORIGIN at the new point
    /// size, and stores the rebuilt config back so a later window-MOVE re-anchor uses the new size.
    /// THROWS `CannotResizeInPlace` for `.window`/union/no-stream (caller restart-fallbacks); on a thrown
    /// `updateConfiguration` the live stream keeps running at the OLD size (no dead stream). The filter is
    /// unchanged (same window+display), so only the config (size + sourceRect) is updated.
    public func updateSize(pixelWidth: Int, pixelHeight: Int) async throws {
        guard let stream else { throw CannotResizeInPlace.noStream }
        // Claim the single-driver gate so a CONCURRENT window-MOVE re-anchor defers (records pending)
        // instead of issuing a second `updateConfiguration` on this stream mid-resize. Best-effort: if a
        // re-anchor is ALREADY driving, this resize's config write still wins last + the next geometry
        // re-anchor reads the new-size anchor below and self-heals — a documented rare residual (this
        // path is env-gated + HW-validation-gated). Clear the gate + drop any stale pending move at the end.
        anchorLock.withLock { reanchorInFlight = true }
        defer { anchorLock.withLock { reanchorInFlight = false
            reanchorPending = nil
        } }
        guard let anchor = anchorLock.withLock({ displayAnchor }) else { throw CannotResizeInPlace.notDisplayAnchored }
        guard !anchor.isUnion else { throw CannotResizeInPlace.unionOwned }
        let pointW = Double(pixelWidth) / max(1.0, captureScale)
        let pointH = Double(pixelHeight) / max(1.0, captureScale)
        let newConfig = Self.makeConfiguration(
            width: pixelWidth,
            height: pixelHeight,
            fps: fps,
            captureScale: captureScale,
            fullRange: fullRange,
        )
        // Preserve the live crop ORIGIN (top-left fixed across an AX resize) at the NEW point size,
        // and the display-including child-window compositing.
        newConfig.sourceRect = CGRect(
            origin: anchor.config.sourceRect.origin,
            size: CGSize(width: pointW, height: pointH),
        )
        if #available(macOS 14.2, *) { newConfig.includeChildWindows = anchor.config.includeChildWindows }
        try await stream.updateConfiguration(newConfig)
        // Persist the rebuilt (new-size) config so a later MOVE re-anchor crops at the right size.
        anchorLock.withLock {
            displayAnchor = DisplayAnchor(displayBounds: anchor.displayBounds, config: newConfig, isUnion: false)
        }
        log.notice("in-place resize: updateConfiguration to \(pixelWidth)x\(pixelHeight) px (no restart)")
    }

    public func stop() async {
        guard let stream else { return }
        anchorLock.withLock { displayAnchor = nil }
        // VIDEO-HOST-1: cancel the timer + release the cached copy on `frameQueue` (the timer's
        // queue) BEFORE stopping capture, so no tick can race teardown. `cachedPixelBuffer = nil`
        // is sufficient — ARC releases the managed copy; no manual CVPixelBufferRelease.
        frameQueue.sync {
            idrTimer?.cancel()
            idrTimer = nil
            // GATED-TAIL FLUSH: cancel the one-shot inside the same frameQueue.sync, so no flush
            // can race teardown (the work item runs on frameQueue too). Belt-and-braces: a
            // hypothetical already-queued execution is also inert — `cachedPixelBuffer` is nil.
            pendingGatedFlush?.cancel()
            pendingGatedFlush = nil
            cachedPixelBuffer = nil
        }
        try? await stream.stopCapture()
        self.stream = nil
    }

    // MARK: SCStreamOutput

    public func stream(
        _: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType,
    ) {
        guard type == .screen else { return }

        // Idle-skip (doc 17 §3.5): read SCStreamFrameInfo.status; on .idle return
        // immediately — no IOSurface touch, no encode, no send. This keeps the
        // encoder slot free for the next real (keystroke-driven) frame.
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false,
        ) as? [[SCStreamFrameInfo: Any]],
            let info = attachments.first,
            let statusRaw = info[.status] as? Int,
            let status = SCFrameStatus(rawValue: statusRaw)
        else {
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

        // KHỰNG LADDER stage 1 (2026-06-10, AISLOPDESK_VIDEO_DEBUG): a >28ms gap between two DELIVERED
        // frames during continuous motion means SCK itself stalled (or idle-skipped a changing
        // frame) — anything downstream can only inherit this hole. Idle pages legitimately gap;
        // read these lines only against a continuous-motion test (testufo).
        if Self.dbgGapEnabled {
            if lastDeliveredAt > 0, now - lastDeliveredAt > 0.028 {
                FileHandle.standardError
                    .write(Data("aislopdesk-videohostd[gap]: capture gap \(Int((now - lastDeliveredAt) * 1000))ms\n"
                            .utf8))
            }
            lastDeliveredAt = now
        }

        // VIDEO-HOST-1: cache a deep COPY of this real frame so the timer can re-encode it as a
        // forced IDR while the window is static, anchor the decider's live clock, and advance the
        // synthetic-PTS high-water mark so a later synthetic frame stays strictly past every real
        // frame (§5). All on `frameQueue`. >90% of frames are idle, so this copy lands only on the
        // rare real frame that already pays for an encode.
        // SCROLL REPROJECTION (gated): measure the TRUE per-frame content scroll between the PREVIOUS
        // cached frame and this one and send it to the client (which warps the last frame by it between
        // codec frames). Done BEFORE cachedPixelBuffer is overwritten, so it is still the previous frame.
        // Only sends on a confident non-zero shift, plus one (0,0) when scroll stops (decay arm).
        if Self.scrollReprojectEnabled, let prev = cachedPixelBuffer {
            let (dx, dy, bandTop, bandBottom) = Self.measureScrollOffset(prev: prev, cur: pixelBuffer)
            if dx != 0 || dy != 0 {
                onScrollOffset?(dx, dy, bandTop, bandBottom)
                lastScrollWasNonZero = true
            } else if lastScrollWasNonZero {
                onScrollOffset?(0, 0, 0, 0)
                lastScrollWasNonZero = false
            }
        }
        // ADAPTIVE-QP (gated): measure this frame's change magnitude vs the PREVIOUS frame and stage the
        // per-frame QP ceiling (sharp on a small change, graded blur on a burst). BEFORE cachedPixelBuffer
        // is overwritten, so it is still the previous frame. Asymmetric-EMA: snap to sharper instantly,
        // ease to blurrier slowly (no QP shimmer). Read at the live encode hand-off (`encodeBelowGate`).
        // Adaptive-QP AND true-idle-skip both reuse ONE NEON change measurement vs the previous frame.
        // Run it when either feature is on. `measured` is true only on a real (non-fallback) measurement,
        // so the FFI's degenerate-frame fallback (also change 0) can never be mistaken for idle.
        var changeMilli: UInt32 = 0
        var measured = false
        if Self.adaptiveQPEnabled || Self.idleSkipEnabled, let prev = cachedPixelBuffer,
           let m = Self.measureAdaptiveQP(prev: prev, cur: pixelBuffer)
        {
            measured = true
            changeMilli = m.changeMilli
            if Self.adaptiveQPEnabled {
                let rawQP = m.qp
                let smoothed: Int =
                    if let s = adaptiveQPSmoothed {
                        if rawQP > s {
                            // Coarsen on motion ONSET by 1/upRamp (default 1 ⇒ INSTANT) so a scroll's
                            // first frames are already small.
                            s + max(1, (rawQP - s) / Self.adaptiveQPUpRamp)
                        } else {
                            // Re-sharpen on STOP by at most downStep QP/frame: a snap straight to the
                            // floor re-encodes the whole settled viewport in ONE ~80 KB frame (the
                            // scroll-stop "khựng"); stepping spreads it over a few small frames.
                            max(rawQP, s - Self.adaptiveQPDownStep)
                        }
                    } else {
                        rawQP
                    }
                adaptiveQPSmoothed = smoothed
                pendingAdaptiveQP = smoothed
                if Self.dbgGapEnabled {
                    FileHandle.standardError
                        .write(Data("aislopdesk-videohostd[aqp]: rawQP=\(rawQP) smoothed=\(smoothed)\n".utf8))
                }
            } else {
                pendingAdaptiveQP = nil
            }
        } else {
            pendingAdaptiveQP = nil
        }
        // LATENCY (2026-06-18, Rank 1): defer the `cachedPixelBuffer` COPY to function exit so it no longer
        // blocks the encode-submit critical path. The cache (IDR-heartbeat / crisp / dialog-union) is read
        // only on LATER timer ticks, never by THIS frame's encode (which is handed `pixelBuffer` directly).
        // `defer` fires on EVERY exit — idle-skip / scroll-fps / static-suppress / governor-gate returns AND
        // the encode path — so the cache updates on all paths exactly as before; only its ORDER vs the inline
        // encode changes (the encoder sees the frame ~0.5–2ms sooner). Placed AFTER the measure-vs-prev reads
        // above so scroll-reproject + adaptive-QP still compare against the PREVIOUS frame.
        defer { cachedPixelBuffer = Self.copyPixelBuffer(pixelBuffer) }

        // TRUE IDLE-SKIP decision (default OFF): drop a frame ONLY when it is byte-identical to the
        // previous one by the FULL NV12 hash (luma+chroma, `hashFrame`) — so a chroma-only change (a
        // syntax-highlight color flip, theme toggle) is NOT mistaken for idle (the luma-only `changeMilli`
        // would miss it) — AND it carries no pending obligation. The cheap luma `idleSkipEligible`
        // pre-check (the adaptive-QP changed-row fraction) gates the full-hash compute. A skipped frame
        // must NOT re-anchor `staticIDRDecider` below — leaving the quiet-window clock stale lets the
        // ~300ms crisp refresh fire on a static window (the anti-freeze invariant STATIC_SUPPRESS violated).
        var idleSkip = false
        if Self.idleSkipEnabled,
           Self.idleSkipEligible(measured: measured, changeMilli: changeMilli),
           let fullHash = Self.hashFrame(pixelBuffer),
           fullHash != FrameHash.SENTINEL
        {
            idleSkip = lastIdleFullHash == fullHash
                && staticSuppressDecider.shouldSuppress(
                    hashEqualToLast: true, // full-frame (luma+chroma) hash equality already proven above
                    isFirstFrame: !hasEmittedFirstFrame,
                    forcedKeyframePending: peekPendingForcedKeyframe(),
                    recoveryPending: peekPendingLTRRefresh(),
                    heartbeatDue: peekHeartbeatDue(now: now),
                    ltrRefreshDue: false,
                    selfHealDue: false,
                )
            lastIdleFullHash = fullHash
        }
        if !idleSkip {
            staticIDRDecider.onCompleteFrame(now: now)
        }

        // EVENT-DRIVEN crisp (gated): feed this frame's hash-equality to the stillness decider so a run
        // of byte-identical .complete re-deliveries can trip the crisp re-anchor before the quiet window
        // (the IDR timer drains it). Runs BEFORE the suppression block so the decider sees every frame.
        if Self.stillCrispEnabled,
           let frameHash = Self.hashFrame(pixelBuffer),
           frameHash != FrameHash.SENTINEL
        {
            stillnessDecider.onFrame(hashEqualToPrevious: lastStillnessHash == frameHash)
            lastStillnessHash = frameHash
        }

        // TRUE IDLE-SKIP (default OFF): drop this byte-identical, obligation-free frame entirely — no
        // encode, no packetize, no send (Parsec's zero-on-static). The cache + stillness feed above ran
        // first (so the crisp triggers stay healthy) and `staticIDRDecider` was deliberately NOT
        // re-anchored, so the quiet-window crisp still fires ~300ms after the screen truly settles.
        if idleSkip {
            idleSkippedCount += 1
            if idleSkippedCount.isMultiple(of: 600) {
                let dropped = idleSkippedCount
                log.notice("idle-skip: \(dropped) true-idle frames dropped (zero packets while static)")
            }
            return
        }

        // SCROLL-FPS CAP (default OFF): hold ~scrollFps of the captured fps during sustained FAST scroll
        // so the HW encoder never overruns the budget (the involuntary-VT-drop source at higher capture
        // scales). Bresenham-even decimation; only ordinary live frames drop — a pending forced/recovery/
        // heartbeat always passes — and slow scroll / caret (low changeMilli) never triggers. No rebuild.
        if Self.scrollFps > 0, Self.scrollFps < fps,
           measured, changeMilli >= Self.scrollMotionThresholdMilli
        {
            scrollMotionRun = min(scrollMotionRun + 1, 1_000_000)
        } else {
            scrollMotionRun = 0
        }
        if scrollMotionRun >= Self.scrollMotionSustainFrames,
           !peekPendingForcedKeyframe(), !peekPendingLTRRefresh(), !peekHeartbeatDue(now: now)
        {
            scrollPhase += Self.scrollFps
            if scrollPhase >= fps {
                scrollPhase -= fps // KEEP this frame
            } else {
                scrollDecimatedCount += 1
                if scrollDecimatedCount.isMultiple(of: 600) {
                    let dropped = scrollDecimatedCount
                    let cap = Self.scrollFps
                    log.notice("scroll-fps: \(dropped) fast-scroll frames decimated to ~\(cap)fps")
                }
                return // SKIP — even-decimate this fast-scroll frame (no encode/packetize/send)
            }
        } else {
            scrollPhase = 0 // reset the accumulator when not decimating
        }

        // STATIC-FRAME SUPPRESSION (default OFF). Hash THIS frame's locked NV12 planes (zero-copy,
        // NEON) and, when it is pixel-identical to the last SUBMITTED frame and no forced obligation
        // is pending, drop it here — before any PTS bookkeeping or the encode hand-off — so a SCK
        // `.complete` re-delivery of unchanged pixels never re-encodes/re-sends. The cache + decider
        // clock above ARE updated first, so the static-IDR timer still re-anchors on a quiet window.
        // Gate OFF ⇒ this block is skipped entirely (no hash, byte-identical to today).
        if Self.staticSuppressEnabled,
           let frameHash = Self.hashFrame(pixelBuffer),
           frameHash != FrameHash.SENTINEL,
           let lastHash = lastSubmittedFrameHash
        {
            // PEEK (do not drain) the forced obligations so a suppressed frame never swallows a
            // pending recovery/keyframe latch — the latch drains on the next encoded frame, exactly
            // as the FPS-governor cadence gate peeks. The first-frame case is covered by
            // `lastSubmittedFrameHash == nil` (this branch is skipped until a frame has been sent).
            if staticSuppressDecider.shouldSuppress(
                hashEqualToLast: frameHash == lastHash,
                isFirstFrame: !hasEmittedFirstFrame,
                forcedKeyframePending: peekPendingForcedKeyframe(),
                recoveryPending: peekPendingLTRRefresh(),
                heartbeatDue: peekHeartbeatDue(now: now),
                ltrRefreshDue: false, // folded into recoveryPending (the LTR-refresh latch)
                selfHealDue: false, // self-heal is decided per-ENCODED frame below the gate, never here
            ) {
                completeButDuplicateCount += 1
                // Log every 600th suppression (~10 s at 60 fps of pure duplicates) so a HW session
                // can read the re-delivery rate without flooding the log on a static screen.
                if completeButDuplicateCount.isMultiple(of: 600) {
                    let dropped = completeButDuplicateCount
                    log.notice("static-frame suppression: \(dropped) complete-but-duplicate frames dropped")
                }
                return // duplicate with no obligation — skip encode/send entirely
            }
        }

        let pts90k = CMTimeConvertScale(pts, timescale: Self.ptsTimescale, method: .default)
        // Clamp the value ACTUALLY handed to the encoder up to the high-water mark — not just
        // the tracker — so a real frame can never reverse a prior synthetic IDR's PTS (the
        // live session has AllowFrameReordering=false), and both paths feed VT a single uniform
        // 90 kHz timescale (review finding, VIDEO-HOST-1 §5).
        lastEmittedPTS = CMTimeMaximum(lastEmittedPTS, pts90k)
        let encodePTS = lastEmittedPTS

        // FPS-GOVERNOR cadence gate (2026-06-11): when governed below the base fps, admit
        // deliveries on the drift-free schedule (every 2nd/3rd/4th delivery slot — metronome-
        // regular, NOT the retired alternating skip). Placement invariants (each load-bearing):
        //  - the cachedPixelBuffer copy + staticIDRDecider.onCompleteFrame above MUST run for
        //    gated frames too. Cache: otherwise the static-timer crisp refresh would re-ship a
        //    stale pre-final frame after motion stops on a gated frame (permanent stale screen).
        //    Decider: otherwise the timer would think the live path quiet and fire crisp IDRs
        //    MID-motion. Cost unchanged vs today (every delivered frame is copied today already).
        //  - the gate sits ABOVE the latch DRAIN and uses a PEEK for `forced`, so a gated return
        //    is impossible while a recovery latch is pending / before the first frame — recovery
        //    converts to the NEXT delivery (≤1 delivery interval, deliveries stay at full rate).
        //  - `framesSinceAnchor` (below) counts only ENCODED frames — self-heal stays
        //    per-encoded-frame, rebased time-equivalently via SelfHealCadence.
        //  - a due motion-heartbeat (default OFF) sits below the gate ⇒ worst-case +66 ms slip on
        //    its 2.5 s cadence — acceptable.
        //  - GATED-TAIL FLUSH: any fresh `.complete` delivery supersedes a pending one-shot flush
        //    (it either encodes now, or is gated and RE-ARMS a replacement below) — so the flush
        //    only ever fires when its armed frame is still the NEWEST content.
        pendingGatedFlush?.cancel()
        pendingGatedFlush = nil
        let governed = currentGovernedFPS()
        if governed < fps {
            let mustEncode = !hasEmittedFirstFrame || peekPendingRecoveryLatches()
            if !cadenceGate.admit(
                now: now,
                targetIntervalSeconds: 1.0 / Double(governed),
                toleranceSeconds: 0.5 / Double(captureHz),
                forced: mustEncode,
            ) {
                // Delivered-but-gated: cache/decider/PTS already updated above. If this turns out
                // to be the LAST frame of the burst, the one-shot ships its content at the next
                // governed slot boundary instead of leaving a stale tail until the crisp refresh.
                scheduleGatedTailFlush(now: now)
                return
            }
        }
        encodeBelowGate(pixelBuffer: pixelBuffer, encodePTS: encodePTS, now: now, governed: governed)
    }

    /// The BELOW-GATE encode path, shared verbatim by the live SCStream delivery and the
    /// gated-tail flush (so the flushed frame honours every convention: latch drain, first-frame /
    /// heartbeat / recovery-cooldown keyframe resolution, compact IDR, LTR refresh + self-heal
    /// cadence). frameQueue-owned.
    private func encodeBelowGate(pixelBuffer: CVPixelBuffer, encodePTS: CMTime, now: TimeInterval, governed: Int) {
        // Heartbeat IDR ~1s, plus a forced keyframe on the very first delivered frame,
        // plus any client-requested IDR (loss recovery, doc 17 §3.6).
        let latched = takePendingForcedKeyframe()
        // WF-8: drain the LTR-refresh latch too (always false when AISLOPDESK_LTR is off ⇒ byte-identical).
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
           Self.minRecoveryIDRInterval > 0, now - lastKeyframeEmit < Self.minRecoveryIDRInterval
        {
            forceKeyframe = false
        }
        // Anchor BOTH the heartbeat cadence and the recovery cooldown on ANY actually-emitted keyframe.
        if forceKeyframe { lastHeartbeat = now
            lastKeyframeEmit = now
        }
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
        // Always false when AISLOPDESK_LTR is off (the latch is never set) ⇒ byte-identical.
        var ltrRefresh = ltrLatched && !forceKeyframe
        // SELF-HEAL cadence: every `selfHealEvery`-th live delta becomes an acked-LTR-anchored
        // refresh (see the `selfHealEvery` doc — HW-validated loss self-healing). Counted against
        // the last RE-ANCHOR (keyframe or any refresh) so a recovery-latched refresh restarts the
        // window. Gated on eligibility (acks flowing) — ineligible frames don't advance the
        // counter past the threshold meaninglessly; they keep counting so healing starts at most
        // one frame after eligibility arms.
        // FPS-GOVERNOR: the heal K is rebased TIME-equivalently at a governed fps (60→6, 30→3,
        // 20→2, 15→2) so the wall-clock heal latency stays ≈100-133 ms — fps is governed down
        // exactly when whole-frame loss is most likely. `governed == fps` ⇒ K unchanged.
        let healEvery = SelfHealCadence.effectiveEvery(
            baseEvery: Self.selfHealEvery,
            baseFps: fps,
            governedFps: governed,
        )
        if healEvery > 0, !forceKeyframe, !ltrRefresh {
            framesSinceAnchor += 1
            if framesSinceAnchor >= healEvery, selfHealIsEligible() {
                ltrRefresh = true
            }
        }
        if forceKeyframe || ltrRefresh { framesSinceAnchor = 0 }

        // STATIC-FRAME SUPPRESSION: record the hash of the frame we are ABOUT TO SUBMIT (only when
        // the gate is on), so the NEXT capture is compared against the last frame actually sent
        // (never against a frame that was cadence-gated and dropped). Computed from the exact buffer
        // being handed to the encoder, so every submit path (live + gated-tail flush) stays in sync.
        if Self.staticSuppressEnabled {
            lastSubmittedFrameHash = Self.hashFrame(pixelBuffer)
        }

        // Hand the CVPixelBuffer to the encoder. The pixel buffer is retained by the
        // encoder for the duration of the encode; when this callback returns the
        // CMSampleBuffer (and its surface) is released — within the queue-depth
        // deadline minimumFrameInterval × (queueDepth − 1) (WWDC22 s10155).
        // A live (motion) frame is NEVER crisp — motion must stay low-latency; only the static
        // timer above upgrades to a crisp refresh.
        // DIAGNOSTIC force-compact storm (AISLOPDESK_FORCE_COMPACT_EVERY): reproduce the loss-driven
        // recovery-IDR storm on localhost. Only when no real obligation is already set.
        var forceCompact = compact
        if Self.forceCompactEvery > 0, !forceKeyframe, !ltrRefresh, !compact {
            forceCompactCounter += 1
            if forceCompactCounter.isMultiple(of: Self.forceCompactEvery) { forceCompact = true }
        }
        handOffToEncoder(
            pixelBuffer, pts: encodePTS, forceKeyframe: forceKeyframe, crisp: false,
            compact: forceCompact, ltrRefresh: ltrRefresh, perFrameMaxQP: pendingAdaptiveQP,
        )
    }

    // MARK: GATED-TAIL FLUSH (FPS governor, 2026-06-11)

    /// Arms (REPLACING any prior one — repeated gated deliveries re-arm) the one-shot flush at the
    /// cadence gate's next-due boundary. The work item runs on `frameQueue`, so it is serialized
    /// against the SCStream callback: by construction it only fires when NO newer `.complete`
    /// delivery arrived after arming (a fresh delivery cancels/replaces it first). frameQueue-owned.
    private func scheduleGatedTailFlush(now: Double) {
        pendingGatedFlush?.cancel()
        let delay = max(0, cadenceGate.nextDue - now)
        let item = DispatchWorkItem { [weak self] in self?.onGatedTailFlush() }
        pendingGatedFlush = item
        frameQueue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// One-shot flush body (runs on `frameQueue`): re-encode the cached LATEST frame — the gated
    /// content — through the normal below-gate path. The gate is re-consulted at the boundary
    /// (advancing the drift-free schedule so the metronome stays regular around the flush; the
    /// `forced` peek keeps the forced-frames-are-never-gated invariant); a governed fps that
    /// returned to base in the meantime makes the gate inert, exactly like the live path. The PTS
    /// is the established synthetic 90 kHz counter (strictly monotonic past the gated frame's own
    /// PTS, which already advanced `lastEmittedPTS` above the gate).
    private func onGatedTailFlush() {
        pendingGatedFlush = nil
        guard let buf = cachedPixelBuffer else { return } // stopped / never delivered — nothing to ship
        let now = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1_000_000_000.0
        let governed = currentGovernedFPS()
        if governed < fps {
            let mustEncode = !hasEmittedFirstFrame || peekPendingRecoveryLatches()
            guard cadenceGate.admit(
                now: now,
                targetIntervalSeconds: 1.0 / Double(governed),
                toleranceSeconds: 0.5 / Double(captureHz),
                forced: mustEncode,
            ) else {
                return // fired early vs the schedule (clock skew) — the next delivery covers it
            }
        }
        encodeBelowGate(pixelBuffer: buf, encodePTS: syntheticPTS(), now: now, governed: governed)
    }

    // MARK: SCStreamDelegate

    public func stream(_: SCStream, didStopWithError error: Error) {
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
        let planes = CVPixelBufferGetPlaneCount(src) // NV12 = 2 (Y, CbCr)
        for p in 0..<planes {
            guard let s = CVPixelBufferGetBaseAddressOfPlane(src, p),
                  let d = CVPixelBufferGetBaseAddressOfPlane(dst, p) else { return nil }
            let sb = CVPixelBufferGetBytesPerRowOfPlane(src, p)
            let db = CVPixelBufferGetBytesPerRowOfPlane(dst, p)
            let rows = CVPixelBufferGetHeightOfPlane(src, p)
            if sb == db {
                memcpy(d, s, sb * rows)
            } else { // stride mismatch → row-by-row
                let copyBytes = min(sb, db)
                for r in 0..<rows { memcpy(d + r * db, s + r * sb, copyBytes) }
            }
        }
        return dst
    }

    // MARK: STATIC-FRAME SUPPRESSION pixel-buffer hash

    /// Hashes the NV12 `pixelBuffer`'s luma + interleaved-chroma planes into one 64-bit value via the
    /// native ``FrameHasher/hashNV12(y:yStride:width:height:cbcr:cbcrStride:)`` NEON kernel, ZERO-COPY: it locks the buffer read-only,
    /// passes the locked plane base addresses + their `bytesPerRow` strides straight to Rust (which
    /// borrows them for the call only), then unlocks. The hash reads only the VISIBLE `width` bytes
    /// of each row, so it is independent of plane padding. Returns nil on a lock failure / missing
    /// luma plane (the caller then simply does not suppress). Called only when suppression is enabled.
    /// SCROLL REPROJECTION: measure the dominant per-frame VERTICAL content shift between `prev` and
    /// `cur` (NV12 luma planes), returned as a signed NORMALIZED offset in ten-thousandths of the frame
    /// HEIGHT (×10000), PLUS the moving-content vertical band (`bandTop`/`bandBottom`, also in
    /// ten-thousandths of height) so the client warps only the editor body and the chrome stays put.
    /// `(0, 0, 0, 0)` when the planes differ in size, a lock fails, or the shift is not confident
    /// (typing / non-scroll); `bandTop == bandBottom == 0` ⇒ no band (whole-frame warp fallback). Both
    /// planes are locked read-only for the call only. `dx` is always `0` on the v1 host (vertical scroll
    /// only). frameQueue-confined.
    private static func measureScrollOffset(prev: CVPixelBuffer, cur: CVPixelBuffer)
        -> (dx: Int16, dy: Int16, bandTop: UInt16, bandBottom: UInt16)
    {
        let w = CVPixelBufferGetWidthOfPlane(cur, 0)
        let h = CVPixelBufferGetHeightOfPlane(cur, 0)
        guard w > 0, h > 0,
              CVPixelBufferGetWidthOfPlane(prev, 0) == w,
              CVPixelBufferGetHeightOfPlane(prev, 0) == h
        else { return (0, 0, 0, 0) }
        guard CVPixelBufferLockBaseAddress(prev, .readOnly) == kCVReturnSuccess else { return (0, 0, 0, 0) }
        defer { CVPixelBufferUnlockBaseAddress(prev, .readOnly) }
        guard CVPixelBufferLockBaseAddress(cur, .readOnly) == kCVReturnSuccess else { return (0, 0, 0, 0) }
        defer { CVPixelBufferUnlockBaseAddress(cur, .readOnly) }
        guard let pBase = CVPixelBufferGetBaseAddressOfPlane(prev, 0),
              let cBase = CVPixelBufferGetBaseAddressOfPlane(cur, 0)
        else { return (0, 0, 0, 0) }
        let pStride = CVPixelBufferGetBytesPerRowOfPlane(prev, 0)
        let cStride = CVPixelBufferGetBytesPerRowOfPlane(cur, 0)
        // Search up to a quarter-frame scroll per frame (covers a fast flick at 30 fps).
        let maxShift = max(8, h / 4)
        if Self.dbgGapEnabled {
            FileHandle.standardError.write(Data(
                "aislopdesk-videohostd[scroll]: measure w=\(w) h=\(h) pStride=\(pStride) cStride=\(cStride) maxShift=\(maxShift)\n"
                    .utf8,
            ))
        }
        let (shift, confMilli, bandTopRow, bandBottomRow) = ScrollShiftEstimator.estimateNV12(
            prevY: pBase, prevStride: pStride, curY: cBase, curStride: cStride,
            width: w, height: h, maxShift: maxShift, quantizeShift: Self.scrollQuantizeShift,
        )
        if Self.dbgGapEnabled {
            FileHandle.standardError
                .write(Data(
                    "aislopdesk-videohostd[scroll]: shift=\(shift) conf=\(confMilli) band=\(bandTopRow)..\(bandBottomRow)\n"
                        .utf8,
                ))
        }
        guard confMilli >= 500, shift != 0 else { return (0, 0, 0, 0) }
        let normMilli = (Double(shift) / Double(h) * 10000.0).rounded()
        let dy = Int16(max(-32767.0, min(32767.0, normMilli)))
        // Normalize the moving-content band (current-frame rows, INCLUSIVE) → ten-thousandths of the
        // frame height. The shader applies the reproject offset only inside [bandTop, bandBottom) and
        // clamps the sample to it, so the static chrome above/below never slides. `-1` rows ⇒ no band
        // (0, 0) ⇒ the client falls back to a whole-frame warp.
        let (bandTop, bandBottom): (UInt16, UInt16)
        if bandTopRow >= 0, bandBottomRow >= bandTopRow {
            let top = (Double(bandTopRow) / Double(h) * 10000.0).rounded()
            let bottom = (Double(Int(bandBottomRow) + 1) / Double(h) * 10000.0).rounded()
            bandTop = UInt16(max(0.0, min(10000.0, top)))
            bandBottom = UInt16(max(0.0, min(10000.0, bottom)))
        } else {
            bandTop = 0
            bandBottom = 0
        }
        return (0, dy, bandTop, bandBottom)
    }

    /// ADAPTIVE-QP: compute the per-frame `MaxAllowedFrameQP` ceiling from the change magnitude between
    /// `prev` and `cur` (NV12 luma planes) via the NEON per-row hash + the pure core curve. `nil` when
    /// the planes differ in size or a lock fails (caller then leaves the configured ceiling). Both
    /// planes are locked read-only for the call only. frameQueue-confined.
    private static func measureAdaptiveQP(prev: CVPixelBuffer, cur: CVPixelBuffer)
        -> (qp: Int, changeMilli: UInt32)?
    {
        let w = CVPixelBufferGetWidthOfPlane(cur, 0)
        let h = CVPixelBufferGetHeightOfPlane(cur, 0)
        guard w > 0, h > 0,
              CVPixelBufferGetWidthOfPlane(prev, 0) == w,
              CVPixelBufferGetHeightOfPlane(prev, 0) == h
        else { return nil }
        guard CVPixelBufferLockBaseAddress(prev, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(prev, .readOnly) }
        guard CVPixelBufferLockBaseAddress(cur, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(cur, .readOnly) }
        guard let pBase = CVPixelBufferGetBaseAddressOfPlane(prev, 0),
              let cBase = CVPixelBufferGetBaseAddressOfPlane(cur, 0)
        else { return nil }
        let (qp, changeMilli) = AdaptiveFrameQP.computeNV12(
            prevY: pBase, prevStride: CVPixelBufferGetBytesPerRowOfPlane(prev, 0),
            curY: cBase, curStride: CVPixelBufferGetBytesPerRowOfPlane(cur, 0),
            width: w, height: h,
            qpSharp: UInt8(clamping: adaptiveQPSharp), qpMax: UInt8(clamping: adaptiveQPMax),
            bLoMilli: adaptiveQPBLoMilli, bHiMilli: adaptiveQPBHiMilli,
        )
        return (Int(qp), changeMilli)
    }

    private static func hashFrame(_ pixelBuffer: CVPixelBuffer) -> UInt64? {
        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        // Luma plane (plane 0): the visible width/height come from the plane, not the buffer, so a
        // padded plane still hashes only its visible region.
        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return nil }
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        // Chroma plane (plane 1, interleaved CbCr) when present (NV12 has 2 planes); luma-only else.
        let cbcr: UnsafeRawPointer?
        let cbcrStride: Int
        if CVPixelBufferGetPlaneCount(pixelBuffer) > 1,
           let cbcrBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)
        {
            cbcr = UnsafeRawPointer(cbcrBase)
            cbcrStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
        } else {
            cbcr = nil
            cbcrStride = 0
        }
        return FrameHasher.hashNV12(
            y: UnsafeRawPointer(yBase),
            yStride: yStride,
            width: width,
            height: height,
            cbcr: cbcr,
            cbcrStride: cbcrStride,
        )
    }
}
#endif
