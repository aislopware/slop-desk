// ResolvedChordDispatchTests (WS-B / B3) — the live dispatcher's CORE step pinned headlessly: a keystroke's
// `KeyChord` is looked up in `WorkspaceBindingRegistry.resolvedChordTable` and the resolved action is routed
// via `WorkspaceBindingRegistry.route(action, to: store)`, landing the right store TREE op. This mirrors
// exactly what `WorkspaceKeyDispatcher.handle` does (NSEvent→chord→resolvedChordTable→route) minus the
// AppKit monitor, so the routing contract is provable without a window server.
//
// The override leg reuses the PreferencesStoreApplyTests resolved-chord-routing precedent: an overridden
// chord routes the NEW chord to its action while the OLD default chord no longer resolves (it is freed).
// Backed by `FakePaneSession` — no real client / SCStream / VT / Metal.

import SlopDeskVideoProtocol
import XCTest
@testable import SlopDeskWorkspaceCore

@MainActor
final class ResolvedChordDispatchTests: XCTestCase {
    override func tearDown() {
        WorkspaceBindingRegistry.activeOverrides = KeybindingPreferences()
        super.tearDown()
    }

    private func makeTreeStore() -> WorkspaceStore {
        WorkspaceStore(
            restoringTree: .defaultWorkspace(),
            liveModel: .tree,
            makeSession: { FakePaneSession($0) },
            liveVideoCap: 2,
        )
    }

    private func leaves(_ store: WorkspaceStore) -> [PaneID] { store.tree.allPaneIDs() }

    /// The dispatcher's lookup+route step: resolve a chord against the table, then route the action. The
    /// default ⌘D chord must resolve to `.splitRight` and land the split (one new leaf).
    private func dispatch(_ chord: KeyChord, to store: WorkspaceStore) -> Bool {
        guard let action = WorkspaceBindingRegistry.resolvedChordTable[chord] else { return false }
        WorkspaceBindingRegistry.route(action, to: store)
        return true
    }

    /// The default ⌘D chord resolves to `.splitRight` and routing it lands the split store op (one new leaf,
    /// the new leaf focused) — the full NSEvent-free dispatch contract.
    func testDefaultChordResolvesAndRoutesToSplit() {
        let store = makeTreeStore()
        XCTAssertEqual(leaves(store).count, 1)

        XCTAssertTrue(dispatch(KeyChord(character: "d", [.command]), to: store), "⌘D resolves in the table")

        XCTAssertEqual(leaves(store).count, 2, "routing the resolved .splitRight added one leaf")
    }

    /// A bare unmodified key is NOT in the table → the dispatch is a miss (the live monitor then passes it
    /// through to the PTY). No store mutation occurs. This pins the "never swallow normal typing" boundary at
    /// the table-lookup level the dispatcher relies on.
    func testBareKeyIsNotInTableSoDispatchMissesAndMutatesNothing() {
        let store = makeTreeStore()
        let before = leaves(store).count
        XCTAssertFalse(dispatch(KeyChord(character: "j"), to: store), "a bare key is unbound — a table miss")
        XCTAssertEqual(leaves(store).count, before, "an unbound bare key mutates nothing")
    }

    /// An OVERRIDE that rebinds split-right to ⌘E routes the NEW chord to `.splitRight` (the split lands)
    /// while the OLD ⌘D chord no longer resolves — proving the dispatcher honours the live override table
    /// (reuses the PreferencesStoreApplyTests `testResolvedChordTableRoutesTheOverrideChord` precedent, now
    /// driven all the way through `route` to the store op).
    func testOverriddenChordRoutesNewChordAndFreesOld() {
        WorkspaceBindingRegistry.activeOverrides = KeybindingPreferences(overrides: [
            "pane.splitRight": .init(key: "e", command: true),
        ])
        let store = makeTreeStore()
        XCTAssertEqual(leaves(store).count, 1)

        // The OLD default chord is freed: it no longer resolves, so dispatching it is a miss + no mutation.
        XCTAssertFalse(dispatch(KeyChord(character: "d", [.command]), to: store), "⌘D is freed by the override")
        XCTAssertEqual(leaves(store).count, 1, "the freed old chord mutates nothing")

        // The NEW chord resolves to .splitRight and routing it lands the split.
        XCTAssertTrue(dispatch(KeyChord(character: "e", [.command]), to: store), "⌘E now resolves to splitRight")
        XCTAssertEqual(leaves(store).count, 2, "routing the override chord landed the split")
    }

    /// The prefix-machine path the dispatcher feeds: after the configured prefix arms, a bound follow-up
    /// chord resolves its action against `resolvedChordTable` (the dispatcher's `resolveAfterPrefix`), so a
    /// tmux-style ⌃A→⌘D prefix sequence routes the SAME `.splitRight` op. Pins the prefix→route wiring.
    func testPrefixThenBoundChordResolvesViaTheSameTable() {
        let store = makeTreeStore()
        let machine = PrefixStateMachine(
            prefix: KeyChord(character: "a", [.control]),
            resolveAfterPrefix: { WorkspaceBindingRegistry.resolvedChordTable[$0] },
        )
        // Arm on the prefix (swallowed), then feed the bound chord.
        XCTAssertEqual(machine.feed(KeyChord(character: "a", [.control]), at: 0), .consumedArm)
        guard case let .resolved(action) = machine.feed(KeyChord(character: "d", [.command]), at: 0.1) else {
            XCTFail("a bound follow-up chord should resolve while armed")
            return
        }
        XCTAssertEqual(action, .splitRight)
        WorkspaceBindingRegistry.route(action, to: store)
        XCTAssertEqual(leaves(store).count, 2, "the prefix-resolved action routed the split")
    }
}
