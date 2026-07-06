import Defaults
import SlopDeskAgentDetect
import XCTest
@testable import SlopDeskWorkspaceCore

/// E13 WI-3: the WorkspaceStore wiring behind the tab-context-menu badge controls — the per-pane
/// ``AgentBadgeGates`` override (override-else-global resolution), the single-bit toggle, and "Clear Badge"
/// (acknowledge completion/attention so the badge drops). Hang-safe: `FakePaneSession`, no surface/socket.
@MainActor
final class AgentBadgeStoreTests: XCTestCase {
    private func makeStore() -> WorkspaceStore {
        WorkspaceStore(
            restoringTree: .defaultWorkspace(),
            liveModel: .tree,
            makeSession: { FakePaneSession($0) },
            liveVideoCap: 2,
        )
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
        // The hazard: a stale failure outranks the running spinner in the resolver (error > running), so a busy
        // pane would keep showing the error triangle instead of the spinner.
        XCTAssertEqual(
            TabBadgeResolver.badge(
                agent: .none, completion: store.pendingCompletion(for: id), isBusy: true, foregroundProcess: nil,
            ),
            .error,
            "a stale failure badge would hide the running spinner on a busy pane",
        )

        store.handleCommandStarted(id: id)
        XCTAssertNil(store.pendingCompletion(for: id), "the command-start edge clears the stale failure badge")
        XCTAssertEqual(
            TabBadgeResolver.badge(
                agent: .none, completion: store.pendingCompletion(for: id), isBusy: true, foregroundProcess: nil,
            ),
            .commandRunning,
            "with the stale badge cleared, the busy pane now shows the command-running marker",
        )
    }

    // MARK: E20 ES-E20-3 — manual per-tab badge override (the `tab badge --kind` CLI seam)

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
