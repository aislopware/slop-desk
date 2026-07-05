import Foundation

// MARK: - OnLaunchBehavior (the `On Launch` general setting — O1)

/// What the app does when it opens — the **On Launch** setting
/// (`spec/getting-started__first-launch.md`, Settings → General). Two choices:
///
/// - ``restoreLastSession``: restore the persisted workspace tree (scrollback + the still-running
///   detached host sessions resume on reconnect — see `DetachedSessionStore`). This is the EXISTING
///   slopdesk launch behaviour (the store already restores the persisted tree), so it is the default —
///   byte-identical to today. This is the recommended default.
/// - ``newWindow``: open a fresh single-pane session instead of restoring.
///
/// The launch path reads this via `WorkspacePersistence.launchTree(behavior:persistence:)` at the app's
/// store-construction site (`SlopDeskClientApp.init`): `.newWindow` seeds
/// ``TreeWorkspace/defaultWorkspace()`` instead of `loadTree()`, so the General → On Launch picker
/// genuinely changes launch behaviour.
///
/// PURE: a `String`-raw + `CaseIterable` enum so it bridges to `Defaults` (see `SettingsKey`) and the
/// General-settings picker can enumerate it. ``init(rawValue:)`` is validate-then-repair (a stale /
/// hostile persisted string falls back to ``restoreLastSession`` rather than trapping) — the same
/// non-failable shape as ``CloseConfirmationPolicy/init(rawValue:)`` so the
/// `Defaults.PreferRawRepresentable` bridge keeps working.
public enum OnLaunchBehavior: String, Codable, Sendable, CaseIterable {
    /// Restore the persisted workspace tree on launch (the current default behaviour). Raw value
    /// `restore-last-session` is the on-disk config string, so the persisted setting round-trips.
    case restoreLastSession = "restore-last-session"
    /// Open a fresh empty window on launch. Raw value `new-window` is the on-disk config string.
    case newWindow = "new-window"

    /// Decodes the stored `On Launch` config string. Validate-then-repair: a recognized raw value
    /// maps to its case; anything else (a stale / hostile persisted string) repairs to
    /// ``restoreLastSession`` rather than trapping. Non-failable so it satisfies `RawRepresentable`
    /// without ever returning `nil` (the `Defaults.PreferRawRepresentable` bridge relies on this).
    public init(rawValue: String) {
        switch rawValue {
        case "restore-last-session": self = .restoreLastSession
        case "new-window": self = .newWindow
        default: self = .restoreLastSession
        }
    }
}
