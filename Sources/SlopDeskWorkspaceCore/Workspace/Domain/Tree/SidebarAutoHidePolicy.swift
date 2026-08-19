import CSlopDeskFFI

// MARK: - SidebarAutoHidePolicy (`auto-hide-tabs-panel` decision)

/// The PURE decision for whether the vertical TABS panel (sidebar) should be collapsed for a given
/// ``AutoHideTabsPanelMode`` + active-session tab count. Headless + unit-tested apart from the
/// view-side glue that reads this and conditionally drives `WorkspaceChromeState.sidebarCollapsed`.
///
/// The result is a three-valued ``Bool?`` on purpose:
/// - a concrete `true`/`false` is an OPINION the wiring should apply (collapse / reveal), and
/// - `nil` means "no opinion" — the wiring leaves the user's manual ⌘⇧L collapse alone.
///
/// Only ``AutoHideTabsPanelMode/auto`` has an opinion; ``AutoHideTabsPanelMode/default`` and
/// ``AutoHideTabsPanelMode/always`` both yield `nil` so they never fight a manual toggle (in the
/// vertical-tabs-only clone they both mean "never auto-hide" — see the enum's doc-comment).
public enum SidebarAutoHidePolicy {
    /// Whether the sidebar should be collapsed for `mode` given the active session's `tabCount`.
    ///
    /// - ``AutoHideTabsPanelMode/auto`` → `tabCount <= 1` (collapse when there is one tab or none, reveal
    ///   when there is more than one — hidden whenever there is nothing to switch between). An empty session
    ///   (`tabCount == 0`) collapses too — there is nothing to switch between.
    /// - ``AutoHideTabsPanelMode/default`` / ``AutoHideTabsPanelMode/always`` → `nil` (no opinion).
    ///
    /// The rule is `slopdesk_workspace::chrome::desired_collapsed`, which answers `-1` for the modes
    /// with no opinion — outside both booleans by construction, so it can never be read as one.
    public static func desiredCollapsed(mode: AutoHideTabsPanelMode, tabCount: Int) -> Bool? {
        switch slopdesk_ws_sidebar_desired_collapsed(mode.ffiByte, max(0, tabCount)) {
        case 0: false
        case 1: true
        default: nil
        }
    }
}

package extension AutoHideTabsPanelMode {
    /// The case index the door reads.
    var ffiByte: UInt8 {
        switch self {
        case .default: 0
        case .always: 1
        case .auto: 2
        }
    }
}
