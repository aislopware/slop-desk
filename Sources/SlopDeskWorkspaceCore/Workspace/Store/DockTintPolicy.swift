import CSlopDeskFFI

// MARK: - macOS Dock tile decision (aggregate progress + red-on-error tint)

/// Whether the macOS Dock tile shows the red error tint. A tiny pure value (`Equatable`/`Sendable`) so the
/// whole tint decision crosses the headless → AppKit boundary without an `NSDockTile` — the actuation lives
/// in the macOS-only `DockProgressController` (`SlopDeskMacUI`), this is the decision it reads.
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
    /// The COMPLETE Dock-tile decision combining the cross-session progress rollup, whether any session
    /// carries a `.failure` (non-zero exit) completion badge, and the two macOS-only toggles.
    ///
    /// The rule is `slopdesk_workspace::chrome::dock_tile` — which of the three rollups tints, which
    /// animate, and the fraction the determinate one draws with. The rollup crosses as the WIRE's own
    /// `OSC 9;4` discriminant rather than as this enum's case index, so the byte means the same thing on
    /// both sides of the client as it does on the wire that produced it.
    public static func resolve(
        progressRollup: PaneProgress?,
        anyFailure: Bool,
        animateProgressEnabled: Bool,
        errorBadgeEnabled: Bool,
    ) -> DockTileModel {
        let tile = slopdesk_ws_dock_tile(
            progressRollup?.ffiRollup ?? 0, progressRollup?.ffiPercent ?? 0,
            anyFailure, animateProgressEnabled, errorBadgeEnabled,
        )
        return DockTileModel(
            tint: tile.tinted ? .error : DockTint.none,
            animatesProgress: tile.animates,
            determinateFraction: tile.fraction_present ? tile.fraction : nil,
        )
    }
}

extension PaneProgress {
    /// The `OSC 9;4` discriminant this rollup came from — `1` in progress, `2` error, `3` indeterminate.
    /// `0`, the clear, has no case here: it is the ABSENCE of a rollup.
    var ffiRollup: UInt8 {
        switch self {
        case .determinate: 1
        case .error: 2
        case .indeterminate: 3
        }
    }

    /// The percent the two value-carrying cases hold; the spinner has none.
    var ffiPercent: UInt8 {
        switch self {
        case let .determinate(percent),
             let .error(percent): percent
        case .indeterminate: 0
        }
    }
}
