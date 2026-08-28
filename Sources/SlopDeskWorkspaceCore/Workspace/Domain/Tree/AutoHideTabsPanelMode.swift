// MARK: - AutoHideTabsPanelMode (`auto-hide-tabs-panel` policy)

/// When the vertical TABS panel (sidebar) is shown — the `auto-hide-tabs-panel` config
/// (`spec/user-interface__window-tab-split.md`, values `default` / `always` / `auto`). Covers the
/// VERTICAL-sidebar single-tab auto-hide ONLY; a horizontal `auto-hide-tab-bar` equivalent is out of scope
/// (slopdesk is vertical-tabs-only — see `docs/ui-shell/plans/E19-carryovers.md`).
///
/// - ``default``: the tabs panel is always shown — **no** auto-hide.
/// - ``always``: the tabs panel is always shown — also **no** auto-hide. (`default` and `always` are kept as
///   distinct cases for a possible future horizontal-bar layout; in the vertical-tabs-only shell both collapse
///   to "never auto-hide", so the policy treats the two identically — it has no opinion for either.)
/// - ``auto``: hide the tabs panel when the active session has only ONE tab, reveal it when there is more
///   than one. This is the single behaviour this mode actuates.
///
/// The type is the config TOKEN and nothing else. Every decision this mode feeds —
/// which modes have an opinion, the 1↔>1 regime edge, and whether a manual ⌘⇧L may be
/// overruled — is `slopdesk_settings::chrome`, reached through the one door
/// ``WorkspaceChromePolicy/applyAutoHide(mode:tabCount:chrome:)`` calls. `String`-raw (the case names ARE
/// the persisted tokens) + `CaseIterable` so it bridges to `Defaults` (see `SettingsKey`) and the Settings
/// picker can enumerate it. A stale / invalid persisted raw value repairs to ``default`` via the
/// `Defaults.PreferRawRepresentable` bridge declared in `SettingsKey`.
public enum AutoHideTabsPanelMode: String, Codable, Sendable, CaseIterable {
    case `default`
    case always
    case auto
}

package extension AutoHideTabsPanelMode {
    /// The case index the door reads. Lives beside the enum rather than at the call site because the
    /// mapping is the enum's own — a case added here without a matching Rust arm is the bug this
    /// adjacency makes visible.
    var ffiByte: UInt8 {
        switch self {
        case .default: 0
        case .always: 1
        case .auto: 2
        }
    }
}
