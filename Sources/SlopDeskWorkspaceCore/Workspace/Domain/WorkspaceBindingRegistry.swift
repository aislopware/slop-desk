import Foundation

// MARK: - WorkspaceAction (the tree-native command intent)

/// A tree-native workspace action — the intent the IDE-shell keyboard / menu / palette / cheat sheet
/// produce, routed to the matching ``WorkspaceStore`` TREE op by ``WorkspaceBindingRegistry`` (docs/42
/// §W6). The `Session → Tab → Pane` redesign's command vocabulary; distinct from the retained-but-dead
/// canvas ``WorkspaceCommand`` (still routed in `.canvas` mode) — the tree has split-right/down, tabs,
/// and sessions the flat canvas never had.
///
/// A pure value enum (no SwiftUI / store import) so the chord → action mapping is unit-testable with no
/// view.
public enum WorkspaceAction: Hashable, Sendable {
    // Panes
    case splitRight // ⌘D  — split the active pane into a side-by-side column
    case splitDown // ⌘⇧D — split the active pane into a stacked row
    case splitLeft // ⌘⌥D — split the active pane, inserting the new pane on the LEADING (left) side
    case splitUp // ⌘⌥⇧D — split the active pane, inserting the new pane on the LEADING (top) side
    case closePane // ⌘W  — close the active pane (cascades the tab/session)
    case renamePane // no default chord — renames the active TAB on the tree shell (inline tab-strip
    // field), or the active pane on the retained-but-dead canvas path. Title menu / context menu / palette only.
    case breakPaneToTab // ⌃⌘T — eject the active pane into a new tab

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
    // Paste as Keystrokes: ⌥⌘V types the LOCAL clipboard into the ACTIVE remote-GUI
    // pane's host window as paced per-key CGEvents (the path that reaches a sudo / SecurityAgent secure
    // field) — since a plain ⌘V forwards a raw Cmd+V that pastes the HOST clipboard. A no-op for a
    // terminal (own paste pipeline) / empty / read-only pane.
    case pasteAsKeystrokes
    case toggleSidebar // ⌘⇧L — show/hide the sessions sidebar
    // Host Windows rail (docs/45): ⌘⇧R shows/hides the RIGHT sidebar listing the host machine's
    // windows (mirror-twin of the left rail; ⌘⇧R is free since the Details panel was removed).
    // Window-scope → needs no active pane; routed through a view closure onto
    // `WorkspaceChromeState.hostRailCollapsed` like `.toggleSidebar`.
    case toggleHostWindows // ⌘⇧R — show/hide the host-windows rail
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
    // CHORD-LESS (⌘⇧R is reserved for Toggle Details — see `view.toggleDetails`) so palette/menu-surfaced +
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
    case nextTab // ⌘⇧]
    case prevTab // ⌘⇧[
    case selectTab(Int) // ⌘1…⌘9 (1-based)
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
    /// and the menu can grey it out) — mirrors ``WorkspaceCommand/requiresFocusedPane``.
    var requiresActivePane: Bool {
        switch self {
        case .splitRight,
             .splitDown,
             .splitLeft, // splits the active pane — needs one
             .splitUp,
             .closePane,
             .renamePane,
             .breakPaneToTab,
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
             .nextTab,
             .prevTab,
             .selectTab,
             .closeTab,
             .closeWindow, // closes the whole window (→ Session) — a window-scope action, needs no active pane
             .reopenClosed, // restores a closed pane into the active tab — acts on history, not a live pane
             .toggleSidebar,
             .toggleHostWindows, // window-scope chrome toggle — needs no active pane (like the sidebar toggle)
             .pinWindow, // a window-scope NSWindow.level toggle — needs no active pane (like the sidebar toggle)
             .openQuickly, // a global fuzzy switcher — needs no active pane
             .toggleSyncInput, // the tab must exist, but the palette can still show it (mirrors .newTab)
             .jumpToAttention, // acts globally across all tabs/sessions — needs no active pane
             .peekAndReply: // acts globally (targets the oldest attention pane) — needs no active pane
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
    /// For a multi-key binding this is the FIRST chord (the prefix); ``sequence`` carries the full list.
    public let chord: KeyChord?
    /// The default multi-key SEQUENCE (tmux/zellij prefix idiom — e.g. `⌃A` then `D`), or `nil` for a
    /// single-chord / palette-only binding. When set, ``chord`` mirrors `sequence.head` so the existing
    /// single-chord glyph / menu-shortcut derivation keeps working off `chord` and the prefix dispatcher
    /// reads the full sequence. The single source of truth for "what fires this" is ``effectiveSequence``.
    public let sequence: KeySequence?
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
        sequence: KeySequence? = nil,
        symbol: String,
        keywords: String? = nil,
    ) {
        self.id = id
        self.action = action
        self.title = title
        self.category = category
        // Keep `chord` in lock-step with a multi-key sequence's head so single-chord consumers (menu /
        // palette glyph) keep working without knowing about sequences.
        self.chord = sequence?.head ?? chord
        self.sequence = sequence
        self.symbol = symbol
        self.keywords = keywords
    }

    /// The full key sequence that fires this binding: the explicit ``sequence`` if multi-key, else a
    /// length-1 sequence wrapping ``chord``, else `nil` (palette-only). The ONE accessor the prefix
    /// dispatcher + conflict detection read so single and multi-key bindings are handled uniformly.
    public var effectiveSequence: KeySequence? {
        if let sequence { return sequence }
        if let chord { return KeySequence(single: chord) }
        return nil
    }
}

// MARK: - WorkspaceBindingRegistry (the ONE source of truth)

/// The single source of truth for the IDE-shell command surface (docs/42 §W6): ONE ``bindings`` table
/// that the menu bar (``WorkspaceCommands``), the ⌘⇧P command palette (``CommandPaletteView``), the ⌘/
/// cheat sheet (``KeyboardCheatSheet``), and the routing tests ALL read — so chord, menu item, palette
/// row, and cheat-sheet glyph can never drift (and settings has one table to make user-editable).
///
/// Every chord is ⌘- or ⌥-prefixed (the load-bearing §5 conflict rule: a bare key / Ctrl-letter falls
/// through to the focused terminal), and no two bindings share a chord — both pinned by
/// `TreeCommandRoutingTests`. The chords follow the reference keymap: ⌘T new tab, ⌘W close, ⌘D
/// split-right, ⌘⇧D split-down, ⌃⌘+arrows focus, ⌘⇧↩ zoom, ⌘⇧]/⌘⇧[ next/prev tab, ⌘1…9 select tab,
/// ⌘⇧L toggle Tabs panel, ⌃⌘T break-pane-to-tab, ⌘⇧P palette,
/// ⌘/ cheat sheet. Rename has no default chord — menu / palette / context-menu only (`chord: nil`).
public enum WorkspaceBindingRegistry {
    /// The shipped binding table, in cheat-sheet / palette display order (panes, tabs, focus,
    /// view). `.selectTab(n)` for n=1…9 is generated (one chord each) but is NOT listed here — it is
    /// expanded by ``selectTabBindings`` so the table stays readable; the cheat sheet collapses the nine
    /// slots to one representative row synthesized in ``groupedForDisplay`` (the menu builds its own "Select
    /// Tab" submenu, the palette catalog omits the digits).
    public static let bindings: [WorkspaceBinding] = [
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
        // closed-pane LIFO + restore are future work; this route is a documented graceful no-op (no dead chord).
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
        // routes through a `toggleSidebar` view-closure onto the live chrome flag; the titlebar keeps no
        // separate SwiftUI ⌘⇧L shortcut of its own (single owner). ⌘⇧L is FREE (no other `l` chord; ⌃⌘L is
        // Cycle Layout). Pinned by E1KeymapParityTests.
        WorkspaceBinding(
            id: "view.toggleSidebar", action: .toggleSidebar, title: "Toggle Tabs Panel",
            category: .view, chord: KeyChord(character: "l", [.command, .shift]),
            symbol: "sidebar.left", keywords: "sidebar sessions tabs panel rail hide show collapse",
        ),
        // Host Windows rail ⌘⇧R (docs/45): the RIGHT sidebar listing the host machine's windows —
        // the mirror twin of ⌘⇧L. ⌘⇧R is FREE since the Details panel was removed (`r` is otherwise
        // only ⌃⌘R re-run); routes through a `toggleHostWindows` view-closure onto the live
        // `WorkspaceChromeState.hostRailCollapsed`, exactly the `view.toggleSidebar` shape.
        WorkspaceBinding(
            id: "view.hostWindows", action: .toggleHostWindows, title: "Toggle Host Windows",
            category: .view, chord: KeyChord(character: "r", [.command, .shift]),
            symbol: "sidebar.right",
            keywords: "host windows rail right sidebar panel remote list apps stream hide show collapse",
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

    /// The ⌘1…⌘9 "select tab N" bindings (generated, kept out of the main table for readability). One per
    /// digit; carried so the chord table is complete + the conflict / prefix guards see them.
    public static let selectTabBindings: [WorkspaceBinding] = (1...9).map { n in
        WorkspaceBinding(
            id: "tab.select.\(n)", action: .selectTab(n),
            title: "Select Tab \(n)", category: .tabs,
            chord: KeyChord(character: Character("\(n)"), [.command]),
            symbol: "\(n).square", keywords: "switch jump tab \(n)",
        )
    }

    /// Every binding the registry knows — the main table plus the nine ⌘-digit select-tab chords. The
    /// chord-table guards (uniqueness, ⌘/⌥-prefix) run over this full set.
    public static var allBindings: [WorkspaceBinding] { bindings + selectTabBindings }

    /// The binding for `action`, or `nil` if unregistered.
    public static func binding(for action: WorkspaceAction) -> WorkspaceBinding? {
        allBindings.first { $0.action == action }
    }

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
    /// chords that fire an existing action without a display row). For a multi-key binding this maps its
    /// PREFIX (head) chord — the prefix dispatcher then walks the rest via ``sequenceTable``.
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

    /// The full key SEQUENCE → action lookup table (single AND multi-key). The prefix state machine reads
    /// this to resolve a completed sequence; a single-chord binding appears as its length-1 sequence so one
    /// table serves both. Built from ``allBindings`` (the same source as everything else).
    public static var sequenceTable: [KeySequence: WorkspaceAction] {
        var map: [KeySequence: WorkspaceAction] = [:]
        for binding in allBindings {
            if let seq = binding.effectiveSequence { map[seq] = binding.action }
        }
        return map
    }

    // MARK: - Glyph rendering (chord → human string) — the cheat sheet / palette display

    /// Renders a ``KeyChord`` in native modifier-glyph order (⌃⌥⇧⌘ + key) — the same form the canvas
    /// palette uses, kept here as the registry's own pure renderer so the menu/palette/cheat sheet read
    /// ONE place. `nonisolated` (no view / actor) so it composes from any context.
    public nonisolated static func glyph(_ chord: KeyChord) -> String {
        var out = ""
        if chord.modifiers.contains(.control) { out += "⌃" }
        if chord.modifiers.contains(.option) { out += "⌥" }
        if chord.modifiers.contains(.shift) { out += "⇧" }
        if chord.modifiers.contains(.command) { out += "⌘" }
        out += keyGlyph(chord.key)
        return out
    }

    /// Renders a ``KeySequence`` as space-separated chord glyphs (e.g. `⌃A D` for the prefix-then-key
    /// idiom). A length-1 sequence renders exactly like ``glyph(_:)`` of its single chord, so the cheat
    /// sheet / palette show one string for both single and multi-key bindings. `nonisolated` so it composes
    /// from any context.
    public nonisolated static func glyph(_ sequence: KeySequence) -> String {
        sequence.chords.map(glyph).joined(separator: " ")
    }

    /// The display glyph for `action`'s default binding, or `nil` when it has none. Renders the full
    /// SEQUENCE (so a multi-key prefix binding shows e.g. `⌃A D`), falling back to the single chord for an
    /// ordinary binding. `public` so the rebuilt ClientUI palette derives its row hints from the SAME
    /// registry the keyboard bank registers (no drift).
    public nonisolated static func glyph(for action: WorkspaceAction) -> String? {
        guard let binding = binding(for: action) else { return nil }
        if let seq = binding.sequence { return glyph(seq) }
        return binding.chord.map(glyph)
    }

    private nonisolated static func keyGlyph(_ key: KeyChord.Key) -> String {
        switch key {
        case let .character(c): c.uppercased()
        case .tab: "⇥"
        case .return: "↩"
        case .space: "␣"
        case .leftArrow: "←"
        case .rightArrow: "→"
        case .upArrow: "↑"
        case .downArrow: "↓"
        // Named navigation keys — the macOS-native menu glyphs (⇞ PageUp, ⇟ PageDown, ↖ Home, ↘ End).
        case .pageUp: "⇞"
        case .pageDown: "⇟"
        case .home: "↖"
        case .end: "↘"
        }
    }

    // MARK: - Grouped display (the cheat sheet sections + palette catalog order)

    /// The bindings grouped by category in display order (panes, tabs, focus, view), with the
    /// nine ⌘-digit select-tab chords collapsed into ONE representative "⌘1…⌘9" row SYNTHESIZED here (see
    /// ``selectTabRepresentative``) and appended to the Tabs group — the real per-digit chords live only in
    /// ``selectTabBindings`` (keyboard bank / chord table), never in this display set. The menu builds its
    /// own "Select Tab" submenu and the palette catalog omits the digits, so this synthesized row is the
    /// only place the family surfaces in the cheat sheet. The SINGLE source the cheat sheet renders and the
    /// palette catalog iterates — so they cannot drift.
    /// `public` so the rebuilt ClientUI cheat-sheet overlay generates its rows from this one table.
    public static var groupedForDisplay: [(category: WorkspaceAction.Category, bindings: [WorkspaceBinding])] {
        WorkspaceAction.Category.allCases.compactMap { category in
            var rows = bindings.filter { $0.category == category }
            if category == .tabs {
                rows.append(selectTabRepresentative) // the collapsed ⌘1…⌘9 row the comments promise
            }
            guard !rows.isEmpty else { return nil }
            return (category, rows)
        }
    }

    /// The single collapsed representative for the nine generated ⌘1…⌘9 select-tab chords (display only —
    /// the real per-digit chords live in ``selectTabBindings``). `.selectTab(1)` is a stand-in action; the
    /// glyph range is hand-rendered into the title because one ``KeyChord`` can't represent the range, and
    /// `chord: nil` keeps the overlay from rendering a separate (single-chord) hint chip.
    public static let selectTabRepresentative = WorkspaceBinding(
        id: "tab.selectN", action: .selectTab(1),
        title: "Select Tab (⌘1…⌘9)", category: .tabs,
        chord: nil, symbol: "number.square",
        keywords: "switch jump tab number digit 1 2 3 4 5 6 7 8 9",
    )
}
