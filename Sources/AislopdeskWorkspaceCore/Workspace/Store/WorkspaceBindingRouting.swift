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
    var sidebar: (() -> Void)?
    /// Toggles the RIGHT remote-windows column (TabSide partition) — `WorkspaceChromeState.guiCollapsed`
    /// view chrome, so it is a passed-in closure exactly like `sidebar`; `nil` (headless / test / iOS) is
    /// a graceful no-op, never a dead chord.
    var windowsPanel: (() -> Void)?
    var globalSearch: (() -> Void)?
    /// Toggles the Jump-To affordance (E10 WI-8, ⌘J). A VIEW overlay, so — like `globalSearch` — it is a
    /// passed-in closure; `nil` (the headless / test default) is a graceful no-op, never a dead chord. E11
    /// (WI-5/WI-7) folded Jump-To into the Open-Quickly picker: the app now re-points this to "open
    /// Open-Quickly at `.current`" (`OverlayCoordinator.toggleOpenQuickly(filter: .current)`), but the routing
    /// keeps it the distinct `.jumpTo`-action toggle (separate from `openQuickly` below).
    var jumpTo: (() -> Void)?
    /// Toggles the Open-Quickly picker at the merged `.all` pill (E11 WI-7, ⌘⇧O). A VIEW overlay (the
    /// `OverlayCoordinator` owns `openQuicklyVisible`/`openQuicklyFilter`), so — like `jumpTo` — it is a
    /// passed-in closure; `nil` (the headless / test default) is a graceful no-op, never a dead chord. Only
    /// ⌘⇧O (this) and ⌘J (`jumpTo`, → `.current`) are GLOBAL; the pill / ⌘1–9 / Tab / ⌘K chords are
    /// PICKER-LOCAL (handled by `OpenQuicklyView.onKeyPress`, never registered here).
    var openQuickly: (() -> Void)?
    /// Toggles "Pin Window" (E19 WI-3, View ▸ Pin Window). A macOS `NSWindow.level` / window-level
    /// concern, so — like `sidebar` — it is a passed-in closure (the live app flips
    /// `WorkspaceChromeState.pinned`); `nil` (the headless / test / iOS default) is a graceful no-op, never a
    /// dead chord.
    var pinWindow: (() -> Void)?
    /// Actuates a real window close (⌘⇧W / View ▸ Close Window, E3 WI-4 audit fix). A macOS
    /// `NSWindow.performClose(_:)` concern — so, like `pinWindow`, it is a passed-in closure; the live app
    /// wires it to `window.performClose(nil)`, which fires the native `windowShouldClose` → the existing
    /// `WindowCloseGate` confirmation (preserving the configured ``CloseConfirmationPolicy``). `nil` (the
    /// headless / test default) falls back to ``WorkspaceStore/requestCloseWindow()`` so the action still
    /// parks the confirmation rather than trapping — never a dead chord. (The bare-park path alone had no
    /// SwiftUI observer, so ⌘⇧W never actually closed the window — the regression this routes around.)
    var closeWindow: (() -> Void)?
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
        toggleSidebar: (() -> Void)? = nil,
        toggleWindowsPanel: (() -> Void)? = nil,
        toggleGlobalSearch: (() -> Void)? = nil,
        toggleJumpTo: (() -> Void)? = nil,
        openQuickly: (() -> Void)? = nil,
        togglePinWindow: (() -> Void)? = nil,
        closeWindow: (() -> Void)? = nil,
    ) {
        let toggles = RouteToggles(
            palette: togglePalette, cheatSheet: toggleCheatSheet, find: toggleFind,
            peekReply: togglePeekReply,
            sidebar: toggleSidebar, windowsPanel: toggleWindowsPanel,
            globalSearch: toggleGlobalSearch, jumpTo: toggleJumpTo,
            openQuickly: openQuickly, pinWindow: togglePinWindow,
            closeWindow: closeWindow,
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
        // vertical one). The new pane is focused — a left/up split leaves the new pane focused, same as right/down.
        case .splitLeft:
            store.openChooserPane(.split(axis: .horizontal, leading: true))
        case .splitUp:
            store.openChooserPane(.split(axis: .vertical, leading: true))
        case .closePane: store.requestCloseActivePaneTree()
        case .renamePane: store.requestRenameActivePane()
        case .breakPaneToTab: store.breakActivePaneToTab()
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
        // keyboard cheat sheet — ONE binding, contextual behaviour, no new chord, no conflict.
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
        // Jump-To (E10 WI-8 / ES-E10-5): a VIEW overlay (the OverlayCoordinator owns it) that scans the ACTIVE
        // pane, so it is a passed-in closure like the palette / global search. `nil` (the headless / test
        // default) is a graceful no-op — never a dead chord.
        case .jumpTo: toggles.jumpTo?()
        // Hint Mode (E10 WI-9 / ES-E10-6): arm 2-letter Vimium hints over the ACTIVE terminal pane's viewport
        // for the chosen intent (open / copy / reveal). The mode lives on the pane's `TerminalViewModel`
        // (`beginHint(_:)`) so the renderer's key capture + the overlay read ONE source; a no-op for a
        // non-terminal active pane, an empty shell, a headless surface, or an alt-screen TUI (don't fight it).
        // After arming, NUDGE first-responder to the terminal (`onRequestFocus`) so Escape reaches the
        // renderer's `keyDown` → `cancelHintMode()` — otherwise, if focus was elsewhere (sidebar / settings)
        // when the chord fired, Escape never routes to the surface and the badge can't be dismissed (C4).
        case .hintToOpen:
            store.activeTerminalModel?.beginHint(.open)
            store.activeTerminalModel?.onRequestFocus?()
        case .hintToCopy:
            store.activeTerminalModel?.beginHint(.copy)
            store.activeTerminalModel?.onRequestFocus?()
        case .hintToReveal:
            store.activeTerminalModel?.beginHint(.reveal)
            store.activeTerminalModel?.onRequestFocus?()
        // Copy Mode (P5b): arm modal keyboard scrollback navigation over the active terminal pane. As with hint
        // mode, focus the terminal after arming so Escape reaches `keyDown` → `exitCopyMode()` (C5).
        case .toggleCopyMode:
            store.requestCopyModeInActivePane()
            store.activeTerminalModel?.onRequestFocus?()
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
        // Release Stuck Input (C5): fire the active remote-GUI pane's synthetic-release escape hatch (all
        // modifiers up + all buttons up). A graceful no-op for a terminal / empty / read-only active pane.
        case .releaseStuckInput: store.releaseStuckInputInActivePane()
        // Paste as Keystrokes (C7, ⌥⌘V): type the CURRENT local clipboard into the active remote-GUI pane's
        // host window (paced per-key CGEvents). A graceful no-op for a terminal / empty / read-only pane, or
        // when the local clipboard is empty. The store reads the live clipboard via `currentLocalClipboard()`.
        case .pasteAsKeystrokes: store.pasteAsKeystrokesInActivePane()
        // Toggle Tabs Panel (⌘⇧L): the LEFT sidebar collapse on the macOS shell is VIEW @State
        // (`WorkspaceChromeState.sidebarCollapsed`, read by the native split controller) — NOT the legacy
        // `store.sidebarCollapsed`, which nothing reads on macOS. So it is a passed-in closure.
        // When no closure is supplied (the headless / test / iOS default) fall back to
        // the store flag so the action is a non-trapping graceful op (and any store-flag reader still toggles).
        case .toggleSidebar:
            if let s = toggles.sidebar { s() } else { store.toggleSidebarCollapsed() }
        // Toggle Windows Panel (⌘⇧E): the RIGHT remote-windows column collapse is VIEW @State
        // (`WorkspaceChromeState.guiCollapsed`, read by the native split controller) — a passed-in closure
        // like `.toggleSidebar`; `nil` (headless / test / iOS) is a graceful no-op, never a dead chord.
        case .toggleWindowsPanel: toggles.windowsPanel?()
        // Pin Window (E19 ES-E19-1 / WI-3): float the window above all other apps. A macOS NSWindow.level
        // concern (VIEW @State `WorkspaceChromeState.pinned`), so it is a passed-in closure like
        // `.toggleSidebar`; `nil` (the headless / test / iOS default) is a graceful
        // no-op — never a dead chord.
        case .pinWindow: toggles.pinWindow?()
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
        // Open Quickly (E1-registered, E11 WI-7): ⌘⇧O opens the fuzzy multi-source switcher at the merged
        // `.all` pill. A VIEW overlay (the `OverlayCoordinator` owns the picker), so it is a passed-in closure
        // like `.globalSearch` / `.jumpTo`; the app binds it to `overlay.toggleOpenQuickly(filter: .all)`. The
        // pill / ⌘1–9 / Tab / ⌘K chords stay PICKER-LOCAL (handled in the panel, never routed here). `nil`
        // (the headless / test default) is a graceful no-op — never a dead chord.
        case .openQuickly: toggles.openQuickly?()
        // Control Room (big-swing B): flip the store's overview flag — the compositor renders the
        // Exposé grid, the dispatcher owns Esc/typing while it is up. A pure store toggle (no view
        // closure needed), so it works headlessly.
        case .controlRoom: store.toggleControlRoom()
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
        // Close Window (⌘⇧W / View ▸ Close Window, E7 carry-over #5; E3 WI-4 audit fix): a window maps to
        // a ``Session``. ACTUATE the close through the passed-in closure — the live app wires it to
        // `window.performClose(nil)`, which fires the native `windowShouldClose` → the existing
        // ``WindowCloseGate`` confirmation (preserving the configured ``CloseConfirmationPolicy``). When NO
        // closure is supplied (headless / test / iOS) fall back to ``WorkspaceStore/requestCloseWindow()`` so
        // the action still PARKS the confirmation (the prior behaviour), never a dead chord. The audit found
        // the bare-park path had no SwiftUI observer — under the default `.process` policy with an idle shell it
        // parked `nil` and nothing closed — so ⌘⇧W was a dead control until this closure made it actuate.
        case .closeWindow:
            if let close = toggles.closeWindow { close() } else { store.requestCloseWindow() }
        // Reopen the most recently closed TAB (E1 ES-E1-5 chord; E3 WI-3 behaviour): pops the tree shell's
        // in-memory ``WorkspaceStore/recentlyClosedTabs`` LIFO and re-inserts the tab. A graceful no-op when
        // the LIFO is empty — live, never dead.
        case .reopenClosed: store.reopenLastClosedPane()
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
             .newTab:
            apply(.newPaneDefault, to: store)
        case .closePane: apply(.closePane, to: store)
        // Reopen the last closed pane: the canvas has its own retained single-slot reopen (distinct from the
        // tree shell's E3 LIFO) — route to it so the canvas path still responds.
        case .reopenClosed: apply(.reopenClosedPane, to: store)
        case .renamePane: apply(.renamePane, to: store)
        case .breakPaneToTab: break // no canvas analogue
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
        // Jump-To (E10 WI-8): a view overlay; the canvas path still toggles it via the closure (a graceful
        // no-op when none is supplied, like the palette / global search).
        case .jumpTo: toggles.jumpTo?()
        // Hint Mode (E10 WI-9): the canvas path resolves the active pane via canvas focus, so the same model
        // seam arms hints there too (a no-op for a non-terminal active pane / empty shell / alt-screen TUI).
        // Focus the terminal after arming so Escape reaches `keyDown` → `cancelHintMode()` (C4) — same fix as tree.
        case .hintToOpen:
            store.activeTerminalModel?.beginHint(.open)
            store.activeTerminalModel?.onRequestFocus?()
        case .hintToCopy:
            store.activeTerminalModel?.beginHint(.copy)
            store.activeTerminalModel?.onRequestFocus?()
        case .hintToReveal:
            store.activeTerminalModel?.beginHint(.reveal)
            store.activeTerminalModel?.onRequestFocus?()
        // Copy Mode (P5b): the canvas path resolves the active pane via canvas focus, so the same store hook
        // arms copy-mode there too (a no-op for a non-terminal active pane / empty shell). Focus the terminal
        // after arming so Escape reaches `keyDown` → `exitCopyMode()` (C5).
        case .toggleCopyMode:
            store.requestCopyModeInActivePane()
            store.activeTerminalModel?.onRequestFocus?()
        // Vi Mode Key Hints (E17 ES-E17-2 / WI-5): the canvas path uses the SAME store seam as the tree path to
        // toggle the active pane's vi key-hint bar (a no-op for a non-terminal / empty active pane).
        case .toggleViKeyHints: store.toggleViKeyHintsInActivePane()
        // Read-Only (E17 ES-E17-1): the canvas path resolves the active pane via canvas focus, so the same
        // store seam toggles the input gate there too (a no-op for a non-terminal active pane / empty shell).
        case .toggleReadOnly: store.toggleReadOnlyInActivePane()
        // Secure Keyboard Entry (E17 ES-E17-4): the canvas path resolves the active pane via canvas focus, so
        // the same store seam toggles manual secure input there too (a no-op for a non-terminal / empty shell).
        case .secureKeyboardEntry: store.toggleSecureKeyboardEntryInActivePane()
        // Release Stuck Input (C5): the same store seam fires the active remote-GUI pane's synthetic-release
        // escape hatch on the canvas path too (a no-op for a non-video / empty / read-only active pane).
        case .releaseStuckInput: store.releaseStuckInputInActivePane()
        // Paste as Keystrokes (C7): the same store seam types the local clipboard into the active remote-GUI
        // pane on the canvas path too (a no-op for a non-video / empty / read-only pane or empty clipboard).
        case .pasteAsKeystrokes: store.pasteAsKeystrokesInActivePane()
        // Sidebar is the tree-shell chrome; the canvas path still toggles it via the closure (the live macOS
        // app wires `chrome.toggleSidebar`). `nil` (the canvas test default) is a graceful no-op.
        case .toggleSidebar: toggles.sidebar?()
        // Windows panel is tree-shell chrome; the canvas path forwards the same closure (graceful no-op).
        case .toggleWindowsPanel: toggles.windowsPanel?()
        // Pin Window is a window-level concern (the live macOS app flips `WorkspaceChromeState.pinned`); the
        // canvas path forwards it via the closure too — a graceful no-op when none is supplied, never a dead chord.
        case .pinWindow: toggles.pinWindow?()
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
        // Open Quickly is a view overlay (the tree-shell picker); the canvas path still toggles it via the
        // closure (a graceful no-op when none is supplied, like the palette / global search / jump-to).
        case .openQuickly: toggles.openQuickly?()
        // Control Room overviews the TREE compositor's mounted tabs; the retained-but-dead canvas has no
        // tab layers to overview, so the flag still flips (harmless) but nothing renders it.
        case .controlRoom: store.toggleControlRoom()
        case .nextTab,
             .prevTab,
             .selectTab,
             .closeTab: break // no canvas tab model (the tree shell owns sessions)
        // Close Window (E3 WI-4 audit fix): a window-level `NSWindow.performClose` concern (not a model op),
        // so the canvas path forwards the SAME actuator closure as the tree path — a graceful no-op when none
        // is supplied (the canvas test default), never a dead chord.
        case .closeWindow: toggles.closeWindow?()
        case .toggleSyncInput: break // no canvas analogue (tab-scoped, tree-only)
        case .jumpToAttention: break // tree-only (no canvas attention rollup)
        // P4 Peek & Reply is a view overlay; the canvas path still toggles it (the overlay's own selector
        // returns nil under .canvas, where there is no attention rollup, so it opens read-only / no-ops).
        case .peekAndReply: toggles.peekReply?()
        }
    }
}
