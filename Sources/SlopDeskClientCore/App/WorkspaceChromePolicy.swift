// WorkspaceChromePolicy — the chrome decisions that were living inside the root VIEW.
//
// Three pure functions the two shells both need, and none of them draws: whether the TABS panel
// should be hidden right now, what a manual reveal/hide has to record so the auto-hide policy stops
// fighting the user, and what the window is called. They sat as `static func`s on
// `WorkspaceRootView` because that is where they were first needed — which made the macOS half and
// the iOS half of a forked root view reach across into each other's file for a decision neither
// half owns (docs/56 §3: a UI target holds views only).
//
// Each is `@MainActor` and each is unit-pinned without a live view, a split or an `NSWindow`.

import CSlopDeskFFI
import SlopDeskWorkspaceCore

@MainActor
package enum WorkspaceChromePolicy {
    /// The window-title fallback (empty workspace / no active pane) — the product name.
    package static let productName = "SlopDesk"

    /// The single place the `auto-hide-tabs-panel` policy ACTUATES. The arbitration — which mode has
    /// an opinion at all, the 1↔>1 regime edge that lets it re-assert, and the manual ⌘⇧L it must not
    /// fight within a regime — is `slopdesk_workspace::chrome::apply_auto_hide`. What is left here is
    /// the `@Observable` write, guarded per field so a decision that changed nothing does not
    /// invalidate the whole root view.
    package static func applyAutoHide(
        mode: AutoHideTabsPanelMode, tabCount: Int, chrome: WorkspaceChromeState,
    ) {
        let next = slopdesk_ws_sidebar_apply_auto_hide(
            mode.ffiByte, max(0, tabCount),
            SlopDeskWsSidebarState(
                collapsed: chrome.sidebarCollapsed,
                manual_override: chrome.manualSidebarOverride,
                last_auto: chrome.lastAutoHideCollapsed ?? false,
                last_auto_present: chrome.lastAutoHideCollapsed != nil,
            ),
        )
        let lastAuto = next.last_auto_present ? next.last_auto : nil
        if chrome.lastAutoHideCollapsed != lastAuto { chrome.lastAutoHideCollapsed = lastAuto }
        if chrome.manualSidebarOverride != next.manual_override {
            chrome.manualSidebarOverride = next.manual_override
        }
        if chrome.sidebarCollapsed != next.collapsed { chrome.sidebarCollapsed = next.collapsed }
    }

    /// A user swipe of the iPad's leading TABS column — the SECOND manual entry point besides
    /// ``WorkspaceChromeState/toggleSidebar`` — writes the shared `chrome.sidebarCollapsed` flag AND,
    /// when it GENUINELY flips it (a real collapse/reveal, not a SwiftUI echo of the value the
    /// auto-hide policy just set), records `manualSidebarOverride` so ``applyAutoHide(mode:tabCount:chrome:)``
    /// honors the swipe like ⌘⇧L. Without this an iPad user who swipes the panel away at >1 tabs
    /// would have it forcibly REVEALED on the next within-regime tab open/close (policy sees no
    /// override → re-asserts `desired=false`). The `!=` guard distinguishes a genuine swipe from the
    /// binding echo SwiftUI fires when the getter-derived value is written back unchanged, so a
    /// policy-driven change is never mis-recorded as manual.
    package static func applySidebarCollapsed(_ collapsed: Bool, chrome: WorkspaceChromeState) {
        guard collapsed != chrome.sidebarCollapsed else { return }
        chrome.manualSidebarOverride = true
        chrome.sidebarCollapsed = collapsed
    }

    /// The macOS WINDOW title: the active pane's display label — the SAME ``RailRowsBuilder/rowTitle``
    /// the sidebar row + hover-reveal titlebar show — so the window's name (Window menu / Mission
    /// Control / screenshot files / accessibility) tracks the FOCUSED pane instead of a static app
    /// name. Reading the active pane + its spec here registers the `@Observable` store's dependencies,
    /// so a pane switch, a live OSC-0/2 title, or a `cd` (which changes the cwd folder name) re-titles
    /// the window. Falls back to the product name for an empty workspace (no active pane / session).
    package static func windowTitle(for store: WorkspaceStore) -> String {
        guard let session = store.tree.activeSession,
              let paneID = session.activeTab?.activePane
        else { return productName }
        let spec = session.specs[paneID]
        let kind = spec?.kind ?? .terminal
        // The `paneForegroundProcess` read is GUARDED by the SAME `RailStructureKey.titledByProcess`
        // escape-order check the sidebar's structural fingerprint uses: an unconditional read would make
        // `.navigationTitle` — hence the WHOLE root view body — a dependent of the WHOLE process dict, so a
        // background pane's 1Hz process tick would re-evaluate the root view even though only a cwd-less,
        // non-renamed terminal pane's title ever depends on that dict.
        let cwd = store.paneCwd(for: paneID)
        let titledByProcess = RailStructureKey.titledByProcess(kind: kind, spec: spec, cwd: cwd)
        let title = RailRowsBuilder.rowTitle(
            kind: kind, spec: spec, cwd: cwd, liveTitle: store.liveProgramTitle(for: paneID),
            processLabel: titledByProcess ? store.paneForegroundProcess[paneID] : nil,
        )
        // The titlebar is SYSTEM-drawn — no custom-font splice can reach it, so a nerd-font glyph
        // is STRIPPED rather than shown as a notdef box (the one surface that degrades by removal).
        let stripped = NerdSymbolFont.strippingSymbols(title)
        return stripped.isEmpty ? productName : stripped
    }
}
