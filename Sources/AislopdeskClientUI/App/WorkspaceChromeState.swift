// WorkspaceChromeState — the small @Observable chrome model the toolbar toggles drive (REBUILD-V2, L4a).
//
// Owns the sidebar/windows-panel collapse flags + the GUI column width the native SwiftUI shell reads
// (`WorkspaceRootView`: the NavigationSplitView column visibility + the keep-mounted detail split). Kept
// separate from `WorkspaceStore` (whose legacy `sidebarCollapsed` predates the native rebuild and isn't
// read by the new navigator) so the chrome flags live in one place and reading them in a SwiftUI body
// re-invalidates exactly the views that consume them.

#if canImport(SwiftUI)
import Foundation

@MainActor
@Observable
final class WorkspaceChromeState {
    /// The sidebar (TABS panel) default/min thickness — shared with the window-size glue
    /// (`AislopdeskClientApp.applyInitialWindowSize`) so the `grid` mode's `chromeOverhead` uses the SAME
    /// width the native split column adopts (no magic-number drift between the layout and the math).
    static let defaultSidebarWidth: CGFloat = 220
    /// The RIGHT remote-windows column's minimum/default width (matches the old split item's
    /// `minimumThickness` — wide enough for the window dock + a usable video viewport).
    static let minGuiWidth: CGFloat = 380

    /// Whether the left navigator (sidebar) split item is collapsed.
    var sidebarCollapsed = false

    /// The RIGHT remote-windows column's user-chosen width (points) — dragged via the detail split's
    /// divider handle, seeded at the minimum. Pure view state; the column keeps its panes MOUNTED while
    /// collapsed (width 0), so a reveal never re-creates a live video surface.
    var guiWidth: CGFloat = WorkspaceChromeState.minGuiWidth
    /// E19/A30: whether the window is PINNED (View ▸ Pin Window — keep-on-top). Lives with the other
    /// chrome flags so reading it in the SwiftUI scene body re-invalidates the introspect-bearing scene; the
    /// macOS `NSWindow` glue (E19 WI-4) maps it to `NSWindow.level` (`.floating` ⇄ `.normal`). Pure view
    /// state — `false` resting (a fresh window is not pinned), no wire / persistence. iOS has no resizable
    /// floating window, so the flag is inert there (documented no-op, never a dead toggle).
    var pinned = false

    /// E19/WI-7 (auto-hide-tabs-panel): set whenever the user MANUALLY toggles the TABS panel — on macOS ⌘⇧L,
    /// the titlebar button, and the palette row all flip the flag through ``toggleSidebar()``; on iPad a swipe of
    /// the leading column routes through `WorkspaceRootView.applySidebarVisibility`, the SECOND manual entry
    /// point (both record this override; the auto-hide policy writes `sidebarCollapsed` DIRECTLY, never via
    /// either, so it never sets this). While set, `WorkspaceRootView.applyAutoHide` must NOT fight the manual choice on an
    /// UNRELATED tab open/close (a tab-count change that does not cross the 1↔>1 regime edge). Cleared when the
    /// policy crosses that edge — there the default-state opinion ("hidden when only one tab") legitimately
    /// re-asserts. Pure view state; not persisted.
    var manualSidebarOverride = false

    /// The collapsed value the auto-hide policy ITSELF last actuated (i.e. the 1↔>1 regime it last decided), or
    /// `nil` before the first application. Lets ``WorkspaceRootView/applyAutoHide(mode:tabCount:chrome:)`` tell a
    /// regime EDGE (re-assert the auto opinion + clear the manual override) from a WITHIN-regime tab change
    /// (leave a manual ⌘⇧L alone). Bookkeeping only — not persisted, not read by any view.
    var lastAutoHideCollapsed: Bool?

    /// TabSide partition: whether the RIGHT remote-windows column (GUI tabs + the window dock) split item
    /// is collapsed. Starts COLLAPSED — a fresh window is terminal-first; the auto policy reveals it the
    /// moment a GUI tab exists (see `WorkspaceRootView.applyGuiAutoReveal`) and re-collapses when the last
    /// one closes. Pure view state — not persisted.
    var guiCollapsed = true

    /// Set whenever the user MANUALLY toggles the windows panel (⌘⇧E / palette). While set, the GUI-tab-count
    /// auto policy must not fight the manual choice WITHIN a regime (0↔>0 edges re-assert and clear it) —
    /// the exact `manualSidebarOverride` discipline, mirrored for the right column.
    var manualGuiOverride = false

    /// The collapsed value the GUI auto-reveal policy itself last actuated (`nil` before the first
    /// application) — lets the policy tell a 0↔>0 regime EDGE from a within-regime tab change. Bookkeeping
    /// only; not persisted, not read by any view.
    var lastAutoGuiCollapsed: Bool?

    /// Manual entry point for the TABS-panel toggle (⌘⇧L / titlebar / palette; the iPad column swipe is the other,
    /// via `WorkspaceRootView.applySidebarVisibility`). Records the manual override so the auto-hide policy won't
    /// revert it on an unrelated tab open/close (E19 WI-7: "do NOT fight a manual ⌘⇧L").
    func toggleSidebar() {
        sidebarCollapsed.toggle()
        manualSidebarOverride = true
    }

    /// Manual entry point for the WINDOWS-panel toggle (⌘⇧E / palette) — records the manual override so the
    /// GUI auto-reveal policy won't revert it on an unrelated GUI tab open/close.
    func toggleWindowsPanel() {
        guiCollapsed.toggle()
        manualGuiOverride = true
    }

    /// Flip the window-pin flag ("Pin Window"). The macOS scene's `.onChange(of: chrome.pinned)` actuates
    /// `NSWindow.level`; on iOS this is an inert flag flip (no floating-window concept).
    func togglePin() { pinned.toggle() }
}
#endif
