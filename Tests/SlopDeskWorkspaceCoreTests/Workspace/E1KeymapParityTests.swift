import CoreGraphics
import XCTest
@testable import SlopDeskWorkspaceCore

/// Pins the keymap-parity contract in the single-source-of-truth ``WorkspaceBindingRegistry``: every
/// clone action registered with its collision-checked chord, the tab-cycle re-point (⌘]/⌘[ → sequential
/// PANE cycle, tab cycling moved to ⌘⇧]/⌘⇧[), the named-key scroll chords, the font chords, and the agent
/// stubs.
///
/// Mirrors ``TreeCommandRoutingTests`` (same `makeTreeStore` / `route` harness): each new action must
/// resolve to its documented chord AND route through ``WorkspaceBindingRegistry/route(_:to:)`` on a
/// `.tree`-live store WITHOUT trapping (the registry's "no dead chords" contract). Behavioral effects that
/// need a live terminal surface (font / scroll → libghostty) are covered by the recording-fake-surface
/// tests in the store-hook suite; here we pin the structural store effects (split / cycle) + the chord table.
@MainActor
final class E1KeymapParityTests: XCTestCase {
    // MARK: - Fixtures (mirror TreeCommandRoutingTests)

    private func makeTreeStore(restoringTree: TreeWorkspace = .defaultWorkspace()) -> WorkspaceStore {
        WorkspaceStore(
            restoringTree: restoringTree,
            liveModel: .tree,
            makeSession: { FakePaneSession($0) },
            liveVideoCap: 2,
        )
    }

    private func leaves(_ store: WorkspaceStore) -> [PaneID] { store.tree.allPaneIDs() }

    private func activePane(_ store: WorkspaceStore) -> PaneID? {
        store.tree.activeSession?.activeTab?.activePane
    }

    private func chord(_ action: WorkspaceAction) -> KeyChord? {
        WorkspaceBindingRegistry.binding(for: action)?.chord
    }

    // MARK: - split-left / split-up insert the LEADING leaf and focus it

    /// `.splitLeft` splits the active pane and inserts the new `.chooser` leaf on the LEADING (DFS-first)
    /// side, focused. (The leaf is a `.chooser`, which materializes no session until `choosePaneKind`, so we
    /// assert on the tree structure, not a fake handle — the chooser-split itself is the contract under test.)
    /// FAILS on the pre-E1 code: there is no `.splitLeft` action / routing case.
    func testSplitLeftInsertsLeadingLeafAndFocuses() throws {
        let store = makeTreeStore()
        let original = try XCTUnwrap(leaves(store).first)

        WorkspaceBindingRegistry.route(.splitLeft, to: store)

        let after = leaves(store)
        XCTAssertEqual(after.count, 2, "splitLeft added exactly one leaf")
        let added = try XCTUnwrap(after.first { $0 != original })
        XCTAssertEqual(after.first, added, "the new leaf is inserted on the LEADING side (DFS-first)")
        XCTAssertEqual(activePane(store), added, "the new (leading) leaf is focused")
        XCTAssertEqual(store.tree.spec(for: added)?.kind, .terminal, "the new leaf is a terminal (direct mint)")
    }

    /// `.splitUp` does the same on the vertical axis: a leading (top, DFS-first) leaf, focused, in a stacked
    /// split. FAILS on the pre-E1 code (no `.splitUp`).
    func testSplitUpInsertsLeadingLeafInStackedSplit() throws {
        let store = makeTreeStore()
        let original = try XCTUnwrap(leaves(store).first)

        WorkspaceBindingRegistry.route(.splitUp, to: store)

        let after = leaves(store)
        XCTAssertEqual(after.count, 2, "splitUp added exactly one leaf")
        let added = try XCTUnwrap(after.first { $0 != original })
        XCTAssertEqual(after.first, added, "the new leaf is inserted on the LEADING (top) side")
        XCTAssertEqual(activePane(store), added, "the new (top) leaf is focused")
        guard case .split(_, .vertical, _)? = store.tree.activeSession?.activeTab?.root else {
            XCTFail("splitUp produces a vertical (stacked) split")
            return
        }
    }

    // MARK: - sequential pane cycle walks DFS and wraps

    /// `.cyclePaneNext` steps the active pane through the active tab's panes in DFS order and WRAPS at the
    /// end; `.cyclePanePrev` reverses. A 3-pane tab proves both the step and the wrap. FAILS on the pre-E1
    /// code (no `.cyclePaneNext`/`.cyclePanePrev` action or routing).
    func testCyclePaneWalksDFSAndWraps() {
        let store = makeTreeStore()
        // Build a 3-leaf tab: split twice (each split focuses the new leaf), then read DFS order.
        store.splitActivePane(axis: .horizontal, kind: .terminal)
        store.splitActivePane(axis: .horizontal, kind: .terminal)
        let order = leaves(store)
        XCTAssertEqual(order.count, 3, "three panes in the active tab")

        // Anchor on the FIRST pane so the walk is deterministic from a known start.
        store.focusPaneTree(order[0])
        XCTAssertEqual(activePane(store), order[0])

        WorkspaceBindingRegistry.route(.cyclePaneNext, to: store)
        XCTAssertEqual(activePane(store), order[1], "cycleNext → second pane (DFS)")
        WorkspaceBindingRegistry.route(.cyclePaneNext, to: store)
        XCTAssertEqual(activePane(store), order[2], "cycleNext → third pane (DFS)")
        WorkspaceBindingRegistry.route(.cyclePaneNext, to: store)
        XCTAssertEqual(activePane(store), order[0], "cycleNext WRAPS from last → first")

        WorkspaceBindingRegistry.route(.cyclePanePrev, to: store)
        XCTAssertEqual(activePane(store), order[2], "cyclePrev WRAPS from first → last")
        WorkspaceBindingRegistry.route(.cyclePanePrev, to: store)
        XCTAssertEqual(activePane(store), order[1], "cyclePrev → second pane (reverse DFS)")
    }

    // MARK: - Chord table: re-point + new chords match the collision-checked table

    /// The tab-cycle RE-POINT (see DECISIONS.md): `nextTab`/`prevTab` moved to ⌘⇧]/⌘⇧[, and the FREED
    /// ⌘]/⌘[ now drive sequential PANE cycling. A transposed-modifier typo would slip past the uniqueness
    /// guard (it only catches a COLLISION), so pin the exact values. FAILS on the pre-E1 chords.
    func testTabCycleMovedToShiftBracketAndPaneCycleOnPlainBracket() {
        XCTAssertEqual(chord(.nextTab), KeyChord(character: "]", [.command, .shift]), "next tab → ⌘⇧]")
        XCTAssertEqual(chord(.prevTab), KeyChord(character: "[", [.command, .shift]), "prev tab → ⌘⇧[")
        XCTAssertEqual(chord(.cyclePaneNext), KeyChord(character: "]", [.command]), "cycle pane next = ⌘]")
        XCTAssertEqual(chord(.cyclePanePrev), KeyChord(character: "[", [.command]), "cycle pane prev = ⌘[")
    }

    /// Focus-pane directional chords, the divider-move family, and zoom carry the documented default chords
    /// (spec/reference__keybindings.md:78,82-89; customization__custom-keybindings.md:70,74-81). Focus = the
    /// single most load-bearing pane-navigation chord set: ⌃⌘arrows (NOT ⌥⌘arrows). Move-divider = ⌃⌘⇧arrows
    /// (NOT plain ⌃⌘arrows — those are focus). Zoom = ⌘⇧↩ (NOT ⌥⌘↩). A transposed modifier slips past the
    /// uniqueness guard (it only catches a COLLISION), so pin the exact values. FAILS on the pre-fix chords
    /// (focus on ⌥⌘arrows, divider on ⌃⌘arrows, zoom on ⌥⌘↩).
    func testFocusDividerAndZoomChordsMatchSlateDefaults() {
        // Focus pane up/down/left/right = ⌃⌘arrows.
        XCTAssertEqual(chord(.focusLeft), KeyChord(.leftArrow, [.control, .command]), "focus left = ⌃⌘←")
        XCTAssertEqual(chord(.focusRight), KeyChord(.rightArrow, [.control, .command]), "focus right = ⌃⌘→")
        XCTAssertEqual(chord(.focusUp), KeyChord(.upArrow, [.control, .command]), "focus up = ⌃⌘↑")
        XCTAssertEqual(chord(.focusDown), KeyChord(.downArrow, [.control, .command]), "focus down = ⌃⌘↓")
        // Move divider up/down/left/right = ⌃⌘⇧arrows.
        XCTAssertEqual(
            chord(.resizePaneLeft),
            KeyChord(.leftArrow, [.control, .command, .shift]),
            "divider left = ⌃⌘⇧←",
        )
        XCTAssertEqual(
            chord(.resizePaneRight), KeyChord(.rightArrow, [.control, .command, .shift]), "divider right = ⌃⌘⇧→",
        )
        XCTAssertEqual(chord(.resizePaneUp), KeyChord(.upArrow, [.control, .command, .shift]), "divider up = ⌃⌘⇧↑")
        XCTAssertEqual(
            chord(.resizePaneDown),
            KeyChord(.downArrow, [.control, .command, .shift]),
            "divider down = ⌃⌘⇧↓",
        )
        // Zoom / unzoom split = ⌘⇧↩.
        XCTAssertEqual(chord(.toggleZoom), KeyChord(.return, [.command, .shift]), "zoom = ⌘⇧↩")
    }

    /// The split-left/up chords: ⌘⌥D / ⌘⌥⇧D — ⌥+ the ⌘D / ⌘⇧D right/down splits.
    func testSplitLeftUpChordsMatchTable() {
        XCTAssertEqual(chord(.splitLeft), KeyChord(character: "d", [.command, .option]), "split left = ⌘⌥D")
        XCTAssertEqual(chord(.splitUp), KeyChord(character: "d", [.command, .option, .shift]), "split up = ⌘⌥⇧D")
    }

    /// The eight scroll/command-jump chords + three font chords match the table.
    func testScrollAndFontChordsMatchTable() {
        XCTAssertEqual(chord(.scrollPageUp), KeyChord(.pageUp, [.shift]), "scroll page up = ⇧PageUp")
        XCTAssertEqual(chord(.scrollPageDown), KeyChord(.pageDown, [.shift]), "scroll page down = ⇧PageDown")
        XCTAssertEqual(chord(.scrollToTop), KeyChord(.home, [.shift]), "scroll top = ⇧Home")
        XCTAssertEqual(chord(.scrollToBottom), KeyChord(.end, [.shift]), "scroll bottom = ⇧End")
        XCTAssertEqual(chord(.commandJumpPrev), KeyChord(.pageUp, [.command]), "command jump prev = ⌘PageUp")
        XCTAssertEqual(chord(.commandJumpNext), KeyChord(.pageDown, [.command]), "command jump next = ⌘PageDown")
        XCTAssertEqual(chord(.increaseFontSize), KeyChord(character: "=", [.command]), "font increase = ⌘=")
        XCTAssertEqual(chord(.decreaseFontSize), KeyChord(character: "-", [.command]), "font decrease = ⌘-")
        XCTAssertEqual(chord(.resetFontSize), KeyChord(character: "0", [.command]), "font reset = ⌘0")
    }

    /// Pressing ⌘+ must grow the terminal font. The canonical chord is ⌘= (no ⇧), but on
    /// a US/ANSI layout `+` IS Shift-`=`: `charactersIgnoringModifiers` ignores ⌘/⌥/⌃ but NOT ⇧, so physically
    /// pressing ⌘+ delivers the character `"+"` with ⇧ set — `KeyChord(character: "+", [.command, .shift])` —
    /// NOT ⌘=. Without an alias that chord is unbound and ⌘+ leaks to the PTY. The registry's `aliasChords`
    /// folds BOTH ⌘+ spellings (shifted main-row `+`, keypad `+`) → `.increaseFontSize` in the chord table, so
    /// ⌘+ grows the font. FAILS on the pre-fix code (only the literal ⌘= chord resolved; ⌘+ was unbound).
    func testCmdPlusResolvesToIncreaseFontSize() {
        // The two chord shapes the OS can deliver for ⌘+ both resolve to font-increase.
        XCTAssertEqual(
            WorkspaceBindingRegistry.chordTable[KeyChord(character: "+", [.command, .shift])], .increaseFontSize,
            "⌘+ (delivered as ⌘⇧+ on a US/ANSI layout) grows the font",
        )
        XCTAssertEqual(
            WorkspaceBindingRegistry.chordTable[KeyChord(character: "+", [.command])], .increaseFontSize,
            "keypad ⌘+ (no ⇧ reported) grows the font",
        )
        // The live dispatcher reads the OVERRIDE-AWARE table; the alias must be present there too (default,
        // no overrides) so the runtime path — not just the static table — resolves ⌘+.
        XCTAssertEqual(
            WorkspaceBindingRegistry.resolvedChordTable[KeyChord(character: "+", [.command, .shift])],
            .increaseFontSize,
            "⌘+ resolves to font-increase in the override-aware table the dispatcher reads",
        )
        // The canonical ⌘= still works, and the canonical display binding is unchanged (no duplicate row).
        XCTAssertEqual(
            WorkspaceBindingRegistry.chordTable[KeyChord(character: "=", [.command])], .increaseFontSize,
            "the canonical ⌘= chord still grows the font",
        )
        XCTAssertEqual(
            chord(.increaseFontSize), KeyChord(character: "=", [.command]),
            "the canonical display binding stays ⌘= (the alias adds no display row)",
        )
    }

    /// `route(.increaseFontSize, …)` from the ⌘+ alias chord runs through the SAME routing as ⌘= — it is a
    /// graceful no-op against a non-live FakePaneSession surface (font scaling needs libghostty), but must not
    /// trap or mutate the tree. Pins that the aliased chord drives the real action, not a dead path.
    func testIncreaseFontSizeFromAliasRoutesWithoutTrap() throws {
        let store = makeTreeStore()
        let action = try XCTUnwrap(
            WorkspaceBindingRegistry.chordTable[KeyChord(character: "+", [.command, .shift])],
            "⌘+ is bound to an action",
        )
        let before = store.tree
        WorkspaceBindingRegistry.route(action, to: store) // must not trap
        XCTAssertEqual(store.tree, before, "font-increase is a render-only op — the tree is unchanged")
    }

    // MARK: - Default-keymap parity: command palette ⌘⇧P + freed ⌘⇧R + chord-less rename

    /// The Command Palette is bound to the documented default ⌘⇧P, NOT the coding-IDE ⌘K
    /// (spec/reference__keybindings.md:42, spec/user-interface__command-palette.md:5/9/35 "Opened with ⌘⇧P
    /// from anywhere"). FAILS on the pre-fix code (palette was ⌘K). Also asserts ⌘K no longer fires the palette.
    func testCommandPaletteIsCmdShiftP() {
        XCTAssertEqual(
            chord(.commandPalette), KeyChord(character: "p", [.command, .shift]),
            "command palette = ⌘⇧P (default chord)",
        )
        XCTAssertNotEqual(
            chord(.commandPalette), KeyChord(character: "k", [.command]),
            "command palette must NOT be the old ⌘K coding-IDE chord",
        )
        // The chord table resolves ⌘⇧P → the palette, and ⌘K resolves to nothing (freed).
        XCTAssertEqual(
            WorkspaceBindingRegistry.chordTable[KeyChord(character: "p", [.command, .shift])], .commandPalette,
            "⌘⇧P routes to the command palette",
        )
        XCTAssertNil(
            WorkspaceBindingRegistry.chordTable[KeyChord(character: "k", [.command])],
            "⌘K is freed — it no longer maps to any action",
        )
    }

    /// ⌘⇧R was freed by the Host Windows rail's retirement (the full-desktop pivot) and deliberately
    /// left UNBOUND; Rename — which once squatted on ⌘⇧R — stays chord-less. ⌥⌘N is the desktop
    /// pane's chord. FAILS if either moves again without a deliberate decision.
    func testCmdShiftRIsFreeAndNewDesktopTabIsOptCmdN() {
        XCTAssertNil(
            WorkspaceBindingRegistry.chordTable[KeyChord(character: "r", [.command, .shift])],
            "⌘⇧R returned to the free pool with the rail's retirement",
        )
        XCTAssertEqual(
            WorkspaceBindingRegistry.chordTable[KeyChord(character: "n", [.command, .option])],
            .newDesktopTab,
            "⌥⌘N opens a full-desktop tab (the full-desktop pivot's dedicated non-terminal chord)",
        )
        // Rename is still a REGISTERED, routable action (title menu / context menu / palette), but chord-LESS.
        let rename = WorkspaceBindingRegistry.binding(for: .renamePane)
        XCTAssertNotNil(rename, "rename is still a registered binding (menu / palette reachable)")
        XCTAssertNil(rename?.chord, "rename carries NO default chord")
    }

    /// ⌘B "Toggle Sidebar" was a DEAD chord on macOS — it routed to
    /// `store.toggleSidebarCollapsed()`, a LEGACY flag the native split shell never reads (the macOS sidebar
    /// collapse is `WorkspaceChromeState.sidebarCollapsed`). Re-bound to ⌘⇧L "Toggle Tabs Panel" and
    /// routed through a `toggleSidebar` VIEW closure the live app wires to
    /// `chrome.toggleSidebar`. Pins (1) the chord is ⌘⇧L, NOT ⌘B; (2) the action DRIVES the supplied closure
    /// (the live collapse flag), not just the dead store flag. FAILS on the pre-fix code (chord was ⌘B; the
    /// route had no `toggleSidebar` closure and flipped only the unread store flag).
    func testToggleSidebarIsCmdShiftLAndDrivesTheSuppliedClosure() {
        // (1) the chord is ⌘⇧L, and the old ⌘B no longer fires the sidebar.
        XCTAssertEqual(
            chord(.toggleSidebar), KeyChord(character: "l", [.command, .shift]),
            "toggle sidebar = ⌘⇧L (Toggle Tabs Panel)",
        )
        XCTAssertEqual(
            WorkspaceBindingRegistry.chordTable[KeyChord(character: "l", [.command, .shift])], .toggleSidebar,
            "⌘⇧L routes to Toggle Tabs Panel",
        )
        XCTAssertNil(
            WorkspaceBindingRegistry.chordTable[KeyChord(character: "b", [.command])],
            "⌘B is freed — it no longer maps to the (dead) sidebar toggle",
        )

        // (2) the action drives the SUPPLIED closure — the live `chrome.sidebarCollapsed` flip, not the
        // legacy store flag. This is the crux: ⌘⇧L must reach the flag the native split actually reads.
        let store = makeTreeStore()
        let before = store.tree
        var fired = 0
        WorkspaceBindingRegistry.route(.toggleSidebar, to: store, toggleSidebar: { fired += 1 })
        XCTAssertEqual(fired, 1, "the supplied sidebar-toggle closure fires exactly once")
        XCTAssertEqual(store.tree, before, "Toggle Tabs Panel is a view toggle — the tree is unchanged")
    }

    /// Without a `toggleSidebar` closure (the headless / test default) `.toggleSidebar` must still be a
    /// non-trapping graceful op — it falls back to the legacy store flag so the action is never DEAD/trapping.
    /// (On macOS the live app always supplies the closure; this pins the fallback path only.)
    func testToggleSidebarFallsBackGracefullyWithoutClosure() {
        let store = makeTreeStore()
        let before = store.sidebarCollapsed
        WorkspaceBindingRegistry.route(.toggleSidebar, to: store) // nil closure → store-flag fallback
        XCTAssertEqual(store.sidebarCollapsed, !before, "the no-closure fallback still flips the store flag (no trap)")
    }

    /// The delegated-stub chords: reopen ⌘⇧T, open-quickly ⌘⇧O — registered with the exact
    /// collision-checked chords.
    func testDelegatedStubChordsMatchTable() {
        XCTAssertEqual(chord(.reopenClosed), KeyChord(character: "t", [.command, .shift]), "reopen closed = ⌘⇧T")
        XCTAssertEqual(chord(.openQuickly), KeyChord(character: "o", [.command, .shift]), "open quickly = ⌘⇧O")
    }

    // MARK: - Registry integrity for the new actions

    /// Every new E1 action has a registered binding with a resolvable default chord (none is a palette-only
    /// orphan / unregistered). FAILS on the pre-E1 code where these actions / bindings don't exist.
    func testEveryE1ActionHasARegisteredChord() {
        let actions: [WorkspaceAction] = [
            .splitLeft, .splitUp,
            .cyclePaneNext, .cyclePanePrev,
            .scrollPageUp, .scrollPageDown, .scrollToTop, .scrollToBottom,
            .commandJumpPrev, .commandJumpNext,
            .increaseFontSize, .decreaseFontSize, .resetFontSize,
            .reopenClosed, .openQuickly,
        ]
        for action in actions {
            let binding = WorkspaceBindingRegistry.binding(for: action)
            XCTAssertNotNil(binding, "\(action) has a registry binding")
            XCTAssertNotNil(binding?.chord, "\(action) has a resolvable default chord")
        }
    }

    /// Routing EVERY new E1 action through `route(_:to:)` on a tree store must not trap — the stubs
    /// (reopen / open-quickly) are documented graceful no-ops, the font /
    /// scroll / command-jump hooks no-op against a non-live surface, and the split / cycle ops mutate the
    /// tree. Pins the registry's "no dead chord" contract: every action is wired, none is dropped/traps.
    func testEveryE1ActionRoutesWithoutTrap() {
        let actions: [WorkspaceAction] = [
            .splitLeft, .splitUp,
            .cyclePaneNext, .cyclePanePrev,
            .scrollPageUp, .scrollPageDown, .scrollToTop, .scrollToBottom,
            .commandJumpPrev, .commandJumpNext,
            .increaseFontSize, .decreaseFontSize, .resetFontSize,
            .reopenClosed, .openQuickly,
        ]
        for action in actions {
            // Fresh store per action so a tree-mutating action (split) doesn't perturb the next assertion.
            let store = makeTreeStore()
            WorkspaceBindingRegistry.route(action, to: store) // must not trap
        }
    }

    /// The stub actions (reopen / open-quickly) are GRACEFUL no-ops in E1:
    /// they route without mutating the tree (their behaviour lands in later epics). Pins that they are wired
    /// to a documented no-op, not accidentally bound to a destructive op.
    func testE1StubActionsDoNotMutateTree() {
        for action in [WorkspaceAction.openQuickly, .reopenClosed] {
            let store = makeTreeStore()
            let before = store.tree
            WorkspaceBindingRegistry.route(action, to: store)
            XCTAssertEqual(store.tree, before, "\(action) is an E1 stub — the tree is unchanged")
        }
    }
}
