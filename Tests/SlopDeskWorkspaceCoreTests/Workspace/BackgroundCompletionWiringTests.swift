import XCTest
@testable import SlopDeskClient
@testable import SlopDeskWorkspaceCore

/// B3 — the background-pane command-completion wiring in the store: a finished command (OSC 133;D, wire
/// type 23) badges an UNFOCUSED pane (✓/✗), fires the focus-gated long-command notification only when
/// backgrounded, and the badge clears the instant the pane gains focus / the app returns active. Entirely
/// headless (the `FakePaneSession` opens no socket; the notification sink is a spy closure — no
/// `UNUserNotificationCenter`).
@MainActor
final class BackgroundCompletionWiringTests: XCTestCase {
    private let longMS: UInt32 = CommandNotificationPolicy.longRunningThresholdMS // 10_000

    private func makeStore() -> WorkspaceStore {
        WorkspaceStore(liveModel: .tree, makeSession: { FakePaneSession($0) })
    }

    // MARK: - badge: only on an UNFOCUSED pane

    /// The default tree has ONE pane which is the active (focused) leaf. A completion on it sets NO badge
    /// (you're watching it) — the B3 focus gate, driven through the store handler.
    func testFocusedCompletionSetsNoBadge() throws {
        let store = makeStore()
        let paneID = try XCTUnwrap(store.tree.allPaneIDs().first)
        store.handleCommandCompleted(id: paneID, exitCode: 1, durationMS: longMS, paneTitle: "term")
        XCTAssertNil(store.pendingCompletion(for: paneID), "a focused pane never badges")
    }

    /// A completion on a NON-active leaf badges. Split to get a second pane (focus stays on the original
    /// active leaf), then complete on the unfocused second pane.
    func testUnfocusedFailureBadgesFailure() throws {
        let store = makeStore()
        let first = try XCTUnwrap(store.tree.allPaneIDs().first)
        store.splitActivePane(axis: .horizontal, kind: .terminal)
        let second = try XCTUnwrap(store.tree.allPaneIDs().first { $0 != first })
        // Make `first` the focused leaf so `second` is unfocused.
        store.focusPaneTree(first)
        store.handleCommandCompleted(id: second, exitCode: 2, durationMS: 500, paneTitle: "bg")
        XCTAssertEqual(store.pendingCompletion(for: second), .failure, "a quick background failure badges")
        XCTAssertNil(store.pendingCompletion(for: first), "the focused leaf is untouched")
    }

    /// A short background SUCCESS does NOT badge (no ls/cd noise); a long one does.
    func testUnfocusedShortSuccessNoBadgeLongSuccessBadges() throws {
        let store = makeStore()
        let first = try XCTUnwrap(store.tree.allPaneIDs().first)
        store.splitActivePane(axis: .horizontal, kind: .terminal)
        let second = try XCTUnwrap(store.tree.allPaneIDs().first { $0 != first })
        store.focusPaneTree(first)

        store.handleCommandCompleted(id: second, exitCode: 0, durationMS: 500, paneTitle: "bg")
        XCTAssertNil(store.pendingCompletion(for: second), "a short background success does not badge")

        store.handleCommandCompleted(id: second, exitCode: 0, durationMS: longMS, paneTitle: "bg")
        XCTAssertEqual(store.pendingCompletion(for: second), .success, "a long background success badges")
    }

    // MARK: - rollup: failure dominates success

    func testRollupFailureDominatesSuccess() throws {
        let store = makeStore()
        let sessionID = try XCTUnwrap(store.tree.sessions.first?.id)
        let first = try XCTUnwrap(store.tree.allPaneIDs().first)
        store.splitActivePane(axis: .horizontal, kind: .terminal)
        let second = try XCTUnwrap(store.tree.allPaneIDs().first { $0 != first })

        store.setCompletionBadge(.success, for: first)
        store.setCompletionBadge(.failure, for: second)
        XCTAssertEqual(
            store.rollupPendingCompletion(forSession: sessionID),
            .failure,
            "a failing pane outranks a succeeding one in the rollup",
        )
    }

    func testRollupNilWhenNoneAndSuccessWhenOnlySuccess() throws {
        let store = makeStore()
        let sessionID = try XCTUnwrap(store.tree.sessions.first?.id)
        let paneID = try XCTUnwrap(store.tree.allPaneIDs().first)
        XCTAssertNil(store.rollupPendingCompletion(forSession: sessionID), "no badges → nil")
        store.setCompletionBadge(.success, for: paneID)
        XCTAssertEqual(store.rollupPendingCompletion(forSession: sessionID), .success)
    }

    // MARK: - setter dedup (no re-mutation on identical)

    /// `setCompletionBadge` is idempotent: a stream with repeats mutates the observable dict exactly once
    /// per DISTINCT value (mirrors the agent-status dedup test — proves the guard, not a tautology).
    func testSetterDedupesIdenticalValues() throws {
        let store = makeStore()
        let paneID = try XCTUnwrap(store.tree.allPaneIDs().first)

        var observed: [PaneCompletionBadge?] = []
        func setAndRecord(_ b: PaneCompletionBadge?) {
            let before = store.pendingCompletion(for: paneID)
            store.setCompletionBadge(b, for: paneID)
            let after = store.pendingCompletion(for: paneID)
            if after != before { observed.append(after) }
        }
        setAndRecord(.success)
        setAndRecord(.success) // dup
        setAndRecord(.failure)
        setAndRecord(.failure) // dup
        setAndRecord(nil)
        setAndRecord(nil) // dup

        XCTAssertEqual(observed, [.success, .failure, nil], "one mutation per distinct value")
    }

    // MARK: - completion freshness (the checkmark→accent-dot decay clock)

    /// A `.success` badge stamps the ephemeral `completedAt`, so ``WorkspaceStore/completionFreshness``
    /// reports `.fresh` inside the flash window and `.settled` past it — the input that decays the resolver
    /// from `.completed` (checkmark) to `.finished` (accent dot). Dates are injected (no wall clock).
    func testSuccessBadgeFreshnessDecaysFromFreshToSettled() throws {
        let store = makeStore()
        let paneID = try XCTUnwrap(store.tree.allPaneIDs().first)
        let base = Date(timeIntervalSinceReferenceDate: 1000)
        store.setCompletionBadge(.success, for: paneID, at: base)

        let window = WorkspaceStore.completedFlashWindow
        XCTAssertEqual(store.completionFreshness(forPane: paneID, now: base), .fresh, "just-completed is fresh")
        XCTAssertEqual(
            store.completionFreshness(forPane: paneID, now: base.addingTimeInterval(window - 0.5)),
            .fresh, "still within the flash window",
        )
        XCTAssertEqual(
            store.completionFreshness(forPane: paneID, now: base.addingTimeInterval(window + 0.5)),
            .settled, "past the flash window it settles to the accent dot",
        )
    }

    /// An agent entering `.done` stamps the SAME freshness clock, so an idle-done agent flashes `.completed`
    /// then settles to the `.finished` dot (a dot when the agent goes idle).
    func testAgentDoneStampsFreshness() throws {
        let store = makeStore()
        let paneID = try XCTUnwrap(store.tree.allPaneIDs().first)
        let base = Date(timeIntervalSinceReferenceDate: 2000)
        store.setAgentStatus(.done, for: paneID, at: base)
        XCTAssertEqual(store.completionFreshness(forPane: paneID, now: base), .fresh)
        XCTAssertEqual(
            store.completionFreshness(
                forPane: paneID, now: base.addingTimeInterval(WorkspaceStore.completedFlashWindow + 1),
            ),
            .settled,
        )
    }

    /// No stamp ⇒ `.settled` (the persistent marker), never a perpetual checkmark — so an un-stamped row
    /// resolves to the accent dot, not a stuck `.completed`.
    func testFreshnessDefaultsSettledWithoutStamp() throws {
        let store = makeStore()
        let paneID = try XCTUnwrap(store.tree.allPaneIDs().first)
        XCTAssertEqual(store.completionFreshness(forPane: paneID), .settled)
    }

    // MARK: - FIX 1: the flash-window boundary re-render driver (scheduler + tick)

    /// Resolve the rail's fused badge for a `.success` completion on `pane` at instant `now`, the way the
    /// sidebar does — the only input that moves here is the store's freshness (the rest are at rest).
    private func successBadge(_ store: WorkspaceStore, for pane: PaneID, now: Date) -> TabBadgeKind? {
        TabBadgeResolver.badge(
            agent: .none, completion: store.pendingCompletion(for: pane), isBusy: false,
            foregroundProcess: nil, completionFreshness: store.completionFreshness(forPane: pane, now: now),
        )
    }

    /// FIX 1 (headline): stamping a clean completion ARMS a one-shot (``WorkspaceStore/flashDecayScheduler``)
    /// that, after ``WorkspaceStore/completedFlashWindow``, bumps ``WorkspaceStore/completionFlashTick`` — the
    /// SINGLE rail re-render that lets a quiet completed row decay from the brief `.completed` checkmark to
    /// the persistent `.finished` accent dot on its own. The rail reads the freshness clock only at BUILD
    /// time, so without this driver the tick never bumps and the checkmark would stick (the badge would be
    /// effectively unreachable). The scheduler is INJECTED (a capture-and-fire stub) so this is deterministic
    /// with no wall clock. Reverting the `armCompletionFlashDecay()` call makes this FAIL — no fire is
    /// captured (the `XCTUnwrap` throws) and the tick never bumps.
    func testSuccessCompletionArmsFlashDecayThatBumpsTheTickAtTheWindowBoundary() throws {
        let store = makeStore()
        let first = try XCTUnwrap(store.tree.allPaneIDs().first)
        store.splitActivePane(axis: .horizontal, kind: .terminal)
        let second = try XCTUnwrap(store.tree.allPaneIDs().first { $0 != first })
        store.focusPaneTree(first) // `second` is unfocused so a completion badges it

        // Capture the one-shot instead of running it on the real run loop (deterministic, no wall clock).
        var captured: (delay: TimeInterval, bump: @MainActor () -> Void)?
        store.flashDecayScheduler = { delay, bump in captured = (delay, bump) }

        let base = Date(timeIntervalSinceReferenceDate: 5000)
        let tickBefore = store.completionFlashTick
        store.setCompletionBadge(.success, for: second, at: base)

        // A decay one-shot was armed at the flash-window delay; the tick has NOT bumped (no premature
        // re-render — the brief checkmark flash is still on screen).
        let oneShot = try XCTUnwrap(captured, "a clean completion must arm the flash-decay one-shot (FIX 1)")
        XCTAssertEqual(oneShot.delay, WorkspaceStore.completedFlashWindow, "armed at the flash-window boundary")
        XCTAssertEqual(store.completionFlashTick, tickBefore, "stamping does not bump the tick (no premature decay)")
        XCTAssertEqual(successBadge(store, for: second, now: base), .completed, "still fresh → the checkmark flash")

        // Fire the one-shot (the boundary elapses): the tick bumps EXACTLY once → the rail re-renders, and
        // the freshness (now past the window) resolves the row to the persistent `.finished` accent dot.
        oneShot.bump()
        XCTAssertEqual(
            store.completionFlashTick, tickBefore &+ 1, "the boundary one-shot bumps the tick once (the re-render)",
        )
        let past = base.addingTimeInterval(WorkspaceStore.completedFlashWindow + 0.5)
        XCTAssertEqual(successBadge(store, for: second, now: past), .finished, "past the window it decays to the dot")
    }

    /// FIX 1: an agent entering `.done` arms the SAME decay one-shot (the agent-turn path), so an idle-done
    /// row settles to the `.finished` dot without a further store mutation. Fails on the un-fixed code (no
    /// arm call ⇒ nothing captured).
    func testAgentDoneArmsFlashDecayOneShot() throws {
        let store = makeStore()
        let paneID = try XCTUnwrap(store.tree.allPaneIDs().first)
        var captured: (delay: TimeInterval, bump: @MainActor () -> Void)?
        store.flashDecayScheduler = { delay, bump in captured = (delay, bump) }

        store.setAgentStatus(.done, for: paneID, at: Date(timeIntervalSinceReferenceDate: 6000))
        let oneShot = try XCTUnwrap(captured, "agent .done must arm the flash-decay one-shot (FIX 1)")
        XCTAssertEqual(oneShot.delay, WorkspaceStore.completedFlashWindow)

        let before = store.completionFlashTick
        oneShot.bump()
        XCTAssertEqual(store.completionFlashTick, before &+ 1, "firing the one-shot bumps the re-render tick")
    }

    // MARK: - clear on focus / app-active

    /// A badge on a pane CLEARS the instant that pane gains focus (`focusPaneTree` routes through the
    /// reconcile that clears the active leaf's badge).
    func testBadgeClearsWhenPaneGainsFocus() throws {
        let store = makeStore()
        let first = try XCTUnwrap(store.tree.allPaneIDs().first)
        store.splitActivePane(axis: .horizontal, kind: .terminal)
        let second = try XCTUnwrap(store.tree.allPaneIDs().first { $0 != first })
        store.focusPaneTree(first)

        store.handleCommandCompleted(id: second, exitCode: 1, durationMS: 500, paneTitle: "bg")
        XCTAssertEqual(store.pendingCompletion(for: second), .failure)

        store.focusPaneTree(second) // now watching it
        XCTAssertNil(store.pendingCompletion(for: second), "focusing the pane clears its badge")
    }

    /// When the app returns to `.active`, the CURRENT active leaf's badge clears (a badge that landed while
    /// the app was backgrounded — its leaf happened to be the active one — is dismissed on return).
    func testBadgeClearsWhenAppBecomesActive() throws {
        let store = makeStore()
        let paneID = try XCTUnwrap(store.tree.allPaneIDs().first)
        // App backgrounded → the active leaf is NOT focused, so a completion on it badges.
        store.isAppActive = false
        store.handleCommandCompleted(id: paneID, exitCode: 1, durationMS: 500, paneTitle: "term")
        XCTAssertEqual(store.pendingCompletion(for: paneID), .failure, "backgrounded ⇒ even the active leaf badges")

        store.isAppActive = true // user returns
        XCTAssertNil(store.pendingCompletion(for: paneID), "returning active clears the focused leaf's badge")
    }

    // MARK: - the long-command notification sink (the B3 focus gate end-to-end)

    /// The `onLongCommandNotify` sink fires EXACTLY ONCE for a backgrounded LONG command and NEVER for a
    /// focused one (the focus gate, spied through the closure). No double-notify.
    func testNotifySinkFiresOnceForBackgroundLongAndNeverForFocused() throws {
        SettingsKey.store.set(true, forKey: SettingsKey.longCommandNotifications) // deterministic enabled
        defer { SettingsKey.store.removeObject(forKey: SettingsKey.longCommandNotifications) }
        let store = makeStore()
        var calls: [(key: String, title: String, exit: Int32?, dur: UInt32)] = []
        store.onLongCommandNotify = { key, title, exit, dur in
            calls.append((key, title, exit, dur))
        }
        let first = try XCTUnwrap(store.tree.allPaneIDs().first)
        store.splitActivePane(axis: .horizontal, kind: .terminal)
        let second = try XCTUnwrap(store.tree.allPaneIDs().first { $0 != first })
        store.focusPaneTree(first) // `second` is unfocused, `first` is focused

        // Focused long command → NO notify.
        store.handleCommandCompleted(id: first, exitCode: 0, durationMS: longMS, paneTitle: "fg")
        XCTAssertTrue(calls.isEmpty, "a foreground long command does not notify")

        // Backgrounded long command → exactly one notify carrying the pane id string.
        store.handleCommandCompleted(id: second, exitCode: 0, durationMS: longMS, paneTitle: "bg")
        XCTAssertEqual(calls.count, 1, "a backgrounded long command notifies exactly once")
        XCTAssertEqual(calls[0].key, second.raw.uuidString, "the notify carries the pane id (click reveals)")
        XCTAssertEqual(calls[0].title, "bg")
        XCTAssertEqual(calls[0].dur, longMS)
    }

    /// A backgrounded SHORT command never notifies (only LONG ones alert) — even though a short background
    /// FAILURE still badges.
    func testNotifySinkDoesNotFireForBackgroundShort() throws {
        let store = makeStore()
        var fired = false
        store.onLongCommandNotify = { _, _, _, _ in fired = true }
        let first = try XCTUnwrap(store.tree.allPaneIDs().first)
        store.splitActivePane(axis: .horizontal, kind: .terminal)
        let second = try XCTUnwrap(store.tree.allPaneIDs().first { $0 != first })
        store.focusPaneTree(first)

        store.handleCommandCompleted(id: second, exitCode: 1, durationMS: 500, paneTitle: "bg")
        XCTAssertFalse(fired, "a short command never notifies")
        XCTAssertEqual(store.pendingCompletion(for: second), .failure, "but the short background failure still badges")
    }

    // MARK: - M1: per-command finish/error gate (NotificationPolicy as the PRIMARY authority)

    /// M1: a SHORT failing command must notify PER-COMMAND through the pure ``NotificationPolicy`` (Notify on
    /// Error, default ON) — DECOUPLED from both the ~10s long-running floor AND slopdesk's own "Long-Command
    /// Completion" master. The app is backgrounded so the Notify-While-Foreground gate is a pass-through; the
    /// master is forced OFF to prove the per-event toggle has INDEPENDENT authority. Revert-to-confirm-fail:
    /// the un-fixed store gates ONLY on `BackgroundCompletionPolicy.shouldNotify` (long + enabled), so a 500ms
    /// command with the master OFF never fires the sink — this asserts it now does.
    func testShortBackgroundedFailureNotifiesPerCommandEvenWithLongMasterOff() throws {
        SettingsKey.store.set(false, forKey: SettingsKey.longCommandNotifications) // master OFF
        defer { SettingsKey.store.removeObject(forKey: SettingsKey.longCommandNotifications) }
        let store = makeStore()
        var calls: [(key: String, exit: Int32?, dur: UInt32)] = []
        store.onLongCommandNotify = { key, _, exit, dur in calls.append((key, exit, dur)) }
        let paneID = try XCTUnwrap(store.tree.allPaneIDs().first)
        store.isAppActive = false // backgrounded → the foreground gate passes

        store.handleCommandCompleted(id: paneID, exitCode: 1, durationMS: 500, paneTitle: "make")
        XCTAssertEqual(
            calls.count,
            1,
            "a short backgrounded failure notifies per-command (Notify on Error) with the master OFF",
        )
        XCTAssertEqual(calls[0].key, paneID.raw.uuidString)
        XCTAssertEqual(calls[0].exit, 1)
        XCTAssertEqual(calls[0].dur, 500)
    }

    /// M1: a SHORT clean exit does NOT notify — "Notify on Finish" is default OFF, so the per-command gate
    /// stays silent for a quick `ls`. Pins that the new per-command authority is the toggle, not "fire on every
    /// completion" (guards against over-firing; not tautological — it exercises the notifyOnFinish branch).
    func testShortBackgroundedCleanExitDoesNotNotifyWhenNotifyOnFinishOff() throws {
        SettingsKey.store.set(false, forKey: SettingsKey.longCommandNotifications)
        defer { SettingsKey.store.removeObject(forKey: SettingsKey.longCommandNotifications) }
        let store = makeStore()
        var fired = false
        store.onLongCommandNotify = { _, _, _, _ in fired = true }
        let paneID = try XCTUnwrap(store.tree.allPaneIDs().first)
        store.isAppActive = false

        store.handleCommandCompleted(id: paneID, exitCode: 0, durationMS: 500, paneTitle: "ls")
        XCTAssertFalse(fired, "a clean short command stays silent (Notify on Finish default OFF)")
    }

    /// M1: when BOTH authorities would fire (a backgrounded LONG failing command — per-command Notify-on-Error
    /// AND the Long-Command Completion master), the sink fires EXACTLY ONCE (no double-banner).
    func testLongBackgroundedFailureFiresExactlyOnceWhenBothAuthoritiesAgree() throws {
        SettingsKey.store.set(true, forKey: SettingsKey.longCommandNotifications) // master ON
        defer { SettingsKey.store.removeObject(forKey: SettingsKey.longCommandNotifications) }
        let store = makeStore()
        var count = 0
        store.onLongCommandNotify = { _, _, _, _ in count += 1 }
        let paneID = try XCTUnwrap(store.tree.allPaneIDs().first)
        store.isAppActive = false

        store.handleCommandCompleted(id: paneID, exitCode: 2, durationMS: longMS, paneTitle: "build")
        XCTAssertEqual(count, 1, "both authorities agreeing still deliver ONE notification (no double-banner)")
    }
}
