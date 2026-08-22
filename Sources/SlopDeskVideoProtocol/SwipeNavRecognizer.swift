import CSlopDeskFFI
import Foundation

/// Recognises a two-finger "swipe between pages" flick in the forwarded scroll stream and
/// answers with the history-navigation direction it should be TRANSLATED into (⌘[ / ⌘]).
///
/// WHY A TRANSLATION EXISTS AT ALL: a synthetic phased scroll can NEVER trigger the browser's
/// own swipe-back. Chromium's HistorySwiper needs real `NSTouch` data (trackpad path) or routes
/// into `trackSwipeEventWithOptions:` (Magic-Mouse path), and both reject CGEvent-posted
/// scrolls; Safari behaves the same (probe-verified on macOS 26 across six field variants —
/// phases, ScrollCount, mayBegin, momentum tail, BeginGesture/EndGesture brackets). So the host
/// watches the stream it is already injecting and fires the universal keyboard equivalent
/// instead. See docs/05-input-window-control.md §"Trackpad gestures".
///
/// THREE decision points, matching how real page-swipes distribute their energy:
///
///  1. **Lift** (the `ended` marker): a decisive flick that spent enough travel on-glass fires
///     immediately. The completed-gesture shape gates out content pans — a navigation flick is
///     short and decisively horizontal; a horizontal CONTENT pan (spreadsheet, wide code) runs
///     longer or drifts vertically.
///  2. **Momentum confirmation**: the harder/faster the flick, the SHORTER the fingers stay on
///     glass — most of a sharp flick's displacement arrives in the momentum tail, so an
///     on-glass-only recogniser rejects exactly the most emphatic swipes. A lift that was
///     dominant and quick but short of `fireTravel` therefore ARMS a brief coast window; the
///     momentum deltas (same sign, OS-computed from lift velocity) then confirm or expire it.
///     Momentum can only ever CONFIRM a candidate the on-glass segment armed — a pan whose lift
///     was rejected (too long, not dominant) contributes nothing, so momentum tails of ordinary
///     pans still can't navigate.
///  3. **Slow deliberate swipe**: natively a page-swipe works at ANY speed — the peel tracks the
///     fingers and commits at release — so a long duration alone must not disqualify. Past
///     `flickMaxDuration` the lift decision demands COMMITMENT instead of speed: a graduated
///     SURFACE (``slowRequiredTravel``), not steps — the required travel interpolates from the
///     flick bar at the seam up to `slowFireTravel` @ `slowDominance` by `slowGraceMaxDuration`,
///     and between `slowDominance` and `slowRelaxedDominance` from `slowFireTravel` up to
///     `slowRelaxedTravel` (native decides the axis at onset and forgives later wobble that a
///     whole-gesture ratio re-taxes; a 2 ms-later lift must not double the requirement — both
///     step cliffs ate real field swipes that retried right after). Page CONTENT state (is the
///     content at its horizontal edge? can it scroll at all?) is what native browsers arbitrate
///     with, and that remains invisible remotely — commitment is the only proxy left. (History
///     AVAILABILITY — would ⌘[/⌘] navigate at all — IS readable via AX and gates the client's
///     chip, `HostNavHistory`/doc 20 §9.6; it never changes this recogniser's decisions.)
///     There is no upper
///     duration bound: natively you may drag, hold, and release whenever. Slow gestures never
///     ARM — momentum confirmation is a flick mechanism (a slow lift has no tail).
///
/// LOSS TOLERANCE (the input channel is fire-and-forget UDP; scroll datagrams are sent once):
/// a lost `began` is synthesised from the first continuous `changed`; a lost `ended` is
/// synthesised from the first momentum event (momentum ⇒ the fingers demonstrably lifted). v1
/// silently discarded the whole gesture on either loss — a swipe that randomly "didn't count".
/// The channel can also DUPLICATE and REORDER, hence two hardenings: a post-fire REFRACTORY
/// window (no new candidate right after a fire — a reordered on-glass straggler would otherwise
/// re-fire off the gesture's own momentum tail), and synthesised candidates never ARM momentum
/// confirmation (see `synthesised`).
///
/// Pure value type: the injector feeds it the (already coalesced) scroll events it posts;
/// coalescing SUMS same-phase deltas and preserves began/ended markers, so the accumulated
/// totals here are identical to the raw gesture's.
///
/// The Swift face of `rust/slopdesk-video`'s `swipe_recognizer`, reached through the door of the
/// same name. A STRUCT on both sides: the state is sixteen scalars and flags, and it crosses by
/// value because the host's injector and the client's peel planner each hold one — the whole point
/// being that the two reach the SAME verdict over the same event stream, which one implementation
/// guarantees and two only promise.
public struct SwipeNavRecognizer: Sendable {
    public enum Direction: Equatable, Sendable {
        /// Fingers moved RIGHT (natural scrolling: content follows fingers, revealing the
        /// page to the LEFT) → history BACK — matches the local trackpad convention.
        case back
        /// Fingers moved left → history forward.
        case forward
    }

    /// The direction a door code names. An unknown code cannot arise from this door.
    private static func direction(of code: UInt32) -> Direction {
        code == SLOPDESK_SWIPE_FORWARD ? .forward : .back
    }

    /// The law's fixed thresholds, from the door, so neither language writes one down twice.
    private static let law = slopdesk_swipe_constants()

    /// The on-glass travel that fires at lift when nothing overrides it.
    public static var defaultFireTravel: Double { law.default_fire_travel }

    /// On-glass |Σdx| (points) that fires at lift with no momentum needed. Tunable via
    /// `SLOPDESK_SWIPE_NAV_TRAVEL` (the injector threads it through `init`).
    public var fireTravel: Double { record.fire_travel }
    /// On-glass |Σdx| that ARMS momentum confirmation at lift (below it the gesture is jitter).
    public var armTravel: Double { record.arm_travel }
    /// Combined on-glass + momentum |Σdx| that fires an armed candidate.
    public var confirmTravel: Double { record.confirm_travel }
    /// |Σdx| that fires a SLOW deliberate swipe (past `flickMaxDuration`) at lift. Double the
    /// flick threshold: with no duration cap, travel commitment is what separates a deliberate
    /// navigation drag from a modest horizontal content nudge.
    public var slowFireTravel: Double { record.slow_fire_travel }
    /// |Σdx| from which the slow tier's dominance requirement relaxes to
    /// ``slowRelaxedDominance`` (see that constant for the model).
    public var slowRelaxedTravel: Double { record.slow_relaxed_travel }

    /// Horizontal dominance: |Σdx| must be ≥ this multiple of |Σdy|. Cuts diagonal pans.
    /// Re-checked at momentum confirmation over the combined sums, so a coast that curves
    /// vertical dies too.
    public static var dominance: Double { law.dominance }
    /// Dominance for the slow tier. Stricter than the flick's: over a long gesture the hand has
    /// time to wander, and a 2-D content exploration (maps, canvas) wanders — a deliberate slow
    /// nav swipe is a clean line (field traces run 16×+).
    public static var slowDominance: Double { law.slow_dominance }
    /// The slow tier's dominance FLOOR: below 2× nothing fires at any travel. Between here and
    /// ``slowDominance`` the required travel interpolates (``slowRequiredTravel``) — native
    /// decides the axis at ONSET and then forgives drift; a whole-gesture 4× requirement
    /// re-taxes every later wobble (field: 856 ms Σ=(355,−155), 2.3×, and 839 ms Σ=(170,45),
    /// 3.8× — both deliberate swipes a step rule rejected). Travel buys the tolerance: at 2×
    /// the shorter gestures still reject, so a modest diagonal nudge can't ride the relaxation.
    /// This ratio deliberately does NOT scale with `fireTravel` — the knob scales the whole
    /// travel family (at the clamp floor of 20 the relaxed line sits at 60 pt), which is
    /// exactly the hair-trigger an operator setting 20 asked for.
    public static var slowRelaxedDominance: Double { law.slow_relaxed_dominance }
    /// Began→ended duration (seconds) separating the FLICK tier from the SLOW tier. Also gates
    /// ARMING — a long gesture's momentum tail must never navigate (slow fires at lift only).
    public static var flickMaxDuration: TimeInterval { law.flick_max_duration }
    /// End of the GRACE RAMP past the flick seam (``slowRequiredTravel``): between
    /// `flickMaxDuration` and here the requirement eases in from the flick bar (travel
    /// `fireTravel`, 3× dominance) to the full slow bar (`slowFireTravel`, 4×) — a lift 100 ms
    /// past the window must not face DOUBLE the travel (field: 550 ms Σ=(−131,25), 5.2×
    /// dominance, eaten by the step and immediately retried). At the ramp's top the rule
    /// equals the full-dominance band exactly, so behaviour past it is unchanged.
    public static var slowGraceMaxDuration: TimeInterval { law.slow_grace_max_duration }
    /// No NEW candidate may start this soon after a fire. The input channel can REORDER: an
    /// on-glass `changed` datagram of the gesture that just fired can arrive after its `ended`
    /// did — without this quiet window that straggler synthesises a fresh candidate which the
    /// gesture's own momentum tail then fires AGAIN (⌘[ twice = back two pages). A real human
    /// re-flick needs longer than this to lift, re-place and travel, so nothing legitimate is
    /// eaten (a rapid re-flick's later `changed` events still synthesise past the window).
    public static var refractory: TimeInterval { law.refractory }

    /// The threshold family, the live candidate and the refractory anchor — the whole state.
    private var record: SlopDeskSwipeRecognizer
    /// The trace line the last ``ingest(dx:dy:scrollPhase:momentumPhase:continuous:now:)``
    /// produced, awaiting pickup. Not state the law folds: it is recorded AT a decision and
    /// popped straight after, so it crosses as an answer rather than riding in the record.
    private var traceLine: String?

    /// `fireTravel` scales the whole threshold family: arming at 0.3× (below that is jitter),
    /// momentum confirmation at 1.5× (an armed candidate must show real combined travel), the
    /// slow tier at 2× (past the duration boundary only commitment discriminates), and the
    /// slow tier's relaxed-dominance line at 3×.
    ///
    /// `slowSwipe` is the slow-tier kill switch (`SLOPDESK_SWIPE_NAV_SLOW=0`): with it off,
    /// past-`flickMaxDuration` lifts reject on duration exactly like v2 — the escape hatch if
    /// slow-fires ever collide with a horizontal-scrolling workload (sheets/maps in a browser).
    public init(
        fireTravel: Double = Self.defaultFireTravel,
        slowSwipe: Bool = true,
        trace: Bool = false,
    ) {
        record = slopdesk_swipe_recognizer_new(fireTravel, slowSwipe, trace)
    }

    /// The slow tier's GRADUATED commitment SURFACE, shared verbatim by the lift decision and
    /// the live-candidate mirror (``LiveCandidate/wouldFireAtLift`` + the chip's fill) so the
    /// client feedback can never disagree with the fire. Returns the |Σdx| this candidate must
    /// reach to fire — `nil` when its dominance is below the 2× floor (no travel fires).
    ///
    /// ONE joint interpolation replaces the old two-branch step rule (field-tuned 2026-07-17 —
    /// both step cliffs ate real swipes that retried right after). The band's cheap-end ANCHOR
    /// eases along the seam fraction f = (duration − `flickMaxDuration`) / grace span, clamped
    /// 0…1: dominance 3× → 4×, travel `fireTravel` → `slowFireTravel`. At or above the anchor
    /// the requirement is the anchor's travel; between the anchor and the fixed 2× floor it
    /// interpolates linearly toward `slowRelaxedTravel`. So:
    ///  - f = 0 (the seam): ratio ≥ 3× needs `fireTravel` — CONTINUOUS with the flick tier;
    ///  - f = 1 (`slowGraceMaxDuration`+): exactly the old endpoints — 4× @ `slowFireTravel`,
    ///    2× @ `slowRelaxedTravel` — so everything the old steps fired still fires;
    ///  - continuous in BOTH axes. The first cut combined a duration ramp and a ratio band
    ///    with `Double.minimum`, whose independently-gated branches FOLD along their crossing
    ///    (review-caught: at 3.5× the requirement jumped 120 → 180 pt across ~2 ms) — a joint
    ///    surface is the only shape with no cliff anywhere.
    /// Verified against a 320-lift field log: the two eaten swipes (550 ms 5.2× 131 pt;
    /// 839 ms 3.8× 170 pt) flip to FIRE, none of the 204 vertical-dominant true scrolls do.
    public static func slowRequiredTravel(
        duration: TimeInterval,
        sumX: Double,
        sumY: Double,
        fireTravel: Double,
        slowFireTravel: Double,
        slowRelaxedTravel: Double,
    ) -> Double? {
        var required = 0.0
        let answered = slopdesk_swipe_slow_required_travel(
            duration, sumX, sumY, fireTravel, slowFireTravel, slowRelaxedTravel, &required,
        )
        return answered ? required : nil
    }

    /// Feeds one forwarded scroll event; returns a direction exactly when a gesture qualifies
    /// (at lift, or at momentum confirmation of an armed lift). `now` is the host arrival clock
    /// (`ProcessInfo.systemUptime`) — wire events carry no timestamps, and arrival time tracks
    /// the gesture closely enough for the sub-second budgets here.
    public mutating func ingest(
        dx: Double,
        dy: Double,
        scrollPhase: UInt8,
        momentumPhase: UInt8,
        continuous: Bool,
        now: TimeInterval,
    ) -> Direction? {
        var scratch = [UInt8](repeating: 0, count: Self.traceCapacity)
        let answered = scratch.withUnsafeMutableBufferPointer { buffer in
            slopdesk_swipe_recognizer_ingest(
                record, dx, dy, scrollPhase, momentumPhase, continuous, now,
                buffer.baseAddress, buffer.count,
            )
        }
        record = answered.recognizer
        if answered.trace_len > 0, answered.trace_len <= Self.traceCapacity {
            traceLine = String(bytes: scratch[0..<answered.trace_len], encoding: .utf8)
        }
        return answered.fired ? Self.direction(of: answered.direction) : nil
    }

    /// Pops the pending per-gesture decision trace (set only when constructed with
    /// `trace: true`; at most a couple of lines per gesture, never per-event).
    public mutating func takeTraceLine() -> String? {
        defer { traceLine = nil }
        return traceLine
    }

    /// A live, read-only view of the in-flight candidate for CLIENT-side gesture feedback
    /// (the peel overlay): how far along the current tier's commitment the gesture is, and
    /// whether a lift right now would fire. `nil` when no candidate is live (idle,
    /// refractory, zero horizontal travel, or just decided).
    ///
    /// The client runs its own recognizer over the SAME event stream it forwards — raw,
    /// pre-coalescing, but coalescing SUMS same-phase deltas and preserves the boundary
    /// markers, so the two instances reach the same sums and the same verdicts. Feedback
    /// driven from here therefore predicts what the host will do, without a round trip.
    public struct LiveCandidate: Equatable, Sendable {
        /// The direction a fire would take (sign of the horizontal travel so far).
        public var direction: Direction
        /// Signed horizontal travel so far (points; includes momentum while coasting).
        public var travelX: Double
        /// 0…1 toward the live tier's fire threshold (flick `fireTravel`, slow
        /// `slowFireTravel`, coast `confirmTravel`). 0 while the tier's dominance fails —
        /// feedback must never promise a fire the lift decision would reject.
        public var progress: Double
        /// Whether a lift at `now` would fire. Always `false` while coasting: the fingers
        /// are already up, and momentum confirmation is the only decision left.
        public var wouldFireAtLift: Bool
        /// The candidate is armed and coasting — awaiting momentum confirmation.
        public var coasting: Bool
    }

    /// See ``LiveCandidate``. Tier selection mirrors the lift decision exactly: duration
    /// picks flick vs slow, the slow tier vanishes (progress 0) with `slowSwipe` off, and
    /// each tier applies its own dominance before reporting any progress.
    public func liveCandidate(now: TimeInterval) -> LiveCandidate? {
        var answered = SlopDeskSwipeCandidate()
        guard slopdesk_swipe_live_candidate(record, now, &answered) else { return nil }
        return LiveCandidate(
            direction: Self.direction(of: answered.direction),
            travelX: answered.travel_x,
            progress: answered.progress,
            wouldFireAtLift: answered.would_fire_at_lift,
            coasting: answered.coasting,
        )
    }

    /// The buffer one decision's trace is delivered into. A trace line is a duration and two
    /// sums in whole units plus a verdict — the widest one the law can write stays well inside
    /// this, and a line that somehow did not would report its length and be dropped rather than
    /// truncated.
    private static let traceCapacity = 256
}
