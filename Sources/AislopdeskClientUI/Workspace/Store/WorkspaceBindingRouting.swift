import CoreGraphics
import Foundation

// MARK: - WorkspaceBindingRegistry routing (the action → store-op dispatch)

/// The routing half of the single-source-of-truth registry (docs/42 §W6): dispatches a pure
/// ``WorkspaceAction`` to the matching ``WorkspaceStore`` mutation. The menu bar, the ⌘K palette rows, the
/// hardware-keyboard dispatcher, and the routing tests ALL funnel through this one function — so the chord
/// → action → mutation chain lives in one auditable place (mirroring the canvas ``apply(_:to:)``).
///
/// **Live-model aware.** When ``WorkspaceStore/liveModel`` is ``WorkspaceStore/LiveModel/tree`` (the live
/// IDE shell) every action lands on a TREE op; when it is ``WorkspaceStore/LiveModel/canvas`` (the
/// retained-but-dead path) the tree-only actions fall back to the nearest canvas equivalent via
/// ``apply(_:to:)`` so the canvas tests stay green. The view-layer overlays (command palette / cheat
/// sheet) are not store state, so their toggles are passed in as closures (defaulted `nil`).
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
    ) {
        switch store.liveModel {
        case .tree:
            routeTree(
                action, to: store, togglePalette: togglePalette,
                toggleCheatSheet: toggleCheatSheet, toggleFind: toggleFind,
                togglePeekReply: togglePeekReply,
            )
        case .canvas:
            routeCanvas(
                action, to: store, togglePalette: togglePalette,
                toggleCheatSheet: toggleCheatSheet, toggleFind: toggleFind,
                togglePeekReply: togglePeekReply,
            )
        }
    }

    /// The TREE dispatch (the live path): each action → the matching ``WorkspaceStore`` tree op.
    @MainActor
    private static func routeTree(
        _ action: WorkspaceAction,
        to store: WorkspaceStore,
        togglePalette: (() -> Void)?,
        toggleCheatSheet: (() -> Void)?,
        toggleFind: (() -> Void)?,
        togglePeekReply: (() -> Void)?,
    ) {
        switch action {
        // Panes
        case .splitRight: store.splitActivePaneDefault(axis: .horizontal)
        case .splitDown: store.splitActivePaneDefault(axis: .vertical)
        case .closePane: store.requestCloseActivePaneTree()
        case .renamePane: store.requestRenameActivePane()
        case .breakPaneToTab: store.breakActivePaneToTab()
        // Floating panes (zellij toggle-float / new floating pane)
        case .toggleFloat: store.toggleFloatActivePaneCommand()
        case .spawnFloating: store.spawnFloatingPaneDefault()
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
        // View
        case .toggleZoom: store.toggleZoomActivePane()
        case .commandPalette: togglePalette?()
        case .cheatSheet: toggleCheatSheet?()
        // Find opens the active pane's find bar via the store (so the menu + chord work without threading a
        // view closure); an explicit `toggleFind` override wins when supplied.
        case .find: if let toggleFind { toggleFind() } else { store.requestFindInActivePane() }
        // Copy Mode (P5b): arm modal keyboard scrollback navigation over the active terminal pane.
        case .toggleCopyMode: store.requestCopyModeInActivePane()
        case .toggleSidebar: store.toggleSidebarCollapsed()
        // Blocks (WB2): the navigator toggle + jump-to-block both target the active terminal pane via the store.
        case .commandNavigator: store.requestBlockNavigatorInActivePane()
        case .jumpPreviousBlock: store.jumpToBlockInActivePane(delta: -1)
        case .jumpNextBlock: store.jumpToBlockInActivePane(delta: 1)
        case .reRunLastCommand: store.reRunLastCommandInActivePane()
        // "Previous failed" = toward NEWER blocks (backward over the newest-first list); "next failed" =
        // toward OLDER blocks (forward).
        case .jumpPreviousFailed: store.jumpToFailedBlockInActivePane(forward: false)
        case .jumpNextFailed: store.jumpToFailedBlockInActivePane(forward: true)
        // Tabs
        case .newTab: store.newTabDefault()
        case .nextTab: store.cycleTab(by: 1)
        case .prevTab: store.cycleTab(by: -1)
        case let .selectTab(n): store.selectTabNumber(n)
        case .closeTab: store.closeActiveTab()
        // Sessions
        case .newSession: store.newSessionDefault()
        // Synchronized input (Zellij ToggleActiveSyncTab)
        case .toggleSyncInput:
            if let tabID = store.tree.activeSession?.activeTab?.id { store.toggleSyncInput(tabID: tabID) }
        // Supervision (P3): focus the oldest pane needing attention across all tabs/sessions.
        case .jumpToAttention: store.jumpToOldestAttentionPane()
        // Supervision (P4): open the Peek & Reply overlay (a VIEW @State toggle, like the palette) over the
        // oldest pane needing attention. The toggle closure itself no-ops when nothing needs attention.
        case .peekAndReply: togglePeekReply?()
        }
    }

    /// The CANVAS fallback (retained-but-dead path): the tree-only verbs map to the nearest canvas command
    /// so a `.canvas` store still responds (and the canvas suites stay green). Split → new pane; tabs /
    /// sessions have no canvas analogue and are graceful no-ops there.
    @MainActor
    private static func routeCanvas(
        _ action: WorkspaceAction,
        to store: WorkspaceStore,
        togglePalette: (() -> Void)?,
        toggleCheatSheet: (() -> Void)?,
        toggleFind: (() -> Void)?,
        togglePeekReply: (() -> Void)?,
    ) {
        switch action {
        case .splitRight,
             .splitDown,
             .newTab,
             .newSession:
            apply(.newPaneDefault, to: store)
        case .closePane: apply(.closePane, to: store)
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
        case .toggleZoom: apply(.toggleZoom, to: store)
        case .commandPalette: togglePalette?()
        case .cheatSheet: toggleCheatSheet?()
        case .find: toggleFind?() // canvas path: find is view-overlay only (no tree active-pane store hook)
        // Copy Mode (P5b): the canvas path resolves the active pane via canvas focus, so the same store hook
        // arms copy-mode there too (a no-op for a non-terminal active pane / empty shell).
        case .toggleCopyMode: store.requestCopyModeInActivePane()
        case .toggleSidebar: break // sidebar is tree-shell only
        // Blocks (WB2): the canvas path is retained-but-dead; route through the same store hooks (they
        // resolve the active pane via the canvas focus, so the navigator/jump still work there).
        case .commandNavigator: store.requestBlockNavigatorInActivePane()
        case .jumpPreviousBlock: store.jumpToBlockInActivePane(delta: -1)
        case .jumpNextBlock: store.jumpToBlockInActivePane(delta: 1)
        case .reRunLastCommand: store.reRunLastCommandInActivePane()
        case .jumpPreviousFailed: store.jumpToFailedBlockInActivePane(forward: false)
        case .jumpNextFailed: store.jumpToFailedBlockInActivePane(forward: true)
        case .nextTab,
             .prevTab,
             .selectTab,
             .closeTab: break // no canvas tab model
        case .toggleSyncInput: break // no canvas analogue (tab-scoped, tree-only)
        case .jumpToAttention: break // tree-only (no canvas attention rollup)
        // P4 Peek & Reply is a view overlay; the canvas path still toggles it (the overlay's own selector
        // returns nil under .canvas, where there is no attention rollup, so it opens read-only / no-ops).
        case .peekAndReply: togglePeekReply?()
        }
    }
}
