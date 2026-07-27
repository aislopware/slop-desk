import SlopDeskAgentDetect
import SlopDeskWorkspaceModel
import XCTest
@testable import SlopDeskWorkspaceCore

/// The FOCUSED-pane finish settle: a finished agent turn on the pane the user is actually watching
/// acknowledges ITSELF after ``WorkspaceStore/focusedDoneSettleWindow``, instead of waiting for a
/// selection change it may never get.
///
/// The gap this closes: the unread latch (``WorkspaceStore/paneUnseenDone``) is cleared only by
/// ``WorkspaceStore/clearAgentBadge(_:)``, which runs on a tab SELECT / rail click / ⌘⇧U. Returning to
/// the app re-selects nothing, so a turn that finished while you were away kept its marker on the very
/// pane you were staring at until you clicked away and back.
///
/// The scope is deliberately narrow — only a pane that is focused AND in an active app settles. An
/// unfocused pane keeps the old contract exactly: unread until visited, however long that takes.
/// Hang-safe: `FakePaneSession`, no surface/socket, injected clock.
@MainActor
final class FocusedDoneSettleTests: XCTestCase {
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

    private let base = Date(timeIntervalSinceReferenceDate: 9000)
    private var pastWindow: Date { base.addingTimeInterval(WorkspaceStore.focusedDoneSettleWindow + 1) }

    // MARK: The settle itself

    /// The headline: a finish latched while the user was AWAY, then watched for the whole window, settles
    /// on its own — no click needed. Revert-to-confirm-fail: without the settle the latch (and its
    /// `.finished` rail marker) survives every refresh forever.
    func testWatchedUnreadFinishSettlesAfterTheWindow() throws {
        let store = makeStore()
        let id = try firstPane(store)

        // The turn finishes while the app is in the background → the unread latch arms.
        store.isAppActive = false
        store.setAgentStatus(.done, for: id, at: base)
        XCTAssertTrue(store.paneUnseenDone.contains(id), "a finish nobody watched latches")

        // Coming back does NOT acknowledge on contact — the marker is what tells you a turn ended.
        store.isAppActive = true
        XCTAssertTrue(store.paneUnseenDone.contains(id), "returning to the app does not clear on contact")
        XCTAssertNotNil(store.paneDoneDwellSince[id], "the watch clock starts on the focused pane")
        // Re-point the clock the app-active edge just stamped with the real `Date()` onto the injected one.
        store.paneDoneDwellSince[id] = base

        store.refreshFocusedDoneSettle(at: pastWindow)
        XCTAssertFalse(store.paneUnseenDone.contains(id), "a whole window of watching acknowledges the finish")
        XCTAssertNil(store.paneDoneDwellSince[id], "the settled pane drops its watch clock")
    }

    /// A LIVE `.done` status on the focused pane settles the same way — the host's own done→idle decay is
    /// the usual path, but a pane whose host never decays (a report-driven agent) must not stay marked.
    func testFocusedLiveDoneStatusSettlesToIdle() throws {
        let store = makeStore()
        let id = try firstPane(store)

        store.setAgentStatus(.done, for: id, at: base) // focused + app active ⇒ no latch, live `.done`
        XCTAssertFalse(store.paneUnseenDone.contains(id), "a watched finish is pre-seen (no latch)")
        XCTAssertEqual(store.agentStatus(for: id), .done)

        store.refreshFocusedDoneSettle(at: base)
        store.refreshFocusedDoneSettle(at: pastWindow)
        XCTAssertEqual(store.agentStatus(for: id), .idle, "the watched finish settles to idle")
    }

    /// Halfway through the window is still unread — the settle is a dwell, not a debounce-free clear.
    func testFinishIsStillUnreadBeforeTheWindowElapses() throws {
        let store = makeStore()
        let id = try firstPane(store)

        store.isAppActive = false
        store.setAgentStatus(.done, for: id, at: base)
        store.isAppActive = true
        store.paneDoneDwellSince[id] = base // the app-active edge stamped `Date()`; pin it to the fake clock
        store.refreshFocusedDoneSettle(at: base.addingTimeInterval(WorkspaceStore.focusedDoneSettleWindow / 2))

        XCTAssertTrue(store.paneUnseenDone.contains(id), "half a window of watching is not an acknowledge")
    }

    // MARK: The unfocused contract (unchanged)

    /// The old behaviour, pinned: an UNFOCUSED pane never settles on its own, no matter how long it sits.
    /// This is the whole point of the latch — a finish you were not there for waits for you.
    func testUnfocusedPaneNeverSettlesOnItsOwn() throws {
        let store = makeStore()
        let background = try firstPane(store)
        store.newTab(kind: .terminal, launchGrace: .zero) // selects the NEW tab → pane 1 is background

        store.setAgentStatus(.done, for: background, at: base)
        XCTAssertTrue(store.paneUnseenDone.contains(background))

        store.refreshFocusedDoneSettle(at: base)
        store.refreshFocusedDoneSettle(at: base.addingTimeInterval(3600))
        XCTAssertTrue(store.paneUnseenDone.contains(background), "an unwatched finish waits forever")
        XCTAssertNil(store.paneDoneDwellSince[background], "an unfocused pane never even starts a watch clock")
    }

    /// A BACKGROUNDED app is nobody watching: the focused leaf's clock stops with it, so a marker cannot
    /// expire behind the user's back while they are in another app.
    func testInactiveAppStopsTheWatchClock() throws {
        let store = makeStore()
        let id = try firstPane(store)

        store.setAgentStatus(.done, for: id, at: base)
        store.refreshFocusedDoneSettle(at: base)
        XCTAssertNotNil(store.paneDoneDwellSince[id], "watching starts while the app is active")

        store.isAppActive = false
        store.refreshFocusedDoneSettle(at: base.addingTimeInterval(1))
        XCTAssertNil(store.paneDoneDwellSince[id], "leaving the app abandons the watch")

        store.refreshFocusedDoneSettle(at: pastWindow)
        XCTAssertEqual(store.agentStatus(for: id), .done, "a window's worth of ABSENCE settles nothing")
    }

    /// Focus leaving and returning RESTARTS the clock — the window measures an unbroken watch, so a pane
    /// glanced at twice for a second each never reaches the threshold.
    func testFocusLeavingRestartsTheWatchClock() throws {
        let store = makeStore()
        let watched = try firstPane(store)
        store.setAgentStatus(.done, for: watched, at: base)
        store.refreshFocusedDoneSettle(at: base)

        store.newTab(kind: .terminal, launchGrace: .zero) // focus leaves
        store.refreshFocusedDoneSettle(at: base.addingTimeInterval(1))
        XCTAssertNil(store.paneDoneDwellSince[watched], "the clock is abandoned when focus leaves")

        store.selectTab(0) // back — `selectTab` acknowledges outright, so re-arm a fresh finish
        store.setAgentStatus(.done, for: watched, at: base.addingTimeInterval(2))
        store.refreshFocusedDoneSettle(at: base.addingTimeInterval(2))
        XCTAssertEqual(
            store.paneDoneDwellSince[watched], base.addingTimeInterval(2), "the returning watch starts from zero",
        )
    }

    // MARK: What is (not) a settle candidate

    /// Only a FINISHED turn settles: a working agent and a blocked one are live signals, never unread
    /// output, so neither starts a clock (and a blocked pane can never be silenced by looking at it).
    func testLiveStatusesNeverStartTheWatchClock() throws {
        let store = makeStore()
        let id = try firstPane(store)

        for status in [ClaudeStatus.working, .needsPermission, .idle] {
            store.setAgentStatus(status, for: id, at: base)
            store.refreshFocusedDoneSettle(at: base)
            XCTAssertNil(store.paneDoneDwellSince[id], "\(status) is not an unread finish")
        }
    }

    /// The agent moving on supersedes a pending watch: a new turn starting drops the clock along with the
    /// marker, so the settle can never fire onto a live turn.
    func testNewTurnDropsThePendingWatch() throws {
        let store = makeStore()
        let id = try firstPane(store)

        store.setAgentStatus(.done, for: id, at: base)
        store.refreshFocusedDoneSettle(at: base)
        XCTAssertNotNil(store.paneDoneDwellSince[id])

        store.setAgentStatus(.working, for: id, at: base.addingTimeInterval(1))
        XCTAssertNil(store.paneDoneDwellSince[id], "a new turn retires the pending watch")

        store.refreshFocusedDoneSettle(at: pastWindow)
        XCTAssertEqual(store.agentStatus(for: id), .working, "the late one-shot cannot settle a live turn")
    }

    // MARK: Wiring (the drivers that must call the refresh)

    /// Starting a watch ARMS a one-shot at the window boundary — without it nothing would ever re-evaluate a
    /// quiet pane (the store mutates no further once the agent is done), and the settle would only happen as
    /// a side effect of unrelated traffic. Fails on the un-wired code: nothing is captured.
    func testStartingAWatchArmsTheBoundaryOneShot() throws {
        let store = makeStore()
        let id = try firstPane(store)
        var captured: (delay: TimeInterval, fire: @MainActor () -> Void)?
        store.doneSettleScheduler = { delay, fire in captured = (delay, fire) }

        store.setAgentStatus(.done, for: id, at: base)

        let oneShot = try XCTUnwrap(captured, "a focused finish must arm the settle one-shot")
        XCTAssertEqual(oneShot.delay, WorkspaceStore.focusedDoneSettleWindow, "armed at the window boundary")
        XCTAssertEqual(store.agentStatus(for: id), .done, "arming alone settles nothing")
    }

    /// Returning to the app is what starts the watch in the case that motivated this: the turn finished
    /// while you were elsewhere, and the pane you come back to is already focused (so no selection change
    /// ever fires). The `isAppActive` edge must drive the refresh.
    func testReturningToTheAppStartsTheWatch() throws {
        let store = makeStore()
        let id = try firstPane(store)

        store.isAppActive = false
        store.setAgentStatus(.done, for: id, at: base)
        XCTAssertNil(store.paneDoneDwellSince[id], "no watch while the app is away")

        store.isAppActive = true
        XCTAssertNotNil(store.paneDoneDwellSince[id], "the app-active edge starts the watch")
    }

    /// A closed pane's watch is pruned with every other per-pane mirror — a recycled id must never inherit
    /// a stale clock.
    func testWatchClockIsPrunedWithTheLeafSet() throws {
        let store = makeStore()
        let id = try firstPane(store)
        store.splitActivePane(axis: .horizontal, kind: .terminal)
        let second = try XCTUnwrap(store.tree.allPaneIDs().first { $0 != id })

        store.focusPaneTree(second)
        store.setAgentStatus(.done, for: second, at: base)
        store.refreshFocusedDoneSettle(at: base)
        XCTAssertNotNil(store.paneDoneDwellSince[second])

        store.closePaneTree(second)
        XCTAssertNil(store.paneDoneDwellSince[second], "a closed pane drops its watch clock")
    }
}
