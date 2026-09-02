#if canImport(QuartzCore) && canImport(CoreVideo)
import CoreVideo
import CSlopDeskFFI
import Foundation
import QuartzCore
import SlopDeskVideoProtocol
#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Drives display from VSync (`CADisplayLink`), NOT decode-completion (doc 17 §3.7).
///
/// ⚠️ **GUI-ONLY** for the `CADisplayLink` path (needs a run loop + a screen); never driven
/// from tests.
///
/// Pacing policy — a small JITTER BUFFER, the Parsec/Moonlight render-ahead:
/// - Decoded frames queue oldest-first via ``submit(_:)``.
/// - Presentation HOLDS (priming) until the buffer first fills to ``targetDepth``,
///   establishing a few frames of slack. Thereafter each VSync presents ONE frame in
///   order — turning bursty / variable arrival into a steady one-per-vsync cadence.
/// - The slack absorbs the arrival/decode latency SPIKE at a static→motion transition
///   (idle = tiny 1.5 KB frames → scroll = 40–220 KB frames). A "present newest / skip-late"
///   pacer has no slack to spend there, so it re-shows the last frame for a tick — exactly the
///   idle-then-scroll stutter.
/// - HOMEOSTASIS: never carry more than ``targetDepth`` frames (drop the oldest excess),
///   so steady-state depth — hence added latency — settles at ≈targetDepth/fps instead of
///   ratcheting up to ``maxDepth`` under sustained motion or clock skew. ``maxDepth`` is a
///   submit-side hard backstop. An empty buffer re-presents the last frame (single repeat).
/// - RE-PRIME: the host idle-skips static frames, so any idle drains the buffer to empty.
///   After a sustained dry spell the pacer drops back to priming, REBUILDING the slack
///   before the next scroll — so every stop→scroll transition is smooth, not just the first.
/// - PRESENT-ON-ARRIVAL (really present-on-DECODE): a frame landing in an empty queue that
///   completes the depth is presented IMMEDIATELY, not held for the next vsync — reclaiming the
///   tick-wait on EVERY frame at depth 1 (sparse highlight/typing AND the dense scroll stream;
///   the Parsec model). Only reachable at `liveDepth == 1` (at depth ≥ 2 an empty-queue arrival
///   can never complete the depth). The immediate present consumes the cadence slot
///   (`lastRenderHostTime`), so the following link tick is throttled and re-shows never pile on.
///   `SLOPDESK_PRESENT_ON_ARRIVAL=0` for A/B.
/// - DISPLAY-NATIVE TICK: ``maxFrameRate`` resolves to the DISPLAY's native refresh
///   (``resolveTickRate``), not the host content fps. On a 120 Hz panel the link ticks every
///   8.3 ms, halving the worst-case hold of a mid-interval arrival. At depth 1 with 60 fps
///   content the tick BETWEEN two arrivals drains the queue (underflowRun → 1), so the NEXT
///   arrival satisfies the present-on-arrival gate — dense stream presents on decode with the
///   8.3 ms tick as fallback cadence. `SLOPDESK_PRESENT_ON_ARRIVAL=0` ⇒ pure 120 Hz-quantized
///   cadence (avg hold ≈ 4.2 ms); `SLOPDESK_TICK_HZ` overrides the resolved rate. Steady 60 fps
///   content never reaches the re-prime threshold (underflowRun oscillates 0↔1, occasionally 2 —
///   a depth-1 re-prime is satisfied by the very next arrival, no hold).
/// - CONTENT SLOTS ABOVE DEPTH 1: the queue knows the tick-to-content ratio (`ticks_per_frame`,
///   the floor of ``maxFrameRate`` over the content fps, rebased by ``setContentFps(_:)``) and at
///   any depth ≥ 2 hands a frame out once per that many ticks, answering `SLOPDESK_PRESENT_HOLD`
///   on the ticks between. Without it a 120 Hz tick presents the slack frame on the very next
///   tick (frames in pairs 8 ms apart, then a 58 ms hole at 30 fps) and the empty ticks between
///   arrivals read as starvation, so depth 2 was judder rather than slack. The underflow run and
///   the re-prime floor count empty SLOTS. Depth 1 is untouched: every tick is a slot there.
///
/// The queue policy is pure and unit-testable; the `CADisplayLink` wiring is GUI-only.
/// Trade-off: ~``targetDepth`` frames of added latency (≈targetDepth/fps s) for smoothness,
/// the same trade Parsec makes. Both depths are env-tunable at the construction site
/// (``VideoWindowPipeline``) via `SLOPDESK_JITTER_DEPTH` / `_MAX`.
public final class FramePacer: @unchecked Sendable {
    /// Called each VSync with the frame to draw (the next queued, or the last shown when
    /// the buffer is empty / still priming). `nil` only before the first frame.
    public typealias RenderCallback = @Sendable (CVImageBuffer) -> Void

    /// Depth-change observability (env `SLOPDESK_VIDEO_DEBUG`): one stderr line per liveDepth
    /// transition, so an HW A/B can verify the buffer floats down to 1 on a clean link (or see
    /// what jitter is pinning it higher).
    ///
    /// A DIRECT `ProcessInfo` read by decision, and the one `unless` on `slopdesk-invariants`'
    /// tree-wide direct-read ban: this is a developer gate, not a setting. It has no `config.toml`
    /// row, `slopdesk-guigate video` drives it through the real environment, and it is spelled the
    /// same way in the host half (`CursorSampler`, `slopdesk-videohostd`). Routing only the client
    /// half through the overlay would light half the family off one `[env]` line.
    private static let dbgEnabled = ProcessInfo.processInfo.environment["SLOPDESK_VIDEO_DEBUG"] != nil
    private let renderCallback: RenderCallback
    /// An `NSLock` and NOT a `Mutex`, alone in this module after the 2026-09-02 sweep, for a reason
    /// the shape gives: the tick path takes it, releases it MID-FUNCTION to hop to the main actor
    /// for the present, and re-takes it — three separate spans that a scoped `withLock` cannot
    /// express without splitting the state machine the spans share. `@unchecked Sendable` would
    /// stay here regardless (the render callback and the held `CVImageBuffer`s are neither `Mutex`
    /// state nor `Sendable`), so the conversion would buy churn on the one measured hot path.
    private let lock = NSLock()
    /// The whole presentation state machine — the jitter buffer, the priming latch, the underflow
    /// run, the live depth — as one value folded through `rust/slopdesk-video`'s `present_queue`,
    /// reached by `rust/slopdesk-ffi`'s `present_queue` door. Every rule the header describes
    /// (priming, HOMEOSTASIS, the `max(2, liveDepth)` re-prime floor, the hard cap) is that law's,
    /// spelled once. Guarded by ``lock``.
    private var record: SlopDeskPresentQueue
    /// The decoded frames the record's handles name. The record carries HANDLES and never touches
    /// an image; each fold answers which handles it let go of, and this is the bag they name — so
    /// there is exactly one place a `CVImageBuffer` is held and exactly one law deciding when.
    /// Guarded by ``lock``.
    private var images: [UInt64: CVImageBuffer] = [:]
    /// The next handle to mint. Monotonic and never reused; wrap is unreachable at a frame per
    /// vsync, and would only collide with a frame still queued from before it.
    private var nextHandle: UInt64 = 1
    /// The last frame shown — re-presented while priming or on an empty buffer. Held apart from
    /// ``images`` because the record goes on re-showing a handle long after the queue released it.
    private var lastShownFrame: CVImageBuffer?
    /// Debug-only (``dbgEnabled``): per-frame pacer holds for the current ~2s window, drained
    /// into one stderr line (`pacer hold p50/p90/max`). Guarded by ``lock``.
    private var dbgHolds: [Double] = []
    private var dbgHoldsWindowStart: Double = 0
    /// Debug-only (``dbgEnabled``): last CONTENT-present time, feeding the present-gap detector in
    /// ``dbgNoteHold(since:now:)``. Guarded by ``lock``.
    private var dbgLastPresentAt: Double = 0

    /// Frames to buffer before presentation begins. The absorbed arrival/decode jitter is
    /// ≈ this many frames; it is also the steady-state added latency (≈ targetDepth / fps).
    public let targetDepth: Int
    /// Hard cap on buffered frames; beyond it the oldest are dropped so latency cannot grow.
    public let maxDepth: Int

    /// The display-link tick rate AND render-rate cap. Resolved via ``resolveTickRate`` to the
    /// DISPLAY's native refresh (120 on ProMotion), floored at the host content fps. Content
    /// presents are bounded by what the host produces (60 fps), so a 120 Hz tick costs only
    /// cheap re-shows, not extra content work — while halving how long an arriving frame waits
    /// for the next tick.
    public let maxFrameRate: Double

    /// Whether the adaptive jitter-buffer controller is engaged (env `SLOPDESK_ADAPTIVE_JITTER`).
    /// When false the buffer is a FIXED ``targetDepth``: ``liveDepth`` is never reassigned,
    /// ``controller`` is nil, arrival jitter is never measured.
    private let adaptiveJitter: Bool
    /// The LIVE presentation depth the priming / homeostasis / re-prime logic reads — the record's
    /// own field, so there is no second copy to drift. Equals ``targetDepth`` when adaptive is off;
    /// otherwise the controller's recommendation, adopted through one of the two depth doors.
    /// ⚠️ Read ONLY under ``lock``. Do NOT read it from ``tick()`` (runs unlocked) — go through
    /// ``frameForVSync()`` or the locked ``currentDepth`` accessor, or you reintroduce the data
    /// race the queue avoids.
    private var liveDepth: Int { Int(record.live_depth) }
    /// Client-clock arrival-jitter estimator, fed ONE sample per decoded-frame ``submit``
    /// (adaptive only). Guarded by ``lock``. RESET at a re-prime-on-idle transition so the long
    /// idle gap isn't folded as a spurious jitter spike that would re-inflate on every resume.
    private var jitter = OWDJitterEstimator()
    /// The adaptive depth controller (nil when adaptive is off). Guarded by ``lock``.
    private var controller: AdaptiveJitterController?
    /// Late-EVENT driven 1↔2 depth policy + always-on presentation-health telemetry
    /// (``drainTelemetry()``). The policy ALWAYS runs (its counters feed the NetworkStats wire
    /// unconditionally); only its DEPTH ACTION is gated by ``adaptiveDepthV2``. Guarded by ``lock``.
    private var depthPolicy: PacerDepthPolicy
    /// Whether the v2 policy may move ``liveDepth`` (1↔2). Resolved at construction:
    /// `adaptiveDepth && targetDepth == 1 && !deadlineMode` — a manual `SLOPDESK_JITTER_DEPTH ≥ 2`
    /// makes v2 telemetry-only, and deadline mode has no queue depth to boost.
    private let adaptiveDepthV2: Bool
    /// Present-on-arrival for a starved display (see the header). Construction-time constant.
    private let presentOnArrival: Bool

    // MARK: DEADLINE PACER

    //
    // The arrival-driven modes (drain-on-vsync, present-on-decode) schedule presentation off
    // ARRIVAL events, so network jitter passes straight into inter-presentation intervals — the
    // "bunched frame" stutter: two frames arrive inside one vsync window, drain on consecutive
    // 8.3ms ticks, then a hole (8/8/17/8ms instead of 16.7 flat). Per WebRTC `VCMTiming` + the
    // Moonlight/cloud-gaming literature, this mode instead anchors each frame's presentation
    // DEADLINE to the CONTENT rhythm — `lastDeadline + contentInterval` — with a small playout
    // delay absorbing jitter, and presents at the first tick past the deadline.
    // CRITICAL: the anchor advances by the SCHEDULED deadline, never the actual present time,
    // so a late tick cannot accumulate schedule drift. Latest-frame-wins on the single pending
    // slot (a post-stall bunch shows the newest frame, not a fast-forward replay).
    // OPT-IN (`SLOPDESK_PACER=deadline`) for the remote-GUI video path; the DEFAULT is present-on-arrival
    // (Parsec's queued_frames=0 zero-playout shape — lowest latency, the right trade for an interactive
    // desktop). Anchoring presentation to the content rhythm absorbs this transport's FEC/recovery arrival
    // jitter into a small adaptive playout buffer instead of letting it bunch the present cadence —
    // HW-validated over NetBird (present-gaps 0.37%→0%, max hold 258ms→91ms) — but it costs standing
    // latency, so it wins only on a genuinely JITTERY WAN link. `SLOPDESK_PLAYOUT_MS` pins a fixed buffer
    // (else adaptive; 10ms cold-start seed).
    private let deadlineMode: Bool
    /// The content-rhythm interval (deadline mode). MUTABLE: a host `streamCadence` message
    /// rebases it via ``setContentFps(_:)``. Read and written only under ``lock``.
    private var contentIntervalSec: Double
    /// The deadline-mode playout buffer (seconds). MUTABLE: when ``adaptivePlayout`` is on it is
    /// driven by live network jitter via ``notePlayoutJitter(_:)`` (grow-fast / shrink-slow), else
    /// it stays the construction-time seed. Read and written only under ``lock``.
    private var playoutDelaySec: Double
    /// Adaptive-playout state (all seconds). When on with no fixed override, ``notePlayoutJitter``
    /// recomputes ``playoutDelaySec`` from live jitter on a slow (~1s) cadence via the Rust-core
    /// law, so the buffer auto-tunes to the link.
    private let adaptivePlayout: Bool
    private let fixedPlayoutOverride: Bool
    private let playoutK: Double
    private let playoutBaseMs: Double
    private let playoutFloorMs: Double
    private let playoutCeilMs: Double
    /// Max shrink per recompute tick (ms) — the shrink-slow rate that decays a transient spike.
    private let playoutShrinkStepMs = AdaptivePlayoutPolicy.defaultShrinkStepMs
    /// Folded-sample counter gating the ~1s recompute cadence (avoids per-fragment churn). ``lock``.
    private var playoutJitterSampleCount = 0
    /// Single pending frame + its deadline (latest-wins). Guarded by ``lock``.
    private var pendingFrame: CVImageBuffer?
    private var pendingDeadline: Double = 0
    private var pendingSubmittedAt: Double = 0
    /// The content-rhythm anchor: the last SCHEDULED present deadline (0 ⇒ none yet). ``lock``.
    private var lastPresentDeadline: Double = 0

    // On BOTH platforms the modern driver is a `CADisplayLink`: macOS 14+ exposes
    // `NSView.displayLink(target:selector:)` (the non-deprecated `CVDisplayLink` replacement,
    // run-loop driven like iOS); iOS uses `CADisplayLink` directly. A tiny `@objc` proxy
    // forwards each vsync into ``tick()``.
    #if canImport(QuartzCore)
    private var displayLink: CADisplayLink?
    /// A small target object the `CADisplayLink` retains; it forwards to ``tick()``.
    private final class DisplayLinkProxy: NSObject {
        let pacer: FramePacer
        init(_ pacer: FramePacer) { self.pacer = pacer }
        @objc
        func step() { pacer.tick() }
    }

    private var proxy: DisplayLinkProxy?
    #endif

    /// Tracks the elapsed time so the cap throttles ticks below the display refresh.
    private var lastRenderHostTime: Double = 0
    /// The frame object last handed to ``renderCallback`` (main-confined, like
    /// `lastRenderHostTime`). Re-presenting the SAME object is a visual no-op, so ``tick()`` SKIPS
    /// the render — at 120 Hz with 60 fps content half the ticks are empty re-shows, and rendering
    /// them burns ~1 ms of main-thread/GPU work per 8.3 ms slot, delaying the present-on-decode
    /// main-actor hops this pacer relies on.
    private var lastRenderedFrame: CVImageBuffer?
    /// Forces the next tick to render even an identical frame (main-confined). Set via
    /// ``setNeedsRedisplay()`` on layout/scale changes, where the LAYER changed under an
    /// unchanged frame.
    private var needsRedisplay = false

    // MARK: SCROLL-HINT REPROJECTION (default-OFF; env-gated at the construction site)

    /// The Rust-core scroll-hint offset law, or `nil` when `SLOPDESK_SCROLL_REPROJECT != 1`. When
    /// nil EVERY reproject path below is skipped, leaving the present path untouched. When set, the
    /// pacer integrates local scroll velocity into a UV offset on its BETWEEN-CONTENT ticks (the
    /// would-be identity-skip re-shows), re-presents the last frame WITH that offset, and resets the
    /// offset the instant a real decoded frame is presented (so the new frame's own scrolled content
    /// is never double-counted). Main-confined like the render path.
    private let reprojector: ScrollReprojector?
    /// Sets the current reproject offset on the (@MainActor) renderer's dedicated uniform. Does NOT
    /// present — the pacer drives the re-present through its own ``renderCallback`` right after, so
    /// offset and frame land on the SAME vsync. Main-actor. Set together with ``reprojector`` (both
    /// nil ⇒ feature off).
    private let applyReprojection: ((SIMD2<Float>) -> Void)?
    /// Host time of the last reproject tick, so a between-content tick integrates by the REAL elapsed
    /// since the previous reproject (not a fixed nominal interval). Main-confined.
    private var lastReprojTickTime: Double = 0
    /// True once a non-zero reproject offset has been applied, so the reset on a real present can be
    /// skipped when nothing was ever shifted (avoids a redundant re-present at rest). Main-confined.
    private var reprojOffsetActive = false

    public init(
        maxFrameRate: Double = 60.0,
        targetDepth: Int = 2,
        maxDepth: Int = 5,
        adaptiveJitter: Bool = false,
        presentOnArrival: Bool = true,
        adaptiveDepth: Bool = false,
        depthPolicyConfig: PacerDepthPolicy.Config = .init(),
        deadlineMode: Bool = false,
        contentFps: Double = 60.0,
        playoutDelayMs: Double = 20.0,
        adaptivePlayout: Bool = false,
        fixedPlayoutOverride: Bool = false,
        playoutK: Double = AdaptivePlayoutPolicy.defaultK,
        playoutBaseMs: Double = AdaptivePlayoutPolicy.defaultBaseMs,
        playoutFloorMs: Double = AdaptivePlayoutPolicy.defaultFloorMs,
        playoutCeilMs: Double = AdaptivePlayoutPolicy.defaultCeilMs,
        reprojector: ScrollReprojector? = nil,
        applyReprojection: ((SIMD2<Float>) -> Void)? = nil,
        renderCallback: @escaping RenderCallback,
    ) {
        // SCROLL-HINT REPROJECTION: both must be present to engage; either nil ⇒ feature off (the
        // default), and every reproject path is skipped, leaving the present path untouched.
        if let reprojector, let applyReprojection {
            self.reprojector = reprojector
            self.applyReprojection = applyReprojection
        } else {
            self.reprojector = nil
            self.applyReprojection = nil
        }
        self.presentOnArrival = presentOnArrival
        self.deadlineMode = deadlineMode
        contentIntervalSec = 1.0 / max(1.0, contentFps)
        playoutDelaySec = slopdesk_present_clamped_playout_seconds(playoutDelayMs / 1000.0)
        // Adaptive only takes effect in deadline mode with no fixed override; otherwise the seed holds.
        self.adaptivePlayout = adaptivePlayout && deadlineMode && !fixedPlayoutOverride
        self.fixedPlayoutOverride = fixedPlayoutOverride
        self.playoutK = playoutK
        self.playoutBaseMs = playoutBaseMs
        self.playoutFloorMs = playoutFloorMs
        self.playoutCeilMs = playoutCeilMs
        self.maxFrameRate = maxFrameRate
        // Every depth bound is the law's — a floor of one, a cap no lower than the target and no
        // deeper than the band one crossing is sized for. Reading them back off the record is what
        // keeps these two `let`s from becoming a second, drifting statement of the same clamps.
        record = slopdesk_present_queue_new(
            UInt32(clamping: targetDepth),
            UInt32(clamping: max(targetDepth, maxDepth)),
            slopdesk_present_ticks_per_frame(maxFrameRate, contentFps),
        )
        let clampedTarget = Int(record.live_depth)
        let clampedMax = Int(record.max_depth)
        self.targetDepth = clampedTarget
        self.maxDepth = clampedMax
        // PRECEDENCE: if BOTH adaptive systems are requested, v2 wins and v1 is forced OFF — two
        // writers of `liveDepth` are forbidden (they would fight: v1 grows on the 120Hz-tick
        // transient dips v2 was built to ignore).
        let resolvedAdaptiveJitter = adaptiveJitter && !adaptiveDepth
        self.adaptiveJitter = resolvedAdaptiveJitter
        // v2 depth ACTION only at the depth-1 arrival-mode default (manual depth ≥ 2 and deadline
        // mode keep the policy telemetry-only).
        adaptiveDepthV2 = adaptiveDepth && clampedTarget == 1 && !deadlineMode
        depthPolicy = PacerDepthPolicy(
            config: depthPolicyConfig,
            adaptEnabled: adaptiveDepth && clampedTarget == 1 && !deadlineMode,
        )
        // Adaptive OFF ⇒ liveDepth stays == targetDepth forever (controller nil, never consulted).
        // The controller's fps is its seconds→frames conversion UNIT and it is the CONTENT fps —
        // the SAME unit ``setContentFps(_:)`` rebases with. Seeding it with `maxFrameRate` (the
        // display tick rate, e.g. 120) would make the unit FLIP to content fps (60) on the first
        // `streamCadence` rebase, halving every depth recommendation mid-session.
        controller = resolvedAdaptiveJitter
            ? AdaptiveJitterController(
                minDepth: 1,
                maxDepth: clampedMax,
                fps: max(1.0, contentFps),
                initialDepth: clampedTarget,
            )
            : nil
        self.renderCallback = renderCallback
        if Self.dbgEnabled {
            if adaptiveJitter, adaptiveDepth {
                FileHandle.standardError
                    .write(
                        Data(
                            "SlopDesk[video.client]: ADAPTIVE_JITTER (v1) forced OFF — ADAPTIVE_DEPTH (v2) owns liveDepth\n"
                                .utf8,
                        ),
                    )
            }
            FileHandle.standardError
                .write(
                    Data(
                        "SlopDesk[video.client]: pacer up — tick=\(Int(maxFrameRate))Hz depth=\(clampedTarget) adaptive=\(resolvedAdaptiveJitter) adaptiveDepthV2=\(adaptiveDepthV2) presentOnArrival=\(presentOnArrival) mode=\(deadlineMode ? "deadline(playout=\(Int(playoutDelaySec * 1000))ms)" : "arrival")\n"
                            .utf8,
                    ),
                )
        }
    }

    /// Submits a freshly decoded frame to the tail of the jitter buffer. If the buffer has
    /// grown past ``maxDepth`` (producer outran the display), the OLDEST frames are dropped
    /// so latency cannot accumulate — we catch up to "now" rather than playing stale frames.
    public func submit(_ frame: CVImageBuffer) {
        submitForTest(frame, now: Self.currentHostTimeSeconds())
    }

    /// TEST SEAM (internal — don't churn the public surface for tests): the full production
    /// ``submit(_:)`` body with the monotonic clock injected, so the depth-v2 policy's
    /// time-windowed promote/demote is drivable from a virtual-clock unit test.
    func submitForTest(_ frame: CVImageBuffer, now: Double) {
        if deadlineMode {
            lock.lock()
            depthPolicy.noteArrival(now) // telemetry parity (depth action never engages in deadline mode)
            let deadline = Self.deadlineForArrival(
                arrival: now,
                lastDeadline: lastPresentDeadline,
                interval: contentIntervalSec,
                playoutDelay: playoutDelaySec,
            )
            pendingFrame = frame // latest-wins: a post-stall bunch shows the newest
            pendingDeadline = deadline
            pendingSubmittedAt = now
            lock.unlock()
            return
        }
        lock.lock()
        let handle = nextHandle
        nextHandle &+= 1
        images[handle] = frame
        let submission = withUnsafePointer(to: record) { slopdesk_present_queue_submit($0, handle, now) }
        record = submission.queue
        // The hard cap's own eviction: the law says WHICH handle it dropped, so the image behind it
        // is released here and nowhere else.
        if submission.has_evicted { images.removeValue(forKey: submission.evicted) }
        let queueWasEmpty = submission.was_empty
        // Adaptive: one decoded-FRAME arrival = one jitter sample (correct cadence for a
        // FRAME-denominated depth). Fold it and let the controller re-recommend liveDepth;
        // maxDepth (the hard cap trim above) stays the backstop.
        var depthChangeLine: String?
        if adaptiveJitter {
            jitter.note(arrival: now)
            let before = liveDepth
            let jitterMs = jitter.jitterSeconds * 1000
            // `controller` is a value-type with a MUTATING method on an optional stored property;
            // `guard let` would mutate a COPY and silently drop the depth update. adaptiveJitter ⇒ non-nil.
            // swiftlint:disable:next force_unwrapping
            adoptLiveDepthLocked(controller!.noteFrame(jitterSeconds: jitter.jitterSeconds))
            if Self.dbgEnabled, liveDepth != before {
                depthChangeLine = "SlopDesk[video.client]: jitter depth \(before)→\(liveDepth) (arrival jitter \(String(format: "%.1f", jitterMs))ms)\n"
            }
        }
        // One decoded-frame arrival feeds the v2 policy's interval estimator + dense gate (telemetry
        // always; the demote evaluation inside fires BEFORE the pacer re-primes on a post-idle
        // resume, so the boost doesn't cost one extra held frame at resume).
        depthPolicy.noteArrival(now)
        if adaptiveDepthV2, let line = applyPolicyDepthLocked() { depthChangeLine = line }
        // Starved-display fast path (header: PRESENT-ON-ARRIVAL). Decided under the lock, ACTED on
        // after unlock: the present must run on the main actor (render path), so hop there and run
        // the no-throttle present. The hop is sub-ms when this fires (sparse content ⇒ idle main loop).
        let presentNow = Self.shouldPresentOnArrival(
            enabled: presentOnArrival,
            queueWasEmpty: queueWasEmpty,
            queueCount: Int(record.len),
            liveDepth: liveDepth,
        )
        lock.unlock()
        if let depthChangeLine {
            FileHandle.standardError.write(Data(depthChangeLine.utf8))
        }
        if presentNow {
            Task { @MainActor [weak self] in self?.presentNow() }
        }
    }

    /// Called under ``lock``: consume the v2 policy's recommended depth. PROMOTE re-primes
    /// (`primed = false`) so the slack frame is actually BUILT — without it, depth 2 only disables
    /// present-on-arrival and changes trim limits but holds no standing frame. DEMOTE is plain:
    /// homeostasis trims the extra frame and the present-on-arrival gate re-arms by itself (both
    /// read ``liveDepth``). Returns the debug depth-change line (nil outside `SLOPDESK_VIDEO_DEBUG`
    /// / when depth did not move) for the CALLER to write AFTER `lock.unlock()` — this is reachable
    /// from the decode-thread ``submit(_:)`` path, and a blocking stderr write must never happen
    /// under the pacer lock.
    private func applyPolicyDepthLocked() -> String? {
        let desired = depthPolicy.depth
        guard desired != liveDepth else { return nil }
        let before = liveDepth
        record = withUnsafePointer(to: record) {
            slopdesk_present_queue_set_live_depth($0, UInt32(clamping: desired))
        }
        guard Self.dbgEnabled else { return nil }
        return "SlopDesk[video.client]: jitter depth \(before)→\(desired) (v3 owd-late)\n"
    }

    /// Called under ``lock``: consume the ARRIVAL-JITTER controller's recommended depth. This is
    /// the other depth door — bounded, but never re-priming. That controller re-recommends on every
    /// frame and every underrun, and holding the picture that often is a change the user would see;
    /// the two controllers are mutually exclusive (see the `resolvedAdaptiveJitter` precedence at
    /// construction), so the two rules never both apply to one pacer.
    private func adoptLiveDepthLocked(_ depth: Int) {
        record = withUnsafePointer(to: record) {
            slopdesk_present_queue_adopt_live_depth($0, UInt32(clamping: depth))
        }
    }

    /// Folds one NETWORK-late event (the session's `OwdLateDetector` flagged an owd spike past the
    /// path baseline) into the depth policy — the promotion/demotion source. Lock-guarded and
    /// synchronous; callable straight from the session actor (same contract as ``drainTelemetry()``).
    /// The depth action applies immediately so a promote re-primes before the next present, not one
    /// arrival later.
    public func noteNetworkLate() {
        noteNetworkLateForTest(now: Self.currentHostTimeSeconds())
    }

    /// TEST SEAM (internal, see ``submitForTest(_:now:)``): ``noteNetworkLate()`` with the clock injected.
    func noteNetworkLateForTest(now: Double) {
        var depthChangeLine: String?
        lock.lock()
        depthPolicy.noteNetworkLate(now)
        if adaptiveDepthV2, let line = applyPolicyDepthLocked() { depthChangeLine = line }
        lock.unlock()
        if let depthChangeLine {
            FileHandle.standardError.write(Data(depthChangeLine.utf8))
        }
    }

    /// Drains the windowed presentation-health counters + the live depth gauge for one NetworkStats
    /// report. Lock-guarded and synchronous — callable straight from the session actor with no main
    /// hop (the pacer is `@unchecked Sendable` with its own lock).
    public func drainTelemetry() -> PacerTelemetrySnapshot {
        lock.lock()
        defer { lock.unlock() }
        let (late, gaps) = depthPolicy.drainCounters()
        return PacerTelemetrySnapshot(lateFrames: late, presentGaps: gaps, depth: record.live_depth)
    }

    /// PURE present-on-arrival decision (unit-tested): fire whenever an arrival lands in an EMPTY
    /// queue and completes the live depth — present on decode, the Parsec model.
    /// `queueWasEmpty && queueCount >= liveDepth` is only satisfiable at `liveDepth == 1` (after an
    /// empty-queue append, `queueCount == 1`), so depth ≥ 2 keeps the pure vsync cadence untouched.
    ///
    /// Do NOT add an `underflowRun >= 1` ("display already starved") requirement to scope this to
    /// sparse content: a THROTTLED tick returns before incrementing `underflowRun`, so that gate
    /// races the arrival and usually loses — measured on HW it barely fires even in the DENSE
    /// regime, leaving hold at p50≈8ms/p90≈20ms (pure tick-wait). Firing unconditionally is safe:
    /// a second present inside one vsync slot is queued to the next refresh by Core Animation
    /// (when the tick would have shown it anyway), and it still consumes the cadence slot so the
    /// link tick right after is throttled.
    public static func shouldPresentOnArrival(
        enabled: Bool,
        queueWasEmpty: Bool,
        queueCount: Int,
        liveDepth: Int,
    ) -> Bool {
        slopdesk_present_should_present_on_arrival(
            enabled,
            queueWasEmpty,
            UInt32(clamping: queueCount),
            UInt32(clamping: liveDepth),
        )
    }

    /// The no-throttle present behind present-on-arrival. ⚠️ Main-actor only (the render callback
    /// and `lastRenderHostTime` are main-confined). Deliberately BYPASSES the ``shouldRender`` cap —
    /// the display-link re-shows the last frame every vsync, so `lastRenderHostTime` is almost
    /// always < one interval old and the cap would veto the very present this path exists for.
    /// Instead it CONSUMES the cadence slot (stamps `lastRenderHostTime`), so the next link tick
    /// throttles and aggregate render rate stays ≤ ``maxFrameRate``. Racing link tick already
    /// drained the queue? `frameForVSync` degrades to a re-show of the last frame — a visual no-op.
    private func presentNow() {
        let now = Self.currentHostTimeSeconds()
        // Under a vsync-LOCKED present the compositor holds a presented drawable until its refresh,
        // and the layer has two: a third `nextDrawable()` inside one refresh blocks MAIN — the
        // thread that dispatches every key and pointer event — until the next vsync. A second
        // arrival inside half an interval is therefore left for the tick, which presents it at the
        // next refresh, exactly where vsync would have put it. The unlocked default never blocks
        // here and keeps its present-on-arrival.
        if Self.presentIsVsyncLocked, now - lastRenderHostTime < 0.5 / maxFrameRate {
            needsRedisplay = true
            return
        }
        lastRenderHostTime = now
        if let frame = frameForVSync(), frame !== lastRenderedFrame || needsRedisplay {
            lastRenderedFrame = frame
            needsRedisplay = false
            renderCallback(frame)
        }
    }

    /// Whether a present waits for the panel's refresh: always on iOS, and on macOS only under
    /// `SLOPDESK_VSYNC=1` — the same reading `MetalVideoRenderer` makes when it decides
    /// `displaySyncEnabled`, resolved once because neither changes while the app runs.
    private static let presentIsVsyncLocked: Bool = {
        #if os(macOS)
        EnvConfig.string("SLOPDESK_VSYNC") == "1"
        #else
        true
        #endif
    }()

    /// Forces the next tick/present to render even if the frame object is unchanged. Call on
    /// layout/scale changes (the layer geometry changed under the same content). ⚠️ Main-confined
    /// (same as the render path it arms).
    public func setNeedsRedisplay() {
        needsRedisplay = true
    }

    /// FPS GOVERNOR: rebase the content-cadence assumptions on a host fps change (the
    /// `streamCadence` control message). Lock-guarded; callable off-main. Default arrival-mode
    /// pacing is fps-agnostic (present-on-arrival), so this rebases only (a) the deadline-mode
    /// rhythm interval and (b) the adaptive controller's seconds→frames conversion — the controller
    /// is recreated at the new fps PRESERVING its live depth (depth is path knowledge; a cadence
    /// change must not dump or inflate the buffer). The tick rate (``maxFrameRate``) is deliberately
    /// NOT lowered — it stays display-native.
    public func setContentFps(_ fps: Double) {
        lock.lock()
        contentIntervalSec = 1.0 / max(1.0, fps)
        // The queue's own slot ratio follows the announced cadence: a host stepped 60→30 by the
        // encode-load pacer doubles the ticks a depth-2 slack frame is held for, or it is handed
        // out on the next tick and the slack is gone.
        record = withUnsafePointer(to: record) {
            slopdesk_present_queue_set_ticks_per_frame($0, slopdesk_present_ticks_per_frame(maxFrameRate, fps))
        }
        if adaptiveJitter, let c = controller {
            controller = AdaptiveJitterController(
                minDepth: 1,
                maxDepth: maxDepth,
                fps: max(1.0, fps),
                initialDepth: c.targetDepth,
            )
        }
        // Pin the v2 policy's expected interval to the announced cadence — an INSTANT late-threshold
        // rebase (no ~8-arrival estimator transient, no false late at the crossover). The governor
        // re-announces on every step, so the hint tracks the live fps.
        depthPolicy.setIntervalHint(1.0 / max(1.0, fps))
        lock.unlock()
    }

    /// Feeds one live network-jitter sample (seconds, the session's RFC3550 EWMA) to the adaptive
    /// playout buffer. No-op unless adaptive playout is active (deadline mode + no fixed override).
    /// On a slow (~1s) cadence it recomputes ``playoutDelaySec`` via the Rust-core law (grow-fast /
    /// shrink-slow) so the buffer auto-tunes to the link. Lock-guarded (written here, read in the
    /// deadline ``submit`` branch under the same ``lock``); safe to call off-main per fragment — the
    /// cadence gate throttles the actual recompute. Feeding the EWMA (not the raw delta) keeps a
    /// single post-idle spike from jumping the buffer to the ceiling.
    public func notePlayoutJitter(_ jitterSeconds: Double) {
        lock.lock()
        defer { lock.unlock() }
        guard adaptivePlayout else { return }
        let gate = slopdesk_present_playout_recompute_due(UInt32(clamping: playoutJitterSampleCount))
        playoutJitterSampleCount = Int(gate.next_samples)
        guard gate.due else { return }
        recomputePlayoutLocked(jitterSeconds: jitterSeconds)
    }

    /// Test seam: recompute every call (no cadence gate) so a deterministic test drives convergence.
    func notePlayoutJitterForTest(_ jitterSeconds: Double) {
        lock.lock()
        defer { lock.unlock() }
        guard adaptivePlayout else { return }
        recomputePlayoutLocked(jitterSeconds: jitterSeconds)
    }

    /// Live playout (ms) for assertions/telemetry. Lock-guarded.
    func playoutDelayMsForTest() -> Double {
        lock.lock()
        defer { lock.unlock() }
        return playoutDelaySec * 1000.0
    }

    /// Steps ``playoutDelaySec`` toward the jitter-sized target via the Rust-core law. MUST hold ``lock``.
    private func recomputePlayoutLocked(jitterSeconds: Double) {
        let nextMs = AdaptivePlayoutPolicy.stepMs(
            jitterSeconds: jitterSeconds,
            prevPlayoutMs: playoutDelaySec * 1000.0,
            shrinkStepMs: playoutShrinkStepMs,
            k: playoutK,
            baseMs: playoutBaseMs,
            floorMs: playoutFloorMs,
            ceilMs: playoutCeilMs,
        )
        let clamped = slopdesk_present_clamped_playout_seconds(nextMs / 1000.0)
        if Self.dbgEnabled, abs(clamped - playoutDelaySec) > 1e-6 {
            let line = "SlopDesk[video.client]: playout J=\(Int((jitterSeconds * 1000).rounded()))ms" +
                " → \(String(format: "%.1f", clamped * 1000))ms\n"
            FileHandle.standardError.write(Data(line.utf8))
        }
        playoutDelaySec = clamped
    }

    /// One VSync step: decide which frame to present (pure; the GUI link calls this).
    /// Returns the next queued frame in order, or the last shown while priming / on an
    /// empty buffer, or `nil` if nothing has ever been decoded yet.
    public func frameForVSync() -> CVImageBuffer? {
        frameForVSyncForTest(now: Self.currentHostTimeSeconds())
    }

    /// TEST SEAM (internal, see ``submitForTest(_:now:)``): the production ``frameForVSync()``
    /// body with the monotonic clock injected.
    func frameForVSyncForTest(now: Double) -> CVImageBuffer? {
        // v2 depth-change line collected under the lock, WRITTEN by this defer AFTER the unlock:
        // defers run LIFO, so this one (registered before the lock defer) executes after it —
        // the same write-after-unlock discipline as `depthChangeLine` in ``submitForTest``.
        var depthChangeLine: String?
        defer { if let depthChangeLine { FileHandle.standardError.write(Data(depthChangeLine.utf8)) } }
        lock.lock()
        defer { lock.unlock() }
        // One refresh of the law: priming, HOMEOSTASIS, the present, the underflow run and the
        // `max(2, liveDepth)` re-prime floor are all inside this one fold — see the module header
        // of `rust/slopdesk-video`'s `present_queue` for why each is shaped the way it is.
        let step = withUnsafePointer(to: record) { slopdesk_present_queue_step($0) }
        record = step.queue
        // Homeostasis trimmed these to reach the frame it chose; the law names them, so the images
        // behind them are released here rather than inferred from a queue order this side no longer
        // keeps.
        for obsolete in Self.handles(step.dropped, step.dropped_len) { images.removeValue(forKey: obsolete) }
        switch step.kind {
        case SLOPDESK_PRESENT_PRESENT:
            guard let next = images.removeValue(forKey: step.frame.handle) else { return lastShownFrame }
            lastShownFrame = next
            // One CONTENT present = one gap classification (telemetry always; the depth action only
            // when v2 is engaged).
            depthPolicy.notePresent(now)
            if adaptiveDepthV2, let line = applyPolicyDepthLocked() { depthChangeLine = line }
            if Self.dbgEnabled { dbgNoteHold(since: step.frame.submitted_at, now: now) }
            // A present that follows ≥1 empty vsync WHILE STILL PRIMED is a real (transient)
            // starvation → grow. The law reports it as false after an IDLE re-prime, so host
            // idle-skips never inflate the buffer (the precise idle-vs-underrun discriminator).
            if adaptiveJitter, step.transient_dip {
                let before = liveDepth
                // Mutating value-type method on the optional stored property — see noteFrame above.
                // swiftlint:disable:next force_unwrapping
                adoptLiveDepthLocked(controller!.noteUnderrun())
                if Self.dbgEnabled, liveDepth != before {
                    FileHandle.standardError
                        .write(Data("SlopDesk[video.client]: jitter depth \(before)→\(liveDepth) (underrun)\n".utf8))
                }
            }
            return next
        case SLOPDESK_PRESENT_RESHOW:
            // Underflow: producer fell behind (idle-skip or stall). Re-present last. An empty-queue
            // re-show may OPEN a late-gap episode (counted once per episode inside the policy) — the
            // hitch is recorded as it happens, even if no frame ever resolves it (motion stop).
            depthPolicy.noteReshow(now)
            // Reset the jitter estimator at the idle transition the law just declared: otherwise the
            // long idle gap becomes a huge inter-arrival → a spurious 2nd-difference spike on resume
            // → the buffer inflates on every stop→scroll, defeating the latency reclaim.
            if step.re_primed, adaptiveJitter { jitter = OWDJitterEstimator() }
            return lastShownFrame
        case SLOPDESK_PRESENT_HOLD:
            // A tick between two content slots on a panel faster than the content: the slack frame
            // keeps waiting for its slot. Not a re-show for the telemetry — the queue is not empty.
            return lastShownFrame
        default:
            // Priming: hold (re-show last, nil before the first decode) while the slack is built.
            return lastShownFrame
        }
    }

    /// The live prefix of a crossing's handle array. A C array is a TUPLE in Swift, so it is read
    /// through its own bytes rather than subscripted.
    private static func handles(_ carried: some Any, _ count: Int) -> [UInt64] {
        withUnsafeBytes(of: carried) { raw in Array(raw.bindMemory(to: UInt64.self).prefix(count)) }
    }

    /// TEST SEAM (also useful under `SLOPDESK_VIDEO_DEBUG`): the live presentation depth, read
    /// under ``lock``. With adaptive off this always equals ``targetDepth``.
    var currentDepth: Int { lock.lock()
        defer { lock.unlock() }
        return liveDepth
    }

    /// TEST SEAM: the adaptive v1 controller's fps — its seconds→frames conversion UNIT. Pinned to
    /// the CONTENT fps at construction AND after a ``setContentFps(_:)`` rebase (never the display
    /// tick rate, which would flip the unit on the first `streamCadence` message). nil when
    /// adaptive is off. Read under ``lock``.
    var controllerFpsForTest: Double? { lock.lock()
        defer { lock.unlock() }
        return controller?.fps
    }

    /// Debug-only (called under ``lock``): fold one frame's REAL pacer hold (submit → first present)
    /// and emit a ~2s-windowed `p50/p90/max` stderr line — the ground-truth presentation-latency
    /// metric for HW A/Bs. The in-lock stderr write is debug mode only, microseconds.
    private func dbgNoteHold(since submittedAt: Double, now: Double) {
        // Stutter-ladder stage 5: a >28ms gap between two CONTENT presents = the user-visible hitch
        // itself (one content interval at 60fps is 16.7ms; >28ms means a frame slot went empty).
        // Read against stages 1-4 (host-side) to see which segment created the hole.
        if dbgLastPresentAt > 0, now - dbgLastPresentAt > 0.028 {
            FileHandle.standardError
                .write(Data("SlopDesk[video.client]: present gap \(Int((now - dbgLastPresentAt) * 1000))ms\n".utf8))
        }
        dbgLastPresentAt = now
        dbgHolds.append(now - submittedAt)
        if dbgHoldsWindowStart == 0 { dbgHoldsWindowStart = now }
        guard now - dbgHoldsWindowStart >= 2.0 else { return }
        let sorted = dbgHolds.sorted()
        let ms = { (v: Double) in String(format: "%.1f", v * 1000) }
        let line = "SlopDesk[video.client]: pacer hold n=\(sorted.count) p50=\(ms(sorted[sorted.count / 2]))ms p90=\(ms(sorted[min(sorted.count - 1, (sorted.count * 9) / 10)]))ms max=\(ms(sorted[sorted.count - 1]))ms\n"
        FileHandle.standardError.write(Data(line.utf8))
        dbgHolds.removeAll(keepingCapacity: true)
        dbgHoldsWindowStart = now
    }

    /// VSync handler: pull the frame and render it, honouring the frame-rate cap.
    /// Called by the display-link driver each refresh (and directly from tests).
    public func tick(hostTimeSeconds: Double = currentHostTimeSeconds()) {
        if deadlineMode {
            // Deadline path: the schedule IS the cadence — no shouldRender cap (presents are
            // ≤ content fps by construction: one pending slot, deadlines spaced ≥ interval).
            lock.lock()
            let due = pendingFrame != nil && Self.deadlineDue(
                deadline: pendingDeadline,
                now: hostTimeSeconds,
                halfTick: 0.5 / max(1.0, maxFrameRate),
            )
            let frame = due ? pendingFrame : nil
            let submittedAt = pendingSubmittedAt
            if due {
                lastPresentDeadline = pendingDeadline // advance by the SCHEDULE, not by `now`
                pendingFrame = nil
                depthPolicy.notePresent(hostTimeSeconds) // telemetry only: no depth action in deadline mode
                if Self.dbgEnabled { dbgNoteHold(since: submittedAt, now: hostTimeSeconds) }
            }
            lock.unlock()
            if let frame {
                lastRenderedFrame = frame
                // REAL codec frame present: it already contains the scrolled content, so reset the
                // hint offset to zero BEFORE the render (never double-count). No-op when off.
                resetReprojectionOnRealFrame()
                renderCallback(frame)
            } else {
                // BETWEEN-CONTENT tick (the would-be identity-skip / no-frame-due slot): if the
                // feature is on, advance the hint offset and re-present the last frame WITH it.
                reprojectBetweenContentTick(now: hostTimeSeconds)
            }
            return
        }
        guard Self.shouldRender(now: hostTimeSeconds, lastRender: lastRenderHostTime, maxFrameRate: maxFrameRate) else {
            return // throttle: a display refresh faster than the GUI cap is skipped
        }
        lastRenderHostTime = hostTimeSeconds
        if let frame = frameForVSync(), frame !== lastRenderedFrame || needsRedisplay {
            // A genuinely NEW frame object is a real codec present → reset the hint (no double-count).
            // A `needsRedisplay`-forced re-render of the SAME frame is NOT a new codec frame, so it
            // must NOT reset — it just re-applies the current offset under the changed layer.
            let isNewFrame = frame !== lastRenderedFrame
            lastRenderedFrame = frame
            needsRedisplay = false
            if isNewFrame { resetReprojectionOnRealFrame() }
            renderCallback(frame)
        } else {
            // BETWEEN-CONTENT tick (identity-skip re-show): advance + re-present with the hint offset.
            reprojectBetweenContentTick(now: hostTimeSeconds)
        }
    }

    /// SCROLL-HINT REPROJECTION — a between-content (would-be identity-skip / no-frame-due) tick.
    /// No-op unless the feature is on. Integrates the local scroll velocity over the REAL elapsed
    /// since the last reproject tick, applies the resulting normalized offset to the renderer, and
    /// re-presents the last frame so the picture keeps moving at display rate between codec frames.
    /// Skips the re-present while the offset is exactly zero AND was already zero (nothing to shift),
    /// so a static window with the feature on still does the cheap identity-skip. Main-confined.
    private func reprojectBetweenContentTick(now: Double) {
        guard let reprojector, let applyReprojection, let frame = lastRenderedFrame else { return }
        let elapsed = lastReprojTickTime > 0 ? now - lastReprojTickTime : 0
        lastReprojTickTime = now
        let (ox, oy) = reprojector.advance(elapsedSeconds: elapsed)
        let offset = SIMD2<Float>(Float(ox), Float(oy))
        let nonZero = ox != 0 || oy != 0
        // Re-present only when there is (or just was) a shift to show — otherwise stay an identity
        // re-show. The `reprojOffsetActive` latch lets the FINAL settle-to-zero tick repaint once.
        guard nonZero || reprojOffsetActive else { return }
        reprojOffsetActive = nonZero
        applyReprojection(offset) // set the renderer's offset uniform…
        renderCallback(frame) // …then re-present the SAME last frame with the shift, this vsync
    }

    /// SCROLL-HINT REPROJECTION — a real codec frame is being presented: reset the hint offset to
    /// exactly zero so the new frame's own scrolled content is never double-counted. No-op unless the
    /// feature is on. Clears the renderer offset back to `(0, 0)` (the real frame is the authoritative
    /// position) when a hint was active. Main-confined.
    private func resetReprojectionOnRealFrame() {
        guard let reprojector else { return }
        reprojector.noteRealFrame()
        lastReprojTickTime = 0 // restart the elapsed baseline at the fresh frame
        if reprojOffsetActive, let applyReprojection {
            reprojOffsetActive = false
            applyReprojection(.zero) // set offset 0 ONLY; the renderCallback right after presents the new frame un-shifted
        }
    }

    /// PURE deadline computation (unit-tested). First frame (`lastDeadline == 0`) schedules
    /// `arrival + playoutDelay`. Steady state extends the CONTENT rhythm: `lastDeadline +
    /// interval` — anchored to the schedule, NOT the arrival, so ±jitter on arrivals does not
    /// modulate presentation spacing. STALL CATCH-UP: when the rhythm has fallen more than one
    /// interval behind the arrival (a 50-150ms network stall just ended), re-anchor at
    /// `arrival + playoutDelay` instead of fast-forwarding through the backlog.
    public static func deadlineForArrival(
        arrival: Double,
        lastDeadline: Double,
        interval: Double,
        playoutDelay: Double,
    ) -> Double {
        slopdesk_present_deadline_for_arrival(arrival, lastDeadline, interval, playoutDelay)
    }

    /// PURE present decision (unit-tested): present at the first tick whose half-period
    /// lookahead covers the deadline (a "just missed" deadline waits ≤ half a tick, never a
    /// full one).
    public static func deadlineDue(deadline: Double, now: Double, halfTick: Double) -> Bool {
        slopdesk_present_deadline_due(deadline, now, halfTick)
    }

    /// PURE tick-rate resolution (unit-tested): the display link runs at the display's native
    /// refresh so a decoded frame waits at most one NATIVE interval for a tick, not one content
    /// interval (8.3 ms vs 16.7 ms worst-case on ProMotion). `floor` is the host content fps —
    /// the rate below which we never drop even if the screen reports something degenerate (0 on
    /// an unknown/headless screen). `SLOPDESK_TICK_HZ` overrides for A/B, clamped to a sane band.
    public static func resolveTickRate(envOverride: String?, displayMaxHz: Int, floor: Double) -> Double {
        let hz = UInt32(clamping: displayMaxHz)
        guard let raw = envOverride else { return slopdesk_present_resolve_tick_rate(nil, 0, hz, floor) }
        // The override is borrowed for the call and parsed on the far side: a bad one, an empty one
        // and an absent one are one answer there, not three spellings of it here.
        return Array(raw.utf8).withUnsafeBytes { bytes in
            slopdesk_present_resolve_tick_rate(
                bytes.baseAddress?.assumingMemoryBound(to: CChar.self),
                bytes.count,
                hz,
                floor,
            )
        }
    }

    /// Pure cap decision: render only when at least `1/maxFrameRate` seconds elapsed
    /// since the last render (a small slack absorbs vsync jitter so we don't drop one
    /// extra frame to rounding). `lastRender == 0` ⇒ first tick always renders.
    /// Unit-testable without a display link.
    public static func shouldRender(now: Double, lastRender: Double, maxFrameRate: Double) -> Bool {
        slopdesk_present_should_render(now, lastRender, maxFrameRate)
    }

    // MARK: Display-link driver (GUI-only; never created in tests)

    /// Monotonic host time in seconds (vsync timestamp source). Pure read.
    public static func currentHostTimeSeconds() -> Double {
        CACurrentMediaTime()
    }

    #if os(macOS)
    /// Starts the display link driving ``tick()`` at the display's refresh rate, via the modern,
    /// NON-deprecated `NSView.displayLink(target:selector:)` (macOS 14+, the `CVDisplayLink`
    /// replacement). Bound to `view`'s screen and run on the main run loop (like iOS's
    /// `CADisplayLink`), so the cap throttle + render path are consistent across OSes. ⚠️ GUI-only
    /// — needs a view on screen; NEVER called from a test. `@MainActor`:
    /// `NSView.displayLink(target:selector:)` is main-actor API and the returned `CADisplayLink` is
    /// main-confined; the pipeline calls this on the main actor.
    @preconcurrency
    @MainActor
    public func start(view: NSView) {
        guard displayLink == nil else { return }
        let proxy = DisplayLinkProxy(self)
        self.proxy = proxy
        let link = view.displayLink(target: proxy, selector: #selector(DisplayLinkProxy.step))
        configureCadence(link)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    #elseif canImport(UIKit)
    /// Starts the `CADisplayLink` driving ``tick()`` at the display's refresh rate, capped to
    /// ``maxFrameRate`` via the throttle in ``tick()``. `view` is accepted for signature parity
    /// with the macOS path (and so the link's screen could be derived later); iOS constructs the
    /// `CADisplayLink` directly. ⚠️ GUI-only — needs a run loop + a screen; NEVER called from a test.
    @preconcurrency
    @MainActor
    public func start(view: UIView) {
        guard displayLink == nil else { return }
        _ = view // parity with macOS NSView.displayLink; the link runs on the main loop
        let proxy = DisplayLinkProxy(self)
        self.proxy = proxy
        let link = CADisplayLink(target: proxy, selector: #selector(DisplayLinkProxy.step))
        configureCadence(link)
        link.add(to: RunLoop.main, forMode: .common)
        displayLink = link
    }
    #endif

    #if canImport(QuartzCore)
    /// Hints the system toward ``maxFrameRate`` (the display-native tick rate) so the link
    /// fires every native refresh. The ``tick()`` throttle is the authoritative cap; this
    /// just lets the OS pace the link efficiently.
    @MainActor
    private func configureCadence(_ link: CADisplayLink) {
        link.preferredFrameRateRange = CAFrameRateRange(
            minimum: 15,
            maximum: Float(maxFrameRate),
            preferred: Float(maxFrameRate),
        )
    }

    /// Stops + releases the display link. `@MainActor`: the link is main-confined.
    @preconcurrency
    @MainActor
    public func stop() {
        displayLink?.invalidate()
        displayLink = nil
        proxy = nil
    }
    #endif
}
#endif
