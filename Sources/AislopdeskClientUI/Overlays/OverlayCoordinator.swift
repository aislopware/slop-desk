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

/// How the palette was opened (warp-overlays-actions.md §2.1) — governs only the friendly omnibar label now.
/// BOTH entry points are the verbs-only ⌘⇧P Command Palette; the multi-source ⌘⇧O Open-Quickly jump-to is
/// its OWN surface in E11 (`OpenQuicklyView` / `OpenQuicklyModel`), NOT a palette mode — so there is no
/// `openQuickly` case and no `multiSource` flag here (E11 / WI-5 removed the dead palette jump-to path).
public enum PaletteMode: Sendable, Equatable {
    /// ⌘⇧P — the verbs-only Command Palette (actions/verbs grouped by otty category; NO filter chips).
    case command
    /// The title-bar omnibar entry (still verbs-only — a friendlier label over the command palette).
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
    /// The live query text (the palette view's search field binds this). Editing it RESETS the keyboard
    /// selection to the first row (E2 fix): the ranked result set changes with every keystroke, so a parked
    /// index would otherwise point past the end after a narrowing edit — the highlight would vanish and ↩
    /// would silently no-op (`acceptSelected` guards `selection < rows.count`). Row 0 is always the first
    /// selectable row (separators are excluded from the selection index), so the highlight always lands on a
    /// valid, runnable row.
    public var paletteQuery = "" {
        didSet {
            guard paletteQuery != oldValue else { return }
            paletteSelection = 0
        }
    }

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

    // MARK: Global Search state (E5 / WI-4)

    /// Whether the cross-tab Global Search surface (⇧⌘F) is presented. UNLIKE the four scrimmed panels this is
    /// a NON-modal, NON-scrimmed full surface — the closest faithful equivalent to otty's dedicated results
    /// *tab* (E5 divergence #1), so it must NOT dim the workspace and is deliberately EXCLUDED from
    /// ``anyModalVisible``. ``OverlayHostView`` mounts it WITHOUT a ``Scrim`` and gates its own hit-testing on
    /// this flag directly. Reopening it RESTORES the store's last in-memory results (held by
    /// ``WorkspaceStore/globalSearch``) until the query is re-run.
    public private(set) var globalSearchVisible = false

    // MARK: Open-Quickly state (E11 / WI-5)

    /// Whether the Open-Quickly picker (⌘⇧O All / ⌘J Current) is presented. It FOLDS in E10's Jump-To: one
    /// floating, centered, SCRIMMED quick-switcher card over the terminal (`open-quickly.png`), so it is
    /// included in ``anyModalVisible`` and ``OverlayHostView`` mounts it behind a ``Scrim``. The picker reads
    /// its own sources (open panes / recents / folders / agents / the focused pane's links + OSC-133 command
    /// index) — like Global Search, the coordinator owns only the visibility flag + the active pill, not the
    /// per-source data.
    public private(set) var openQuicklyVisible = false

    /// The pill the picker opens to / is currently showing (``OpenQuicklyFilter``). ⌘⇧O opens ``.all``; ⌘J
    /// opens ``.current``; Tab/⇧Tab + the picker-local pill chords drive ``setOpenQuicklyFilter(_:)`` while it
    /// is open. Defaults to ``.all`` (the ⌘⇧O entry).
    public private(set) var openQuicklyFilter: OpenQuicklyFilter = .all

    // MARK: Peek & Reply state (P4 / E13 WI-8 — answer a blocked agent INLINE, ⌘⌥J)

    /// Whether the Peek & Reply overlay (⌘⌥J) is presented. A centered, SCRIMMED card over the oldest pane
    /// needing attention (``WorkspaceStore/peekReplyTargetPane(excluding:)``) that lets the user ANSWER a
    /// blocked agent INLINE — observe + reply, **NEVER an approval gate** (E13 binding directive 2; the agent
    /// is never paused pending an aislopdesk confirmation). Included in ``anyModalVisible`` and mounted behind
    /// a ``Scrim`` by ``OverlayHostView``.
    public private(set) var peekReplyVisible = false

    /// The advance-to-next exclusion set accumulated while the overlay is open (E13 WI-8): each answered pane
    /// is added here so ``peekReplyTarget()`` skips it on the immediate advance (the just-answered pane may
    /// still report `.needsPermission` until the host re-reports). Reset on every open / close so a fresh open
    /// re-targets cleanly.
    public private(set) var peekReplyExcluding: Set<PaneID> = []

    // MARK: Send-to-Chat state (E13 WI-5 / ES-E13-5 — ⌘⌃↩)

    /// Whether the Send-to-Chat dialog (⌘⌃↩) is presented. A centered, SCRIMMED card over the workspace
    /// (`send-to-chat-frame-03/04.png`) that quotes the active pane's selection / last command and routes the
    /// composed message to a chosen Claude-only agent pane. Included in ``anyModalVisible`` and mounted behind
    /// a ``Scrim`` by ``OverlayHostView``. Opening HONESTLY no-ops when there is nothing to quote (no selection
    /// + no command block), so ⌘⌃↩ on an empty pane does nothing rather than flashing an empty card.
    public private(set) var sendToChatVisible = false
    /// The captured quote shown in the dialog (the source title + the verbatim quoted text). `nil` until a
    /// successful capture opens the dialog.
    public private(set) var sendToChatContext: SendToChatContext?
    /// The live Claude-only agent panes the quote can be routed to (built off the store on open). Empty ⇒ the
    /// picker offers only "New session".
    public private(set) var sendToChatSessions: [SendToChatSession] = []
    /// The picker's pre-selected target on open — the last-used session if still live, else the first live
    /// agent pane, else `nil` ("New session"). Resolved via ``SendToChatModel/defaultSession(in:lastUsed:)``.
    public private(set) var sendToChatInitialSelection: PaneID?
    /// The in-memory last-used Send-to-Chat target (the spec's "last-used session is the default"). Updated on
    /// every send + on a manual picker change so the next open pre-selects it.
    @ObservationIgnored private var lastChatTarget: PaneID?
    /// Captures the active pane's quote (selection / last command). Injected by ``WorkspaceRootView`` to read
    /// the live store (``WorkspaceStore/captureSendToChatContext()``); the default reads the attached store, so
    /// a test can override it with a synthetic context. `nil` from it ⇒ nothing to quote ⇒ the dialog stays
    /// closed (the honest no-op).
    @ObservationIgnored public var captureSendToChat: (@MainActor () -> SendToChatContext?)?
    /// Writes the composed message to the system pasteboard (the dialog's "Copy Message"). Injected by the
    /// root (AppKit / UIKit) so the coordinator stays clipboard-framework-agnostic; default no-op (tests /
    /// previews).
    @ObservationIgnored public var copyToPasteboard: @MainActor (String) -> Void = { _ in }

    // MARK: Remote-window picker state (L6)

    /// Whether the Remote-Window picker modal is presented (the `/remote-control` pill + the "New Remote
    /// Window Tab" palette action open it; a pick opens a `.remoteGUI` pane).
    public private(set) var remotePickerVisible = false
    /// The dedicated discovery-driving model for the live picker (NOT a pane's). Built per open from a
    /// fresh app target so its `refresh()` queries the current host. `nil` until first opened.
    @ObservationIgnored public private(set) var remotePickerModel: RemoteWindowModel?
    /// Resolves the app-global ``ConnectionTarget`` for the picker's discovery query. Injected by the root.
    @ObservationIgnored public var connectionTarget: @MainActor () -> ConnectionTarget = { .default }

    // MARK: Chrome toggles (injected by the root, which owns the live `WorkspaceChromeState`)

    /// Toggles the left navigator / Tabs panel. Bound by ``WorkspaceRootView`` to `chrome.toggleSidebar()` so
    /// the "Toggle Tabs Panel" palette row flips the SAME live `chrome.sidebarCollapsed` the ⌘⇧L chord + the
    /// titlebar button + the palette ✓ all read — never the legacy `store.sidebarCollapsed` the native shell
    /// never reads. The default is a no-op (iOS / tests / previews), so the row is never a trap.
    @ObservationIgnored public var toggleSidebar: @MainActor () -> Void = {}
    /// Toggles the right Details / inspector panel. Bound by ``WorkspaceRootView`` to `chrome.toggleInspector()`
    /// (the same live flag ⌘⇧R + the titlebar button drive). No-op by default (iOS / tests / previews).
    @ObservationIgnored public var toggleInspector: @MainActor () -> Void = {}
    /// Jumps the right Details / inspector panel to a specific tab AND reveals it (E9/WI-7, ES-E9-5). Bound by
    /// ``WorkspaceRootView`` (on BOTH platforms) to set the shared `DetailsPanelState.selected` + un-collapse
    /// the inspector (`chrome.inspectorCollapsed = false`). The palette's four `Details: *` rows AND the macOS
    /// View ▸ Details: * menu rows both route here, so every surface drives the same live state. No-op by
    /// default (tests / previews / a pre-`onAppear` scene).
    @ObservationIgnored public var selectDetailsTab: @MainActor (DetailsPanelTab) -> Void = { _ in }
    /// E19/A30 (WI-4): toggles the window-pin flag (otty View ▸ Pin Window). Bound by ``WorkspaceRootView`` to
    /// `chrome.togglePin()` so any palette / command surface routed here flips the SAME live
    /// `WorkspaceChromeState.pinned` the menu Button + the macOS `NSWindow.level` glue read. No-op by default
    /// (iOS / tests / previews), so the seam is never a trap when no Pin-Window row is surfaced.
    @ObservationIgnored public var togglePinWindow: @MainActor () -> Void = {}

    // MARK: Modal gate

    /// Whether ANY focus-stealing modal overlay is presented — the `OverlayHostView` hit-testing gate (E2 /
    /// WI-5). True ⇒ the host's ZStack swallows clicks (the scrim + the centered panel); false ⇒ the host is
    /// transparent to hits so the workspace beneath stays interactive (the always-mounted toast stack is NOT
    /// a modal, so it is gated separately by the host on `!toasts.isEmpty`). Mirrors the four scrimmed panels
    /// the host composes — Settings AND the non-scrimmed Global Search surface (E5) are each presented on their
    /// own surface (Global Search must not dim the workspace), so both are deliberately excluded here; the host
    /// gates Global Search's hit-testing separately on ``globalSearchVisible``.
    public var anyModalVisible: Bool {
        paletteVisible || cheatSheetVisible || connectVisible || remotePickerVisible || openQuicklyVisible
            || peekReplyVisible || sendToChatVisible
    }

    /// Whether a presented overlay must OWN the keyboard — the narrower subset of ``anyModalVisible`` the app's
    /// `isOverlayCapturingKeys` gate reads so the global ``WorkspaceKeyDispatcher`` NSEvent monitor (which
    /// PREEMPTS the responder chain) YIELDS modeled chords to the focused card instead of resolving them
    /// behind it. The Open-Quickly picker, the Peek & Reply card, AND (E13 / WI-5) the Send-to-Chat dialog
    /// each host a focused field / quick-answer chords (`.onKeyPress`), so a modeled ⌘W / ⌘1–9 / ⌘T must reach
    /// them, never destroy / switch a background pane. SINGLE source of truth for that gate (the app's closure
    /// reads THIS), so adding an overlay here keeps the dispatcher honest without duplicating the predicate.
    public var capturesKeyboardWhileVisible: Bool {
        openQuicklyVisible || peekReplyVisible || sendToChatVisible
    }

    // MARK: Toasts

    /// The live toast stack (newest last). Bounded; auto-dismissed by the view's timers.
    public private(set) var toasts: [Toast] = []
    private static let toastCap = 4

    // MARK: Recents (mirrors the store's recent commands into palette item ids)

    /// The mixer that combines the verb-catalog sources (rebuilt per open; verbs-only — ⌘⇧P). `nil` until
    /// first opened.
    @ObservationIgnored public private(set) var mixer: SearchMixer?

    private weak var store: WorkspaceStore?

    /// The app-owned, client-side Folders frecency store (E11 / WI-5) — the backing of the Open-Quickly
    /// **Folders** pill (`⌘Z`). Held weakly (the app owns it; attached once by the root like ``store``). `nil`
    /// on iOS / tests / previews that don't construct one ⇒ the Folders source is simply empty there.
    @ObservationIgnored public private(set) weak var folders: FolderFrecencyStore?

    public init(store: WorkspaceStore? = nil, folders: FolderFrecencyStore? = nil) {
        self.store = store
        self.folders = folders
    }

    /// Attach the live store (the root view does this once).
    public func attach(_ store: WorkspaceStore) { self.store = store }

    /// Attach the app-owned Folders frecency store (the root view does this once, alongside ``attach(_:)``).
    public func attach(folders: FolderFrecencyStore) { self.folders = folders }

    // MARK: Palette open / close

    /// Open the palette. `titleBarSearch` mode reads identically but starts empty (the omnibar friendly
    /// label); `command` mode is the ⌘⇧P entry. Rebuilds the mixer from a fresh store snapshot.
    public func openPalette(mode: PaletteMode = .command, query: String = "") {
        paletteMode = mode // cosmetic (the friendly omnibar label); the mixer is verbs-only regardless of mode.
        rebuildMixer()
        paletteFilter = nil
        paletteQuery = query
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

    /// Rebuild the verbs-only ⌘⇧P mixer: the action catalog grouped into otty categories (Working Directory /
    /// Window / Pane / Tab / View / Shell / Settings), one section header each. A typed query gets one section
    /// header per matching category. (E11 / WI-5: the old multi-source Open-Quickly branch — a live Tabs
    /// snapshot + the file/conversation/repo `EmptyPaletteSource` stubs — was removed; that jump-to is now the
    /// dedicated `OpenQuicklyView`/`OpenQuicklyModel`, NOT a palette mode.)
    public func rebuildMixer() {
        // The verb-catalog categories, plus the live saved-snippet rows (E16 WI-7) and the recipe rows (E16 /
        // M1: Save Recipe… / Open Recipe… + one row per saved `.ottyrecipe`) when a store is attached — each a
        // snapshot taken here so the mixer stays a pure value over the snippets / saved recipes at palette-open.
        // The recipe rows are the cross-platform entry point that makes Save / Open Recipe reachable on iOS too.
        var sources = ActionsPaletteSource.categorySources()
        if let store {
            sources.append(SnippetPaletteSource.snapshot(store))
            sources.append(RecipePaletteSource.snapshot(store))
        }
        mixer = SearchMixer(sources: sources)
    }

    // MARK: Palette results (view binds these)

    /// The current ordered, sectioned result list. Empty query ⇒ the otty-sectioned zero-state (WORKING
    /// DIRECTORY, then Recents, then the catalog grouped by category) so the palette is never blank.
    public var paletteResults: [PaletteItem] {
        guard let mixer else { return [] }
        let q = paletteQuery.trimmingCharacters(in: .whitespaces)
        if q.isEmpty, paletteFilter == nil {
            return zeroStateResults()
        }
        return mixer.results(query: q, activeFilter: paletteFilter)
    }

    /// The current ordered, sectioned result list WITH each row's fzf title-match ranges (``RankedRow``) —
    /// the palette view binds THIS (not ``paletteResults``) so it can highlight the matched code points.
    /// Mirrors ``paletteResults`` exactly but via ``SearchMixer/ranked(query:activeFilter:)``; the zero-state
    /// (empty query, no filter) wraps each recents/catalog row in a range-less ``RankedRow`` (the highlight is
    /// only meaningful for a typed query). Kept alongside ``paletteResults`` so existing callers/tests that
    /// only need the items are unaffected.
    public var rankedResults: [RankedRow] {
        guard let mixer else { return [] }
        let q = paletteQuery.trimmingCharacters(in: .whitespaces)
        if q.isEmpty, paletteFilter == nil {
            return zeroStateResults().map { RankedRow(item: $0) }
        }
        return mixer.ranked(query: q, activeFilter: paletteFilter)
    }

    /// Zero-state (empty query, no filter): the otty-sectioned verb list. WORKING DIRECTORY leads (its header
    /// OWNS the cwd badge in the view, per command-palette.png) with its Copy Path row; then the MRU Recents
    /// block; then the remaining catalog grouped into otty categories (Window / Pane / Tab / View / Settings).
    /// An empty category is skipped (no empty header). Hand-built (rather than `mixer.ranked("")`) so the
    /// aislopdesk-only Recents block can interleave after Working Directory.
    private func zeroStateResults() -> [PaletteItem] {
        var out: [PaletteItem] = []
        // Working Directory first — its header carries the cwd badge; Copy Path (+ TODO(E10) host rows) below.
        let workingDir = ActionsPaletteSource.items(in: .workingDirectory)
        if !workingDir.isEmpty {
            out.append(.separator(PaletteCategory.workingDirectory.label, filter: .actions))
            out.append(contentsOf: workingDir)
        }
        // Recents (MRU), namespaced so they can't collide with the same catalog rows under their categories.
        let recentItems = recentPaletteItems()
        if !recentItems.isEmpty {
            out.append(.separator("Recents", filter: .actions))
            out.append(contentsOf: recentItems)
        }
        // The rest of the catalog, grouped into otty categories in display order (Working Directory already
        // led above). A category with no rows is skipped — no empty section header. (Shell now carries the
        // E17 "Read Only" verb; a still-empty category like a future one stays skipped.)
        for category in PaletteCategory.commandOrder where category != .workingDirectory {
            let items = ActionsPaletteSource.items(in: category)
            guard !items.isEmpty else { continue }
            out.append(.separator(category.label, filter: .actions))
            out.append(contentsOf: items)
        }
        return out
    }

    /// Map the store's `recentCommands` ring onto the action catalog rows (by matching the verb), in MRU
    /// order. Verbs not present in the catalog (focus/cycle/etc.) are skipped. Each row is re-id'd into the
    /// `recent.*` namespace (``PaletteItem/namespacedForRecents()``) so a recents row and its identical
    /// Actions-catalog row never collide on the same `ForEach`/`.id` key — the action is preserved, so accept
    /// still runs the catalog verb.
    private func recentPaletteItems() -> [PaletteItem] {
        guard let store else { return [] }
        var out: [PaletteItem] = []
        for command in store.recentCommands {
            if let item = Self.catalogItem(for: command) { out.append(item.namespacedForRecents()) }
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

    /// Accept the currently keyboard-selected row (the ↩ chord): runs it AND closes the palette.
    public func acceptSelected() {
        let rows = selectableResults
        guard paletteSelection >= 0, paletteSelection < rows.count else { return }
        run(rows[paletteSelection])
    }

    /// Accept the keyboard-selected row but KEEP the palette open (the ⌘↩ chord) so the user can chain
    /// another action without re-opening (Warp command-chaining — spec §Behaviors / ES-E2-2). Runs the row
    /// with `keepOpen: true` so a `.store`/`.command` row mutates the store WITHOUT closing; the query is left
    /// intact for the next ⌘↩, and the selection is re-clamped in case the selectable set shrank.
    public func acceptSelectedKeepingOpen() {
        let rows = selectableResults
        guard paletteSelection >= 0, paletteSelection < rows.count else { return }
        run(rows[paletteSelection], keepOpen: true)
        moveSelection(0) // re-clamp to the (possibly shrunk) selectable set; never leaves a stale index
    }

    /// Run one palette row's action against the store, then close (or apply a filter in place). Separators
    /// are no-ops. This is the ONE place a palette intent becomes a store mutation. `keepOpen` (the ⌘↩
    /// chaining path) suppresses the close for the `.store`/`.command`/chrome-toggle rows — the chainable
    /// kinds; the overlay-switching rows (settings/connect/cheat/picker) always close-then-open regardless.
    /// The chrome-toggle rows route through the injected ``toggleSidebar``/``toggleInspector`` closures so they
    /// flip the LIVE `WorkspaceChromeState` the split + the ✓ read — not the dead `store.sidebarCollapsed`.
    public func run(_ item: PaletteItem, keepOpen: Bool = false) {
        guard !item.isSeparator else { return }
        switch item.action {
        case let .store(closure):
            if let store { closure(store) }
            if !keepOpen { closePalette() }
        case let .command(command):
            if let store { apply(command, to: store) }
            if !keepOpen { closePalette() }
        case .toggleSidebar:
            toggleSidebar()
            if !keepOpen { closePalette() }
        case .toggleInspector:
            toggleInspector()
            if !keepOpen { closePalette() }
        case let .selectDetailsTab(tab):
            selectDetailsTab(tab)
            if !keepOpen { closePalette() }
        case .togglePinWindow:
            togglePinWindow()
            if !keepOpen { closePalette() }
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

    // MARK: Global Search (⇧⌘F)

    /// Present the cross-tab Global Search surface (E5 ES-E5-5). `seed` is the active pane's current selection
    /// when a caller has one (otty pre-fills the search with the selection): a non-empty seed that differs from
    /// the last query immediately runs the search through ``WorkspaceStore/runGlobalSearch(query:caseSensitive:isRegex:)``
    /// (reusing the store's last `Aa`/`.*` flags); a nil / empty seed leaves the store's last results in place so
    /// ⇧⌘F REOPENS onto the previous results (E5 divergence #1). The view restores its field + pills from the
    /// store's retained query/flags on appear, then live-re-runs as the user edits.
    public func openGlobalSearch(seed: String? = nil) {
        if let store {
            // E5 perf: snapshot every pane's scrollback ONCE per open; the seed run + every keystroke then
            // re-run only the in-memory match pass over this cache (no per-keystroke cross-seam re-mirroring).
            store.beginGlobalSearchSession()
            if let trimmed = seed?.trimmingCharacters(in: .whitespacesAndNewlines),
               !trimmed.isEmpty, trimmed != store.globalSearchQuery
            {
                store.runGlobalSearch(
                    query: trimmed,
                    caseSensitive: store.globalSearchCaseSensitive,
                    isRegex: store.globalSearchRegex,
                )
            }
        }
        globalSearchVisible = true
    }

    public func closeGlobalSearch() {
        globalSearchVisible = false
        store?.endGlobalSearchSession() // E5 perf: drop the cached scrollback so the next open re-snapshots.
    }

    /// Toggle the Global Search surface (the ⇧⌘F binding the app threads into the key dispatcher + menu).
    /// Opening with no seed restores the last in-memory results.
    public func toggleGlobalSearch() {
        if globalSearchVisible { closeGlobalSearch() } else { openGlobalSearch() }
    }

    // MARK: Open-Quickly (⌘⇧O — All · ⌘J — Current · E11 / WI-5)

    /// Present the Open-Quickly picker at `filter` (⌘⇧O → ``OpenQuicklyFilter/all``; ⌘J → ``.current``). The
    /// picker resolves its own sources (open panes / recents / folders / agents / the focused pane's links +
    /// OSC-133 command index), so — like Global Search — there is no per-open data snapshot here.
    public func openOpenQuickly(filter: OpenQuicklyFilter = .all) {
        openQuicklyFilter = filter
        openQuicklyVisible = true
    }

    public func closeOpenQuickly() { openQuicklyVisible = false }

    /// Toggle the Open-Quickly picker (the ⌘⇧O / ⌘J bindings the app threads into the key dispatcher + menu).
    /// Opening lands on `filter`; an already-open picker closes (matching the prior Jump-To toggle semantics).
    public func toggleOpenQuickly(filter: OpenQuicklyFilter = .all) {
        if openQuicklyVisible { closeOpenQuickly() } else { openOpenQuickly(filter: filter) }
    }

    /// Switch the visible picker to `filter` WITHOUT closing it — the Tab/⇧Tab cycle + the picker-local pill
    /// chords (⌘0/⌘W/⌘R/⌘Z/⌘G/⌘J) drive this while the panel is open.
    public func setOpenQuicklyFilter(_ filter: OpenQuicklyFilter) {
        openQuicklyFilter = filter
    }

    // MARK: Peek & Reply (⌘⌥J — answer a blocked agent INLINE · E13 WI-8 / P4)

    /// Present the Peek & Reply overlay over the oldest pane needing attention. HONEST no-op when nothing
    /// needs attention (no target ⇒ the card would be empty) — exactly mirroring the routing contract "the
    /// toggle closure itself no-ops when nothing needs attention", so ⌘⌥J on a calm workspace does nothing
    /// rather than flashing an empty card. Resets the advance-exclusion so each open starts fresh.
    public func openPeekReply() {
        peekReplyExcluding = []
        guard store?.peekReplyTargetPane() != nil else { return }
        peekReplyVisible = true
    }

    /// Dismiss the Peek & Reply overlay and clear the advance-exclusion (so the next open targets fresh).
    public func closePeekReply() {
        peekReplyVisible = false
        peekReplyExcluding = []
    }

    /// Toggle the Peek & Reply overlay (the ⌘⌥J binding the app threads into the key dispatcher + the menu).
    public func togglePeekReply() {
        if peekReplyVisible { closePeekReply() } else { openPeekReply() }
    }

    /// The pane the overlay currently targets: the focused-blocked-first / oldest-attention selection
    /// (``WorkspaceStore/peekReplyTargetPane(excluding:)``) over the panes NOT yet answered this session.
    /// `nil` when nothing is left to answer (the view then closes). Reads the store's `@Observable`
    /// per-pane status + the exclusion set, so a SwiftUI body that calls it re-resolves on either change.
    public func peekReplyTarget() -> PaneID? {
        store?.peekReplyTargetPane(excluding: peekReplyExcluding)
    }

    /// Deliver one formatted reply to `pane` then ADVANCE. The caller pre-formats via ``PeekReplyFormatter``
    /// (digit / bang-shell / plain), which already appends the single trailing newline — so `text` is sent
    /// **VERBATIM** down the same per-pane PTY funnel (``WorkspaceStore/sendPeekReply(_:to:)``), NEVER through
    /// `SendKeysParser`. Then the just-answered pane is excluded and, when nothing is left needing attention,
    /// the overlay closes. Observe + reply, **never a gate** — the agent was never blocked waiting on us.
    public func deliverPeekReply(_ text: String, to pane: PaneID) {
        store?.sendPeekReply(text, to: pane)
        advancePeekReply(answered: pane)
    }

    /// Advance past the just-answered `pane`: add it to the exclusion set, then close the overlay when no pane
    /// still needs attention. Public so the view's submit / quick-answer paths (and a test) drive it directly.
    public func advancePeekReply(answered pane: PaneID) {
        peekReplyExcluding.insert(pane)
        if peekReplyTarget() == nil { closePeekReply() }
    }

    // MARK: Send to Chat (⌘⌃↩ — quote the active pane → a chosen agent · E13 WI-5 / ES-E13-5)

    /// Present the Send-to-Chat dialog over the active pane's captured quote. HONEST no-op when there is
    /// nothing to quote (no selection + no command block) — mirroring ``openPeekReply()`` — so ⌘⌃↩ on an empty
    /// pane does nothing rather than flashing an empty card. Builds the Claude-only session picker off the
    /// store and pre-selects the last-used (or first live) agent pane.
    public func openSendToChat() {
        guard let store else { return }
        // The injected capture wins (the app wires it to the live store; a test overrides it); falling back to
        // the attached store keeps the default working even if the app forgot to inject one.
        guard let context = captureSendToChat?() ?? store.captureSendToChatContext() else { return }
        sendToChatContext = context
        sendToChatSessions = store.agentChatSessions()
        sendToChatInitialSelection = SendToChatModel.defaultSession(
            in: sendToChatSessions, lastUsed: lastChatTarget,
        )?.id
        sendToChatVisible = true
    }

    /// Dismiss the Send-to-Chat dialog and clear its captured quote / session list (so a stale capture can't
    /// leak into the next open).
    public func closeSendToChat() {
        sendToChatVisible = false
        sendToChatContext = nil
        sendToChatSessions = []
        sendToChatInitialSelection = nil
    }

    /// Toggle the Send-to-Chat dialog (the ⌘⌃↩ binding the app threads into the key dispatcher + the menu).
    public func toggleSendToChat() {
        if sendToChatVisible { closeSendToChat() } else { openSendToChat() }
    }

    /// Record a manual picker change as the new last-used default (the dialog's `onSelectionChange`), so the
    /// next open pre-selects it even if the user cancels this one.
    public func recordSendToChatSelection(_ target: PaneID?) {
        if let target { lastChatTarget = target }
    }

    /// Deliver the composed `message` to the chosen target then close. A live agent pane (`target`) routes
    /// through ``WorkspaceStore/sendChatMessage(_:to:)`` (the per-pane ordered-OUT VERBATIM sink — which also
    /// AUTO-SWITCHES focus to that pane); a `nil` target ("New session") spawns a fresh terminal tab and
    /// injects the message after the launch grace (``WorkspaceStore/sendChatToNewSession(_:)``). The chosen
    /// live target is remembered as the last-used default for the next open.
    public func sendChat(to target: PaneID?, message: String) {
        if let target {
            store?.sendChatMessage(message, to: target)
            lastChatTarget = target
        } else {
            store?.sendChatToNewSession(message)
        }
        closeSendToChat()
    }

    /// Copy the composed `message` to the pasteboard WITHOUT sending (the dialog's "Copy Message"), then close.
    public func copyChatMessage(_ message: String) {
        copyToPasteboard(message)
        closeSendToChat()
    }

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
