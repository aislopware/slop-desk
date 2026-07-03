// OverlayCoordinator — the single `@MainActor @Observable` owner of the floating-overlay layer's state
// (warp-overlays-actions.md §4: a central reducer the chrome controls dispatch into). It owns:
//   - the command-palette presentation (mode + active filter + query) and its mixer,
//   - the Settings open action (the injected `openSettings` environment action → the stock Settings scene),
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
    /// ⌘⇧P — the verbs-only Command Palette (actions/verbs grouped by category; NO filter chips).
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

    /// Opens the app's Settings surface. On macOS the Settings surface is the STOCK SwiftUI `Settings` scene
    /// (a separate system-chromed window opened by ⌘,), which no in-window flag can present — so the root view
    /// injects this closure, bound to the SwiftUI `openSettings` environment action (with an `NSApp`
    /// `showSettingsWindow:` fallback). The palette "Open Settings" row routes
    /// through ``openSettings()`` → this closure. `nil` (tests / previews / a pre-`onAppear` scene) makes
    /// ``openSettings()`` a graceful no-op rather than a dead control that silently does nothing.
    @ObservationIgnored public var openSettingsAction: (@MainActor () -> Void)?

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
    /// a NON-modal, NON-scrimmed full surface — a dedicated results *overlay* rather than a results *tab*
    /// (E5 divergence #1), so it must NOT dim the workspace and is deliberately EXCLUDED from
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
    /// TabSide partition: toggles the RIGHT remote-windows column. Bound by ``WorkspaceRootView`` to
    /// `chrome.toggleWindowsPanel()` so the palette row flips the SAME live `chrome.guiCollapsed` the ⌘⇧E
    /// chord + the split shell read. No-op default (iOS / tests / previews) — never a trap.
    @ObservationIgnored public var toggleWindowsPanel: @MainActor () -> Void = {}
    /// E19/A30 (WI-4): toggles the window-pin flag (the View ▸ Pin Window menu row). Bound by ``WorkspaceRootView`` to
    /// `chrome.togglePin()` so any palette / command surface routed here flips the SAME live
    /// `WorkspaceChromeState.pinned` the menu Button + the macOS `NSWindow.level` glue read. No-op by default
    /// (iOS / tests / previews), so the seam is never a trap when no Pin-Window row is surfaced.
    @ObservationIgnored public var togglePinWindow: @MainActor () -> Void = {}
    /// Closes the active window (the Window ▸ Close Window menu row — the palette "Close Window" row). Bound on macOS
    /// to `NSWindow.performClose(nil)` (→ the native `windowShouldClose` close-confirmation gate, preserving
    /// the configured ``CloseConfirmationPolicy``). `nil` (iOS / tests / a pre-`onAppear` scene) makes the run
    /// arm fall back to ``WorkspaceStore/requestCloseWindow()`` — the SAME parked-confirmation fallback the
    /// ⌘⇧W route arm uses, never a dead control.
    @ObservationIgnored public var closeWindow: (@MainActor () -> Void)?
    /// Theme parity (Batch 4): switches the active local theme (the palette "Switch Theme" row). Bound app-side to
    /// ``PreferencesStore`` (advance the primary slot through the built-in themes), so the palette row retints
    /// the chrome + terminal cells through the SAME live `appearance.theme` Settings → Appearance edits. No-op
    /// by default (tests / previews), so the row is never a trap.
    @ObservationIgnored public var switchTheme: @MainActor () -> Void = {}
    /// Batch-5b (A): EAGERLY resolve the focused pane's working directory (the host `cwd()` metadata RPC →
    /// ``WorkspaceStore/setLastKnownCwd(_:for:)``) so the WORKING DIRECTORY palette header's cwd pill is
    /// populated the moment the palette opens. Bound by ``WorkspaceRootView`` to the live ``MetadataClient``.
    /// WITHOUT this the pill stayed blank on a freshly-connected pane sitting at a prompt: the only other
    /// `lastKnownCwd` writer — a command completing (OSC 133;D) — had not
    /// fired. Fired from ``openPalette(mode:query:)``; the
    /// resolution lands reactively (`@Observable` spec write) within ~1 RTT, so the pill pops in without
    /// blocking the open. No-op by default (tests / previews / a disconnected pane), so opening the palette is
    /// never gated on it — and it spends NO new wire message (the `cwd()` RPC already exists).
    @ObservationIgnored public var resolveActiveCwd: @MainActor () -> Void = {}

    // MARK: Prefix-armed indicator (keyboard improvement)

    /// Whether the tmux-style workspace PREFIX (default ⌃A) is currently ARMED — the machine has swallowed
    /// the prefix and awaits the follow-up key. Driven by the app's ``WorkspaceKeyDispatcher`` through
    /// ``setPrefixArmed(_:)`` on every armed edge (arm → true; a resolved/unbound follow-up, the double-tap
    /// send-prefix, or the escape timeout → false), so the workspace chip (``OverlayHostView``) shows exactly
    /// while a follow-up is awaited and never lies. Stays `false` on iOS / tests (nothing drives it there).
    public private(set) var prefixArmed = false

    /// Publish one armed edge (the dispatcher's `onPrefixArmedChange` target). Idempotent — a redundant edge
    /// never re-publishes the `@Observable` flag.
    public func setPrefixArmed(_ armed: Bool) {
        guard prefixArmed != armed else { return }
        prefixArmed = armed
    }

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
            || peekReplyVisible
    }

    /// Whether a presented overlay must OWN the keyboard — the gate the app's `isOverlayCapturingKeys` closure
    /// reads so the global ``WorkspaceKeyDispatcher`` NSEvent monitor (which PREEMPTS the responder chain)
    /// YIELDS modeled chords to the focused card instead of resolving them behind it. EVERY focus-stealing
    /// overlay belongs here: the four scrimmed panels (palette / cheat sheet / connect / remote picker) own
    /// Esc/arrows/Return and swallow clicks behind their scrim, so a modeled ⌘W / ⌘1–9 / ⌘T leaking past them
    /// would DESTRUCTIVELY close / switch / mutate the BACKGROUND tree the user can't even see — the recurring
    /// E11 ⌘W class. So this mirrors ``anyModalVisible`` exactly, PLUS the non-scrimmed Global Search surface
    /// (E5), whose focused query field (``GlobalSearchView``) must likewise keep ⌘W from reaching the workspace
    /// (Global Search is deliberately absent from ``anyModalVisible`` because it must NOT dim the workspace, but
    /// it still owns the keyboard while up). SINGLE source of truth for that gate (the app's closure reads
    /// THIS), so adding an overlay to ``anyModalVisible`` keeps the dispatcher honest without duplicating it.
    public var capturesKeyboardWhileVisible: Bool {
        anyModalVisible || globalSearchVisible
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
        // Batch-5b (A): kick the focused pane's cwd resolution so the WORKING DIRECTORY header's cwd pill is
        // populated (within ~1 RTT, reactively) even on a fresh prompt where no command has completed — the
        // lazy `lastKnownCwd` writer that otherwise left the pill blank.
        resolveActiveCwd()
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

    /// Rebuild the verbs-only ⌘⇧P mixer: the action catalog grouped into fixed categories (Working Directory /
    /// Window / Pane / Tab / View / Shell / Settings), one section header each. A typed query gets one section
    /// header per matching category. (E11 / WI-5: the old multi-source Open-Quickly branch — a live Tabs
    /// snapshot + the file/conversation/repo `EmptyPaletteSource` stubs — was removed; that jump-to is now the
    /// dedicated `OpenQuicklyView`/`OpenQuicklyModel`, NOT a palette mode.)
    public func rebuildMixer() {
        // The verb-catalog categories, one section header each.
        mixer = SearchMixer(sources: ActionsPaletteSource.categorySources())
    }

    // MARK: Palette results (view binds these)

    /// The current ordered, sectioned result list. Empty query ⇒ the sectioned zero-state (WORKING
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

    /// Zero-state (empty query, no filter): the sectioned verb list. WORKING DIRECTORY leads (its header
    /// OWNS the cwd badge in the view, per command-palette.png) with its Copy Path row; then the MRU Recents
    /// block; then the remaining catalog grouped into fixed categories (Window / Pane / Tab / View / Settings).
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
        // The rest of the catalog, grouped into fixed categories in display order (Working Directory already
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
    /// The chrome-toggle rows route through the injected ``toggleSidebar`` closure so they
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
        case .toggleWindowsPanel:
            toggleWindowsPanel()
            if !keepOpen { closePalette() }
        case .togglePinWindow:
            togglePinWindow()
            if !keepOpen { closePalette() }
        case .closeWindow:
            // The injected actuator (macOS `performClose` → the close-confirmation gate) wins; `nil` (iOS /
            // tests) falls back to the store's parked-confirmation request — the SAME fallback the ⌘⇧W route
            // arm uses, never a dead control. Always closes the palette (a window-scope action, not chainable).
            if let closeWindow { closeWindow() } else { store?.requestCloseWindow() }
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
        // Theme parity (Batch 4): a live theme switch — chainable (⌘↩ keep-open) like the `.store` rows, so
        // the user can cycle themes without re-opening. The injected closure is a graceful no-op by default
        // (tests / previews).
        case .switchTheme:
            switchTheme()
            if !keepOpen { closePalette() }
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

    /// Open the app Settings surface via the injected ``openSettingsAction`` (the SwiftUI `openSettings`
    /// environment action on macOS). A no-op when unbound (tests / previews) — never a dead control.
    public func openSettings() { openSettingsAction?() }

    // MARK: Connect-to-Host

    public func openConnect() { connectVisible = true }
    public func closeConnect() { connectVisible = false }

    // MARK: Cheat sheet (⌘/)

    public func toggleCheatSheet() { cheatSheetVisible.toggle() }
    public func closeCheatSheet() { cheatSheetVisible = false }
    public func openCheatSheet() { cheatSheetVisible = true }

    // MARK: Global Search (⇧⌘F)

    /// Present the cross-tab Global Search surface (E5 ES-E5-5). `seed` is the active pane's current selection
    /// when a caller has one (pre-fills the search with the selection): a non-empty seed that differs from
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
            bundleID: summary.bundleID,
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
