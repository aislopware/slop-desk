// WorkspaceChromeState — the small @Observable chrome model the toolbar toggles drive.
//
// Owns the sidebar collapse flag the sidebar's own toggle (and the titlebar's collapsed-state reopen
// button) flips. The macOS
// `WorkspaceSplitRepresentable.updateNSViewController` reads it each update and animates the matching
// `NSSplitViewItem.isCollapsed`. Kept separate from `WorkspaceStore` (whose legacy `sidebarCollapsed`
// predates the native rebuild and isn't read by the new navigator) so the chrome flags live in one
// place and reading them in the SwiftUI body re-invalidates the representable.

import Defaults
import Foundation
import SlopDeskWorkspaceCore

@MainActor
@Observable
package final class WorkspaceChromeState {
    package init() {}

    /// Whether the left navigator (sidebar) split item is collapsed.
    package var sidebarCollapsed = false

    /// The navigator column's LIVE width in points, republished by
    /// ``SlopDeskSplitViewController`` on every divider step. Exists for the ONE thing mounted at
    /// window level that has to line up with a column edge: the band's status rollup
    /// (``RailStatusRollupMount``), which parks its trailing edge on the navigator's own gutter.
    ///
    /// ⚠️ A constant would be wrong — the item is resizable (`minimumThickness` 220,
    /// `maximumThickness` 360), so a hard-coded 220 would unalign the cluster the first time anyone
    /// drags the divider.
    ///
    /// ⚠️ It CHANGES ON EVERY FRAME OF A DRAG, so read it only from a LEAF. Reading it in a body
    /// that owns subtrees (the window root, a column) makes that whole subtree a dependency of the
    /// divider's motion — the re-render storm `RailRowsMemo` exists to prevent, arriving by a new
    /// door. Kept UNCLAMPED and untouched while collapsed: the collapsed cluster does not read it.
    ///
    /// `nil` until the split view has reported one, which is the honest resting value: this layer
    /// knows what the navigator MEASURES, not what a design says it should measure at rest. The
    /// reader supplies its own resting token for the gap (docs/56) — and the two UI halves lay the
    /// navigator out differently, so a single seed here would have been wrong for one of them.
    package var navigatorWidth: CGFloat?
    /// Whether the RIGHT code panel (project-scoped embedded VS Code) is collapsed. Seeded from the
    /// persisted `Defaults[.codeSidebarCollapsed]` (unlike the session-scoped left panel — expanding the
    /// code panel is a workstyle choice that survives relaunch); ``toggleCodeSidebar()`` writes it back.
    /// The macOS `WorkspaceSplitRepresentable.updateNSViewController` animates the matching split item.
    package var codeSidebarCollapsed = Defaults[.codeSidebarCollapsed]
    /// Which surface the RIGHT panel is showing. It lives here rather than in the panel's own view
    /// state because the panel is no longer the only thing that renders its tabs: collapsing leaves
    /// a RAIL carrying the same four tabs turned on their side (``PanelRail``), and two surfaces
    /// showing one selection cannot each own it. Per-window, not persisted — the panel always comes
    /// back on Files, its primary surface.
    package var panelSurface: PanelSurface = .code
    /// Whether the window is PINNED (View ▸ Pin Window — keep-on-top). Lives with the other
    /// chrome flags so reading it in the SwiftUI scene body re-invalidates the introspect-bearing scene; the
    /// macOS `NSWindow` glue maps it to `NSWindow.level` (`.floating` ⇄ `.normal`). Pure view
    /// state — `false` resting (a fresh window is not pinned), no wire / persistence. iOS has no resizable
    /// floating window, so the flag is inert there (documented no-op, never a dead toggle).
    package var pinned = false

    /// Auto-hide-tabs-panel: set whenever the user MANUALLY toggles the TABS panel — on macOS ⌘⇧L,
    /// the titlebar button, and the palette row all flip the flag through ``toggleSidebar()``; on iPad a swipe of
    /// the leading column routes through `WorkspaceRootView.applySidebarVisibility`, the SECOND manual entry
    /// point (both record this override; the auto-hide policy writes `sidebarCollapsed` DIRECTLY, never via
    /// either, so it never sets this). While set, `WorkspaceRootView.applyAutoHide` must NOT fight the manual choice on an
    /// UNRELATED tab open/close (a tab-count change that does not cross the 1↔>1 regime edge). Cleared when the
    /// policy crosses that edge — there the default-state opinion ("hidden when only one tab") legitimately
    /// re-asserts. Pure view state; not persisted.
    package var manualSidebarOverride = false

    /// The collapsed value the auto-hide policy ITSELF last actuated (i.e. the 1↔>1 regime it last decided), or
    /// `nil` before the first application. Lets ``WorkspaceRootView/applyAutoHide(mode:tabCount:chrome:)`` tell a
    /// regime EDGE (re-assert the auto opinion + clear the manual override) from a WITHIN-regime tab change
    /// (leave a manual ⌘⇧L alone). Bookkeeping only — not persisted, not read by any view.
    package var lastAutoHideCollapsed: Bool?

    /// Manual entry point for the TABS-panel toggle (⌘⇧L / titlebar / palette; the iPad column swipe is the other,
    /// via `WorkspaceRootView.applySidebarVisibility`). Records the manual override so the auto-hide policy won't
    /// revert it on an unrelated tab open/close ("do NOT fight a manual ⌘⇧L").
    package func toggleSidebar() {
        sidebarCollapsed.toggle()
        manualSidebarOverride = true
    }

    /// Flip the window-pin flag ("Pin Window"). The macOS scene's `.onChange(of: chrome.pinned)` actuates
    /// `NSWindow.level`; on iOS this is an inert flag flip (no floating-window concept).
    package func togglePin() { pinned.toggle() }

    /// Toggle the RIGHT code panel (⌘⇧R / View menu / palette) and persist the choice — the one manual
    /// entry point (no auto-hide policy touches this panel, so no override bookkeeping like the left one).
    package func toggleCodeSidebar() {
        codeSidebarCollapsed.toggle()
        Defaults[.codeSidebarCollapsed] = codeSidebarCollapsed
    }

    /// Reveal (never collapse) the RIGHT code panel — the open-in-code-panel actuation: a file the
    /// user just sent to the embedded workbench must be visible, and opening a file IS a workstyle
    /// choice, so it persists like the manual toggle. Idempotent while expanded.
    package func revealCodeSidebar() {
        guard codeSidebarCollapsed else { return }
        codeSidebarCollapsed = false
        Defaults[.codeSidebarCollapsed] = false
    }

    /// The project roots whose embedded workbench has been EXPLICITLY opened. The code panel used
    /// to boot the workbench for whatever project focus landed on — every project switch paid a
    /// multi-second workbench boot plus a warm per-project webview for a surface the user often
    /// never looked at. Opening is an act, not a side effect of focus (user-directed 2026-08-07):
    /// a root outside this set renders the panel's open gate, and only the gate's button — or an
    /// explicit open-in-editor on one of the project's files — admits it. Lives here rather than
    /// on the panel's own model because the verb-19 reveal fires from the terminal leaf's wiring,
    /// which can reach the window's chrome but not the panel's private `@State`.
    ///
    /// PERSISTED (`Defaults[.openedCodeProjects]`, user-directed 2026-08-07 — re-scoping the
    /// same-day session-scoped decision): once a project's workbench has been asked for, a
    /// relaunch or reconnect must come back to it booting, not to the gate — re-admitting a
    /// known project cost a click plus a cold boot on every startup. The gate still fronts every
    /// root the user never opened.
    package private(set) var openedCodeProjects = Defaults[.openedCodeProjects]

    /// Admit a project through the code panel's open gate — the gate button and the
    /// open-in-editor reveal are the only two callers, both of them a user gesture — and persist
    /// the admission for the next launch.
    package func openCodeProject(_ root: String) {
        openedCodeProjects.insert(root)
        Defaults[.openedCodeProjects] = openedCodeProjects
    }
}

/// One of the RIGHT panel's four surfaces — the thing its tab row (and, while collapsed, its rail)
/// selects. Two REAL host resources (the project's workbench, the host's simulator and device sets)
/// and one announced-but-empty one; they share no protocol, which is why they are four surfaces
/// rather than one with modes.
package enum PanelSurface {
    case code
    case simulators
    case android
    case desktop
}
