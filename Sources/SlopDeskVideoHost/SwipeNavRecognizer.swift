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
///     `flickMaxDuration` the lift decision demands COMMITMENT instead of speed: double the
///     travel (`slowFireTravel`) and harder dominance (`slowDominance`). Page state (is the
///     content at its horizontal edge? can it scroll at all?) is what native browsers arbitrate
///     with, and it is invisible remotely — commitment is the only proxy left. There is no
///     upper duration bound: natively you may drag, hold, and release whenever. Slow gestures
///     never ARM — momentum confirmation is a flick mechanism (a slow lift has no tail).
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
public struct SwipeNavRecognizer: Sendable {
    public enum Direction: Equatable, Sendable {
        /// Fingers moved RIGHT (natural scrolling: content follows fingers, revealing the
        /// page to the LEFT) → history BACK — matches the local trackpad convention.
        case back
        /// Fingers moved left → history forward.
        case forward
    }

    /// On-glass |Σdx| (points) that fires at lift with no momentum needed. Tunable via
    /// `SLOPDESK_SWIPE_NAV_TRAVEL` (the injector threads it through `init`).
    public let fireTravel: Double
    /// On-glass |Σdx| that ARMS momentum confirmation at lift (below it the gesture is jitter).
    public let armTravel: Double
    /// Combined on-glass + momentum |Σdx| that fires an armed candidate.
    public let confirmTravel: Double
    /// |Σdx| that fires a SLOW deliberate swipe (past `flickMaxDuration`) at lift. Double the
    /// flick threshold: with no duration cap, travel commitment is what separates a deliberate
    /// navigation drag from a modest horizontal content nudge.
    public let slowFireTravel: Double
    /// Horizontal dominance: |Σdx| must be ≥ this multiple of |Σdy|. Cuts diagonal pans.
    /// Re-checked at momentum confirmation over the combined sums, so a coast that curves
    /// vertical dies too.
    public static let dominance: Double = 3
    /// Dominance for the slow tier. Stricter than the flick's: over a long gesture the hand has
    /// time to wander, and a 2-D content exploration (maps, canvas) wanders — a deliberate slow
    /// nav swipe is a clean line (field traces run 16×+).
    public static let slowDominance: Double = 4
    /// Began→ended duration (seconds) separating the FLICK tier from the SLOW tier. Also gates
    /// ARMING — a long gesture's momentum tail must never navigate (slow fires at lift only).
    public static let flickMaxDuration: TimeInterval = 0.45
    /// How long after lift momentum may still confirm. Momentum begins within a frame of the
    /// lift; this only needs to absorb wire jitter plus a few coalesced momentum emits.
    public static let momentumWindow: TimeInterval = 0.25
    /// No NEW candidate may start this soon after a fire. The input channel can REORDER: an
    /// on-glass `changed` datagram of the gesture that just fired can arrive after its `ended`
    /// did — without this quiet window that straggler synthesises a fresh candidate which the
    /// gesture's own momentum tail then fires AGAIN (⌘[ twice = back two pages). A real human
    /// re-flick needs longer than this to lift, re-place and travel, so nothing legitimate is
    /// eaten (a rapid re-flick's later `changed` events still synthesise past the window).
    public static let refractory: TimeInterval = 0.25

    /// Slow-tier kill switch (`SLOPDESK_SWIPE_NAV_SLOW=0`): with it off, past-`flickMaxDuration`
    /// lifts reject on duration exactly like v2 — the escape hatch if slow-fires ever collide
    /// with a horizontal-scrolling workload (sheets/maps in a browser).
    private let slowSwipe: Bool
    private let trace: Bool
    private var traceLine: String?

    private var tracking = false
    private var coasting = false
    /// The live candidate was SYNTHESISED from a `changed` (its `began` never arrived). Such a
    /// candidate may fire at lift on full-strength evidence but must never ARM momentum
    /// confirmation: a reordered straggler `changed` from a REJECTED pan would otherwise form a
    /// near-empty candidate that the pan's big momentum tail then "confirms" into a navigation.
    private var synthesised = false
    private var startedAt: TimeInterval = 0
    private var coastDeadline: TimeInterval = 0
    private var firedAt: TimeInterval = -.infinity
    private var sumX: Double = 0
    private var sumY: Double = 0
    /// The last momentum event accumulated during a coast, for raw-UDP dup rejection (see
    /// ``ingestMomentum``).
    private var lastMomentum: (dx: Double, dy: Double, phase: UInt8)?

    /// `fireTravel` scales the whole threshold family: arming at 0.3× (below that is jitter),
    /// momentum confirmation at 1.5× (an armed candidate must show real combined travel), and
    /// the slow tier at 2× (past the duration boundary only commitment discriminates).
    public init(fireTravel: Double = 80, slowSwipe: Bool = true, trace: Bool = false) {
        self.fireTravel = fireTravel
        armTravel = fireTravel * 0.3
        confirmTravel = fireTravel * 1.5
        slowFireTravel = fireTravel * 2
        self.slowSwipe = slowSwipe
        self.trace = trace
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
        // Momentum ⇒ the fingers are OFF the glass (the phases are mutually exclusive).
        guard momentumPhase == 0 else {
            return ingestMomentum(dx: dx, dy: dy, momentumPhase: momentumPhase, now: now)
        }
        switch scrollPhase {
        case 1: // began — a fresh candidate (a real gesture only; wheel notches carry phase 0)
            guard now - firedAt >= Self.refractory else { return nil }
            tracking = continuous
            synthesised = false
            coasting = false // a new gesture obsoletes any armed predecessor
            startedAt = now
            sumX = dx
            sumY = dy
            return nil
        case 2: // changed
            if !tracking {
                // While an ARMED candidate coasts, an on-glass `changed` here is a
                // reordered/duplicated straggler of the gesture that just armed — synthesising
                // from it would clobber the arm (and its kept sums) right before the genuine
                // momentum confirms. Ignore it while the coast window is live; past the
                // deadline the arm is stale (momentum never came), so release it and let the
                // straggler-or-new-gesture synthesis below run normally.
                if coasting {
                    guard now > coastDeadline else { return nil }
                    coasting = false
                }
                // The gesture's `began` datagram was lost — a continuous `changed` can only
                // come from a live gesture, so synthesise the start here (duration measured a
                // touch short, which only biases the duration gate toward permitting).
                guard continuous, now - firedAt >= Self.refractory else { return nil }
                tracking = true
                synthesised = true
                coasting = false
                startedAt = now
                sumX = 0
                sumY = 0
            }
            sumX += dx
            sumY += dy
            return nil
        case 4: // ended — the lift decision
            guard tracking else { return nil }
            sumX += dx
            sumY += dy
            return liftDecision(now: now)
        case 8: // cancelled — the OS/client abandoned the gesture; never fire from it
            reset()
            return nil
        default: // none(0 = wheel notch) / mayBegin(128) / unknown — not part of a candidate
            return nil
        }
    }

    /// Pops the pending per-gesture decision trace (set only when constructed with
    /// `trace: true`; at most a couple of lines per gesture, never per-event).
    public mutating func takeTraceLine() -> String? {
        defer { traceLine = nil }
        return traceLine
    }

    /// A momentum event: synthesise the lift if `ended` was lost, then let the coast window
    /// accumulate confirmation evidence for an armed candidate.
    private mutating func ingestMomentum(
        dx: Double,
        dy: Double,
        momentumPhase: UInt8,
        now: TimeInterval,
    ) -> Direction? {
        if tracking {
            // Only a momentum BEGIN may prove a lost `ended`: it is the OS's own lift marker
            // and the planner emits it uncoalesced. A continue/end arriving while STILL
            // tracking is a reordered straggler from the PREVIOUS gesture's tail (ms-scale UDP
            // reorder around its momentum-end/began seam) — synthesising a lift from it would
            // CHOP a live content pan into flick-shaped segments that fire (review-reproduced:
            // a 700 ms pan + one stray continue navigated). Ignore it; the candidate lives on.
            guard momentumPhase == 1 else { return nil }
            // The `ended` datagram was lost — momentum-begin proves the lift; decide now.
            if let fired = liftDecision(now: now) { return fired }
        }
        guard coasting else { return nil }
        if now > coastDeadline {
            emitTrace("coast expired Σ=(\(Int(sumX)),\(Int(sumY)))")
            reset()
            return nil
        }
        // Raw-UDP DUPLICATE rejection: the momentum-begin emit is a planner boundary
        // (uncoalesced), so its wire dup arrives verbatim — double-counting it could shove a
        // marginal armed candidate over `confirmTravel`. An exactly identical consecutive
        // momentum event is dropped; a real decay curve never repeats bytes back-to-back, and
        // losing one plateau sample would cost a few points at most. (Continue-phase dups fold
        // into the planner's sum upstream where they are invisible — and small.)
        if let last = lastMomentum, last == (dx, dy, momentumPhase) { return nil }
        lastMomentum = (dx, dy, momentumPhase)
        // This event is post-lift evidence — it accumulates even when it also synthesised the
        // lift above (it happened after the fingers left the glass either way).
        sumX += dx
        sumY += dy
        if abs(sumX) >= confirmTravel, abs(sumX) >= Self.dominance * abs(sumY) {
            let fired: Direction = sumX > 0 ? .back : .forward
            emitTrace("momentum confirm Σ=(\(Int(sumX)),\(Int(sumY))) → FIRE \(fired)")
            firedAt = now
            reset()
            return fired
        }
        if momentumPhase == 3 { // momentum end — no more evidence is coming
            emitTrace("coast ended short Σ=(\(Int(sumX)),\(Int(sumY))) need \(Int(confirmTravel))")
            reset()
        }
        return nil
    }

    /// The lift decision: fire outright (flick or slow tier), arm momentum confirmation, or
    /// reject. Duration picks the tier; dominance gates every outcome — an armed candidate is
    /// always a plausible flick already.
    private mutating func liftDecision(now: TimeInterval) -> Direction? {
        tracking = false
        let duration = now - startedAt
        let stats = "dur=\(Int(duration * 1000))ms Σ=(\(Int(sumX)),\(Int(sumY)))"
        guard duration <= Self.flickMaxDuration else {
            return slowLiftDecision(now: now, stats: stats)
        }
        guard abs(sumX) >= Self.dominance * abs(sumY) else {
            emitTrace("lift \(stats) → reject dominance")
            reset()
            return nil
        }
        if abs(sumX) >= fireTravel {
            let fired: Direction = sumX > 0 ? .back : .forward
            emitTrace("lift \(stats) → FIRE \(fired)")
            firedAt = now
            reset()
            return fired
        }
        if abs(sumX) >= armTravel {
            if synthesised {
                emitTrace("lift \(stats) → reject (synthesised candidate can't arm)")
                reset()
                return nil
            }
            coasting = true
            coastDeadline = now + Self.momentumWindow
            emitTrace("lift \(stats) → armed (confirm ≥\(Int(confirmTravel)))")
            return nil // sums KEPT: momentum confirms over the combined travel
        }
        emitTrace("lift \(stats) → reject travel (<\(Int(armTravel)))")
        reset()
        return nil
    }

    /// The slow tier (see decision point 3 in the type doc): a lift past `flickMaxDuration`
    /// fires on commitment — double travel, harder dominance, no upper duration bound — or
    /// rejects outright. It never ARMS: momentum confirmation exists for flicks whose energy
    /// went into the tail; a slow lift has none, and letting a long gesture coast would hand
    /// content-pan tails a path to navigate again.
    private mutating func slowLiftDecision(now: TimeInterval, stats: String) -> Direction? {
        defer { reset() }
        guard slowSwipe else {
            emitTrace("lift \(stats) → reject duration (slow tier off)")
            return nil
        }
        guard abs(sumX) >= Self.slowDominance * abs(sumY) else {
            emitTrace("lift \(stats) → reject slow dominance")
            return nil
        }
        guard abs(sumX) >= slowFireTravel else {
            emitTrace("lift \(stats) → reject slow travel (<\(Int(slowFireTravel)))")
            return nil
        }
        let fired: Direction = sumX > 0 ? .back : .forward
        emitTrace("lift \(stats) → FIRE \(fired) (slow)")
        firedAt = now
        return fired
    }

    private mutating func reset() {
        tracking = false
        coasting = false
        synthesised = false
        sumX = 0
        sumY = 0
        lastMomentum = nil
        // `firedAt` deliberately survives — the refractory window outlives the candidate.
    }

    private mutating func emitTrace(_ line: String) {
        if trace { traceLine = line }
    }
}

/// Which HOST apps the swipe translation may drive. ⌘[ / ⌘] is history-back/forward in every
/// mainstream browser and in Finder — but in an editor it is outdent/indent (a TEXT EDIT), so
/// the translation is allow-listed instead of universal: an unknown frontmost app gets the
/// scroll it already received and nothing else.
public enum SwipeNavPolicy {
    /// Bundle ids where ⌘[ / ⌘] means history navigation. Extend at runtime via
    /// `SLOPDESK_SWIPE_NAV_APPS` (comma-separated bundle ids) without a rebuild.
    public static let navigableApps: Set<String> = [
        "com.apple.Safari",
        "com.apple.SafariTechnologyPreview",
        "com.apple.finder",
        "com.google.Chrome",
        "com.google.Chrome.beta",
        "com.google.Chrome.dev",
        "com.google.Chrome.canary",
        "org.chromium.Chromium",
        "company.thebrowser.Browser", // Arc
        "company.thebrowser.dia",
        "org.mozilla.firefox",
        "org.mozilla.nightly",
        "org.mozilla.firefoxdeveloperedition",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "com.brave.Browser.beta",
        "com.brave.Browser.nightly",
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
        "com.kagi.kagimacOS", // Orion
        "app.zen-browser.zen",
    ]

    /// Parses the `SLOPDESK_SWIPE_NAV_APPS` extension list (comma-separated, whitespace-tolerant).
    public static func extraApps(from raw: String?) -> Set<String> {
        guard let raw else { return [] }
        return Set(raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }

    public static func isNavigable(bundleID: String?, extraApps: Set<String> = []) -> Bool {
        guard let bundleID else { return false }
        return navigableApps.contains(bundleID) || extraApps.contains(bundleID)
    }
}
