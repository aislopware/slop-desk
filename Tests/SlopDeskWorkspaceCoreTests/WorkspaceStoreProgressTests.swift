import SlopDeskProtocol
import XCTest
@testable import SlopDeskClient
@testable import SlopDeskWorkspaceCore

/// The per-pane OSC 9;4 PROGRESS wiring: the client validates the state at its boundary, the
/// ``TerminalViewModel`` mirrors it (`progress`), and the store holds the per-pane `paneProgress` (→ the
/// sidebar badge + the macOS Dock aggregate) bumping `completionFlashTick` on each edge. Entirely headless
/// (`FakePaneSession` opens no socket; the ConnectionViewModel path drives `foldEventForTesting`, no network).
@MainActor
final class WorkspaceStoreProgressTests: XCTestCase {
    private func makeStore() -> WorkspaceStore {
        WorkspaceStore(liveModel: .tree, makeSession: { FakePaneSession($0) })
    }

    // MARK: - store mirror: set / clear

    func testHandleProgressSetsAndClears() throws {
        let store = makeStore()
        let id = try XCTUnwrap(store.tree.allPaneIDs().first)
        XCTAssertNil(store.progress(for: id), "no progress reported yet")

        store.handleProgress(.indeterminate, for: id)
        XCTAssertEqual(store.progress(for: id), .indeterminate)

        store.handleProgress(.determinate(percent: 40), for: id)
        XCTAssertEqual(store.progress(for: id), .determinate(percent: 40))

        store.handleProgress(nil, for: id) // a 9;4;0 clear
        XCTAssertNil(store.progress(for: id), "a clear removes the indicator")
    }

    /// A finished command (OSC 133;D) clears the store's per-pane progress mirror too, so the sidebar rail
    /// doesn't rank the running tier over the just-completed ✓/✗ badge (the `9;4;5`-equivalent on the store
    /// side). Revert-to-confirm-fail: the un-fixed `handleCommandCompleted` never touched `paneProgress`, so a
    /// program that finished without an explicit `9;4;0` left a stuck spinner over the completion badge.
    func testHandleCommandCompletedClearsStoreProgress() throws {
        let store = makeStore()
        let id = try XCTUnwrap(store.tree.allPaneIDs().first)
        store.handleProgress(.determinate(percent: 50), for: id)
        XCTAssertEqual(store.progress(for: id), .determinate(percent: 50), "precondition: progress is showing")

        store.handleCommandCompleted(id: id, exitCode: 0, durationMS: 1200, paneTitle: "term")
        XCTAssertNil(store.progress(for: id), "a finished command clears the store's per-pane progress mirror")
    }

    // MARK: - completionFlashTick bumps on an edge (the rail re-render seam), not on a dup

    /// A genuine progress edge bumps ``WorkspaceStore/completionFlashTick`` (the seam the sidebar rail
    /// observes) so the row recomputes its fused badge; an IDENTICAL update is idempotent (no churn). Reverting
    /// the `completionFlashTick &+= 1` in `handleProgress` makes this FAIL — the tick never moves.
    func testProgressEdgeBumpsFlashTickButDupDoesNot() throws {
        let store = makeStore()
        let id = try XCTUnwrap(store.tree.allPaneIDs().first)
        let t0 = store.completionFlashTick

        store.handleProgress(.indeterminate, for: id)
        let t1 = store.completionFlashTick
        XCTAssertEqual(t1, t0 &+ 1, "a progress edge bumps the rail re-render tick")

        store.handleProgress(.indeterminate, for: id) // identical → no edge
        XCTAssertEqual(store.completionFlashTick, t1, "an identical progress does not churn the rail")

        store.handleProgress(nil, for: id) // clear → an edge
        XCTAssertEqual(store.completionFlashTick, t1 &+ 1, "clearing is an edge too")
    }

    // MARK: - rollup: error-dominant across leaves

    /// The session rollup (the Dock aggregate source) is ERROR-dominant: an erroring leaf makes the whole
    /// session read error even when a sibling is mid-progress.
    func testRollupIsErrorDominant() throws {
        let store = makeStore()
        let sessionID = try XCTUnwrap(store.tree.sessions.first?.id)
        let first = try XCTUnwrap(store.tree.allPaneIDs().first)
        store.splitActivePane(axis: .horizontal, kind: .terminal)
        let second = try XCTUnwrap(store.tree.allPaneIDs().first { $0 != first })

        store.handleProgress(.determinate(percent: 50), for: first)
        store.handleProgress(.error(percent: 80), for: second)
        XCTAssertEqual(
            store.rollupProgress(forSession: sessionID), .error(percent: 80),
            "an erroring leaf dominates a determinate one in the rollup",
        )
    }

    /// With no error: a determinate value outranks a bare spinner (the bar fills toward done); with nothing
    /// reported the rollup is `nil`.
    func testRollupDeterminateOverSpinnerElseNil() throws {
        let store = makeStore()
        let sessionID = try XCTUnwrap(store.tree.sessions.first?.id)
        let first = try XCTUnwrap(store.tree.allPaneIDs().first)
        store.splitActivePane(axis: .horizontal, kind: .terminal)
        let second = try XCTUnwrap(store.tree.allPaneIDs().first { $0 != first })

        XCTAssertNil(store.rollupProgress(forSession: sessionID), "no progress on any leaf → nil")

        store.handleProgress(.indeterminate, for: first)
        XCTAssertEqual(store.rollupProgress(forSession: sessionID), .indeterminate, "only a spinner → indeterminate")

        store.handleProgress(.determinate(percent: 30), for: second)
        XCTAssertEqual(
            store.rollupProgress(forSession: sessionID), .determinate(percent: 30),
            "a determinate value outranks a bare spinner",
        )
    }

    // MARK: - VM mirror: feeding a .progress event through the terminal model

    /// A `.progress` event folded through the ``TerminalViewModel`` sets its observable `progress` mirror (the
    /// pane status strip + Dock read it); a `.clear` resets it; the state is mapped from the validated
    /// ``ProgressState``. Revert-to-confirm-fail: a model without a `progress` property — this would
    /// not compile.
    func testTerminalModelMirrorsProgress() {
        let vm = TerminalViewModel()
        XCTAssertNil(vm.progress)

        vm.handle(.progress(state: .indeterminate, percent: 0))
        XCTAssertEqual(vm.progress, .indeterminate)

        vm.handle(.progress(state: .inProgress, percent: 40))
        XCTAssertEqual(vm.progress, .determinate(percent: 40))

        vm.handle(.progress(state: .error, percent: 80))
        XCTAssertEqual(vm.progress, .error(percent: 80))

        vm.handle(.progress(state: .clear, percent: 0))
        XCTAssertNil(vm.progress, "a 9;4;0 clear removes the indicator")
    }

    /// A dead shell must not leave a stuck spinner: an `.exit` clears the model's progress mirror.
    func testExitClearsTerminalModelProgress() {
        let vm = TerminalViewModel()
        vm.handle(.progress(state: .indeterminate, percent: 0))
        XCTAssertEqual(vm.progress, .indeterminate)
        vm.handle(.exit(code: 0))
        XCTAssertNil(vm.progress, "a terminated shell reports no progress")
    }

    /// OSC 133;D (a command finished) clears a stuck OSC 9;4 badge — the `9;4;5`-equivalent. A program that
    /// drove a determinate bar and finished WITHOUT an explicit `9;4;0` (or was killed mid-progress) must not
    /// leave the indicator showing. `ProgressOSCParser` DROPS state 5, so the completion edge is what clears it.
    /// Revert-to-confirm-fail: the un-fixed `.commandStatus(.idle)` arm sets `shellActivity`/`lastCommand`/beep
    /// but NEVER `progress = nil`, so the determinate badge sticks — this asserts it now clears.
    func testCommandIdleClearsTerminalModelProgress() {
        let vm = TerminalViewModel()
        vm.handle(.progress(state: .inProgress, percent: 50))
        XCTAssertEqual(vm.progress, .determinate(percent: 50), "precondition: a determinate badge is showing")
        vm.handle(.commandStatus(.idle(exitCode: 0, durationMS: 1200)))
        XCTAssertNil(vm.progress, "a finished command (OSC 133;D) clears the stuck 9;4 badge")
    }

    // MARK: - connection → store push (the production path, end to end)

    /// The ``ConnectionViewModel`` routes a validated `.progress` event to its `onProgressUpdate` sink (which
    /// the store wires to `handleProgress` in `wireMaterializedLeaf`) AND folds the terminal model's mirror —
    /// the production path. A `.clear` arrives as `nil` (remove the indicator).
    func testConnectionRoutesProgressToSinkAndMirror() {
        let terminal = TerminalViewModel()
        let vm = ConnectionViewModel(
            terminal: terminal,
            target: { .default },
            makeClient: { SlopDeskClient(makeTransport: { fatalError("not used in progress tests") }) },
        )
        var pushed: [PaneProgress?] = []
        vm.onProgressUpdate = { pushed.append($0) }

        vm.foldEventForTesting(.progress(state: .indeterminate, percent: 0))
        vm.foldEventForTesting(.progress(state: .clear, percent: 0))

        XCTAssertEqual(pushed, [.indeterminate, nil], "each progress event routes to the store sink (clear → nil)")
        XCTAssertNil(terminal.progress, "the terminal mirror also folded the clear")
    }

    func testConnectionRoutesCwdToSink() {
        let terminal = TerminalViewModel()
        let vm = ConnectionViewModel(
            terminal: terminal,
            target: { .default },
            makeClient: { SlopDeskClient(makeTransport: { fatalError("not used in cwd tests") }) },
        )
        var pushed: [String] = []
        vm.onWorkingDirectoryChanged = { pushed.append($0) }

        // Type-33 is host-gated single-source (MuxChannelSession.deriveProjectKey: warm-up gate +
        // probe-at-edge — the plugin startup-noise filtering lives THERE, pinned in
        // MuxChannelSessionProjectKeyTests), so the VM routes every non-empty edge straight to the
        // store sink — including the host's reattach re-assert, which arrives before any command.
        vm.foldEventForTesting(.cwd("/Users/me/next"))

        XCTAssertEqual(pushed, ["/Users/me/next"], "a host-pushed cwd edge routes to the store sink")
    }

    /// A lifecycle drop / exit clears the store's per-pane progress (the badge source) so it agrees with the
    /// terminal model — no stuck spinner on a dead/dropped pane. Both `.exit` and `.disconnected` push a `nil`.
    func testExitAndDisconnectClearStoreProgress() {
        let terminal = TerminalViewModel()
        let vm = ConnectionViewModel(
            terminal: terminal,
            target: { .default },
            makeClient: { SlopDeskClient(makeTransport: { fatalError("not used in progress tests") }) },
        )
        var pushed: [PaneProgress?] = []
        vm.onProgressUpdate = { pushed.append($0) }

        vm.foldEventForTesting(.progress(state: .indeterminate, percent: 0))
        vm.foldEventForTesting(.exit(code: 0))
        XCTAssertEqual(pushed, [.indeterminate, nil], "an exit clears the store progress mirror")
        XCTAssertNil(terminal.progress, "and the terminal mirror")

        pushed.removeAll()
        vm.foldEventForTesting(.progress(state: .inProgress, percent: 30))
        vm.foldEventForTesting(.disconnected(reason: "drop"))
        XCTAssertEqual(pushed, [.determinate(percent: 30), nil], "a drop clears the store progress mirror")
    }
}
