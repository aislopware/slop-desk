import CoreGraphics
import SlopDeskAgentDetect
import XCTest
@testable import SlopDeskWorkspaceCore

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
        // The production `route(...)` mints a terminal directly for the new-pane verbs (pinned by
        // `NewTerminalPaneTests`); this suite needs kind-controlled panes, so translate those verbs to a direct
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

    // MARK: - AttentionWalk.step (pure walk-vs-pop-home decision)

    /// A press with unvisited queue entries advances to the FIRST one — the queue is already
    /// rank-then-since sorted by the caller (``WorkspaceStore/unseenAttentionPanes``), so `step` itself is
    /// just "first not yet visited".
    func testWalkStepAdvancesToFirstUnvisitedInQueue() {
        let a = PaneID(), b = PaneID()
        XCTAssertEqual(
            AttentionWalk.step(queue: [a, b], visited: [a], origin: a, isPaneLive: { _ in true }),
            .advance(to: b),
        )
    }

    /// Termination is VISITED-SET exhaustion, not queue emptiness: once every queue entry has been
    /// visited, the next press pops back to the recorded origin.
    func testWalkStepPopsHomeWhenQueueFullyVisited() {
        let a = PaneID(), b = PaneID(), origin = PaneID()
        XCTAssertEqual(
            AttentionWalk.step(queue: [a, b], visited: [a, b], origin: origin, isPaneLive: { _ in true }),
            .popHome(to: origin),
        )
    }

    /// An origin closed mid-triage pops to `nil` (the caller treats this as a silent no-op) rather than
    /// resurrecting a dead pane id.
    func testWalkStepPopHomeTargetIsNilWhenOriginClosed() {
        let a = PaneID(), origin = PaneID()
        XCTAssertEqual(
            AttentionWalk.step(queue: [a], visited: [a], origin: origin, isPaneLive: { _ in false }),
            .popHome(to: nil),
        )
    }

    /// A cold chord (never started, nothing pending) is the pre-existing single-shot no-op — expressed as
    /// the same nil-target pop-home the caller already no-ops on.
    func testWalkStepPopHomeTargetIsNilWhenNeverStarted() {
        XCTAssertEqual(
            AttentionWalk.step(queue: [], visited: [], origin: nil, isPaneLive: { _ in true }),
            .popHome(to: nil),
        )
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

    /// ⌘⇧U now reads ``WorkspaceStore/unseenAttentionPanes`` — the SAME list the title menu renders — as its
    /// ONE shared source, not the ``ClaudeStatus``-only ``AttentionJump``. A failed-command `.error` badge
    /// (``WorkspaceStore/panePendingCompletion``, whose `agentStatus` stays `.none`) is reachable as a
    /// result, where the old `AttentionJump`-only selector could never see it.
    func testJumpReachesFailedCommandErrorPane() throws {
        let store = makeTreeStore()
        let firstPane = try XCTUnwrap(store.tree.allPaneIDs().first)
        route(.newTab, store)
        XCTAssertNotEqual(store.tree.activeSession?.activeTab?.activePane, firstPane)
        store.setCompletionBadge(.failure, for: firstPane) // .error — agentStatus never leaves .none

        store.jumpToOldestAttentionPane()
        XCTAssertEqual(
            store.tree.activeSession?.activeTab?.activePane, firstPane,
            "⌘⇧U reaches a pane AttentionJump.oldestPane's ClaudeStatus-only view could never select",
        )
    }

    // MARK: - ⌘⇧U walks the queue with an explicit visited-set

    /// A store with THREE background `.needsPermission` panes at distinct `since` stamps (oldest → newest:
    /// `b`, `c`, `d`) plus the still-focused `origin` — the walk's starting point.
    private struct BlockedTrio {
        let store: WorkspaceStore
        let origin: PaneID
        let b: PaneID
        let c: PaneID
        let d: PaneID
    }

    private func makeStoreWithThreeBackgroundBlockedPanes() throws -> BlockedTrio {
        let store = makeTreeStore()
        let origin = try XCTUnwrap(store.tree.allPaneIDs().first)
        route(.newTab, store)
        let b = try XCTUnwrap(store.tree.activeSession?.activeTab?.activePane)
        route(.newTab, store)
        let c = try XCTUnwrap(store.tree.activeSession?.activeTab?.activePane)
        route(.newTab, store)
        let d = try XCTUnwrap(store.tree.activeSession?.activeTab?.activePane)
        store.focusPaneTree(origin)
        store.setAgentStatus(.needsPermission, for: b, at: Date(timeIntervalSinceReferenceDate: 1000))
        store.setAgentStatus(.needsPermission, for: c, at: Date(timeIntervalSinceReferenceDate: 2000))
        store.setAgentStatus(.needsPermission, for: d, at: Date(timeIntervalSinceReferenceDate: 3000))
        return BlockedTrio(store: store, origin: origin, b: b, c: c, d: d)
    }

    /// Repeated presses step b → c → d WITHOUT bouncing: each visited-but-still-blocked pane re-enters
    /// `unseenAttentionPanes` the instant focus leaves it (only `isPaneFocused` excludes it), so without a
    /// visited-set the raw queue head would oscillate between the two most recently left panes forever.
    /// Exhausting all three pops back to `origin`.
    func testWalkAdvancesThroughVisitedSetWithoutBouncing() throws {
        let fixture = try makeStoreWithThreeBackgroundBlockedPanes()
        let store = fixture.store
        func active() -> PaneID? { store.tree.activeSession?.activeTab?.activePane }

        store.jumpToOldestAttentionPane()
        XCTAssertEqual(active(), fixture.b, "press 1 → the oldest blocked pane")
        store.jumpToOldestAttentionPane()
        XCTAssertEqual(active(), fixture.c, "press 2 → the next unvisited pane, not back to b")
        store.jumpToOldestAttentionPane()
        XCTAssertEqual(active(), fixture.d, "press 3 → the next unvisited pane, skipping both b and c")
        store.jumpToOldestAttentionPane()
        XCTAssertEqual(active(), fixture.origin, "press 4 → the visited-set is exhausted; pop back to origin")
    }

    /// The press AFTER pop-home starts a FRESH walk over whatever the queue then holds — the panes skimmed
    /// in the prior walk are re-offered, oldest-first, exactly like a cold chord.
    func testWalkFreshStartAfterPopHomeReOffersSkimmedPanes() throws {
        let fixture = try makeStoreWithThreeBackgroundBlockedPanes()
        let store = fixture.store
        for _ in 0..<4 { store.jumpToOldestAttentionPane() } // walk b → c → d → pop-home
        XCTAssertEqual(
            store.tree.activeSession?.activeTab?.activePane, fixture.origin, "precondition: popped home",
        )

        store.jumpToOldestAttentionPane()
        XCTAssertEqual(
            store.tree.activeSession?.activeTab?.activePane, fixture.b,
            "a fresh walk re-offers the oldest still-blocked pane — nothing is permanently skipped",
        )
    }

    /// A `.done` visit runs the STRONGER `clearAgentBadge` acknowledge (not the weaker plain-focus
    /// completion-badge clear) — it settles `agentStatus .done → .idle`, so the badge is gone for good, not
    /// just hidden while focused.
    func testWalkVisitClearsADoneBadgePermanently() throws {
        let store = makeTreeStore()
        let origin = try XCTUnwrap(store.tree.allPaneIDs().first)
        route(.newTab, store)
        let finished = try XCTUnwrap(store.tree.activeSession?.activeTab?.activePane)
        store.focusPaneTree(origin)
        store.setAgentStatus(.done, for: finished)
        XCTAssertTrue(store.hasUnseenAttention, "precondition: the unread finish lights the dot")

        store.jumpToOldestAttentionPane()
        XCTAssertEqual(store.tree.activeSession?.activeTab?.activePane, finished)
        XCTAssertEqual(
            store.agentStatus(for: finished), .idle,
            "the walk-visit settles .done → .idle — the badge is truly acknowledged, not merely unfocused",
        )
        store.focusPaneTree(origin) // leave it
        XCTAssertFalse(store.hasUnseenAttention, "the finished pane's badge stays gone once you look away")
    }

    /// A `.needsPermission` visit must NOT fake-clear a live approval gate: `clearAgentBadge` no-ops on the
    /// agent signal by its own contract, so the pane re-enters `unseenAttentionPanes` the moment focus
    /// leaves it — it left the WALK by visited-set membership only, not because it stopped being blocked.
    func testWalkVisitDoesNotFakeClearALiveNeedsPermissionGate() throws {
        let fixture = try makeStoreWithThreeBackgroundBlockedPanes()
        let store = fixture.store
        store.jumpToOldestAttentionPane()
        XCTAssertEqual(store.tree.activeSession?.activeTab?.activePane, fixture.b)
        XCTAssertEqual(
            store.agentStatus(for: fixture.b), .needsPermission,
            "a live approval gate is never faked away by the walk's visit-acknowledge",
        )
        store.focusPaneTree(fixture.origin)
        XCTAssertTrue(
            store.unseenAttentionPanes.map(\.pane).contains(fixture.b),
            "b re-enters the dot set the instant focus leaves it — still genuinely blocked",
        )
    }

    /// If the origin pane closes mid-triage, the exhausted-queue press is a SILENT no-op (focus stays put)
    /// rather than resurrecting a dead pane id.
    func testWalkPopHomeIsSilentNoOpWhenOriginClosed() throws {
        let fixture = try makeStoreWithThreeBackgroundBlockedPanes()
        let store = fixture.store
        store.jumpToOldestAttentionPane() // → b
        store.closePaneTree(fixture.origin) // origin gone mid-triage
        store.jumpToOldestAttentionPane() // → c
        store.jumpToOldestAttentionPane() // → d (walk now exhausted)
        let beforePop = store.tree.activeSession?.activeTab?.activePane

        store.jumpToOldestAttentionPane() // would pop-home, but origin no longer exists
        XCTAssertEqual(
            store.tree.activeSession?.activeTab?.activePane, beforePop,
            "a closed-origin pop-home press is a silent no-op — focus stays exactly where it was",
        )
    }

    /// ANY focus change NOT driven by the walk's own step — a manual tab click, ⌘1-9, a session switch,
    /// Peek & Reply — abandons the walk silently: the NEXT ⌘⇧U press starts fresh from the new focus, and
    /// the discarded visited-set means an already-visited pane is offered again.
    func testWalkAbandonedByManualFocusChangeStartsFreshNextPress() throws {
        let fixture = try makeStoreWithThreeBackgroundBlockedPanes()
        let store = fixture.store
        store.jumpToOldestAttentionPane() // → b (walk starts)
        XCTAssertEqual(store.tree.activeSession?.activeTab?.activePane, fixture.b)

        store.focusPaneTree(fixture.c) // a MANUAL focus change — not the walk's own step
        store.jumpToOldestAttentionPane()
        XCTAssertEqual(
            store.tree.activeSession?.activeTab?.activePane, fixture.b,
            "the abandoned walk's visited-set is discarded — b (already visited) is offered again",
        )

        // The fresh walk's new origin is `c` (where the manual click landed) — `c` itself was never
        // WALK-visited (a manual click is not a chord visit), so it re-enters the queue the instant this
        // press leaves `b`, and is offered before `d` (earlier `since`).
        store.jumpToOldestAttentionPane() // → c
        XCTAssertEqual(store.tree.activeSession?.activeTab?.activePane, fixture.c)
        store.jumpToOldestAttentionPane() // → d
        XCTAssertEqual(store.tree.activeSession?.activeTab?.activePane, fixture.d)
        store.jumpToOldestAttentionPane() // exhausted → pop home
        XCTAssertEqual(
            store.tree.activeSession?.activeTab?.activePane, fixture.c,
            "pop-home returns to the NEW origin (c, where the manual click landed) — the pre-abandon origin"
                + " was discarded too, not just the visited-set",
        )
    }
}
