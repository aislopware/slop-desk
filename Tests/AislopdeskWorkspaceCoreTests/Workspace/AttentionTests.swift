import AislopdeskAgentDetect
import CoreGraphics
import XCTest
@testable import AislopdeskWorkspaceCore

/// Pins the P3 supervision-cockpit pure logic + store wiring (the "which agent needs me, take me there"
/// affordances):
///
/// - ``AttentionEdge/shouldNotify(prev:current:)`` — the EDGE rule: notify only on a real transition
///   INTO needsPermission/done from a different state.
/// - ``AttentionJump/oldestPane(in:status:)`` — needsPermission-before-done, oldest-first ordering.
/// - The ⌘⇧U chord is registered, maps to `.jumpToAttention`, and is UNIQUE (no collision).
/// - The store edge-notify is COALESCED (a flap does not re-fire) via the `lastNotifiedStatus` memory.
/// - `jumpToOldestAttentionPane()` focuses the right pane across tabs/sessions (switching as needed).
///
/// All tests are hang-safe: no `GhosttySurface`, no `NWConnection`, no `VideoToolbox`, no
/// `UNUserNotificationCenter` — the `onAgentAttention` sink is a closure spy.
@MainActor
final class AttentionTests: XCTestCase {
    // MARK: - Fixtures

    private func makeTreeStore(restoringTree: TreeWorkspace = .defaultWorkspace()) -> WorkspaceStore {
        WorkspaceStore(
            restoringTree: restoringTree,
            liveModel: .tree,
            makeSession: { FakePaneSession($0) },
            liveVideoCap: 2,
        )
    }

    private func route(_ action: WorkspaceAction, _ store: WorkspaceStore) {
        // The production `route(...)` now mints an in-pane `.chooser` pane for the new-pane verbs (pinned by
        // `PaneChooserRoutingTests`); this suite needs REAL panes, so translate those verbs to a direct
        // terminal creation. Every OTHER action routes unchanged.
        switch action {
        case .splitRight: store.splitActivePane(axis: .horizontal, kind: .terminal)
        case .splitDown: store.splitActivePane(axis: .vertical, kind: .terminal)
        case .newTab: store.newTab(kind: .terminal)
        default: WorkspaceBindingRegistry.route(action, to: store)
        }
    }

    // MARK: - AttentionEdge.shouldNotify (pure edge rule)

    /// A transition INTO needsPermission / done from a DIFFERENT state is an attention edge.
    func testEdgeFiresEnteringAttentionStates() {
        XCTAssertTrue(AttentionEdge.shouldNotify(prev: .working, current: .needsPermission))
        XCTAssertTrue(AttentionEdge.shouldNotify(prev: .working, current: .done))
        XCTAssertTrue(AttentionEdge.shouldNotify(prev: .idle, current: .needsPermission))
        XCTAssertTrue(AttentionEdge.shouldNotify(prev: .none, current: .done))
        // done → needsPermission is a real escalation edge (now blocked, was merely finished).
        XCTAssertTrue(AttentionEdge.shouldNotify(prev: .done, current: .needsPermission))
    }

    /// Staying in the same attention state (no transition) is NOT an edge — the coalesce guard.
    func testEdgeDoesNotFireOnSameState() {
        XCTAssertFalse(AttentionEdge.shouldNotify(prev: .needsPermission, current: .needsPermission))
        XCTAssertFalse(AttentionEdge.shouldNotify(prev: .done, current: .done))
    }

    /// Transitions INTO non-attention states (working / idle / none) never notify.
    func testEdgeDoesNotFireEnteringQuietStates() {
        XCTAssertFalse(AttentionEdge.shouldNotify(prev: .needsPermission, current: .working))
        XCTAssertFalse(AttentionEdge.shouldNotify(prev: .done, current: .idle))
        XCTAssertFalse(AttentionEdge.shouldNotify(prev: .working, current: .none))
    }

    /// `isAttention` is the level predicate the ring/glow read.
    func testIsAttentionLevelPredicate() {
        XCTAssertTrue(AttentionEdge.isAttention(.needsPermission))
        XCTAssertTrue(AttentionEdge.isAttention(.done))
        XCTAssertFalse(AttentionEdge.isAttention(.working))
        XCTAssertFalse(AttentionEdge.isAttention(.idle))
        XCTAssertFalse(AttentionEdge.isAttention(.none))
    }

    // MARK: - AttentionJump.oldestPane (pure ordering)

    /// needsPermission ALWAYS wins over done, regardless of position (blocked is the most urgent).
    func testJumpBlockedBeforeDone() {
        let a = PaneID(), b = PaneID(), c = PaneID()
        let status: [PaneID: ClaudeStatus] = [a: .done, b: .needsPermission, c: .done]
        // `b` is blocked even though `a` (done) comes first — blocked wins.
        XCTAssertEqual(AttentionJump.oldestPane(in: [a, b, c]) { status[$0] ?? .none }, b)
    }

    /// Within a bucket the FIRST in traversal order (the oldest/top-most) wins.
    func testJumpOldestWithinBucket() {
        let a = PaneID(), b = PaneID(), c = PaneID()
        let status: [PaneID: ClaudeStatus] = [a: .needsPermission, b: .needsPermission, c: .done]
        XCTAssertEqual(AttentionJump.oldestPane(in: [a, b, c]) { status[$0] ?? .none }, a)
    }

    /// With no blocked pane, the first DONE pane wins.
    func testJumpFallsBackToDone() {
        let a = PaneID(), b = PaneID(), c = PaneID()
        let status: [PaneID: ClaudeStatus] = [a: .working, b: .done, c: .done]
        XCTAssertEqual(AttentionJump.oldestPane(in: [a, b, c]) { status[$0] ?? .none }, b)
    }

    /// All idle/working/none → nil (nothing to jump to).
    func testJumpNilWhenNoAttention() {
        let a = PaneID(), b = PaneID()
        let status: [PaneID: ClaudeStatus] = [a: .working, b: .idle]
        XCTAssertNil(AttentionJump.oldestPane(in: [a, b]) { status[$0] ?? .none })
        XCTAssertNil(AttentionJump.oldestPane(in: [PaneID]()) { _ in .none })
    }

    // MARK: - Chord (⌘⇧U registered, mapped, unique)

    func testJumpChordIsRegistered() {
        let chord = KeyChord(character: "u", [.command, .shift])
        XCTAssertEqual(WorkspaceBindingRegistry.chordTable[chord], .jumpToAttention, "⌘⇧U maps to .jumpToAttention")
    }

    func testJumpBindingIsInTable() throws {
        let binding = try XCTUnwrap(
            WorkspaceBindingRegistry.allBindings.first { $0.id == "view.jumpToAttention" },
            "binding 'view.jumpToAttention' must exist",
        )
        XCTAssertEqual(binding.action, .jumpToAttention)
        XCTAssertFalse(binding.action.requiresActivePane, "jumpToAttention acts globally — no active pane required")
    }

    func testJumpChordIsUnique() {
        let chord = KeyChord(character: "u", [.command, .shift])
        let hits = WorkspaceBindingRegistry.allBindings.filter { $0.chord == chord }
        XCTAssertEqual(hits.count, 1, "⌘⇧U must be bound to exactly one action — no chord collision")
    }

    /// The whole registry must be chord-unique (catches ANY future ⌘⇧U-style collision).
    func testNoTwoBindingsShareAChord() {
        var seen: [KeyChord: String] = [:]
        for binding in WorkspaceBindingRegistry.allBindings {
            guard let chord = binding.chord else { continue }
            if let prior = seen[chord] {
                XCTFail(
                    "chord collision: '\(binding.id)' and '\(prior)' share \(WorkspaceBindingRegistry.glyph(chord))",
                )
            }
            seen[chord] = binding.id
        }
    }

    // MARK: - Store edge-notify (coalesced)

    /// A real entry into needsPermission fires the sink ONCE; a flap (working→needsPermission again)
    /// without leaving the bucket does not re-fire until the state actually leaves and re-enters.
    func testStoreEdgeNotifyIsCoalesced() throws {
        let store = makeTreeStore()
        let pane = try XCTUnwrap(store.tree.allPaneIDs().first)
        var fired: [(needsInput: Bool, name: String)] = []
        store.onAgentAttention = { _, name, needsInput, _ in fired.append((needsInput, name)) }

        store.setAgentStatus(.working, for: pane)
        XCTAssertEqual(fired.count, 0, "working does not notify")

        store.setAgentStatus(.needsPermission, for: pane)
        XCTAssertEqual(fired.count, 1, "entering needsPermission notifies once")
        XCTAssertTrue(fired.last?.needsInput == true)

        // Flap: leave to working, come back to needsPermission → notifies again (genuine re-entry).
        store.setAgentStatus(.working, for: pane)
        store.setAgentStatus(.needsPermission, for: pane)
        XCTAssertEqual(fired.count, 2, "a genuine leave-and-re-enter re-fires")
    }

    /// done → working → done re-fires on the second done (it left the bucket between), but a redundant
    /// re-assert of the SAME status is deduped upstream and never reaches the edge.
    func testStoreDoneEdgeFiresAndDedupes() throws {
        let store = makeTreeStore()
        let pane = try XCTUnwrap(store.tree.allPaneIDs().first)
        var count = 0
        store.onAgentAttention = { _, _, _, _ in count += 1 }

        store.setAgentStatus(.done, for: pane)
        XCTAssertEqual(count, 1)
        store.setAgentStatus(.done, for: pane) // idempotent no-op (paneAgentStatus unchanged)
        XCTAssertEqual(count, 1, "re-asserting the same status does not re-notify")
    }

    /// The store-level done → needsPermission ESCALATION edge re-fires (with needsInput==true): a pane that
    /// already notified `done` and then becomes blocked must announce again, since the human now must act.
    /// This pins the `lastNotifiedStatus` re-arm/escalation branch through `setAgentStatus` (the pure
    /// `AttentionEdge` layer alone does not exercise the stored memory).
    func testStoreEscalatesDoneToNeedsPermission() throws {
        let store = makeTreeStore()
        let pane = try XCTUnwrap(store.tree.allPaneIDs().first)
        var fired: [(needsInput: Bool, name: String)] = []
        store.onAgentAttention = { _, name, needsInput, _ in fired.append((needsInput, name)) }

        store.setAgentStatus(.done, for: pane)
        XCTAssertEqual(fired.count, 1, "entering done notifies once")
        XCTAssertEqual(fired.last?.needsInput, false, "done is not a needs-input edge")

        // Escalate straight from done → needsPermission WITHOUT leaving the attention bucket between.
        store.setAgentStatus(.needsPermission, for: pane)
        XCTAssertEqual(fired.count, 2, "done → needsPermission re-fires (a genuine escalation edge)")
        XCTAssertEqual(fired.last?.needsInput, true, "the escalation edge carries needsInput == true")
    }

    /// The host label is captured and surfaced as the notification detail.
    func testStoreEdgeCarriesLabelDetail() throws {
        let store = makeTreeStore()
        let pane = try XCTUnwrap(store.tree.allPaneIDs().first)
        var detail: String?
        store.onAgentAttention = { _, _, _, d in detail = d }
        store.setAgentLabel("Allow edit to main.swift?", for: pane)
        store.setAgentStatus(.needsPermission, for: pane)
        XCTAssertEqual(detail, "Allow edit to main.swift?")
    }

    // MARK: - jumpToOldestAttentionPane (across tabs/sessions)

    /// Jump focuses the blocked pane in a BACKGROUND tab, switching the active tab to reach it.
    func testJumpFocusesBlockedPaneInOtherTab() throws {
        let store = makeTreeStore()
        let firstPane = try XCTUnwrap(store.tree.allPaneIDs().first)
        // A second tab (new pane) becomes active; mark the FIRST tab's pane blocked.
        route(.newTab, store)
        let secondPane = try XCTUnwrap(store.tree.activeSession?.activeTab?.activePane)
        XCTAssertNotEqual(firstPane, secondPane)
        store.setAgentStatus(.needsPermission, for: firstPane)

        store.jumpToOldestAttentionPane()
        XCTAssertEqual(store.tree.activeSession?.activeTab?.activePane, firstPane, "jumped to the blocked pane")
    }

    /// With nothing needing attention, jump is a no-op (focus stays put).
    func testJumpNoOpWhenNothingNeedsAttention() throws {
        let store = makeTreeStore()
        let pane = try XCTUnwrap(store.tree.allPaneIDs().first)
        route(.newTab, store)
        let active = try XCTUnwrap(store.tree.activeSession?.activeTab?.activePane)
        store.setAgentStatus(.working, for: pane) // not attention-worthy
        store.jumpToOldestAttentionPane()
        XCTAssertEqual(store.tree.activeSession?.activeTab?.activePane, active, "no jump — focus unchanged")
    }
}
