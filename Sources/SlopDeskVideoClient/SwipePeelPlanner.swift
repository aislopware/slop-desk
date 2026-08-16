import CSlopDeskFFI
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

/// The Swift face of `rust/slopdesk-video`'s `swipe_peel`, reached through the door of the same
/// name.
///
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
/// A FOLD, and therefore still a pure value type: the planner IS the mirrored recogniser plus
/// what the chip is doing, and the recogniser already crosses by value for the reason that
/// matters here — the host's injector and this mirror have to reach the same verdict over the
/// same events, which is only guaranteed if there is one law rather than two.
///
/// All AppKit work — chip publish, haptic — still happens in the view from the returned
/// ``Verdict``.
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

    /// The planner's fixed numbers, from the door, so neither language writes them down twice.
    private static let law = slopdesk_peel_constants()
    /// Chip-fill quantum: progress is rounded to this so the @Published chip state changes at
    /// most ~32 times per fill, not once per 120 Hz event.
    public static var progressQuantum: Double { law.progress_quantum }
    /// The host's own default lift-fire travel, in points.
    public static var defaultFireTravel: Double { SwipeNavRecognizer.defaultFireTravel }

    /// The mirrored recogniser, and what the chip is doing.
    private var record: SlopDeskPeelPlanner

    public init(fireTravel: Double = Self.defaultFireTravel, slowSwipe: Bool = true) {
        record = slopdesk_peel_new(fireTravel, slowSwipe)
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
        answered(slopdesk_peel_ingest(record, dx, dy, scrollPhase, momentumPhase, continuous, now))
    }

    /// The view stopped feeding this gesture mid-flight (scroll rerouted to canvas pan, pane
    /// lost focus, eligibility flipped off) — abandon the candidate and hide the chip.
    public mutating func cancel() -> Verdict {
        answered(slopdesk_peel_cancel(record))
    }

    /// History gate over one verdict (doc 20 §9.6): a candidate toward a direction the host
    /// says CANNOT navigate never surfaces — `.show` and `.commit` become `.retract`
    /// (idempotent when nothing is showing), so neither the chip nor the commit haptic/pulse
    /// promises a dead navigation. Applied by the VIEW between `ingest` and the chip publish
    /// rather than inside the recogniser mirror: the host keeps firing the (self-gating) chord
    /// on these swipes, so the mirror's internal state must keep tracking the gesture exactly
    /// as the host's does. UNKNOWN history fails open inside ``SwipeNavStatusMessage/allowsChip(_:)``.
    public static func historyGated(_ verdict: Verdict, status: SwipeNavStatusMessage) -> Verdict {
        let code: UInt32
        let direction: SwipeNavRecognizer.Direction
        switch verdict {
        case let .show(chip): (code, direction) = (SLOPDESK_PEEL_SHOW, chip.direction)
        case let .commit(fired): (code, direction) = (SLOPDESK_PEEL_COMMIT, fired)
        default: return verdict
        }
        let gated = status.peelGated(
            verdict: code, direction: direction == .back ? SLOPDESK_SWIPE_BACK : SLOPDESK_SWIPE_FORWARD,
        )
        return gated == code ? verdict : .retract
    }

    /// One answered ingest folded back onto this planner.
    private mutating func answered(_ answer: SlopDeskPeelIngest) -> Verdict {
        record = answer.planner
        let direction: SwipeNavRecognizer.Direction =
            answer.direction == SLOPDESK_SWIPE_FORWARD ? .forward : .back
        switch answer.verdict {
        case SLOPDESK_PEEL_SHOW:
            return .show(SwipePeelChipState(
                direction: direction,
                progress: answer.progress,
                committed: answer.committed,
                confirming: answer.confirming,
            ))
        case SLOPDESK_PEEL_COMMIT: return .commit(direction)
        case SLOPDESK_PEEL_RETRACT: return .retract
        default: return .idle
        }
    }
}
