// Resamples a bursty, low-rate remote scroll stream into a STEADY high-rate (≈250 Hz) output so a
// captured Chromium/Electron window renders smooth-scroll at the full display rate.
//
// ## Why this exists (HW-measured 2026-06-19)
//
// Chromium renders SYNTHETIC (injected) smooth-scroll at a rate that climbs with the INJECTION event
// rate, only saturating at the display's 60 fps around ~250 Hz (4× vsync): 60 Hz-inject → 20 fps,
// 125 Hz → 35 fps, 250 Hz → 60 fps. Below ~3× vsync the events alias with the compositor and most
// 16.7 ms frames land zero events. The remote scroll path injects at the client trackpad rate
// (~60–120 Hz), made burstier by network jitter, so VS Code scroll renders ~20–35 fps → "giật".
// (Capture and encode are already 60 fps; the source app CAN render 60 fps — it's the inject rate.)
//
// ## What it does — pure, deterministic, total-preserving
//
// `ingest(...)` folds each arriving wire scroll event; `drain(...)` is called on a fixed OUTPUT
// cadence (the caller's ~250 Hz timer) and returns the next integer-pixel sub-event to post.
//
//   * **Markers pass through 1:1** — Began / Ended / Cancelled / momentum-Began / momentum-End carry
//     gesture lifecycle + rubber-band semantics; `ingest` returns them IMMEDIATELY (preserving the
//     exact phase fidelity the direct path already had), so only the high-volume *continuous* portion
//     is resampled.
//   * **The continuous stream (Changed / momentum-Continue) accumulates** into a per-axis residual and
//     `drain` emits a portion each output tick — `residual / spread`, lag-capped so a fast flick
//     drains within a few ticks instead of lagging, with the sub-pixel fraction CARRIED so the summed
//     output equals the summed input (to <1 px/axis/gesture).
//
// No wall clock, no env, no I/O — fully testable. The host wires it behind a 4 ms timer
// (`InputInjector`); this layer owns only the math + the gesture-phase bookkeeping.

/// Pure resampler that turns a bursty low-rate scroll stream into a steady high-rate one. Not
/// thread-safe by itself — the host confines it to one serial queue (ingest + drain on the same
/// queue), so it needs no internal locking.
public struct ScrollResampler {
    /// One integer-pixel scroll sub-event to post, carrying the CoreGraphics phase codes verbatim.
    public struct SubEvent: Equatable, Sendable {
        /// Horizontal / vertical pixel delta (whole pixels; the resampler carries the fraction).
        public var dx: Double
        public var dy: Double
        /// `CGScrollPhase` code (1 Began, 2 Changed, 4 Ended, 8 Cancelled, 0 = none/momentum).
        public var scrollPhase: UInt8
        /// `CGMomentumScrollPhase` code (1 Began, 2 Continue, 3 End, 0 = none).
        public var momentumPhase: UInt8
        /// The precise/continuous (trackpad) flag, forwarded from the wire.
        public var continuous: Bool

        public init(dx: Double, dy: Double, scrollPhase: UInt8, momentumPhase: UInt8, continuous: Bool) {
            self.dx = dx
            self.dy = dy
            self.scrollPhase = scrollPhase
            self.momentumPhase = momentumPhase
            self.continuous = continuous
        }
    }

    // CGScrollPhase / CGMomentumScrollPhase code constants (the wire carries these verbatim).
    private static let scrollChanged: UInt8 = 2
    private static let momentumContinue: UInt8 = 2
    private static let momentumBegan: UInt8 = 1
    private static let momentumEnd: UInt8 = 3
    private static let scrollEnded: UInt8 = 4
    private static let scrollCancelled: UInt8 = 8

    /// Fraction divisor: each `drain` emits ~`residual / spread`, so the residual drains over ~`spread`
    /// ticks (≈ a one-tick lead lag at the output rate). 2 ⇒ ~half per tick. Larger = smoother but
    /// laggier; smaller = snappier but coarser.
    private let spread: Double
    /// Per-axis lag cap (px): if the residual exceeds this, `drain` emits enough to bring it back down
    /// to the cap THIS tick, so a fast flick never lags by more than ~`lagCap` px (≈ one frame's
    /// travel) while a slow scroll still spreads smoothly.
    private let lagCap: Double

    /// Per-axis un-emitted continuous residual (carries the sub-pixel fraction between ticks).
    private var resX: Double = 0
    private var resY: Double = 0
    /// True while the latest continuous samples are an inertial coast (momentum) vs finger-driven, so a
    /// resampled continuation carries momentum-Continue rather than scroll-Changed.
    private var coasting: Bool = false
    /// The precise/continuous flag of the latest sample, stamped on resampled continuations.
    private var continuousFlag: Bool = false

    /// Builds a resampler. `spread` (default 2) and `lagCap` (default 48 px) shape the drain curve;
    /// both are sanitized to a sane band so a hostile value can't stall or over-emit.
    public init(spread: Double = 2.0, lagCap: Double = 48.0) {
        self.spread = (spread.isFinite && spread >= 1.0) ? min(spread, 16.0) : 2.0
        self.lagCap = (lagCap.isFinite && lagCap >= 1.0) ? min(lagCap, 4096.0) : 48.0
    }

    /// True when there is no continuous residual left to drain (the caller can suspend its timer).
    public var isIdle: Bool { resX.magnitude < 1.0 && resY.magnitude < 1.0 }

    /// Folds one arriving wire scroll event. Returns any MARKER sub-events to post IMMEDIATELY
    /// (gesture-lifecycle / momentum boundary events pass through 1:1, preserving exact phase
    /// fidelity); the continuous portion is accumulated and surfaces later via `drain`. Non-finite
    /// deltas are dropped (treated as 0) so a bad sample can't poison the residual.
    public mutating func ingest(
        dx: Double, dy: Double, scrollPhase: UInt8, momentumPhase: UInt8, continuous: Bool,
    ) -> [SubEvent] {
        let dx = dx.isFinite ? dx : 0
        let dy = dy.isFinite ? dy : 0
        continuousFlag = continuous

        // The high-volume CONTINUOUS portion (finger Changed or momentum Continue) is what we resample:
        // accumulate it and let `drain` meter it out at the output rate.
        if scrollPhase == Self.scrollChanged {
            resX += dx
            resY += dy
            coasting = false
            return []
        }
        if momentumPhase == Self.momentumContinue {
            resX += dx
            resY += dy
            coasting = true
            return []
        }

        // A MARKER (Began / Ended / Cancelled / momentum Began / momentum End). If it ENDS the gesture,
        // FLUSH any pending residual FIRST — as a continuation under its CURRENT (pre-flip) phase — so a
        // later timer tick can never drain leftover pixels AFTER the End marker, which would be a
        // malformed `Changed`-after-`Ended` (phase 2 after 4) that corrupts AppKit/Chromium
        // rubber-banding. Other markers (Began) just pass through verbatim.
        var out: [SubEvent] = []
        let endsGesture = scrollPhase == Self.scrollEnded
            || scrollPhase == Self.scrollCancelled
            || momentumPhase == Self.momentumEnd
        if endsGesture, let flush = flushResidual() { out.append(flush) }

        if momentumPhase == Self.momentumBegan { coasting = true }
        if endsGesture { coasting = false }
        out.append(SubEvent(
            dx: dx, dy: dy, scrollPhase: scrollPhase, momentumPhase: momentumPhase, continuous: continuous,
        ))
        return out
    }

    /// Emits ALL pending residual as one final continuation sub-event (whole pixels; the <1 px fraction
    /// is dropped), stamped with the CURRENT continuation phase, and zeroes the residual. Used to drain
    /// a gesture's leftover BEFORE its End marker, so residual never outlives the phase that produced it.
    /// `nil` when there is <1 px/axis to flush.
    private mutating func flushResidual() -> SubEvent? {
        let ex = resX.rounded(.towardZero)
        let ey = resY.rounded(.towardZero)
        resX = 0
        resY = 0
        if ex == 0, ey == 0 { return nil }
        return SubEvent(
            dx: ex,
            dy: ey,
            scrollPhase: coasting ? 0 : Self.scrollChanged,
            momentumPhase: coasting ? Self.momentumContinue : 0,
            continuous: continuousFlag,
        )
    }

    /// Emits the next resampled continuation sub-event, or `nil` when the residual is drained. Call on
    /// the fixed output cadence (the host's ≈250 Hz timer). The phase reflects whether the latest
    /// continuous samples were finger-driven (scroll-Changed) or an inertial coast (momentum-Continue).
    public mutating func drain() -> SubEvent? {
        let ex = Self.drainAxis(&resX, spread: spread, lagCap: lagCap)
        let ey = Self.drainAxis(&resY, spread: spread, lagCap: lagCap)
        if ex == 0, ey == 0 { return nil }
        return SubEvent(
            dx: ex,
            dy: ey,
            scrollPhase: coasting ? 0 : Self.scrollChanged,
            momentumPhase: coasting ? Self.momentumContinue : 0,
            continuous: continuousFlag,
        )
    }

    /// Fully resets the resampler (drops any residual) — call when a pane loses focus / the session
    /// tears down so a stale half-pixel can't resume on the next gesture.
    public mutating func reset() {
        resX = 0
        resY = 0
        coasting = false
        continuousFlag = false
    }

    /// Drains one axis by one output tick: emits `residual / spread` (≥1 px so it always makes
    /// progress, ≤ residual so it never over-shoots), but at least `residual − lagCap` so a large
    /// residual (fast flick) drains down to the lag cap THIS tick. Sub-pixel residual (<1 px) is held
    /// (returned 0) and CARRIED so the integer outputs sum to the float input. Mutates the residual.
    private static func drainAxis(_ res: inout Double, spread: Double, lagCap: Double) -> Double {
        let mag = res.magnitude
        if mag < 1.0 { return 0 } // sub-pixel: hold + carry (never emit a fractional pixel)
        let byFraction = mag / spread // the smooth ~half-per-tick drain
        let byLagCap = mag - lagCap // bring an over-large residual back to the cap this tick
        // Emit at least 1 px (progress), at most the whole residual (no overshoot), choosing the FASTER
        // of the fraction / lag-cap drains so a flick doesn't crawl.
        let emitMag = min(mag, max(max(byFraction, byLagCap), 1.0))
        let emit = (res > 0 ? emitMag : -emitMag).rounded(.towardZero) // whole pixels; fraction stays
        res -= emit
        return emit
    }
}
