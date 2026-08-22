import CSlopDeskFFI
import Foundation

/// The chip's state machine over ``SwipePeelPlanner/Verdict`` — the half of swipe-peel feedback that
/// is a DECISION rather than a framework call.
///
/// The planner answers "what is this gesture doing". This answers "what should be on screen, and
/// what should the hand feel", and it is the piece that was written once and then needed twice: the
/// Mac drove the chip from `NSEvent`s and an `NSHapticFeedbackManager`, the phone from `UITouch`es
/// and a `UIFeedbackGenerator`, and everything BETWEEN those two pairs — when the haptic fires, how
/// long a fired chip is held, which retract is swallowed — is the same law on both. Written twice it
/// would be two laws that agreed until one of them was edited.
///
/// Each half is left with exactly three actuations: publish a state, tap the haptic, and run a
/// timer. Every EDGE that decides whether to do any of them is here.
///
/// ## The three rules that are not obvious
///
/// **The haptic is a RISING EDGE, never a level.** It fires the moment the chip turns solid — the
/// "release now navigates" line — and not again while it stays solid, which is most of the events in
/// a slow swipe.
///
/// **A confirming chip outranks a retract.** The planner resets `showing` at commit, so the only
/// live publish a `.retract` can coexist with is the PREVIOUS gesture's confirm hold (a double-back
/// at the end of history). Clearing it there would erase the acknowledgement of the fire that caused
/// it; the pending hold is what ends it.
///
/// **A no-op publish is not free.** The history gate relabels every qualifying event of a
/// dead-direction gesture as `.retract`, so a driver that answered "clear" each time would re-fire
/// the observable's invalidation ~80× per gesture for no visible change. `.none` is returned instead.
public struct SwipePeelChipDriver: Sendable {
    /// What the caller should do with one verdict.
    public enum Step: Equatable, Sendable {
        /// Nothing changed that anyone can see.
        case none
        /// Publish this state; tap the "release now navigates" haptic if `haptic`.
        case show(SwipePeelChipState, haptic: Bool)
        /// The mirror fired: publish the confirming state, then clear it after `hold` seconds
        /// unless a later step supersedes it.
        case confirm(SwipePeelChipState, hold: TimeInterval)
        /// Take the chip down.
        case clear
    }

    /// How long a fired chip is held, from the door — so neither client spells the number.
    public static var confirmHold: TimeInterval { slopdesk_peel_constants().confirm_hold_seconds }

    /// Whether the chip was solid at the last step (the haptic's rising edge).
    private var committed = false

    public init() {}

    /// Folds one verdict — already history-gated by the caller — into what the surface should do.
    ///
    /// - Parameters:
    ///   - verdict: the planner's answer for the event just ingested.
    ///   - showing: what is on screen right now (`nil` = nothing).
    public mutating func step(
        _ verdict: SwipePeelPlanner.Verdict, showing: SwipePeelChipState?,
    ) -> Step {
        switch verdict {
        case .idle:
            return .none
        case let .show(chip):
            let haptic = chip.committed && !committed
            committed = chip.committed
            guard haptic || showing != chip else { return .none }
            return .show(chip, haptic: haptic)
        case let .commit(direction):
            committed = false
            let chip = SwipePeelChipState(
                direction: direction, progress: 1, committed: true, confirming: true,
            )
            return .confirm(chip, hold: Self.confirmHold)
        case .retract:
            committed = false
            guard let showing, !showing.confirming else { return .none }
            return .clear
        }
    }
}
