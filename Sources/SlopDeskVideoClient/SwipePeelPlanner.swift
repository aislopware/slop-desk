import Foundation
import SlopDeskVideoProtocol

/// What the swipe-peel chip overlay renders (published through ``VideoPaneControls``).
/// `nil` ⇒ hidden. Progress is QUANTIZED by the planner so a 120 Hz event stream doesn't
/// re-render the SwiftUI overlay per event.
public struct SwipePeelChipState: Equatable, Sendable {
    /// Which edge the chip sits on (`.back` = leading, `.forward` = trailing).
    public var direction: SwipeNavRecognizer.Direction
    /// 0…1 fill toward the live tier's commit threshold.
    public var progress: Double
    /// Release-now-navigates: the chip renders solid (and the view taps the trackpad haptic
    /// on the rising edge).
    public var committed: Bool
    /// The gesture fired — the chip plays its confirm pulse and fades.
    public var confirming: Bool

    public init(direction: SwipeNavRecognizer.Direction, progress: Double, committed: Bool, confirming: Bool = false) {
        self.direction = direction
        self.progress = progress
        self.committed = committed
        self.confirming = confirming
    }
}

/// Client-side mirror of the HOST's swipe-nav recogniser, run purely for FEEDBACK — the piece
/// of native swipe-back that key translation can never give: something reacting WHILE the
/// fingers are still on the glass. The host remains the sole authority on actually firing
/// ⌘[/⌘]; this planner drives the edge chip (+ the view's haptic), from the SAME event stream
/// the view forwards (pre-coalescing — coalescing sums same-phase deltas and keeps the
/// boundary markers, so both recognisers reach the same sums and the same verdicts). The
/// STREAMED IMAGE itself never moves: a remote pane is a window onto a whole desktop, so
/// translating it reads as dragging the pane, not peeling a page (v6 HW verdict — see
/// DECISIONS).
///
/// The mirror's thresholds come from the host's ``SwipeNavStatusMessage`` push, so a host-side
/// `SLOPDESK_SWIPE_NAV_TRAVEL`/`_SLOW` retune never desynchronises the feedback; the view only
/// feeds the planner while the host says the target app is eligible at all.
///
/// Pure value type (headless-testable): all AppKit work — chip publish, haptic — happens in
/// the view from the returned ``Verdict``.
public struct SwipePeelPlanner: Sendable {
    /// What the view should do after feeding one scroll event.
    public enum Verdict: Equatable, Sendable {
        /// Nothing showing, nothing to change.
        case idle
        /// A live decisively-horizontal candidate — publish the chip.
        case show(SwipePeelChipState)
        /// The mirror fired: play the chip's confirm pulse. The HOST fires the actual ⌘[/⌘]
        /// from its own recogniser at the same moment.
        case commit(SwipeNavRecognizer.Direction)
        /// The candidate died without firing (reject, coast expiry, cancel) — hide the chip.
        case retract
    }

    /// Chip-fill quantum: progress is rounded to this so the @Published chip state changes at
    /// most ~32 times per fill, not once per 120 Hz event.
    public static let progressQuantum: Double = 1.0 / 32.0

    private var recognizer: SwipeNavRecognizer
    /// Overlay appearance threshold — the recogniser's own arm line (0.3× fire): below it the
    /// horizontal component is jitter, and a slightly-diagonal ordinary scroll must not flash
    /// the chip for its first few points of incidental Σx.
    private let showTravel: Double
    private var showing = false
    /// The direction the visible chip sits on. A mid-gesture REVERSAL that jumps the ±show
    /// dead zone in one event would otherwise emit consecutive `.show`s with flipped direction
    /// and the chip would keep its SwiftUI identity — animating a full-pane slide from one edge
    /// to the other instead of fading out and re-appearing. A flip therefore concludes the old
    /// chip first (`.retract`); the next event re-shows on the new edge.
    private var shownDirection: SwipeNavRecognizer.Direction?
    /// Chip fill floor across the tracking→coasting seam: the denominator changes there
    /// (`fireTravel` → `confirmTravel`), which would visibly DROP the fill mid-gesture even
    /// though nothing regressed. Coast frames display at least the fill the on-glass segment
    /// reached — unless dominance collapses to 0, which stays an honest retract.
    private var glassProgress: Double = 0

    public init(fireTravel: Double = 80, slowSwipe: Bool = true) {
        recognizer = SwipeNavRecognizer(fireTravel: fireTravel, slowSwipe: slowSwipe)
        showTravel = fireTravel * 0.3
    }

    /// Feeds one forwarded scroll event (same tuple the pipeline sends the host).
    public mutating func ingest(
        dx: Double,
        dy: Double,
        scrollPhase: UInt8,
        momentumPhase: UInt8,
        continuous: Bool,
        now: TimeInterval,
    ) -> Verdict {
        if let fired = recognizer.ingest(
            dx: dx, dy: dy, scrollPhase: scrollPhase, momentumPhase: momentumPhase,
            continuous: continuous, now: now,
        ) {
            showing = false
            shownDirection = nil
            glassProgress = 0
            return .commit(fired)
        }
        guard let live = recognizer.liveCandidate(now: now), live.progress > 0,
              abs(live.travelX) >= showTravel
        else {
            // No candidate, one that stopped being decisively horizontal (dominance / tier
            // collapse), or incidental sub-arm Σx — the overlay must not promise a fire the
            // host would reject, nor flash on an ordinary scroll's first diagonal points.
            return concludeIfShowing()
        }
        if showing, let shown = shownDirection, live.direction != shown {
            return concludeIfShowing()
        }
        var progress = live.progress
        if live.coasting {
            progress = Double.maximum(progress, glassProgress)
        } else {
            glassProgress = progress
        }
        showing = true
        shownDirection = live.direction
        let quantized = (progress / Self.progressQuantum).rounded(.down) * Self.progressQuantum
        return .show(SwipePeelChipState(
            direction: live.direction,
            progress: Double.minimum(Double.maximum(quantized, Self.progressQuantum), 1),
            committed: live.wouldFireAtLift,
        ))
    }

    /// The view stopped feeding this gesture mid-flight (scroll rerouted to canvas pan, pane
    /// lost focus, eligibility flipped off) — abandon the candidate and hide the chip.
    public mutating func cancel() -> Verdict {
        _ = recognizer.ingest(dx: 0, dy: 0, scrollPhase: 8, momentumPhase: 0, continuous: true, now: 0)
        return concludeIfShowing()
    }

    private mutating func concludeIfShowing() -> Verdict {
        glassProgress = 0
        shownDirection = nil
        guard showing else { return .idle }
        showing = false
        return .retract
    }
}
