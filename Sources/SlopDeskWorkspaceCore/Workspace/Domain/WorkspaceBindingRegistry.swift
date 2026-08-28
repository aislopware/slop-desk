import CSlopDeskFFI
import SlopDeskWorkspaceModel

// MARK: - WorkspaceAction (the tree-native command intent)

/// A tree-native workspace action — the intent the IDE-shell keyboard / menu / palette / cheat sheet
/// produce, routed to the matching ``WorkspaceStore`` TREE op by ``WorkspaceBindingRegistry`` (docs/42
/// §W6). The `Session → Tab → Pane` redesign's command vocabulary, and the ONLY one — the flat canvas
/// command enum it replaced is deleted, along with the canvas model itself.
///
/// A pure value enum (no view framework, no store import) so the chord → action mapping is unit-testable
/// with no view.
public enum WorkspaceAction: Hashable, Sendable {
    // Panes
    case splitRight // ⌘D  — split the active pane into a side-by-side column
    case splitDown // ⌘⇧D — split the active pane into a stacked row
    case splitLeft // ⌘⌥D — split the active pane, inserting the new pane on the LEADING (left) side
    case splitUp // ⌘⌥⇧D — split the active pane, inserting the new pane on the LEADING (top) side
    case closePane // ⌘W  — close the active pane (cascades the tab/session)
    case renamePane // no default chord — renames the active TAB on the tree shell (inline tab-strip
    // field). Title menu / context menu / palette only.
    case breakPaneToTab // ⌃⌘T — eject the active pane into a new tab
    case detachPane // ⌥⌘P — pop the active pane out into its OWN macOS window (session survives; the
    // satellite window's close reattaches it). macOS only — a no-op routing on iOS (no NSWindow).
    case reattachAllPanes // chord-less — fold every detached (own-window) pane back into its tab

    // Move pane (Zellij "move pane" — swap with the geometric neighbour)
    case movePaneLeft // ⌥⌘⇧←
    case movePaneRight // ⌥⌘⇧→
    case movePaneUp // ⌥⌘⇧↑
    case movePaneDown // ⌥⌘⇧↓

    // Resize pane (keyboard divider nudge — grow right/down, shrink left/up)
    case resizePaneLeft // ⌃⌘⇧←
    case resizePaneRight // ⌃⌘⇧→
    case resizePaneUp // ⌃⌘⇧↑
    case resizePaneDown // ⌃⌘⇧↓

    // Balance (tmux even-layout)
    case balancePanes // ⌃⌘=

    // Layouts (tmux/zellij select-layout — re-tile the active tab's panes)
    case cycleLayout // ⌃⌘L — step through the algorithmic layout presets
    case applyLayout(WorkspaceTreeOps.LayoutPreset) // a named preset (menu/palette only — no chord)

    // Focus
    case focusLeft // ⌃⌘←
    case focusRight // ⌃⌘→
    case focusUp // ⌃⌘↑
    case focusDown // ⌃⌘↓
    case cyclePaneNext // ⌘]  — sequentially focus the NEXT pane in the active tab (DFS order, wraps)
    case cyclePanePrev // ⌘[  — sequentially focus the PREVIOUS pane in the active tab (DFS order, wraps)

    // View
    case toggleZoom // ⌘⇧↩ — maximize / restore the active pane (render-only)
    case commandPalette // ⌘⇧P — show/hide the command palette (the documented default)
    case cheatSheet // ⌘/ — show/hide the keyboard cheat sheet
    case find // ⌘F — show/hide the find-in-terminal bar over the active pane
    case findNext // ⌘G — advance to the NEXT find match (opens the find bar if closed)
    case findPrev // ⇧⌘G — step to the PREVIOUS find match (opens the find bar if closed)
    case globalSearch // ⇧⌘F — show/hide the cross-tab Global Search results surface
    case toggleCopyMode // ⌘⇧C (+ ⌃⇧Space alias) — enter modal keyboard vi / copy-mode over the active pane
    // Vi Mode Key Hints: palette / menu command toggling the active pane's `⌘/` vi
    // key-hint bar. chord: nil — the live `⌘/` is `.cheatSheet`'s (contextual); surfacing it here makes
    // the bar discoverable, not only reachable via the contextual chord while in vi mode.
    case toggleViKeyHints
    // Read-Only mode: toggle the active pane's READ-ONLY input gate — every outbound path
    // (keys / paste / IME commit / mouse-report / click-to-move / drop / sync-broadcast) drops + beeps
    // once while output keeps streaming. No default chord; menu + command palette only.
    case toggleReadOnly
    // Secure Keyboard Entry: the MANUAL toggle for macOS process-global secure event input
    // over the active pane (the AUTO path engages on a host no-echo password prompt; this is the explicit
    // override). No default chord — menu + command palette only.
    case secureKeyboardEntry
    // Release Stuck Input: manual escape hatch for a remote-GUI pane whose host is left
    // holding a modifier/button (every release datagram of a redundant burst lost) — synthesizes key-up
    // for ALL modifiers + mouse-up for all buttons via the pane's synthetic-release paths. No default
    // chord — palette/menu only; a no-op for a non-video active pane.
    case releaseStuckInput
    // Lock Viewport Position: ⌥⌘L toggles the ACTIVE remote-GUI pane's viewport position
    // lock — freezes the edge-hover auto-pan so a pointer reaching for a pane-edge control no longer
    // drags the content along. A pure client compositor gate (never touches the host); a no-op for a
    // terminal / empty / not-streaming active pane.
    case toggleViewportLock
    // Fit Viewport to Pane / Actual Size: the ACTIVE remote-GUI pane's [fit] / [1×] footer
    // buttons, palette/menu-surfaced so they're discoverable outside that small control-bar icon
    // cluster (mirrors `toggleViewportLock`'s active-pane routing — same pure client compositor gate,
    // never touches the host). No default chord — chord-less like `pane.rename` / `view.readOnly`; a
    // no-op for a terminal / empty / not-streaming active pane, or while the viewport is LOCKED (the
    // footer buttons are disabled then too — unlock first).
    case fitViewportToPane
    case resetViewportZoom
    // Paste as Keystrokes: ⌥⌘V types the LOCAL clipboard into the ACTIVE remote-GUI
    // pane's host window as paced per-key CGEvents (the path that reaches a sudo / SecurityAgent secure
    // field) — since a plain ⌘V forwards a raw Cmd+V that pastes the HOST clipboard. A no-op for a
    // terminal (own paste pipeline) / empty / read-only pane.
    case pasteAsKeystrokes
    case toggleSidebar // ⌘⇧L — show/hide the sessions sidebar
    // View → Toggle Code Panel: show/hide the RIGHT sidebar hosting the project-scoped embedded
    // VS Code (code-server in a WKWebView — every pane of one project shares the ONE instance opened
    // at that project's root). ⌘⇧R, mirroring ⌘⇧L on the left panel. Window-scope chrome → needs no
    // active pane. iOS HAS the code panel — the old note here said it did not, which stopped being
    // true: `SlopDeskPhoneUI/WorkspaceRootView.swift` mounts the same `CodePanelSurfaces` as a
    // `.fullScreenCover` and installs this closure. A sidebar on the Mac, a cover on the phone, is
    // the layout difference the split exists for; the capability is on both.
    case toggleCodeSidebar
    // View → Switch Editor / Terminal Focus: move the KEYBOARD between the terminal and the embedded
    // editor, and back. ⌥⌘R, the sibling of ⌘⇧R (that one shows/hides the panel; this one decides who types
    // into it). Until this existed the editor could only be reached by CLICKING it — the panel's
    // focus policy refuses every claim that is not a mouse-down inside the webview, which is what
    // keeps VS Code's own aggressive autofocus from stealing the keyboard mid-keystroke. A chord is
    // app-directed, not page-directed, so it rides the same explicitly-armed path the pool's
    // warm-swap restore uses and leaves that guarantee intact. One chord for both directions: with
    // the editor holding the keyboard it hands back to the pane that had it, otherwise it reveals
    // the panel (if hidden) and claims. Window-scope chrome → needs no active pane; iOS has no code
    // panel (documented no-op — the closure is never installed there).
    case focusCodePanel
    // View → Pin Window: keep the window floating above ALL other apps' windows. CHORD-LESS;
    // the live macOS app flips `WorkspaceChromeState.pinned` → `NSWindow.level = .floating` via the route
    // closure. Window-scope → needs no active pane; iOS has no window level (documented no-op).
    case pinWindow
    case openQuickly // ⌘⇧O — open the fuzzy "open quickly" file/symbol switcher (stub)
    // Jump-To: ⌘J opens the floating Jump-To panel — the active pane's detected paths/URLs
    // (over scrollback) + its OSC-133 command/prompt index, fuzzy-filterable, ↩ to act / ⌘K per-row
    // actions. A VIEW overlay (OverlayCoordinator), routed through a passed-in toggle closure like
    // `.globalSearch`. ⌘J is FREE (only ⌘⇧J / ⌘⌥J use `j`).
    case jumpTo

    // Hint Mode (`terminal-features__hint-mode`): overlay 2-letter Vimium labels on every
    // detected target in the active pane's viewport; type the label to run the action — no mouse. Three
    // intents: ⌘⇧J open (paths→host / URLs→client), ⌘⇧Y copy (→ client clipboard), reveal-in-Finder (host),
    // CHORD-LESS (⌘⇧R is Toggle Code Panel — see `view.toggleCodeSidebar`) so palette/menu-surfaced +
    // an in-overlay action switch. Hint Mode owns ⌘⇧J for Hint to Open, so `.peekAndReply` binds ⌘⌥J instead
    // (see `view.peekReply`). Each targets the active terminal pane (a no-op off-terminal).
    case hintToOpen // ⌘⇧J
    case hintToCopy // ⌘⇧Y
    case hintToReveal // chord-less

    // View — viewport scroll (named-key chords — the §5 prefix exemption)
    case scrollPageUp // ⇧PageUp — scroll the active pane one page toward older scrollback
    case scrollPageDown // ⇧PageDown — scroll the active pane one page toward newer output
    case scrollToTop // ⇧Home — jump the viewport to the top of the scrollback buffer
    case scrollToBottom // ⇧End — jump the viewport to the bottom (newest) of the buffer
    case commandJumpPrev // ⌘PageUp — jump to the PREVIOUS shell prompt (reuses jumpToBlock(-1))
    case commandJumpNext // ⌘PageDown — jump to the NEXT shell prompt (reuses jumpToBlock(+1))

    // View — font size (libghostty rescales the cell box, reflowing the remote PTY grid via SIGWINCH)
    case increaseFontSize // ⌘= / ⌘+ — bump the active pane's render font size (⌘+ via `aliasChords`)
    case decreaseFontSize // ⌘- — shrink the active pane's render font size
    case resetFontSize // ⌘0 — reset the active pane's render font size to the configured default

    // Blocks (Warp-style per-command blocks)
    case commandNavigator // ⌃⌘O — show/hide the searchable recent-blocks navigator over the active pane
    case jumpPreviousBlock // ⌃⌘[ — jump the viewport to the previous shell prompt (OSC 133, libghostty)
    case jumpNextBlock // ⌃⌘] — jump the viewport to the next shell prompt
    case reRunLastCommand // ⌃⌘R — re-inject the active pane's latest captured command (verbatim + newline)
    case jumpPreviousFailed // ⌃⌘⇧[ — jump to the previous (newer) FAILED block
    case jumpNextFailed // ⌃⌘⇧] — jump to the next (older) FAILED block

    // Tabs
    case newTab // ⌘T
    case newDesktopTab // ⌥⌘N — the remote-desktop WINDOW (historical case name; schemas persist it)
    case nextTab // ⌘⇧]
    case prevTab // ⌘⇧[
    case selectPane(Int) // ⌘1…⌘9 (1-based, the session's flat pane order)
    case paneSwitcher // ⌃⇥ — the press-and-hold MRU switcher. CHORD-LESS in this table on purpose: the live
    // gesture (open / step / commit-on-⌃-release) cannot be expressed as one chord row, so each platform's
    // key path claims ⌃⇥ directly, ABOVE the table — `WorkspaceKeyDispatcher.consumePaneSwitcher` on macOS,
    // `TerminalInputHost.takesPaneSwitcherKey` on iOS (both spend `PhoneKey.paneSwitcherKey`'s / their own
    // reading of the same four keys on the same store verbs). This entry exists so the switcher is
    // DISCOVERABLE in the palette / cheat sheet and openable without a keyboard; routing it opens an UNARMED
    // switcher (Return commits, since no modifier is held to release) — which is also what the phone's
    // hardware ⌃⇥ opens, iOS having no press to report for a bare modifier's release.
    case closeTab // no default chord — closes the active tab (all its panes); reachable via the ⌘W
    // cascade + palette/menu (⌘⇧W is Close Window, so there's no Close-Tab chord)
    case closeWindow // ⌘⇧W — close the active window (→ Session); the close-confirmation surface gates it
    case reopenClosed // ⌘⇧T — reopen the most recently closed pane (browser idiom; stub)

    // Synchronized input (Zellij ToggleActiveSyncTab)
    case toggleSyncInput // ⌘⇧I — broadcast keystrokes to every other pane in the active tab

    // Supervision (jump to the pane that needs you)
    case jumpToAttention // ⌘⇧U — focus the oldest pane needing attention (needsPermission first, then done)

    // Supervision (answer the blocked pane INLINE without a context switch)
    case peekAndReply // ⌘⌥J — open the Peek & Reply overlay over the oldest pane needing attention (not ⌘⇧J:
    // Hint Mode owns that for Hint to Open — see `view.peekReply` / `hintToOpen`)
}

public extension WorkspaceAction {
    /// The display category the cheat sheet groups by (and the menu/palette sections mirror).
    enum Category: String, Sendable, CaseIterable {
        case panes = "Panes"
        case tabs = "Tabs"
        case focus = "Focus"
        case view = "View"
    }

    /// Whether running this action requires an active pane (so the palette can omit it on an empty shell,
    /// and the menu can grey it out).
    var requiresActivePane: Bool {
        switch self {
        case .splitRight,
             .splitDown,
             .splitLeft, // splits the active pane — needs one
             .splitUp,
             .closePane,
             .renamePane,
             .breakPaneToTab,
             .detachPane, // pops the ACTIVE pane out — needs one
             .movePaneLeft,
             .movePaneRight,
             .movePaneUp,
             .movePaneDown,
             .resizePaneLeft,
             .resizePaneRight,
             .resizePaneUp,
             .resizePaneDown,
             .balancePanes,
             .cycleLayout, // re-tiles the active tiled tab
             .applyLayout, // re-tiles the active tiled tab into a named preset
             .focusLeft,
             .focusRight,
             .focusUp,
             .focusDown,
             .cyclePaneNext, // steps focus through the active tab's panes — needs one to step from
             .cyclePanePrev,
             .toggleZoom:
            true
        case .find,
             // ⌘G / ⇧⌘G navigate find-bar matches over the active TERMINAL pane (opening it when closed) —
             // same graceful-no-op family as `.find`.
             .findNext,
             .findPrev,
             .toggleCopyMode,
             // toggles the ACTIVE terminal pane's `⌘/` hint bar; no-ops off-terminal or outside vi mode.
             .toggleViKeyHints,
             // gates the ACTIVE terminal pane's input; no-ops on an empty / non-terminal shell.
             .toggleReadOnly,
             // toggles the ACTIVE terminal pane's manual secure input; no-ops off-terminal.
             .secureKeyboardEntry,
             // targets the ACTIVE remote-GUI pane's release sink; no-ops on a terminal / empty / read-only pane.
             .releaseStuckInput,
             // toggles the ACTIVE remote-GUI pane's viewport lock; no-ops on a terminal / empty / off-stream pane.
             .toggleViewportLock,
             // fit / actual-size the ACTIVE remote-GUI pane's viewport; no-ops on a terminal / empty / off-stream / locked pane.
             .fitViewportToPane,
             .resetViewportZoom,
             // types the local clipboard into the ACTIVE remote-GUI pane; no-ops on a terminal / empty / read-only pane.
             .pasteAsKeystrokes,
             .commandNavigator,
             // scans the ACTIVE terminal pane (scrollback links + OSC-133 command index); empty list off-terminal.
             .jumpTo,
             // Hint Mode overlays labels on the ACTIVE terminal pane's targets; no-ops off-terminal.
             .hintToOpen,
             .hintToCopy,
             .hintToReveal,
             .jumpPreviousBlock,
             .jumpNextBlock,
             .reRunLastCommand,
             .jumpPreviousFailed,
             .jumpNextFailed,
             // Scroll / font / command-jump target the active TERMINAL pane — same graceful-no-op family
             // as the block / find rows above.
             .scrollPageUp,
             .scrollPageDown,
             .scrollToTop,
             .scrollToBottom,
             .commandJumpPrev,
             .commandJumpNext,
             .increaseFontSize,
             .decreaseFontSize,
             .resetFontSize:
            // Block / find / scroll / font affordances all target the active TERMINAL pane, so they need
            // one but degrade gracefully (a no-pane shell just no-ops) — not greyed out aggressively.
            true
        case .commandPalette,
             .cheatSheet,
             .globalSearch, // a cross-tab results surface — acts globally, needs no active pane (like the palette)
             .newTab,
             .newDesktopTab, // reveal-or-mint the desktop window — acts on the session, needs no active pane
             .nextTab,
             .prevTab,
             .selectPane, // names a pane by NUMBER — resolves against the session, not the focused pane
             .paneSwitcher, // walks the session's panes — a session-scope action, needs no active pane
             .closeTab,
             .closeWindow, // closes the whole window (→ Session) — a window-scope action, needs no active pane
             .reopenClosed, // restores a closed pane into the active tab — acts on history, not a live pane
             .toggleSidebar,
             .toggleCodeSidebar, // the right code panel — window-scope chrome, like the left sidebar
             // Focus Code Panel reaches for the PANEL, not a pane — and its hand-back target is
             // whatever last held the keyboard, which need not be a pane at all.
             .focusCodePanel,
             .pinWindow, // a window-scope NSWindow.level toggle — needs no active pane (like the sidebar toggle)
             .openQuickly, // a global fuzzy switcher — needs no active pane
             .toggleSyncInput, // the tab must exist, but the palette can still show it (mirrors .newTab)
             .jumpToAttention, // acts globally across all tabs/sessions — needs no active pane
             .peekAndReply, // acts globally (targets the oldest attention pane) — needs no active pane
             .reattachAllPanes: // acts on the detached set — needs no active pane
            false
        }
    }
}

// MARK: - WorkspaceBinding (one registry row: action + chord + display)

/// One row of the single-source-of-truth binding table: an action, its default chord (or `nil` for a
/// palette-only verb), plus the display shape the menu / palette / cheat sheet render. Pure value data.
public struct WorkspaceBinding: Sendable, Equatable {
    /// A stable string id (the dedup + rebind key; settings will key user overrides by it).
    public let id: String
    public let action: WorkspaceAction
    public let title: String
    public let category: WorkspaceAction.Category
    /// The default chord, or `nil` for a binding surfaced only in the palette / menu (no key equivalent).
    public let chord: KeyChord?
    /// SF Symbol for the menu / palette row.
    public let symbol: String
    /// Extra non-displayed fuzzy-match terms (synonyms the user might type) — folded into the palette
    /// haystack, never rendered.
    public let keywords: String?

    public init(
        id: String,
        action: WorkspaceAction,
        title: String,
        category: WorkspaceAction.Category,
        chord: KeyChord?,
        symbol: String,
        keywords: String? = nil,
    ) {
        self.id = id
        self.action = action
        self.title = title
        self.category = category
        self.chord = chord
        self.symbol = symbol
        self.keywords = keywords
    }
}

// MARK: - WorkspaceBindingRegistry (the ONE source of truth)

/// The single source of truth for the IDE-shell command surface (docs/42 §W6): ONE ``bindings`` table
/// that the menu bar (``WorkspaceCommands``), the ⌘⇧P command palette (`PaletteView`), the ⌘/
/// cheat sheet (`KeyboardCheatSheetView`), and the routing tests ALL read — so chord, menu item, palette
/// row, and cheat-sheet glyph can never drift (and settings has one table to make user-editable).
///
/// Every chord is ⌘- or ⌥-prefixed (the load-bearing §5 conflict rule: a bare key / Ctrl-letter falls
/// through to the focused terminal), and no two bindings share a chord — both pinned by
/// `TreeCommandRoutingTests`. The chords follow the reference keymap: ⌘T new tab, ⌘W close, ⌘D
/// split-right, ⌘⇧D split-down, ⌃⌘+arrows focus, ⌘⇧↩ zoom, ⌘⇧]/⌘⇧[ next/prev tab, ⌘1…9 select pane,
/// ⌘⇧L toggle Tabs panel, ⌃⌘T break-pane-to-tab, ⌘⇧P palette,
/// ⌘/ cheat sheet. Rename has no default chord — menu / palette / context-menu only (`chord: nil`).
public enum WorkspaceBindingRegistry {
    /// The shipped binding table for THIS half — ``declared`` minus the rows
    /// `slopdesk_workspace::binding_rows` says this platform does not list.
    ///
    /// Filtering here rather than at each display surface is deliberate, and the chord table is why.
    /// Every surface downstream reads from this one array, ``allBindings`` or ``groupedForDisplay``,
    /// and ``chordTable`` is one of them: a row kept on a half that cannot run it takes its chord away
    /// from the terminal to do nothing. Dropping the row drops the chord, so the key falls through to
    /// the pane the way an unbound chord should.
    public static let bindings: [WorkspaceBinding] = declared.filter { BindingRowPlatform.lists($0.id) }

    /// Every binding the registry DECLARES, before the platform filter, in cheat-sheet / palette
    /// display order (panes, tabs, focus, view). `.selectPane(n)` for n=1…9 is generated (one chord
    /// each) but is NOT listed here — it is expanded by ``selectPaneBindings`` so the table stays
    /// readable; the cheat sheet collapses the nine slots to the one representative row
    /// ``selectPaneRepresentative``, appended by ``groupedForDisplay`` (the menu builds its own
    /// "Select Pane" submenu, the palette catalog omits the digits).
    ///
    /// Private because a caller that wanted this one rather than ``bindings`` would be asking for the
    /// rows this half cannot run — which is the defect ``BindingRowPlatform`` exists to close.
    private static let declared: [WorkspaceBinding] = [
        // Panes
        WorkspaceBinding(
            id: "pane.splitRight", action: .splitRight, title: "Split Right",
            category: .panes, chord: KeyChord(character: "d", [.command]),
            symbol: "rectangle.split.2x1", keywords: "split column side vertical divider new pane",
        ),
        WorkspaceBinding(
            id: "pane.splitDown", action: .splitDown, title: "Split Down",
            category: .panes, chord: KeyChord(character: "d", [.command, .shift]),
            symbol: "rectangle.split.1x2", keywords: "split row stacked horizontal divider new pane below",
        ),
        // Split-left / split-up: ⌥+ the ⌘D / ⌘⇧D split chords, inserting the new pane on the
        // LEADING side (left of a horizontal split / above a vertical one) and focusing it. ⌘⌥D / ⌘⌥⇧D are
        // FREE (⌥ is in no other `d` chord; ⌘D right, ⌘⇧D down). Pinned unique by the chord-uniqueness guard.
        WorkspaceBinding(
            id: "pane.splitLeft", action: .splitLeft, title: "Split Left",
            category: .panes, chord: KeyChord(character: "d", [.command, .option]),
            symbol: "rectangle.split.2x1", keywords: "split column side vertical divider new pane left leading",
        ),
        WorkspaceBinding(
            id: "pane.splitUp", action: .splitUp, title: "Split Up",
            category: .panes, chord: KeyChord(character: "d", [.command, .option, .shift]),
            symbol: "rectangle.split.1x2", keywords: "split row stacked horizontal divider new pane above leading",
        ),
        WorkspaceBinding(
            id: "pane.close", action: .closePane, title: "Close Pane",
            category: .panes, chord: KeyChord(character: "w", [.command]),
            symbol: "xmark", keywords: "quit kill end terminate remove",
        ),
        // Rename has NO default chord — title menu / context menu / palette only; `chord: nil` surfaces the
        // row without binding a key. Pinned chord-less by `E1KeymapParityTests`.
        WorkspaceBinding(
            id: "pane.rename", action: .renamePane, title: "Rename Tab",
            category: .panes, chord: nil,
            symbol: "pencil", keywords: "title label name tab",
        ),
        WorkspaceBinding(
            id: "pane.breakToTab", action: .breakPaneToTab, title: "Break Pane to Tab",
            category: .panes, chord: KeyChord(character: "t", [.control, .command]),
            symbol: "rectangle.portrait.and.arrow.right", keywords: "eject move detach pop out promote",
        ),
        // Detach to an OWN OS window (satellite): ⌥⌘P ("Pop out") — `p` is in no other ⌘ chord
        // (⌘⇧P is the palette; modifiers differ), pinned unique by the chord-uniqueness guard. The
        // session/PTY/stream survives; closing the satellite window reattaches.
        WorkspaceBinding(
            id: "pane.detach", action: .detachPane, title: "Detach Pane into Window",
            category: .panes, chord: KeyChord(character: "p", [.option, .command]),
            symbol: "macwindow.on.rectangle", keywords: "detach pop out float window satellite separate monitor",
        ),
        // Reattach all satellites — chord-less (menu / palette; each satellite's close button reattaches
        // just itself).
        WorkspaceBinding(
            id: "pane.reattachAll", action: .reattachAllPanes, title: "Reattach All Panes",
            category: .panes, chord: nil,
            symbol: "macwindow.and.cursorarrow", keywords: "reattach dock fold return window satellite",
        ),
        // Move pane (Zellij "move pane" — swap with the geometric neighbour). ⌥⌘⇧+arrows: the ⌥ modifier
        // (vs ⌃) keeps them distinct from focus (⌃⌘arrows) and the ⌃⌘⇧arrow divider chords below, so a
        // move never collides with a focus move or a divider nudge.
        WorkspaceBinding(
            id: "pane.moveLeft", action: .movePaneLeft, title: "Move Pane Left",
            category: .panes, chord: KeyChord(.leftArrow, [.option, .command, .shift]),
            symbol: "arrow.left.square", keywords: "swap reorder shift pane left",
        ),
        WorkspaceBinding(
            id: "pane.moveRight", action: .movePaneRight, title: "Move Pane Right",
            category: .panes, chord: KeyChord(.rightArrow, [.option, .command, .shift]),
            symbol: "arrow.right.square", keywords: "swap reorder shift pane right",
        ),
        WorkspaceBinding(
            id: "pane.moveUp", action: .movePaneUp, title: "Move Pane Up",
            category: .panes, chord: KeyChord(.upArrow, [.option, .command, .shift]),
            symbol: "arrow.up.square", keywords: "swap reorder shift pane up",
        ),
        WorkspaceBinding(
            id: "pane.moveDown", action: .movePaneDown, title: "Move Pane Down",
            category: .panes, chord: KeyChord(.downArrow, [.option, .command, .shift]),
            symbol: "arrow.down.square", keywords: "swap reorder shift pane down",
        ),
        // Move divider (keyboard divider nudge). "Move divider up/down/left/right" = ⌃⌘⇧arrows
        // (spec/reference__keybindings.md:86-89, customization__custom-keybindings.md:78-81) — distinct from
        // focus (⌃⌘arrows). Grows the active pane toward the arrow (right/down) or shrinks it (left/up).
        WorkspaceBinding(
            id: "pane.resizeLeft", action: .resizePaneLeft, title: "Move Divider Left",
            category: .panes, chord: KeyChord(.leftArrow, [.control, .command, .shift]),
            symbol: "arrow.left.and.line.vertical.and.arrow.right",
            keywords: "resize shrink narrower width divider move",
        ),
        WorkspaceBinding(
            id: "pane.resizeRight", action: .resizePaneRight, title: "Move Divider Right",
            category: .panes, chord: KeyChord(.rightArrow, [.control, .command, .shift]),
            symbol: "arrow.right.and.line.vertical.and.arrow.left",
            keywords: "resize grow wider width divider move",
        ),
        WorkspaceBinding(
            id: "pane.resizeUp", action: .resizePaneUp, title: "Move Divider Up",
            category: .panes, chord: KeyChord(.upArrow, [.control, .command, .shift]),
            symbol: "arrow.up.and.line.horizontal.and.arrow.down",
            keywords: "resize shrink shorter height divider move",
        ),
        WorkspaceBinding(
            id: "pane.resizeDown", action: .resizePaneDown, title: "Move Divider Down",
            category: .panes, chord: KeyChord(.downArrow, [.control, .command, .shift]),
            symbol: "arrow.down.and.line.horizontal.and.arrow.up",
            keywords: "resize grow taller height divider move",
        ),
        // Balance (tmux even-layout): reset the active tab's split weights to equal. ⌃⌘= is otherwise unbound.
        WorkspaceBinding(
            id: "pane.balance", action: .balancePanes, title: "Balance Panes",
            category: .panes, chord: KeyChord(character: "=", [.control, .command]),
            symbol: "rectangle.split.2x2", keywords: "even equal distribute reset layout balance tile",
        ),
        // Layouts (tmux/zellij select-layout): ⌃⌘L cycles the algorithmic re-tile presets
        // (even-horizontal/vertical, main-vertical/horizontal, tiled). Parallels ⌃⌘= Balance ("L = Layout");
        // ⌃⌘L is otherwise unbound (`l` in NO other chord). This binding fires ONLY via its menu item (no
        // NSEvent monitor — same as sync-input), so the Pane menu's "Layouts ▸ Cycle Layout" item is what
        // dispatches ⌃⌘L. The five NAMED presets are menu/palette only (`.applyLayout(_)`, no chord). Pinned
        // unique by `TreeCommandRoutingTests`.
        WorkspaceBinding(
            id: "pane.cycleLayout", action: .cycleLayout, title: "Cycle Layout",
            category: .panes, chord: KeyChord(character: "l", [.control, .command]),
            symbol: "rectangle.3.group",
            keywords: "layout retile arrange tile even main select-layout cycle zellij tmux",
        ),
        // Tabs
        WorkspaceBinding(
            id: "tab.new", action: .newTab, title: "New Tab",
            category: .tabs, chord: KeyChord(character: "t", [.command]),
            symbol: "plus.rectangle.on.rectangle", keywords: "add open create tab",
        ),
        // REMOTE DESKTOP (⌥⌘N): the dedicated desktop WINDOW — reveal-or-mint, never a tab
        // (docs/DECISIONS.md 2026-07-22). ⌥⌘N is FREE (`n` appears in no other live chord) and
        // echoes the dead canvas table's "⌥⌘N = new remote pane" precedent. The id + action keep
        // their historical names (keybinding schemas persist them).
        WorkspaceBinding(
            id: "tab.newDesktop", action: .newDesktopTab, title: "Remote Desktop",
            category: .tabs, chord: KeyChord(character: "n", [.command, .option]),
            symbol: "display",
            keywords: "desktop display screen full remote stream monitor window",
        ),
        // Tab cycling lives on ⌘⇧]/⌘⇧[ (see DECISIONS), NOT plain ⌘]/⌘[ — those drive sequential
        // PANE cycling instead (`focus.cycleNext`/`focus.cyclePrev`), per the reference table; the Muxy tab
        // parity on bare ⌘]/⌘[ is intentionally not followed here. Pinned by `E1KeymapParityTests`.
        WorkspaceBinding(
            id: "tab.next", action: .nextTab, title: "Next Tab",
            category: .tabs, chord: KeyChord(character: "]", [.command, .shift]),
            symbol: "arrow.forward.square", keywords: "cycle forward switch tab next",
        ),
        WorkspaceBinding(
            id: "tab.prev", action: .prevTab, title: "Previous Tab",
            category: .tabs, chord: KeyChord(character: "[", [.command, .shift]),
            symbol: "arrow.backward.square", keywords: "cycle back previous switch tab",
        ),
        // Close Tab has NO default chord (see DECISIONS): ⌘⇧W is Close WINDOW and ⌘W already
        // cascades pane → tab → window, so a dedicated Close-Tab chord is unnecessary. `chord: nil` keeps the
        // row in the palette / menu; tab close stays reachable via the ⌘W cascade. Pinned chord-less by
        // `TreeCommandRoutingTests`; the ⌘⇧W assignment is explained in DECISIONS.md.
        // The ⌃⇥ switcher. `chord: nil` — the ⌃⇥ gesture is RESPONDER-owned on both platforms (see the
        // action's comment), and registering ⌃⇥ here would both misdescribe it (one row cannot mean
        // open/step/commit, and the walk's Esc / Return / arrows have no row at all) and put a ⌃-only chord
        // in a table whose §5 invariant is "every chord carries ⌘ or ⌥". A row would also cost the
        // `unbind: ctrl+tab` escape hatch its meaning: that unbind hands the GESTURE back, which only works
        // while the gesture is the thing above the table rather than a row inside it. The glyph rides the
        // keywords instead — the established idiom for a chord-less row whose key is worth advertising
        // (cf. `view.viKeyHints` carrying ⌘/).
        WorkspaceBinding(
            id: "pane.switcher", action: .paneSwitcher, title: "Pane Switcher",
            category: .panes, chord: nil,
            symbol: "square.stack",
            keywords: "⌃⇥ ctrl tab pane switcher recent recently used mru last previous quick switch alt-tab",
        ),
        WorkspaceBinding(
            id: "tab.close", action: .closeTab, title: "Close Tab",
            category: .tabs, chord: nil,
            symbol: "xmark.rectangle", keywords: "close end terminate tab all panes",
        ),
        // Close Window ⌘⇧W — the reference default (spec/user-interface__window-tab-
        // split.md:99/103/104: ⌘⇧W = Close window). A window maps to a slopdesk ``Session`` (DECISIONS.md),
        // so routing to `requestCloseWindow()` parks the close behind the `closeConfirmWindow` policy /
        // busy-shell guard. Close Tab (above) is deliberately left chord-less so ⌘⇧W stays collision-free
        // for this binding. Pinned by `TreeCommandRoutingTests`.
        WorkspaceBinding(
            id: "window.close", action: .closeWindow, title: "Close Window",
            category: .tabs, chord: KeyChord(character: "w", [.command, .shift]),
            symbol: "macwindow.badge.minus", keywords: "close window session end terminate all tabs quit",
        ),
        // Reopen the most recently closed pane (the browser "reopen tab" idiom, beside ⌘T new / ⌘⇧W close).
        // ⌘⇧T is FREE on the tree shell (the only other `t` chords are ⌘T new tab + ⌃⌘T break-pane). The
        // "closed-pane LIFO + restore are future work, this is a graceful no-op" note that used to sit here
        // outlived its own subject: the route runs `reopenLastClosedPane()`, which stages intent 20 with LIFO
        // index 0 — a pinned wire op with a golden vector — and Open Quickly addresses the same stack by index.
        WorkspaceBinding(
            id: "tab.reopenClosed", action: .reopenClosed, title: "Reopen Closed Pane",
            category: .tabs, chord: KeyChord(character: "t", [.command, .shift]),
            symbol: "arrow.uturn.backward", keywords: "reopen restore undo closed pane tab last recently",
        ),
        WorkspaceBinding(
            id: "tab.syncInput", action: .toggleSyncInput, title: "Sync Input to All Panes",
            category: .tabs, chord: KeyChord(character: "i", [.command, .shift]),
            symbol: "keyboard.badge.ellipsis",
            keywords: "sync broadcast input panes tab synchronize mirror zellij",
        ),
        // Supervision: jump to the oldest pane needing attention (needsPermission first, then done) —
        // a global action across all tabs/sessions, so it lives in the Tabs group beside sync-input. ⌘⇧U is
        // FREE (no other binding uses `u`); pinned unique by the chord-uniqueness test.
        WorkspaceBinding(
            id: "view.jumpToAttention", action: .jumpToAttention, title: "Jump to Pane Needing Attention",
            category: .tabs, chord: KeyChord(character: "u", [.command, .shift]),
            symbol: "bell.badge",
            keywords: "jump unread attention needs permission blocked done next pane supervise oldest",
        ),
        // Supervision: ⌘⌥J opens the Peek & Reply overlay over the oldest pane needing attention so the
        // human can ANSWER a blocked agent INLINE — no full tab/context switch. Partner of ⌘⇧U (jump TO the
        // pane): "J" = jump-in-and-reply, kept on `j`. Bound to ⌘⌥J, not ⌘⇧J, because Hint Mode owns
        // ⌘⇧J for Hint to Open (`view.hintOpen`); ⌘⌥J is free. Menu/palette-surfaced, so there's no muscle-
        // memory cost to this choice (DECISIONS.md). This chord fires ONLY via its menu item, so the Pane
        // menu carries the matching "Peek & Reply" item. Pinned unique by the chord-uniqueness test +
        // `PeekReplyTests`.
        WorkspaceBinding(
            id: "view.peekReply", action: .peekAndReply, title: "Peek & Reply to Blocked Pane",
            category: .tabs, chord: KeyChord(character: "j", [.command, .option]),
            symbol: "bubble.left.and.text.bubble.right",
            keywords: "peek reply answer respond blocked needs permission inline quick supervise prompt",
        ),
        // Focus pane up/down/left/right — the documented default ⌃⌘arrows
        // (spec/reference__keybindings.md:82-85, customization__custom-keybindings.md:74-77). The single most
        // load-bearing pane-navigation chord set; the divider-move family sits on ⌃⌘⇧arrows above.
        WorkspaceBinding(
            id: "focus.left", action: .focusLeft, title: "Focus Left",
            category: .focus, chord: KeyChord(.leftArrow, [.control, .command]),
            symbol: "arrow.left", keywords: "move navigate pane",
        ),
        WorkspaceBinding(
            id: "focus.right", action: .focusRight, title: "Focus Right",
            category: .focus, chord: KeyChord(.rightArrow, [.control, .command]),
            symbol: "arrow.right", keywords: "move navigate pane",
        ),
        WorkspaceBinding(
            id: "focus.up", action: .focusUp, title: "Focus Up",
            category: .focus, chord: KeyChord(.upArrow, [.control, .command]),
            symbol: "arrow.up", keywords: "move navigate pane",
        ),
        WorkspaceBinding(
            id: "focus.down", action: .focusDown, title: "Focus Down",
            category: .focus, chord: KeyChord(.downArrow, [.control, .command]),
            symbol: "arrow.down", keywords: "move navigate pane",
        ),
        // Sequential pane cycle: ⌘]/⌘[ step focus through the active tab's panes in DFS order
        // (wrapping). These chords were FREED from tab cycling, which moved to ⌘⇧]/⌘⇧[ (see the `tab.next`
        // re-point + DECISIONS). Distinct from ⌃⌘]/⌃⌘[ (block jump) and ⌘⇧]/⌘⇧[ (tab cycle).
        WorkspaceBinding(
            id: "focus.cycleNext", action: .cyclePaneNext, title: "Cycle to Next Pane",
            category: .focus, chord: KeyChord(character: "]", [.command]),
            symbol: "arrow.forward", keywords: "cycle next pane focus sequential rotate",
        ),
        WorkspaceBinding(
            id: "focus.cyclePrev", action: .cyclePanePrev, title: "Cycle to Previous Pane",
            category: .focus, chord: KeyChord(character: "[", [.command]),
            symbol: "arrow.backward", keywords: "cycle previous pane focus sequential rotate back",
        ),
        // View
        // Zoom / unzoom split — the documented default ⌘⇧↩ (spec/reference__keybindings.md:78,
        // customization__custom-keybindings.md:70). Toggles a single pane to fill the tab.
        WorkspaceBinding(
            id: "view.zoom", action: .toggleZoom, title: "Maximize Pane",
            category: .view, chord: KeyChord(.return, [.command, .shift]),
            symbol: "arrow.up.left.and.arrow.down.right", keywords: "fullscreen full screen zoom expand enlarge",
        ),
        // Command Palette ⌘⇧P — the documented default (spec/reference__keybindings.md:42,
        // spec/user-interface__command-palette.md:5/9/35 "Opened with ⌘⇧P from anywhere"). ⌘⇧P is FREE (no
        // other `p` chord). Pinned by `E1KeymapParityTests`; the chord-reassignment history is in DECISIONS.md.
        WorkspaceBinding(
            id: "view.palette", action: .commandPalette, title: "Command Palette",
            category: .view, chord: KeyChord(character: "p", [.command, .shift]),
            symbol: "command", keywords: "search run quickly open actions",
        ),
        WorkspaceBinding(
            id: "view.cheatSheet", action: .cheatSheet, title: "Keyboard Shortcuts",
            category: .view, chord: KeyChord(character: "/", [.command]),
            symbol: "keyboard", keywords: "shortcuts cheat sheet help keys reference",
        ),
        WorkspaceBinding(
            id: "view.find", action: .find, title: "Find…",
            category: .view, chord: KeyChord(character: "f", [.command]),
            symbol: "magnifyingglass", keywords: "search scrollback grep locate text in terminal",
        ),
        // Find Next / Previous: ⌘G advances, ⇧⌘G steps back through the active pane's find
        // matches — and OPENS the find bar when it is closed (faithful "find next opens find"). ⌘G / ⇧⌘G are
        // FREE (`g` appears in NO other chord). Pinned unique by `TreeCommandRoutingTests`.
        WorkspaceBinding(
            id: "view.findNext", action: .findNext, title: "Find Next",
            category: .view, chord: KeyChord(character: "g", [.command]),
            symbol: "chevron.down", keywords: "next find search again forward match",
        ),
        WorkspaceBinding(
            id: "view.findPrev", action: .findPrev, title: "Find Previous",
            category: .view, chord: KeyChord(character: "g", [.command, .shift]),
            symbol: "chevron.up", keywords: "previous find search back backward match",
        ),
        // Global Search: ⇧⌘F searches every tab's scrollback and shows a grouped results surface.
        // ⇧⌘F is reserved for global search. Pinned unique by `TreeCommandRoutingTests`.
        WorkspaceBinding(
            id: "view.globalSearch", action: .globalSearch, title: "Global Search…",
            category: .view, chord: KeyChord(character: "f", [.command, .shift]),
            symbol: "magnifyingglass.circle", keywords: "global search all tabs scrollback grep cross pane find",
        ),
        // Vi Mode: modal keyboard scrollback navigation ("Vi Mode" / tmux-zellij copy-mode).
        // Documented entry chord is ⌃⇧Space; slopdesk's canonical DISPLAY chord stays the pre-existing ⌘⇧C
        // (muscle memory / menu glyph unchanged), with ⌃⇧Space folded in as a SECOND resolving chord via
        // ``aliasChords`` (no extra display row — the ⌘+ font-increase idiom). Title "Vi Mode", "copy mode"
        // kept in keywords so palette search for the old name still finds it. ⌘⇧C is FREE (`c` in NO other
        // binding) and does not collide with the system plain ⌘C copy (different modifier set, handled by the
        // terminal's own copy responder). Verified unique by the chord-uniqueness guard.
        WorkspaceBinding(
            id: "view.copyMode", action: .toggleCopyMode, title: "Vi Mode",
            category: .view, chord: KeyChord(character: "c", [.command, .shift]),
            symbol: "doc.on.clipboard",
            keywords: "vi mode copy mode scrollback keyboard navigate select yank visual control shift space tmux zellij",
        ),
        // Vi Mode Key Hints: the `⌘/` reference-card toggle, surfaced as a DISCOVERABLE
        // palette / menu command (not only the contextual `⌘/` firing in vi mode). `chord: nil` — the live
        // `⌘/` is `view.cheatSheet`'s (double duty: cheat sheet normally, this hint bar in vi mode), so a
        // second registered chord would collide. Toggles the active pane's hint bar (no-op outside vi mode,
        // where the bar is gated off). The glyph `⌘/` is in the keywords for discovery.
        WorkspaceBinding(
            id: "view.viKeyHints", action: .toggleViKeyHints, title: "Vi Mode Key Hints",
            category: .view, chord: nil,
            symbol: "keyboard.badge.eye",
            keywords: "vi mode key hints reference card cheat shortcuts copy mode command slash toggle bar",
        ),
        // Read-Only mode: toggle the active pane's input gate. No default chord — reachable
        // via the View menu (the app ships no Shell menu) + the command palette ("Read Only", also
        // `readonly` / `lock` / `freeze` / `view only` — the spec's accepted terms). `chord: nil` surfaces
        // the row WITHOUT binding a key (chord-less idiom — like `pane.rename` / `tab.close`); the user may
        // bind it in Settings → Keybindings. Pinned chord-less by `TreeCommandRoutingTests`.
        WorkspaceBinding(
            id: "view.readOnly", action: .toggleReadOnly, title: "Read Only",
            category: .view, chord: nil,
            symbol: "lock",
            keywords: "read only readonly lock freeze view only locked viewer input gate protect",
        ),
        // Secure Keyboard Entry: the MANUAL toggle for macOS process-global secure event input
        // over the active pane. No default chord — `chord: nil` surfaces the row in the menu + palette
        // WITHOUT binding a key (chord-less idiom — like `view.readOnly` / `pane.rename`); bindable in
        // Settings → Keybindings. Pinned chord-less by `TreeCommandRoutingTests`.
        WorkspaceBinding(
            id: "view.secureKeyboardEntry", action: .secureKeyboardEntry, title: "Secure Keyboard Entry",
            category: .view, chord: nil,
            symbol: "lock.shield",
            keywords: "secure input keyboard entry password sudo protect eavesdrop sniff secure event input",
        ),
        // Release Stuck Input: the remote-GUI escape hatch — synthesize key-up for ALL
        // modifiers + mouse-up for all buttons on the active video pane when the host is left holding input
        // (every release datagram of the loss-resilient burst lost). `chord: nil` (chord-less idiom);
        // palette/menu, bindable in Settings → Keybindings. A no-op for a non-video / read-only /
        // not-streaming active pane.
        WorkspaceBinding(
            id: "view.releaseStuckInput", action: .releaseStuckInput, title: "Release Stuck Input",
            category: .view, chord: nil,
            symbol: "keyboard.badge.ellipsis",
            keywords: "release stuck input modifier key mouse button unstick reset keyboard command shift remote window video",
        ),
        // Lock Viewport Position: ⌥⌘L freezes the active remote-GUI pane's edge-hover
        // auto-pan (the viewport stays put as the pointer nudges the pane edges — e.g. reaching for a
        // control that sits near an edge of an overflowing window). ⌥⌘L is FREE (`l` is otherwise only
        // ⌘⇧L Toggle Tabs Panel + ⌃⌘L Cycle Layout — different modifier sets) and ⌘-prefixed (§5).
        // Mirrors the footer lock button 1:1 (both flip ``RemoteWindowModel/viewportLocked``). Pinned
        // unique by the chord-uniqueness guard; a graceful no-op off a streaming video pane.
        WorkspaceBinding(
            id: "view.lockViewport", action: .toggleViewportLock, title: "Lock Viewport Position",
            category: .view, chord: KeyChord(character: "l", [.command, .option]),
            symbol: "lock.rectangle",
            keywords: "lock viewport position freeze edge pan auto pan hold pin content remote window video unlock",
        ),
        // Fit Viewport to Pane / Actual Size: discoverability twins of the footer [fit]/[1×] buttons —
        // reachable ONLY via that small control-bar icon cluster before this (docs audit finding #37).
        // `chord: nil` (chord-less idiom — like `view.readOnly` / `pane.rename`); bindable in
        // Settings → Keybindings. A graceful no-op off a streaming video pane, or while the viewport is
        // locked (mirrors the footer buttons' own disabled-while-locked gate).
        WorkspaceBinding(
            id: "view.fitViewportToPane", action: .fitViewportToPane, title: "Fit to Pane",
            category: .view, chord: nil,
            symbol: "rectangle.arrowtriangle.2.inward",
            keywords: "fit window pane zoom shrink grow whole visible remote video",
        ),
        WorkspaceBinding(
            id: "view.resetViewportZoom", action: .resetViewportZoom, title: "Actual Size",
            category: .view, chord: nil,
            symbol: "1.magnifyingglass",
            keywords: "actual size reset zoom 1x one to one native remote video",
        ),
        // Paste as Keystrokes: ⌥⌘V types the LOCAL clipboard into the active remote-GUI
        // pane's host window (paced per-key CGEvents — reaches a sudo / SecurityAgent secure field). ⌥⌘V is
        // FREE (`v` in NO other chord — plain ⌘V / ⌘⇧V never enter the registry, they belong to the
        // terminal's paste responder) and ⌘-prefixed (§5) so it's intercepted before a focused terminal.
        // Pinned unique by the chord-uniqueness guard. A no-op off a remote pane.
        WorkspaceBinding(
            id: "view.pasteAsKeystrokes", action: .pasteAsKeystrokes, title: "Paste as Keystrokes",
            category: .view, chord: KeyChord(character: "v", [.command, .option]),
            symbol: "keyboard",
            keywords: "paste keystrokes type clipboard local password sudo securityagent remote window video field secure",
        ),
        // Toggle Tabs Panel ⌘⇧L — the reference default (spec/reference__keybindings.md:66 "Toggle tabs
        // panel | ⌘⇧L"; line 201 "⌘⇧L … map to sidebar … toggles"). Deliberately NOT ⌘B: that chord only
        // reaches `store.toggleSidebarCollapsed()`, a flag the native split shell never reads (macOS collapse
        // is driven by `WorkspaceChromeState.sidebarCollapsed`) — binding ⌘B here would be a dead chord. ⌘⇧L
        // routes through a `toggleSidebar` shell closure onto the live chrome flag; the titlebar's own
        // toggle button actuates that SAME closure rather than binding ⌘⇧L a second time (single owner).
        // ⌘⇧L is FREE (no other `l` chord; ⌃⌘L is
        // Cycle Layout). Pinned by E1KeymapParityTests.
        WorkspaceBinding(
            id: "view.toggleSidebar", action: .toggleSidebar, title: "Toggle Tabs Panel",
            category: .view, chord: KeyChord(character: "l", [.command, .shift]),
            symbol: "sidebar.left", keywords: "sidebar sessions tabs panel rail hide show collapse",
        ),
        // Toggle Code Panel ⌘⇧R — the RIGHT sidebar (project-scoped embedded VS Code, a code-server
        // WKWebView; all panes of one project share the one instance at that project's root). ⌘⇧R
        // mirrors ⌘⇧L (the two panels flank the content column). ⌘⇧R is FREE: the historical "reserved
        // for Toggle Details" claim died with the Details column (no `view.toggleDetails` row exists),
        // and no other `r` chord is registered. Routed through a `toggleCodeSidebar` view-closure onto
        // the live `WorkspaceChromeState.codeSidebarCollapsed` (like the left panel — there is no store
        // flag to fall back to). Pinned by E1KeymapParityTests.
        WorkspaceBinding(
            id: "view.toggleCodeSidebar", action: .toggleCodeSidebar, title: "Toggle Code Panel",
            category: .view, chord: KeyChord(character: "r", [.command, .shift]),
            symbol: "chevron.left.forwardslash.chevron.right",
            keywords: "code panel vscode editor ide right sidebar hide show collapse code-server",
        ),
        // Switch Editor / Terminal Focus ⌥⌘R — the keyboard's way INTO the embedded editor and back
        // out (⌘⇧R only shows/hides the panel). It reads as one gesture in both directions, which
        // is why the title names the switch rather than one end of it. ⌥⌘R is FREE: `r` carries
        // ⌘⇧R (this panel's toggle) and ⌃⌘R (Reset Zoom) only. `.focus` category — it moves the
        // keyboard, exactly like the ⌃⌘arrow family beside it. Routed through a `focusCodePanel`
        // view-closure onto the macOS panel's webview pool; iOS installs no closure (documented
        // no-op). Inside the editor ⌃` and ⌘` reach the same action without appearing in this
        // table — see `WorkspaceKeyDispatcher.codePanelLocalAction`. Pinned by E1KeymapParityTests.
        WorkspaceBinding(
            id: "focus.codePanel", action: .focusCodePanel,
            title: "Switch Editor / Terminal Focus",
            category: .focus, chord: KeyChord(character: "r", [.command, .option]),
            symbol: "keyboard",
            keywords: "focus code panel editor vscode keyboard type into back terminal switch",
        ),
        // Pin Window ("View ▸ Pin Window" — `spec/user-interface__window-tab-split.md:14`
        // "keeps the window floating above all other apps' windows"). No default chord — `chord: nil`
        // surfaces the row WITHOUT binding a key (chord-less idiom — like `view.readOnly` / `pane.rename`);
        // bindable in Settings → Keybindings. The live macOS app flips `WorkspaceChromeState.pinned` →
        // `NSWindow.level = .floating` (window-scope; iOS has no window level — a documented no-op). Pinned
        // chord-less + `.view` by `WorkspaceBindingRoutingTests`.
        WorkspaceBinding(
            id: "view.pinWindow", action: .pinWindow, title: "Pin Window",
            category: .view, chord: nil,
            symbol: "pin",
            keywords: "pin window float floating always on top above keep front level stay topmost pip",
        ),
        // Blocks: the Command Navigator toggle + jump-to-block prev/next. ⌃⌘O / ⌃⌘[ / ⌃⌘] are all
        // ⌘-prefixed (the §5 conflict rule) and collision-free against the rest of the table (tab cycling
        // is ⌘[/], focus is ⌃⌘arrows — neither uses ⌃⌘bracket). They target the active terminal pane.
        WorkspaceBinding(
            id: "view.commandNavigator", action: .commandNavigator, title: "Command Navigator",
            category: .view, chord: KeyChord(character: "o", [.control, .command]),
            symbol: "list.bullet.rectangle", keywords: "blocks commands history recent navigator output jump warp",
        ),
        // Jump-To (`user-interface__outline.md`): ⌘J opens the floating Jump-To panel over the
        // active pane — detected paths/URLs + its OSC-133 command/prompt index, fuzzy-filterable, ↩ acts / ⌘K
        // opens the per-row actions popover. ⌘J is FREE (`j` is otherwise only ⌘⇧J peek-reply / ⌘⌥J). A VIEW
        // overlay (OverlayCoordinator), routed via a passed-in toggle closure like Global Search. Pinned
        // unique by the chord-uniqueness guard + `JumpToModelTests`.
        WorkspaceBinding(
            id: "view.jumpTo", action: .jumpTo, title: "Jump To…",
            category: .view, chord: KeyChord(character: "j", [.command]),
            symbol: "scope",
            keywords: "jump to outline quick switch goto navigate command url path link prompt current",
        ),
        // Hint Mode (`terminal-features__hint-mode`): the three "Hint to …" intents overlaying
        // 2-letter Vimium labels on the active pane's targets. ⌘⇧J Open + ⌘⇧Y Copy are the documented
        // defaults — ⌘⇧J is free for Hint Mode to own because `.peekAndReply` is bound to ⌘⌥J instead
        // (see `view.peekReply`); `y` is in NO other chord. Hint to Reveal is CHORD-LESS (`chord: nil` — palette/menu +
        // in-overlay action switch while hint mode is up; bindable in Settings — ⌘⇧R is free since the
        // Details panel was removed). Pinned unique by the chord-uniqueness guard.
        WorkspaceBinding(
            id: "view.hintOpen", action: .hintToOpen, title: "Hint to Open",
            category: .view, chord: KeyChord(character: "j", [.command, .shift]),
            symbol: "cursorarrow.rays",
            keywords: "hint mode open vimium label link path url file follow keyboard jump target",
        ),
        WorkspaceBinding(
            id: "view.hintCopy", action: .hintToCopy, title: "Hint to Copy",
            category: .view, chord: KeyChord(character: "y", [.command, .shift]),
            symbol: "doc.on.doc",
            keywords: "hint mode copy vimium label yank clipboard link path url text keyboard target",
        ),
        WorkspaceBinding(
            id: "view.hintReveal", action: .hintToReveal, title: "Hint to Reveal in Finder",
            category: .view, chord: nil,
            symbol: "folder",
            keywords: "hint mode reveal finder vimium label path file host keyboard target show",
        ),
        WorkspaceBinding(
            id: "view.jumpPreviousBlock", action: .jumpPreviousBlock, title: "Jump to Previous Block",
            category: .view, chord: KeyChord(character: "[", [.control, .command]),
            symbol: "chevron.up.circle", keywords: "previous prompt block command back up jump scroll osc133",
        ),
        WorkspaceBinding(
            id: "view.jumpNextBlock", action: .jumpNextBlock, title: "Jump to Next Block",
            category: .view, chord: KeyChord(character: "]", [.control, .command]),
            symbol: "chevron.down.circle", keywords: "next prompt block command forward down jump scroll osc133",
        ),
        // Re-run last command + jump-to-failed prev/next. ⌃⌘R / ⌃⌘⇧[ / ⌃⌘⇧] are all ⌘-prefixed (§5)
        // and collision-free: ⌃⌘R is otherwise unbound; ⌃⌘⇧[ / ⌃⌘⇧] add ⇧ to the block-jump chords, so
        // they are distinct from both ⌃⌘[ / ⌃⌘] (block jump) and ⌘[ / ⌘] (tab cycling).
        WorkspaceBinding(
            id: "view.reRunLastCommand", action: .reRunLastCommand, title: "Re-run Last Command",
            category: .view, chord: KeyChord(character: "r", [.control, .command]),
            symbol: "arrow.clockwise", keywords: "rerun repeat replay again last command block execute",
        ),
        WorkspaceBinding(
            id: "view.jumpPreviousFailed", action: .jumpPreviousFailed, title: "Jump to Previous Failed",
            category: .view, chord: KeyChord(character: "[", [.control, .command, .shift]),
            symbol: "chevron.up.2", keywords: "previous failed error nonzero exit block jump back up",
        ),
        WorkspaceBinding(
            id: "view.jumpNextFailed", action: .jumpNextFailed, title: "Jump to Next Failed",
            category: .view, chord: KeyChord(character: "]", [.control, .command, .shift]),
            symbol: "chevron.down.2", keywords: "next failed error nonzero exit block jump forward down",
        ),
        // Viewport scroll: the named-key chords ⇧PageUp/PageDown (page scroll) + ⇧Home/End
        // (buffer ends). These are the ONE exemption to the §5 "every chord ⌘/⌥-prefixed" rule — a ⇧-prefixed
        // NAMED key (PageUp/Home/End) cannot steal a printable terminal letter (pinned by the prefix test's
        // named-key exemption). Distinct from copy-mode's half-page scroll. Target the active terminal pane.
        WorkspaceBinding(
            id: "view.scrollPageUp", action: .scrollPageUp, title: "Scroll Page Up",
            category: .view, chord: KeyChord(.pageUp, [.shift]),
            symbol: "arrow.up.to.line", keywords: "scroll page up viewport scrollback older terminal",
        ),
        WorkspaceBinding(
            id: "view.scrollPageDown", action: .scrollPageDown, title: "Scroll Page Down",
            category: .view, chord: KeyChord(.pageDown, [.shift]),
            symbol: "arrow.down.to.line", keywords: "scroll page down viewport scrollback newer terminal",
        ),
        WorkspaceBinding(
            id: "view.scrollTop", action: .scrollToTop, title: "Scroll to Top",
            category: .view, chord: KeyChord(.home, [.shift]),
            symbol: "arrow.up.to.line.compact", keywords: "scroll top buffer beginning start scrollback terminal",
        ),
        WorkspaceBinding(
            id: "view.scrollBottom", action: .scrollToBottom, title: "Scroll to Bottom",
            category: .view, chord: KeyChord(.end, [.shift]),
            symbol: "arrow.down.to.line.compact", keywords: "scroll bottom buffer end newest scrollback terminal",
        ),
        // Command jumps: ⌘PageUp/PageDown jump the viewport to the previous / next shell
        // prompt — they REUSE the OSC-133 command-jump (`jumpToBlockInActivePane(∓1)`), NOT raw scroll.
        WorkspaceBinding(
            id: "view.cmdJumpPrev", action: .commandJumpPrev, title: "Jump to Previous Command",
            category: .view, chord: KeyChord(.pageUp, [.command]),
            symbol: "chevron.up.circle", keywords: "jump previous command prompt block osc133 up",
        ),
        WorkspaceBinding(
            id: "view.cmdJumpNext", action: .commandJumpNext, title: "Jump to Next Command",
            category: .view, chord: KeyChord(.pageDown, [.command]),
            symbol: "chevron.down.circle", keywords: "jump next command prompt block osc133 down",
        ),
        // Font size: ⌘= bumps, ⌘- shrinks, ⌘0 resets. ⌘0 is FREE (select-tab digits start at
        // ⌘1). The `+` glyph (⌘+) does NOT fold onto `=` for free — on a US/ANSI layout ⌘+ arrives as `+`+⇧
        // (or keypad `+`), which `charactersIgnoringModifiers` keys as a DISTINCT chord — so ``aliasChords``
        // adds those two spellings → `.increaseFontSize` (no extra display row). A font-size step resizes the
        // cell box, so FEWER/MORE cells fit and the remote PTY grid REFLOWS (SIGWINCH) — NOT a glyph-only
        // rescale. Target the active terminal pane.
        WorkspaceBinding(
            id: "view.fontIncrease", action: .increaseFontSize, title: "Increase Font Size",
            category: .view, chord: KeyChord(character: "=", [.command]),
            symbol: "textformat.size.larger", keywords: "font size increase bigger larger zoom in plus text",
        ),
        WorkspaceBinding(
            id: "view.fontDecrease", action: .decreaseFontSize, title: "Decrease Font Size",
            category: .view, chord: KeyChord(character: "-", [.command]),
            symbol: "textformat.size.smaller", keywords: "font size decrease smaller minus text zoom out",
        ),
        WorkspaceBinding(
            id: "view.fontReset", action: .resetFontSize, title: "Reset Font Size",
            category: .view, chord: KeyChord(character: "0", [.command]),
            symbol: "textformat.size", keywords: "font size reset default actual original zero text",
        ),
        // Open Quickly: ⌘⇧O fuzzy file/symbol switcher. ⌘⇧O is FREE (the only
        // other `o` chord is ⌃⌘O command navigator). A routable stub for now — never a dead chord.
        WorkspaceBinding(
            id: "view.openQuickly", action: .openQuickly, title: "Open Quickly…",
            category: .view, chord: KeyChord(character: "o", [.command, .shift]),
            symbol: "magnifyingglass.circle", keywords: "open quickly fuzzy file symbol switcher jump goto",
        ),
    ]

    /// The ⌘1…⌘9 "select pane N" bindings (generated, kept out of the main table for readability). One
    /// per digit; carried so the chord table is complete + the conflict / prefix guards see them.
    public static let selectPaneBindings: [WorkspaceBinding] = (1...9).map { n in
        WorkspaceBinding(
            id: "pane.select.\(n)", action: .selectPane(n),
            title: "Select Pane \(n)", category: .panes,
            chord: KeyChord(character: Character("\(n)"), [.command]),
            symbol: "\(n).square", keywords: "switch jump pane tab \(n)",
        )
    }

    /// Every binding the registry knows — the main table plus the nine ⌘-digit select-pane chords. The
    /// chord-table guards (uniqueness, ⌘/⌥-prefix) run over this full set.
    ///
    /// `let`, and the `let` is load-bearing. As a computed `var` this concatenation ran on every read,
    /// and its readers are the keyboard's: `resolvedChordTable` walks it once per key event and called
    /// ``binding(for:)`` per row, which read it AGAIN — 86 fresh 85-element arrays per keystroke, each
    /// retaining four strings per element. Measured at 210µs of allocation per key event on an M-series
    /// Mac, all of it to rebuild a table whose inputs cannot change. `rust/slopdesk-invariants` pins
    /// the `let` because a `var` here costs nothing a test can see.
    public static let allBindings: [WorkspaceBinding] = bindings + selectPaneBindings

    /// The binding for `action`, or `nil` if unregistered.
    ///
    /// A hash lookup rather than the linear scan it was, and FIRST-WINS the way `first(where:)` was:
    /// nothing in the table repeats an action today, but the collapsed ⌘1…⌘9 representative shares
    /// `.selectPane(1)` with the generated row, so "the first row that claims it" is the rule this
    /// answers by rather than a coincidence it relies on.
    public static func binding(for action: WorkspaceAction) -> WorkspaceBinding? {
        byAction[action]
    }

    /// ``binding(for:)``'s index, built once. Private because the ORDER is the registry's, and a
    /// caller that wanted the mapping would be asking for the array.
    private static let byAction: [WorkspaceAction: WorkspaceBinding] = {
        var index: [WorkspaceAction: WorkspaceBinding] = [:]
        index.reserveCapacity(allBindings.count)
        for binding in allBindings where index[binding.action] == nil { index[binding.action] = binding }
        return index
    }()

    /// Extra chord → action ALIASES that fire an existing action from a SECOND chord WITHOUT minting a
    /// display row (so the cheat sheet / palette / menu still show the ONE canonical binding). Folded into
    /// ``chordTable`` + ``resolvedChordTable`` so the dispatcher resolves them, but NOT into ``allBindings``
    /// / ``groupedForDisplay`` — the chord-uniqueness guard runs over `allBindings`, so an alias is
    /// intentionally outside it (it shares its ACTION, not its chord, with the canonical row).
    ///
    /// The font-increase chord is canonically ⌘= (no ⇧), but the muscle-memory chord is the `+`
    /// glyph (`⌘+`). On a US/ANSI layout `+` IS Shift-`=`, and `charactersIgnoringModifiers` ignores ⌘/⌥/⌃
    /// but NOT ⇧ — so pressing ⌘+ delivers `"+"` with ⇧ set, i.e. `KeyChord(character: "+", [.command,
    /// .shift])`, NOT ⌘=. Without this alias that chord is unbound and ⌘+ leaks to the PTY (font never grows).
    /// We alias BOTH spellings the OS can deliver for ⌘+: the shifted main-row `+` (`⌘⇧+`) and the (unshifted)
    /// keypad `+` (`⌘+`). `KeyChord.init(character:)` lower-cases, a no-op for `+`, so both key cleanly.
    ///
    /// The documented Vi Mode entry chord is ⌃⇧Space. slopdesk's canonical Vi-Mode
    /// binding (`view.copyMode`) DISPLAYS ⌘⇧C, so ⌃⇧Space is folded in as a SECOND resolving chord onto the
    /// same `.toggleCopyMode` action — like the ⌘+ font-increase alias (no display row, shares the ACTION not
    /// the chord). Space is the NAMED `.space` key (the macOS normalizer maps keyCode 49 → `.space` only with
    /// a non-shift modifier, so a bare Space still types); ⌃⇧Space is otherwise unbound (no collision).
    public static let aliasChords: [KeyChord: WorkspaceAction] = [
        KeyChord(character: "+", [.command, .shift]): .increaseFontSize, // ⌘+ = ⌘⇧= on a US/ANSI layout
        KeyChord(character: "+", [.command]): .increaseFontSize, // keypad + (no ⇧ reported)
        KeyChord(.space, [.control, .shift]): .toggleCopyMode, // ⌃⇧Space = Vi Mode entry (alias of ⌘⇧C)
    ]

    /// The chord → action lookup table (drives the keyboard dispatcher). Built from ``allBindings`` (so the
    /// keyboard layer reads the SAME source as the menu/palette/cheat sheet) plus ``aliasChords`` (extra
    /// chords that fire an existing action without a display row).
    public static var chordTable: [KeyChord: WorkspaceAction] {
        var map: [KeyChord: WorkspaceAction] = [:]
        for binding in allBindings {
            if let chord = binding.chord { map[chord] = binding.action }
        }
        // Aliases never overwrite a real binding (they target an existing action from a free second chord),
        // but fold them AFTER so the table is the union the dispatcher resolves.
        for (chord, action) in aliasChords where map[chord] == nil { map[chord] = action }
        return map
    }

    // MARK: - Glyph rendering (chord → human string) — the cheat sheet / palette display

    /// Renders a ``KeyChord`` as a human reads it, asked of `slopdesk_terminal::keybind` — the same
    /// module that writes the chord's canonical config text, so the menu, the palette and the cheat
    /// sheet all print what one rule says a chord is called. `nonisolated` (no view / actor) so it
    /// composes from any context.
    /// The retry is not ceremony. ``glyphCapacity`` is a GUESS, and the door's contract (docs/55 §4)
    /// is that an answer larger than the buffer leaves it UNTOUCHED and reports the size. This used
    /// to read `out.prefix(max(0, written))` off that untouched buffer, so a glyph that overflowed
    /// came back as thirty-two zero bytes — an empty string, in the one place a chord is shown to
    /// the user, with no error anywhere. Asking again at the size the door named is the whole fix,
    /// and it costs nothing on any chord that fits.
    public nonisolated static func glyph(_ chord: KeyChord) -> String {
        var token = chord.key.canonicalToken
        return token.withUTF8 { key -> String in
            func render(into out: inout [UInt8]) -> Int {
                out.withUnsafeMutableBufferPointer { rendered in
                    slopdesk_keybind_glyph(
                        key.baseAddress,
                        key.count,
                        chord.modifiers.contains(.command),
                        chord.modifiers.contains(.shift),
                        chord.modifiers.contains(.option),
                        chord.modifiers.contains(.control),
                        rendered.baseAddress,
                        rendered.count,
                    )
                }
            }
            var out = [UInt8](repeating: 0, count: glyphCapacity)
            var written = render(into: &out)
            if written > out.count {
                out = [UInt8](repeating: 0, count: written)
                written = render(into: &out)
                // The second answer cannot disagree with the first — the door is pure — so a short
                // fill here means the two calls saw different memory, and none of it is readable.
                guard written == out.count else { return "" }
            }
            guard written > 0 else { return "" }
            return String(bytes: out.prefix(written), encoding: .utf8) ?? ""
        }
    }

    /// Four modifier glyphs at three bytes each plus a key — enough for every chord the platform
    /// delivers, which is why it is the FIRST guess and not a limit. A key name longer than this
    /// costs a second call, not a truncated glyph.
    private nonisolated static let glyphCapacity = 32

    /// The display glyph for `action`'s default binding, or `nil` when it has none. `public` so the
    /// rebuilt ClientUI palette derives its row hints from the SAME registry the keyboard bank registers
    /// (no drift).
    public nonisolated static func glyph(for action: WorkspaceAction) -> String? {
        guard let binding = binding(for: action) else { return nil }
        return binding.chord.map(glyph)
    }

    // MARK: - Grouped display (the cheat sheet sections + palette catalog order)

    /// The bindings grouped by category in display order (panes, tabs, focus, view), with the
    /// nine ⌘-digit select-pane chords collapsed into ONE representative "⌘1…⌘9" row SYNTHESIZED here (see
    /// ``selectPaneRepresentative``) and appended to the Panes group — the real per-digit chords live only
    /// in ``selectPaneBindings`` (keyboard bank / chord table), never in this display set. The menu builds
    /// its own "Select Pane" submenu and the palette catalog omits the digits, so this synthesized row is
    /// the only place the family surfaces in the cheat sheet. The SINGLE source the cheat sheet renders and
    /// the palette catalog iterates — so they cannot drift.
    /// `public` so the rebuilt ClientUI cheat-sheet overlay generates its rows from this one table.
    public static var groupedForDisplay: [(category: WorkspaceAction.Category, bindings: [WorkspaceBinding])] {
        WorkspaceAction.Category.allCases.compactMap { category in
            var rows = bindings.filter { $0.category == category }
            if category == .panes {
                rows.append(selectPaneRepresentative) // the collapsed ⌘1…⌘9 row the comments promise
            }
            guard !rows.isEmpty else { return nil }
            return (category, rows)
        }
    }

    /// The single collapsed representative for the nine generated ⌘1…⌘9 select-pane chords (display only —
    /// the real per-digit chords live in ``selectPaneBindings``). `.selectPane(1)` is a stand-in action; the
    /// glyph range is hand-rendered into the title because one ``KeyChord`` can't represent the range, and
    /// `chord: nil` keeps the overlay from rendering a separate (single-chord) hint chip.
    public static let selectPaneRepresentative = WorkspaceBinding(
        id: "pane.selectN", action: .selectPane(1),
        title: "Select Pane (⌘1…⌘9)", category: .panes,
        chord: nil, symbol: "number.square",
        keywords: "switch jump pane tab number digit 1 2 3 4 5 6 7 8 9",
    )
}
