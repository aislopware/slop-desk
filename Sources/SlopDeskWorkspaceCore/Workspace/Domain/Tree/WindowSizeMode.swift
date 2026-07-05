import Foundation

// MARK: - WindowSizeMode (`window-size` policy)

/// How a newly opened window decides its initial dimensions — the `window-size`
/// config (`spec/user-interface__window-tab-split.md`, values `remember` / `grid` / `frame`).
///
/// - ``remember``: the default. Restore the previous window's size + position on reopen (the macOS
///   `setFrameAutosaveName` path — no explicit size is applied, the autosaved frame stands).
/// - ``grid``: size the window to an exact cell count via `window-cols` × `window-rows` (defaults
///   `80` × `24`). The grid → content-points math lives in ``WindowSizeMath/gridContentSize(cols:rows:cell:)``.
/// - ``frame``: use literal pixel dimensions via `window-width-px` × `window-height-px` (defaults
///   `1000` × `600`).
///
/// A pure value type: the sizing math lives in ``WindowSizeMath`` so it is unit-testable apart from the
/// (macOS-only, hang-unsafe) `NSWindow` glue that consumes it. `String`-raw (the case names ARE the
/// config tokens) + `CaseIterable` so it bridges to `Defaults` (see `SettingsKey`) and the Settings picker
/// can enumerate it. A stale / invalid persisted raw value repairs to ``remember`` via the
/// `Defaults.PreferRawRepresentable` bridge declared in `SettingsKey`.
public enum WindowSizeMode: String, Codable, Sendable, CaseIterable {
    case remember
    case grid
    case frame
}
