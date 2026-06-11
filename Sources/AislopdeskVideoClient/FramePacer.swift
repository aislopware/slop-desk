#if canImport(QuartzCore) && canImport(CoreVideo)
import Foundation
import CoreVideo
import QuartzCore
import OSLog
#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Drives display from VSync (`CADisplayLink`), NOT decode-completion (doc 17 §3.7).
///
/// ⚠️ **GUI-ONLY** for the `CADisplayLink` path (needs a run loop + a screen).
/// COMPILED + reviewed; not driven from tests.
///
/// Pacing policy — small JITTER BUFFER (2026-06-08, motion-smoothness):
/// - The decoder pushes decoded frames into ``submit(_:)``; they queue oldest-first.
/// - Presentation HOLDS until the buffer first fills to ``targetDepth`` (priming),
///   establishing a few frames of slack. Thereafter each VSync presents ONE frame in
///   order — converting bursty / variable arrival into a steady one-per-vsync cadence.
/// - The slack absorbs the arrival/decode latency SPIKE at a static→motion transition
///   (idle = tiny 1.5 KB frames → scroll = 40–220 KB frames): without it the previous
///   "present newest / skip-late" pacer re-showed the last frame for a tick = the
///   "khựng khựng on idle-then-scroll" judder. (This is the Parsec/Moonlight render-ahead.)
/// - HOMEOSTASIS: presentation never carries more than ``targetDepth`` frames (drops the
///   oldest excess), so steady-state depth — and thus added latency — settles at
///   ≈targetDepth/fps instead of ratcheting up to ``maxDepth`` under sustained motion or
///   clock skew. ``maxDepth`` is a submit-side hard backstop. An empty buffer re-presents
///   the last frame (no judder beyond a single repeat).
/// - RE-PRIME: the host idle-skips static frames, so during any idle the buffer drains to
///   empty. After a sustained dry spell the pacer drops back to priming, so the slack is
///   REBUILT before the next scroll — making every stop→scroll transition smooth, not just
///   the first of a session.
/// - PRESENT-ON-ARRIVAL (2026-06-10, select-text latency; widened same day to PRESENT-ON-DECODE):
///   when an arriving frame lands in an empty queue and completes the depth, present it
///   IMMEDIATELY instead of holding it for the next vsync tick — reclaiming the tick-wait on
///   EVERY frame at depth 1 (sparse highlight/typing AND the dense scroll stream; the Parsec
///   model). Only reachable at `liveDepth == 1` (at depth ≥ 2 an empty-queue arrival can never
///   complete the depth). The immediate present consumes the cadence slot (`lastRenderHostTime`),
///   so the link tick that follows is throttled and re-shows never pile on. Disable via
///   `AISLOPDESK_PRESENT_ON_ARRIVAL=0` for A/B (pure vsync cadence).
/// - DISPLAY-NATIVE TICK (2026-06-10, latency audit): ``maxFrameRate`` is now resolved to the
///   DISPLAY's native refresh (``resolveTickRate``), not hard-locked to the host's content fps.
///   On a 120 Hz panel the link ticks every 8.3 ms, halving the worst-case hold of a frame that
///   arrives mid-interval. Composition effect at depth 1 with 60 fps content: the tick BETWEEN
///   two arrivals drains the queue (underflowRun becomes 1), so the NEXT arrival satisfies the
///   present-on-arrival gate — the dense stream presents on decode (Parsec model) with the
///   8.3 ms tick as fallback cadence. `AISLOPDESK_PRESENT_ON_ARRIVAL=0` ⇒ pure 120 Hz-quantized
///   cadence (avg hold ≈ 4.2 ms); `AISLOPDESK_TICK_HZ` overrides the resolved rate for A/B.
///   Steady 60 fps content never reaches the re-prime threshold (underflowRun oscillates 0↔1,
///   occasionally 2 — and a depth-1 re-prime is satisfied by the very next arrival, no hold).
///
/// The queue policy is pure and unit-testable in isolation; the `CADisplayLink` wiring
/// is GUI-only. Trade-off: ~``targetDepth`` frames of added latency (≈targetDepth/fps s)
/// bought for smoothness — the same trade Parsec makes. Both depths are env-tunable from
/// the construction site (``VideoWindowPipeline``) via `AISLOPDESK_JITTER_DEPTH` / `_MAX`.
public final class FramePacer: @unchecked Sendable {
    /// Called each VSync with the frame to draw (the next queued, or the last shown when
    /// the buffer is empty / still priming). `nil` only before the first frame.
    public typealias RenderCallback = @Sendable (CVImageBuffer) -> Void

    private let log = Logger(subsystem: "aislopdesk.video.client", category: "FramePacer")
    /// Depth-change observability for the adaptive controller (env `AISLOPDESK_VIDEO_DEBUG`): one
    /// stderr line per liveDepth transition, so an HW A/B can verify the buffer actually
    /// floats down to 1 on a clean link (or see what jitter is pinning it higher).
    private static let dbgEnabled = ProcessInfo.processInfo.environment["AISLOPDESK_VIDEO_DEBUG"] != nil
    private let renderCallback: RenderCallback
    private let lock = NSLock()
    /// Jitter buffer: decoded frames awaiting presentation, oldest first. Drained one per
    /// vsync; the oldest are dropped if it grows past ``maxDepth`` (bounded latency).
    private var queue: [CVImageBuffer] = []
    /// The last frame shown — re-presented while priming or on an empty buffer.
    private var lastShownFrame: CVImageBuffer?
    /// False until the buffer reaches ``targetDepth``; while false we hold (re-show last) so
    /// the slack that absorbs jitter is established before steady presentation. RESET to false
    /// after a SUSTAINED dry spell (``underflowRun`` ≥ `max(2, liveDepth)` — a real idle, since the
    /// host idle-skips static frames, NOT a transient single-frame dip during scroll), so the
    /// slack is REBUILT before motion resumes. This is what makes EVERY stop→scroll transition
    /// smooth, not only the first of a session. (The `max(2, …)` floor keeps re-prime strictly
    /// above the single-vsync transient-dip detector even at the adaptive floor `liveDepth == 1`.)
    private var primed = false
    /// Consecutive vsyncs the buffer has been empty (underflow). Reaching `max(2, liveDepth)` means
    /// a genuine producer stall/idle (re-prime); reset to 0 on any presented frame.
    private var underflowRun = 0
    /// Submit timestamps in LOCKSTEP with ``queue`` (same appends/removeFirsts), so the dequeue
    /// site can measure the REAL pacer hold (submit → first present) of each frame. The earlier
    /// attempt to validate present-on-arrival via the host's `clientHoldMs` telemetry measured
    /// arrival staleness at the 50ms report timer — useless for presentation latency. Guarded
    /// by ``lock``.
    private var queueSubmittedAt: [Double] = []
    /// Debug-only (``dbgEnabled``): per-frame pacer holds for the current ~2s window; drained
    /// into one stderr line (`pacer hold p50/p90/max`) so an HW A/B can read the REAL
    /// presentation latency. Guarded by ``lock``.
    private var dbgHolds: [Double] = []
    private var dbgHoldsWindowStart: Double = 0
    /// KHỰNG-ladder stage 5 (``dbgEnabled``): last CONTENT-present time. Guarded by ``lock``.
    private var dbgLastPresentAt: Double = 0

    /// Frames to buffer before presentation begins. The absorbed arrival/decode jitter is
    /// ≈ this many frames; it is also the steady-state added latency (≈ targetDepth / fps).
    public let targetDepth: Int
    /// Hard cap on buffered frames; beyond it the oldest are dropped so latency cannot grow.
    public let maxDepth: Int

    /// The display-link tick rate AND render-rate cap. Resolved at the construction site via
    /// ``resolveTickRate`` to the DISPLAY's native refresh (120 on ProMotion), floored at the
    /// host content fps. Renders never exceed it; actual content presents are bounded by what
    /// the host produces (60 fps), so a 120 Hz tick costs only cheap re-shows, not extra content
    /// work — while halving how long an arriving frame can sit waiting for the next tick.
    public let maxFrameRate: Double

    /// Whether the adaptive jitter-buffer controller is engaged (env `AISLOPDESK_ADAPTIVE_JITTER`).
    /// When false the buffer is a FIXED ``targetDepth``, byte-identical to the pre-adaptive
    /// pacer: ``liveDepth`` is never reassigned, ``controller`` is nil, and arrival jitter is
    /// never measured.
    private let adaptiveJitter: Bool
    /// The LIVE presentation depth the priming / homeostasis / re-prime logic reads. Equals
    /// ``targetDepth`` when adaptive is off; otherwise the controller's recommendation.
    /// ⚠️ MUTABLE — mutated AND read ONLY under ``lock`` (``submit`` writes it via the
    /// controller; ``frameForVSync`` reads it at the 3 depth sites and writes it on underrun).
    /// Do NOT read it from ``tick()`` (which runs unlocked) — go through ``frameForVSync()`` or
    /// the locked ``currentDepth`` accessor, or you reintroduce the data race the queue avoids.
    private var liveDepth: Int
    /// Client-clock arrival-jitter estimator, fed ONE sample per decoded-frame ``submit``
    /// (adaptive only). Guarded by ``lock``. RESET at a re-prime-on-idle transition so the long
    /// idle gap is not folded as a spurious jitter spike that would re-inflate on every resume.
    private var jitter = OWDJitterEstimator()
    /// The adaptive depth controller (nil when adaptive is off). Guarded by ``lock``.
    private var controller: AdaptiveJitterController?
    /// Present-on-arrival for a starved display (see the header). Construction-time constant.
    private let presentOnArrival: Bool

    // MARK: DEADLINE PACER (2026-06-10, the Parsec-smoothness research round)
    //
    // Both prior modes schedule presentation off ARRIVAL events (drain-on-vsync, or
    // present-on-decode), so network jitter passes straight into inter-presentation intervals —
    // the "bunched frame" stutter: two frames arrive inside one vsync window, drain on
    // consecutive 8.3ms ticks, then a hole (8/8/17/8ms instead of 16.7 flat). The fix, per
    // WebRTC `VCMTiming` + the Moonlight/cloud-gaming literature: anchor each frame's
    // presentation DEADLINE to the CONTENT rhythm — `lastDeadline + contentInterval` — with a
    // small playout delay absorbing jitter, and present at the first tick past the deadline.
    // CRITICAL: the anchor advances by the SCHEDULED deadline, never the actual present time,
    // so a late tick cannot accumulate schedule drift. Latest-frame-wins on the single pending
    // slot (a post-stall bunch shows the newest frame, not a fast-forward replay).
    // Enabled via `AISLOPDESK_PACER=deadline`; `AISLOPDESK_PLAYOUT_MS` tunes the delay (default 20).
    private let deadlineMode: Bool
    private let contentIntervalSec: Double
    private let playoutDelaySec: Double
    /// Single pending frame + its deadline (latest-wins). Guarded by ``lock``.
    private var pendingFrame: CVImageBuffer?
    private var pendingDeadline: Double = 0
    private var pendingSubmittedAt: Double = 0
    /// The content-rhythm anchor: the last SCHEDULED present deadline (0 ⇒ none yet). ``lock``.
    private var lastPresentDeadline: Double = 0

    // On BOTH platforms the modern driver is a `CADisplayLink`: macOS 14+ exposes
    // `NSView.displayLink(target:selector:)` (the non-deprecated replacement for
    // `CVDisplayLink`, run-loop driven like iOS), and iOS uses `CADisplayLink`
    // directly. A tiny `@objc` proxy forwards each vsync into ``tick()``.
    #if canImport(QuartzCore)
    private var displayLink: CADisplayLink?
    /// A small target object the `CADisplayLink` retains; it forwards to ``tick()``.
    private final class DisplayLinkProxy: NSObject {
        let pacer: FramePacer
        init(_ pacer: FramePacer) { self.pacer = pacer }
        @objc func step() { pacer.tick() }
    }
    private var proxy: DisplayLinkProxy?
    #endif

    /// Tracks the elapsed time so the cap throttles ticks below the display refresh.
    private var lastRenderHostTime: Double = 0
    /// The frame object last handed to ``renderCallback`` (main-confined, like
    /// `lastRenderHostTime`). Re-presenting the SAME object is a visual no-op, so ``tick()``
    /// SKIPS the render — at a 120 Hz link with 60 fps content half the ticks are empty
    /// re-shows, and rendering them burned ~1 ms of main-thread/GPU work per 8.3 ms slot,
    /// delaying the present-on-decode main-actor hops this pacer now relies on.
    private var lastRenderedFrame: CVImageBuffer?
    /// Forces the next tick to render even an identical frame (main-confined). Set via
    /// ``setNeedsRedisplay()`` on layout/scale changes, where the LAYER changed under an
    /// unchanged frame.
    private var needsRedisplay = false

    public init(maxFrameRate: Double = 60.0, targetDepth: Int = 2, maxDepth: Int = 5, adaptiveJitter: Bool = false, presentOnArrival: Bool = true,
                deadlineMode: Bool = false, contentFps: Double = 60.0, playoutDelayMs: Double = 20.0,
                renderCallback: @escaping RenderCallback) {
        self.presentOnArrival = presentOnArrival
        self.deadlineMode = deadlineMode
        self.contentIntervalSec = 1.0 / max(1.0, contentFps)
        self.playoutDelaySec = min(200.0, max(0.0, playoutDelayMs)) / 1000.0
        self.maxFrameRate = maxFrameRate
        let clampedTarget = max(1, targetDepth)
        let clampedMax = max(clampedTarget, maxDepth)
        self.targetDepth = clampedTarget
        self.maxDepth = clampedMax
        self.adaptiveJitter = adaptiveJitter
        // OFF ⇒ liveDepth stays == targetDepth forever (controller nil, never consulted) ⇒
        // the fixed-depth path is byte-identical to before this feature.
        self.liveDepth = clampedTarget
        self.controller = adaptiveJitter
            ? AdaptiveJitterController(minDepth: 1, maxDepth: clampedMax, fps: maxFrameRate, initialDepth: clampedTarget)
            : nil
        self.renderCallback = renderCallback
        if Self.dbgEnabled {
            FileHandle.standardError.write(Data("Aislopdesk[video.client]: pacer up — tick=\(Int(maxFrameRate))Hz depth=\(clampedTarget) adaptive=\(adaptiveJitter) presentOnArrival=\(presentOnArrival) mode=\(deadlineMode ? "deadline(playout=\(Int(playoutDelaySec * 1000))ms)" : "arrival")\n".utf8))
        }
    }

    /// Submits a freshly decoded frame to the tail of the jitter buffer. If the buffer has
    /// grown past ``maxDepth`` (producer outran the display), the OLDEST frames are dropped
    /// so latency cannot accumulate — we catch up to "now" rather than playing stale frames.
    public func submit(_ frame: CVImageBuffer) {
        if deadlineMode {
            let now = Self.currentHostTimeSeconds()
            lock.lock()
            let deadline = Self.deadlineForArrival(arrival: now, lastDeadline: lastPresentDeadline,
                                                   interval: contentIntervalSec, playoutDelay: playoutDelaySec)
            pendingFrame = frame          // latest-wins: a post-stall bunch shows the newest
            pendingDeadline = deadline
            pendingSubmittedAt = now
            lock.unlock()
            return
        }
        lock.lock()
        let queueWasEmpty = queue.isEmpty
        queue.append(frame)
        queueSubmittedAt.append(Self.currentHostTimeSeconds())
        if queue.count > maxDepth {
            queueSubmittedAt.removeFirst(queue.count - maxDepth)
            queue.removeFirst(queue.count - maxDepth)
        }
        // Adaptive: one decoded-FRAME arrival = one jitter sample (correct cadence for a
        // FRAME-denominated depth). Fold it and let the controller re-recommend liveDepth.
        // maxDepth (the hard cap trim above) is unchanged — it stays the backstop.
        var depthChangeLine: String?
        if adaptiveJitter {
            jitter.note(arrival: Self.currentHostTimeSeconds())
            let before = liveDepth
            let jitterMs = jitter.jitterSeconds * 1000
            liveDepth = controller!.noteFrame(jitterSeconds: jitter.jitterSeconds)
            if Self.dbgEnabled && liveDepth != before {
                depthChangeLine = "Aislopdesk[video.client]: jitter depth \(before)→\(liveDepth) (arrival jitter \(String(format: "%.1f", jitterMs))ms)\n"
            }
        }
        // Starved-display fast path (header: PRESENT-ON-ARRIVAL). Decided under the lock,
        // ACTED on after unlock: the present itself must run on the main actor (render path),
        // so hop there and run the no-throttle present. The hop is sub-ms exactly when this
        // fires (sparse content ⇒ idle main loop).
        let presentNow = Self.shouldPresentOnArrival(enabled: presentOnArrival,
                                                     queueWasEmpty: queueWasEmpty,
                                                     queueCount: queue.count,
                                                     liveDepth: liveDepth)
        lock.unlock()
        if let depthChangeLine {
            FileHandle.standardError.write(Data(depthChangeLine.utf8))
        }
        if presentNow {
            Task { @MainActor [weak self] in self?.presentNow() }
        }
    }

    /// PURE present-on-arrival decision (unit-tested): fire whenever an arrival lands in an
    /// EMPTY queue and completes the live depth — i.e. present on decode, the Parsec model.
    /// `queueWasEmpty && queueCount >= liveDepth` is only satisfiable at `liveDepth == 1`
    /// (after an empty-queue append, `queueCount == 1`), so depth ≥ 2 configurations keep the
    /// pure vsync cadence untouched.
    ///
    /// HISTORY (2026-06-10): the first version also required `underflowRun >= 1` ("display
    /// already starved"), intending to scope this to sparse content. MEASURED on HW it barely
    /// fired in the DENSE regime either: a THROTTLED tick returns before incrementing
    /// `underflowRun`, so at any tick rate the gate raced the arrival and usually lost —
    /// live hold telemetry stayed at p50≈8ms/p90≈20ms (pure tick-wait). Dropping the starved
    /// requirement is safe: a second present inside one vsync slot is simply queued to the
    /// next refresh by Core Animation (exactly when the tick would have shown it), and the
    /// present still consumes the cadence slot so the link tick right after is throttled.
    public static func shouldPresentOnArrival(enabled: Bool, queueWasEmpty: Bool,
                                              queueCount: Int, liveDepth: Int) -> Bool {
        enabled && queueWasEmpty && queueCount >= liveDepth
    }

    /// The no-throttle present behind present-on-arrival. ⚠️ Main-actor only (the render
    /// callback and `lastRenderHostTime` are main-confined). Deliberately BYPASSES the
    /// ``shouldRender`` cap — the display-link re-shows the last frame every vsync, so
    /// `lastRenderHostTime` is almost always < one interval old and the cap would veto the
    /// very present this path exists for. Instead it CONSUMES the cadence slot (stamps
    /// `lastRenderHostTime`), so the next link tick throttles and the aggregate render rate
    /// stays ≤ ``maxFrameRate``. Racing link tick already drained the queue? `frameForVSync`
    /// degrades to a re-show of the last frame — visually a no-op.
    private func presentNow() {
        lastRenderHostTime = Self.currentHostTimeSeconds()
        if let frame = frameForVSync(), frame !== lastRenderedFrame || needsRedisplay {
            lastRenderedFrame = frame
            needsRedisplay = false
            renderCallback(frame)
        }
    }

    /// Forces the next tick/present to render even if the frame object is unchanged. Call on
    /// layout/scale changes (the layer geometry changed under the same content). ⚠️ Main-confined
    /// (same as the render path it arms).
    public func setNeedsRedisplay() {
        needsRedisplay = true
    }

    /// One VSync step: decide which frame to present (pure; the GUI link calls this).
    /// Returns the next queued frame in order, or the last shown while priming / on an
    /// empty buffer, or `nil` if nothing has ever been decoded yet.
    public func frameForVSync() -> CVImageBuffer? {
        lock.lock(); defer { lock.unlock() }
        // NOTE: all depth reads below use `liveDepth` (== targetDepth when adaptive is off, so
        // this path is unchanged; the controller's live recommendation when on).
        if !primed {
            // (Re)prime: hold (re-show last) until the buffer fills to liveDepth, (re)building the
            // jitter slack BEFORE steady presentation. Re-entered after a sustained dry spell (below),
            // so the slack is rebuilt ahead of every stop→scroll resume — not just once per session.
            // This also resets underflowRun to 0, which the transient-dip discriminator below relies on.
            if queue.count >= liveDepth { primed = true; underflowRun = 0 } else { return lastShownFrame }
        }
        // Homeostasis: never carry MORE than liveDepth frames — drop the OLDEST excess so steady-state
        // depth (hence added latency) settles at ≈ liveDepth/fps instead of ratcheting up to maxDepth
        // under sustained motion / clock skew. Catches up to the freshest within the slack window.
        if queue.count > liveDepth {
            queueSubmittedAt.removeFirst(queue.count - liveDepth)
            queue.removeFirst(queue.count - liveDepth)
        }
        if !queue.isEmpty {
            // Capture the transient-dip flag BEFORE resetting underflowRun: a present that follows ≥1
            // empty vsync WHILE STILL PRIMED is a real (transient) starvation → grow. After an IDLE
            // re-prime, underflowRun was reset to 0 at the priming gate above, so this is false ⇒ host
            // idle-skips never inflate the buffer (the precise idle-vs-underrun discriminator).
            let wasTransientDip = underflowRun > 0
            let next = queue.removeFirst()
            let submittedAt = queueSubmittedAt.removeFirst()
            lastShownFrame = next
            underflowRun = 0
            if Self.dbgEnabled { dbgNoteHold(since: submittedAt) }
            if adaptiveJitter && wasTransientDip {
                let before = liveDepth
                liveDepth = controller!.noteUnderrun()
                if Self.dbgEnabled && liveDepth != before {
                    FileHandle.standardError.write(Data("Aislopdesk[video.client]: jitter depth \(before)→\(liveDepth) (underrun)\n".utf8))
                }
            }
            return next
        }
        // Underflow: producer fell behind (idle-skip or stall). Re-present last. After a SUSTAINED dry
        // spell (empty ≥ max(2, liveDepth) vsyncs ⇒ a real idle, not a transient scroll dip) drop back
        // to priming so slack is rebuilt before motion resumes.
        //
        // FLOOR: the threshold is max(2, …), NOT max(1, …), so it stays STRICTLY above the transient-dip
        // detector (a single empty vsync, `wasTransientDip = underflowRun > 0` above). At the adaptive
        // floor liveDepth == 1 (the steady state a clean link drives toward) the two would otherwise
        // COLLIDE at 1: the first empty vsync would re-prime (resetting underflowRun + wiping the jitter
        // estimator) before the next present could see underflowRun > 0, so neither grow path (noteUnderrun
        // nor noteFrame) could ever fire — the buffer would pin at 1 with single-frame-repeat judder and
        // no self-healing as a clean LAN degrades. Keeping re-prime ≥ 2 means a single dip at the floor is
        // still classified transient (→ grows via noteUnderrun), while 2+ empty vsyncs is still a real idle.
        // For liveDepth ≥ 2 this is identical to the old max(1, liveDepth) == liveDepth (no behaviour change).
        underflowRun += 1
        if underflowRun >= max(2, liveDepth) {
            primed = false
            // Reset the jitter estimator at the idle transition: otherwise the long idle gap becomes a
            // huge inter-arrival → a spurious 2nd-difference spike on resume → the buffer inflates on
            // every stop→scroll, defeating the latency reclaim.
            if adaptiveJitter { jitter = OWDJitterEstimator() }
        }
        return lastShownFrame
    }

    /// TEST SEAM (also useful under `AISLOPDESK_VIDEO_DEBUG`): the live presentation depth, read
    /// under ``lock``. With adaptive off this always equals ``targetDepth``.
    var currentDepth: Int { lock.lock(); defer { lock.unlock() }; return liveDepth }

    /// Debug-only (called under ``lock``): fold one frame's REAL pacer hold (submit → first
    /// present) and emit a ~2s-windowed `p50/p90/max` stderr line. This is the ground-truth
    /// presentation-latency metric for HW A/Bs (the wire `clientHoldMs` is arrival staleness,
    /// not pacer hold). The in-lock stderr write matches the depth-change line's precedent —
    /// debug mode only, microseconds.
    private func dbgNoteHold(since submittedAt: Double) {
        let now = Self.currentHostTimeSeconds()
        // KHỰNG-ladder stage 5: a >28ms gap between two CONTENT presents = the user-visible hitch
        // itself (one content interval at 60fps is 16.7ms; >28ms means a frame slot went empty).
        // Read against stages 1-4 to see which segment created the hole.
        if dbgLastPresentAt > 0, now - dbgLastPresentAt > 0.028 {
            FileHandle.standardError.write(Data("Aislopdesk[video.client]: present gap \(Int((now - dbgLastPresentAt) * 1000))ms\n".utf8))
        }
        dbgLastPresentAt = now
        dbgHolds.append(now - submittedAt)
        if dbgHoldsWindowStart == 0 { dbgHoldsWindowStart = now }
        guard now - dbgHoldsWindowStart >= 2.0 else { return }
        let sorted = dbgHolds.sorted()
        let ms = { (v: Double) in String(format: "%.1f", v * 1000) }
        let line = "Aislopdesk[video.client]: pacer hold n=\(sorted.count) p50=\(ms(sorted[sorted.count / 2]))ms p90=\(ms(sorted[min(sorted.count - 1, (sorted.count * 9) / 10)]))ms max=\(ms(sorted[sorted.count - 1]))ms\n"
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
            let due = pendingFrame != nil && Self.deadlineDue(deadline: pendingDeadline, now: hostTimeSeconds,
                                                              halfTick: 0.5 / max(1.0, maxFrameRate))
            let frame = due ? pendingFrame : nil
            let submittedAt = pendingSubmittedAt
            if due {
                lastPresentDeadline = pendingDeadline   // advance by the SCHEDULE, not by `now`
                pendingFrame = nil
                if Self.dbgEnabled { dbgNoteHold(since: submittedAt) }
            }
            lock.unlock()
            if let frame {
                lastRenderedFrame = frame
                renderCallback(frame)
            }
            return
        }
        guard Self.shouldRender(now: hostTimeSeconds, lastRender: lastRenderHostTime, maxFrameRate: maxFrameRate) else {
            return // throttle: a display refresh faster than the GUI cap is skipped
        }
        lastRenderHostTime = hostTimeSeconds
        if let frame = frameForVSync(), frame !== lastRenderedFrame || needsRedisplay {
            lastRenderedFrame = frame
            needsRedisplay = false
            renderCallback(frame)
        }
    }

    /// PURE deadline computation (unit-tested). First frame (`lastDeadline == 0`) schedules
    /// `arrival + playoutDelay`. Steady state extends the CONTENT rhythm: `lastDeadline +
    /// interval` — anchored to the schedule, NOT the arrival, so ±jitter on arrivals does not
    /// modulate presentation spacing. STALL CATCH-UP: when the rhythm has fallen more than one
    /// interval behind the arrival (a 50-150ms network stall just ended), re-anchor at
    /// `arrival + playoutDelay` instead of fast-forwarding through the backlog.
    public static func deadlineForArrival(arrival: Double, lastDeadline: Double,
                                          interval: Double, playoutDelay: Double) -> Double {
        guard lastDeadline > 0 else { return arrival + playoutDelay }
        let next = lastDeadline + interval
        if next < arrival - interval { return arrival + playoutDelay }
        return next
    }

    /// PURE present decision (unit-tested): present at the first tick whose half-period
    /// lookahead covers the deadline (a "just missed" deadline waits ≤ half a tick, never a
    /// full one).
    public static func deadlineDue(deadline: Double, now: Double, halfTick: Double) -> Bool {
        deadline <= now + halfTick
    }

    /// PURE tick-rate resolution (unit-tested): the display link runs at the display's native
    /// refresh so a decoded frame waits at most one NATIVE interval for a tick, not one content
    /// interval (8.3 ms vs 16.7 ms worst-case on ProMotion). `floor` is the host content fps —
    /// the rate below which we never drop even if the screen reports something degenerate (0 on
    /// an unknown/headless screen). `AISLOPDESK_TICK_HZ` overrides for A/B, clamped to a sane band.
    public static func resolveTickRate(envOverride: String?, displayMaxHz: Int, floor: Double) -> Double {
        if let raw = envOverride, let hz = Double(raw), hz.isFinite {
            return min(240, max(30, hz))
        }
        return max(floor, Double(displayMaxHz))
    }

    /// Pure cap decision: render only when at least `1/maxFrameRate` seconds elapsed
    /// since the last render (a small slack absorbs vsync jitter so we don't drop one
    /// extra frame to rounding). `lastRender == 0` ⇒ first tick always renders.
    /// Unit-testable without a display link.
    public static func shouldRender(now: Double, lastRender: Double, maxFrameRate: Double) -> Bool {
        guard maxFrameRate > 0 else { return true }
        guard lastRender > 0 else { return true }
        let minInterval = 1.0 / maxFrameRate
        // 0.5 ms slack so a refresh landing a hair early still counts (avoids a
        // beat-frequency stutter between the display vsync and the cap interval).
        return (now - lastRender) >= (minInterval - 0.0005)
    }

    // MARK: Display-link driver (GUI-only; never created in tests)

    /// Monotonic host time in seconds (vsync timestamp source). Pure read.
    public static func currentHostTimeSeconds() -> Double {
        CACurrentMediaTime()
    }

    #if os(macOS)
    /// Starts the display link driving ``tick()`` at the display's refresh rate, using
    /// the modern, NON-deprecated `NSView.displayLink(target:selector:)` (macOS 14+) —
    /// the replacement for `CVDisplayLink`. It is bound to `view`'s screen and runs on
    /// the main run loop (like iOS's `CADisplayLink`), so the cap throttle + render path
    /// are consistent across OSes. ⚠️ GUI-only — needs a view on screen; NEVER called
    /// from a test. `@MainActor`: `NSView.displayLink(target:selector:)` is main-actor
    /// API and the returned `CADisplayLink` is main-confined; the pipeline calls this on
    /// the main actor.
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
    /// Starts the `CADisplayLink` driving ``tick()`` at the display's refresh rate,
    /// capped to ``maxFrameRate`` via the throttle in ``tick()``. `view` is accepted for
    /// signature parity with the macOS path (and so the link's screen could be derived
    /// later); iOS constructs the `CADisplayLink` directly.
    /// ⚠️ GUI-only — needs a run loop + a screen; NEVER called from a test.
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
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: Float(maxFrameRate), preferred: Float(maxFrameRate))
    }

    /// Stops + releases the display link. `@MainActor`: the link is main-confined.
    @MainActor
    public func stop() {
        displayLink?.invalidate()
        displayLink = nil
        proxy = nil
    }
    #endif
}
#endif
