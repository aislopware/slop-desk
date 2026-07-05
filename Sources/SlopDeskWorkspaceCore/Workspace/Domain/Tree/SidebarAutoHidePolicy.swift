import Foundation

// MARK: - SidebarAutoHidePolicy (`auto-hide-tabs-panel` decision)

/// The PURE decision for whether the vertical TABS panel (sidebar) should be collapsed for a given
/// ``AutoHideTabsPanelMode`` + active-session tab count (E19/A18). Headless + unit-tested apart from the
/// view-side glue (WI-7) that reads this and conditionally drives `WorkspaceChromeState.sidebarCollapsed`.
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
    /// Pure integer arithmetic; no force-unwrap, no allocation, no side effects.
    public static func desiredCollapsed(mode: AutoHideTabsPanelMode, tabCount: Int) -> Bool? {
        switch mode {
        case .auto:
            tabCount <= 1
        case .default,
             .always:
            nil
        }
    }
}
