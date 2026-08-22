// PaletteDataSource — the per-domain result providers + the SearchMixer that combines them
// (warp-overlays-actions.md §1.2 / §2.2). A `PaletteDataSource` is registered against a set of
// `QueryFilter`s and returns its `PaletteItem`s for a query; the `SearchMixer` runs the registered sources
// in order, keeps a source iff the query has no filter OR a registered filter matches, ranks the union by
// per-item score, and groups them under section separators.
//
// All sources here are SYNCHRONOUS over a store SNAPSHOT (taken on the @MainActor) so the mixing/ranking is
// pure + unit-testable without a view. The ⌘⇧P palette mixes the ACTIONS catalog (grouped by category) plus
// the PANES jump rows (`TabsPaletteSource` — a pane is searchable by title/cwd right in the palette); the
// richer multi-source jump-to (recents/folders/agents/files) stays on its OWN surface
// (`OpenQuicklyModel`/`OpenQuicklyView`), so the former `files`/`conversations`/`repos` empty-stub sources
// were removed here — they were never reachable.

import Foundation
import SlopDeskAgentDetect
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel

// MARK: - Data source protocol

/// A palette result provider for one or more domains (warp-overlays-actions.md §2.2). `results(for:)` is
/// pure over a captured snapshot — the live store read happens when the snapshot is built on the @MainActor.
public protocol PaletteDataSource: Sendable {
    /// The filters this source answers (the mixer runs it when the query filter is nil or one of these).
    var filters: Set<QueryFilter> { get }
    /// The section header label shown above this source's rows (nil ⇒ no separator).
    var sectionTitle: String? { get }
    /// The rows this source returns for `query` (already title/subtitle-matched + scored by the caller — a
    /// source returns its FULL candidate set; the mixer filters + ranks).
    func candidates(query: String) -> [PaletteItem]
}

// MARK: - ACTIONS source (the WorkspaceCommand catalog) — REAL

/// The action catalog source (warp-overlays-actions.md §4.4) — the workspace verbs (new tab, close pane,
/// split H/V, toggle sidebar, open settings, …). Each row runs a tree-path store mutation directly (under
/// `.tree`, per logic-api §7.5) and records a recent command where the verb is recents-worthy. REAL
/// (the only fully client-side-wired source besides TABS).
public struct ActionsPaletteSource: PaletteDataSource {
    public let filters: Set<QueryFilter> = [.actions]
    public let sectionTitle: String? = "Actions"

    public init() {}

    public func candidates(query _: String) -> [PaletteItem] { Self.catalog }

    /// The fixed action catalog. IDs are stable so recents/tests can reference them. Each `.store` closure
    /// drives the tree-path store API (not the canvas-era `apply`), then records the matching recent command.
    ///
    /// Shortcut hints are NEVER hardcoded — each row derives its glyph from
    /// ``WorkspaceBindingRegistry/glyph(for:)`` (the SAME single source the keyboard bank registers and the
    /// cheat sheet renders) so a chord change can't desync the displayed glyph. A verb with no registry
    /// chord (New Remote Window Tab, Reconnect Pane, …) resolves to `nil` ⇒ no hint chip — correct, since
    /// the chord genuinely does not exist.
    public static let catalog: [PaletteItem] = declared.filter { PaletteRowPlatform.lists($0.id) }

    /// Every verb the catalog DECLARES, before the platform filter. Private because a caller that
    /// wanted this one rather than ``catalog`` would be asking for the rows this half cannot run —
    /// which is the defect ``PaletteRowPlatform`` exists to close.
    private static let declared: [PaletteItem] = [
        // WORKING DIRECTORY — leads the palette (the section header OWNS the cwd badge in the view). "Copy
        // Path" is a CLIENT-side write of the focused pane's cwd to the platform
        // pasteboard. Sibling "Reveal in Finder" / "Open in…" rows are host-routed —
        // TODO: add them once the host can resolve a local Finder/Open path over the control channel.
        item(
            id: "action.copyPath", icon: "doc.on.doc", title: "Copy Path",
            category: .workingDirectory,
            run: { store in
                guard let session = store.tree.activeSession,
                      let paneID = session.activeTab?.activePane,
                      let cwd = store.paneCwd(for: paneID), !cwd.isEmpty else { return }
                copyToPasteboard(cwd)
                // Pane-less confirmation: the palette sheet is closing as the write lands, so the
                // window-level `COPIED · N` chip (store hook → overlay coordinator) is the receipt.
                store.noteLocalCopy(cwd)
            },
        ),
        verb(
            id: "action.newTerminalTab", icon: "plus.rectangle", title: "New Tab",
            category: .tab, runs: .newTab,
        ),
        // "Remote Desktop" (⌥⌘N): the dedicated desktop WINDOW — reveal-or-mint, never a tab.
        verb(
            id: "action.newDesktopTab", icon: "display", title: "Remote Desktop",
            category: .tab, runs: .newDesktopTab,
        ),
        verb(
            id: "action.closeTab", icon: "xmark.rectangle", title: "Close Tab",
            category: .tab, runs: .closeTab,
        ),
        verb(
            id: "action.splitRight", icon: "rectangle.split.2x1", title: "Split Pane Right",
            category: .pane, runs: .splitRight,
        ),
        verb(
            id: "action.splitDown", icon: "rectangle.split.1x2", title: "Split Pane Down",
            category: .pane, runs: .splitDown,
        ),
        verb(
            id: "action.closePane", icon: "xmark.square", title: "Close Pane",
            category: .pane, runs: .closePane,
        ),
        verb(
            id: "action.toggleZoom", icon: "arrow.up.left.and.arrow.down.right", title: "Toggle Maximize Pane",
            category: .pane, runs: .toggleZoom,
        ),
        verb(
            id: "action.renamePane", icon: "pencil", title: "Rename Pane",
            category: .pane, runs: .renamePane,
        ),
        // Detach / reattach (own-window satellites). Non-destructive: the pane's session survives the
        // move; closing the satellite window reattaches it.
        // The gate these two rows' run arms used to carry is now the row's PLATFORM
        // (`slopdesk_workspace::palette_rows`): a shell with no satellite `NSWindow` does not list the
        // verb at all, rather than listing it and answering with nothing.
        verb(
            id: "action.detachPane", icon: "macwindow.on.rectangle", title: "Detach Pane into Window",
            keywords: "detach pop out float window satellite separate monitor",
            category: .pane, runs: .detachPane,
        ),
        verb(
            id: "action.reattachAllPanes", icon: "macwindow.and.cursorarrow", title: "Reattach All Panes",
            keywords: "reattach dock fold return window satellite",
            category: .pane, runs: .reattachAllPanes,
        ),
        // "Move Pane to New Tab" — the keyboard twin of dropping a pane on the sidebar's New-Tab slot
        // (`breakPaneToTab`). PaneID-preserving, so the live session survives. Chord-less ⇒ no hint
        // chip. Under TAB (with New Tab / Close Tab / Reopen Closed Pane — the tab-shape verbs): the
        // Pane section renders FIRST, so a `.pane` row matching "new tab" would shadow the exact
        // "New Tab" verb for that query (section order beats score across sections). Its per-tab
        // siblings ("Move Pane to Tab N") are DYNAMIC rows the coordinator snapshots per palette open
        // (``MovePaneToTabSource``) — a fixed catalog can't enumerate tabs.
        verb(
            id: "action.movePaneToNewTab", icon: "plus.square.on.square", title: "Move Pane to New Tab",
            keywords: "move break pane new tab own separate split out",
            category: .tab, runs: .breakPaneToTab,
        ),
        // No registry chord exists for reconnect (the keyboard bank never registers one) ⇒ no hint chip.
        item(
            id: "action.reconnect", icon: "arrow.clockwise", title: "Reconnect Pane",
            shortcut: nil, category: .pane,
            run: { store in
                if let pane = store.tree.activeSession?.activeTab?.activePane {
                    store.reconnect(pane)
                }
            },
        ),
        // "Toggle Tabs Panel" toggles the LIVE `WorkspaceChromeState.sidebarCollapsed` (the macOS split + the
        // palette ✓ both read it) via a typed action the overlay coordinator routes to the injected chrome
        // closure — NOT the legacy `store.sidebarCollapsed`, which nothing reads on macOS (running it there was
        // a visible no-op AND its ✓ could never flip from the palette). Same live flag the ⌘⇧L chord drives.
        verb(
            id: "action.toggleSidebar", icon: "sidebar.left", title: "Toggle Tabs Panel",
            category: .view, runs: .toggleSidebar,
        ),
        // "Toggle Code Panel" — the RIGHT sidebar (project-scoped embedded VS Code). Routed through
        // the injected chrome closure like the Tabs panel, so the ⌘⇧R chord, the menu row, and this
        // row's ✓ all flip/read the same live `chrome.codeSidebarCollapsed`.
        verb(
            id: "action.toggleCodeSidebar", icon: "sidebar.right", title: "Toggle Code Panel",
            category: .view, runs: .toggleCodeSidebar,
        ),
        // The keyboard's way into the embedded editor and back out. Sits beside the panel's own
        // toggle: one row decides whether the panel is THERE, this one decides who types into it.
        verb(
            id: "action.focusCodePanel", icon: "keyboard", title: "Switch Editor / Terminal Focus",
            category: .view, runs: .focusCodePanel,
        ),
        // Read Only: toggle the active pane's input gate. Under the SHELL section as the
        // first shell verb in the catalog. The spec accepts
        // "read only" plus the synonyms `readonly` / `lock` / `freeze` / `view only` — folded into the row's
        // HIDDEN `keywords` so they search without being rendered. No registry chord is registered for this
        // verb ⇒ the glyph resolves to nil ⇒ no hint chip. Drives the store seam that converges with the pill `×` + menu.
        verb(
            id: "action.toggleReadOnly", icon: "lock", title: "Read Only",
            keywords: "readonly lock freeze view only locked viewer input gate protect",
            category: .shell, runs: .toggleReadOnly,
        ),
        // Secure Keyboard Entry: the MANUAL toggle for macOS process-global secure event input
        // over the active pane. Under the SHELL section beside Read Only.
        // No registry chord is registered for this verb ⇒ the glyph resolves to nil ⇒ no hint chip. Drives the store
        // seam that flips the active model's manual flag (→ the pill + the leaf's controller).
        verb(
            id: "action.secureKeyboardEntry", icon: "lock.shield", title: "Secure Keyboard Entry",
            keywords: "secure input keyboard entry password sudo protect eavesdrop sniff secure event input",
            category: .shell, runs: .secureKeyboardEntry,
        ),
        // Reopen Closed Pane (⌘⇧T) — pops the tree shell's recently-closed LIFO. A graceful no-op when
        // the LIFO is empty. Glyph derives from the registry's `.reopenClosed` chord (no drift).
        verb(
            id: "action.reopenClosed", icon: "arrow.uturn.backward", title: "Reopen Closed Pane",
            keywords: "reopen closed tab pane restore undo recover",
            category: .tab, runs: .reopenClosed,
        ),
        // Sync Input to All Panes (Zellij ToggleActiveSyncTab-style broadcast; ⌘⇧I) — mirror keystrokes to
        // every other pane in the active tab. A graceful no-op when there is no active tab.
        verb(
            id: "action.toggleSyncInput", icon: "rectangle.3.group", title: "Sync Input to All Panes",
            keywords: "sync broadcast send all panes input mirror simultaneous",
            category: .pane, runs: .toggleSyncInput,
        ),
        // Named layout presets (tmux/zellij `select-layout`; registry comment: "menu/palette only — no
        // chord"). The registry tracks `.applyLayout(_)` as palette/menu-only but listed it on NEITHER surface
        // (only the chorded `.cycleLayout` shipped), so the documented entry point was missing. Surface the five
        // presets here so they're reachable. Each re-tiles the active tiled tab directly via
        // ``WorkspaceStore/applyLayout(_:)`` (a graceful no-op on a 0/1-leaf tab). Chord-less ⇒ no hint chip.
        layoutItem(
            id: "action.layoutEvenHorizontal",
            title: "Layout: Even Horizontal",
            icon: "rectangle.split.3x1",
            preset: .evenHorizontal,
        ),
        layoutItem(
            id: "action.layoutEvenVertical",
            title: "Layout: Even Vertical",
            icon: "rectangle.split.1x2",
            preset: .evenVertical,
        ),
        layoutItem(
            id: "action.layoutMainVertical",
            title: "Layout: Main Vertical",
            icon: "rectangle.split.2x1",
            preset: .mainVertical,
        ),
        layoutItem(
            id: "action.layoutMainHorizontal",
            title: "Layout: Main Horizontal",
            icon: "square.split.1x2",
            preset: .mainHorizontal,
        ),
        layoutItem(
            id: "action.layoutTiled",
            title: "Layout: Tiled",
            icon: "rectangle.split.2x2",
            preset: .tiled,
        ),
        // Close Window (⌘⇧W) — routes through the injected `closeWindow` closure
        // (macOS `NSWindow.performClose` → the close-confirmation gate), falling back to the store's parked
        // confirmation when no closure is installed (iOS / tests). The SAME actuation the ⌘⇧W chord + menu use.
        verb(
            id: "action.closeWindow", icon: "xmark.square", title: "Close Window",
            keywords: "close window quit session",
            category: .window, runs: .closeWindow,
        ),
        // Font size (⌘= / ⌘- / ⌘0) — rescale the active pane's render font (the cell box resizes, so the
        // remote PTY grid REFLOWS). A graceful no-op off a terminal active pane.
        verb(
            id: "action.increaseFontSize", icon: "textformat.size.larger", title: "Increase Font Size",
            keywords: "font size bigger increase larger zoom in text",
            category: .view, runs: .increaseFontSize,
        ),
        verb(
            id: "action.decreaseFontSize", icon: "textformat.size.smaller", title: "Decrease Font Size",
            keywords: "font size smaller decrease zoom out text",
            category: .view, runs: .decreaseFontSize,
        ),
        verb(
            id: "action.resetFontSize", icon: "textformat.size", title: "Reset Font Size",
            keywords: "font size reset default actual zoom text",
            category: .view, runs: .resetFontSize,
        ),
        // Connect to a (possibly non-default) host — the only entry point to the host/port editor besides
        // the top-bar status pill. No registry chord ⇒ no hint chip.
        PaletteItem(
            id: "action.connect", icon: "network", title: "Connect to Host…",
            subtitle: nil, shortcut: nil, filter: .actions, category: .window, action: .openConnect,
        ),
        // Pin Window (float the window above all other apps). A CHECKABLE
        // toggle: `PalettePresentation.toggledState(chrome:store:)` lights the ✓ gutter when `chrome.pinned`.
        // CHORD-LESS (no registry chord is registered) ⇒ `shortcut: nil` ⇒ no hint chip; routed by the coordinator to the
        // injected `togglePinWindow` closure (the SAME live `chrome.pinned` the View menu + the `NSWindow.level`
        // glue read). macOS-meaningful (iOS has no window level — a documented no-op).
        verb(
            id: "action.pinWindow", icon: "pin", title: "Pin Window",
            category: .window, runs: .pinWindow,
        ),
        PaletteItem(
            id: "action.openSettings", icon: "slider.horizontal.3", title: "Open Settings",
            subtitle: nil, shortcut: nil, filter: .actions, category: .settings, action: .openSettings,
        ),
        // The cheat sheet is also reachable by ⌘/; surfacing it here means the keyboard reference is
        // discoverable without knowing the chord. Its hint derives from the registry (no drift).
        verb(
            id: "action.cheatSheet", icon: "keyboard", title: "Keyboard Shortcuts",
            category: .settings, runs: .cheatSheet,
        ),
    ]

    /// The registry verbs the hand-written catalog above ALREADY carries, derived from the rows
    /// themselves rather than listed a second time.
    ///
    /// Read from ``declared`` and not from ``catalog``: a row this half does not list is still a row
    /// the catalog SPEAKS FOR, and the registry drops the same verb on the same half anyway
    /// (`slopdesk_workspace::binding_rows`), so filtering first would only make the two tables argue.
    static let coveredActions: Set<WorkspaceAction> = Set(declared.compactMap { item in
        guard case let .binding(action) = item.action else { return nil }
        return action
    })

    /// Two verbs no registry-derived row is minted for, and the whole of that exclusion.
    ///
    /// `.commandPalette` opens the surface the row is being read on. `.selectPane` is the nine
    /// generated ⌘1…⌘9 chords collapsed to one display row whose TITLE promises a range — a row that
    /// answered Return by selecting pane 1 would be lying about what it does, and the ⌘-digit that
    /// tells the truth is already registered.
    private static func isUnlistable(_ action: WorkspaceAction) -> Bool {
        if case .selectPane = action { return true }
        return action == .commandPalette
    }

    /// Every KEYBINDING the catalog does not already carry, as a palette row.
    ///
    /// The registry is not a second catalog — it is the same catalog, one surface further in, and
    /// until this existed the palette listed 33 of its 77 rows. On a Mac that gap was invisible
    /// (the menu bar reaches every binding); on a phone with no hardware keyboard the palette IS the
    /// command surface, so ~45 verbs — every focus move, every resize nudge, every scroll jump, Vi
    /// mode, hint mode, the block jumps — were simply unreachable. docs/56 §3: layout diverges,
    /// capability does not.
    ///
    /// Platform-correct without a gate of its own: ``WorkspaceBindingRegistry/bindings`` is already
    /// filtered by `slopdesk_workspace::binding_rows`, so a half that cannot run a verb never sees a
    /// row for it here either.
    static let registryRows: [PaletteItem] = WorkspaceBindingRegistry.bindings
        .filter { !coveredActions.contains($0.action) && !isUnlistable($0.action) }
        .map { binding in
            PaletteItem(
                id: "binding.\(binding.id)", icon: binding.symbol, title: binding.title,
                keywords: binding.keywords, shortcut: WorkspaceBindingRegistry.glyph(for: binding.action),
                filter: .actions, category: PaletteCategory(binding.category),
                action: .binding(binding.action),
            )
        }

    /// Every row the ⌘⇧P palette can list, catalog first — the lookup the Recents block resolves its
    /// ids against, so a registry-derived verb can be a recent too.
    public static let allRows: [PaletteItem] = catalog + registryRows

    /// ``allRows`` indexed by id — what the Recents block resolves through.
    ///
    /// A `let` rather than the `first(where:)` that was here, for ``rowsByCategory``'s reason one
    /// register down: the MRU ring is walked on every zero-state read, and a linear scan of ~90 rows
    /// per remembered id is a scan per row of a block that has at most a dozen.
    static let rowsByID: [String: PaletteItem] = Dictionary(
        allRows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first },
    )

    /// ``allRows`` grouped by the section each row draws under.
    ///
    /// A `let`, on `SettingsCatalog.groupRows`' argument: the answer is a pure function of a
    /// constant, and the reader is the palette's zero state, which runs on every ⌘⇧P open AND on
    /// every read of the result list while the query is empty. Filtering `allRows` per category
    /// meant one full pass over the catalog per SECTION — 8 passes over ~90 rows and 8 fresh arrays
    /// to lay out a list that never changes. Measured, `swiftc -O`, two runs agreeing: the whole
    /// zero-state build went **8.1 µs → 2.7 µs**, and what is left is the concatenation itself.
    /// A row with NO category is in no group, exactly as the `==` this replaced left it out.
    private static let rowsByCategory: [PaletteCategory: [PaletteItem]] = {
        var out: [PaletteCategory: [PaletteItem]] = [:]
        for row in allRows {
            guard let category = row.category else { continue }
            out[category, default: []].append(row)
        }
        return out
    }()

    /// The rows in `category`, hand-written catalog first and then the registry-derived ones — the
    /// verbs-only command palette groups by these (one section header per non-empty category).
    ///
    /// The table is built by appending in `allRows` order, so this is `allRows` restricted to one
    /// category — the same list the filter answered, read rather than rebuilt.
    public static func items(in category: PaletteCategory) -> [PaletteItem] {
        rowsByCategory[category] ?? []
    }

    /// One ``PaletteDataSource`` per non-empty category, in ``PaletteCategory/commandOrder`` — the verbs-only
    /// ⌘⇧P palette registers these so the mixer emits a section header per category (Working
    /// Directory / Window / Pane / Tab / View / Settings) for a typed query. (The empty-query zero-state is
    /// hand-built the same way in ``OverlayCoordinator/zeroStateResults()`` so it can interleave Recents.)
    public static func categorySources() -> [any PaletteDataSource] {
        PaletteCategory.commandOrder.compactMap { category in
            let rows = items(in: category)
            return rows.isEmpty ? nil : CategoryActionsSource(category: category, items: rows)
        }
    }

    /// Write `string` to the platform pasteboard — the client-side local clipboard
    /// write. Host-routed Reveal/Open are a future addition.
    private static func copyToPasteboard(_ string: String) {
        ClientPasteboard.write(string)
    }

    /// The live registry glyph for `action`'s default chord (nil when unbound) — the ONE source the catalog
    /// hints derive from, so the displayed chord can never drift from the keyboard bank.
    private static func glyph(_ action: WorkspaceAction) -> String? {
        WorkspaceBindingRegistry.glyph(for: action)
    }

    /// Build a row that runs the REGISTRY verb `action` — the same dispatch the chord and the menu
    /// item resolve to, so the row cannot drift from them. The hint chip derives from that verb's own
    /// chord (nil when it has none), which is why this helper takes no `shortcut:`.
    private static func verb(
        id: String, icon: String, title: String, keywords: String? = nil,
        category: PaletteCategory, runs action: WorkspaceAction,
    ) -> PaletteItem {
        PaletteItem(
            id: id, icon: icon, title: title, keywords: keywords, shortcut: glyph(action),
            filter: .actions, category: category, action: .binding(action),
        )
    }

    /// Build a `.store` action row in a category — for the verbs the registry has NO binding for
    /// (Copy Path, Reconnect Pane, the named layout presets, Connect to Host…, Open Settings). A row
    /// whose verb the registry DOES carry belongs in ``verb(id:icon:title:keywords:category:runs:)``.
    private static func item(
        id: String, icon: String, title: String, keywords: String? = nil, shortcut: String? = nil,
        category: PaletteCategory,
        run: @escaping @MainActor @Sendable (WorkspaceStore) -> Void,
    ) -> PaletteItem {
        PaletteItem(
            id: id, icon: icon, title: title, keywords: keywords, shortcut: shortcut,
            filter: .actions, category: category, action: .store(run),
        )
    }

    /// Build a PANE "Layout: …" row whose `.store` run-arm re-tiles the active tab into a named
    /// ``WorkspaceTreeOps/LayoutPreset`` via ``WorkspaceStore/applyLayout(_:)`` (a graceful no-op on a 0/1-leaf
    /// tab). Chord-less (the named presets ship no key equivalent) ⇒ no hint chip. The keyword set folds in the
    /// tmux/zellij/select-layout synonyms so "layout" / "retile" / "tile" all surface the rows.
    private static func layoutItem(
        id: String, title: String, icon: String, preset: WorkspaceTreeOps.LayoutPreset,
    ) -> PaletteItem {
        item(
            id: id, icon: icon, title: title,
            keywords: "layout retile arrange tile even main tiled select-layout tmux zellij \(preset.rawValue)",
            shortcut: nil, category: .pane,
            run: { store in store.applyLayout(preset) },
        )
    }
}

// MARK: - CATEGORY ACTIONS source (one category of the verb catalog) — REAL

/// A single verb category of ``ActionsPaletteSource/catalog`` (Working Directory / Window / Pane / …)
/// surfaced as its own ``PaletteDataSource`` so the verbs-only ⌘⇧P palette's mixer emits one section header
/// per category. Filters on `.actions` like the parent source; the section title is the category label.
public struct CategoryActionsSource: PaletteDataSource {
    public let filters: Set<QueryFilter> = [.actions]
    public let sectionTitle: String?
    private let items: [PaletteItem]

    public init(category: PaletteCategory, items: [PaletteItem]) {
        sectionTitle = category.label
        self.items = items
    }

    public func candidates(query _: String) -> [PaletteItem] { items }
}

// MARK: - MOVE-PANE-TO-TAB source (dynamic per-tab move verbs) — REAL

/// One "Move Pane to Tab: <title>" verb per OTHER tab of the active session — the keyboard twin of
/// dropping a pane on a sidebar row (`moveLeafAcrossTabsTree`, PaneID-preserving: the live session
/// survives the hop). DYNAMIC: the fixed ``ActionsPaletteSource/catalog`` can't enumerate tabs, so the
/// overlay coordinator snapshots this source per palette open (same pattern as ``TabsPaletteSource``).
/// The moved pane lands BESIDE the destination tab's active pane (a horizontal split after it) — the
/// same landing the sidebar-row drop commits.
public struct MovePaneToTabSource: PaletteDataSource {
    public let filters: Set<QueryFilter> = [.actions]
    public let sectionTitle: String? = "Move Pane"

    /// A snapshot row: the DESTINATION tab, resolved by stable id at run time (an index could shift
    /// between snapshot and accept).
    public struct Entry: Sendable {
        public let tabID: TabID
        /// The tab's active pane's live title — the row SUBTITLE (context, not identity).
        public let title: String
        /// 1-based position at snapshot time — the row title + the "tab 2" search keyword.
        public let tabNumber: Int
    }

    private let entries: [Entry]

    public init(entries: [Entry]) { self.entries = entries }

    public var isEmpty: Bool { entries.isEmpty }

    /// Build a snapshot from the live store: every tab of the active session EXCEPT the active one
    /// (moving a pane "to its own tab" is the identity op). The row TITLE is the stable position
    /// ("Move Pane to Tab 2" — every fresh pane is titled "Terminal", so a title-based label would
    /// render indistinguishable twins); the tab's live pane title rides the SUBTITLE for context.
    @preconcurrency
    @MainActor
    public static func snapshot(_ store: WorkspaceStore) -> Self {
        guard let session = store.tree.activeSession, session.tabs.count > 1 else { return Self(entries: []) }
        var out: [Entry] = []
        for (index, tab) in session.tabs.enumerated() where index != session.activeTabIndex {
            let spec = tab.activePane.flatMap { session.specs[$0] }
            let live = tab.activePane.flatMap { store.liveProgramTitle(for: $0) } ?? spec?.title ?? ""
            out.append(Entry(tabID: tab.id, title: live, tabNumber: index + 1))
        }
        return Self(entries: out)
    }

    public func candidates(query _: String) -> [PaletteItem] {
        entries.map { entry in
            PaletteItem(
                id: "action.movePaneToTab.\(entry.tabID.raw.uuidString)",
                icon: "rectangle.stack",
                title: "Move Pane to Tab \(entry.tabNumber)",
                subtitle: entry.title.isEmpty ? nil : entry.title,
                keywords: "move pane tab \(entry.tabNumber) across send transfer",
                shortcut: nil,
                filter: .actions,
                category: .pane,
                action: .store { store in
                    guard let session = store.tree.activeSession,
                          let source = session.activeTab?.activePane,
                          let dest = session.tabs.first(where: { $0.id == entry.tabID }),
                          let anchor = dest.activePane
                    else { return }
                    store.moveLeafAcrossTabsTree(source, beside: anchor, axis: .horizontal, before: false)
                },
            )
        }
    }
}

// MARK: - PANES source (jump to a pane) — REAL

/// Jump-to-pane source (warp-overlays-actions.md §2.2 navigation). One row per visible pane of the
/// active session's tabs (the same enumeration the rail uses); selecting it focuses that pane. Registered
/// into the ⌘⇧P mixer by the overlay coordinator (a per-open snapshot, like ``MovePaneToTabSource``) so a
/// pane is searchable by its live title / cwd without leaving the palette; the multi-source Open-Quickly
/// picker remains the dedicated jump surface.
public struct TabsPaletteSource: PaletteDataSource {
    public let filters: Set<QueryFilter> = [.tabs]
    public let sectionTitle: String? = "Panes"

    /// A snapshot row (the store read is done when the snapshot is built).
    public struct Entry: Sendable {
        public let paneID: PaneID
        public let tabIndex: Int
        public let title: String
        public let subtitle: String?
        public let isAgent: Bool
        /// A VIDEO pane (window / desktop stream): rendered with the window glyph; its jump routes
        /// through the same `jumpToPaneTree` funnel as any pane.
        public var isWindow: Bool = false
        /// The pane's raw cwd — a HIDDEN search keyword (the rendered subtitle is the switcher's quiet
        /// place line, but a full-path query must still find the pane).
        public var cwd: String?
    }

    private let entries: [Entry]

    public init(entries: [Entry]) { self.entries = entries }

    /// Build a snapshot from the live store (active session's tabs → one entry per visible pane).
    /// Title + subtitle come from ``PaneSwitcherRowsBuilder/identity(pane:spec:tab:store:)`` — the SAME
    /// chain the ⌃⇥ switcher and the sidebar resolve, so the palette can never call a pane something
    /// the switcher does not.
    @preconcurrency
    @MainActor
    public static func snapshot(_ store: WorkspaceStore) -> Self {
        guard let session = store.tree.activeSession else { return Self(entries: []) }
        var out: [Entry] = []
        for (tabIndex, tab) in session.tabs.enumerated() {
            // Enumerate the tab's full pane set (`tab.allPaneIDs()`, pre-order DFS) — matching OpenQuickly.
            for paneID in tab.allPaneIDs() {
                let spec = session.specs[paneID]
                let ident = PaneSwitcherRowsBuilder.identity(pane: paneID, spec: spec, tab: tab, store: store)
                out.append(Entry(
                    paneID: paneID, tabIndex: tabIndex,
                    title: ident.title,
                    subtitle: ident.placeLine,
                    isAgent: (store.paneAgentStatus[paneID] ?? .none) != .none,
                    isWindow: spec?.kind.isVideo == true,
                    cwd: store.paneCwd(for: paneID),
                ))
            }
        }
        return Self(entries: out)
    }

    public func candidates(query _: String) -> [PaletteItem] {
        entries.map { entry in
            PaletteItem(
                id: "tab.\(entry.paneID.raw.uuidString)",
                icon: entry.isWindow ? "macwindow" : (entry.isAgent ? "asterisk" : "terminal"),
                title: entry.title,
                subtitle: entry.subtitle,
                // Hidden synonyms so "pane"/"jump"/"tab 2" — and the pane's FULL cwd, which the quiet
                // place-line subtitle no longer spells out — surface the row without polluting it.
                keywords: "pane jump go switch tab \(entry.tabIndex + 1) \(entry.cwd ?? "")",
                shortcut: nil,
                filter: .tabs,
                action: .store { store in store.jumpToPaneTree(entry.paneID) },
            )
        }
    }
}

// MARK: - The mixer

/// Combines registered sources into one ordered, sectioned result list (warp-overlays-actions.md §2.2).
/// Pure + `@MainActor`-free for the mix step (the live store reads happen when the snapshot sources are
/// built). Ranks by per-item score, keeps source-registration order for ties, and inserts section
/// separators before each non-empty source group.
public struct SearchMixer: Sendable {
    /// The maximum rows returned — asked for, not transcribed, so no two surfaces can disagree about
    /// where the list stops.
    public static var maxResults: Int { wsMaxSearchResults }

    private let sources: [any PaletteDataSource]

    public init(sources: [any PaletteDataSource]) { self.sources = sources }

    /// Whether `source` runs for `activeFilter` (no filter ⇒ all sources; else only matching sources).
    private func runs(_ source: any PaletteDataSource, for activeFilter: QueryFilter?) -> Bool {
        guard let activeFilter else { return true }
        return source.filters.contains(activeFilter)
    }

    /// Produce the ordered, sectioned result list for `query` under an optional `activeFilter`, with the
    /// fzf title-match ranges attached (``RankedRow``). Within a source, rows that match on the title
    /// outrank rows that match only on the subtitle; inside each tier, higher fzf score wins, ties keep
    /// source-registration order (stable). A separator precedes each source that declares a section title
    /// and contributes ≥1 row. Capped to `maxResults`.
    public func ranked(query: String, activeFilter: QueryFilter? = nil) -> [RankedRow] {
        var out: [RankedRow] = []
        for source in sources where runs(source, for: activeFilter) {
            // Title, then subtitle, then the HIDDEN synonyms — a row's `keywords` (e.g. "Read Only"
            // accepting `lock` / `freeze` / `view only`) are searchable but never rendered, so a
            // synonym hit sits below every visible one. Only the title is underlined, which is why
            // it is the only field whose match positions come back.
            let items = source.candidates(query: query)
            let rows = FuzzyMatcher
                .ranked(query, candidates: items.map { ($0.title, $0.subtitle, $0.keywords) })
                .compactMap { placed -> RankedRow? in
                    guard items.indices.contains(placed.candidate) else { return nil }
                    return RankedRow(item: items[placed.candidate], titleRanges: placed.titleRanges)
                }
            guard !rows.isEmpty else { continue }
            if let title = source.sectionTitle {
                out.append(RankedRow(item: .separator(title, filter: source.filters.first ?? .actions)))
            }
            out.append(contentsOf: rows)
            if out.count >= Self.maxResults { break }
        }
        return Array(out.prefix(Self.maxResults))
    }

    /// The ordered, sectioned result list for `query` (the ``RankedRow`` items without their match ranges).
    public func results(query: String, activeFilter: QueryFilter? = nil) -> [PaletteItem] {
        ranked(query: query, activeFilter: activeFilter).map(\.item)
    }

    /// The selectable (non-separator) rows of a result list — for keyboard ↑/↓ navigation + ⏎ accept.
    public static func selectable(_ items: [PaletteItem]) -> [PaletteItem] {
        items.filter { !$0.isSeparator }
    }
}
