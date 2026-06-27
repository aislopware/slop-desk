import CoreGraphics
import Foundation

// MARK: - WorkspaceBindingRegistry routing (the action → store-op dispatch)

/// The routing half of the single-source-of-truth registry (docs/42 §W6): dispatches a pure
/// ``WorkspaceAction`` to the matching ``WorkspaceStore`` mutation. The menu bar, the ⌘⇧P palette rows, the
/// hardware-keyboard dispatcher, and the routing tests ALL funnel through this one function — so the chord
/// → action → mutation chain lives in one auditable place (mirroring the canvas ``apply(_:to:)``).
///
/// **Live-model aware.** When ``WorkspaceStore/liveModel`` is ``WorkspaceStore/LiveModel/tree`` (the live
/// IDE shell) every action lands on a TREE op; when it is ``WorkspaceStore/LiveModel/canvas`` (the
/// retained-but-dead path) the tree-only actions fall back to the nearest canvas equivalent via
/// ``apply(_:to:)`` so the canvas tests stay green. The view-layer overlays (command palette / cheat
/// sheet) are not store state, so their toggles are passed in as closures (defaulted `nil`).

/// Bundles the view-owned overlay-toggle closures passed to ``WorkspaceBindingRegistry/route(_:to:)``.
/// Keeping them in one value lets the private dispatch helpers stay within SwiftLint's parameter-count limit.
struct RouteToggles {
    var palette: (() -> Void)?
    var cheatSheet: (() -> Void)?
    var find: (() -> Void)?
    var peekReply: (() -> Void)?
    var detailsPanel: (() -> Void)?
    var sidebar: (() -> Void)?
    var globalSearch: (() -> Void)?
    /// Jumps the Details panel to a specific tab (E9/WI-7). View-owned state (`DetailsPanelState` + the
    /// chrome reveal), so — like `detailsPanel` — it is a passed-in closure; `nil` = a graceful no-op.
    var selectDetailsTab: ((DetailsPanelTab) -> Void)?
}

public extension WorkspaceBindingRegistry {
    /// Routes `action` to its store op against `store`. The overlay toggles (`togglePalette` /
    /// `toggleCheatSheet`) are the view-owned `@State` switches the root view passes; `nil` (the test /
    /// headless default) makes those two actions a no-op.
    @MainActor
    static func route(
        _ action: WorkspaceAction,
        to store: WorkspaceStore,
        togglePalette: (() -> Void)? = nil,
        toggleCheatSheet: (() -> Void)? = nil,
        toggleFind: (() -> Void)? = nil,
        togglePeekReply: (() -> Void)? = nil,
        toggleDetailsPanel: (() -> Void)? = nil,
        toggleSidebar: (() -> Void)? = nil,
        toggleGlobalSearch: (() -> Void)? = nil,
        selectDetailsTab: ((DetailsPanelTab) -> Void)? = nil,
    ) {
        let toggles = RouteToggles(
            palette: togglePalette, cheatSheet: toggleCheatSheet, find: toggleFind,
            peekReply: togglePeekReply, detailsPanel: toggleDetailsPanel,
            sidebar: toggleSidebar, globalSearch: toggleGlobalSearch,
            selectDetailsTab: selectDetailsTab,
        )
        switch store.liveModel {
        case .tree: routeTree(action, to: store, toggles: toggles)
        case .canvas: routeCanvas(action, to: store, toggles: toggles)
        }
    }

    /// The TREE dispatch (the live path): each action → the matching ``WorkspaceStore`` tree op.
    @MainActor
    private static func routeTree(
        _ action: WorkspaceAction,
        to store: WorkspaceStore,
        toggles: RouteToggles,
    ) {
        switch action {
        // Panes
        // A split MINTS a new pane → create an in-pane CHOOSER pane (Terminal / Remote window), focused, so
        // the user picks the kind INSIDE the new pane (no modal). `openChooserPane(.split(axis:))` splits the
        // active pane into a `.chooser` leaf; `choosePaneKind` later flips it to the real kind in place.
        case .splitRight:
            store.openChooserPane(.split(axis: .horizontal))
        case .splitDown:
            store.openChooserPane(.split(axis: .vertical))
        // Split-left / split-up (E1 ES-E1-1): same chooser-split as right/down, but `leading: true` inserts
        // the new `.chooser` leaf on the LEADING side of the active pane (left of a horizontal split / above a
        // vertical one). The new pane is focused, matching otty's "new pane is left/up and focused".
        case .splitLeft:
            store.openChooserPane(.split(axis: .horizontal, leading: true))
        case .splitUp:
            store.openChooserPane(.split(axis: .vertical, leading: true))
        case .closePane: store.requestCloseActivePaneTree()
        case .renamePane: store.requestRenameActivePane()
        case .breakPaneToTab: store.breakActivePaneToTab()
        // Floating panes (zellij toggle-float / new floating pane). Spawning a NEW floating pane mints a
        // pane → route through the chooser (`.floating` context) when a host is supplied; `nil` keeps the
        // direct default-kind spawn. `.toggleFloat` only floats/un-floats the EXISTING active pane (mints
        // nothing), so it never gates.
        case .toggleFloat: store.toggleFloatActivePaneCommand()
        case .spawnFloating:
            store.openChooserPane(.floating)
        // Move pane (swap with the geometric neighbour, against the reported layout)
        case .movePaneLeft: store.swapActivePaneInDirection(.left)
        case .movePaneRight: store.swapActivePaneInDirection(.right)
        case .movePaneUp: store.swapActivePaneInDirection(.up)
        case .movePaneDown: store.swapActivePaneInDirection(.down)
        // Resize pane (keyboard divider nudge — structural, no geometry)
        case .resizePaneLeft: store.resizeActivePane(.left)
        case .resizePaneRight: store.resizeActivePane(.right)
        case .resizePaneUp: store.resizeActivePane(.up)
        case .resizePaneDown: store.resizeActivePane(.down)
        // Balance (tmux even-layout)
        case .balancePanes: store.balanceActivePaneSplits()
        // Layouts (tmux/zellij select-layout): cycle steps the presets, a named preset re-tiles directly.
        case .cycleLayout: store.cycleLayout()
        case let .applyLayout(preset): store.applyLayout(preset)
        // Focus
        case .focusLeft: store.moveFocusTreeUsingReportedLayout(.left)
        case .focusRight: store.moveFocusTreeUsingReportedLayout(.right)
        case .focusUp: store.moveFocusTreeUsingReportedLayout(.up)
        case .focusDown: store.moveFocusTreeUsingReportedLayout(.down)
        // Sequential pane cycle (E1 ES-E1-2): step focus through the active tab's panes in DFS order (wraps).
        case .cyclePaneNext: store.cyclePaneFocusTree(forward: true)
        case .cyclePanePrev: store.cyclePaneFocusTree(forward: false)
        // View
        case .toggleZoom: store.toggleZoomActivePane()
        case .commandPalette: toggles.palette?()
        // Cheat sheet / vi key hints (E17 ES-E17-2 / WI-5): `⌘/` is CONTEXTUAL. While the active pane is in
        // vi / copy-mode, `⌘/` toggles that pane's vi KEY-HINT BAR (the reference card) instead of the global
        // keyboard cheat sheet — ONE binding, contextual behaviour (otty parity), no new chord, no conflict.
        // Out of copy-mode it falls through to the view-owned cheat-sheet toggle (the existing behaviour).
        case .cheatSheet:
            if store.activeTerminalModel?.isCopyMode == true {
                store.toggleViKeyHintsInActivePane()
            } else {
                toggles.cheatSheet?()
            }
        // Find opens the active pane's find bar via the store (so the menu + chord work without threading a
        // view closure); an explicit `toggleFind` override wins when supplied.
        case .find: if let f = toggles.find { f() } else { store.requestFindInActivePane() }
        // Find Next / Previous (E5 ES-E5-3): advance/retreat the active pane's find match. The store opens the
        // bar (via `onRequestFind`) when it is closed — so ⌘G works as "find next opens find". Always a store
        // path (no view closure): the bar's match nav is owned by the per-pane TerminalViewModel callback.
        case .findNext: store.requestFindNextInActivePane()
        case .findPrev: store.requestFindPrevInActivePane()
        // Global Search (E5 ES-E5-5): a VIEW overlay surface (the OverlayCoordinator owns it), so it is a
        // passed-in closure like the palette / cheat sheet. `nil` (the headless / test default) is a graceful
        // no-op — never a dead chord.
        case .globalSearch: toggles.globalSearch?()
        // Copy Mode (P5b): arm modal keyboard scrollback navigation over the active terminal pane.
        case .toggleCopyMode: store.requestCopyModeInActivePane()
        // Vi Mode Key Hints (E17 ES-E17-2 / WI-5): the DISCOVERABLE palette / menu command toggles the active
        // pane's vi key-hint bar directly (the same seam the contextual `⌘/` fires). A graceful no-op for an
        // empty / non-terminal pane; outside vi mode the bar stays gated off.
        case .toggleViKeyHints: store.toggleViKeyHintsInActivePane()
        // Read-Only (E17 ES-E17-1): toggle the active pane's input gate via the store (so the pill ×, the
        // View-menu item, and the command-palette term all converge on the one `paneReadOnly` source of
        // truth). A graceful no-op for an empty / non-terminal shell.
        case .toggleReadOnly: store.toggleReadOnlyInActivePane()
        // Secure Keyboard Entry (E17 ES-E17-4): toggle MANUAL macOS secure event input over the active pane
        // (the auto path engages on a host no-echo prompt without an action). A graceful no-op for an empty /
        // non-terminal shell; the macOS leaf's `SecureKeyboardEntryController` actuates the process-global API.
        case .secureKeyboardEntry: store.toggleSecureKeyboardEntryInActivePane()
        // Toggle Tabs Panel (otty ⌘⇧L): the LEFT sidebar collapse on the macOS shell is VIEW @State
        // (`WorkspaceChromeState.sidebarCollapsed`, read by the native split controller) — NOT the legacy
        // `store.sidebarCollapsed`, which nothing reads on macOS. So it is a passed-in closure (like
        // `.toggleDetailsPanel`). When no closure is supplied (the headless / test / iOS default) fall back to
        // the store flag so the action is a non-trapping graceful op (and any store-flag reader still toggles).
        case .toggleSidebar:
            if let s = toggles.sidebar { s() } else { store.toggleSidebarCollapsed() }
        // Toggle Details Panel (otty ⌘⇧R): the right-hand inspector is VIEW @State (`WorkspaceChromeState`),
        // not store state, so it is a passed-in closure (like the palette / cheat-sheet toggles). `nil` (the
        // headless / test default) keeps it a graceful no-op — never a dead chord.
        case .toggleDetailsPanel: toggles.detailsPanel?()
        // Details tab jump (E9/WI-7, ES-E9-5): switch the right-hand Details panel to a specific tab AND
        // reveal it if hidden. View-owned state (`DetailsPanelState` + `WorkspaceChromeState`), so it is a
        // passed-in closure like `.toggleDetailsPanel`; `nil` (the headless / test default) is a graceful
        // no-op — never a dead chord.
        case let .selectDetailsTab(tab): toggles.selectDetailsTab?(tab)
        // Blocks (WB2): the navigator toggle + jump-to-block both target the active terminal pane via the store.
        case .commandNavigator: store.requestBlockNavigatorInActivePane()
        case .jumpPreviousBlock: store.jumpToBlockInActivePane(delta: -1)
        case .jumpNextBlock: store.jumpToBlockInActivePane(delta: 1)
        case .reRunLastCommand: store.reRunLastCommandInActivePane()
        // "Previous failed" = toward NEWER blocks (backward over the newest-first list); "next failed" =
        // toward OLDER blocks (forward).
        case .jumpPreviousFailed: store.jumpToFailedBlockInActivePane(forward: false)
        case .jumpNextFailed: store.jumpToFailedBlockInActivePane(forward: true)
        // E1 viewport scroll (ES-E1-3): ⇧PageUp/Down page-scroll, ⇧Home/End jump to buffer ends — through the
        // active pane's `TerminalSurfaceActions` seam (the WorkspaceStore+FontScroll hooks). No-op off-terminal.
        case .scrollPageUp: store.scrollActivePane(.pageUp)
        case .scrollPageDown: store.scrollActivePane(.pageDown)
        case .scrollToTop: store.scrollActivePane(.top)
        case .scrollToBottom: store.scrollActivePane(.bottom)
        // E1 command jumps (ES-E1-3): ⌘PageUp/Down REUSE the OSC-133 command-jump (prev/next prompt), NOT scroll.
        case .commandJumpPrev: store.jumpToBlockInActivePane(delta: -1)
        case .commandJumpNext: store.jumpToBlockInActivePane(delta: 1)
        // E1 font size (ES-E1-4): ⌘=/⌘-/⌘0 rescale the active pane's render font — the cell box resizes, so the
        // remote PTY grid REFLOWS (SIGWINCH); not grid-preserving. No-op off-terminal.
        case .increaseFontSize: store.increaseFontInActivePane()
        case .decreaseFontSize: store.decreaseFontInActivePane()
        case .resetFontSize: store.resetFontInActivePane()
        // Open Quickly (E1-registered, E11 behaviour): a routable no-op stub until E11 wires the fuzzy switcher
        // overlay — registered so the chord is live, never dead. E11 threads its overlay toggle through `route`.
        case .openQuickly: break
        // Tabs
        // `.newTab` is the generic new-pane entry (the `+` button / a future generic chord): it creates an
        // in-pane `.chooser` pane (Terminal / Remote window), focused. ⌘T stays a direct-terminal escape hatch
        // via `.newPane(.terminal)` on the canvas command path — it never opens the chooser.
        case .newTab:
            store.openChooserPane(.newTab)
        case .nextTab: store.cycleTab(by: 1)
        case .prevTab: store.cycleTab(by: -1)
        case let .selectTab(n): store.selectTabNumber(n)
        case .closeTab: store.closeActiveTab()
        // Close Window (otty ⌘⇧W, E7 carry-over #5): a window maps to a ``Session`` — request the window close,
        // which parks `pendingWindowClose` behind the `closeConfirmWindow` policy. The macOS
        // `WindowCloseConfirmationDelegate` (NSAlert) resolves the park; on iOS the in-app surface does.
        case .closeWindow: store.requestCloseWindow()
        // Reopen the most recently closed TAB (E1 ES-E1-5 chord; E3 WI-3 behaviour): pops the tree shell's
        // in-memory ``WorkspaceStore/recentlyClosedTabs`` LIFO and re-inserts the tab. A graceful no-op when
        // the LIFO is empty — live, never dead.
        case .reopenClosed: store.reopenLastClosedPane()
        // Sessions — a new session carries one fresh leaf, so it mints a pane → create it as an in-pane
        // `.chooser` pane (the user picks the kind inside the new session's pane).
        case .newSession:
            store.openChooserPane(.newSession)
        // Synchronized input (Zellij ToggleActiveSyncTab)
        case .toggleSyncInput:
            if let tabID = store.tree.activeSession?.activeTab?.id { store.toggleSyncInput(tabID: tabID) }
        // Supervision (P3): focus the oldest pane needing attention across all tabs/sessions.
        case .jumpToAttention: store.jumpToOldestAttentionPane()
        // Supervision (P4): open the Peek & Reply overlay (a VIEW @State toggle, like the palette) over the
        // oldest pane needing attention. The toggle closure itself no-ops when nothing needs attention. When
        // no overlay closure is supplied (the keyboard bank, until the Peek & Reply overlay lands), the chord
        // must not be DEAD — fall back to focusing the oldest attention pane (mirrors the `.find` fallback to
        // `requestFindInActivePane()`), so ⌘⇧J does something useful rather than nothing.
        case .peekAndReply:
            if let p = toggles.peekReply { p() } else { store.jumpToOldestAttentionPane() }
        // Agents (E12 Composer / Prompt Queue): route to the active-pane composer ops — ⌘⇧E toggles the
        // Composer, ⌘⇧M opens it in Prompt-Queue input mode (both a graceful no-op off-terminal). `.sendToChat`
        // STAYS a routable no-op stub — its behaviour lands in E13 (agent send-to-chat), not E12 (ES-E1-5
        // keeps the chord LIVE, never dead).
        case .composer: store.requestComposerInActivePane()
        case .promptQueue: store.requestPromptQueueInActivePane()
        case .sendToChat: break
        }
    }

    /// The CANVAS fallback (retained-but-dead path): the tree-only verbs map to the nearest canvas command
    /// so a `.canvas` store still responds (and the canvas suites stay green). Split → new pane; tabs /
    /// sessions have no canvas analogue and are graceful no-ops there.
    @MainActor
    private static func routeCanvas(
        _ action: WorkspaceAction,
        to store: WorkspaceStore,
        toggles: RouteToggles,
    ) {
        switch action {
        case .splitRight,
             .splitDown,
             .splitLeft, // canvas has no split tree; a split mints a new pane (the canvas analogue)
             .splitUp,
             .newTab,
             .newSession:
            apply(.newPaneDefault, to: store)
        case .closePane: apply(.closePane, to: store)
        // Reopen the last closed pane: the canvas has its own retained single-slot reopen (distinct from the
        // tree shell's E3 LIFO) — route to it so the canvas path still responds.
        case .reopenClosed: apply(.reopenClosedPane, to: store)
        case .renamePane: apply(.renamePane, to: store)
        case .breakPaneToTab: break // no canvas analogue
        case .toggleFloat,
             .spawnFloating:
            break // floating overlay is tree-shell only
        // Tree-only pane management (move / resize / balance) — the flat canvas has no split tree to act on.
        case .movePaneLeft,
             .movePaneRight,
             .movePaneUp,
             .movePaneDown,
             .resizePaneLeft,
             .resizePaneRight,
             .resizePaneUp,
             .resizePaneDown,
             .balancePanes,
             .cycleLayout,
             .applyLayout:
            break // no canvas analogue (tiled-split only)
        case .focusLeft: apply(.focus(.left), to: store)
        case .focusRight: apply(.focus(.right), to: store)
        case .focusUp: apply(.focus(.up), to: store)
        case .focusDown: apply(.focus(.down), to: store)
        // Sequential pane cycle on the canvas maps to its existing whole-canvas focus cycle (⌘]/⌘[ analogue).
        case .cyclePaneNext: apply(.cycleFocus(forward: true), to: store)
        case .cyclePanePrev: apply(.cycleFocus(forward: false), to: store)
        case .toggleZoom: apply(.toggleZoom, to: store)
        case .commandPalette: toggles.palette?()
        // Cheat sheet / vi key hints (E17 ES-E17-2 / WI-5): same CONTEXTUAL `⌘/` as the tree path — while the
        // canvas-focused pane is in vi / copy-mode (which the canvas path also arms via `.toggleCopyMode`), the
        // chord toggles that pane's vi key-hint bar; otherwise it forwards to the view-owned cheat-sheet toggle.
        case .cheatSheet:
            if store.activeTerminalModel?.isCopyMode == true {
                store.toggleViKeyHintsInActivePane()
            } else {
                toggles.cheatSheet?()
            }
        case .find: toggles.find?() // canvas path: find is view-overlay only (no tree active-pane store hook)
        // Find Next / Previous: the canvas path resolves the active pane via canvas focus, so the same store
        // hooks open + advance the find bar there too (a graceful no-op for a non-terminal / empty canvas).
        case .findNext: store.requestFindNextInActivePane()
        case .findPrev: store.requestFindPrevInActivePane()
        // Global Search is a view overlay (tree-shell chrome); the canvas path still toggles it via the closure.
        case .globalSearch: toggles.globalSearch?()
        // Copy Mode (P5b): the canvas path resolves the active pane via canvas focus, so the same store hook
        // arms copy-mode there too (a no-op for a non-terminal active pane / empty shell).
        case .toggleCopyMode: store.requestCopyModeInActivePane()
        // Vi Mode Key Hints (E17 ES-E17-2 / WI-5): the canvas path uses the SAME store seam as the tree path to
        // toggle the active pane's vi key-hint bar (a no-op for a non-terminal / empty active pane).
        case .toggleViKeyHints: store.toggleViKeyHintsInActivePane()
        // Read-Only (E17 ES-E17-1): the canvas path resolves the active pane via canvas focus, so the same
        // store seam toggles the input gate there too (a no-op for a non-terminal active pane / empty shell).
        case .toggleReadOnly: store.toggleReadOnlyInActivePane()
        // Secure Keyboard Entry (E17 ES-E17-4): the canvas path resolves the active pane via canvas focus, so
        // the same store seam toggles manual secure input there too (a no-op for a non-terminal / empty shell).
        case .secureKeyboardEntry: store.toggleSecureKeyboardEntryInActivePane()
        // Sidebar is the tree-shell chrome; the canvas path still toggles it via the closure (the live macOS
        // app wires `chrome.toggleSidebar`). `nil` (the canvas test default) is a graceful no-op.
        case .toggleSidebar: toggles.sidebar?()
        // Details panel is a view overlay (tree-shell chrome); the canvas path still toggles it via the closure.
        case .toggleDetailsPanel: toggles.detailsPanel?()
        // Details tab jump: a view overlay (tree-shell chrome); the canvas path still forwards it via the closure.
        case let .selectDetailsTab(tab): toggles.selectDetailsTab?(tab)
        // Blocks (WB2): the canvas path is retained-but-dead; route through the same store hooks (they
        // resolve the active pane via the canvas focus, so the navigator/jump still work there).
        case .commandNavigator: store.requestBlockNavigatorInActivePane()
        case .jumpPreviousBlock: store.jumpToBlockInActivePane(delta: -1)
        case .jumpNextBlock: store.jumpToBlockInActivePane(delta: 1)
        case .reRunLastCommand: store.reRunLastCommandInActivePane()
        case .jumpPreviousFailed: store.jumpToFailedBlockInActivePane(forward: false)
        case .jumpNextFailed: store.jumpToFailedBlockInActivePane(forward: true)
        // E1 scroll / font / command-jump: route through the SAME active-pane store hooks (they resolve the
        // active pane via the canvas focus, so they no-op gracefully for a non-terminal / empty canvas).
        case .scrollPageUp: store.scrollActivePane(.pageUp)
        case .scrollPageDown: store.scrollActivePane(.pageDown)
        case .scrollToTop: store.scrollActivePane(.top)
        case .scrollToBottom: store.scrollActivePane(.bottom)
        case .commandJumpPrev: store.jumpToBlockInActivePane(delta: -1)
        case .commandJumpNext: store.jumpToBlockInActivePane(delta: 1)
        case .increaseFontSize: store.increaseFontInActivePane()
        case .decreaseFontSize: store.decreaseFontInActivePane()
        case .resetFontSize: store.resetFontInActivePane()
        case .openQuickly: break // E11 overlay — no canvas analogue
        case .nextTab,
             .prevTab,
             .selectTab,
             .closeTab,
             .closeWindow: break // no canvas tab/window model (the tree shell owns sessions)
        case .toggleSyncInput: break // no canvas analogue (tab-scoped, tree-only)
        case .jumpToAttention: break // tree-only (no canvas attention rollup)
        // P4 Peek & Reply is a view overlay; the canvas path still toggles it (the overlay's own selector
        // returns nil under .canvas, where there is no attention rollup, so it opens read-only / no-ops).
        case .peekAndReply: toggles.peekReply?()
        // Agents (E12 Composer / Prompt Queue): the canvas path resolves the active pane via canvas focus,
        // so the same store ops toggle/open the composer there too (a graceful no-op for a non-terminal /
        // empty canvas). `.sendToChat` STAYS inert — its behaviour lands in E13.
        case .composer: store.requestComposerInActivePane()
        case .promptQueue: store.requestPromptQueueInActivePane()
        case .sendToChat: break
        }
    }
}
