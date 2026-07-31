// DispatcherPaneSwitcherTests — the ⌃⇥ press-and-hold pane switcher at the live NSEvent monitor.
//
// The gesture is not expressible as a chord-table row: it OPENS on ⌃⇥, STEPS on each repeat while ⌃ is
// still down, and COMMITS on the ⌃ key-up — three different meanings for one chord plus a modifier
// transition, which is why it is handled in the dispatcher rather than `WorkspaceBindingRegistry`.
//
// The load-bearing safety property, pinned first below: claiming ⌃⇥ must not cost the pane BARE ⇥ (shell
// completion) or ⇧⇥ (Claude Code cycles permission modes with it). Those two must still reach the PTY
// untouched, which is exactly what a careless "exempt the Tab key" rule would break.

#if os(macOS)
import AppKit
import SlopDeskVideoProtocol
import SlopDeskWorkspaceModel
import XCTest
@testable import SlopDeskClientUI
@testable import SlopDeskWorkspaceCore

@MainActor
final class DispatcherPaneSwitcherTests: XCTestCase {
    override func tearDown() {
        WorkspaceBindingRegistry.activeOverrides = KeybindingPreferences()
        super.tearDown()
    }

    private func keyDown(
        _ chars: String, keyCode: UInt16,
        control: Bool = false, shift: Bool = false, command: Bool = false,
    ) -> NSEvent {
        var flags: NSEvent.ModifierFlags = []
        if control { flags.insert(.control) }
        if shift { flags.insert(.shift) }
        if command { flags.insert(.command) }
        return NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: 0, context: nil, characters: chars, charactersIgnoringModifiers: chars,
            isARepeat: false, keyCode: keyCode,
        )!
    }

    /// A `.flagsChanged` event carrying the modifiers STILL held after the transition — the dispatcher
    /// reads the absence of `.control` here as "the ⌃⇥ gesture ended".
    private func flagsChanged(control: Bool) -> NSEvent {
        NSEvent.keyEvent(
            with: .flagsChanged, location: .zero,
            modifierFlags: control ? [.control] : [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: 59, // left Control
        )!
    }

    private static let tab: UInt16 = 48
    private static let escape: UInt16 = 53
    private static let returnKey: UInt16 = 36

    /// A store whose active session has THREE single-pane tabs, left with a visit order where the
    /// recency answer and the positional answer differ (active = A at index 0, ring = [A, C, B]).
    private func makeThreeTabStore() -> WorkspaceStore {
        let store = WorkspaceStore(liveModel: .tree, makeSession: { seed in MountTestPaneSession(seed.spec) })
        store.attachLoopbackWorkspaceDocument()
        store.newTab(kind: .terminal)
        store.newTab(kind: .terminal)
        XCTAssertEqual(store.tree.activeSession?.tabs.count, 3, "precondition: three tabs")
        store.selectTab(2)
        store.selectTab(0)
        return store
    }

    private func activeTab(_ store: WorkspaceStore) -> TabID? {
        store.tree.activeSession?.activeTab?.id
    }

    /// HOST TRUTH — the projection BEFORE this device's local overlays. The follow-along preview moves
    /// what the device LOOKS at while the switcher is open, so "nothing was committed" is asserted here.
    private func committedTab(_ store: WorkspaceStore) -> TabID? {
        store.workspaceMirror.topology?.tree.activeSession?.activeTab?.id
    }

    // MARK: - The keys we must NOT cost the pane

    /// BARE ⇥ is shell completion. It must pass through untouched and open nothing.
    func testBareTabPassesThroughToThePane() {
        let store = makeThreeTabStore()
        let dispatcher = WorkspaceKeyDispatcher(store: store)

        let result = dispatcher.handle(keyDown("\t", keyCode: Self.tab))

        XCTAssertNotNil(result, "bare ⇥ reaches the PTY — it is shell completion, not a workspace chord")
        XCTAssertNil(store.paneSwitcher, "and opens no switcher")
    }

    /// ⇧⇥ is how Claude Code cycles permission modes. Claiming it would break the agent workflow this
    /// app exists to host, so it must pass through with no ⌃ present.
    func testShiftTabPassesThroughToThePane() {
        let store = makeThreeTabStore()
        let dispatcher = WorkspaceKeyDispatcher(store: store)

        let result = dispatcher.handle(keyDown("\t", keyCode: Self.tab, shift: true))

        XCTAssertNotNil(result, "⇧⇥ reaches the PTY (Claude Code's permission-mode cycle)")
        XCTAssertNil(store.paneSwitcher, "and opens no switcher")
    }

    /// A lone tab has nothing to switch between, so ⌃⇥ must fall through to the pane rather than being
    /// swallowed into an overlay that cannot act.
    func testControlTabWithOneTabPassesThrough() {
        let store = WorkspaceStore(liveModel: .tree, makeSession: { seed in MountTestPaneSession(seed.spec) })
        store.attachLoopbackWorkspaceDocument()
        XCTAssertEqual(store.tree.activeSession?.tabs.count, 1, "precondition: one tab")
        let dispatcher = WorkspaceKeyDispatcher(store: store)

        let result = dispatcher.handle(keyDown("\t", keyCode: Self.tab, control: true))

        XCTAssertNotNil(result, "nothing to switch to ⇒ ⌃⇥ is not ours")
        XCTAssertNil(store.paneSwitcher)
    }

    // MARK: - The gesture

    /// ⌃⇥ opens the switcher, is swallowed, and — critically — does NOT move the workspace yet.
    func testControlTabOpensTheSwitcherWithoutSwitchingYet() {
        let store = makeThreeTabStore()
        let before = committedTab(store)
        let dispatcher = WorkspaceKeyDispatcher(store: store)

        let result = dispatcher.handle(keyDown("\t", keyCode: Self.tab, control: true))

        XCTAssertNil(result, "⌃⇥ is owned by the workspace (swallowed)")
        XCTAssertNotNil(store.paneSwitcher, "the switcher is open")
        XCTAssertEqual(committedTab(store), before, "but no tab switch has been committed")
    }

    /// Releasing ⌃ commits — that key-up IS the selection, and it lands on the recently-used tab rather
    /// than the positional neighbour.
    func testReleasingControlCommitsToTheRecentTab() {
        let store = makeThreeTabStore()
        let tabs = store.tree.activeSession?.tabs.map(\.id) ?? []
        let dispatcher = WorkspaceKeyDispatcher(store: store)

        _ = dispatcher.handle(keyDown("\t", keyCode: Self.tab, control: true))
        let result = dispatcher.handle(flagsChanged(control: false))

        XCTAssertNotNil(result, "a modifier transition is never swallowed")
        XCTAssertNil(store.paneSwitcher, "the release closed the switcher")
        XCTAssertEqual(activeTab(store), tabs[2], "committed to the recently-visited pane, not the next one")
    }

    /// A `.flagsChanged` that still carries ⌃ is a mid-gesture transition (e.g. ⇧ going down to reverse)
    /// and must NOT commit.
    func testFlagsChangeStillHoldingControlDoesNotCommit() {
        let store = makeThreeTabStore()
        let before = committedTab(store)
        let dispatcher = WorkspaceKeyDispatcher(store: store)

        _ = dispatcher.handle(keyDown("\t", keyCode: Self.tab, control: true))
        _ = dispatcher.handle(flagsChanged(control: true))

        XCTAssertNotNil(store.paneSwitcher, "still mid-gesture — ⌃ is down")
        XCTAssertEqual(committedTab(store), before, "nothing committed")
    }

    /// Repeat ⌃⇥ while open STEPS the frozen ring; two taps then release lands on the third candidate.
    func testRepeatControlTabStepsThenCommits() {
        let store = makeThreeTabStore()
        let tabs = store.tree.activeSession?.tabs.map(\.id) ?? []
        let dispatcher = WorkspaceKeyDispatcher(store: store)

        _ = dispatcher.handle(keyDown("\t", keyCode: Self.tab, control: true))
        _ = dispatcher.handle(keyDown("\t", keyCode: Self.tab, control: true))
        _ = dispatcher.handle(flagsChanged(control: false))

        XCTAssertEqual(activeTab(store), tabs[1], "two steps reached the third candidate (A → C → B)")
    }

    /// Esc abandons the gesture and is swallowed; the active tab is the one we started on.
    func testEscapeCancelsTheSwitcher() {
        let store = makeThreeTabStore()
        let before = activeTab(store)
        let dispatcher = WorkspaceKeyDispatcher(store: store)

        _ = dispatcher.handle(keyDown("\t", keyCode: Self.tab, control: true))
        let result = dispatcher.handle(keyDown("\u{1B}", keyCode: Self.escape, control: true))

        XCTAssertNil(result, "Esc is consumed by the open switcher")
        XCTAssertNil(store.paneSwitcher, "the switcher closed")
        XCTAssertEqual(activeTab(store), before, "and committed nothing")

        // The release that follows a cancel must not resurrect the commit.
        _ = dispatcher.handle(flagsChanged(control: false))
        XCTAssertEqual(activeTab(store), before, "the trailing ⌃ key-up stays inert after a cancel")
    }

    /// Esc with NO switcher open is not ours — it is the single most important byte a TUI receives.
    func testEscapePassesThroughWhenNoSwitcherIsOpen() {
        let store = makeThreeTabStore()
        let dispatcher = WorkspaceKeyDispatcher(store: store)

        let result = dispatcher.handle(keyDown("\u{1B}", keyCode: Self.escape))

        XCTAssertNotNil(result, "Esc reaches the PTY when no switcher is up")
    }

    /// Return commits an open switcher — the path a palette-opened switcher needs, since it has no held
    /// modifier to release.
    func testReturnCommitsAnOpenSwitcher() {
        let store = makeThreeTabStore()
        let tabs = store.tree.activeSession?.tabs.map(\.id) ?? []
        let dispatcher = WorkspaceKeyDispatcher(store: store)

        _ = dispatcher.handle(keyDown("\t", keyCode: Self.tab, control: true))
        let result = dispatcher.handle(keyDown("\r", keyCode: Self.returnKey, control: true))

        XCTAssertNil(result, "Return is consumed by the open switcher")
        XCTAssertEqual(activeTab(store), tabs[2], "and committed the highlight")
    }

    /// Return with NO switcher open must reach the shell — it is how every command is submitted.
    func testReturnPassesThroughWhenNoSwitcherIsOpen() {
        let store = makeThreeTabStore()
        let dispatcher = WorkspaceKeyDispatcher(store: store)

        let result = dispatcher.handle(keyDown("\r", keyCode: Self.returnKey))

        XCTAssertNotNil(result, "Return reaches the PTY when no switcher is up")
    }

    /// The workspace window losing key mid-gesture (⌘⇥ to another app while ⌃ is down) must abandon the
    /// switcher rather than leave a stuck overlay whose ⌃ key-up will never arrive.
    func testLosingKeyWindowCancelsTheSwitcher() {
        let store = makeThreeTabStore()
        let before = activeTab(store)
        var windowIsKey = true
        let dispatcher = WorkspaceKeyDispatcher(store: store, isWorkspaceWindowKey: { windowIsKey })

        _ = dispatcher.handle(keyDown("\t", keyCode: Self.tab, control: true))
        XCTAssertNotNil(store.paneSwitcher, "precondition: the switcher is open")

        windowIsKey = false
        let result = dispatcher.handle(keyDown("a", keyCode: 0))

        XCTAssertNotNil(result, "keys pass through to the other window")
        XCTAssertNil(store.paneSwitcher, "the stranded switcher was abandoned")
        XCTAssertEqual(activeTab(store), before, "and committed nothing")
    }

    // MARK: - Giving the chord back

    /// ⌃⇥ reaches the PTY as `CSI 9 ; 5 u` under the Kitty keyboard protocol, and a Neovim user who has
    /// bound `<C-Tab>` in their config needs a way to take it back. `unbind: ctrl+tab` must free the
    /// GESTURE, not merely a table row — the gesture never had a row.
    func testUnbindingControlTabFreesTheGestureBackToThePane() {
        WorkspaceBindingRegistry.activeOverrides = KeybindingPreferences(
            unbinds: [.init(key: "tab", control: true)],
        )
        let store = makeThreeTabStore()
        let dispatcher = WorkspaceKeyDispatcher(store: store)

        let result = dispatcher.handle(keyDown("\t", keyCode: Self.tab, control: true))

        XCTAssertNotNil(result, "the unbound chord reaches the pane")
        XCTAssertNil(store.paneSwitcher, "and opens nothing")
    }

    /// Each chord is reclaimed INDIVIDUALLY, exactly as `unbind:` behaves everywhere else in the table:
    /// giving `ctrl+tab` back does not silently surrender `ctrl+shift+tab` too. A user who wants both
    /// unbinds both — we do not infer a second chord they did not name.
    func testUnbindingControlTabLeavesControlShiftTabOwned() {
        WorkspaceBindingRegistry.activeOverrides = KeybindingPreferences(
            unbinds: [.init(key: "tab", control: true)],
        )
        let store = makeThreeTabStore()
        let dispatcher = WorkspaceKeyDispatcher(store: store)

        let result = dispatcher.handle(keyDown("\t", keyCode: Self.tab, control: true, shift: true))

        XCTAssertNil(result, "⌃⇧⇥ was not the chord that was unbound")
        XCTAssertNotNil(store.paneSwitcher, "so it still opens the switcher")
    }

    /// The unbind gates OPENING only. Once a switcher is up (here from the palette, which needs no chord
    /// at all), the gesture owns the keyboard until it commits or cancels — otherwise an unbind would
    /// leave the overlay up with no way to step it.
    func testUnbindDoesNotDisarmAnAlreadyOpenSwitcher() {
        WorkspaceBindingRegistry.activeOverrides = KeybindingPreferences(
            unbinds: [.init(key: "tab", control: true)],
        )
        let store = makeThreeTabStore()
        let dispatcher = WorkspaceKeyDispatcher(store: store)
        store.openOrStepPaneSwitcher(forward: true, armedByModifier: false) // the palette route

        let result = dispatcher.handle(keyDown("\t", keyCode: Self.tab, control: true))

        XCTAssertNil(result, "the open switcher consumes ⇥")
        XCTAssertEqual(store.paneSwitcher?.highlightIndex, 2, "and stepped rather than passing through")
    }
}
#endif
