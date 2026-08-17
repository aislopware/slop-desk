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

import SlopDeskWorkspaceCore

@MainActor
package enum WorkspaceChromePolicy {
    /// The window-title fallback (empty workspace / no active pane) — the product name.
    package static let productName = "SlopDesk"

    /// The single place the `auto-hide-tabs-panel` policy ACTUATES. Apply the pure
    /// ``SidebarAutoHidePolicy/desiredCollapsed(mode:tabCount:)`` decision to the live
    /// `chrome.sidebarCollapsed`, but ONLY when the policy has an opinion (mode `.auto`); a `nil`
    /// opinion (`.default`/`.always`) is left untouched.
    ///
    /// The `.auto` decision flips ONLY across the 1↔>1 tab-count regime (`desired == tabCount <= 1`),
    /// so actuation is gated on a regime EDGE — the first application (`lastAutoHideCollapsed == nil`)
    /// or a `desired` differing from the last value the policy drove. ON that edge the default-state
    /// opinion ("hidden when only one tab") re-asserts: clear any manual override and actuate. WITHIN
    /// a regime (an UNRELATED tab open/close — e.g. 2→3 tabs — that does not flip `desired`) a manual
    /// ⌘⇧L is honored and NEVER fought. The `!= desired` write guard avoids a redundant `@Observable`
    /// invalidation.
    package static func applyAutoHide(
        mode: AutoHideTabsPanelMode, tabCount: Int, chrome: WorkspaceChromeState,
    ) {
        guard let desired = SidebarAutoHidePolicy.desiredCollapsed(mode: mode, tabCount: tabCount) else { return }
        let isRegimeEdge = chrome.lastAutoHideCollapsed != desired
        chrome.lastAutoHideCollapsed = desired
        if isRegimeEdge {
            // 1↔>1 transition (or first apply): the auto default-state opinion wins, manual override cleared.
            chrome.manualSidebarOverride = false
        } else if chrome.manualSidebarOverride {
            // Same regime + a live manual override: leave the user's ⌘⇧L choice in place.
            return
        }
        if chrome.sidebarCollapsed != desired {
            chrome.sidebarCollapsed = desired
        }
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
