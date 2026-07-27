import Defaults
import SlopDeskAgentDetect
import SlopDeskWorkspaceModel
import XCTest
@testable import SlopDeskWorkspaceCore

/// The WorkspaceStore wiring behind the tab-context-menu badge controls — the per-pane
/// ``AgentBadgeGates`` override (override-else-global resolution), the single-bit toggle, and "Clear Badge"
/// (acknowledge completion/attention so the badge drops). Hang-safe: `FakePaneSession`, no surface/socket.
@MainActor
final class AgentBadgeStoreTests: XCTestCase {
    private func makeStore() -> WorkspaceStore {
        let store = WorkspaceStore(
            restoringTree: .defaultWorkspace(),
            liveModel: .tree,
            makeSession: { seed in FakePaneSession(seed.spec) },
            liveVideoCap: 2,
        )
        store.attachLoopbackWorkspaceDocument()
        return store
    }

    private func firstPane(_ store: WorkspaceStore) throws -> PaneID {
        try XCTUnwrap(store.tree.allPaneIDs().first)
    }

    // MARK: Per-pane override resolution

    /// With NO per-pane override, a pane follows the GLOBAL default (``SettingsKey/agentBadgeGates``); a set
    /// override wins; clearing the override (`nil`) reverts to the global again.
    func testPerPaneOverrideBeatsGlobalThenReverts() throws {
        let store = makeStore()
        let id = try firstPane(store)

        XCTAssertEqual(store.agentBadgeGates(for: id), SettingsKey.agentBadgeGates, "no override ⇒ global default")

        let override = AgentBadgeGates(
            badgeWhileProcessing: false, badgeWhenComplete: true, badgeWhenAwaitingInput: false,
        )
        store.setAgentBadgeOverride(override, for: id)
        XCTAssertEqual(store.agentBadgeGates(for: id), override, "override wins over the global default")

        store.setAgentBadgeOverride(nil, for: id)
        XCTAssertEqual(store.agentBadgeGates(for: id), SettingsKey.agentBadgeGates, "clearing reverts to global")
    }

    /// A change to the GLOBAL settings key flows through ``WorkspaceStore/agentBadgeGates(for:)`` for a pane
    /// with no override — proving the SettingsKey → store wiring (not a hard-coded all-on).
    func testGlobalSettingChangeReachesUnoverriddenPane() throws {
        let prior = Defaults[.agentBadgeWhileProcessing]
        defer { Defaults[.agentBadgeWhileProcessing] = prior }
        let store = makeStore()
        let id = try firstPane(store)

        Defaults[.agentBadgeWhileProcessing] = false
        XCTAssertFalse(
            store.agentBadgeGates(for: id).badgeWhileProcessing,
            "the global toggle reaches an un-overridden pane",
        )
    }

    /// The context-menu toggle flips ONE bit, seeding from the pane's current EFFECTIVE gates so the other
    /// two are preserved (the first flip is relative to the global default, not a blank slate).
    func testToggleAgentBadgeGateFlipsOneBitFromEffective() throws {
        let prior = (
            Defaults[.agentBadgeWhileProcessing],
            Defaults[.agentBadgeWhenComplete],
            Defaults[.agentBadgeWhenAwaitingInput],
        )
        defer {
            Defaults[.agentBadgeWhileProcessing] = prior.0
            Defaults[.agentBadgeWhenComplete] = prior.1
            Defaults[.agentBadgeWhenAwaitingInput] = prior.2
        }
        Defaults[.agentBadgeWhileProcessing] = true
        Defaults[.agentBadgeWhenComplete] = true
        Defaults[.agentBadgeWhenAwaitingInput] = true

        let store = makeStore()
        let id = try firstPane(store)
        store.toggleAgentBadgeGate(.whenComplete, for: id)

        let gates = store.agentBadgeGates(for: id)
        XCTAssertFalse(gates.badgeWhenComplete, "the flipped bit is off")
        XCTAssertTrue(gates.badgeWhileProcessing, "the other two preserved from the (all-on) effective gates")
        XCTAssertTrue(gates.badgeWhenAwaitingInput)
    }

    // MARK: Clear Badge

    /// "Clear Badge" acknowledges the pane: a pending completion badge is dropped AND a `.done` agent settles
    /// to `.idle` (no finished dot). Revert-to-confirm-fail: without `clearAgentBadge` clearing both, the
    /// completion badge / done status would persist.
    func testClearBadgeAcknowledgesCompletionAndDoneStatus() throws {
        let store = makeStore()
        let id = try firstPane(store)

        store.setCompletionBadge(.success, for: id)
        store.setAgentStatus(.done, for: id)
        XCTAssertEqual(store.pendingCompletion(for: id), .success)
        XCTAssertEqual(store.agentStatus(for: id), .done)

        store.clearAgentBadge(id)
        XCTAssertNil(store.pendingCompletion(for: id), "completion badge cleared")
        XCTAssertEqual(store.agentStatus(for: id), .idle, "a done agent settles to idle (no badge)")
    }

    /// Clear Badge leaves a LIVE state alone — a still-working agent keeps its `.working` status (Clear Badge
    /// acknowledges unread output, it never fakes-away an active signal, and is NEVER an approval gate).
    func testClearBadgeDoesNotTouchWorkingAgent() throws {
        let store = makeStore()
        let id = try firstPane(store)

        store.setAgentStatus(.working, for: id)
        store.clearAgentBadge(id)
        XCTAssertEqual(store.agentStatus(for: id), .working, "a working agent is untouched by Clear Badge")
    }

    // MARK: Command-start stale-badge clear (progress cluster)

    /// A new command STARTING (OSC 133;C → `handleCommandStarted`) clears a STALE `.failure` completion badge
    /// so a busy background pane resolves to the running spinner, not the prior run's error triangle. The
    /// resolver ranks a `.failure` completion ABOVE the running spinner, so WITHOUT the clear a busy pane with a
    /// stale failure shows `.error`; the first assertion proves that hazard, the clear fixes it.
    /// Revert-to-confirm-fail: drop the `setCompletionBadge(nil,…)` in `handleCommandStarted` and the badge
    /// persists, so the post-clear assertions fail.
    func testCommandStartClearsStaleCompletionBadgeSoSpinnerShows() throws {
        let store = makeStore()
        let id = try firstPane(store)

        store.setCompletionBadge(.failure, for: id)
        // The hazard: a stale failure outranks the running spinner in the resolver (error > running), so a
        // pane with live OSC 9;4 progress would keep showing the stale red dot instead of the spinner.
        XCTAssertEqual(
            TabBadgeResolver.badge(
                agent: .none, completion: store.pendingCompletion(for: id), isBusy: true, foregroundProcess: nil,
                progress: .indeterminate,
            ),
            .error,
            "a stale failure badge would hide the running spinner on a busy pane",
        )

        store.handleCommandStarted(id: id)
        XCTAssertNil(store.pendingCompletion(for: id), "the command-start edge clears the stale failure badge")
        XCTAssertEqual(
            TabBadgeResolver.badge(
                agent: .none, completion: store.pendingCompletion(for: id), isBusy: true, foregroundProcess: nil,
                progress: .indeterminate,
            ),
            .commandRunning,
            "with the stale badge cleared, the progressing pane now shows the command-running marker",
        )
    }

    // MARK: The unread agent-finish latch (`paneUnseenDone`)

    /// The latch lifecycle: a `.done` edge on a pane the user is NOT watching latches; the host's own
    /// done→idle decay does NOT clear it (the badge survives — the whole point); visiting the pane's
    /// tab clears it. Revert-to-confirm-fail: without the latch, the `.idle` push would drop the badge
    /// 8 s after every agent finish.
    func testUnseenDoneLatchSurvivesDecayUntilVisited() throws {
        let store = makeStore()
        let backgroundPane = try firstPane(store)
        store.newTab(kind: .terminal, launchGrace: .zero) // selects the NEW tab → pane 1 is background

        store.setAgentStatus(.done, for: backgroundPane)
        XCTAssertTrue(store.paneUnseenDone.contains(backgroundPane), "an unwatched finish latches")

        // The host machine decays done → idle seconds later; the latch must survive the push.
        store.setAgentStatus(.idle, for: backgroundPane)
        XCTAssertTrue(store.paneUnseenDone.contains(backgroundPane), "the host decay never clears unreadness")
        XCTAssertEqual(
            TabBadgeGating.resolve(
                agent: store.agentStatus(for: backgroundPane), completion: nil, isBusy: true,
                foregroundProcess: nil,
                unseenAgentDone: store.paneUnseenDone.contains(backgroundPane),
                agentGates: .allOn, commandGates: .allOn,
            ),
            .finished,
            "the rail still resolves the finished dot over the busy claude shell",
        )

        // Visiting the tab acknowledges every pane in it (the selectTab badge auto-clear).
        store.selectTab(0)
        XCTAssertFalse(store.paneUnseenDone.contains(backgroundPane), "visiting the tab clears the latch")
    }

    /// A finish the user WATCHED happen (the pane is visible — active tab, app active) never latches:
    /// it still gets the brief `.completed` flash via the live `.done` status, but no sticky unread
    /// marker (the t3code/herdr "watching = seen" rule).
    func testDoneWhileVisibleDoesNotLatch() throws {
        let store = makeStore()
        let id = try firstPane(store) // the active tab's pane; isAppActive defaults true
        store.setAgentStatus(.done, for: id)
        XCTAssertFalse(store.paneUnseenDone.contains(id), "a watched finish is pre-seen")
        XCTAssertEqual(store.agentStatus(for: id), .done, "the live status still flashes the checkmark")
    }

    /// New agent activity supersedes an unread finish: a latched pane entering `.working` (a fresh
    /// prompt) drops the latch — the unread marker never lies about a turn the agent already moved past.
    func testNewActivityClearsUnseenDoneLatch() throws {
        let store = makeStore()
        let backgroundPane = try firstPane(store)
        store.newTab(kind: .terminal, launchGrace: .zero)

        store.setAgentStatus(.done, for: backgroundPane)
        XCTAssertTrue(store.paneUnseenDone.contains(backgroundPane))
        store.setAgentStatus(.working, for: backgroundPane)
        XCTAssertFalse(store.paneUnseenDone.contains(backgroundPane), "a new turn replaces the unread finish")
    }

    // MARK: The working-turn clock (`paneWorkingSince` — the per-pane turn-start stamp)

    /// The elapsed anchor's lifecycle: the genuine entry into `.working` stamps the turn start; a
    /// re-push of the same status (the idempotency guard) cannot reset it, so mid-turn label churn
    /// keeps one clock; leaving `.working` (done / blocked / idle) retires the stamp.
    func testWorkingSinceStampsOnTheWorkingEdgeOnly() throws {
        let store = makeStore()
        let id = try firstPane(store)
        let start = Date(timeIntervalSinceReferenceDate: 100)

        store.setAgentStatus(.working, for: id, at: start)
        XCTAssertEqual(store.paneWorkingSince[id], start, "entering .working starts the turn clock")

        store.setAgentStatus(.working, for: id, at: start.addingTimeInterval(30))
        XCTAssertEqual(store.paneWorkingSince[id], start, "a same-status re-push never resets the clock")

        store.setAgentStatus(.done, for: id, at: start.addingTimeInterval(60))
        XCTAssertNil(store.paneWorkingSince[id], "leaving .working retires the stamp")

        // A fresh turn re-stamps from its own edge.
        let second = start.addingTimeInterval(90)
        store.setAgentStatus(.working, for: id, at: second)
        XCTAssertEqual(store.paneWorkingSince[id], second)
        store.setAgentStatus(.needsPermission, for: id, at: second.addingTimeInterval(5))
        XCTAssertNil(store.paneWorkingSince[id], "a blocked pane shows the hand, not a ticking clock")
    }

    // MARK: Manual per-tab badge override (the `tab badge --kind` CLI seam)

    private func firstTab(_ store: WorkspaceStore) throws -> TabID {
        try XCTUnwrap(store.tree.activeSession?.activeTab?.id)
    }

    /// Set / replace / clear: a manual override lands under its ``TabID``, reads back, a follow-up call
    /// replaces it, and `nil` drops it (the tab falls back to its derived badge). Without
    /// `setTabBadgeOverride` actually writing the dict, every read here would be nil.
    func testTabBadgeOverrideSetReplaceClear() throws {
        let store = makeStore()
        let tab = try firstTab(store)

        XCTAssertNil(store.tabBadgeOverride(for: tab), "no manual override by default")
        store.setTabBadgeOverride(.error, for: tab)
        XCTAssertEqual(store.tabBadgeOverride(for: tab), .error, "the override is stored under the tab id")
        store.setTabBadgeOverride(.running, for: tab)
        XCTAssertEqual(store.tabBadgeOverride(for: tab), .running, "a follow-up `tab badge` replaces it")
        store.setTabBadgeOverride(nil, for: tab)
        XCTAssertNil(store.tabBadgeOverride(for: tab), "nil clears the override")
    }

    /// A closed tab's manual override is pruned on the ``reconcileTree`` sidebar-mirror sweep (it is
    /// TabID-keyed, like the recency mirror) — no stale badge on a recycled id, no unbounded growth.
    func testTabBadgeOverridePrunedWhenTabCloses() throws {
        let store = makeStore()
        store.newTab(kind: .terminal, launchGrace: .zero)
        let newTab = try firstTab(store)
        store.setTabBadgeOverride(.completed, for: newTab)
        XCTAssertEqual(store.tabBadgeOverride(for: newTab), .completed)

        store.closeTab(newTab)
        XCTAssertNil(
            store.tabBadgeOverride(for: newTab),
            "a closed tab's manual badge override drops out on the reconcileTree prune",
        )
    }
}
