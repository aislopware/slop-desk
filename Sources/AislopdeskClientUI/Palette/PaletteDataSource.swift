// PaletteDataSource — the per-domain result providers + the SearchMixer that combines them
// (warp-overlays-actions.md §1.2 / §2.2). A `PaletteDataSource` is registered against a set of
// `QueryFilter`s and returns its `PaletteItem`s for a query; the `SearchMixer` runs the registered sources
// in order, keeps a source iff the query has no filter OR a registered filter matches, ranks the union by
// per-item score, and groups them under section separators.
//
// All sources here are SYNCHRONOUS over a store SNAPSHOT (taken on the @MainActor) so the mixing/ranking is
// pure + unit-testable without a view. The ⌘⇧P palette is verbs-only (the ACTIONS catalog grouped by
// category); the multi-source jump-to (panes/recents/folders/agents/files) lives on its OWN E11 surface
// (`OpenQuicklyModel`/`OpenQuicklyView`), so the former `files`/`conversations`/`repos` empty-stub sources
// were removed here (E11 / WI-5) — they were never reachable.

import AislopdeskAgentDetect
import AislopdeskWorkspaceCore
import Foundation
#if canImport(AppKit)
import AppKit // NSPasteboard for the client-side "Copy Path"
#elseif canImport(UIKit)
import UIKit // UIPasteboard for the client-side "Copy Path"
#endif

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
/// `.tree`, per logic-api §7.5 / W6) and records a recent command where the verb is recents-worthy. REAL
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
    public static let catalog: [PaletteItem] = [
        // WORKING DIRECTORY — leads the palette (the section header OWNS the cwd badge in the view). "Copy
        // Path" is a CLIENT-side write of the focused pane's cwd to the platform
        // pasteboard. Sibling "Reveal in Finder" / "Open in…" rows are host-routed —
        // TODO(E10): add them once the host can resolve a local Finder/Open path over the control channel.
        item(
            id: "action.copyPath", icon: "doc.on.doc", title: "Copy Path",
            category: .workingDirectory,
            run: { store in
                guard let session = store.tree.activeSession,
                      let paneID = session.activeTab?.activePane,
                      let cwd = session.specs[paneID]?.lastKnownCwd, !cwd.isEmpty else { return }
                copyToPasteboard(cwd)
            },
        ),
        item(
            id: "action.newTerminalTab", icon: "plus.rectangle", title: "New Tab",
            shortcut: glyph(.newTab), category: .tab,
            run: { store in
                store.newTab(kind: .terminal)
                store.recordRecentCommand(.newPane(.terminal))
            },
        ),
        // L6 / W1: "New Remote Window Tab" opens the Remote-Window picker (the host window list) rather
        // than minting an UNBOUND `.remoteGUI` pane — the pick then opens a pre-bound streaming pane. The
        // overlay coordinator handles `.openRemotePicker` (it records the recent command on open). No
        // registry chord exists for it ⇒ no hint.
        PaletteItem(
            id: "action.newRemoteTab", icon: "rectangle.on.rectangle", title: "New Remote Window Tab",
            shortcut: nil, filter: .actions, category: .tab, action: .openRemotePicker,
        ),
        item(
            id: "action.closeTab", icon: "xmark.rectangle", title: "Close Tab",
            shortcut: glyph(.closeTab), category: .tab,
            run: { store in store.closeActiveTab() },
        ),
        item(
            id: "action.splitRight", icon: "rectangle.split.2x1", title: "Split Pane Right",
            shortcut: glyph(.splitRight), category: .pane,
            run: { store in
                store.splitActivePane(axis: .horizontal, kind: .terminal)
            },
        ),
        item(
            id: "action.splitDown", icon: "rectangle.split.1x2", title: "Split Pane Down",
            shortcut: glyph(.splitDown), category: .pane,
            run: { store in
                store.splitActivePane(axis: .vertical, kind: .terminal)
            },
        ),
        item(
            id: "action.closePane", icon: "xmark.square", title: "Close Pane",
            shortcut: glyph(.closePane), category: .pane,
            run: { store in
                store.requestCloseActivePaneTree()
                store.recordRecentCommand(.closePane)
            },
        ),
        item(
            id: "action.toggleZoom", icon: "arrow.up.left.and.arrow.down.right", title: "Toggle Maximize Pane",
            shortcut: glyph(.toggleZoom), category: .pane,
            run: { store in
                store.toggleZoomActivePane()
                store.recordRecentCommand(.toggleZoom)
            },
        ),
        item(
            id: "action.renamePane", icon: "pencil", title: "Rename Pane",
            shortcut: glyph(.renamePane), category: .pane,
            run: { store in store.requestRenameActivePane() },
        ),
        // No registry chord exists for reconnect (the keyboard bank never registers one) ⇒ no hint chip.
        item(
            id: "action.reconnect", icon: "arrow.clockwise", title: "Reconnect Pane",
            shortcut: nil, category: .pane,
            run: { store in
                if let pane = store.tree.activeSession?.activeTab?.activePane {
                    store.reconnect(pane)
                }
                store.recordRecentCommand(.reconnectPane)
            },
        ),
        // "Toggle Tabs Panel" toggles the LIVE `WorkspaceChromeState.sidebarCollapsed` (the macOS split + the
        // palette ✓ both read it) via a typed action the overlay coordinator routes to the injected chrome
        // closure — NOT the legacy `store.sidebarCollapsed`, which nothing reads on macOS (running it there was
        // a visible no-op AND its ✓ could never flip from the palette). Same live flag the ⌘⇧L chord drives.
        PaletteItem(
            id: "action.toggleSidebar", icon: "sidebar.left", title: "Toggle Tabs Panel",
            subtitle: nil, shortcut: glyph(.toggleSidebar), filter: .actions, category: .view,
            action: .toggleSidebar,
        ),
        // Read Only (E17 ES-E17-1): toggle the active pane's input gate. Under the SHELL section as the
        // first shell verb in the catalog. The spec accepts
        // "read only" plus the synonyms `readonly` / `lock` / `freeze` / `view only` — folded into the row's
        // HIDDEN `keywords` so they search without being rendered. No registry chord is registered for this
        // verb ⇒ the glyph resolves to nil ⇒ no hint chip. Drives the store seam that converges with the pill `×` + menu.
        item(
            id: "action.toggleReadOnly", icon: "lock", title: "Read Only",
            keywords: "readonly lock freeze view only locked viewer input gate protect",
            shortcut: glyph(.toggleReadOnly), category: .shell,
            run: { store in store.toggleReadOnlyInActivePane() },
        ),
        // Secure Keyboard Entry (E17 ES-E17-4): the MANUAL toggle for macOS process-global secure event input
        // over the active pane. Under the SHELL section beside Read Only.
        // No registry chord is registered for this verb ⇒ the glyph resolves to nil ⇒ no hint chip. Drives the store
        // seam that flips the active model's manual flag (→ the pill + the leaf's controller).
        item(
            id: "action.secureKeyboardEntry", icon: "lock.shield", title: "Secure Keyboard Entry",
            keywords: "secure input keyboard entry password sudo protect eavesdrop sniff secure event input",
            shortcut: glyph(.secureKeyboardEntry), category: .shell,
            run: { store in store.toggleSecureKeyboardEntryInActivePane() },
        ),
        // Reopen Closed Pane (⌘⇧T) — pops the tree shell's recently-closed LIFO. A graceful no-op when
        // the LIFO is empty. Glyph derives from the registry's `.reopenClosed` chord (no drift).
        item(
            id: "action.reopenClosed", icon: "arrow.uturn.backward", title: "Reopen Closed Pane",
            keywords: "reopen closed tab pane restore undo recover",
            shortcut: glyph(.reopenClosed), category: .tab,
            run: { store in store.reopenLastClosedPane() },
        ),
        // Sync Input to All Panes (Zellij ToggleActiveSyncTab-style broadcast; ⌘⇧I) — mirror keystrokes to
        // every other pane in the active tab. A graceful no-op when there is no active tab.
        item(
            id: "action.toggleSyncInput", icon: "rectangle.3.group", title: "Sync Input to All Panes",
            keywords: "sync broadcast send all panes input mirror simultaneous",
            shortcut: glyph(.toggleSyncInput), category: .pane,
            run: { store in
                if let tabID = store.tree.activeSession?.activeTab?.id { store.toggleSyncInput(tabID: tabID) }
            },
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
        PaletteItem(
            id: "action.closeWindow", icon: "xmark.square", title: "Close Window",
            subtitle: nil, keywords: "close window quit session", shortcut: glyph(.closeWindow),
            filter: .actions, category: .window, action: .closeWindow,
        ),
        // Font size (⌘= / ⌘- / ⌘0) — rescale the active pane's render font (the cell box resizes, so the
        // remote PTY grid REFLOWS). A graceful no-op off a terminal active pane.
        item(
            id: "action.increaseFontSize", icon: "textformat.size.larger", title: "Increase Font Size",
            keywords: "font size bigger increase larger zoom in text",
            shortcut: glyph(.increaseFontSize), category: .view,
            run: { store in store.increaseFontInActivePane() },
        ),
        item(
            id: "action.decreaseFontSize", icon: "textformat.size.smaller", title: "Decrease Font Size",
            keywords: "font size smaller decrease zoom out text",
            shortcut: glyph(.decreaseFontSize), category: .view,
            run: { store in store.decreaseFontInActivePane() },
        ),
        item(
            id: "action.resetFontSize", icon: "textformat.size", title: "Reset Font Size",
            keywords: "font size reset default actual zoom text",
            shortcut: glyph(.resetFontSize), category: .view,
            run: { store in store.resetFontInActivePane() },
        ),
        // Open Composer (E12; ⌘⇧E) — toggle the active pane's Composer. A graceful no-op off a
        // terminal active pane. Under the AGENTS section.
        item(
            id: "action.openComposer", icon: "square.and.pencil", title: "Open Composer",
            keywords: "composer prompt write agent message draft compose",
            shortcut: glyph(.composer), category: .agents,
            run: { store in store.requestComposerInActivePane() },
        ),
        // Prompt Queue (E12; ⌘⇧M) — open the active pane's composer in prompt-queue
        // input mode. The macOS Agents menu has it; surfacing it here makes it reachable cross-platform (iOS has
        // no Agents menu). A graceful no-op off a terminal active pane. Glyph from the registry (no drift).
        item(
            id: "action.promptQueue", icon: "list.bullet.rectangle.portrait", title: "Prompt Queue",
            keywords: "prompt queue agent messages pending backlog compose",
            shortcut: glyph(.promptQueue), category: .agents,
            run: { store in store.requestPromptQueueInActivePane() },
        ),
        // Send to Chat (E13 ES-E13-5; ⌘⌃↩) — quote the active pane's selection /
        // last command into a chosen Claude-only agent pane. A VIEW overlay (the coordinator captures the quote
        // + presents the scrimmed dialog), so it routes through ``PaletteAction/openSendToChat`` — the SAME ⌘⌃↩
        // surface the menu mirrors. Surfacing it makes the dialog reachable from the palette (cross-platform).
        // It HONESTLY no-ops (toast) when there is nothing to quote, so it is never a dead control.
        PaletteItem(
            id: "action.sendToChat", icon: "arrow.up.message", title: "Send to Chat",
            keywords: "send chat agent selection command share forward message",
            shortcut: glyph(.sendToChat), filter: .actions, category: .agents, action: .openSendToChat,
        ),
        // Fork in Split Right / Down / New Tab (E13 ES-E13-7, spec `agents__fork-branch-session`; CLAUDE-ONLY).
        // PALETTE / MENU ONLY (the registry rows ship `chord: nil`) — the fork is started inside the agent's
        // own `/branch` command, then the user picks a destination here. Each routes through the SAME single
        // ``WorkspaceBindingRegistry/route`` `performFork` path (no duplicated fork logic), which is a graceful
        // no-op when the active pane is not an agent or no `/branch` was detected — so surfacing them is never a
        // dead/destructive control. Surfacing them in the catalog makes the fork reachable cross-platform (iOS
        // has no Agents menu). The glyph derives from the registry (chord: nil ⇒ nil ⇒ no hint chip).
        forkItem(
            id: "action.forkSplitRight",
            icon: "rectangle.split.2x1",
            title: "Fork in Split Right",
            keywords: "fork branch session split right parallel claude /branch new pane",
            action: .forkInSplitRight,
        ),
        forkItem(
            id: "action.forkSplitDown",
            icon: "rectangle.split.1x2",
            title: "Fork in Split Down",
            keywords: "fork branch session split down parallel claude /branch new pane",
            action: .forkInSplitDown,
        ),
        forkItem(
            id: "action.forkNewTab",
            icon: "plus.rectangle.on.rectangle",
            title: "Fork in New Tab",
            keywords: "fork branch session new tab parallel claude /branch open",
            action: .forkInNewTab,
        ),
        // Connect to a (possibly non-default) host — the only entry point to the host/port editor besides
        // the top-bar status pill. No registry chord ⇒ no hint chip.
        PaletteItem(
            id: "action.connect", icon: "network", title: "Connect to Host…",
            subtitle: nil, shortcut: nil, filter: .actions, category: .window, action: .openConnect,
        ),
        // E19 WI-4: Pin Window (float the window above all other apps). A CHECKABLE
        // toggle (ES-E2-3): `OverlayHostView.toggledState(for:)` lights the ✓ gutter when `chrome.pinned`.
        // CHORD-LESS (no registry chord is registered) ⇒ `shortcut: nil` ⇒ no hint chip; routed by the coordinator to the
        // injected `togglePinWindow` closure (the SAME live `chrome.pinned` the View menu + the `NSWindow.level`
        // glue read). macOS-meaningful (iOS has no window level — a documented no-op).
        PaletteItem(
            id: "action.pinWindow", icon: "pin", title: "Pin Window",
            subtitle: nil, shortcut: nil, filter: .actions, category: .window, action: .togglePinWindow,
        ),
        PaletteItem(
            id: "action.openSettings", icon: "slider.horizontal.3", title: "Open Settings",
            subtitle: nil, shortcut: nil, filter: .actions, category: .settings, action: .openSettings,
        ),
        // Theme / config verbs (Batch 4 catalog-completeness) — "Switch Theme", "Reload Config", and
        // "Open Theme File" rows. Theme is LOCAL client state in aislopdesk (``ThemeStore`` /
        // ``PreferencesStore``), so these are pure client actions routed by the coordinator to injected handlers
        // (the SAME live `appearance` Settings → Appearance edits). Chord-less ⇒ no hint chip. Grouped under the
        // SETTINGS section (aislopdesk has no separate Theme palette category).
        PaletteItem(
            id: "action.switchTheme", icon: "paintpalette", title: "Switch Theme",
            subtitle: nil, keywords: "theme switch appearance color scheme dark light monokai paper palette",
            shortcut: nil, filter: .actions, category: .settings, action: .switchTheme,
        ),
        PaletteItem(
            id: "action.reloadConfig", icon: "arrow.clockwise.circle", title: "Reload Config",
            subtitle: nil, keywords: "reload config reapply refresh settings preferences theme apply reload theme",
            shortcut: nil, filter: .actions, category: .settings, action: .reloadConfig,
        ),
        PaletteItem(
            id: "action.openThemeFile", icon: "doc.text", title: "Open Theme File",
            subtitle: nil, keywords: "open theme file reveal finder folder custom aislopdesktheme edit config",
            shortcut: nil, filter: .actions, category: .settings, action: .openThemeFile,
        ),
        // The cheat sheet is also reachable by ⌘/; surfacing it here means the keyboard reference is
        // discoverable without knowing the chord. Its hint derives from the registry (no drift).
        PaletteItem(
            id: "action.cheatSheet", icon: "keyboard", title: "Keyboard Shortcuts",
            subtitle: nil, shortcut: glyph(.cheatSheet), filter: .actions, category: .settings,
            action: .openCheatSheet,
        ),
    ]

    /// The catalog rows in `category`, preserving catalog order — the verbs-only command palette groups by
    /// these (one section header per non-empty category).
    public static func items(in category: PaletteCategory) -> [PaletteItem] {
        catalog.filter { $0.category == category }
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
    /// write. Host-routed Reveal/Open land in E10.
    private static func copyToPasteboard(_ string: String) {
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #elseif canImport(UIKit)
        UIPasteboard.general.string = string
        #endif
    }

    /// The live registry glyph for `action`'s default chord (nil when unbound) — the ONE source the catalog
    /// hints derive from, so the displayed chord can never drift from the keyboard bank.
    private static func glyph(_ action: WorkspaceAction) -> String? {
        WorkspaceBindingRegistry.glyph(for: action)
    }

    /// Build a `.store` action row in a category.
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

    /// Build an AGENTS "Fork in…" row whose `.store` run-arm routes the given fork ``WorkspaceAction`` through
    /// the central ``WorkspaceBindingRegistry/route`` (the SINGLE `performFork` path — no duplicated fork
    /// logic). A graceful no-op when the active pane has no detected `/branch`. The glyph derives from the
    /// registry (chord: nil ⇒ no hint chip). CLAUDE-ONLY.
    private static func forkItem(
        id: String, icon: String, title: String, keywords: String, action: WorkspaceAction,
    ) -> PaletteItem {
        PaletteItem(
            id: id, icon: icon, title: title, keywords: keywords, shortcut: glyph(action),
            filter: .actions, category: .agents,
            action: .store { store in WorkspaceBindingRegistry.route(action, to: store) },
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

// MARK: - TABS source (jump to a pane/tab) — REAL

/// Jump-to-tab/pane source (warp-overlays-actions.md §2.2 navigation). One row per visible pane of the
/// active session's tabs (the same enumeration the rail uses); selecting it focuses that pane. REAL.
public struct TabsPaletteSource: PaletteDataSource {
    public let filters: Set<QueryFilter> = [.tabs]
    public let sectionTitle: String? = "Tabs"

    /// A snapshot row (the store read is done when the snapshot is built).
    public struct Entry: Sendable {
        public let paneID: PaneID
        public let tabIndex: Int
        public let title: String
        public let subtitle: String?
        public let isAgent: Bool
    }

    private let entries: [Entry]

    public init(entries: [Entry]) { self.entries = entries }

    /// Build a snapshot from the live store (active session's tabs → one entry per visible pane).
    @preconcurrency
    @MainActor
    public static func snapshot(_ store: WorkspaceStore) -> Self {
        guard let session = store.tree.activeSession else { return Self(entries: []) }
        var out: [Entry] = []
        for (tabIndex, tab) in session.tabs.enumerated() {
            // E21 ES-E21-2/-4: enumerate the FULL pane set (`tab.allPaneIDs()` = tree + floating layer) so a
            // floated pane (incl. a floated `.remoteGUI` remote window) stays in the ⌘K jump-to-pane palette —
            // matching OpenQuickly. `tab.root.allPaneIDs()` alone drops the float layer.
            for paneID in tab.allPaneIDs() {
                let spec = session.specs[paneID]
                let title = spec?.lastKnownTitle ?? spec?.title ?? "Terminal"
                let subtitle = spec?.lastKnownCwd
                let isAgent = (store.paneAgentStatus[paneID] ?? .none) != .none
                out.append(Entry(
                    paneID: paneID, tabIndex: tabIndex,
                    title: title.isEmpty ? "Terminal" : title, subtitle: subtitle, isAgent: isAgent,
                ))
            }
        }
        return Self(entries: out)
    }

    public func candidates(query _: String) -> [PaletteItem] {
        entries.map { entry in
            PaletteItem(
                id: "tab.\(entry.paneID.raw.uuidString)",
                icon: entry.isAgent ? "asterisk" : "terminal",
                title: entry.title,
                subtitle: entry.subtitle,
                shortcut: nil,
                filter: .tabs,
                action: .store { store in store.focusPaneTree(entry.paneID) },
            )
        }
    }
}

// MARK: - SNIPPETS source (run a saved snippet by name) — REAL

/// The saved-snippet source (E16 WI-7) — one row per persisted ``Snippet``; selecting it runs the snippet
/// into the focused (or broadcast) pane via ``WorkspaceStore/beginRunSnippet(_:)`` (which arms the value-entry
/// sheet for a parameterized snippet, or injects immediately for a plain one). Surfaced under the verbs-only
/// ⌘⇧P palette's `.actions` filter with a "Snippets" section header, so saved snippets are searchable and
/// runnable by name directly from the command palette. SNAPSHOT-based (like ``TabsPaletteSource``) — the live store read
/// happens when the snapshot is built on the @MainActor at palette-open, so the mix/rank stay pure + testable.
public struct SnippetPaletteSource: PaletteDataSource {
    public let filters: Set<QueryFilter> = [.actions]
    public let sectionTitle: String? = "Snippets"

    /// A snapshot snippet row (id + display name + alias) captured from the store.
    public struct Entry: Sendable {
        public let id: UUID
        public let name: String
        public let alias: String

        public init(id: UUID, name: String, alias: String) {
            self.id = id
            self.name = name
            self.alias = alias
        }
    }

    private let entries: [Entry]

    public init(entries: [Entry]) { self.entries = entries }

    /// Build a snapshot from the live store's persisted snippets (display-name normalized so a blank name
    /// never renders an empty "Run …" row).
    @preconcurrency
    @MainActor
    public static func snapshot(_ store: WorkspaceStore) -> Self {
        Self(entries: store.snippets.map {
            Entry(id: $0.id, name: WorkspaceStore.snippetName($0.name), alias: $0.alias)
        })
    }

    public func candidates(query _: String) -> [PaletteItem] {
        entries.map { entry in
            PaletteItem(
                id: "snippet.\(entry.id.uuidString)",
                icon: "doc.plaintext",
                title: entry.name,
                // The alias rides BOTH the rendered subtitle (so the row reads "name / alias") and the hidden
                // keywords, so typing the alias surfaces the snippet too (the same trigger word the at-prompt
                // expansion uses). nil when the snippet has no alias.
                subtitle: entry.alias.isEmpty ? nil : entry.alias,
                keywords: entry.alias.isEmpty ? nil : entry.alias,
                shortcut: nil,
                filter: .actions,
                action: .store { store in _ = store.beginRunSnippet(entry.id) },
            )
        }
    }
}

// MARK: - RECIPES source (save / open a recipe, + run a saved one by name) — REAL

/// The recipe source (E16 ES-E16-1/2/3 / M1) — surfaces a THIRD recipe entry point: the
/// command palette (alongside Settings ▸ Recipes + the File ▸ Recipe menu). Two FIXED verb rows — "Save
/// Recipe…" arms ``WorkspaceStore/requestSaveRecipe()`` and "Open Recipe…" arms
/// ``WorkspaceStore/requestOpenRecipe()`` — plus one row per saved `.aislopdeskrecipe` ("Open Recipe: <name>",
/// opening it via ``WorkspaceStore/openRecipe(at:source:launchGrace:)`` with ``RecipeSource/savedLibrary``).
/// Because the palette is the ONLY cross-platform recipe surface, these rows ALSO make Save / Open Recipe
/// reachable on iOS (no menu bar, no ⌘S). SNAPSHOT-based (like ``SnippetPaletteSource``) — the saved-file scan
/// happens when the snapshot is built on the @MainActor at palette-open, so the mix / rank stay pure + testable.
public struct RecipePaletteSource: PaletteDataSource {
    public let filters: Set<QueryFilter> = [.actions]
    public let sectionTitle: String? = "Recipes"

    /// A snapshot saved-recipe row (its on-disk URL + the resolved display name).
    public struct Entry: Sendable {
        public let url: URL
        public let name: String

        public init(url: URL, name: String) {
            self.url = url
            self.name = name
        }
    }

    private let entries: [Entry]

    public init(entries: [Entry]) { self.entries = entries }

    /// Build a snapshot from the store's saved library files (display-name normalized the SAME way the
    /// Open-Recipe picker does — the recipe's name, else the filename). A malformed file (`recipe == nil`) is
    /// skipped: it is greyed / non-runnable in the picker, so it carries no palette row here either.
    @preconcurrency
    @MainActor
    public static func snapshot(_ store: WorkspaceStore) -> Self {
        Self(entries: store.savedRecipeFiles().compactMap { file in
            guard let recipe = file.recipe else { return nil }
            let trimmed = recipe.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = trimmed.isEmpty ? file.url.deletingPathExtension().lastPathComponent : trimmed
            return Entry(url: file.url, name: name)
        })
    }

    public func candidates(query _: String) -> [PaletteItem] {
        var rows: [PaletteItem] = [
            PaletteItem(
                id: "recipe.save", icon: "square.and.arrow.down", title: "Save Recipe…",
                keywords: "recipe save layout window tab snapshot export aislopdeskrecipe",
                shortcut: nil, filter: .actions,
                action: .store { store in store.requestSaveRecipe() },
            ),
            PaletteItem(
                id: "recipe.open", icon: "square.and.arrow.up", title: "Open Recipe…",
                keywords: "recipe open restore import layout aislopdeskrecipe",
                shortcut: nil, filter: .actions,
                action: .store { store in store.requestOpenRecipe() },
            ),
        ]
        // One row per saved `.aislopdeskrecipe` — opens it by URL from the library (`.savedLibrary` follows the
        // Saved-Recipes Command-Replay default). The id is path-namespaced so two recipes never collide.
        rows += entries.map { entry in
            PaletteItem(
                id: "recipe.saved.\(entry.url.path)",
                icon: "doc.text",
                title: "Open Recipe: \(entry.name)",
                keywords: "recipe \(entry.name)",
                shortcut: nil,
                filter: .actions,
                action: .store { store in store.openRecipe(at: entry.url, source: .savedLibrary) },
            )
        }
        return rows
    }
}

// MARK: - The mixer

/// Combines registered sources into one ordered, sectioned result list (warp-overlays-actions.md §2.2).
/// Pure + `@MainActor`-free for the mix step (the live store reads happen when the snapshot sources are
/// built). Ranks by per-item score, keeps source-registration order for ties, and inserts section
/// separators before each non-empty source group.
public struct SearchMixer: Sendable {
    /// The maximum rows returned (warp `MAX_SEARCH_RESULTS = 250`).
    public static let maxResults = 250

    private let sources: [any PaletteDataSource]

    public init(sources: [any PaletteDataSource]) { self.sources = sources }

    /// All filters any registered source answers (drives the zero-state chips, registration order).
    public var availableFilters: [QueryFilter] {
        var seen = Set<QueryFilter>()
        var out: [QueryFilter] = []
        for source in sources {
            for f in QueryFilter.allCases where source.filters.contains(f) && !seen.contains(f) {
                seen.insert(f)
                out.append(f)
            }
        }
        return out
    }

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
            // (row, score, tier, sourceOffset) — tier 1 = title match, tier 0 = subtitle-only match, tier -1
            // = hidden-keyword (synonym) match. A higher tier always outranks a lower one (see the sort).
            let scored: [(row: RankedRow, score: Int, tier: Int, offset: Int)] = source
                .candidates(query: query)
                .enumerated()
                .compactMap { offset, item in
                    if let title = FuzzyMatcher.score(query, item.title) {
                        return (RankedRow(item: item, titleRanges: title.ranges), title.score, 1, offset)
                    }
                    if let subtitle = item.subtitle, let sub = FuzzyMatcher.score(query, subtitle) {
                        return (RankedRow(item: item), sub.score, 0, offset)
                    }
                    // HIDDEN synonyms (E17): a row's `keywords` (e.g. "Read Only" accepting `lock` / `freeze`
                    // / `view only`) are searchable but never rendered, so a keyword hit sits at tier -1 —
                    // below every title (1) and subtitle (0) hit — and carries NO title highlight ranges.
                    if let keywords = item.keywords, let kw = FuzzyMatcher.score(query, keywords) {
                        return (RankedRow(item: item), kw.score, -1, offset)
                    }
                    return nil
                }
            let rows = scored.sorted { lhs, rhs in
                if lhs.tier != rhs.tier { return lhs.tier > rhs.tier } // title beats subtitle-only
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.offset < rhs.offset // stable: keep source order for equal scores
            }.map(\.row)
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
