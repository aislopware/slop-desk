// OverlayCoordinator — the single `@MainActor @Observable` owner of the floating-overlay layer's state
// (warp-overlays-actions.md §4: a central reducer the chrome controls dispatch into). It owns:
//   - the command-palette presentation (mode + active filter + query) and its mixer,
//   - the Settings overlay flag,
//   - the toast stack (wired to the store's onPaneNotification / onLongCommandNotify / onAgentAttention),
//   - and routes a palette row's `PaletteAction` to the store, then closes.
//
// Mounted once at `WorkspaceRootView` in a ZStack above the whole window; the Omnibar/keybinds dispatch
// `openPalette`, the L4 Settings pill + the palette "Open Settings" row dispatch `openSettings`. The modal
// (busy-close confirmation) is driven directly off the store's `pendingCloseSpec` — the coordinator only
// owns palette/settings/toasts.

import AislopdeskAgentDetect
import AislopdeskWorkspaceCore
import Foundation
import Observation

/// How the palette was opened (warp-overlays-actions.md §2.1) — purely cosmetic (the omnibar shows a
/// friendlier label) but kept so the title-bar-search vs ⌘⇧P entry points are distinguishable.
public enum PaletteMode: Sendable, Equatable {
    case command
    case titleBarSearch
}

@preconcurrency
@MainActor
@Observable
public final class OverlayCoordinator {
    // MARK: Palette state

    /// Whether the command palette is presented.
    public private(set) var paletteVisible = false
    /// The mode the palette was opened in (cosmetic).
    public private(set) var paletteMode: PaletteMode = .command
    /// The live query text (the palette view's search field binds this).
    public var paletteQuery = ""
    /// The active filter chip (nil ⇒ all sources / zero-state chips shown when query empty).
    public var paletteFilter: QueryFilter?
    /// The keyboard-selected row index into the SELECTABLE rows of the current result list.
    public var paletteSelection = 0

    // MARK: Settings state

    /// Whether the Settings overlay is presented.
    public private(set) var settingsVisible = false

    // MARK: Connect-to-Host state

    /// Whether the Connect-to-Host overlay (the host/port editor) is presented. Opened by the top-bar
    /// status pill and the "Connect to Host…" palette action — the only surfaces that let a user point the
    /// client at a non-default host (the app-global ``AppConnection`` form is otherwise unbound by any view).
    public private(set) var connectVisible = false

    // MARK: Cheat-sheet state

    /// Whether the keyboard cheat sheet (⌘/) is presented. Its rows are generated from
    /// ``WorkspaceBindingRegistry/groupedForDisplay`` so the displayed glyphs can't drift from the chords.
    public private(set) var cheatSheetVisible = false

    // MARK: Remote-window picker state (L6)

    /// Whether the Remote-Window picker modal is presented (the `/remote-control` pill + the "New Remote
    /// Window Tab" palette action open it; a pick opens a `.remoteGUI` pane).
    public private(set) var remotePickerVisible = false
    /// The dedicated discovery-driving model for the live picker (NOT a pane's). Built per open from a
    /// fresh app target so its `refresh()` queries the current host. `nil` until first opened.
    @ObservationIgnored public private(set) var remotePickerModel: RemoteWindowModel?
    /// Resolves the app-global ``ConnectionTarget`` for the picker's discovery query. Injected by the root.
    @ObservationIgnored public var connectionTarget: @MainActor () -> ConnectionTarget = { .default }

    // MARK: Toasts

    /// The live toast stack (newest last). Bounded; auto-dismissed by the view's timers.
    public private(set) var toasts: [Toast] = []
    private static let toastCap = 4

    // MARK: Recents (mirrors the store's recent commands into palette item ids)

    /// The mixer that combines the data sources. Rebuilt per open from a fresh store snapshot so the TABS
    /// source reflects the live tree. `nil` until first opened.
    @ObservationIgnored public private(set) var mixer: SearchMixer?

    private weak var store: WorkspaceStore?

    public init(store: WorkspaceStore? = nil) { self.store = store }

    /// Attach the live store (the root view does this once).
    public func attach(_ store: WorkspaceStore) { self.store = store }

    // MARK: Palette open / close

    /// Open the palette. `titleBarSearch` mode reads identically but starts empty (the omnibar friendly
    /// label); `command` mode is the ⌘⇧P entry. Rebuilds the mixer from a fresh store snapshot.
    public func openPalette(mode: PaletteMode = .command, query: String = "") {
        rebuildMixer()
        paletteMode = mode
        paletteQuery = query
        paletteFilter = nil
        paletteSelection = 0
        paletteVisible = true
    }

    /// Toggle the palette (the ⌘⇧P binding).
    public func togglePalette(mode: PaletteMode = .command) {
        if paletteVisible { closePalette() } else { openPalette(mode: mode) }
    }

    public func closePalette() {
        paletteVisible = false
        paletteQuery = ""
        paletteFilter = nil
        paletteSelection = 0
    }

    /// Rebuild the mixer from the current store (TABS source = a live snapshot; the rest are fixed/stub).
    public func rebuildMixer() {
        var sources: [any PaletteDataSource] = [ActionsPaletteSource()]
        if let store {
            sources.append(TabsPaletteSource.snapshot(store))
        }
        // Files / conversations / repos: protocol present, no client data yet (TODO host wires).
        sources.append(EmptyPaletteSource(filter: .files, sectionTitle: "Files"))
        sources.append(EmptyPaletteSource(filter: .conversations, sectionTitle: "Conversations"))
        sources.append(EmptyPaletteSource(filter: .repos, sectionTitle: "Repositories"))
        mixer = SearchMixer(sources: sources)
    }

    // MARK: Palette results (view binds these)

    /// The current ordered, sectioned result list. Empty query ⇒ the recents block (or the full action
    /// catalog when there are no recents) so the palette is never blank.
    public var paletteResults: [PaletteItem] {
        guard let mixer else { return [] }
        let q = paletteQuery.trimmingCharacters(in: .whitespaces)
        if q.isEmpty, paletteFilter == nil {
            return zeroStateResults()
        }
        return mixer.results(query: q, activeFilter: paletteFilter)
    }

    /// Zero-state (empty query, no filter): the recent commands first, then the full action catalog under a
    /// separator (warp-overlays-actions.md §1.5 — recents + suggested).
    private func zeroStateResults() -> [PaletteItem] {
        var out: [PaletteItem] = []
        let recentItems = recentPaletteItems()
        if !recentItems.isEmpty {
            out.append(.separator("Recents", filter: .actions))
            out.append(contentsOf: recentItems)
        }
        out.append(.separator("Actions", filter: .actions))
        out.append(contentsOf: ActionsPaletteSource.catalog)
        return out
    }

    /// Map the store's `recentCommands` ring onto the action catalog rows (by matching the verb), in MRU
    /// order. Verbs not present in the catalog (focus/cycle/etc.) are skipped.
    private func recentPaletteItems() -> [PaletteItem] {
        guard let store else { return [] }
        var out: [PaletteItem] = []
        for command in store.recentCommands {
            if let item = Self.catalogItem(for: command) { out.append(item) }
        }
        return out
    }

    /// The catalog row that corresponds to `command` (used to surface recents). nil ⇒ no catalog row.
    static func catalogItem(for command: WorkspaceCommand) -> PaletteItem? {
        let id: String? =
            switch command {
            case .newPane(.terminal),
                 .newPaneDefault: "action.newTerminalTab"
            case .newPane(.remoteGUI): "action.newRemoteTab"
            case .newPane: nil
            case .closePane: "action.closePane"
            case .toggleZoom: "action.toggleZoom"
            case .renamePane: "action.renamePane"
            case .reconnectPane: "action.reconnect"
            default: nil
            }
        guard let id else { return nil }
        return ActionsPaletteSource.catalog.first { $0.id == id }
    }

    /// The selectable rows (non-separators) of the current result list — keyboard nav target.
    public var selectableResults: [PaletteItem] { SearchMixer.selectable(paletteResults) }

    // MARK: Palette keyboard / accept

    /// Move the keyboard selection by `delta`, clamped to the selectable rows (wrapping not done — Warp
    /// clamps). A no-op when there are no selectable rows.
    public func moveSelection(_ delta: Int) {
        let n = selectableResults.count
        guard n > 0 else { paletteSelection = 0
            return
        }
        let next = paletteSelection + delta
        paletteSelection = max(0, min(n - 1, next))
    }

    /// Accept the currently keyboard-selected row.
    public func acceptSelected() {
        let rows = selectableResults
        guard paletteSelection >= 0, paletteSelection < rows.count else { return }
        run(rows[paletteSelection])
    }

    /// Run one palette row's action against the store, then close (or apply a filter in place). Separators
    /// are no-ops. This is the ONE place a palette intent becomes a store mutation.
    public func run(_ item: PaletteItem) {
        guard !item.isSeparator else { return }
        switch item.action {
        case let .store(closure):
            if let store { closure(store) }
            closePalette()
        case let .command(command):
            if let store { apply(command, to: store) }
            closePalette()
        case let .selectFilter(filter):
            paletteFilter = filter
            paletteSelection = 0
        case .openSettings:
            closePalette()
            openSettings()
        case .openConnect:
            closePalette()
            openConnect()
        case .openCheatSheet:
            closePalette()
            openCheatSheet()
        case .openRemotePicker:
            closePalette()
            openRemotePicker()
        case .noOp:
            break
        }
    }

    /// Select a filter chip (zero-state) — narrows the result set in place (palette stays open).
    public func selectFilter(_ filter: QueryFilter) {
        paletteFilter = (paletteFilter == filter) ? nil : filter
        paletteSelection = 0
    }

    // MARK: Settings

    public func openSettings() { settingsVisible = true }
    public func closeSettings() { settingsVisible = false }

    // MARK: Connect-to-Host

    public func openConnect() { connectVisible = true }
    public func closeConnect() { connectVisible = false }

    // MARK: Cheat sheet (⌘/)

    public func toggleCheatSheet() { cheatSheetVisible.toggle() }
    public func closeCheatSheet() { cheatSheetVisible = false }
    public func openCheatSheet() { cheatSheetVisible = true }

    // MARK: Remote-window picker (L6 / W1)

    /// Present the Remote-Window picker (the `/remote-control` pill + the "New Remote Window Tab" action).
    /// Builds a fresh discovery-driving ``RemoteWindowModel`` bound to the live app target so its
    /// `refresh()` lists the current host's windows.
    public func openRemotePicker() {
        remotePickerModel = RemoteWindowModel(target: connectionTarget)
        remotePickerVisible = true
    }

    public func closeRemotePicker() {
        remotePickerVisible = false
        remotePickerModel = nil
    }

    /// A window was chosen in the picker → open a NEW `.remoteGUI` tab pre-bound to it (logic-api §4),
    /// then close the picker. The materialized pane's own ``RemoteWindowModel`` drives the live stream.
    public func openRemoteWindow(_ summary: RemoteWindowSummary) {
        store?.newRemoteWindowTab(
            windowID: summary.windowID, title: summary.title, appName: summary.appName,
        )
        store?.recordRecentCommand(.newPane(.remoteGUI))
        closeRemotePicker()
    }

    // MARK: Toasts

    /// Push a toast (newest last); evicts the oldest beyond the cap and de-dupes by id (a newer same-id
    /// toast replaces the old one, warp `object_id` discipline).
    public func pushToast(_ toast: Toast) {
        toasts.removeAll { $0.id == toast.id }
        toasts.append(toast)
        if toasts.count > Self.toastCap {
            toasts.removeFirst(toasts.count - Self.toastCap)
        }
    }

    /// Dismiss a toast by id (the X button or the auto-dismiss timer).
    public func dismissToast(_ id: String) {
        toasts.removeAll { $0.id == id }
    }
}
