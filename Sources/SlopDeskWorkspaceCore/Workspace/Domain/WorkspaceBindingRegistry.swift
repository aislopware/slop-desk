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
    // true: `SlopDeskPhoneUI/Shell/WorkspaceRootViewController.swift` mounts the same
    // `CodePanelSurfaces` full-screen and installs this closure. A sidebar on the Mac, a cover on
    // the phone, is the layout difference the split exists for; the capability is on both.
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

    // View — font size (the renderer rescales the cell box, reflowing the remote PTY grid via SIGWINCH)
    case increaseFontSize // ⌘= / ⌘+ — bump the active pane's render font size (⌘+ via `aliasChords`)
    case decreaseFontSize // ⌘- — shrink the active pane's render font size
    case resetFontSize // ⌘0 — reset the active pane's render font size to the configured default

    // Blocks (Warp-style per-command blocks)
    case commandNavigator // ⌃⌘O — show/hide the searchable recent-blocks navigator over the active pane
    case jumpPreviousBlock // ⌃⌘[ — jump the viewport to the previous shell prompt (OSC 133, libghostty-vt)
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

// MARK: - WorkspaceBindingRegistry (the face over the ONE source of truth)

/// The command surface the IDE shell renders: the menu bar (``WorkspaceCommands``), the ⌘⇧P command
/// palette, the ⌘/ cheat sheet, the keybindings editor and the keyboard dispatcher all read from
/// here, so chord, menu item, palette row and cheat-sheet glyph cannot drift.
///
/// **This type holds no table.** The 77 rows — id, action, title, category, chord, symbol, keywords
/// and platform — are `slopdesk_workspace::bindings`, read once through ``WorkspaceBindingTable``.
/// What is here is the derived shape each surface wants: the display list, the chord lookup, the
/// per-action index and the glyph renderer. They were never duplicated, and keeping them Swift keeps
/// the per-keystroke path a hash lookup with no door on it.
///
/// Until docs/64 the rows WERE here, as an array literal beside a Rust array literal of the same
/// ids, held equal by a `SameSet` claim over a regex on each side. A join maintained by hand across
/// a language boundary is the cross-language mirror `CLAUDE.md` forbids by name, and the claim that
/// held it was the tell rather than the safeguard.
public enum WorkspaceBindingRegistry {
    /// The shipped binding table for THIS half — every declared row this platform lists.
    ///
    /// Filtering in the TABLE rather than at each display surface is deliberate, and the chord table
    /// is why. Every surface downstream reads from this one array, ``allBindings`` or
    /// ``groupedForDisplay``, and ``chordTable`` is one of them: a row kept on a half that cannot run
    /// it takes its chord away from the terminal to do nothing. Dropping the row drops the chord, so
    /// the key falls through to the pane the way an unbound chord should.
    public static let bindings: [WorkspaceBinding] = WorkspaceBindingTable.current.listed

    /// The ⌘1…⌘9 "select pane N" bindings, minted from a formula rather than declared as rows. One
    /// per digit; carried so the chord table is complete and the conflict / prefix guards see them.
    ///
    /// A loop, not a table — which is why these nine stay on this side while every declared row
    /// crossed. There is no Rust twin of a formula to drift from, and writing the nine out over
    /// there would have turned one rule into nine rows of interpolated strings.
    public static let selectPaneBindings: [WorkspaceBinding] = (1...9).map { n in
        WorkspaceBinding(
            id: "pane.select.\(n)", action: .selectPane(n),
            title: "Select Pane \(n)", category: .panes,
            chord: KeyChord(character: Character("\(n)"), [.command]),
            symbol: "\(n).square", keywords: "switch jump pane tab \(n)",
        )
    }

    /// Every binding the registry knows — the shipped table plus the nine ⌘-digit select-pane chords.
    /// The chord-table guards (uniqueness, ⌘/⌥-prefix) run over this full set.
    ///
    /// `let`, and the `let` is load-bearing. As a computed `var` this concatenation ran on every
    /// read, and its readers are the keyboard's: `resolvedChordTable` walks it once per key event and
    /// called ``binding(for:)`` per row, which read it AGAIN — 86 fresh 85-element arrays per
    /// keystroke, each retaining four strings per element. Measured at 210µs of allocation per key
    /// event on an M-series Mac, all of it to rebuild a table whose inputs cannot change.
    /// `rust/slopdesk-invariants` pins the `let` because a `var` here costs nothing a test can see.
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

    /// Extra chord → action ALIASES that fire an existing action from a SECOND chord WITHOUT minting
    /// a display row (so the cheat sheet / palette / menu still show the ONE canonical binding).
    /// Folded into ``chordTable`` + ``resolvedChordTable`` so the dispatcher resolves them, but NOT
    /// into ``allBindings`` / ``groupedForDisplay`` — the chord-uniqueness guard runs over
    /// `allBindings`, so an alias is intentionally outside it (it shares its ACTION, not its chord,
    /// with the canonical row).
    ///
    /// The two spellings of ⌘+ and the ⌃⇧Space Vi-Mode entry, and why each is needed, are
    /// `slopdesk_workspace::bindings::ALIASES`.
    public static let aliasChords: [KeyChord: WorkspaceAction] = WorkspaceBindingTable.current.aliases

    /// The chord → action lookup table (drives the keyboard dispatcher). Built from ``allBindings``
    /// (so the keyboard layer reads the SAME source as the menu/palette/cheat sheet) plus
    /// ``aliasChords`` (extra chords that fire an existing action without a display row).
    public static var chordTable: [KeyChord: WorkspaceAction] {
        var map: [KeyChord: WorkspaceAction] = [:]
        for binding in allBindings {
            if let chord = binding.chord { map[chord] = binding.action }
        }
        // Aliases never overwrite a real binding (they target an existing action from a free second
        // chord), but fold them AFTER so the table is the union the dispatcher resolves.
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
    /// rebuilt palette in each shell derives its row hints from the SAME registry the keyboard bank
    /// registers (no drift).
    public nonisolated static func glyph(for action: WorkspaceAction) -> String? {
        guard let binding = binding(for: action) else { return nil }
        return binding.chord.map(glyph)
    }

    // MARK: - Grouped display (the cheat sheet sections + palette catalog order)

    /// The bindings grouped by category in display order (panes, tabs, focus, view), with the
    /// nine ⌘-digit select-pane chords collapsed into ONE representative "⌘1…⌘9" row (see
    /// ``selectPaneRepresentative``) appended to the Panes group — the real per-digit chords live
    /// only in ``selectPaneBindings`` (keyboard bank / chord table), never in this display set. The
    /// menu builds its own "Select Pane" submenu and the palette catalog omits the digits, so this
    /// row is the only place the family surfaces in the cheat sheet. The SINGLE source the cheat
    /// sheet renders and the palette catalog iterates — so they cannot drift.
    /// `public` so each shell's rebuilt cheat-sheet overlay generates its rows from this one table.
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

    /// The single collapsed representative for the nine generated ⌘1…⌘9 select-pane chords (display
    /// only — the real per-digit chords live in ``selectPaneBindings``). `.selectPane(1)` is a
    /// stand-in action; the glyph range is hand-rendered into the title because one ``KeyChord``
    /// cannot represent a range, and a chord-less row keeps the overlay from drawing a separate
    /// (single-chord) hint chip.
    public static let selectPaneRepresentative = WorkspaceBindingTable.current.representative
}
