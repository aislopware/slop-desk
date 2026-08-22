// OverlayCoordinator — the single `@MainActor @Observable` owner of the floating-overlay layer's state
// (warp-overlays-actions.md §4: a central reducer the chrome controls dispatch into). Owns:
//   - the command-palette presentation (mode + filter + query) and its mixer,
//   - the Settings open action (injected `openSettings` env action → the stock Settings scene),
//   - the toast stack (wired to the store's onPaneNotification / onLongCommandNotify / onAgentAttention),
//   - and routes a palette row's `PaletteAction` to the store, then closes.
//
// Mounted once at each shell's root view in a ZStack above the window. The busy-close modal is driven directly
// off the store's `pendingCloseSpec` — the coordinator owns only palette/settings/toasts.

import Foundation
import Observation
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel

/// How the palette was opened (warp-overlays-actions.md §2.1) — governs only the friendly omnibar label.
/// BOTH entry points are the ⌘⇧P Command Palette (verbs + the PANES jump rows); the multi-source ⌘⇧O
/// Open-Quickly jump-to is its OWN surface (`OpenQuicklyView`/`OpenQuicklyModel`), NOT a palette mode — so
/// there is no `openQuickly` case / `multiSource` flag here.
public enum PaletteMode: Sendable, Equatable {
    /// ⌘⇧P — the Command Palette (actions/verbs grouped by category + the open panes; NO filter chips).
    case command
    /// The title-bar omnibar entry (identical content — a friendlier label over the command palette).
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

    /// Whether the cross-tab Global Search surface (⇧⌘F) is presented. UNLIKE the four modal panels this is
    /// deliberately a NON-modal surface, so it must NOT swallow clicks over the workspace and is
    /// deliberately EXCLUDED from ``anyModalVisible``; ``OverlayHostView`` mounts it WITHOUT the modal
    /// hit-catching backdrop and
    /// gates hit-testing on this flag directly. Reopening RESTORES the store's last in-memory results
    /// (``WorkspaceStore/globalSearch``) until the query is re-run.
    public private(set) var globalSearchVisible = false

    // MARK: Open-Quickly state

    /// Whether the Open-Quickly picker (⌘⇧O All / ⌘J Current) is presented. A floating, centered MODAL
    /// quick-switcher card, so it is in ``anyModalVisible`` and mounted on ``OverlayHostView``'s
    /// hit-catching (non-dimming) backdrop. The picker reads its own sources (open panes / recents / folders / agents / the focused
    /// pane's links + OSC-133 command index) — like Global Search, the coordinator owns only the flag + pill.
    public private(set) var openQuicklyVisible = false

    /// The pill the picker opens to / is currently showing (``OpenQuicklyFilter``). ⌘⇧O opens ``.all``; ⌘J
    /// opens ``.current``; Tab/⇧Tab + the picker-local pill chords drive ``setOpenQuicklyFilter(_:)`` while it
    /// is open. Defaults to ``.all`` (the ⌘⇧O entry).
    public private(set) var openQuicklyFilter: OpenQuicklyFilter = .all

    // MARK: Peek & Reply state (answer a blocked agent INLINE, ⌘⌥J)

    /// Whether the Peek & Reply overlay (⌘⌥J) is presented. A centered MODAL card over the oldest pane
    /// needing attention (``WorkspaceStore/peekReplyTargetPane(excluding:)``) that answers a blocked agent
    /// INLINE — observe + reply, **NEVER an approval gate**: the agent is never paused
    /// pending a slopdesk confirmation. In ``anyModalVisible``, mounted on the hit-catching backdrop.
    public private(set) var peekReplyVisible = false

    /// The advance-to-next exclusion set accumulated while the overlay is open: each answered pane
    /// is added so ``peekReplyTarget()`` skips it on the immediate advance (a just-answered pane may still
    /// report `.needsPermission` until the host re-reports). Reset on every open/close so a fresh open
    /// re-targets cleanly.
    public private(set) var peekReplyExcluding: Set<PaneID> = []

    /// Resolves the app-global ``ConnectionTarget`` (kept for overlay features that query the host).
    /// Injected by the root.
    @ObservationIgnored public var connectionTarget: @MainActor () -> ConnectionTarget = { .default }

    // MARK: Chrome toggles (injected by the macOS window root, which owns the live `WorkspaceChromeState`)

    /// Toggles the left navigator / Tabs panel. Bound by `MacWorkspaceRootView` to `chrome.toggleSidebar()` so
    /// the "Toggle Tabs Panel" row flips the SAME live `chrome.sidebarCollapsed` the ⌘⇧L chord + titlebar
    /// button + the palette ✓ read — never the legacy `store.sidebarCollapsed` the native shell ignores. No-op
    /// by default (iOS / tests / previews), so the row is never a trap.
    @ObservationIgnored public var toggleSidebar: @MainActor () -> Void = {}
    /// Toggles the RIGHT code panel (the project-scoped embedded VS Code). Bound by `MacWorkspaceRootView`
    /// to `chrome.toggleCodeSidebar()` — the SAME live `chrome.codeSidebarCollapsed` the ⌘⇧R chord + the
    /// palette ✓ read. No-op by default (iOS / tests / previews), so the row is never a trap.
    @ObservationIgnored public var toggleCodeSidebar: @MainActor () -> Void = {}
    /// Moves the keyboard into the code panel's embedded editor, or hands it back (⌥⌘R). Bound by
    /// `MacWorkspaceRootView` to the same webview-pool hand-off the chord drives. No-op by default
    /// (iOS / tests / previews), so the row is never a trap.
    @ObservationIgnored public var focusCodePanel: @MainActor () -> Void = {}
    /// Toggles the window-pin flag (View ▸ Pin Window). Bound by `MacWorkspaceRootView` to
    /// `chrome.togglePin()` so any surface routed here flips the SAME live `WorkspaceChromeState.pinned` the
    /// menu Button + the macOS `NSWindow.level` glue read. No-op by default (iOS / tests / previews).
    @ObservationIgnored public var togglePinWindow: @MainActor () -> Void = {}
    /// Closes the active window (Window ▸ Close Window / the palette "Close Window" row). Bound on macOS to
    /// `NSWindow.performClose(nil)` (→ the native `windowShouldClose` gate, preserving ``CloseConfirmationPolicy``).
    /// `nil` (iOS / tests / a pre-`onAppear` scene) falls back to ``WorkspaceStore/requestCloseWindow()`` — the
    /// SAME parked-confirmation fallback the ⌘⇧W route arm uses, never a dead control.
    @ObservationIgnored public var closeWindow: (@MainActor () -> Void)?
    /// EAGERLY resolve the focused pane's cwd (host `cwd()` RPC →
    /// ``WorkspaceStore/setLastKnownCwd(_:for:)``) so the WORKING DIRECTORY header's cwd pill is populated the
    /// moment the palette opens. Bound by each shell's root view to the live ``MetadataClient``. WITHOUT this
    /// the pill stayed blank on a freshly-connected pane at a prompt: the only other `pane/cwd` writer — a
    /// command completing (OSC 133;D) — hadn't fired. Fired from ``openPalette(mode:query:)``; the resolution
    /// lands reactively within ~1 RTT, so the pill pops in without blocking the open. No-op by default (tests /
    /// previews / a disconnected pane), and spends NO new wire message (the `cwd()` RPC already exists).
    @ObservationIgnored public var resolveActiveCwd: @MainActor () -> Void = {}

    // MARK: Copy receipt (the window-level `COPIED · N` chip)

    /// The window-level copy receipt — published for NON-pane-scoped copies (palette "Copy Path",
    /// host-window rail "Copy Window Title"), whose trigger sheet / menu is already gone by the time the
    /// write lands, so no pane can host the confirmation. Pane-scoped copies publish
    /// ``TerminalViewModel/copyReceipt`` on their own pane instead and never route here.
    ///
    /// BOTH owners surface at the same place: `IslandChipStack` prefers this one and falls back to
    /// `WorkspaceStore.activePaneCopyReceipt()`, so a copy has ONE home wherever it started
    /// (user-directed 2026-08-11).
    public private(set) var copyReceipt: CopyReceipt?

    /// Per-copy monotonic counter — fresh identity per receipt so a rapid re-copy restarts the chip's
    /// dwell (`.task(id: epoch)`) instead of expiring on the old timer.
    @ObservationIgnored private var copyReceiptEpoch = 0

    /// Publish a fresh receipt for a completed pane-less clipboard write (the target the app wires
    /// ``WorkspaceStore/onLocalCopy`` to). Empty text is a no-op.
    public func noteCopy(_ text: String) {
        guard !text.isEmpty else { return }
        copyReceiptEpoch += 1
        copyReceipt = CopyReceipt(text: text, epoch: copyReceiptEpoch)
    }

    /// Dismisses the window-level chip (its dwell elapsed). Idempotent.
    public func clearCopyReceipt() {
        copyReceipt = nil
    }

    // MARK: Notice chip (the window-level transient `LABEL · DETAIL` cue)

    /// The window-level transient notice — the copy receipt's generic twin for non-copy cues (a sole-leaf
    /// tab close → the ⇧⌘T undo affordance; a Peek & Reply delivery → which pane got the reply). One slot:
    /// a successor RETARGETS the mounted chip (text hard-cuts, dwell restarts) rather than stacking.
    /// `IslandChipStack` mounts the shared `NoticeChip` at the island's foot while non-nil.
    public private(set) var notice: ChipNotice?

    /// Per-notice monotonic counter — fresh identity so a rapid successor restarts the chip's dwell
    /// (`.task(id: epoch)`) instead of expiring on the old timer.
    @ObservationIgnored private var noticeEpoch = 0

    /// Publish a transient notice, SENTENCE CASE throughout (the chip is paper now, and the caps register
    /// belongs to the glass — ``ChipNotice``). `label` names the event ("Tab closed"), `detail` carries the
    /// answer ("1,204 characters"; may be empty — the chip then shows the label alone), and `keycap` is a
    /// chord to draw as a pressable key rather than as words, which turns `detail` into the verb that
    /// finishes the sentence around it: `Tab closed ⇧⌘T reopens`.
    public func noteNotice(
        label: String, keycap: String? = nil, detail: String, dwell: Duration = .seconds(4),
    ) {
        noticeEpoch += 1
        notice = ChipNotice(
            label: label, keycap: keycap, detail: detail, epoch: noticeEpoch, dwell: dwell,
        )
    }

    /// Dismisses the notice chip (its dwell elapsed). Idempotent.
    public func clearNotice() {
        notice = nil
    }

    // MARK: Modal gate

    /// Whether ANY focus-stealing modal overlay is presented — the `OverlayHostView` hit-testing gate.
    /// True ⇒ the host's ZStack swallows clicks (scrim + centered panel); false ⇒ the host is transparent to
    /// hits so the workspace stays interactive (the always-mounted toast stack is NOT a modal, gated separately
    /// on `!toasts.isEmpty`). Excludes Settings AND the non-scrimmed Global Search surface (which must not dim
    /// the workspace) — the host gates Global Search's hit-testing separately on ``globalSearchVisible``.
    public var anyModalVisible: Bool {
        paletteVisible || cheatSheetVisible || connectVisible || openQuicklyVisible
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
    /// Monotonic dwell-timer identity handed to each pushed toast (``Toast/epoch``). A same-id replace keeps
    /// the id (so the card is REUSED, not re-inserted) but takes a FRESH epoch, which is what makes the
    /// card's `.task(id:)` restart its dwell instead of inheriting the replaced toast's spent time.
    private var toastEpoch = 0

    // MARK: Recents (mirrors the store's recent commands into palette item ids)

    /// The mixer that combines the verb-catalog sources + the per-open PANES snapshot (rebuilt per
    /// open — ⌘⇧P). `nil` until first opened.
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
        paletteMode = mode // cosmetic (the friendly omnibar label); the mixer is identical regardless of mode.
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

    /// Rebuild the ⌘⇧P mixer: the action catalog grouped into fixed categories (Working Directory /
    /// Window / Pane / Tab / View / Shell / Settings), one section header each, plus two DYNAMIC
    /// per-open store snapshots — the "Move Pane to Tab: …" verbs and the PANES jump rows
    /// (``TabsPaletteSource``: one row per open pane, searchable by live title / cwd, accept =
    /// `jumpToPaneTree`). A fixed catalog can't enumerate tabs or panes, so both snapshot per open. The
    /// richer multi-source jump-to (recents/folders/agents/files) stays in
    /// `OpenQuicklyView`/`OpenQuicklyModel`, NOT here.
    public func rebuildMixer() {
        // Every input the memo below is NOT keyed on individually — the mixer, the two per-open
        // snapshots — is replaced in this one method, so one counter covers all three.
        mixerGeneration &+= 1
        // The verb-catalog categories, one section header each.
        var sources = ActionsPaletteSource.categorySources()
        if let store {
            let movePane = MovePaneToTabSource.snapshot(store)
            if !movePane.isEmpty {
                sources.append(movePane)
                movePaneToTabItems = movePane.candidates(query: "")
            } else {
                movePaneToTabItems = []
            }
            // The PANES jump rows — verbs first, panes after, so an action title always outranks a
            // pane row on a shared query (section order beats score across sections).
            let panes = TabsPaletteSource.snapshot(store)
            paneJumpItems = panes.candidates(query: "")
            if !paneJumpItems.isEmpty { sources.append(panes) }
        } else {
            movePaneToTabItems = []
            paneJumpItems = []
        }
        mixer = SearchMixer(sources: sources)
    }

    /// The per-open "Move Pane to Tab: …" rows — kept so the zero-state can list them too (the mixer
    /// alone only surfaces them for a typed query).
    @ObservationIgnored private var movePaneToTabItems: [PaletteItem] = []

    /// The per-open PANES jump rows — kept so the zero-state lists the open panes too (discoverable
    /// without typing), mirroring the Move-Pane snapshot above.
    @ObservationIgnored private var paneJumpItems: [PaletteItem] = []

    // MARK: Palette results (view binds these)

    // ONE ranking pass backs all three properties below, memoized on everything it reads.
    //
    // They read like fields and they are a whole fzf pass over every catalog row: the mixer ranks
    // each of its ~8 category sources, and per source that is a fresh tuple array, a fresh
    // `[String?]` of three fields per row and one `slopdesk_ws_search_rank` crossing whose blob is
    // every title, subtitle and synonym concatenated. Measured, `swiftc -O` against the shipped
    // xcframework over a 90-row catalog in 8 sources, two runs agreeing: **~150 µs per read** for a
    // typed query, ~8 µs for the zero state.
    //
    // Nothing read it once. `selectableResults` re-ran the whole thing to answer `.count`, so
    // `moveSelection` — every ↑/↓ — paid one pass before the body paid another; the phone's
    // `PaletteView` reads `rankedResults` TWICE per body (rows, then the selected row's id). So an
    // arrow key cost 3 passes on the phone and 2 on the Mac, for one list that had not changed. It
    // is now one pass per (mixer, query, filter, recents) and an array read for every repeat.
    //
    // ``paletteResults`` is `rankedResults.map(\.item)` on BOTH branches — the typed path is
    // literally `SearchMixer.results` calling `ranked` and dropping the ranges, and the zero state
    // wraps range-less rows — so deriving one from the other is not an equivalence anyone has to
    // maintain. `OverlayCoordinatorMountTests` asserts it row for row.

    /// Everything the ranking reads. `generation` covers the mixer and the two per-open snapshots,
    /// which are replaced together in ``rebuildMixer()``; the recents ride WHOLE rather than behind
    /// a counter, so reading the key also registers the Observation dependency a cached answer would
    /// otherwise hide — a ⌘↩ chain that records a recent must still refresh the zero state's block.
    private struct ResultsKey: Equatable {
        let generation: Int
        let query: String
        let filter: QueryFilter?
        let recents: [String]
    }

    /// One ranking, in the three shapes the callers ask for. All three are cut from the same pass,
    /// so `selectableResults.count` — which every ↑/↓ reads — is an array read rather than a rank
    /// plus two filters.
    private struct Results {
        let key: ResultsKey
        let ranked: [RankedRow]
        let items: [PaletteItem]
        let selectable: [PaletteItem]
    }

    @ObservationIgnored private var mixerGeneration = 0
    @ObservationIgnored private var resultsMemo: Results?

    /// The one ranking pass, run at most once per distinct ``ResultsKey``.
    private var memoizedResults: Results {
        let key = ResultsKey(
            generation: mixerGeneration,
            query: paletteQuery.trimmingCharacters(in: .whitespaces),
            filter: paletteFilter,
            recents: store?.recentCommands ?? [],
        )
        if let memo = resultsMemo, memo.key == key { return memo }
        let ranked: [RankedRow] =
            if let mixer {
                if key.query.isEmpty, key.filter == nil {
                    zeroStateResults().map { RankedRow(item: $0) }
                } else {
                    mixer.ranked(query: key.query, activeFilter: key.filter)
                }
            } else {
                []
            }
        let items = ranked.map(\.item)
        let memo = Results(
            key: key, ranked: ranked, items: items, selectable: SearchMixer.selectable(items),
        )
        resultsMemo = memo
        return memo
    }

    /// The current ordered, sectioned result list. Empty query ⇒ the sectioned zero-state (PANES, then
    /// WORKING DIRECTORY, then Recents, then the catalog grouped by category) so the palette is never blank.
    public var paletteResults: [PaletteItem] { memoizedResults.items }

    /// Like ``paletteResults`` but WITH each row's fzf title-match ranges (``RankedRow``) — the palette view
    /// binds THIS so it can highlight matched code points. Via ``SearchMixer/ranked(query:activeFilter:)``; the
    /// zero-state (empty query, no filter) wraps each row in a range-less ``RankedRow`` (highlight is only
    /// meaningful for a typed query). Kept alongside ``paletteResults`` so callers/tests that only need items
    /// are unaffected.
    public var rankedResults: [RankedRow] { memoizedResults.ranked }

    /// Zero-state (empty query, no filter): the sectioned verb list. PANES leads (the palette doubles as a
    /// pane switcher, so the jump rows are visible without scrolling past the whole catalog); then WORKING
    /// DIRECTORY (its header OWNS the cwd badge, per command-palette.png) with its Copy Path row; then the
    /// MRU Recents block; then the rest of the catalog grouped by category. Empty categories are skipped (no
    /// empty header). Hand-built (not `mixer.ranked("")`) so the slopdesk-only Recents block can interleave
    /// after Working Directory. TYPED queries keep the mixer's verbs-before-panes order (see
    /// ``rebuildMixer()``) — this lead is a zero-state affordance, not a ranking change.
    private func zeroStateResults() -> [PaletteItem] {
        var out: [PaletteItem] = []
        // The open panes (snapshotted in `rebuildMixer`) lead — the palette doubles as a pane switcher,
        // so the list is visible before a query narrows it.
        if !paneJumpItems.isEmpty {
            out.append(.separator("Panes", filter: .tabs))
            out.append(contentsOf: paneJumpItems)
        }
        // Working Directory next — its header carries the cwd badge; Copy Path (+ TODO: host rows) below.
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
        // The dynamic per-tab move verbs (snapshotted in `rebuildMixer`) — listed in the zero-state too
        // so they're discoverable without typing.
        if !movePaneToTabItems.isEmpty {
            out.append(.separator("Move Pane", filter: .actions))
            out.append(contentsOf: movePaneToTabItems)
        }
        return out
    }

    /// Map the store's `recentCommands` ring (palette catalog ids) onto catalog rows, MRU order. An id with
    /// no catalog row left (a verb that has since been retired) is skipped. Each row is re-id'd into the
    /// `recent.*` namespace (``PaletteItem/namespacedForRecents()``) so it can't collide with its identical
    /// catalog row on the same `ForEach`/`.id` key — the action is preserved, so accept still runs the
    /// catalog verb.
    private func recentPaletteItems() -> [PaletteItem] {
        guard let store else { return [] }
        var out: [PaletteItem] = []
        for id in store.recentCommands {
            if let item = ActionsPaletteSource.rowsByID[id] {
                out.append(item.namespacedForRecents())
            }
        }
        return out
    }

    /// Run a REGISTRY verb the way the chord and the menu item run it — through the ONE
    /// ``WorkspaceBindingRegistry/route(_:to:)`` dispatch, threading this coordinator's own overlay
    /// switches so a summoning verb actually summons.
    ///
    /// This is the palette's half of the same wiring `WorkspaceStore/overlayKeyToggles` does for the
    /// phone's hardware keyboard and `WorkspaceKeyDispatcher` does for the Mac's NSEvent monitor —
    /// three callers, one dispatch. `toggleFind` is deliberately left `nil`: `route`'s own arm falls
    /// back to `store.requestFindInActivePane()`, which is the pane-owned find bar, and there is no
    /// coordinator-level find overlay to prefer over it.
    private func routeBinding(_ action: WorkspaceAction) {
        guard let store else { return }
        WorkspaceBindingRegistry.route(
            action, to: store,
            togglePalette: { [weak self] in self?.togglePalette() },
            toggleCheatSheet: { [weak self] in self?.toggleCheatSheet() },
            togglePeekReply: { [weak self] in self?.togglePeekReply() },
            toggleSidebar: toggleSidebar,
            toggleCodeSidebar: toggleCodeSidebar,
            toggleGlobalSearch: { [weak self] in self?.toggleGlobalSearch() },
            toggleJumpTo: { [weak self] in self?.toggleOpenQuickly(filter: .current) },
            openQuickly: { [weak self] in self?.toggleOpenQuickly() },
            togglePinWindow: togglePinWindow,
            closeWindow: closeWindow,
            focusCodePanel: focusCodePanel,
        )
    }

    /// The selectable rows (non-separators) of the current result list — keyboard nav target.
    public var selectableResults: [PaletteItem] { memoizedResults.selectable }

    // MARK: Palette keyboard / accept

    /// Move the keyboard selection by `delta`, clamped to the selectable rows (wrapping not done — Warp
    /// clamps, and so does ``ListNavigation/clampedSelection``, which the picker and the command
    /// navigator move by too). `delta` is ±1 for the arrows and ± one viewport's worth for ⇞/⇟ (the
    /// view derives the stride from its own row metrics); an empty list answers `0`.
    public func moveSelection(_ delta: Int) {
        paletteSelection = ListNavigation.clampedSelection(
            current: paletteSelection, delta: delta, count: selectableResults.count,
        )
    }

    /// Jump the keyboard selection to the FIRST selectable row (⌘↑ — the macOS list idiom).
    public func moveSelectionToFirst() {
        paletteSelection = 0
    }

    /// Jump the keyboard selection to the LAST selectable row (⌘↓) — the End key's move, which is
    /// the same clamp with the whole list as its delta. A no-op-safe `0` when empty.
    public func moveSelectionToLast() {
        let count = selectableResults.count
        paletteSelection = ListNavigation.clampedSelection(current: 0, delta: count, count: count)
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
    /// suppresses the close for the chainable `.store`/chrome-toggle rows; the overlay-switching
    /// rows (settings/connect/cheat/picker) always close-then-open. Chrome-toggle rows route through the
    /// injected ``toggleSidebar`` closure so they flip the LIVE `WorkspaceChromeState` — not the dead
    /// `store.sidebarCollapsed`.
    public func run(_ item: PaletteItem, keepOpen: Bool = false) {
        guard !item.isSeparator else { return }
        // Every accepted VERB is a recent — but a filter chip and a zero row are not verbs. This used
        // to be five hand-picked `recordRecentCommand` calls buried in five run arms, which meant the
        // MRU block answered "which verbs did someone remember to instrument", not "which verbs do you
        // use". A Recents row is namespaced (`recent.<id>`) and re-running it must record the CATALOG
        // id, or the ring fills with rows that resolve to nothing.
        switch item.action {
        case .selectFilter,
             .noOp: break
        default: store?.recordRecentCommand(item.catalogID)
        }
        switch item.action {
        case let .store(closure):
            if let store { closure(store) }
            if !keepOpen { closePalette() }
        case let .binding(action):
            // Close FIRST: a verb that summons another overlay (Find, Global Search, Jump To, the
            // cheat sheet, Peek & Reply) would otherwise open underneath the palette it was picked
            // from. A mutation does not care about the order.
            if !keepOpen { closePalette() }
            routeBinding(action)
        case let .selectFilter(filter):
            paletteFilter = filter
            paletteSelection = 0
        case .openSettings:
            closePalette()
            openSettings()
        case .openConnect:
            closePalette()
            openConnect()
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
        // The delivery cue: the card advances (or closes) the instant the reply lands, so without a cue
        // a submit is indistinguishable from a skip/cancel. The notice names WHICH pane got the reply —
        // the one doubt the advance leaves. The title is untrusted OSC-settable text ⇒ masked at this
        // construction site (idempotent, same rule as the toast surfaces).
        if let title = store?.peekContent(for: pane).title {
            noteNotice(label: "Reply sent", detail: Toast.redactSecretsIfEnabled(title), dwell: .seconds(2.5))
        }
        advancePeekReply(answered: pane)
    }

    /// Advance past the just-answered `pane`: add it to the exclusion set, then close the overlay when no pane
    /// still needs attention. Public so the view's submit / quick-answer paths (and a test) drive it directly.
    public func advancePeekReply(answered pane: PaneID) {
        peekReplyExcluding.insert(pane)
        if peekReplyTarget() == nil { closePeekReply() }
    }

    // MARK: Toasts

    /// Push a toast (newest last); evicts the oldest beyond the cap and de-dupes by id (a newer same-id
    /// toast replaces the old one, warp `object_id` discipline).
    public func pushToast(_ toast: Toast) {
        toastEpoch += 1
        var stamped = toast
        stamped.epoch = toastEpoch
        toasts.removeAll { $0.id == stamped.id }
        toasts.append(stamped)
        if toasts.count > Self.toastCap {
            toasts.removeFirst(toasts.count - Self.toastCap)
        }
    }

    /// Dismiss a toast by id (the X button or the auto-dismiss timer).
    public func dismissToast(_ id: String) {
        toasts.removeAll { $0.id == id }
    }
}
