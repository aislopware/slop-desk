#if os(macOS)
import CoreMedia
import CoreVideo
import CSlopDeskFFI
import Foundation
import OSLog
import SlopDeskVideoProtocol

/// The frame-decision pipeline behind one captured window: what to do with each frame the capture
/// stream delivers, and when to synthesise one it did not.
///
/// The capture stream ITSELF — the content filter, the configuration, the framework lifecycle, the
/// read of what each delivered sample buffer is — lives in `slopdesk-apple-sck` behind
/// `slopdesk_capture_*`, and every rule those calls are made under (the delivery ceiling, the
/// surface depth, which filter a parked window wants, whether a resize may happen in place) lives
/// in `slopdesk_video::capture_config`. What is left here is the part that is genuinely about
/// SlopDesk rather than about the framework: the backlog pacer, the adaptive quantiser
/// measurement, the scroll reprojection, the static-IDR timer and the cadence gate.
///
/// ⚠️ **HANG-SAFETY:** a capture stream cannot start without a window-server + Screen-Recording TCC
/// session (docs/research/spikes/vtbench/RESULTS.md). ``start(windowID:pixelWidth:pixelHeight:region:)``
/// is NEVER called from a test or a headless context — only from a real GUI host app with the grant.
///
/// - Idle-skip: a frame the framework marks anything but complete carries no new pixels and never
///   reaches this type at all (doc 17 §3.5). >90% of coding frames are static.
/// - Heartbeat IDR (``heartbeatIDRInterval``) so a reconnecting / loss-recovering client catches a frame.
public final class WindowCapturer: NSObject, @unchecked Sendable {
    /// Heartbeat IDR cadence (seconds): periodic forced keyframe so a late-joining / loss-recovering
    /// client gets a decode anchor. 2.5 s rather than 1 s — on a never-idle window every heartbeat is a
    /// 50-135 KB IDR burst (the crisp path never fires there), so a tight cadence risks burst loss for
    /// ZERO benefit to an in-sync client; 2.5 s drops most periodic bursts while keeping a prompt
    /// insurance anchor (DETECTED loss recovers via the recovery channel, not this heartbeat). Env
    /// `SLOPDESK_HEARTBEAT_S`, clamped [0.25, 60].
    public static let heartbeatIDRInterval: TimeInterval = slopdesk_capture_heartbeat_seconds()

    /// Force a periodic heartbeat IDR on the LIVE (active-motion) path. DEFAULT OFF, because on a
    /// never-idle window that heartbeat is a 50-135 KB IDR through `encodeCompactKeyframe`, whose two
    /// synchronous `VTCompressionSessionCompleteFrames` calls BLOCK the capture queue ~15 ms → a dropped
    /// capture plus a big frame every `heartbeatIDRInterval` (2.5 s) = a PERIODIC cadence hitch through a
    /// long scroll. It buys an in-sync client nothing: DETECTED loss recovers via the recovery channel
    /// (requestIDR), not this heartbeat; the STATIC-window timer (`onIDRTimerTick`) re-anchors with a
    /// crisp IDR the instant motion pauses; and a late-joining / decode-failed client requests an IDR
    /// itself. Suppressing it therefore costs no resilience on a low-loss link.
    /// `SLOPDESK_MOTION_HEARTBEAT=1` restores the periodic motion IDR (for a genuinely lossy WAN).
    static var motionHeartbeatEnabled: Bool { gates.motion_heartbeat }

    /// The whole `SLOPDESK_*` operating point of this file, resolved ONCE through
    /// ``CaptureGateTable`` — every default, every clamp and all three conjunctions are
    /// `slopdesk_video::capture_gates`'.
    ///
    /// Each gate below is a one-line read of a field. The prose stays because the prose is the
    /// hardware measurement that chose the value, which no table can hold; what left is the parsing,
    /// which was twenty-eight hand-written copies of four idioms. Twenty-five of them read
    /// `ProcessInfo` directly and so were unreachable from `video-prefs.json` — they go through
    /// ``EnvConfig`` now, which is the only way a setting can reach them at all (`docs/58`).
    private static let gates = CaptureGateTable.resolve(
        maxAllowedFrameQP: Int32(clamping: VideoEncoder.maxAllowedFrameQP),
        encodeEWMAAlpha: EncodeLoadPacer.alpha,
    )

    /// APP-AUDIO master gate (`SLOPDESK_AUDIO`, default ON; `=0` masters the feature off). Gates the
    /// capture audio-tap CONFIGURATION (the sample rate in the start description, which is what
    /// adds the second audio output) here,
    /// and the whole encode→send lane session-side. The per-session client toggle (`audioControl`)
    /// deliberately never touches the stream config — an `updateConfiguration` mid-stream costs a
    /// visible capture hitch — so OFF just drops `.audio` buffers at the delegate
    /// (``setAudioForwardingEnabled(_:)``).
    static var audioCaptureEnabled: Bool { gates.audio_capture }

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
    /// `ltrRefresh` is true ONLY on the LIVE path when the host chose a cheap LTR-refresh
    /// recovery (``VideoEncoder/encodeLiveLTRRefresh(pixelBuffer:presentationTime:)``) — a small
    /// P-frame against an ACKNOWLEDGED long-term reference, NOT a keyframe. It is mutually exclusive
    /// with `forceKeyframe`/`crisp`/`compact` (a keyframe is a superset recovery and wins) and is never
    /// set on the static-timer path (which re-anchors with a crisp/compact IDR instead). Always false
    /// when `SLOPDESK_LTR` is off ⇒ byte-identical handler behaviour.
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
    /// (``VideoEncoder/encodeLiveCrispKeyframe``). Default on; `SLOPDESK_CRISP=0` A/Bs it back to a
    /// plain (live-QP) heartbeat IDR with no encoder rebuild. Read once (static-screen behaviour
    /// only; HW-verified path, not unit-tested).
    private static var crispWhenStatic: Bool { gates.crisp_when_static }

    /// STATIC-FRAME SUPPRESSION (default OFF). When enabled, each `.complete` frame's locked NV12
    /// planes are hashed (the native ``FrameHasher/hashNV12(y:yStride:width:height:cbcr:cbcrStride:)``
    /// NEON kernel) and compared to the last submitted frame's hash; a pixel-identical re-delivery with
    /// no forced obligation pending is DROPPED before the encoder (HEVC + SCK idle-skip handle most
    /// static content — this catches the residual byte-identical `.complete` re-deliveries). OFF ⇒ no
    /// hash, no behaviour change. Needs a real GUI + TCC session to exercise (the SCStream path hangs
    /// headlessly); only the pure decider + hash kernel are unit-tested. `SLOPDESK_STATIC_SUPPRESS=1`.
    private static var staticSuppressEnabled: Bool { gates.static_suppress }

    /// EVENT-DRIVEN CRISP RE-ANCHOR (default OFF). When enabled, each
    /// `.complete` frame's NV12 planes are hashed (NEON) and `stillCrispThreshold` consecutive byte-
    /// identical frames trigger the crisp re-anchor IMMEDIATELY (``StillnessCrispDecider``) instead of
    /// waiting the ~300ms wall-clock quiet window — re-sharpen lands ~1-2 frames after motion stops WHEN
    /// SCK re-delivers the static frame (else the StaticIDRDecider quiet-window timer is the fallback).
    /// OFF because it adds a per-`.complete`-frame hash on the userInteractive capture queue and P1 input
    /// latency must not pay unmeasured hot-path work — flip ON only after a HW A/B confirms the hash cost
    /// is negligible. `SLOPDESK_STILL_CRISP=1` enables; `SLOPDESK_STILL_CRISP_FRAMES` overrides the
    /// threshold (default 2, clamp 1…30).
    private static var stillCrispEnabled: Bool { gates.still_crisp }
    private static var stillCrispThreshold: Int { Int(gates.still_crisp_threshold) }

    /// SCROLL REPROJECTION (default OFF). When enabled, each `.complete` frame's content scroll vs the
    /// PREVIOUS frame is MEASURED (NEON per-row hash + the pure shift estimator) and the offset is sent
    /// to the client, which warps the last frame by it between codec frames so editor scroll looks local
    /// (``ScrollReprojector``). DEFAULT OFF ⇒ no measurement, byte-identical. `SLOPDESK_SCROLL_REPROJECT=1`
    /// (set on BOTH host + client). Confidence-gated so typing / non-scroll motion never reprojects.
    private static var scrollReprojectEnabled: Bool { gates.scroll_reproject }

    /// SCROLL-SHIFT QUANTIZE (default 3). Right-shifts each luma byte by this many bits before the
    /// per-row hash, so real capture noise (resample / dither / ±LSB) cannot break the EXACT row match
    /// the estimator relies on. Without it `measureScrollOffset` returns 0 on every frame of real
    /// content; 3 tolerates ±3 of per-pixel noise. `0` demands an exact byte-for-byte row match.
    /// Clamped to 0...7. `SLOPDESK_SCROLL_QUANTIZE`.
    private static var scrollQuantizeShift: UInt8 { gates.scroll_quantize_shift }

    /// ADAPTIVE-QP (default OFF). When enabled, each `.complete` frame's CHANGE magnitude vs the
    /// previous frame (NEON per-row hash → changed-row fraction) drives the live frame's
    /// `MaxAllowedFrameQP` ceiling: a small change (caret move, few chars) is pinned to a LOW (sharp)
    /// ceiling RC cannot coarsen past — even under a tight WAN budget — while a burst rides up to the
    /// configured ceiling (graded blur). Generalizes the crisp-on-FULL-static refresh to the common
    /// "almost-static editing" case. DEFAULT OFF ⇒ no measurement, no behaviour change. Host-only, no wire.
    /// `SLOPDESK_ADAPTIVE_QP=1`; `SLOPDESK_AQP_SHARP` (sharp ceiling, default 22),
    /// `SLOPDESK_AQP_BLO_MILLI`/`_BHI_MILLI` (change-fraction band ×1000, default 20/300).
    /// Resolved through `EnvConfig` so a GUI setting can drive it; `boolDefaultOff` preserves the
    /// default-OFF (`== "1"`) idiom, and an EMPTY overlay reads exactly like a bare `ProcessInfo` lookup.
    private static var adaptiveQPEnabled: Bool { gates.adaptive_qp }
    private static var adaptiveQPSharp: Int { Int(gates.adaptive_qp_sharp) }

    /// The motion-end QP ceiling the adaptive law ramps UP to on a burst (the sharp end is
    /// ``adaptiveQPSharp``). Defaults to the static drop-avoidance ceiling
    /// (``VideoEncoder/maxAllowedFrameQP``, e.g. 51); `SLOPDESK_AQP_MAX` overrides so motion
    /// coarsening can be capped well below it (e.g. 36) — keeps a scroll frame readable while still
    /// shrinking it ~80 KB → ~15-25 KB. Under const-QP (motion-keyed band) this is the upper end of the
    /// `[floor, AQP_MAX]` range a scroll frame may coarsen into.
    ///
    /// The fifth `[1, 51]` knob of the shape `qp_knob` owns (`rust/slopdesk-video`, `capture_gates`),
    /// and it had the same hand-rolled reject its four siblings had: `SLOPDESK_AQP_MAX=0` asked for the sharpest
    /// motion cap there is and silently got the coarsest. It CLAMPS now, like the other four and
    /// like every other quantiser knob in the tree. Absent, empty and non-numeric are unchanged —
    /// they answer ``VideoEncoder/maxAllowedFrameQP``, which is what the door's own default returns
    /// for text that is not a number.
    private static var adaptiveQPMax: Int { Int(gates.adaptive_qp_max) }

    /// How fast the smoothed QP eases UP toward a coarser target on motion onset: the per-frame step is
    /// `(rawQP - smoothed) / N`. `N == 1` (default) ⇒ INSTANT — the QP jumps to the motion target on
    /// the very first scroll frame, so a quick push-scroll's burst-START frames are already coarse
    /// (small). A slow ease-up would leave the first ~6 frames sharp ⇒ ~80 KB each ⇒ a sluggish scroll.
    /// Re-sharpen on STOP is separate (see `adaptiveQPDownStep`). A larger `N`
    /// (`SLOPDESK_AQP_UP_RAMP=2/3`) trades responsiveness for less QP shimmer if the coarsen-snap
    /// ever looks abrupt. Clamped ≥ 1.
    private static var adaptiveQPUpRamp: Int { Int(gates.adaptive_qp_up_ramp) }

    /// How fast the smoothed QP eases DOWN toward the sharp floor when motion STOPS: at most this many
    /// QP per frame. A straight snap-to-floor (40→24 in one frame) re-encodes the whole settled
    /// viewport SHARP in a single ~80 KB frame — the scroll-STOP stutter. Stepping down by a few QP
    /// spreads that re-sharpen over a handful of small frames (no hitch) while still reaching full
    /// sharpness within ~60-80 ms (imperceptible). `SLOPDESK_AQP_DOWN_STEP` overrides; `≥ 51` (or a
    /// huge value) makes the snap-down instant again. Clamped ≥ 1.
    private static var adaptiveQPDownStep: Int { Int(gates.adaptive_qp_down_step) }

    private static var adaptiveQPBLoMilli: UInt32 { gates.adaptive_qp_band_lo_milli }

    private static var adaptiveQPBHiMilli: UInt32 { gates.adaptive_qp_band_hi_milli }

    /// TRUE IDLE-SKIP (default OFF). Parsec sends ZERO packets when the screen is static; on our
    /// VD/`displayIncluding` capture path SCK sometimes re-delivers byte-identical `.complete` frames it
    /// does NOT mark `.idle`, so without this they get re-encoded + re-sent — a wasteful drip Parsec never
    /// pays. When enabled, a frame the adaptive-QP NEON measurement reports as TRULY idle
    /// (`measured && changeMilli == 0`, every row-hash identical to the previous frame) carrying no pending
    /// obligation (keyframe / recovery / heartbeat — peeked, never drained) is dropped before the encode
    /// hand-off. CRITICAL: a skipped frame does NOT re-anchor `staticIDRDecider` (its quiet-window clock is
    /// deliberately allowed to go stale) so the ~300ms crisp refresh still fires on a genuinely-static
    /// window. Re-anchoring on every dropped duplicate — as `STATIC_SUPPRESS` does — keeps the quiet window
    /// from ever opening and the stream freezes. REUSES the adaptive-QP measurement, so it needs
    /// `SLOPDESK_ADAPTIVE_QP=1` too. OFF ⇒ `idleSkip` always false ⇒ no behaviour change.
    /// `SLOPDESK_IDLE_SKIP=1`. Resolved through `EnvConfig` so a GUI setting can drive it; `boolDefaultOff`
    /// preserves the default-OFF (`== "1"`) idiom, and an empty overlay reads like a bare `ProcessInfo` lookup.
    private static var idleSkipEnabled: Bool { gates.idle_skip }

    /// The resolved table at a STABLE address, so the four per-frame doors can borrow it rather
    /// than take it by value.
    ///
    /// Allocated once for the process's life and deliberately never freed: the alternative is
    /// `withUnsafePointer`, which copies a twenty-eight-field aggregate onto the stack for every
    /// question the capture callback asks — and it asks at 60 Hz.
    ///
    /// `nonisolated(unsafe)` because a pointer is not `Sendable` and this one is written exactly
    /// once, before the first frame, and only ever read afterwards — which is the same discipline
    /// every other resolved-once table in this file keeps, spelled out because the type cannot say
    /// it for itself.
    private nonisolated(unsafe) static let gatesRef: UnsafePointer<SlopDeskVideoCaptureGates> = {
        let box = UnsafeMutablePointer<SlopDeskVideoCaptureGates>.allocate(capacity: 1)
        box.initialize(to: gates)
        return UnsafePointer(box)
    }()

    /// SCROLL-FPS CAP (default OFF, `SLOPDESK_SCROLL_FPS`=N): during sustained FAST scroll (changed-row
    /// fraction ≥ `scrollMotionThresholdMilli`) encode only ~N of the 60 captured fps (even Bresenham
    /// decimation), so the HW encoder never overruns the 16.7 ms frame budget — the involuntary-VT-drop
    /// source at higher capture scales. Even pacing at a lower rate beats stuttery 60-with-random-drops.
    /// REQUIRES the change measurement (`SLOPDESK_ADAPTIVE_QP=1` or idle-skip). Only ordinary live
    /// frames decimate; a pending forced/recovery/heartbeat always passes. Slow scroll / caret (low
    /// `changeMilli`) NEVER triggers (no slow-scroll regression). No rebuild ⇒ no hitch. `0` ⇒ disabled.
    static var scrollFps: Int { Int(gates.scroll_fps) }

    /// Changed-row fraction (milli, 0–1000) at/above which a frame counts as FAST scroll for the
    /// scroll-fps cap. Default 120 (≈12% of rows changed) — well above caret/typing, around real scroll.
    static var scrollMotionThresholdMilli: UInt32 { gates.scroll_motion_threshold_milli }

    /// Consecutive fast-scroll frames required before decimation engages (debounce — a single flick
    /// frame is never dropped).
    static var scrollMotionSustainFrames: Int { Int(gates.scroll_motion_sustain_frames) }

    /// ENCODE DECOUPLING (DEFAULT ON; `SLOPDESK_ENCODE_OFFQUEUE=0` reverts to inline encode). The VT
    /// encode otherwise runs SYNCHRONOUSLY in the SCStream sample handler, so during heavy scroll a
    /// per-frame encode that spikes past the ~16ms budget makes the handler fall progressively behind →
    /// SCStream holds surfaces → capture gaps (the frame-smoothness judder). When ON, the handler
    /// instead COPIES the frame (~1ms) and hands the encode to a dedicated serial queue, then returns
    /// immediately → SCStream delivers at a steady 60Hz; encode runs in parallel, in PTS order. A
    /// bounded pending count drops ordinary deltas (never forced/recovery frames) if the encoder can't
    /// keep up — congestion-dropping at the encoder, not stalling capture (the P-chain stays intact, so
    /// no client decode break). This is Parsec's discipline: capture is never blocked on encode. Default
    /// ON is HW-validated on the 1080p60 desktop stream — the encode-overrun capture-gap band (60–100ms)
    /// dropped ~44% (113→64 events/scroll) and the client held a steadier ~60fps present cadence
    /// (pacer-hold windows n≈111–121 vs a ragged 46–108 inline). `SLOPDESK_ENCODE_QUEUE_MAX` overrides
    /// the pending bound (clamp 1…12).
    static var encodeOffQueueEnabled: Bool { gates.encode_off_queue }
    /// ENCODE-LOAD PACER (DEFAULT ON; `SLOPDESK_ENCODE_PACER=0` reverts to the ragged backlog drop).
    /// Requires the decoupled encode queue (it paces THAT queue's over-run). Measures encode
    /// wall-time and, when the HW encoder cannot sustain the base-fps budget on a CLEAN link (where
    /// the network ``FPSGovernor`` never engages), steps the effective fps down a clean divisor so the
    /// ``EncodeCadenceGate`` decimates metronome-regularly instead of dropping deltas raggedly — the
    /// compute-axis twin of the governor. See ``EncodeLoadPacer``.
    static var encodePacerEnabled: Bool { gates.encode_pacer }
    /// DIAGNOSTIC: force a compact recovery IDR every Nth live frame, so the loss-driven recovery-IDR
    /// storm reproduces deterministically on localhost (no real loss needed).
    /// `SLOPDESK_FORCE_COMPACT_EVERY=N`; 0/unset = off.
    static var forceCompactEvery: Int { Int(gates.force_compact_every) }

    private var forceCompactCounter = 0

    static var maxEncodePending: Int { Int(gates.max_encode_pending) }

    /// FRESHEST-WINS backlog (default OFF; `SLOPDESK_ENCODE_FRESHEST=1`). When the decoupled encode
    /// backlog is full, evict the OLDEST still-pending delta and encode the NEWEST instead of
    /// dropping the incoming one — so a fat scroll frame never strands fresher content and the client
    /// always gets the latest pixels (RE of Parsec: SCStream `setQueueDepth:4` + one-encode-per-frame
    /// = "capture is never blocked on encode", it keeps the newest). Freshness is a coding tool's
    /// north star. Requires the decoupled encode queue. Unset ⇒ the historical drop-newest path runs
    /// byte-identical. A/B lever for the one ragged-cadence source the audit confirmed in code
    /// (``handOffToEncoder`` backlog drop) — HW-verify with client-side framewatch before defaulting.
    static var freshestWins: Bool { gates.freshest_wins }

    // What the gate above decides, it decides in Rust: `slopdesk_video_capture_backlog_decision`
    // takes the forced-flag of each queued frame (oldest first) and the arriving frame's, and
    // answers one of `SLOPDESK_CAPTURE_BACKLOG_{ENQUEUE,DROP_INCOMING,EVICT_OLDEST}`. Default
    // (`freshestWins == false`) drops the INCOMING frame when full — the historical drop-newest
    // policy; freshest-wins evicts the stalest unforced pending one so the newest delta is admitted
    // and the stale one coalesces out. A forced incoming, or a backlog that is somehow ALL forced,
    // always enqueues: never drop a recovery anchor, never drop the fresh delta.

    /// SELF-HEAL cadence (Parsec-style ack-anchored healing — HW-validated in
    /// `slopdesk-loopback-validate --ack-ref` arms L/M/N/O): every `selfHealEvery`-th LIVE delta is
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
    /// the cadence into a surprise-IDR-every-K stream. `SLOPDESK_SELF_HEAL` overrides K (frames,
    /// clamp 2…120); `0` disables. Requires `SLOPDESK_LTR` (the session never arms eligibility
    /// otherwise — acks don't flow when LTR is off).
    ///
    /// K defaults to 30, not to a tight 6: self-heal protects in-MOTION frames, which a coding tool
    /// deliberately lets blur/drop and re-sharpen — so heal far less often (~+1.6% stream bytes at
    /// K=30 vs +8.2% at K=6). The static-window crisp re-anchor (~300ms, ``StaticIDRDecider``)
    /// covers the "stop and read" case faster anyway; a lost motion frame waits at most K frames
    /// (~1s @30fps) for the next refresh, which is acceptable while moving.
    static var selfHealEvery: Int { Int(gates.self_heal_every) }

    /// CLEAN-LINK SELF-HEAL LOSS-GATE. DEFAULT **OFF** (`SLOPDESK_SELF_HEAL_LOSS_GATE=1` enables). When
    /// on, the every-Kth self-heal ``VideoEncoder/encodeLiveLTRRefresh(pixelBuffer:presentationTime:)`` is
    /// SUPPRESSED while the folded loss EWMA is below ``selfHealLossGateThreshold`` — on a loss-0 link the
    /// periodic ~1.49× refresh is a present-doublet (~1–2×/s during sustained motion) that Parsec has no
    /// analog for, and self-heal there protects against a loss that isn't happening. It re-arms the instant
    /// loss appears: the frame counter keeps climbing while suppressed (the heal is skipped, not reset), so
    /// the FIRST frame that sees loss ≥ threshold heals immediately. OFF ⇒ the gate branch is never
    /// consulted ⇒ byte-identical (always heal at K, exactly as today). Mirrors the shipped kfDup
    /// clean-link loss-gate — the same universal loss-EWMA signal, gating the other
    /// periodic-overhead-on-a-clean-link mechanism.
    static var selfHealLossGate: Bool { gates.self_heal_loss_gate }
    /// The loss EWMA at/above which self-heal stays armed under ``selfHealLossGate`` — 0.5%, mirroring the
    /// session's `kfDupLossThreshold` (the adaptive-FEC ladder's lowest escalation boundary).
    static var selfHealLossGateThreshold: Double { gates.self_heal_loss_gate_threshold }

    /// PURE (unit-tested): should this live delta become a self-heal LTR refresh? Base cadence: the counter
    /// has reached K, healing is enabled (`healEvery > 0`), and client acks are flowing (`eligible`). The
    /// clean-link loss-gate (`lossGated`, default OFF) additionally SUPPRESSES the heal while `lossRate <
    /// threshold`; with the gate off the loss terms are ignored ⇒ the decision is exactly the pre-gate one.
    /// The caller keeps advancing the counter while suppressed, so re-arming on the first lossy frame is
    /// immediate (this returns true the moment `lossRate >= threshold` with the counter already past K).

    private let log = Logger(subsystem: "slopdesk.video.host", category: "WindowCapturer")
    private let frameQueue = DispatchQueue(label: "slopdesk.video.capture", qos: .userInteractive)
    /// Dedicated serial queue for the SCStream `.audio` output — NEVER `frameQueue`, so a slow
    /// synchronous video encode can't delay a ~10 ms audio buffer (and the audio path never
    /// touches frameQueue-owned state).
    private let audioQueue = DispatchQueue(label: "slopdesk.video.capture.audio", qos: .userInteractive)
    /// The live capture stream, or nil before ``start(windowID:pixelWidth:pixelHeight:region:)`` and
    /// after ``stop()``. Confined to the session-actor lifecycle paths (start / stop / resize).
    private var capture: OpaquePointer?
    /// This capturer, RETAINED across the C boundary for exactly as long as `capture` lives — the
    /// door's terms are that the context outlives the handle, and the callbacks run on the two
    /// queues below rather than on whatever released the last Swift reference.
    private var captureContext: UnsafeMutableRawPointer?
    private let frameHandler: FrameHandler

    /// APP-AUDIO forward gate + sink under one lock: the session actor toggles/installs off-queue
    /// (the enable flips mid-stream on a client `audioControl`), the `.audio` delegate arm reads
    /// both once per ~10 ms buffer — the `keyframeLock` latch discipline on a dedicated lock so
    /// audio delivery never contends with the per-frame video reads. Gate default FALSE: audio is
    /// per-session opt-in; a nil sink also drops (the capturer without a wired session lane).
    private let audioLock = NSLock()
    private var audioForwardingEnabled = false
    private var audioSampleHandler: (@Sendable (CMSampleBuffer) -> Void)?

    /// APP-AUDIO sink: called on the dedicated audio queue with each captured `.audio`
    /// `CMSampleBuffer` while forwarding is enabled (nil ⇒ drop). The session wires this at
    /// capturer install time (like `onScrollOffset`) to its encode→send lane; lock-guarded
    /// because the `.audio` output delivers on its own queue.
    var onAudioSampleBuffer: (@Sendable (CMSampleBuffer) -> Void)? {
        get { audioLock.withLock { audioSampleHandler } }
        set { audioLock.withLock { audioSampleHandler = newValue } }
    }

    /// CHEAP per-session audio gate (the client's `audioControl` wish). Disabled drops `.audio`
    /// buffers BEFORE any extract/encode work; the SCStream config (`capturesAudio`) is never
    /// touched, so toggling costs no `updateConfiguration` restart/hitch. Thread-safe.
    public func setAudioForwardingEnabled(_ enabled: Bool) {
        audioLock.withLock { audioForwardingEnabled = enabled }
    }

    /// Moves a single-owner `CVPixelBuffer` copy across the encode-queue hop. `CVPixelBuffer` is not
    /// `Sendable`; the copy has exactly one owner (just allocated), so the transfer is safe.
    private struct SendableBuffer: @unchecked Sendable { let value: CVPixelBuffer }

    /// ENCODE DECOUPLING (gated): a dedicated SERIAL queue the encode runs on when
    /// `encodeOffQueueEnabled`, so the capture handler returns immediately (no synchronous encode
    /// blocking SCStream delivery). nil ⇒ inline encode on the capture queue. `userInteractive`
    /// to match the capture queue's priority.
    private lazy var encodeQueue: DispatchQueue? =
        Self.encodeOffQueueEnabled ? DispatchQueue(label: "com.slopdesk.encode", qos: .userInteractive) : nil
    /// Frames dispatched to `encodeQueue` but not yet encoded (lock-guarded — incremented on the
    /// capture queue, decremented on the encode queue). Caps the encode backlog.
    private let encodePendingLock = NSLock()
    private var encodePending = 0
    private var encodeBacklogDropped = 0

    /// A frame copied for the serial encode queue. Used ONLY on the ``Self/freshestWins`` path, where
    /// the backlog is an explicit deque (so the OLDEST pending delta can be evicted) instead of the
    /// default fire-and-forget `encodeQueue.async` + integer counter. Guarded by `encodePendingLock`.
    private struct PendingEncode {
        let buffer: SendableBuffer
        let pts: CMTime
        let forceKeyframe: Bool
        let crisp: Bool
        let compact: Bool
        let ltrRefresh: Bool
        let perFrameMaxQP: Int?
        let pacerAnchor: Bool
        var forced: Bool { forceKeyframe || crisp || compact || ltrRefresh }
    }

    /// Freshest-wins backlog (oldest first). Invariant: the count of scheduled `drainOnePending`
    /// blocks in flight == `pendingEncodes.count`, so an evict-without-schedule is still consumed by
    /// an already-scheduled drain. Guarded by `encodePendingLock`; drained on the serial `encodeQueue`.
    private var pendingEncodes: [PendingEncode] = []

    /// ENCODE-LOAD PACER (``EncodeLoadPacer``, gated on ``encodePacerEnabled``). Mutated ONLY on the
    /// serial `encodeQueue` (single-threaded — no lock on the struct itself); its selected fps is
    /// PUBLISHED to `encodePacedFPS` under `pacerLock` so the frameQueue's `currentGovernedFPS()` can
    /// read it without touching the struct. `encodePacedFPS` starts at the base fps (inert).
    private var encodeLoadPacer: EncodeLoadPacer
    private let pacerLock = NSLock()
    private var encodePacedFPS: Int
    /// ENCODE-WALL EWMA (the stats HUD's host encode axis, wire type 27): folded on the serial
    /// `encodeQueue` after every hand-off, published under `pacerLock` so the session actor can
    /// read it from the ~500 ms `hostStats` sender. Unlike the pacer's load EWMA this one is
    /// ALWAYS measured (two clock reads per frame — noise next to a multi-ms encode) and folds
    /// anchors too: the HUD reports what encode actually costs, spikes included. `0` = none yet.
    private var encodeMsEWMAShared: Double = 0
    /// Last paced fps we logged a transition for (frameQueue/encodeQueue diagnostic dedup).
    private var lastLoggedPacedFPS: Int

    /// Hand a frame to the encoder — inline on the capture queue, or, when `encodeOffQueueEnabled`,
    /// COPIED and dispatched to the serial `encodeQueue` so capture delivery is never blocked by encode time.
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
        if Self.freshestWins {
            // Copy OUTSIDE the backlog lock (heavy memcpy); the copy is a fresh single-owner buffer.
            guard let copy = Self.copyPixelBuffer(buffer) else { return }
            enqueueFreshest(
                PendingEncode(
                    buffer: SendableBuffer(value: copy),
                    pts: pts,
                    forceKeyframe: forceKeyframe,
                    crisp: crisp,
                    compact: compact,
                    ltrRefresh: ltrRefresh,
                    perFrameMaxQP: perFrameMaxQP,
                    pacerAnchor: forceKeyframe || crisp,
                ),
                encodeQueue: encodeQueue,
            )
            return
        }
        encodePendingLock.lock()
        if !forced, encodePending >= Self.maxEncodePending {
            encodePendingLock.unlock()
            encodeBacklogDropped += 1
            if encodeBacklogDropped.isMultiple(of: 600) {
                let dropped = encodeBacklogDropped
                log.notice("encode-offqueue: \(dropped) deltas dropped (encoder backlog full)")
            }
            // SLOPDESK_VIDEO_DEBUG: a saturated backlog means encode over-ran the 60fps inter-arrival
            // (16.7ms) and this delta is being dropped — the RAGGED-cadence source of the client's
            // 100–140ms present hitches. Throttled so a heavy-scroll burst is visible without flooding.
            if Self.dbgGapEnabled, encodeBacklogDropped.isMultiple(of: 15) {
                FileHandle.standardError
                    .write(Data("slopdesk-videohostd[drop]: backlog-full delta drop #\(encodeBacklogDropped)\n"
                            .utf8))
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
        // Big episodic IDRs (keyframe / crisp) are 5–10× encode-time outliers — excluded from the
        // pacer's load EWMA (as the governor excludes them from its bytes EWMA); compact + LTR
        // refreshes are near steady-state and ARE folded.
        let pacerAnchor = forceKeyframe || crisp
        encodeQueue.async { [weak self] in
            // Measure the encode+packetize+send wall-time. Past the 60fps budget (16.7ms) it fills
            // the backlog and forces the ragged [drop] above — the pacer folds it to step the rate
            // down cleanly instead. [enc] + [drop] localize a hitch to encoder over-run under DEBUG.
            let encStart = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
            handler(boxed.value, pts, forceKeyframe, crisp, compact, ltrRefresh, perFrameMaxQP)
            guard let self else { return }
            let ms = (Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) - encStart) / 1_000_000.0
            noteEncodeWall(milliseconds: ms, pacerAnchor: pacerAnchor)
            encodePendingLock.lock()
            encodePending -= 1
            encodePendingLock.unlock()
        }
    }

    /// Post-encode wall-time bookkeeping shared by both hand-off paths (default async block +
    /// freshest-wins drain), on the serial `encodeQueue`: fold the ALWAYS-ON stats-HUD EWMA,
    /// then the flag-gated pacer fold + DEBUG prints exactly as before.
    private func noteEncodeWall(milliseconds ms: Double, pacerAnchor: Bool) {
        pacerLock.lock()
        encodeMsEWMAShared = slopdesk_video_capture_fold_encode_ewma(
            encodeMsEWMAShared, ms, EncodeLoadPacer.alpha,
        )
        pacerLock.unlock()
        // ENCODE-LOAD PACER: the struct is confined to THIS serial queue; only its output fps
        // crosses to the frameQueue (published under `pacerLock`).
        if Self.encodePacerEnabled {
            let paced = encodeLoadPacer.note(encodeMs: ms, isAnchor: pacerAnchor)
            pacerLock.lock()
            encodePacedFPS = paced
            pacerLock.unlock()
            if Self.dbgGapEnabled, paced != lastLoggedPacedFPS {
                let msg = "slopdesk-videohostd[pace]: \(Int(ms))ms ⇒ fps \(lastLoggedPacedFPS)→\(paced)\n"
                FileHandle.standardError.write(Data(msg.utf8))
                lastLoggedPacedFPS = paced
            }
        }
        if Self.dbgGapEnabled, ms > 16.7 {
            FileHandle.standardError
                .write(Data("slopdesk-videohostd[enc]: encode \(Int(ms))ms\(pacerAnchor ? " ANCHOR" : "")\n"
                        .utf8))
        }
    }

    /// The current encode-wall EWMA in milliseconds (`0` = nothing encoded yet). Lock-guarded,
    /// callable from any thread — the session actor's `hostStats` sender reads it.
    public func encodeMillisEWMA() -> Double {
        pacerLock.lock()
        defer { pacerLock.unlock() }
        return encodeMsEWMAShared
    }

    /// FRESHEST-WINS encode hand-off (``Self/freshestWins``): keep an explicit backlog deque so the
    /// OLDEST pending delta can be coalesced out when the encoder over-runs — the client always gets
    /// the newest pixels (Parsec keeps the newest via its depth-4 capture ring), never a ragged
    /// drop-newest gap. Forced frames are never evicted and may overflow the cap (recovery/sharpness
    /// anchors). The caller has already copied the buffer (outside any lock).
    private func enqueueFreshest(_ entry: PendingEncode, encodeQueue: DispatchQueue) {
        var schedule = false
        var evicted = false
        encodePendingLock.lock()
        var evictIndex = 0
        let forcedFlags = pendingEncodes.map { $0.forced ? UInt8(1) : UInt8(0) }
        let verdict = forcedFlags.withUnsafeBufferPointer { flags in
            slopdesk_video_capture_backlog_decision(
                Self.gatesRef, flags.baseAddress, flags.count, entry.forced, &evictIndex,
            )
        }
        switch verdict {
        case UInt8(SLOPDESK_CAPTURE_BACKLOG_EVICT_OLDEST):
            // Coalesce out the stalest pending delta, admit the newest — DO NOT schedule a new drain:
            // an already-scheduled block consumes the newest (blocks-in-flight == count invariant).
            pendingEncodes.remove(at: evictIndex)
            pendingEncodes.append(entry)
            encodeBacklogDropped += 1
            evicted = true
        case UInt8(SLOPDESK_CAPTURE_BACKLOG_DROP_INCOMING):
            // Unreachable on this path — it runs only under `freshestWins` — but the counter is the
            // one thing a drop still owes, so honour it rather than silently losing the frame.
            encodeBacklogDropped += 1
        default:
            pendingEncodes.append(entry)
            schedule = true
        }
        encodePendingLock.unlock()
        if Self.dbgGapEnabled, evicted, encodeBacklogDropped.isMultiple(of: 15) {
            FileHandle.standardError
                .write(Data("slopdesk-videohostd[coalesce]: freshest-wins evict #\(encodeBacklogDropped)\n".utf8))
        }
        if schedule { encodeQueue.async { [weak self] in self?.drainOnePending() } }
    }

    /// Encode exactly one frame from the freshest-wins deque (oldest first), on the serial
    /// `encodeQueue`. Mirrors the default async block's measure/pacer bookkeeping (``EncodeLoadPacer``
    /// stays confined to this queue). A defensive empty-deque guard makes a spurious drain a no-op.
    private func drainOnePending() {
        encodePendingLock.lock()
        guard !pendingEncodes.isEmpty else {
            encodePendingLock.unlock()
            return
        }
        let e = pendingEncodes.removeFirst()
        encodePendingLock.unlock()

        let encStart = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
        frameHandler(e.buffer.value, e.pts, e.forceKeyframe, e.crisp, e.compact, e.ltrRefresh, e.perFrameMaxQP)
        let ms = (Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) - encStart) / 1_000_000.0
        noteEncodeWall(milliseconds: ms, pacerAnchor: e.pacerAnchor)
    }

    /// Last time we forced a heartbeat IDR (uptime seconds).
    private var lastHeartbeat: TimeInterval = 0
    private var hasEmittedFirstFrame = false
    /// Uptime seconds of the last EMITTED keyframe (any reason) — drives the recovery-IDR cooldown.
    /// frameQueue-owned (set on both the live path and the timer path, both on frameQueue).
    private var lastKeyframeEmit: TimeInterval = 0
    /// Minimum spacing (seconds) between RECOVERY-driven (latch) IDRs, to collapse a self-sustaining
    /// recovery-IDR storm (each big IDR is a UDP burst → loss → another recovery request → another IDR).
    /// A latch-only force within this window of the last emitted keyframe ships a P-frame instead: the
    /// recent keyframe already re-anchored the client, and the client's 2·RTT escalation re-requests
    /// later (OUTSIDE the window) if that one was also lost — so recovery is de-bursted, never dropped.
    /// NEVER gates the first-frame or heartbeat IDR. 0 disables. Env `SLOPDESK_MIN_IDR_MS`.
    ///
    /// With `SLOPDESK_RECOVERY_IDR_V2` ON (the default) this SENT-keyed gate is INERT (0): the session
    /// actor's ``RecoveryIDRPolicy`` (delivery-keyed + casualty bypass + token bucket) is then the single
    /// admission authority, and it suppresses BEFORE latching, so a granted latch is never dropped here
    /// (the forced-frame invariant). `SLOPDESK_RECOVERY_IDR_V2=0` falls back to the 500 ms sent-keyed
    /// spacing. An EXPLICIT `SLOPDESK_MIN_IDR_MS` always wins — even with V2 on (a valid
    /// belt-and-suspenders double-gating A/B configuration).
    private static var minRecoveryIDRInterval: TimeInterval { gates.min_recovery_idr_interval }

    /// Latched when the client requests a forced IDR (loss recovery, doc 17 §3.6). The
    /// next delivered frame forces a keyframe and clears it. Guarded because the
    /// orchestrator actor sets it off the capture queue. Plain `os_unfair_lock`-free:
    /// an `NSLock` is enough here (set rarely, read once per frame).
    private let keyframeLock = NSLock()
    private var pendingForcedKeyframe = false
    /// Latched when the host chose an LTR-refresh recovery (``SlopDeskVideoHostSession`` `.refreshLTR`
    /// → ``requestLTRRefresh()``) instead of a forced IDR. The next LIVE frame encodes a cheap
    /// ForceLTRRefresh P-frame and clears it; on a STATIC window the timer drains it and re-anchors
    /// with a crisp/compact IDR instead (an LTR refresh has no live delta to ride). Distinct from
    /// `pendingForcedKeyframe` so an LTR refresh never forces a keyframe (it is the cheap alternative).
    /// Under the same `keyframeLock`. Never set when `SLOPDESK_LTR` is off (the actor folds .refreshLTR to
    /// requestKeyframe()) ⇒ always-false drain ⇒ byte-identical.
    private var pendingLTRRefresh = false
    /// SELF-HEAL eligibility — armed by the session actor while client LTR acks are flowing
    /// (``setSelfHealEligible(_:)``), disarmed on every encoder rebuild (fresh VT session = zero
    /// acked LTRs; a cadence refresh would then be VT's IDR fallback every K frames). Under
    /// `keyframeLock` (set rarely off-queue, read once per frame — same discipline as the latches).
    private var selfHealEligible = false
    /// SELF-HEAL loss-gate snapshot — the session actor pushes the freshly-folded loss EWMA here on every
    /// netstats report (``setSelfHealLossRate(_:)``, ~20/s). Under `keyframeLock` (read once per frame —
    /// the `selfHealEligible` discipline). Defaults HIGH (∞) so that before any report — or when no client
    /// feedback flows at all — the gate NEVER suppresses healing (fail-safe: heal when loss is unmeasured).
    /// Only consulted when ``selfHealLossGate`` is on.
    private var selfHealLossRate = Double.infinity
    /// CLIENT-SILENCE PAUSE (``setClientSilencePaused(_:)``): when the client's feedback has gone
    /// silent past ``SlopDeskVideoHostSession/clientSilencePauseSeconds`` the session sets this true so
    /// ordinary frames are SKIPPED (no encode, no send) — the host stops blasting to a peer that is not
    /// listening. Under `keyframeLock` (set on the 1 s heartbeat / cleared on the next inbound, read
    /// once per frame — same discipline as the self-heal state). Default false ⇒ never pauses.
    private var clientSilencePaused = false
    /// FPS-GOVERNOR: the governed encode fps the session actor latches via ``setGovernedFPS(_:)``.
    /// Equals `fps` (ungoverned, gate inert) until the governor steps. Under `keyframeLock` (set rarely
    /// off-queue, read once per frame — the `setSelfHealEligible` discipline). SCStream delivery stays at
    /// the FULL capture rate either way: the governor actuates at the capture→encode hand-off
    /// (``EncodeCadenceGate``), NEVER by reconfiguring `minimumFrameInterval` — lowering the capture
    /// ceiling to the governed rate reintroduces exactly the slot-beat quantization the 2× capture
    /// ceiling exists to avoid (see `resolveCaptureHz`).
    private var governedFPS: Int
    /// FPS-GOVERNOR: the schedule-anchored regular-cadence admit gate. frameQueue-owned (only
    /// touched in the SCStream callback).
    private var cadenceGate = EncodeCadenceGate()
    /// GATED-TAIL FLUSH: one-shot encode of the cached latest frame at the gate's next slot
    /// boundary, armed when a delivery is REJECTED by the cadence gate. Without it the LAST frame
    /// of a motion burst that lands on a gated slot waits for the ~1-1.25 s static crisp refresh
    /// — a visible stale tail at scroll end. frameQueue-owned (armed in the SCStream
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
    /// CAPTURE-DEATH one-shot latches (frameQueue-owned). `captureFailed`: `didStopWithError` was
    /// already handled — a duplicate delegate fire is a no-op (once-only `onCaptureFailed`).
    /// `captureStopped`: a deliberate ``stop()`` already quiesced this capturer — a failure racing
    /// (or trailing) it must NOT fire `onCaptureFailed` into a session that tore this capturer
    /// down on purpose (bye teardown / resize supersede), which would double-teardown.
    private var captureFailed = false
    private var captureStopped = false

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
    /// CAPTURE-DEATH callback: invoked exactly ONCE, on `frameQueue`, after the SCStream stopped
    /// ITSELF with an error (`didStopWithError` — shared window/app closed, display unplugged,
    /// Screen-Recording TCC revoked, WindowServer/GPU reset) and this capturer's synthetic-frame
    /// machinery has been quiesced (IDR timer cancelled, cached frame dropped). Without it the IDR
    /// timer would re-encode the LAST cached frame as heartbeat/crisp IDRs forever — the client
    /// "decodes video" (a frozen frame), the host heartbeat keeps its stall scrim disarmed, and the
    /// pane freezes permanently and silently. The session wires this (like `onScrollOffset`, at
    /// install time, BEFORE `start()`) to a `bye` + session teardown. NEVER invoked after a
    /// deliberate ``stop()`` (see `captureStopped`). `nil` ⇒ quiesce only.
    var onCaptureFailed: (@Sendable () -> Void)?
    /// True while the last sent scroll offset was non-zero — so exactly one `(0,0)` is emitted when
    /// scroll stops (arming the client reprojector's decay) instead of spamming it on every static frame.
    private var lastScrollWasNonZero = false
    /// ADAPTIVE-QP (gated on `adaptiveQPEnabled`): the per-frame QP ceiling computed from this frame's
    /// change magnitude, staged here and read at the live encode hand-off. frameQueue-owned.
    private var pendingAdaptiveQP: Int?
    /// Asymmetric-EMA'd adaptive QP ceiling — snaps DOWN to a sharper ceiling instantly, eases UP to a
    /// blurrier one over ~3 frames (avoids QP shimmer on borderline activity). frameQueue-owned.
    private var adaptiveQPSmoothed: Int?
    /// Capture-gap diagnostics (`SLOPDESK_VIDEO_DEBUG`): last DELIVERED-frame time, frameQueue-owned.
    static var dbgGapEnabled: Bool { gates.debug_gaps }
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

    /// Sets the CLIENT-SILENCE pause state (``clientSilencePaused``). Thread-safe; the session calls
    /// this from its 1 s heartbeat (true after the silence threshold) and from the inbound path (false
    /// on the next client datagram — instant resume). frameQueue reads it via ``isClientSilencePaused()``
    /// once per frame.
    public func setClientSilencePaused(_ paused: Bool) {
        keyframeLock.lock()
        clientSilencePaused = paused
        keyframeLock.unlock()
    }

    /// PEEK the CLIENT-SILENCE pause flag (frameQueue read, `keyframeLock`-guarded). See
    /// ``setClientSilencePaused(_:)``.
    private func isClientSilencePaused() -> Bool {
        keyframeLock.lock()
        defer { keyframeLock.unlock() }
        return clientSilencePaused
    }

    /// Requests a cheap LTR refresh on the next captured frame (host `.refreshLTR` recovery
    /// decision when the ACKED-ONLY gate holds). Thread-safe; called from the orchestrator actor.
    public func requestLTRRefresh() {
        keyframeLock.lock()
        pendingLTRRefresh = true
        keyframeLock.unlock()
    }

    /// SELF-HEAL gate. The session actor arms this when a client LTR ack folds (acks are flowing ⇒
    /// VT holds an acknowledged LTR ⇒ a cadence `ForceLTRRefresh` is a small loss-immune P-frame)
    /// and disarms it whenever a fresh encoder is installed (``SlopDeskVideoHostSession`` resets the
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

    /// SELF-HEAL loss-gate feed. The session actor pushes the freshly-folded loss EWMA every netstats
    /// report (~20/s) so the clean-link gate (``selfHealLossGate``) can suppress the periodic refresh
    /// doublet while the link is loss-free and re-arm it the instant loss appears. Thread-safe. Behaviorally
    /// inert unless ``selfHealLossGate`` is on (the per-frame read is skipped otherwise).
    public func setSelfHealLossRate(_ lossRate: Double) {
        keyframeLock.lock()
        selfHealLossRate = lossRate
        keyframeLock.unlock()
    }

    private func currentSelfHealLossRate() -> Double {
        keyframeLock.lock()
        defer { keyframeLock.unlock() }
        return selfHealLossRate
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
        let governed = governedFPS
        keyframeLock.unlock()
        guard Self.encodePacerEnabled else { return governed }
        // The two axes compose: the effective rate is the MORE restrictive of the network governor
        // and the encode-load pacer, so a clean-link encoder over-run and a congested-link byte
        // over-run each cap the rate without fighting. Sequential locks (never nested).
        pacerLock.lock()
        let paced = encodePacedFPS
        pacerLock.unlock()
        return min(governed, paced)
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

    /// Atomically reads + clears the pending-LTR-refresh latch.
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
        let forcedKeyframe = takePendingForcedKeyframe()
        // A STATIC window has no live delta to ride an LTR refresh, so on this path an LTR
        // request degrades to the same crisp/compact re-anchor as a forced keyframe — drain it and
        // fold it into `forced` (but the frameHandler is still called with ltrRefresh=false: the
        // static path never issues an actual ForceLTRRefresh, it re-encodes the cached frame crisp).
        // Always false when SLOPDESK_LTR is off.
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
        lastKeyframeEmit = now // the timer ALWAYS emits a keyframe → anchor the recovery cooldown
        // The window is at rest (a quiet live path is why this timer fired), so upgrade the re-encode
        // to a CRISP near-lossless intra refresh for razor-sharp static text (same live session → no
        // client decoder rebuild); `SLOPDESK_CRISP=0` falls back to a plain IDR. Never compact: at rest
        // no live delta competes for the wire, so the larger near-lossless IDR is no burst-loss risk.
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
    /// The resolved capture delivery ceiling (Hz) — `slopdesk_capture_hz`, which is the same rule
    /// the stream itself is configured with, so the two cannot disagree.
    /// Stored so the cadence gate's tolerance (half a delivery slot) matches the actual config.
    private let captureHz: Int
    /// Capture pixel scale: window points × this = the output buffer's pixels. The far side needs
    /// it because the crop it pins is point-space while the buffer it fills is pixel-space, so this
    /// is what divides the two back apart.
    private let captureScale: Double
    /// Capture NV12 in the FULL-RANGE pixel-format variant when true, else the VideoRange variant.
    /// Crosses as `SlopDeskCaptureDesc.full_range`; default false ⇒ VideoRange.
    private let fullRange: Bool
    /// Prefer display-anchored capture over the per-window compositor when no env override is set —
    /// see `slopdesk_capture_mode`.
    /// The live session passes `true`: display-anchored is ≈15ms lower glass-to-glass (one 60Hz slot)
    /// AND occlusion-proof (composites only the target window + children), so it is the default for
    /// every served window. `SLOPDESK_DISPLAY_CAPTURE=window` forces the per-window path; the init
    /// default stays `false` so the bare check-video CLI keeps `.window`.
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
        captureHz = Int(slopdesk_capture_hz(Int32(clamping: max(1, fps))))
        governedFPS = max(1, fps)
        encodeLoadPacer = EncodeLoadPacer(baseFps: max(1, fps))
        encodePacedFPS = max(1, fps)
        lastLoggedPacedFPS = max(1, fps)
        self.captureScale = max(1.0, captureScale)
        self.fullRange = fullRange
        self.frameHandler = frameHandler
        // Quiet window gates shouldReencode (the crisp re-anchor): 300ms, so text re-sharpens fast after
        // motion stops, clamped to the heartbeat so a longer heartbeat never stretches the timer-path
        // recovery-suppression window. SLOPDESK_QUIET_MS.
        staticIDRDecider = StaticIDRDecider(
            heartbeat: Self.heartbeatIDRInterval,
            quietWindow: slopdesk_capture_quiet_window(Self.heartbeatIDRInterval),
        )
        super.init()
    }

    /// An explicit display-anchored capture region (the DIALOG-EXPAND feature): when set, the crop
    /// is `displayLocalRect` (points) on `displayID` instead of the live window frame, so the
    /// captured surface spans the window ∪ its associated dialog. `globalRect` is the same region in
    /// global points — the session uses it to re-origin the input/cursor mapping into the dialog
    /// area. Built by `slopdesk_video::capture_region` and threaded through
    /// ``start(windowID:pixelWidth:pixelHeight:region:)``.
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

    /// Why an in-place resize was refused — the caller restart-fallbacks on any of these.
    public enum CannotResizeInPlace: Error {
        case noStream
        case notDisplayAnchored
        case unionOwned
        /// The framework refused the reconfigure, carrying its own status. The live stream keeps
        /// running at the OLD size rather than dying, so the caller may restart at its leisure.
        case refused(Int32)
    }

    // MARK: The capture stream

    /// Serialises the callers that ask a display-anchored crop to change.
    ///
    /// The far side owns the live configuration and answers whether it is anchored, so all that is
    /// left on this side is admitting one driver at a time: the session fires a fresh `Task` per
    /// geometry message, and without this several could reconfigure one stream at once.
    /// `reanchorInFlight` admits exactly one driver, and newer frames overwrite `reanchorPending`
    /// so the driver always converges to the LATEST position.
    private let anchorLock = NSLock()
    private var reanchorInFlight = false
    private var reanchorPending: CGRect?

    /// Where every BLOCKING door call is made.
    ///
    /// The far side waits on the framework's own completion handler rather than handing a second
    /// callback back across the boundary — one state machine instead of two — so a lifecycle call
    /// blocks for as long as the framework takes (~120 ms for a start). The caller is a session
    /// actor, and an actor that blocks stops serving every other message, so the wait happens here
    /// and the caller awaits it.
    private let controlQueue = DispatchQueue(label: "slopdesk.video.capture.control", qos: .userInitiated)

    /// Awaits one blocking door call on ``controlQueue``.
    ///
    /// Every pointer crosses into the closure as its BIT PATTERN and is rebuilt inside. Swift's
    /// concurrency checker will not carry a raw pointer into a `@Sendable` closure, and it is right
    /// not to in general — the promise that makes these safe is the door's own (the handle is
    /// `Mutex`-guarded on the far side, the queues are retained by the stream, the context is
    /// retained for the handle's whole life), which is not a promise the type system can see.
    private func onControlQueue<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            controlQueue.async { continuation.resume(returning: body()) }
        }
    }

    /// The live handle as a bit pattern, for the closure above. Nil before start and after stop.
    private var captureBits: UInt? {
        capture.map { UInt(bitPattern: UnsafeRawPointer($0)) }
    }

    /// A frame carrying NEW pixels, on `frameQueue`. The surface is borrowed for the call only.
    private static let frameDoor: SlopDeskCaptureFrameFn = { context, imageBuffer, value, timescale in
        guard let context, let imageBuffer else { return }
        let capturer = Unmanaged<WindowCapturer>.fromOpaque(context).takeUnretainedValue()
        let pixelBuffer = Unmanaged<CVPixelBuffer>.fromOpaque(imageBuffer).takeUnretainedValue()
        capturer.deliver(pixelBuffer: pixelBuffer, pts: CMTime(value: value, timescale: timescale))
    }

    /// An audio buffer, on `audioQueue` — its own serial output, so it never queues behind a
    /// synchronous video encode.
    private static let audioDoor: SlopDeskCaptureAudioFn = { context, sampleBuffer in
        guard let context, let sampleBuffer else { return }
        let capturer = Unmanaged<WindowCapturer>.fromOpaque(context).takeUnretainedValue()
        capturer.deliver(audio: Unmanaged<CMSampleBuffer>.fromOpaque(sampleBuffer).takeUnretainedValue())
    }

    /// CAPTURE-DEATH: the stream stopped ITSELF (shared window/app closed, display unplugged,
    /// Screen-Recording grant revoked, window server reset). Never fired for a deliberate ``stop()``.
    private static let stoppedDoor: SlopDeskCaptureStoppedFn = { context in
        guard let context else { return }
        let capturer = Unmanaged<WindowCapturer>.fromOpaque(context).takeUnretainedValue()
        capturer.log.error("capture stream stopped with an error")
        capturer.handleCaptureFailure()
    }

    /// Which content filter to build, as one of the door's `SLOPDESK_CAPTURE_MODE_*` constants.
    ///
    /// Resolved through `EnvConfig` (ProcessInfo env → overlay) so a GUI setting can force the
    /// capture filter; an EMPTY overlay reads exactly like a bare `ProcessInfo` lookup.
    private static func captureMode(preferDisplayAnchored: Bool) -> Int32 {
        let requested = Array((EnvConfig.string("SLOPDESK_DISPLAY_CAPTURE") ?? "").utf8)
        return requested.withUnsafeBufferPointer {
            slopdesk_capture_mode($0.baseAddress, $0.count, preferDisplayAnchored)
        }
    }

    /// Starts capturing the given window at an explicit PIXEL size (`pixelWidth`×`pixelHeight`).
    /// Passing the window's backing-pixel size (points × display scale) captures at native Retina
    /// resolution — sharp text — instead of the soft point-resolution default. ⚠️ Requires a
    /// window-server + Screen-Recording TCC session — NEVER call from a test.
    ///
    /// The window is named by ID, not by an enumerated object: the mint flow AX-moves the window
    /// onto the virtual display AFTER whatever the caller enumerated was made, so that object's
    /// frame is the PRE-move one and a display-local crop computed from it would be wrong. The far
    /// side re-resolves by id, which makes that the only path rather than a correction inside one.
    ///
    /// `region` (DIALOG-EXPAND): when non-nil, the display-anchored crop is pinned to that explicit
    /// union rect (window ∪ dialog) instead of the live window frame — `pixelWidth`/`pixelHeight`
    /// must already match `region.globalRect.size × captureScale`. nil ⇒ the normal window-frame crop.
    public func start(
        windowID: CGWindowID,
        pixelWidth: Int,
        pixelHeight: Int,
        region: CaptureRegionOverride? = nil,
    ) async throws {
        let crop = region?.displayLocalRect ?? .zero
        try await bringUp(
            SlopDeskCaptureDesc(
                capture_scale: captureScale,
                region_x: crop.origin.x,
                region_y: crop.origin.y,
                region_width: crop.size.width,
                region_height: crop.size.height,
                window_id: windowID,
                display_id: region?.displayID ?? 0,
                mode: Self.captureMode(preferDisplayAnchored: preferDisplayAnchored),
                pixel_width: Int32(clamping: pixelWidth),
                pixel_height: Int32(clamping: pixelHeight),
                fps: Int32(clamping: fps),
                audio_sample_rate: Self.audioCaptureEnabled ? Int32(clamping: AudioStreamEncoder.sampleRate) : 0,
                audio_channel_count: Int32(clamping: AudioStreamEncoder.channelCount),
                full_range: fullRange,
                has_region: region != nil,
            ),
            describing: "window \(windowID)\(region != nil ? " [union]" : "")",
        )
    }

    /// Starts capturing a WHOLE display (the full-desktop pane) at an explicit PIXEL size
    /// (`pixelWidth`×`pixelHeight` — the display's point size × `captureScale`). Everything on the
    /// display is captured, dock and desktop included, and the source-rect pin IS the full display
    /// here — so no crop/anchor state is needed (a display never moves; the window path's re-anchor
    /// machinery stays inert). ⚠️ Same TCC/window-server requirements as the window path.
    public func start(displayID: CGDirectDisplayID, pixelWidth: Int, pixelHeight: Int) async throws {
        try await bringUp(
            SlopDeskCaptureDesc(
                capture_scale: captureScale,
                region_x: 0,
                region_y: 0,
                region_width: 0,
                region_height: 0,
                // A zero window id IS what selects the whole display — the two cannot both be asked for.
                window_id: 0,
                display_id: displayID,
                mode: SLOPDESK_CAPTURE_MODE_DISPLAY_EXCLUDING,
                pixel_width: Int32(clamping: pixelWidth),
                pixel_height: Int32(clamping: pixelHeight),
                fps: Int32(clamping: fps),
                audio_sample_rate: Self.audioCaptureEnabled ? Int32(clamping: AudioStreamEncoder.sampleRate) : 0,
                audio_channel_count: Int32(clamping: AudioStreamEncoder.channelCount),
                full_range: fullRange,
                has_region: false,
            ),
            describing: "display \(displayID)",
        )
    }

    /// The shared bring-up: retain this capturer across the boundary, block on the framework off the
    /// caller's actor, and arm the static-IDR timer. The retain is the door's stated term — the
    /// context must outlive the handle — and is released in ``stop()`` after the handle is freed.
    private func bringUp(_ desc: SlopDeskCaptureDesc, describing target: String) async throws {
        let context = Unmanaged.passRetained(self).toOpaque()
        let contextBits = UInt(bitPattern: context)
        let frameBits = UInt(bitPattern: Unmanaged.passUnretained(frameQueue).toOpaque())
        let audioBits = UInt(bitPattern: Unmanaged.passUnretained(audioQueue).toOpaque())
        let (handle, status) = await onControlQueue { () -> (UInt, Int32) in
            var status: Int32 = 0
            var desc = desc
            let created = slopdesk_capture_start(
                &desc,
                UnsafeMutableRawPointer(bitPattern: contextBits),
                Self.frameDoor,
                Self.audioDoor,
                Self.stoppedDoor,
                UnsafeRawPointer(bitPattern: frameBits),
                UnsafeRawPointer(bitPattern: audioBits),
                &status,
            )
            return (UInt(bitPattern: created.map { UnsafeRawPointer($0) }), status)
        }
        guard let created = OpaquePointer(bitPattern: handle) else {
            Unmanaged<WindowCapturer>.fromOpaque(context).release()
            throw CaptureStartError.refused(status)
        }
        capture = created
        captureContext = context
        log.info("WindowCapturer started for \(target)")
        startIDRTimer()
    }

    /// The capture stream would not come up — a framework error code, or one of the door's own
    /// sentinels: -1 no answer inside the wait limit, -2 nothing shareable (no Screen-Recording
    /// grant, no window server), -3 nothing matching the id.
    public enum CaptureStartError: Error { case refused(Int32) }

    /// VIDEO-HOST-1: a heartbeat timer on `frameQueue` so every tick is serialized against the
    /// capture callback — no lock needed for `cachedPixelBuffer` / the decider. On a static window
    /// (no delivered frames at all) this is the ONLY path that can produce an IDR for a joining /
    /// loss-recovering client.
    ///
    /// The poll is DECOUPLED from the heartbeat: with a multi-second heartbeat the timer must still
    /// poll the recovery latch + service a truly-idle window promptly. The decider only EMITS when
    /// due, so sub-cadence ticks are cheap no-ops. At an 80ms tick the crisp re-anchor lands
    /// ≈ quietWindow + tick (~0.38s) after motion stops. SLOPDESK_IDR_TICK_MS.
    private func startIDRTimer() {
        let tick = slopdesk_capture_idr_tick()
        let leewayMs = max(8, Int((tick * 1000.0) / 4.0))
        let timer = DispatchSource.makeTimerSource(queue: frameQueue)
        timer.schedule(deadline: .now() + tick, repeating: tick, leeway: .milliseconds(leewayMs))
        timer.setEventHandler { [weak self] in self?.onIDRTimerTick() }
        timer.resume()
        idrTimer = timer
    }

    /// Re-anchors a display-anchored crop after the window MOVED (geometry-watcher feed from the
    /// session). A no-op in per-window mode, on a poller-owned union crop, and for sub-half-point
    /// deltas — the far side decides which. Rare + user-driven (a title-bar drag), never per-frame.
    public func updateDisplayAnchoredOrigin(windowFrameCG frame: CGRect) async {
        // Coalesce + serialize: record the latest frame, and only the FIRST caller becomes the driver
        // that applies updates — overlapping callers just hand off their frame and return. The driver
        // loops until no newer frame is pending, so we always converge to the latest position without
        // issuing concurrent reconfigures for positions the window has already left.
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

    /// The actual single-threaded re-anchor (only ever run by the ``updateDisplayAnchoredOrigin``
    /// driver). The crop jump lands mid-GOP as a whole-frame delta, so a keyframe right after it is
    /// what keeps a late-joining client from decoding half of each.
    private func applyReanchor(windowFrameCG frame: CGRect) async {
        guard let handle = captureBits else { return }
        let origin = frame.origin
        let status = await onControlQueue {
            slopdesk_capture_reanchor(OpaquePointer(bitPattern: handle), origin.x, origin.y)
        }
        switch status {
        case 0:
            requestKeyframe()
            log.notice("display-anchored crop re-anchored to \(Int(origin.x)),\(Int(origin.y))pt (window moved)")
        case let refused where refused < 0:
            log.error("display-anchored re-anchor failed: \(refused)")
        default:
            break // the move was under half a point, or there was no anchor to rewrite
        }
    }

    /// True when this capturer crops a DISPLAY — i.e. it owns a live configuration that an in-place
    /// size change can drive. Per-window mode returns false. Read from the session actor.
    public var isDisplayAnchored: Bool {
        capture.map { slopdesk_capture_is_display_anchored($0) } ?? false
    }

    /// True when the crop is a DIALOG-EXPAND union region (poller-owned) — an in-place resize must
    /// NOT touch it (the poller re-targets); the caller restart-fallbacks instead.
    public var isUnionAnchored: Bool {
        capture.map { slopdesk_capture_is_union_anchored($0) } ?? false
    }

    /// IN-PLACE resize: reconfigure the LIVE stream to `pixelWidth`×`pixelHeight` — NO restart, so
    /// the framework's ~120ms spin-up is avoided. The far side rebuilds the configuration at the new
    /// size and preserves the display-anchored crop ORIGIN at the new point size; the filter is
    /// untouched (same window, same display), so only the size and the crop move.
    ///
    /// THROWS for per-window / union / no-stream (caller restart-fallbacks); on a refused
    /// reconfigure the live stream keeps running at the OLD size (no dead stream).
    public func updateSize(pixelWidth: Int, pixelHeight: Int) async throws {
        guard let handle = captureBits else { throw CannotResizeInPlace.noStream }
        // Claim the single-driver gate so a CONCURRENT window-MOVE re-anchor defers (records pending)
        // instead of issuing a second reconfigure on this stream mid-resize. Clear the gate + drop
        // any stale pending move at the end.
        anchorLock.withLock { reanchorInFlight = true }
        defer { anchorLock.withLock { reanchorInFlight = false
            reanchorPending = nil
        } }
        guard isDisplayAnchored else { throw CannotResizeInPlace.notDisplayAnchored }
        guard !isUnionAnchored else { throw CannotResizeInPlace.unionOwned }
        let width = Int32(clamping: pixelWidth)
        let height = Int32(clamping: pixelHeight)
        let status = await onControlQueue {
            slopdesk_capture_resize(OpaquePointer(bitPattern: handle), width, height)
        }
        guard status == 0 else { throw CannotResizeInPlace.refused(status) }
        log.notice("in-place resize: reconfigured to \(pixelWidth)x\(pixelHeight) px (no restart)")
    }

    public func stop() async {
        // VIDEO-HOST-1: cancel the timer + release the cached copy on `frameQueue` (the timer's
        // queue) BEFORE stopping capture, so no tick can race teardown. `cachedPixelBuffer = nil`
        // is sufficient — ARC releases the managed copy; no manual CVPixelBufferRelease.
        // CAPTURE-DEATH: runs BEFORE the handle guard below, so even a never-started (or
        // already-failed) capturer latches `captureStopped` — a late capture-death callback racing
        // a deliberate stop must never fire `onCaptureFailed` afterwards (double-teardown guard);
        // the `frameQueue.sync` serializes this latch against ``handleCaptureFailure()``'s hop.
        frameQueue.sync {
            captureStopped = true
            idrTimer?.cancel()
            idrTimer = nil
            // GATED-TAIL FLUSH: cancel the one-shot inside the same frameQueue.sync, so no flush
            // can race teardown (the work item runs on frameQueue too). Belt-and-braces: a
            // hypothetical already-queued execution is also inert — `cachedPixelBuffer` is nil.
            pendingGatedFlush?.cancel()
            pendingGatedFlush = nil
            cachedPixelBuffer = nil
        }
        guard let handle = capture, let handleBits = captureBits else { return }
        capture = nil
        let context = captureContext
        captureContext = nil
        // On the post-failure path the stream is already dead — the stop then answers a framework
        // error, which is nothing to act on: the teardown is the same either way and the
        // capture-death callback has already fired.
        _ = await onControlQueue { slopdesk_capture_stop(OpaquePointer(bitPattern: handleBits)) }
        slopdesk_capture_free(handle)
        // The door's terms are that the context outlives the handle, so the retain taken at
        // ``bringUp`` is released HERE — after the free, never before.
        if let context { Unmanaged<WindowCapturer>.fromOpaque(context).release() }
    }

    // MARK: Deliveries

    /// One audio buffer, on `audioQueue` — its own serial output, so no frameQueue-owned state is
    /// touched here. One lock read per ~10 ms buffer covers gate + sink together; a disabled
    /// session drops the buffer BEFORE any extract/encode work.
    private func deliver(audio sampleBuffer: CMSampleBuffer) {
        let handler: (@Sendable (CMSampleBuffer) -> Void)? = audioLock.withLock {
            audioForwardingEnabled ? audioSampleHandler : nil
        }
        handler?(sampleBuffer)
    }

    /// One frame carrying NEW pixels, on `frameQueue`. The surface is borrowed for the call only —
    /// it goes back to the framework's pool when this returns, within
    /// `minimumFrameInterval × (queueDepth − 1)` (WWDC22 s10155) — so anything kept is copied.
    ///
    /// Idle-skip (doc 17 §3.5) happens on the FAR side: a frame the framework marks anything but
    /// complete carries no new pixels and never reaches this method, so there is no IOSurface touch,
    /// no encode and no send for it. >90% of coding frames are that.
    ///
    /// ⚠️ VIDEO-HOST-1 (docs/25 §4): on a STATIC window NOTHING arrives here, so the
    /// forced-keyframe latch (`takePendingForcedKeyframe`) AND the heartbeat IDR — both below —
    /// never run; a client that requests loss-recovery (or joins) while the host window is
    /// unchanging would get no IDR and freeze on the last good frame. That is why `start()` arms a
    /// heartbeat timer on `frameQueue` (see StaticIDRDecider) that re-encodes the cached last real
    /// COPY (`copyPixelBuffer`) as a forced IDR via `onIDRTimerTick` — the latch + heartbeat get a
    /// second drainer while the live path is quiet.
    private func deliver(pixelBuffer: CVPixelBuffer, pts: CMTime) {
        // `now` (computed here for both the heartbeat block and the static-IDR caching below).
        let now = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1_000_000_000.0

        // SLOPDESK_VIDEO_DEBUG: a >28ms gap between two DELIVERED frames during continuous motion
        // means SCK itself stalled (or idle-skipped a changing frame) — anything downstream can only
        // inherit this hole. Idle pages legitimately gap; read these lines only against a
        // continuous-motion test (testufo).
        if Self.dbgGapEnabled {
            if lastDeliveredAt > 0, now - lastDeliveredAt > 0.028 {
                FileHandle.standardError
                    .write(Data("slopdesk-videohostd[gap]: capture gap \(Int((now - lastDeliveredAt) * 1000))ms\n"
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
                            // scroll-stop stutter); stepping spreads it over a few small frames.
                            max(rawQP, s - Self.adaptiveQPDownStep)
                        }
                    } else {
                        rawQP
                    }
                adaptiveQPSmoothed = smoothed
                pendingAdaptiveQP = smoothed
                if Self.dbgGapEnabled {
                    FileHandle.standardError
                        .write(Data("slopdesk-videohostd[aqp]: rawQP=\(rawQP) smoothed=\(smoothed)\n".utf8))
                }
            } else {
                pendingAdaptiveQP = nil
            }
        } else {
            pendingAdaptiveQP = nil
        }
        // LATENCY: the `cachedPixelBuffer` COPY is DEFERRED to function exit so it stays off the
        // encode-submit critical path (the encoder sees the frame ~0.5–2ms sooner). The cache
        // (IDR-heartbeat / crisp / dialog-union) is read only on LATER timer ticks, never by THIS
        // frame's encode, which is handed `pixelBuffer` directly. `defer` fires on EVERY exit —
        // idle-skip / scroll-fps / static-suppress / governor-gate returns AND the encode path — so
        // every path caches. ⚠️ It must stay BELOW the measure-vs-prev reads above: they compare this
        // frame against the PREVIOUS one, which is still what `cachedPixelBuffer` holds up here.
        defer { cachedPixelBuffer = Self.copyPixelBuffer(pixelBuffer) }

        // Compute the full NV12 hash AT MOST ONCE per frame — idle-skip, still-crisp, and
        // static-suppress are three independently env-gated deciders that would otherwise each pay
        // their own CVPixelBufferLockBaseAddress + full-frame scalar hash on this userInteractive
        // capture queue when stacked together. Trigger is the union of all three gates: idle-skip only
        // once ELIGIBLE (its own cheap luma pre-check still avoids the hash when it alone is enabled
        // and the frame is obviously non-idle); still-crisp/static-suppress compute unconditionally
        // when enabled. The SAME hash value then feeds every decider below — deterministic, so reusing
        // it changes nothing about their individual verdicts.
        let frameHash: UInt64? =
            slopdesk_video_capture_needs_frame_hash(Self.gatesRef, measured, changeMilli)
                ? Self.hashFrame(pixelBuffer)
                : nil

        // TRUE IDLE-SKIP decision (default OFF): drop a frame ONLY when it is byte-identical to the
        // previous one by the FULL NV12 hash (luma+chroma, `hashFrame`) — so a chroma-only change (a
        // syntax-highlight color flip, theme toggle) is NOT mistaken for idle (the luma-only `changeMilli`
        // would miss it) — AND it carries no pending obligation. The cheap luma `idleSkipEligible`
        // pre-check (the adaptive-QP changed-row fraction) gates the full-hash compute. A skipped frame
        // must NOT re-anchor `staticIDRDecider` below — leaving the quiet-window clock stale is what lets
        // the ~300ms crisp refresh fire on a static window (the anti-freeze invariant STATIC_SUPPRESS breaks).
        var idleSkip = false
        if slopdesk_video_capture_skips_idle_frame(Self.gatesRef, measured, changeMilli),
           let fullHash = frameHash,
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
           let hash = frameHash,
           hash != FrameHash.SENTINEL
        {
            stillnessDecider.onFrame(hashEqualToPrevious: lastStillnessHash == hash)
            lastStillnessHash = hash
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
        // Gate OFF ⇒ this block is skipped entirely (no hash computed).
        if Self.staticSuppressEnabled,
           let hash = frameHash,
           hash != FrameHash.SENTINEL,
           let lastHash = lastSubmittedFrameHash
        {
            // PEEK (do not drain) the forced obligations so a suppressed frame never swallows a
            // pending recovery/keyframe latch — the latch drains on the next encoded frame, exactly
            // as the FPS-governor cadence gate peeks. The first-frame case is covered by
            // `lastSubmittedFrameHash == nil` (this branch is skipped until a frame has been sent).
            if staticSuppressDecider.shouldSuppress(
                hashEqualToLast: hash == lastHash,
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
        // 90 kHz timescale (VIDEO-HOST-1 §5).
        lastEmittedPTS = CMTimeMaximum(lastEmittedPTS, pts90k)
        let encodePTS = lastEmittedPTS

        // FPS-GOVERNOR cadence gate: when governed below the base fps, admit deliveries on the
        // drift-free schedule (every 2nd/3rd/4th delivery slot — metronome-regular; an alternating
        // skip would beat audibly against motion). Placement invariants (each load-bearing):
        //  - the cachedPixelBuffer copy + staticIDRDecider.onCompleteFrame above MUST run for
        //    gated frames too. Cache: otherwise the static-timer crisp refresh would re-ship a
        //    stale pre-final frame after motion stops on a gated frame (permanent stale screen).
        //    Decider: otherwise the timer would think the live path quiet and fire crisp IDRs
        //    MID-motion. Costs nothing extra — every delivered frame is copied anyway.
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
        // CLIENT-SILENCE PAUSE: the client's feedback has gone silent past the threshold (walk-away /
        // dead uplink), so skip encode+send for this ordinary frame — the host must not blast ~ABR to a
        // peer that is not listening. Skipped like the static-suppress / cadence gates: the cache /
        // decider / PTS above were updated (a crisp refresh on resume has the latest content) but
        // `encodeBelowGate` is NOT called, so the encoder reference chain does NOT advance — when the
        // client returns the next delta decodes against its last-received frame with NO keyframe. A
        // pending forced-keyframe / LTR-refresh latch is EXEMPT (honored for a clean resume), and the
        // pending-flush was just cancelled above so nothing encodes during the pause. Only ever true
        // after the stream is established (`hasEmittedFirstFrame`) and the feature is enabled
        // (`SLOPDESK_VIDEO_PAUSE_SILENT_SEC`); the session clears it on the next inbound datagram.
        if isClientSilencePaused(), hasEmittedFirstFrame, !peekPendingRecoveryLatches() {
            return
        }
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
        // Heartbeat IDR, plus a forced keyframe on the very first delivered frame, plus any
        // client-requested IDR (loss recovery, doc 17 §3.6).
        let latched = takePendingForcedKeyframe()
        // Drain the LTR-refresh latch too (always false when SLOPDESK_LTR is off).
        let ltrLatched = takePendingLTRRefresh()
        var forceKeyframe = latched
        var isFirstFrame = false
        var isHeartbeat = false
        if !hasEmittedFirstFrame {
            forceKeyframe = true
            isFirstFrame = true
            hasEmittedFirstFrame = true
        } else if Self.motionHeartbeatEnabled, now - lastHeartbeat >= Self.heartbeatIDRInterval {
            // The periodic motion-heartbeat IDR is gated OFF by default (it is the 2.5s scroll hitch —
            // see `motionHeartbeatEnabled`). When off, `lastHeartbeat` is anchored only by the
            // first-frame + recovery IDRs below, and the static timer re-anchors on motion pause.
            forceKeyframe = true
            isHeartbeat = true
        }
        // Collapse a recovery-IDR storm. If the ONLY reason is the recovery latch AND a keyframe was
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
        // COMPACT IDR: a forced IDR on the LIVE (active) path — recovery (client-requested after loss)
        // or heartbeat — is encoded SMALL+coarse (encodeCompactKeyframe) so it survives a UDP burst
        // instead of re-triggering the recovery-IDR loop, which shows up as a periodic motion hitch.
        // The FIRST frame stays full quality (one-time, no loop); the static timer path stays CRISP.
        // `compact ⟹ forceKeyframe` by construction.
        let compact = forceKeyframe && !isFirstFrame
        // Send a cheap LTR refresh ONLY when we are NOT already sending a keyframe — a keyframe
        // (first/heartbeat/recovery IDR) is a superset recovery and wins, so an LTR refresh latched
        // alongside it is simply consumed (the keyframe re-anchors the client). If `forceKeyframe`
        // ended up false but an LTR refresh was latched, ship the small ForceLTRRefresh P-frame.
        // Always false when SLOPDESK_LTR is off (the latch is never set) ⇒ byte-identical.
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
        // CLEAN-LINK LOSS-GATE (default OFF ⇒ byte-identical): with the gate on, the every-Kth refresh is
        // suppressed while the pushed loss EWMA is below threshold — the counter keeps climbing (heal
        // skipped, not reset) so the first lossy frame re-arms healing immediately (see `selfHealLossGate`).
        if healEvery > 0, !forceKeyframe, !ltrRefresh {
            framesSinceAnchor += 1
            if slopdesk_video_capture_should_self_heal(
                Self.gatesRef, Int32(clamping: framesSinceAnchor), selfHealIsEligible(),
                currentSelfHealLossRate(),
            ) {
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
        // DIAGNOSTIC force-compact storm (SLOPDESK_FORCE_COMPACT_EVERY): reproduce the loss-driven
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

    // MARK: GATED-TAIL FLUSH (FPS governor)

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

    // MARK: CAPTURE-DEATH

    /// CAPTURE-DEATH quiesce. The stream is DEAD (shared window/app closed, display unplugged,
    /// Screen-Recording grant revoked, window server / GPU reset). Logging alone is NOT enough —
    /// the IDR timer would keep re-encoding the stale `cachedPixelBuffer` as periodic
    /// heartbeat/crisp IDRs, so the client "decodes video" (a frozen frame) with no error and its
    /// stall scrim never engages.
    ///
    /// The capture-death callback fires on the framework's own private queue, NOT `frameQueue`, so
    /// hop onto `frameQueue` (async — never block that queue) where the IDR timer / cached frame /
    /// gated flush all live; the hop also serializes
    /// against ``stop()``'s `frameQueue.sync` teardown, so whichever side runs first wins and the
    /// other no-ops via the one-shot latches. `onCaptureFailed` is then invoked ON `frameQueue`
    /// (the `onScrollOffset` discipline — the session's closure hops onto its actor itself).
    ///
    /// The dead handle is deliberately NOT freed here: `capture` is confined to the session-actor
    /// lifecycle paths (`start`/`stop`/resize), so a callback-queue write would race them. The
    /// wired session callback tears the session down through the existing bye path → ``stop()``,
    /// which frees it under that discipline (stopping an already-dead stream just answers a
    /// framework error, which is nothing to act on).
    ///
    /// `internal` (not `private`) so the headless regression test can drive the failure path —
    /// a real capture stream can never exist under XCTest (hang-safety) and `init` creates none.
    func handleCaptureFailure() {
        frameQueue.async { [weak self] in
            guard let self else { return }
            guard !captureFailed, !captureStopped else { return } // once-only; a deliberate stop wins
            captureFailed = true
            idrTimer?.cancel()
            idrTimer = nil
            pendingGatedFlush?.cancel()
            pendingGatedFlush = nil
            cachedPixelBuffer = nil // no more synthetic re-encodes of the stale last frame — ever
            onCaptureFailed?()
        }
    }

    // MARK: VIDEO-HOST-1 pixel-buffer copy

    /// Deep-copies an NV12 `CVPixelBuffer` into a fresh IOSurface-backed buffer the capturer
    /// owns indefinitely, so the framework-delivered surface can be returned to the pool
    /// immediately (WWDC22 s10155 — permanently retaining one would shrink the live pool by a
    /// slot and risk a capture stall). Returns nil on alloc/lock failure (the caller then simply
    /// has no cached buffer → the decider returns false, no synthetic IDR — safe). The copy is
    /// IOSurface-backed so the synthetic re-encode stays zero-copy into VT, like live.
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
        // surrounding live frames.
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
                "slopdesk-videohostd[scroll]: measure w=\(w) h=\(h) pStride=\(pStride) cStride=\(cStride) maxShift=\(maxShift)\n"
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
                    "slopdesk-videohostd[scroll]: shift=\(shift) conf=\(confMilli) band=\(bandTopRow)..\(bandBottomRow)\n"
                        .utf8,
                ))
        }
        // The confidence gate, the ten-thousandths scale and the band's inclusive-row → exclusive-edge
        // conversion all live on the far side, beside the client's decode: they are ONE encoding, and a
        // scale spelled on only one end is a scale the two ends can drift apart on. `-1` rows ⇒ no band
        // ⇒ the client falls back to a whole-frame warp.
        let hint = ScrollReprojector.Hint(
            shift: shift, confidenceMilli: confMilli,
            bandTopRow: bandTopRow, bandBottomRow: bandBottomRow, height: h,
        )
        return (hint.dx, hint.dy, hint.bandTop, hint.bandBottom)
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

    /// Hashes the NV12 `pixelBuffer`'s luma + interleaved-chroma planes into one 64-bit value via the
    /// native ``FrameHasher/hashNV12(y:yStride:width:height:cbcr:cbcrStride:)`` NEON kernel, ZERO-COPY:
    /// it locks the buffer read-only, passes the locked plane base addresses + their `bytesPerRow`
    /// strides straight to the kernel (which borrows them for the call only), then unlocks. Only the
    /// VISIBLE `width` bytes of each row are hashed, so the result is independent of plane padding.
    /// Returns nil on a lock failure / missing luma plane (the caller then simply does not suppress).
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

// MARK: - Headless test seams (CAPTURE-DEATH regression)

/// A real SCStream can never exist under XCTest (hang-safety: no SCStream/VT/Metal in unit
/// tests), so the capture-failure quiesce is proven through these `frameQueue`-confined seams:
/// seed the cached `.complete`-frame copy exactly as a live delivery would, run one static-IDR
/// timer tick body, and drain the queue after ``WindowCapturer/handleCaptureFailure()``'s async
/// hop. All three run SYNC on `frameQueue`, preserving the single-owner discipline. Never called
/// in production (`CaptureFailureTeardownTests` only).
extension WindowCapturer {
    func seedCachedPixelBufferForTesting(_ buffer: CVPixelBuffer) {
        frameQueue.sync { cachedPixelBuffer = buffer }
    }

    func runIDRTimerTickForTesting() {
        frameQueue.sync { onIDRTimerTick() }
    }

    func drainFrameQueueForTesting() {
        frameQueue.sync {}
    }

    /// Barrier on the decoupled encode queue (``encodeOffQueueEnabled``, now default-ON): the tick
    /// hands the frame to the encoder ASYNCHRONOUSLY, so a test asserting the emit must wait for the
    /// serial queue to drain first. No-op when encode runs inline (queue nil).
    func drainEncodeQueueForTesting() {
        encodeQueue?.sync {}
    }
}
#endif
