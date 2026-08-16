import CSlopDeskFFI

/// The Swift face of `rust/slopdesk-video`'s `scroll_resample`, reached through the door of the
/// same name.
///
/// ## Why this exists
///
/// Chromium renders SYNTHETIC (injected) smooth-scroll at a rate that climbs with the INJECTION
/// event rate, only saturating at the display's 60 fps around ~250 Hz (4× vsync): 60 Hz-inject → 20
/// fps, 125 Hz → 35 fps, 250 Hz → 60 fps. Below ~3× vsync the events alias with the compositor and
/// most 16.7 ms frames land zero events. The remote scroll path injects at the client trackpad rate
/// (~60–120 Hz), made burstier by network jitter, so VS Code scroll renders a juddery ~20–35 fps.
/// (Capture and encode are already 60 fps; the source app CAN render 60 fps — it's the inject rate.)
///
/// ## What it does — pure, deterministic, total-preserving
///
/// ``ingest(dx:dy:scrollPhase:momentumPhase:continuous:)`` folds each arriving wire scroll event;
/// ``drain()`` is called on a fixed OUTPUT cadence (the caller's ~250 Hz timer) and returns the next
/// integer-pixel sub-event to post.
///
///   * **Markers pass through 1:1** — Began / Ended / Cancelled / momentum-Began / momentum-End
///     carry gesture lifecycle + rubber-band semantics, so `ingest` returns them IMMEDIATELY and
///     only the high-volume *continuous* portion is resampled.
///   * **The continuous stream (Changed / momentum-Continue) accumulates** into a per-axis residual
///     and `drain` emits a portion each output tick — `residual / spread`, lag-capped so a fast
///     flick drains within a few ticks instead of lagging, with the sub-pixel fraction CARRIED so
///     the summed output equals the summed input (to <1 px/axis/gesture).
///
/// A STRUCT, because the injector holds one inline and mutates it on its own serial queue — which
/// is exactly why the state crosses by value: six scalars, and the arithmetic that must not be
/// spelled twice (the whole-pixel truncation that carries its fraction, the lag-cap drain and its
/// one-pixel floor) is spelled once, on the far side. The host wires it behind a 4 ms timer
/// (`InputInjector`); this layer owns nothing but the crossing.
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

    /// The law's default knobs, from the door, so neither language writes the numbers down twice.
    private static let defaults = slopdesk_scroll_resampler_defaults()
    /// Fraction divisor: each `drain` emits ~`residual / spread`, so the residual drains over
    /// ~`spread` ticks (≈ a one-tick lead lag at the output rate). 2 ⇒ ~half per tick. Larger =
    /// smoother but laggier; smaller = snappier but coarser.
    public static var defaultSpread: Double { defaults.spread }
    /// Per-axis lag cap (px): if the residual exceeds this, `drain` emits enough to bring it back
    /// down to the cap THIS tick, so a fast flick never lags by more than ~this (≈ one frame's
    /// travel) while a slow scroll still spreads smoothly.
    public static var defaultLagCap: Double { defaults.lag_cap }

    /// Both knobs, the per-axis residual and the phase the continuations are stamped with.
    private var record: SlopDeskScrollResampler

    /// Builds a resampler. Both knobs are sanitized on the far side into a sane band, so a hostile
    /// value can't stall or over-emit.
    public init(spread: Double = Self.defaultSpread, lagCap: Double = Self.defaultLagCap) {
        record = slopdesk_scroll_resampler_new(spread, lagCap)
    }

    /// True when there is no continuous residual left to drain (the caller can suspend its timer).
    public var isIdle: Bool { slopdesk_scroll_resampler_is_idle(record) }

    /// Folds one arriving wire scroll event. Returns any MARKER sub-events to post IMMEDIATELY
    /// (gesture-lifecycle / momentum boundary events pass through 1:1, preserving exact phase
    /// fidelity); the continuous portion is accumulated and surfaces later via ``drain()``.
    /// Non-finite deltas are dropped (treated as 0) so a bad sample can't poison the residual.
    ///
    /// At most two come back, and only when the marker ENDS the gesture: the pending residual is
    /// flushed AHEAD of the marker, under its current pre-flip phase, so no later timer tick can
    /// drain leftover pixels after the End — a `Changed`-after-`Ended` (phase 2 after 4) corrupts
    /// AppKit and Chromium rubber-banding alike.
    public mutating func ingest(
        dx: Double, dy: Double, scrollPhase: UInt8, momentumPhase: UInt8, continuous: Bool,
    ) -> [SubEvent] {
        let answered = slopdesk_scroll_resampler_ingest(
            record, dx, dy, scrollPhase, momentumPhase, continuous,
        )
        record = answered.resampler
        return Self.markers(answered.events, answered.count)
    }

    /// Emits the next resampled continuation sub-event, or `nil` when the residual is drained. Call
    /// on the fixed output cadence (the host's ≈250 Hz timer). The phase reflects whether the
    /// latest continuous samples were finger-driven (scroll-Changed) or an inertial coast
    /// (momentum-Continue).
    public mutating func drain() -> SubEvent? {
        let tick = slopdesk_scroll_resampler_drain(record)
        record = tick.resampler
        return tick.emitted ? Self.subEvent(tick.event) : nil
    }

    /// Fully resets the resampler (drops any residual) — call when a pane loses focus / the session
    /// tears down so a stale half-pixel can't resume on the next gesture.
    public mutating func reset() {
        record = slopdesk_scroll_resampler_reset(record)
    }

    /// The answered pair, read down to the count the door filled. A C array is a TUPLE in Swift, so
    /// the only way to walk one is over its bytes — the layout is `SlopDeskScrollSubEvent`'s by
    /// construction, and `count` is bounded by the array itself on the far side.
    private static func markers(_ carried: some Any, _ count: Int) -> [SubEvent] {
        withUnsafeBytes(of: carried) { raw in
            raw.bindMemory(to: SlopDeskScrollSubEvent.self).prefix(count).map(subEvent)
        }
    }

    /// One sub-event as the door answered it.
    private static func subEvent(_ answered: SlopDeskScrollSubEvent) -> SubEvent {
        SubEvent(
            dx: answered.dx,
            dy: answered.dy,
            scrollPhase: answered.scroll_phase,
            momentumPhase: answered.momentum_phase,
            continuous: answered.continuous,
        )
    }
}
