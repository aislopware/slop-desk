import Foundation

// MARK: - macOS Dock tile decision (aggregate progress + red-on-error tint)

/// Whether the macOS Dock tile shows the red error tint. A tiny pure value (`Equatable`/`Sendable`) so the
/// whole tint decision crosses the headless → AppKit boundary without an `NSDockTile` — the actuation lives
/// in the macOS-only `DockProgressController` (`SlopDeskClientUI`), this is the decision it reads.
public enum DockTint: Equatable, Sendable {
    /// No tint — the default Dock icon.
    case none
    /// Tint the Dock icon red (a session reported a non-zero exit / OSC 9;4;2 error).
    case error
}

/// The COMPLETE, AppKit-free decision for what the macOS Dock tile should show — the red error
/// tint, whether to run the progress animation, and the determinate fraction when one is known. Pure +
/// `Equatable` so the macOS `DockProgressController` re-applies the tile only on a genuine edge, and so the
/// decision is unit-pinned WITHOUT ever instantiating an `NSDockTile` (the hang-safety rule).
public struct DockTileModel: Equatable, Sendable {
    /// The red-on-error tint decision (gated by the `dock-icon-error-badge` toggle).
    public var tint: DockTint
    /// Whether the tile runs its progress animation (gated by the `dock-icon-animate-progress` toggle; true
    /// only for a RUNNING aggregate — in-progress / indeterminate — never for a held error or a clear).
    public var animatesProgress: Bool
    /// The determinate progress fraction `0…1` when the aggregate is a determinate percent AND animation is
    /// on; `nil` for an indeterminate spinner (or when not animating). Clamped to `0…1`.
    public var determinateFraction: Double?

    public init(tint: DockTint, animatesProgress: Bool, determinateFraction: Double?) {
        self.tint = tint
        self.animatesProgress = animatesProgress
        self.determinateFraction = determinateFraction
    }

    /// The default tile: no tint, no animation — the CLEAR state the controller restores when the last
    /// progress/error session ends (avoids a stuck red tile).
    public static let inert = Self(tint: .none, animatesProgress: false, determinateFraction: nil)

    /// Whether the tile is in its default state (nothing to draw over the app icon).
    public var isInert: Bool { self == .inert }
}

/// The PURE decision policy for the macOS Dock tile — split out of the AppKit actuation so the
/// "error rollup → red, in-progress → animate, clear → inert" rule is unit-pinned headlessly (never
/// instantiates an `NSDockTile`). Mirrors the ``NotificationPolicy`` discipline: the macOS
/// `DockProgressController` owns ONLY the `NSDockTile` drawing + `requestUserAttention` bounce; every decision
/// it makes is one of these pure functions.
public enum DockTintPolicy {
    /// The red error-tint decision from the cross-session OSC 9;4 progress rollup: an `.error` rollup tints
    /// red; an in-progress / indeterminate / cleared rollup leaves it untinted. Pure + AppKit-free. The
    /// `dock-icon-error-badge` toggle + the non-zero-exit signal are folded
    /// in by ``resolve(progressRollup:anyFailure:animateProgressEnabled:errorBadgeEnabled:)``.
    public static func tint(forRollup rollup: PaneProgress?) -> DockTint {
        if case .error = rollup { return .error }
        return .none
    }

    /// The COMPLETE Dock-tile decision combining the cross-session progress rollup, whether any session
    /// carries a `.failure` (non-zero exit) completion badge, and the two macOS-only toggles:
    ///  - **tint**: red iff `dock-icon-error-badge` is on AND (the progress rollup is `.error` OR a session
    ///    exited non-zero) — the spec "tints red when any session reports a non-zero exit or OSC 9;4;2".
    ///  - **animation**: runs iff `dock-icon-animate-progress` is on AND the aggregate is a RUNNING state
    ///    (in-progress / indeterminate); a held error or a clear never animates.
    ///  - **determinateFraction**: the clamped `percent/100` when the aggregate is a determinate percent and
    ///    animation is on, else `nil` (the indeterminate spinner). Ordered min/max clamp (NaN-safe — the
    ///    house style, never a bare `<`/`>` ternary), no fused multiply.
    public static func resolve(
        progressRollup: PaneProgress?,
        anyFailure: Bool,
        animateProgressEnabled: Bool,
        errorBadgeEnabled: Bool,
    ) -> DockTileModel {
        let isError = tint(forRollup: progressRollup) == .error || anyFailure
        let tintDecision: DockTint = errorBadgeEnabled && isError ? .error : .none
        var animates = false
        var fraction: Double?
        if animateProgressEnabled {
            switch progressRollup {
            case .indeterminate:
                animates = true
            case let .determinate(percent):
                animates = true
                fraction = Double.minimum(1, Double.maximum(0, Double(percent) / 100))
            case .error,
                 nil:
                break
            }
        }
        return DockTileModel(tint: tintDecision, animatesProgress: animates, determinateFraction: fraction)
    }
}
