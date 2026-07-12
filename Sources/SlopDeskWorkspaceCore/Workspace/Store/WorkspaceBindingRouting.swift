import CoreGraphics
import Foundation

// MARK: - WorkspaceBindingRegistry routing (the action → store-op dispatch)

/// The routing half of the single-source-of-truth registry (docs/42 §W6): dispatches a pure
/// ``WorkspaceAction`` to the matching ``WorkspaceStore`` mutation. Menu bar, ⌘⇧P palette, hardware-keyboard
/// dispatcher, and routing tests ALL funnel through here — the chord → action → mutation chain in one
/// auditable place (mirroring the canvas ``apply(_:to:)``).
///
/// **Live-model aware.** ``WorkspaceStore/LiveModel/tree`` (live IDE shell) → every action lands on a TREE
/// op; ``WorkspaceStore/LiveModel/canvas`` (retained-but-dead) → tree-only actions fall back to the nearest
/// canvas equivalent via ``apply(_:to:)`` so the canvas tests stay green. View-layer overlays (palette /
/// cheat sheet) are not store state, so their toggles are passed in as closures (defaulted `nil`).

/// Bundles the view-owned overlay-toggle closures passed to ``WorkspaceBindingRegistry/route(_:to:)``.
/// One value keeps the private dispatch helpers within SwiftLint's parameter-count limit.
struct RouteToggles {
    var palette: (() -> Void)?
    var cheatSheet: (() -> Void)?
    var find: (() -> Void)?
    var peekReply: (() -> Void)?
    var sidebar: (() -> Void)?
    /// Toggles the Host Windows rail (docs/45, ⌘⇧R). A chrome-flag concern like `sidebar` (the live
    /// app flips `WorkspaceChromeState.hostRailCollapsed`); `nil` (headless / test / iOS default) is
    /// a graceful no-op, never a dead chord.
    var hostWindows: (() -> Void)?
    var globalSearch: (() -> Void)?
    /// Toggles the Jump-To affordance (⌘J). A VIEW overlay (like `globalSearch`), passed in as a
    /// closure; `nil` (headless / test default) is a graceful no-op, never a dead chord. Jump-To
    /// folds into the Open-Quickly picker: the app re-points this to
    /// `OverlayCoordinator.toggleOpenQuickly(filter: .current)`, but routing keeps it the distinct
    /// `.jumpTo`-action toggle (separate from `openQuickly` below).
    var jumpTo: (() -> Void)?
    /// Toggles the Open-Quickly picker at the merged `.all` pill (⌘⇧O). A VIEW overlay (the
    /// `OverlayCoordinator` owns `openQuicklyVisible`/`openQuicklyFilter`), passed in as a closure (like
    /// `jumpTo`); `nil` (headless / test default) is a graceful no-op, never a dead chord. Only ⌘⇧O (this)
    /// and ⌘J (`jumpTo`, → `.current`) are GLOBAL; the pill / ⌘1–9 / Tab / ⌘K chords are PICKER-LOCAL
    /// (handled by `OpenQuicklyView.onKeyPress`, never registered here).
    var openQuickly: (() -> Void)?
    /// Toggles "Pin Window" (View ▸ Pin Window). A macOS `NSWindow.level` concern, passed in as a
    /// closure (like `sidebar`; the live app flips `WorkspaceChromeState.pinned`); `nil` (headless / test /
    /// iOS default) is a graceful no-op, never a dead chord.
    var pinWindow: (() -> Void)?
    /// Actuates a real window close (⌘⇧W / View ▸ Close Window). A macOS `NSWindow.performClose(_:)`
    /// concern, passed in as a closure (like `pinWindow`); the live app wires it to `window.performClose(nil)`,
    /// firing the native `windowShouldClose` → the existing `WindowCloseGate` confirmation (preserving the
    /// configured ``CloseConfirmationPolicy``). `nil` (headless / test default) falls back to
    /// ``WorkspaceStore/requestCloseWindow()`` — parks the confirmation rather than trapping, never a dead
    /// chord. A bare park has no SwiftUI observer on it, so without this closure ⌘⇧W would silently fail to
    /// close the window.
    var closeWindow: (() -> Void)?
}

public extension WorkspaceBindingRegistry {
    /// Routes `action` to its store op against `store`. The overlay toggles (`togglePalette` /
    /// `toggleCheatSheet`) are the view-owned `@State` switches the root view passes; `nil` (test / headless
    /// default) makes those actions a no-op.
    @MainActor
    static func route(
        _ action: WorkspaceAction,
        to store: WorkspaceStore,
        togglePalette: (() -> Void)? = nil,
        toggleCheatSheet: (() -> Void)? = nil,
        toggleFind: (() -> Void)? = nil,
        togglePeekReply: (() -> Void)? = nil,
        toggleSidebar: (() -> Void)? = nil,
        toggleHostWindows: (() -> Void)? = nil,
        toggleGlobalSearch: (() -> Void)? = nil,
        toggleJumpTo: (() -> Void)? = nil,
        openQuickly: (() -> Void)? = nil,
        togglePinWindow: (() -> Void)? = nil,
        closeWindow: (() -> Void)? = nil,
    ) {
        let toggles = RouteToggles(
            palette: togglePalette, cheatSheet: toggleCheatSheet, find: toggleFind,
            peekReply: togglePeekReply,
            sidebar: toggleSidebar, hostWindows: toggleHostWindows,
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
        // A split MINTS a new pane → an in-pane CHOOSER pane (Terminal / Remote window), focused: the user
        // picks the kind INSIDE the pane (no modal). `openChooserPane(.split(axis:))` splits the active pane
        // into a `.chooser` leaf; `choosePaneKind` later flips it to the real kind in place.
        case .splitRight:
            store.openChooserPane(.split(axis: .horizontal))
        case .splitDown:
            store.openChooserPane(.split(axis: .vertical))
        // Split-left / split-up: same chooser-split as right/down, but `leading: true` inserts
        // the new `.chooser` leaf on the LEADING side of the active pane (left of a horizontal split / above a
        // vertical one). The new pane is focused, same as right/down.
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
        // Sequential pane cycle: step focus through the active tab's panes in DFS order (wraps).
        case .cyclePaneNext: store.cyclePaneFocusTree(forward: true)
        case .cyclePanePrev: store.cyclePaneFocusTree(forward: false)
        // View
        case .toggleZoom: store.toggleZoomActivePane()
        case .commandPalette: toggles.palette?()
        // Cheat sheet / vi key hints: `⌘/` is CONTEXTUAL. In vi / copy-mode it toggles
        // the pane's vi KEY-HINT BAR (reference card) instead of the global cheat sheet — ONE binding, no new
        // chord, no conflict. Out of copy-mode it falls through to the view-owned cheat-sheet toggle.
        case .cheatSheet:
            if store.activeTerminalModel?.isCopyMode == true {
                store.toggleViKeyHintsInActivePane()
            } else {
                toggles.cheatSheet?()
            }
        // Find opens the active pane's find bar via the store (so the menu + chord work without threading a
        // view closure); an explicit `toggleFind` override wins when supplied.
        case .find: if let f = toggles.find { f() } else { store.requestFindInActivePane() }
        // Find Next / Previous: advance/retreat the active pane's find match. The store opens the
        // bar (via `onRequestFind`) when closed — so ⌘G means "find next opens find". Always a store path (no
        // view closure): match nav is owned by the per-pane TerminalViewModel callback.
        case .findNext: store.requestFindNextInActivePane()
        case .findPrev: store.requestFindPrevInActivePane()
        // Global Search: a VIEW overlay (OverlayCoordinator owns it), passed in as a closure like
        // the palette. `nil` (headless / test default) is a graceful no-op, never a dead chord.
        case .globalSearch: toggles.globalSearch?()
        // Jump-To: a VIEW overlay (OverlayCoordinator owns it) that scans the ACTIVE
        // pane, passed in as a closure. `nil` (headless / test default) is a graceful no-op, never a dead chord.
        case .jumpTo: toggles.jumpTo?()
        // Hint Mode: arm 2-letter Vimium hints over the ACTIVE terminal pane's viewport
        // for the chosen intent (open / copy / reveal). The mode lives on the pane's `TerminalViewModel`
        // (`beginHint(_:)`) so key capture + overlay read ONE source; a no-op for a non-terminal / empty /
        // headless / alt-screen pane. After arming, NUDGE first-responder to the terminal (`onRequestFocus`)
        // so Escape reaches `keyDown` → `cancelHintMode()` — else, if focus was elsewhere when the chord
        // fired, Escape never routes to the surface and the badge can't be dismissed.
        case .hintToOpen:
            store.activeTerminalModel?.beginHint(.open)
            store.activeTerminalModel?.onRequestFocus?()
        case .hintToCopy:
            store.activeTerminalModel?.beginHint(.copy)
            store.activeTerminalModel?.onRequestFocus?()
        case .hintToReveal:
            store.activeTerminalModel?.beginHint(.reveal)
            store.activeTerminalModel?.onRequestFocus?()
        // Copy Mode: arm modal keyboard scrollback navigation over the active terminal pane. As with hint
        // mode, focus the terminal after arming so Escape reaches `keyDown` → `exitCopyMode()`.
        case .toggleCopyMode:
            store.requestCopyModeInActivePane()
            store.activeTerminalModel?.onRequestFocus?()
        // Vi Mode Key Hints: the discoverable palette / menu command toggles the active
        // pane's vi key-hint bar directly (the same seam the contextual `⌘/` fires). A no-op for an empty /
        // non-terminal pane; outside vi mode the bar stays gated off.
        case .toggleViKeyHints: store.toggleViKeyHintsInActivePane()
        // Read-Only: toggle the active pane's input gate via the store (so the pill ×, the
        // View-menu item, and the palette term all converge on the one `paneReadOnly` source of truth). A
        // no-op for an empty / non-terminal shell.
        case .toggleReadOnly: store.toggleReadOnlyInActivePane()
        // Secure Keyboard Entry: toggle MANUAL macOS secure event input over the active pane
        // (the auto path engages on a host no-echo prompt without an action). A no-op for an empty /
        // non-terminal shell; the macOS leaf's `SecureKeyboardEntryController` actuates the process-global API.
        case .secureKeyboardEntry: store.toggleSecureKeyboardEntryInActivePane()
        // Release Stuck Input: fire the active remote-GUI pane's synthetic-release escape hatch (all
        // modifiers up + all buttons up). A graceful no-op for a terminal / empty / read-only active pane.
        case .releaseStuckInput: store.releaseStuckInputInActivePane()
        // Paste as Keystrokes (⌥⌘V): type the CURRENT local clipboard into the active remote-GUI pane's
        // host window (paced per-key CGEvents). A graceful no-op for a terminal / empty / read-only pane, or
        // when the local clipboard is empty. The store reads the live clipboard via `currentLocalClipboard()`.
        case .pasteAsKeystrokes: store.pasteAsKeystrokesInActivePane()
        // Toggle Tabs Panel (⌘⇧L): the LEFT sidebar collapse on the macOS shell is VIEW @State
        // (`WorkspaceChromeState.sidebarCollapsed`, read by the native split controller) — NOT the legacy
        // `store.sidebarCollapsed`, which nothing reads on macOS. So it is a passed-in closure; when none is
        // supplied (headless / test / iOS) fall back to the store flag — a non-trapping graceful op (and any
        // store-flag reader still toggles).
        case .toggleSidebar:
            if let s = toggles.sidebar { s() } else { store.toggleSidebarCollapsed() }
        // Toggle Host Windows (⌘⇧R, docs/45): the RIGHT rail collapse is VIEW @State
        // (`WorkspaceChromeState.hostRailCollapsed`, read by the native split controller) — a passed-in
        // closure like `.toggleSidebar`; `nil` (headless / test / iOS default) is a graceful no-op.
        case .toggleHostWindows: toggles.hostWindows?()
        // Pin Window: float the window above all other apps. A macOS NSWindow.level
        // concern (VIEW @State `WorkspaceChromeState.pinned`), passed in as a closure like `.toggleSidebar`;
        // `nil` (headless / test / iOS default) is a graceful no-op, never a dead chord.
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
        // Viewport scroll: ⇧PageUp/Down page-scroll, ⇧Home/End jump to buffer ends — through the
        // active pane's `TerminalSurfaceActions` seam (the WorkspaceStore+FontScroll hooks). No-op off-terminal.
        case .scrollPageUp: store.scrollActivePane(.pageUp)
        case .scrollPageDown: store.scrollActivePane(.pageDown)
        case .scrollToTop: store.scrollActivePane(.top)
        case .scrollToBottom: store.scrollActivePane(.bottom)
        // Command jumps: ⌘PageUp/Down REUSE the OSC-133 command-jump (prev/next prompt), NOT scroll.
        case .commandJumpPrev: store.jumpToBlockInActivePane(delta: -1)
        case .commandJumpNext: store.jumpToBlockInActivePane(delta: 1)
        // Font size: ⌘=/⌘-/⌘0 rescale the active pane's render font — the cell box resizes, so the
        // remote PTY grid REFLOWS (SIGWINCH); not grid-preserving. No-op off-terminal.
        case .increaseFontSize: store.increaseFontInActivePane()
        case .decreaseFontSize: store.decreaseFontInActivePane()
        case .resetFontSize: store.resetFontInActivePane()
        // Open Quickly: ⌘⇧O opens the fuzzy multi-source switcher at the merged
        // `.all` pill. A VIEW overlay (`OverlayCoordinator` owns the picker), passed in as a closure; the app
        // binds it to `overlay.toggleOpenQuickly(filter: .all)`. The pill / ⌘1–9 / Tab / ⌘K chords stay
        // PICKER-LOCAL (handled in the panel, never routed here). `nil` (headless / test default) is a
        // graceful no-op, never a dead chord.
        case .openQuickly: toggles.openQuickly?()
        // Tabs
        // `.newTab` is the generic new-pane entry (the `+` button / a future generic chord): creates a
        // focused in-pane `.chooser` pane (Terminal / Remote window). ⌘T stays a direct-terminal escape hatch
        // via `.newPane(.terminal)` on the canvas command path — it never opens the chooser.
        case .newTab:
            store.openChooserPane(.newTab)
        case .nextTab: store.cycleTab(by: 1)
        case .prevTab: store.cycleTab(by: -1)
        case let .selectTab(n): store.selectTabNumber(n)
        case .closeTab: store.closeActiveTab()
        // Close Window (⌘⇧W / View ▸ Close Window): a window maps to a ``Session``. ACTUATE the close
        // through the passed-in closure — the live app wires it to `window.performClose(nil)`, firing the
        // native `windowShouldClose` → the existing ``WindowCloseGate`` confirmation (preserving the
        // configured ``CloseConfirmationPolicy``). When NO closure is supplied (headless / test / iOS) fall
        // back to ``WorkspaceStore/requestCloseWindow()`` — still PARKS the confirmation, never a dead chord.
        // A bare park has no SwiftUI observer on it — under the default `.process` policy with an idle shell
        // it parks `nil` and nothing closes — so without this closure ⌘⇧W would be a dead control.
        case .closeWindow:
            if let close = toggles.closeWindow { close() } else { store.requestCloseWindow() }
        // Reopen the most recently closed TAB: pops the tree shell's
        // in-memory ``WorkspaceStore/recentlyClosedTabs`` LIFO and re-inserts the tab. A no-op when the LIFO
        // is empty — live, never dead.
        case .reopenClosed: store.reopenLastClosedPane()
        // Synchronized input (Zellij ToggleActiveSyncTab)
        case .toggleSyncInput:
            if let tabID = store.tree.activeSession?.activeTab?.id { store.toggleSyncInput(tabID: tabID) }
        // Supervision: focus the oldest pane needing attention across all tabs/sessions.
        case .jumpToAttention: store.jumpToOldestAttentionPane()
        // Supervision: open the Peek & Reply overlay (a VIEW @State toggle, like the palette) over the
        // oldest pane needing attention. The toggle closure no-ops when nothing needs attention. When no
        // overlay closure is supplied, the chord must not be DEAD — fall back to focusing the oldest attention
        // pane (mirrors the `.find` fallback to `requestFindInActivePane()`), so ⌘⇧J does something useful.
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
        // tree shell's LIFO stack) — route to it so the canvas path still responds.
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
        // Cheat sheet / vi key hints: same CONTEXTUAL `⌘/` as the tree path — in vi /
        // copy-mode (the canvas also arms it via `.toggleCopyMode`) the chord toggles the pane's vi key-hint
        // bar; otherwise it forwards to the view-owned cheat-sheet toggle.
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
        // Jump-To: a view overlay; the canvas path still toggles it via the closure (a graceful
        // no-op when none is supplied, like the palette / global search).
        case .jumpTo: toggles.jumpTo?()
        // Hint Mode: the canvas path resolves the active pane via canvas focus, so the same model
        // seam arms hints there too (a no-op for a non-terminal active pane / empty shell / alt-screen TUI).
        // Focus the terminal after arming so Escape reaches `keyDown` → `cancelHintMode()` — same fix as tree.
        case .hintToOpen:
            store.activeTerminalModel?.beginHint(.open)
            store.activeTerminalModel?.onRequestFocus?()
        case .hintToCopy:
            store.activeTerminalModel?.beginHint(.copy)
            store.activeTerminalModel?.onRequestFocus?()
        case .hintToReveal:
            store.activeTerminalModel?.beginHint(.reveal)
            store.activeTerminalModel?.onRequestFocus?()
        // Copy Mode: the canvas path resolves the active pane via canvas focus, so the same store hook
        // arms copy-mode there too (a no-op for a non-terminal active pane / empty shell). Focus the terminal
        // after arming so Escape reaches `keyDown` → `exitCopyMode()`.
        case .toggleCopyMode:
            store.requestCopyModeInActivePane()
            store.activeTerminalModel?.onRequestFocus?()
        // Vi Mode Key Hints: the canvas path uses the SAME store seam as the tree path to
        // toggle the active pane's vi key-hint bar (a no-op for a non-terminal / empty active pane).
        case .toggleViKeyHints: store.toggleViKeyHintsInActivePane()
        // Read-Only: the canvas path resolves the active pane via canvas focus, so the same
        // store seam toggles the input gate there too (a no-op for a non-terminal active pane / empty shell).
        case .toggleReadOnly: store.toggleReadOnlyInActivePane()
        // Secure Keyboard Entry: the canvas path resolves the active pane via canvas focus, so
        // the same store seam toggles manual secure input there too (a no-op for a non-terminal / empty shell).
        case .secureKeyboardEntry: store.toggleSecureKeyboardEntryInActivePane()
        // Release Stuck Input: the same store seam fires the active remote-GUI pane's synthetic-release
        // escape hatch on the canvas path too (a no-op for a non-video / empty / read-only active pane).
        case .releaseStuckInput: store.releaseStuckInputInActivePane()
        // Paste as Keystrokes: the same store seam types the local clipboard into the active remote-GUI
        // pane on the canvas path too (a no-op for a non-video / empty / read-only pane or empty clipboard).
        case .pasteAsKeystrokes: store.pasteAsKeystrokesInActivePane()
        // Sidebar is the tree-shell chrome; the canvas path still toggles it via the closure (the live macOS
        // app wires `chrome.toggleSidebar`). `nil` (the canvas test default) is a graceful no-op.
        case .toggleSidebar: toggles.sidebar?()
        // The Host Windows rail is tree-shell chrome too; the canvas path forwards the closure the same way.
        case .toggleHostWindows: toggles.hostWindows?()
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
        // Scroll / font / command-jump: route through the SAME active-pane store hooks (they resolve the
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
        case .nextTab,
             .prevTab,
             .selectTab,
             .closeTab: break // no canvas tab model (the tree shell owns sessions)
        // Close Window: a window-level `NSWindow.performClose` concern (not a model op),
        // so the canvas path forwards the SAME actuator closure as the tree path — a graceful no-op when none
        // is supplied (the canvas test default), never a dead chord.
        case .closeWindow: toggles.closeWindow?()
        case .toggleSyncInput: break // no canvas analogue (tab-scoped, tree-only)
        case .jumpToAttention: break // tree-only (no canvas attention rollup)
        // Peek & Reply is a view overlay; the canvas path still toggles it (the overlay's own selector
        // returns nil under .canvas, where there is no attention rollup, so it opens read-only / no-ops).
        case .peekAndReply: toggles.peekReply?()
        }
    }
}
