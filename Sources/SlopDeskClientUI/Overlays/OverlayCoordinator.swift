// OverlayCoordinator — the single `@MainActor @Observable` owner of the floating-overlay layer's state
// (warp-overlays-actions.md §4: a central reducer the chrome controls dispatch into). Owns:
//   - the command-palette presentation (mode + filter + query) and its mixer,
//   - the Settings open action (injected `openSettings` env action → the stock Settings scene),
//   - the toast stack (wired to the store's onPaneNotification / onLongCommandNotify / onAgentAttention),
//   - and routes a palette row's `PaletteAction` to the store, then closes.
//
// Mounted once at `WorkspaceRootView` in a ZStack above the window. The busy-close modal is driven directly
// off the store's `pendingCloseSpec` — the coordinator owns only palette/settings/toasts.

import Foundation
import Observation
import SlopDeskAgentDetect
import SlopDeskWorkspaceCore

/// How the palette was opened (warp-overlays-actions.md §2.1) — governs only the friendly omnibar label.
/// BOTH entry points are the verbs-only ⌘⇧P Command Palette; the multi-source ⌘⇧O Open-Quickly jump-to is
/// its OWN surface (`OpenQuicklyView`/`OpenQuicklyModel`), NOT a palette mode — so there is no `openQuickly`
/// case / `multiSource` flag here.
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
    /// The live query text (the palette search field binds this). Editing it RESETS the keyboard selection to
    /// row 0: the ranked set changes each keystroke, so a parked index could point past the end after
    /// a narrowing edit — the highlight would vanish and ↩ silently no-op (`acceptSelected` guards
    /// `selection < rows.count`). Row 0 is always the first selectable row (separators excluded from the index).
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

    /// Opens the app's Settings surface. On macOS that is the STOCK SwiftUI `Settings` scene (a separate
    /// system-chromed window, ⌘,), which no in-window flag can present — so the root injects this closure
    /// bound to the SwiftUI `openSettings` env action (with an `NSApp` `showSettingsWindow:` fallback). `nil`
    /// (tests / previews / a pre-`onAppear` scene) makes ``openSettings()`` a graceful no-op, never a dead control.
    @ObservationIgnored public var openSettingsAction: (@MainActor () -> Void)?

    // MARK: Connect-to-Host state

    /// Whether the Connect-to-Host overlay (host/port editor) is presented. Opened by the top-bar status pill
    /// and the "Connect to Host…" palette action — the only surfaces that point the client at a non-default
    /// host (the app-global ``AppConnection`` form is otherwise unbound by any view).
    public private(set) var connectVisible = false

    /// Monotonic Connect-sheet PRESENTATION generation — bumped by every ``openConnect()`` AND
    /// ``closeConnect()``. ``ConnectHostView``'s async connect Task captures it at start
    /// and finishes through ``closeConnect(ifCurrent:)``, so a SLOW connect that resolves after the sheet
    /// was cancelled and REOPENED can no longer dismiss the fresh sheet mid-edit.
    public private(set) var connectGeneration = 0

    // MARK: Cheat-sheet state

    /// Whether the keyboard cheat sheet (⌘/) is presented. Its rows are generated from
    /// ``WorkspaceBindingRegistry/groupedForDisplay`` so the displayed glyphs can't drift from the chords.
    public private(set) var cheatSheetVisible = false

    // MARK: Global Search state

    /// Whether the cross-tab Global Search surface (⇧⌘F) is presented. UNLIKE the four scrimmed panels this is
    /// deliberately a NON-modal, NON-scrimmed surface, so it must NOT dim the workspace and is
    /// deliberately EXCLUDED from ``anyModalVisible``; ``OverlayHostView`` mounts it WITHOUT a ``Scrim`` and
    /// gates hit-testing on this flag directly. Reopening RESTORES the store's last in-memory results
    /// (``WorkspaceStore/globalSearch``) until the query is re-run.
    public private(set) var globalSearchVisible = false

    // MARK: Open-Quickly state

    /// Whether the Open-Quickly picker (⌘⇧O All / ⌘J Current) is presented. A floating, centered, SCRIMMED
    /// quick-switcher card, so it is in ``anyModalVisible`` and mounted behind a
    /// ``Scrim``. The picker reads its own sources (open panes / recents / folders / agents / the focused
    /// pane's links + OSC-133 command index) — like Global Search, the coordinator owns only the flag + pill.
    public private(set) var openQuicklyVisible = false

    /// The pill the picker opens to / is currently showing (``OpenQuicklyFilter``). ⌘⇧O opens ``.all``; ⌘J
    /// opens ``.current``; Tab/⇧Tab + the picker-local pill chords drive ``setOpenQuicklyFilter(_:)`` while it
    /// is open. Defaults to ``.all`` (the ⌘⇧O entry).
    public private(set) var openQuicklyFilter: OpenQuicklyFilter = .all

    // MARK: Peek & Reply state (answer a blocked agent INLINE, ⌘⌥J)

    /// Whether the Peek & Reply overlay (⌘⌥J) is presented. A centered, SCRIMMED card over the oldest pane
    /// needing attention (``WorkspaceStore/peekReplyTargetPane(excluding:)``) that answers a blocked agent
    /// INLINE — observe + reply, **NEVER an approval gate**: the agent is never paused
    /// pending a slopdesk confirmation. In ``anyModalVisible``, mounted behind a ``Scrim``.
    public private(set) var peekReplyVisible = false

    /// The advance-to-next exclusion set accumulated while the overlay is open: each answered pane
    /// is added so ``peekReplyTarget()`` skips it on the immediate advance (a just-answered pane may still
    /// report `.needsPermission` until the host re-reports). Reset on every open/close so a fresh open
    /// re-targets cleanly.
    public private(set) var peekReplyExcluding: Set<PaneID> = []

    // MARK: Remote-window picker state

    /// Whether the Remote-Window picker modal is presented (the `/remote-control` pill + the "New Remote
    /// Window Tab" palette action open it; a pick opens a `.remoteGUI` pane).
    public private(set) var remotePickerVisible = false
    /// The dedicated discovery-driving model for the live picker (NOT a pane's). Built per open from a
    /// fresh app target so its `refresh()` queries the current host. `nil` until first opened.
    @ObservationIgnored public private(set) var remotePickerModel: RemoteWindowModel?
    /// Resolves the app-global ``ConnectionTarget`` for the picker's discovery query. Injected by the root.
    @ObservationIgnored public var connectionTarget: @MainActor () -> ConnectionTarget = { .default }
    /// The app-owned host-windows feed (docs/45) — set once at app init so Open Quickly's Host rows
    /// read the SAME live store the rail renders. Weak: the App's `@State` owns the feed.
    @ObservationIgnored public weak var hostWindowFeed: HostWindowFeed?

    // MARK: Chrome toggles (injected by the root, which owns the live `WorkspaceChromeState`)

    /// Toggles the left navigator / Tabs panel. Bound by ``WorkspaceRootView`` to `chrome.toggleSidebar()` so
    /// the "Toggle Tabs Panel" row flips the SAME live `chrome.sidebarCollapsed` the ⌘⇧L chord + titlebar
    /// button + the palette ✓ read — never the legacy `store.sidebarCollapsed` the native shell ignores. No-op
    /// by default (iOS / tests / previews), so the row is never a trap.
    @ObservationIgnored public var toggleSidebar: @MainActor () -> Void = {}
    /// Toggles the RIGHT Host Windows rail (docs/45, ⌘⇧R) — bound by the root view to the live
    /// `chrome.toggleHostWindows()` so the palette row, the chord, and the rail button flip ONE flag.
    @ObservationIgnored public var toggleHostWindows: @MainActor () -> Void = {}
    /// Toggles the window-pin flag (View ▸ Pin Window). Bound by ``WorkspaceRootView`` to
    /// `chrome.togglePin()` so any surface routed here flips the SAME live `WorkspaceChromeState.pinned` the
    /// menu Button + the macOS `NSWindow.level` glue read. No-op by default (iOS / tests / previews).
    @ObservationIgnored public var togglePinWindow: @MainActor () -> Void = {}
    /// Closes the active window (Window ▸ Close Window / the palette "Close Window" row). Bound on macOS to
    /// `NSWindow.performClose(nil)` (→ the native `windowShouldClose` gate, preserving ``CloseConfirmationPolicy``).
    /// `nil` (iOS / tests / a pre-`onAppear` scene) falls back to ``WorkspaceStore/requestCloseWindow()`` — the
    /// SAME parked-confirmation fallback the ⌘⇧W route arm uses, never a dead control.
    @ObservationIgnored public var closeWindow: (@MainActor () -> Void)?
    /// Switches the active local theme (the palette "Switch Theme" row). Bound app-side
    /// to ``PreferencesStore`` (advances the primary slot through the built-in themes), so the row retints
    /// chrome + terminal cells through the SAME live `appearance.theme` that Settings → Appearance edits. No-op
    /// by default (tests / previews), so the row is never a trap.
    @ObservationIgnored public var switchTheme: @MainActor () -> Void = {}
    /// EAGERLY resolve the focused pane's cwd (host `cwd()` RPC →
    /// ``WorkspaceStore/setLastKnownCwd(_:for:)``) so the WORKING DIRECTORY header's cwd pill is populated the
    /// moment the palette opens. Bound by ``WorkspaceRootView`` to the live ``MetadataClient``. WITHOUT this
    /// the pill stayed blank on a freshly-connected pane at a prompt: the only other `lastKnownCwd` writer — a
    /// command completing (OSC 133;D) — hadn't fired. Fired from ``openPalette(mode:query:)``; the resolution
    /// lands reactively within ~1 RTT, so the pill pops in without blocking the open. No-op by default (tests /
    /// previews / a disconnected pane), and spends NO new wire message (the `cwd()` RPC already exists).
    @ObservationIgnored public var resolveActiveCwd: @MainActor () -> Void = {}

    // MARK: Prefix-armed indicator (keyboard improvement)

    /// Whether the tmux-style workspace PREFIX (default ⌃A) is currently ARMED — swallowed, awaiting the
    /// follow-up key. Driven by ``WorkspaceKeyDispatcher`` through ``setPrefixArmed(_:)`` on every armed edge
    /// (arm → true; a resolved/unbound follow-up, double-tap send-prefix, or escape timeout → false), so the
    /// workspace chip (``OverlayHostView``) shows exactly while a follow-up is awaited. Stays `false` on iOS / tests.
    public private(set) var prefixArmed = false

    /// Publish one armed edge (the dispatcher's `onPrefixArmedChange` target). Idempotent — a redundant edge
    /// never re-publishes the `@Observable` flag.
    public func setPrefixArmed(_ armed: Bool) {
        guard prefixArmed != armed else { return }
        prefixArmed = armed
    }

    // MARK: Modal gate

    /// Whether ANY focus-stealing modal overlay is presented — the `OverlayHostView` hit-testing gate.
    /// True ⇒ the host's ZStack swallows clicks (scrim + centered panel); false ⇒ the host is transparent to
    /// hits so the workspace stays interactive (the always-mounted toast stack is NOT a modal, gated separately
    /// on `!toasts.isEmpty`). Excludes Settings AND the non-scrimmed Global Search surface (which must not dim
    /// the workspace) — the host gates Global Search's hit-testing separately on ``globalSearchVisible``.
    public var anyModalVisible: Bool {
        paletteVisible || cheatSheetVisible || connectVisible || remotePickerVisible || openQuicklyVisible
            || peekReplyVisible
    }

    /// Whether a presented overlay must OWN the keyboard — the gate the app's `isOverlayCapturingKeys` closure
    /// reads so the global ``WorkspaceKeyDispatcher`` NSEvent monitor (which PREEMPTS the responder chain)
    /// YIELDS modeled chords to the focused card instead of resolving them behind it. Without this, a modeled
    /// ⌘W / ⌘1–9 / ⌘T leaking past a scrimmed card would DESTRUCTIVELY close / switch / mutate the BACKGROUND
    /// tree the user can't see. Mirrors ``anyModalVisible`` exactly PLUS the
    /// non-scrimmed Global Search surface, whose focused query field (``GlobalSearchView``) must likewise
    /// keep ⌘W from the workspace. SINGLE source of truth for that gate, so adding an overlay to
    /// ``anyModalVisible`` keeps the dispatcher honest without duplicating it.
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

    /// The app-owned Folders frecency store — backs the Open-Quickly **Folders** pill (`⌘Z`).
    /// Held weakly (the app owns it; attached once by the root like ``store``). `nil` on iOS / tests / previews
    /// ⇒ the Folders source is simply empty there.
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
        // Kick the focused pane's cwd resolution so the WORKING DIRECTORY header's cwd pill
        // populates (~1 RTT, reactively) even on a fresh prompt where no command has completed.
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
    /// Window / Pane / Tab / View / Shell / Settings), one section header each. The multi-source jump-to lives
    /// entirely in `OpenQuicklyView`/`OpenQuicklyModel`, NOT here — this mixer stays verbs-only.
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

    /// Like ``paletteResults`` but WITH each row's fzf title-match ranges (``RankedRow``) — the palette view
    /// binds THIS so it can highlight matched code points. Via ``SearchMixer/ranked(query:activeFilter:)``; the
    /// zero-state (empty query, no filter) wraps each row in a range-less ``RankedRow`` (highlight is only
    /// meaningful for a typed query). Kept alongside ``paletteResults`` so callers/tests that only need items
    /// are unaffected.
    public var rankedResults: [RankedRow] {
        guard let mixer else { return [] }
        let q = paletteQuery.trimmingCharacters(in: .whitespaces)
        if q.isEmpty, paletteFilter == nil {
            return zeroStateResults().map { RankedRow(item: $0) }
        }
        return mixer.ranked(query: q, activeFilter: paletteFilter)
    }

    /// Zero-state (empty query, no filter): the sectioned verb list. WORKING DIRECTORY leads (its header OWNS
    /// the cwd badge, per command-palette.png) with its Copy Path row; then the MRU Recents block; then the
    /// rest of the catalog grouped by category. Empty categories are skipped (no empty header). Hand-built (not
    /// `mixer.ranked("")`) so the slopdesk-only Recents block can interleave after Working Directory.
    private func zeroStateResults() -> [PaletteItem] {
        var out: [PaletteItem] = []
        // Working Directory first — its header carries the cwd badge; Copy Path (+ TODO: host rows) below.
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
        // The rest of the catalog, grouped in display order (Working Directory already led). A category with
        // no rows is skipped — no empty section header.
        for category in PaletteCategory.commandOrder where category != .workingDirectory {
            let items = ActionsPaletteSource.items(in: category)
            guard !items.isEmpty else { continue }
            out.append(.separator(category.label, filter: .actions))
            out.append(contentsOf: items)
        }
        return out
    }

    /// Map the store's `recentCommands` ring onto catalog rows (by matching the verb), MRU order. Verbs absent
    /// from the catalog (focus/cycle/etc.) are skipped. Each row is re-id'd into the `recent.*` namespace
    /// (``PaletteItem/namespacedForRecents()``) so it can't collide with its identical catalog row on the same
    /// `ForEach`/`.id` key — the action is preserved, so accept still runs the catalog verb.
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

    /// Accept the keyboard-selected row but KEEP the palette open (the ⌘↩ chord) so the user can chain actions
    /// without re-opening (Warp command-chaining — spec §Behaviors). Runs with `keepOpen: true` so a
    /// `.store`/`.command` row mutates WITHOUT closing; the query is left intact for the next ⌘↩, and the
    /// selection is re-clamped in case the selectable set shrank.
    public func acceptSelectedKeepingOpen() {
        let rows = selectableResults
        guard paletteSelection >= 0, paletteSelection < rows.count else { return }
        run(rows[paletteSelection], keepOpen: true)
        moveSelection(0) // re-clamp to the (possibly shrunk) selectable set; never leaves a stale index
    }

    /// Run one palette row's action against the store, then close (or apply a filter in place). Separators are
    /// no-ops. The ONE place a palette intent becomes a store mutation. `keepOpen` (the ⌘↩ chaining path)
    /// suppresses the close for the chainable `.store`/`.command`/chrome-toggle rows; the overlay-switching
    /// rows (settings/connect/cheat/picker) always close-then-open. Chrome-toggle rows route through the
    /// injected ``toggleSidebar`` closure so they flip the LIVE `WorkspaceChromeState` — not the dead
    /// `store.sidebarCollapsed`.
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
        case .toggleHostWindows:
            toggleHostWindows()
            if !keepOpen { closePalette() }
        case .togglePinWindow:
            togglePinWindow()
            if !keepOpen { closePalette() }
        case .closeWindow:
            // The injected actuator (macOS `performClose` → close-confirmation gate) wins; `nil` (iOS / tests)
            // falls back to the store's parked-confirmation request — the SAME fallback the ⌘⇧W arm uses.
            // Always closes the palette (a window-scope action, not chainable).
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
        // A live theme switch — chainable (⌘↩ keep-open) like `.store` rows, so the
        // user can cycle themes without re-opening. No-op by default (tests / previews).
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

    public func openConnect() {
        connectVisible = true
        connectGeneration &+= 1
    }

    public func closeConnect() {
        connectVisible = false
        connectGeneration &+= 1
    }

    /// Close the Connect sheet ONLY if `generation` is still the current presentation — the completion guard
    /// for ``ConnectHostView``'s async connect Task. A stale generation (the sheet was cancelled and/or
    /// reopened since the Task started) is a no-op, so a slow connect never dismisses a fresh sheet.
    public func closeConnect(ifCurrent generation: Int) {
        guard generation == connectGeneration else { return }
        closeConnect()
    }

    // MARK: Cheat sheet (⌘/)

    public func toggleCheatSheet() { cheatSheetVisible.toggle() }
    public func closeCheatSheet() { cheatSheetVisible = false }
    public func openCheatSheet() { cheatSheetVisible = true }

    // MARK: Global Search (⇧⌘F)

    /// Present the cross-tab Global Search surface. `seed` = the active pane's current selection
    /// when a caller has one: a non-empty seed differing from the last query immediately runs
    /// ``WorkspaceStore/runGlobalSearch(query:caseSensitive:isRegex:)`` (reusing the store's last `Aa`/`.*`
    /// flags); a nil / empty seed leaves the store's last results so ⇧⌘F REOPENS onto them (deliberately
    /// diverging from the scrimmed pickers, which always reset on open).
    /// The view restores its field + pills from the store's retained query/flags on appear, then live-re-runs.
    public func openGlobalSearch(seed: String? = nil) {
        if let store {
            // Snapshot every pane's scrollback ONCE per open; the seed run + every keystroke then
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
        store?.endGlobalSearchSession() // Drop the cached scrollback so the next open re-snapshots.
    }

    /// Toggle the Global Search surface (the ⇧⌘F binding the app threads into the key dispatcher + menu).
    /// Opening with no seed restores the last in-memory results.
    public func toggleGlobalSearch() {
        if globalSearchVisible { closeGlobalSearch() } else { openGlobalSearch() }
    }

    // MARK: Open-Quickly (⌘⇧O — All · ⌘J — Current)

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

    // MARK: Peek & Reply (⌘⌥J — answer a blocked agent INLINE)

    /// Present the Peek & Reply overlay over the oldest pane needing attention. HONEST no-op when nothing needs
    /// attention (no target ⇒ empty card), so ⌘⌥J on a calm workspace does nothing rather than flashing an
    /// empty card. Resets the advance-exclusion so each open starts fresh.
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
    /// (``WorkspaceStore/peekReplyTargetPane(excluding:)``) over panes NOT yet answered this session. `nil`
    /// when nothing is left (the view then closes). Reads the store's `@Observable` per-pane status + the
    /// exclusion set, so a SwiftUI body re-resolves on either change.
    public func peekReplyTarget() -> PaneID? {
        store?.peekReplyTargetPane(excluding: peekReplyExcluding)
    }

    /// Deliver one formatted reply to `pane` then ADVANCE. The caller pre-formats via ``PeekReplyFormatter``
    /// (digit / bang-shell / plain), which already appends the trailing newline — so `text` is sent
    /// **VERBATIM** down the per-pane PTY funnel (``WorkspaceStore/sendPeekReply(_:to:)``), NEVER through
    /// `SendKeysParser`. Then the answered pane is excluded and the overlay closes when nothing needs
    /// attention. Observe + reply, **never a gate** — the agent was never blocked waiting on us.
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

    // MARK: Remote-window picker

    /// Present the Remote-Window picker (the `/remote-control` pill + the "New Remote Window Tab" action).
    /// Builds a fresh discovery-driving ``RemoteWindowModel`` bound to the live app target so its
    /// `refresh()` lists the current host's windows.
    public func openRemotePicker() {
        let model = RemoteWindowModel(target: connectionTarget)
        // docs/45: the LIVE push feed pre-warms the picker so it renders
        // instantly from ≤2 s-fresh data; the panel's on-appear refresh still re-validates.
        if let feed = hostWindowFeed, feed.isLive {
            model.prewarm(feed.structure.map { identity in
                RemoteWindowSummary(
                    windowID: identity.windowID,
                    appName: identity.appName,
                    title: feed.titles[identity.windowID] ?? "",
                    width: UInt16(clamping: feed.metrics[identity.windowID]?.widthPt ?? 0),
                    height: UInt16(clamping: feed.metrics[identity.windowID]?.heightPt ?? 0),
                )
            })
        }
        remotePickerModel = model
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
