import Foundation
import XCTest
@testable import SlopDeskWorkspaceCore

/// The busy-dot REVEAL THRESHOLD: the plain ``TabBadgeKind/commandBusy`` dot shows only
/// once a foreground command has been running at least `SettingsKey.tabBadgeBusyDelaySecondsValue`
/// (default 3 s, user-configurable, 0 = immediate) — a fast `ls`/`cd` must never flash the rail.
///
/// ``WorkspaceStore/paneShowsBusyDot(_:now:)`` is the ONE thresholded `isBusy` input every badge
/// resolution site feeds to `TabBadgeGating.resolve` (the rail's `chrome(...)`,
/// `unseenAttentionPanes`, the control backend's `tab list`) — the resolver itself stays pure and
/// clock-free. The reveal repaint rides a one-shot: ``WorkspaceStore/handleCommandStarted(id:at:)``
/// arms `flashDecayScheduler(delay)` → `completionFlashTick` bump, the same idiom as the
/// completion-flash decay.
///
/// Built on the spec-only `FakePaneSession` seam (`liveModel: .tree`) — no SwiftUI, no client/host
/// (the hang-safety rule). Settings overrides go through `SettingsKey.store` (the per-process test
/// suite), never `UserDefaults.standard`.
@MainActor
final class BusyDotThresholdTests: XCTestCase {
    private func makeTreeStore() -> WorkspaceStore {
        WorkspaceStore(
            restoringTree: .defaultWorkspace(),
            liveModel: .tree,
            makeSession: { FakePaneSession($0) },
            liveVideoCap: 5,
        )
    }

    private func activePane(_ store: WorkspaceStore) throws -> PaneID {
        try XCTUnwrap(store.tree.activeSession?.activeTab?.activePane)
    }

    private func fake(_ store: WorkspaceStore, _ id: PaneID) throws -> FakePaneSession {
        try XCTUnwrap(store.handle(for: id) as? FakePaneSession)
    }

    // MARK: - threshold gating (the default 3 s)

    /// A busy shell whose command just started must NOT show the dot; once the command outlives the
    /// default 3 s delay it must. This is the user-visible contract: fast commands never flash.
    func testBusyDotHiddenUntilDefaultThresholdElapses() throws {
        let store = makeTreeStore()
        let pane = try activePane(store)
        try fake(store, pane).isShellBusy = true

        let start = Date(timeIntervalSinceReferenceDate: 1000)
        store.handleCommandStarted(id: pane, at: start)

        XCTAssertFalse(
            store.paneShowsBusyDot(pane, now: start.addingTimeInterval(0.4)),
            "a just-started command must not flash the busy dot",
        )
        XCTAssertFalse(
            store.paneShowsBusyDot(pane, now: start.addingTimeInterval(2.9)),
            "still inside the default 3 s reveal delay",
        )
        XCTAssertTrue(
            store.paneShowsBusyDot(pane, now: start.addingTimeInterval(3.0)),
            "at the boundary the dot reveals (>= threshold, the completedFlashWindow compare idiom)",
        )
        XCTAssertTrue(store.paneShowsBusyDot(pane, now: start.addingTimeInterval(30)))
    }

    /// A shell that is not busy shows no dot regardless of any stale start stamp.
    func testNotBusyNeverShowsDot() throws {
        let store = makeTreeStore()
        let pane = try activePane(store)
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        store.handleCommandStarted(id: pane, at: start)
        XCTAssertFalse(
            store.paneShowsBusyDot(pane, now: start.addingTimeInterval(60)),
            "no busy bit ⇒ no dot, stamp or not",
        )
    }

    /// FAIL-VISIBLE: a busy shell with NO start stamp shows the dot immediately. The stamp and the
    /// busy bit ride the same OSC-133 `.running` edge, so this is a defensive default — but if the
    /// two ever diverge the long-running command must stay visible, not silently hidden.
    func testBusyWithoutStampShowsImmediately() throws {
        let store = makeTreeStore()
        let pane = try activePane(store)
        try fake(store, pane).isShellBusy = true
        XCTAssertTrue(store.paneShowsBusyDot(pane), "no stamp ⇒ fail-visible, never fail-hidden")
    }

    /// Completion retires the stamp: the NEXT command's reveal clock starts from its own edge, not
    /// the previous command's.
    func testCompletionClearsStartStampSoNextCommandRearms() throws {
        let store = makeTreeStore()
        let pane = try activePane(store)
        try fake(store, pane).isShellBusy = true

        let start = Date(timeIntervalSinceReferenceDate: 1000)
        store.handleCommandStarted(id: pane, at: start)
        store.handleCommandCompleted(id: pane, exitCode: 0, durationMS: 100, paneTitle: "t")
        XCTAssertNil(store.paneCommandStartedAt[pane], "completion retires the reveal clock")

        // The next command re-stamps from its own start.
        let secondStart = start.addingTimeInterval(10)
        store.handleCommandStarted(id: pane, at: secondStart)
        XCTAssertFalse(
            store.paneShowsBusyDot(pane, now: secondStart.addingTimeInterval(1)),
            "the second command's reveal delay counts from ITS start edge",
        )
    }

    // MARK: - configurability (SettingsKey.tabBadgeBusyDelaySeconds)

    /// The delay is user-configurable; 0 reveals immediately (the pre-threshold behaviour).
    func testConfiguredZeroDelayRevealsImmediately() throws {
        SettingsKey.store.set(0.0, forKey: SettingsKey.tabBadgeBusyDelaySeconds)
        defer { SettingsKey.store.removeObject(forKey: SettingsKey.tabBadgeBusyDelaySeconds) }

        let store = makeTreeStore()
        let pane = try activePane(store)
        try fake(store, pane).isShellBusy = true
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        store.handleCommandStarted(id: pane, at: start)
        XCTAssertTrue(store.paneShowsBusyDot(pane, now: start), "delay 0 ⇒ immediate reveal")
    }

    /// A hostile/corrupt negative persisted value clamps to 0 (validate-then-default), never a
    /// dot that can't reveal.
    func testNegativePersistedDelayClampsToZero() {
        SettingsKey.store.set(-5.0, forKey: SettingsKey.tabBadgeBusyDelaySeconds)
        defer { SettingsKey.store.removeObject(forKey: SettingsKey.tabBadgeBusyDelaySeconds) }
        XCTAssertEqual(SettingsKey.tabBadgeBusyDelaySecondsValue, 0)
    }

    // MARK: - the reveal repaint (one-shot)

    /// `handleCommandStarted` arms the one-shot at the CONFIGURED delay, and firing it bumps
    /// `completionFlashTick` — `paneShowsBusyDot` reads the wall clock, not an `@Observable`
    /// dependency, so without this tick nothing would repaint the row when the delay elapses.
    func testCommandStartArmsRevealTickAtConfiguredDelay() throws {
        SettingsKey.store.set(1.5, forKey: SettingsKey.tabBadgeBusyDelaySeconds)
        defer { SettingsKey.store.removeObject(forKey: SettingsKey.tabBadgeBusyDelaySeconds) }

        let store = makeTreeStore()
        let pane = try activePane(store)
        var captured: (delay: TimeInterval, bump: @MainActor () -> Void)?
        store.flashDecayScheduler = { delay, bump in captured = (delay, bump) }

        store.handleCommandStarted(id: pane, at: Date(timeIntervalSinceReferenceDate: 1000))
        let armed = try XCTUnwrap(captured, "the start edge must arm the reveal one-shot")
        XCTAssertEqual(armed.delay, 1.5, "armed at the configured delay, not a hard-coded 3")

        let tickBefore = store.completionFlashTick
        armed.bump()
        XCTAssertEqual(store.completionFlashTick, tickBefore &+ 1, "firing bumps the rail-repaint tick")
    }
}
