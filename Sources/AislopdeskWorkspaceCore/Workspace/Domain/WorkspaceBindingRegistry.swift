import Foundation

// MARK: - WorkspaceAction (the tree-native command intent)

/// A tree-native workspace action — the intent the IDE-shell keyboard / menu / command-palette / cheat
/// sheet all produce, routed to the matching ``WorkspaceStore`` TREE op by ``WorkspaceBindingRegistry``
/// (docs/42 §W6). It is the `Session → Tab → Pane` redesign's command vocabulary, distinct from the
/// retained-but-dead canvas ``WorkspaceCommand`` (which the registry still routes to in `.canvas` mode):
/// the tree has split-right/down, tabs, and sessions the flat canvas never had.
///
/// A pure value enum (no SwiftUI / store import) so the chord → action mapping is fully unit-testable
/// with no view — exactly as ``WorkspaceCommand`` is.
public enum WorkspaceAction: Hashable, Sendable {
    // Panes
    case splitRight // ⌘D  — split the active pane into a side-by-side column
    case splitDown // ⌘⇧D — split the active pane into a stacked row
    case splitLeft // ⌘⌥D — split the active pane, inserting the new pane on the LEADING (left) side
    case splitUp // ⌘⌥⇧D — split the active pane, inserting the new pane on the LEADING (top) side
    case closePane // ⌘W  — close the active pane (cascades the tab/session)
    case renamePane // (no otty default chord) — rename the active TAB on the tree shell (opens its
    // tab-strip inline field); the active canvas pane on the retained-but-dead canvas path. Reachable from
    // the title menu / context menu / palette only (otty ships no rename chord — ⌘⇧R is Toggle Details).
    case breakPaneToTab // ⌃⌘T — eject the active pane into a new tab
    case toggleFloat // ⌘⇧F — float / embed the active pane (zellij toggle-float)
    case spawnFloating // ⌃⌘F — spawn a new floating scratch pane

    // Move pane (Zellij "move pane" — swap with the geometric neighbour)
    case movePaneLeft // ⌥⌘⇧←
    case movePaneRight // ⌥⌘⇧→
    case movePaneUp // ⌥⌘⇧↑
    case movePaneDown // ⌥⌘⇧↓

    // Resize pane (keyboard divider nudge — grow right/down, shrink left/up)
    case resizePaneLeft // ⌃⌘←
    case resizePaneRight // ⌃⌘→
    case resizePaneUp // ⌃⌘↑
    case resizePaneDown // ⌃⌘↓

    // Balance (tmux even-layout)
    case balancePanes // ⌃⌘=

    // Layouts (tmux/zellij select-layout — re-tile the active tab's panes)
    case cycleLayout // ⌃⌘L — step through the algorithmic layout presets
    case applyLayout(WorkspaceTreeOps.LayoutPreset) // a named preset (menu/palette only — no chord)

    // Focus
    case focusLeft // ⌥⌘←
    case focusRight // ⌥⌘→
    case focusUp // ⌥⌘↑
    case focusDown // ⌥⌘↓
    case cyclePaneNext // ⌘]  — sequentially focus the NEXT pane in the active tab (DFS order, wraps)
    case cyclePanePrev // ⌘[  — sequentially focus the PREVIOUS pane in the active tab (DFS order, wraps)

    // View
    case toggleZoom // ⌥⌘↩ — maximize / restore the active pane (render-only)
    case commandPalette // ⌘⇧P — show/hide the command palette (otty's documented default)
    case cheatSheet // ⌘/ — show/hide the keyboard cheat sheet
    case find // ⌘F — show/hide the find-in-terminal bar over the active pane (W14 #5)
    case toggleCopyMode // ⌘⇧C — enter modal keyboard copy-mode over the active pane's scrollback (P5b)
    case toggleSidebar // ⌘⇧L — show/hide the sessions sidebar (otty "Toggle Tabs Panel")
    case toggleDetailsPanel // ⌘⇧R — show/hide the right-hand Details / inspector panel (otty parity)
    case openQuickly // ⌘⇧O — open the fuzzy "open quickly" file/symbol switcher (E11 stub)

    // View — viewport scroll (E1 ES-E1-3; named-key chords — the §5 prefix exemption)
    case scrollPageUp // ⇧PageUp — scroll the active pane one page toward older scrollback
    case scrollPageDown // ⇧PageDown — scroll the active pane one page toward newer output
    case scrollToTop // ⇧Home — jump the viewport to the top of the scrollback buffer
    case scrollToBottom // ⇧End — jump the viewport to the bottom (newest) of the buffer
    case commandJumpPrev // ⌘PageUp — jump to the PREVIOUS shell prompt (reuses jumpToBlock(-1))
    case commandJumpNext // ⌘PageDown — jump to the NEXT shell prompt (reuses jumpToBlock(+1))

    // View — font size (E1 ES-E1-4; libghostty render-only, no PTY reflow)
    case increaseFontSize // ⌘= / ⌘+ — bump the active pane's render font size (⌘+ via `aliasChords`)
    case decreaseFontSize // ⌘- — shrink the active pane's render font size
    case resetFontSize // ⌘0 — reset the active pane's render font size to the configured default

    // Blocks (WB2 — Warp-style per-command blocks)
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
    case closeTab // ⌘⇧W — close the active tab (all its panes)
    case reopenClosed // ⌘⇧T — reopen the most recently closed pane (browser idiom; E3 stub)

    // Sessions
    case newSession // ⌃⌘N

    // Synchronized input (Zellij ToggleActiveSyncTab)
    case toggleSyncInput // ⌘⇧I — broadcast keystrokes to every other pane in the active tab

    // Supervision (P3 — jump to the pane that needs you)
    case jumpToAttention // ⌘⇧U — focus the oldest pane needing attention (needsPermission first, then done)

    // Supervision (P4 — answer the blocked pane INLINE without a context switch)
    case peekAndReply // ⌘⇧J — open the Peek & Reply overlay over the oldest pane needing attention

    // Agents (E1-registered; the behaviour lands in later epics — these are routable stubs, never dead chords)
    case composer // ⌘⇧E — open the agent prompt composer (E12 stub)
    case promptQueue // ⌘⇧M — open the agent prompt queue (E12 stub)
    case sendToChat // ⌘⌃↩ — send the active pane's selection / command to the agent chat (E13 stub)
}

public extension WorkspaceAction {
    /// The display category the cheat sheet groups by (and the menu/palette sections mirror).
    enum Category: String, Sendable, CaseIterable {
        case panes = "Panes"
        case tabs = "Tabs"
        case sessions = "Sessions"
        case focus = "Focus"
        case view = "View"
        // Agent-facing verbs (composer / prompt queue / send-to-chat). Last in display order so the
        // agent section sits below the terminal/IDE verbs (matches the settings taxonomy). `groupedForDisplay`
        // iterates `Category.allCases`, so adding the case here is enough to surface the section.
        case agents = "Agents"
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
             .toggleZoom,
             .toggleFloat: // needs a pane to float/embed
            true
        case .find,
             .toggleCopyMode,
             .commandNavigator,
             .jumpPreviousBlock,
             .jumpNextBlock,
             .reRunLastCommand,
             .jumpPreviousFailed,
             .jumpNextFailed,
             // E1 scroll / font / command-jump target the active TERMINAL pane (its viewport / glyphs /
             // prompt marks), and `sendToChat` carries the active pane's selection — same graceful-no-op
             // family as the block / find affordances above.
             .scrollPageUp,
             .scrollPageDown,
             .scrollToTop,
             .scrollToBottom,
             .commandJumpPrev,
             .commandJumpNext,
             .increaseFontSize,
             .decreaseFontSize,
             .resetFontSize,
             .sendToChat:
            // Block / find / scroll / font affordances target the active TERMINAL pane (its blocks /
            // scrollback / prompt marks / glyphs), so they need one — but they degrade gracefully (a
            // no-pane shell just no-ops), so they are not greyed out aggressively.
            true
        case .commandPalette,
             .cheatSheet,
             .newTab,
             .nextTab,
             .prevTab,
             .selectTab,
             .closeTab,
             .reopenClosed, // restores a closed pane into the active tab — acts on history, not a live pane
             .toggleSidebar,
             .toggleDetailsPanel, // a window-scope panel toggle — needs no active pane
             .openQuickly, // a global fuzzy switcher — needs no active pane
             .newSession,
             .spawnFloating, // creates its own pane — needs none
             .toggleSyncInput, // the tab must exist, but the palette can still show it (mirrors .newTab)
             .jumpToAttention, // acts globally across all tabs/sessions — needs no active pane
             .peekAndReply, // acts globally (targets the oldest attention pane) — needs no active pane
             .composer, // opens a global agent composer — needs no active pane
             .promptQueue: // opens the global agent prompt queue — needs no active pane
            false
        }
    }
}

// MARK: - WorkspaceBinding (one registry row: action + chord + display)

/// One row of the single-source-of-truth binding table: an action, its default chord (or `nil` for a
/// palette-only verb), plus the display shape the menu / palette / cheat sheet render. Pure value data.
public struct WorkspaceBinding: Sendable, Equatable {
    /// A stable string id (the dedup + rebind key; C4 settings will key user overrides by it).
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
/// cheat sheet (``KeyboardCheatSheet``), and the routing tests ALL read — so a chord, a menu item, a
/// palette row, and a cheat-sheet glyph can never drift apart (and C4 settings has one table to make
/// user-editable).
///
/// Every chord is ⌘- or ⌥-prefixed (the load-bearing §5 conflict rule: a bare key / Ctrl-letter falls
/// through to the focused terminal), and no two bindings share a chord — both pinned by
/// `TreeCommandRoutingTests`. The chords mirror otty's reference keymap: ⌘T new tab, ⌘W close, ⌘D
/// split-right, ⌘⇧D split-down, ⌃⌘+arrows focus, ⌥⌘↩ zoom, ⌘⇧]/⌘⇧[ next/prev tab, ⌘1…9 select tab,
/// ⌃⌘N new session, ⌘⇧L toggle Tabs panel, ⌘⇧R toggle Details panel, ⌃⌘T break-pane-to-tab, ⌘⇧P palette,
/// ⌘/ cheat sheet. Rename has no otty default chord — it is menu / palette / context-menu only (`chord: nil`).
public enum WorkspaceBindingRegistry {
    /// The shipped binding table, in cheat-sheet / palette display order (panes, tabs, sessions, focus,
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
        // Split-left / split-up (E1 ES-E1-1): ⌥+ the ⌘D / ⌘⇧D split chords, inserting the new pane on the
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
        // Rename has NO otty default chord (⌘⇧R is otty's Toggle Details Panel — see `view.toggleDetails`).
        // It is reachable from the title menu / context menu / palette only; `chord: nil` surfaces the row
        // (cheat sheet / menu / palette) without binding a key. Pinned chord-less by `E1KeymapParityTests`.
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
        // Floating panes (zellij toggle-float / new floating pane). ⌘⇧F floats/embeds the active pane
        // (⌘F is find, so ⌘⇧F is free); ⌃⌘F spawns a new floating scratch pane (the "F = float" family,
        // ⌃⌘F free vs the used ⌃⌘O/R/N/T/=). Both verified unique by `TreeCommandRoutingTests`.
        WorkspaceBinding(
            id: "pane.toggleFloat", action: .toggleFloat, title: "Float Pane",
            category: .panes, chord: KeyChord(character: "f", [.command, .shift]),
            symbol: "macwindow", keywords: "float overlay scratch detach embed unfloat windowed",
        ),
        WorkspaceBinding(
            id: "pane.spawnFloating", action: .spawnFloating, title: "New Floating Pane",
            category: .panes, chord: KeyChord(character: "f", [.control, .command]),
            symbol: "plus.rectangle.on.rectangle", keywords: "new floating scratch overlay terminal window",
        ),
        // Move pane (Zellij "move pane" — swap with the geometric neighbour). ⌥⌘⇧+arrows = the focus chords
        // (⌥⌘arrows) with ⇧ added, so they read as "carry the pane along the focus move" and stay distinct
        // from both focus (no ⇧) and the ⌃⌘arrow resize chords below.
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
        // Move divider (keyboard divider nudge). otty's "Move divider up/down/left/right" = ⌃⌘⇧arrows
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
        // Layouts (tmux/zellij select-layout): ⌃⌘L cycles through the algorithmic re-tile presets
        // (even-horizontal/vertical, main-vertical/horizontal, tiled). It parallels ⌃⌘= Balance Panes
        // ("L = Layout"); ⌃⌘L is otherwise unbound (`l` appears in NO other chord). A registry binding
        // fires ONLY via its menu item (no NSEvent monitor — same as float / sync-input), so the Pane menu's
        // "Layouts ▸ Cycle Layout" item is what makes ⌃⌘L dispatch. The five NAMED presets are menu/palette
        // only (`.applyLayout(_)`, no chord). Pinned unique by `TreeCommandRoutingTests`.
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
        // Tab cycling RE-POINTED to ⌘⇧]/⌘⇧[ (E1 ES-E1-2 / DECISIONS): plain ⌘]/⌘[ now drive sequential
        // PANE cycling (`focus.cycleNext`/`focus.cyclePrev`), matching otty's reference table. The old
        // ⌘]/⌘[ tab parity (Muxy) is deliberately superseded — pinned by `E1KeymapParityTests`.
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
        WorkspaceBinding(
            id: "tab.close", action: .closeTab, title: "Close Tab",
            category: .tabs, chord: KeyChord(character: "w", [.command, .shift]),
            symbol: "xmark.rectangle", keywords: "close end terminate tab all panes",
        ),
        // Reopen the most recently closed pane (the browser "reopen tab" idiom, beside ⌘T new / ⌘⇧W close).
        // ⌘⇧T is FREE on the tree shell (the only other `t` chords are ⌘T new tab + ⌃⌘T break-pane). The
        // closed-pane LIFO + restore land in E3; the E1 route is a documented graceful no-op (no dead chord).
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
        // Supervision (P3): jump to the oldest pane needing attention (needsPermission first, then done) —
        // a global action across all tabs/sessions, so it lives in the Tabs group beside sync-input. ⌘⇧U is
        // FREE (no other binding uses `u`); pinned unique by the chord-uniqueness test.
        WorkspaceBinding(
            id: "view.jumpToAttention", action: .jumpToAttention, title: "Jump to Pane Needing Attention",
            category: .tabs, chord: KeyChord(character: "u", [.command, .shift]),
            symbol: "bell.badge",
            keywords: "jump unread attention needs permission blocked done next pane supervise oldest",
        ),
        // Supervision (P4): ⌘⇧J opens the Peek & Reply overlay over the oldest pane needing attention so
        // the human can ANSWER a blocked agent INLINE — no full tab/context switch. The partner of ⌘⇧U
        // (jump TO the pane): "J" = jump-in-and-reply. ⌘⇧J is FREE (`j` is in NO other binding); pinned
        // unique by the chord-uniqueness test. A registry chord fires ONLY via its menu item, so the Pane
        // menu carries the matching "Peek & Reply" item.
        WorkspaceBinding(
            id: "view.peekReply", action: .peekAndReply, title: "Peek & Reply to Blocked Pane",
            category: .tabs, chord: KeyChord(character: "j", [.command, .shift]),
            symbol: "bubble.left.and.text.bubble.right",
            keywords: "peek reply answer respond blocked needs permission inline quick supervise prompt",
        ),
        // Sessions
        WorkspaceBinding(
            id: "session.new", action: .newSession, title: "New Session",
            category: .sessions, chord: KeyChord(character: "n", [.control, .command]),
            symbol: "macwindow.badge.plus", keywords: "host connection add open create workspace",
        ),
        // Focus pane up/down/left/right — otty's documented default ⌃⌘arrows
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
        // Sequential pane cycle (E1 ES-E1-2): ⌘]/⌘[ step focus through the active tab's panes in DFS order
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
        // Zoom / unzoom split — otty's documented default ⌘⇧↩ (spec/reference__keybindings.md:78,
        // customization__custom-keybindings.md:70). Toggles a single pane to fill the tab.
        WorkspaceBinding(
            id: "view.zoom", action: .toggleZoom, title: "Maximize Pane",
            category: .view, chord: KeyChord(.return, [.command, .shift]),
            symbol: "arrow.up.left.and.arrow.down.right", keywords: "fullscreen full screen zoom expand enlarge",
        ),
        // Command Palette ⌘⇧P — otty's documented default (spec/reference__keybindings.md:42,
        // spec/user-interface__command-palette.md:5/9/35 "Opened with ⌘⇧P from anywhere"). ⌘⇧P is FREE (no
        // other `p` chord). Pinned by `E1KeymapParityTests`; the otty-divergence history is in DECISIONS.md.
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
        // Copy Mode (P5b): modal keyboard scrollback navigation (tmux/zellij copy-mode). ⌘⇧C is FREE —
        // `c` appears in NO other binding, and ⌘⇧C does not collide with the system plain ⌘C copy (a
        // different modifier set, handled by the terminal's own copy responder). Verified unique by the
        // chord-uniqueness guard.
        WorkspaceBinding(
            id: "view.copyMode", action: .toggleCopyMode, title: "Copy Mode",
            category: .view, chord: KeyChord(character: "c", [.command, .shift]),
            symbol: "doc.on.clipboard",
            keywords: "copy mode scrollback keyboard navigate select yank vi tmux zellij",
        ),
        // Toggle Tabs Panel ⌘⇧L — otty's reference default (spec/reference__keybindings.md:66 "Toggle tabs
        // panel | ⌘⇧L"; line 201 "⌘⇧L … map to sidebar … toggles"). RE-BOUND from the old ⌘B: ⌘B routed to
        // `store.toggleSidebarCollapsed()`, a LEGACY flag the native split shell never reads (the macOS
        // collapse is driven by `WorkspaceChromeState.sidebarCollapsed`), so ⌘B was a DEAD chord. Now ⌘⇧L
        // routes through a `toggleSidebar` view-closure (like `.toggleDetailsPanel`) onto the live chrome
        // flag, and the titlebar's redundant SwiftUI ⌘⇧L shortcut is dropped (single owner). ⌘⇧L is FREE
        // (no other `l` chord; ⌃⌘L is Cycle Layout). Pinned by E1KeymapParityTests.
        WorkspaceBinding(
            id: "view.toggleSidebar", action: .toggleSidebar, title: "Toggle Tabs Panel",
            category: .view, chord: KeyChord(character: "l", [.command, .shift]),
            symbol: "sidebar.left", keywords: "sidebar sessions tabs panel rail hide show collapse",
        ),
        // Toggle Details Panel ⌘⇧R — otty's reference default (spec/reference__keybindings.md:67; the
        // command-palette.png screenshot shows "Toggle Details Panel" with chips ⇧⌘R). The titlebar's
        // matching hidden SwiftUI .keyboardShortcut was DEAD because the NSEvent dispatcher swallowed ⌘⇧R
        // first (it was bound to rename); routing it through `toggleDetailsPanel` (a view-@State closure,
        // like the palette / cheat-sheet toggles) makes ⌘⇧R own the Details panel. Pinned by E1KeymapParityTests.
        WorkspaceBinding(
            id: "view.toggleDetails", action: .toggleDetailsPanel, title: "Toggle Details Panel",
            category: .view, chord: KeyChord(character: "r", [.command, .shift]),
            symbol: "sidebar.right", keywords: "details inspector panel right pane hide show collapse",
        ),
        // Blocks (WB2): the Command Navigator toggle + jump-to-block prev/next. ⌃⌘O / ⌃⌘[ / ⌃⌘] are all
        // ⌘-prefixed (the §5 conflict rule) and collision-free against the rest of the table (tab cycling
        // is ⌘[/], focus is ⌥⌘arrows — neither uses ⌃⌘bracket). They target the active terminal pane.
        WorkspaceBinding(
            id: "view.commandNavigator", action: .commandNavigator, title: "Command Navigator",
            category: .view, chord: KeyChord(character: "o", [.control, .command]),
            symbol: "list.bullet.rectangle", keywords: "blocks commands history recent navigator output jump warp",
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
        // WB3: re-run last command + jump-to-failed prev/next. ⌃⌘R / ⌃⌘⇧[ / ⌃⌘⇧] are all ⌘-prefixed (§5)
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
        // E1 viewport scroll (ES-E1-3): the named-key chords ⇧PageUp/PageDown (page scroll) + ⇧Home/End
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
        // E1 command jumps (ES-E1-3): ⌘PageUp/PageDown jump the viewport to the previous / next shell
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
        // E1 font size (ES-E1-4): ⌘= bumps, ⌘- shrinks, ⌘0 resets. ⌘0 is FREE (the select-tab digits start
        // at ⌘1). The `+` glyph (otty's ⌘+) does NOT fold onto `=` for free — on a US/ANSI layout ⌘+ is
        // delivered as `+`+⇧ (or keypad `+`), which `charactersIgnoringModifiers` keys as a DISTINCT chord —
        // so ``aliasChords`` adds those two spellings → `.increaseFontSize` (no extra display row). libghostty
        // rescales glyphs WITHIN the pane box, so no PTY grid reflow from the font step alone. Target the
        // active terminal pane.
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
        // Open Quickly (E1-registered, E11 behaviour): ⌘⇧O fuzzy file/symbol switcher. ⌘⇧O is FREE (the only
        // other `o` chord is ⌃⌘O command navigator). Routable stub until E11 — never a dead chord.
        WorkspaceBinding(
            id: "view.openQuickly", action: .openQuickly, title: "Open Quickly…",
            category: .view, chord: KeyChord(character: "o", [.command, .shift]),
            symbol: "magnifyingglass.circle", keywords: "open quickly fuzzy file symbol switcher jump goto",
        ),
        // Agents (E1-registered; behaviour lands in E12/E13). ⌘⇧E composer, ⌘⇧M prompt queue, ⌘⌃↩ send-to-chat
        // are all FREE (e/m unused as chords; ⌘⌃↩ has a distinct modifier set from ⌥⌘↩ zoom). Routable stubs.
        WorkspaceBinding(
            id: "agent.composer", action: .composer, title: "Open Composer",
            category: .agents, chord: KeyChord(character: "e", [.command, .shift]),
            symbol: "square.and.pencil", keywords: "composer prompt write agent message draft edit",
        ),
        WorkspaceBinding(
            id: "agent.promptQueue", action: .promptQueue, title: "Prompt Queue",
            category: .agents, chord: KeyChord(character: "m", [.command, .shift]),
            symbol: "list.bullet.rectangle.portrait", keywords: "prompt queue agent messages pending backlog",
        ),
        WorkspaceBinding(
            id: "agent.sendToChat", action: .sendToChat, title: "Send to Chat",
            category: .agents, chord: KeyChord(.return, [.command, .control]),
            symbol: "arrow.up.message", keywords: "send chat agent selection command share forward",
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

    /// Extra chord → action ALIASES that fire an existing action from a SECOND chord, WITHOUT minting a
    /// display row (so the cheat sheet / palette / menu still show the ONE canonical binding). Folded into
    /// ``chordTable`` + ``resolvedChordTable`` so the keyboard dispatcher resolves them, but NOT into
    /// ``allBindings`` / ``groupedForDisplay`` — the chord-uniqueness guard runs over `allBindings`, so an
    /// alias here is intentionally outside it (it shares its ACTION, not its chord, with the canonical row).
    ///
    /// E1 ES-E1-4: the font-increase chord is canonically ⌘= (no ⇧), but otty's spec / muscle memory is the
    /// `+` glyph (`⌘+`). On a US/ANSI layout `+` IS Shift-`=`, and `charactersIgnoringModifiers` ignores
    /// ⌘/⌥/⌃ but NOT ⇧ — so physically pressing ⌘+ delivers the character `"+"` with ⇧ set, i.e.
    /// `KeyChord(character: "+", [.command, .shift])`, NOT ⌘=. Without this alias that chord is unbound and
    /// ⌘+ leaks to the PTY (the font never grows). We alias BOTH spellings the OS can deliver for ⌘+: the
    /// shifted main-row `+` (`⌘⇧+`) and the (unshifted) keypad `+` (`⌘+`). `KeyChord.init(character:)`
    /// lower-cases, which is a no-op for `+`, so both spellings key cleanly.
    public static let aliasChords: [KeyChord: WorkspaceAction] = [
        KeyChord(character: "+", [.command, .shift]): .increaseFontSize, // ⌘+ = ⌘⇧= on a US/ANSI layout
        KeyChord(character: "+", [.command]): .increaseFontSize, // keypad + (no ⇧ reported)
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

    /// The bindings grouped by category in display order (panes, tabs, sessions, focus, view), with the
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
