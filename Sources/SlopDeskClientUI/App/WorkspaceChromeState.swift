// WorkspaceChromeState — the small @Observable chrome model the toolbar toggles drive.
//
// Owns the sidebar collapse flag the sidebar's own toggle (and the titlebar's collapsed-state reopen
// button) flips. The macOS
// `WorkspaceSplitRepresentable.updateNSViewController` reads it each update and animates the matching
// `NSSplitViewItem.isCollapsed`. Kept separate from `WorkspaceStore` (whose legacy `sidebarCollapsed`
// predates the native rebuild and isn't read by the new navigator) so the chrome flags live in one
// place and reading them in the SwiftUI body re-invalidates the representable.

#if canImport(SwiftUI)
import Defaults
import Foundation
import SlopDeskWorkspaceCore

@MainActor
@Observable
final class WorkspaceChromeState {
    /// Whether the left navigator (sidebar) split item is collapsed.
    var sidebarCollapsed = false
    /// Whether the RIGHT Host Windows rail (docs/45) split item is collapsed. Seeded from the
    /// persisted default (visible on first launch — the compact strip earns its pixels); every
    /// toggle writes the choice back so it survives relaunch. Unlike the left sidebar there is no
    /// auto-hide policy — the ONE owner of this flag is the user's toggle.
    var hostRailCollapsed = Defaults[.hostWindowsRailCollapsed]
    /// Whether the rail renders COMPACT (56pt icon strip) vs WIDE (icon + title rows) — a STICKY
    /// width state (the VS Code / Material rail convention: width is an intentional choice, never a
    /// hover transient). Flipped by the rail divider's drag-snap or double-click
    /// (`SlopDeskSplitViewController.endRailDividerDrag` / `toggleRailCompact`); persisted like the
    /// collapse flag. Orthogonal to `hostRailCollapsed` — hiding remembers the flavour it reopens to.
    var hostRailCompact = Defaults[.hostWindowsRailCompact]
    /// Whether the window is PINNED (View ▸ Pin Window — keep-on-top). Lives with the other
    /// chrome flags so reading it in the SwiftUI scene body re-invalidates the introspect-bearing scene; the
    /// macOS `NSWindow` glue maps it to `NSWindow.level` (`.floating` ⇄ `.normal`). Pure view
    /// state — `false` resting (a fresh window is not pinned), no wire / persistence. iOS has no resizable
    /// floating window, so the flag is inert there (documented no-op, never a dead toggle).
    var pinned = false

    /// Auto-hide-tabs-panel: set whenever the user MANUALLY toggles the TABS panel — on macOS ⌘⇧L,
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

    /// Manual entry point for the TABS-panel toggle (⌘⇧L / titlebar / palette; the iPad column swipe is the other,
    /// via `WorkspaceRootView.applySidebarVisibility`). Records the manual override so the auto-hide policy won't
    /// revert it on an unrelated tab open/close ("do NOT fight a manual ⌘⇧L").
    func toggleSidebar() {
        sidebarCollapsed.toggle()
        manualSidebarOverride = true
    }

    /// Flip the window-pin flag ("Pin Window"). The macOS scene's `.onChange(of: chrome.pinned)` actuates
    /// `NSWindow.level`; on iOS this is an inert flag flip (no floating-window concept).
    func togglePin() { pinned.toggle() }

    /// Toggle the Host Windows rail (⌘⇧R / palette / titlebar — docs/45) and persist the choice.
    /// The macOS split shell reads `hostRailCollapsed` in `updateNSViewController` and animates the
    /// third split item; the feed's renewal loop reads it as a lifecycle gate (collapsed = 0 Hz).
    func toggleHostWindows() {
        hostRailCollapsed.toggle()
        Defaults[.hostWindowsRailCollapsed] = hostRailCollapsed
    }

    /// Set the rail's compact/wide flavour (divider drag-snap release + divider double-click) and
    /// persist it. Idempotent — a no-change call writes nothing and re-triggers nothing.
    func setHostRailCompact(_ compact: Bool) {
        guard hostRailCompact != compact else { return }
        hostRailCompact = compact
        Defaults[.hostWindowsRailCompact] = compact
    }
}
#endif
