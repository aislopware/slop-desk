import XCTest
@testable import AislopdeskClient
@testable import AislopdeskClientUI

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
        UserDefaults.standard.set(true, forKey: SettingsKey.longCommandNotifications) // deterministic enabled
        defer { UserDefaults.standard.removeObject(forKey: SettingsKey.longCommandNotifications) }
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
}
