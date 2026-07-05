import Foundation

// MARK: - AutoHideTabsPanelMode (`auto-hide-tabs-panel` policy)

/// When the vertical TABS panel (sidebar) is shown — the `auto-hide-tabs-panel` config
/// (`spec/user-interface__window-tab-split.md`, values `default` / `always` / `auto`). A18 = the
/// VERTICAL-sidebar single-tab auto-hide ONLY; a horizontal `auto-hide-tab-bar` equivalent is out of scope
/// (slopdesk is vertical-tabs-only — see `docs/ui-shell/plans/E19-carryovers.md`).
///
/// - ``default``: the tabs panel is always shown — **no** auto-hide.
/// - ``always``: the tabs panel is always shown — also **no** auto-hide. (`default` and `always` are kept as
///   distinct cases for a possible future horizontal-bar layout; in the vertical-tabs-only shell both collapse
///   to "never auto-hide", so ``SidebarAutoHidePolicy`` treats the two identically — it has no opinion for
///   either.)
/// - ``auto``: hide the tabs panel when the active session has only ONE tab, reveal it when there is more
///   than one. This is the single behaviour A18 actuates.
///
/// A pure value type: the show/hide decision lives in ``SidebarAutoHidePolicy/desiredCollapsed(mode:tabCount:)``
/// so it is unit-testable apart from the view-side glue (WI-7) that drives `chrome.sidebarCollapsed`.
/// `String`-raw (the case names ARE the persisted config tokens) + `CaseIterable` so it bridges to `Defaults`
/// (see `SettingsKey`) and the Settings picker can enumerate it. A stale / invalid persisted raw value
/// repairs to ``default`` via the `Defaults.PreferRawRepresentable` bridge declared in `SettingsKey`.
public enum AutoHideTabsPanelMode: String, Codable, Sendable, CaseIterable {
    case `default`
    case always
    case auto
}
