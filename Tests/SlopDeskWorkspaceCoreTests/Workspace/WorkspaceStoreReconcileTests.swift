import SlopDeskWorkspaceModel
import XCTest
@testable import SlopDeskWorkspaceCore

/// Pins the load-bearing **reconcile** contract of ``WorkspaceStore`` (docs/22 §2.3, §8): the diff that
/// keeps the `[PaneID: any PaneSessionHandle]` table of liveness 1:1 with the leaves of the pure
/// ``TreeWorkspace`` of intent after **every** mutation. This is what guarantees there is exactly one
/// ``LivePaneSession`` (hence one ordered-OUT stream, one events consumer, one `ReconnectManager`) per
/// pane — the four byte-pipeline invariants by construction.
///
/// The whole suite injects the spec-only `makeSession` seam with a ``FakePaneSession`` so it exercises
/// the store's materialize / teardown / id-adoption logic **without ever building a `SlopDeskClient` or a
/// `HostServer`** (forbidden — the latter deadlocks the pool). The assertions are deterministic: they
/// read the fake's RECORDED lifecycle calls, never the reconcile's own recomputed output.
///
/// The bulk of the per-op coverage lives in the ``WorkspaceStoreTreeReconcileTests`` extension of this
/// same class; what stays HERE is the accounting that has to hold while a teardown is still IN FLIGHT.
@MainActor
final class WorkspaceStoreReconcileTests: XCTestCase {
    // MARK: - Fixtures

    /// Builds a store with the ``FakePaneSession`` seam (NEVER a real client/host), restored from
    /// `restoringTree` — default: the one-terminal-leaf default workspace.
    private func makeStore(restoringTree: TreeWorkspace = .defaultWorkspace(), liveVideoCap: Int = 2)
        -> WorkspaceStore
    {
        let store = WorkspaceStore(
            restoringTree: restoringTree,
            makeSession: { seed in FakePaneSession(seed.spec) },
            liveVideoCap: liveVideoCap,
        )
        store.attachLoopbackWorkspaceDocument()
        return store
    }

    /// The reconcile diff domain — the source of truth the registry is asserted against: every tab leaf
    /// PLUS every detached pane. Detached panes are excluded from ``TreeWorkspace/allPaneIDs()`` on
    /// purpose (tree membership is what drives focus/zoom/tab semantics) but their sessions stay live,
    /// so the registry holds them and the invariant is over the union.
    private func paneIDs(_ store: WorkspaceStore) -> [PaneID] {
        store.tree.allPaneIDs() + store.tree.detachedPaneIDs()
    }

    /// The set of ids the registry currently holds, surfaced via the only public registry window
    /// (`allSessions` — order unspecified, hence a Set).
    private func registryIDs(_ store: WorkspaceStore) -> Set<PaneID> {
        Set(store.allSessions.map(\.id))
    }

    /// The fake handle for `id` (downcast for the recorded-lifecycle accessors), or `nil`.
    private func fake(_ store: WorkspaceStore, _ id: PaneID) -> FakePaneSession? {
        store.handle(for: id) as? FakePaneSession
    }

    /// THE invariant, asserted after every op: the registry keys are exactly the tree's leaf ids, AND
    /// every materialized handle has adopted its pane id (so `handle(for:)` round-trips by identity).
    private func assertInvariant(
        _ store: WorkspaceStore,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line,
    ) {
        let panes = Set(paneIDs(store))
        XCTAssertEqual(
            registryIDs(store), panes,
            "registry.keys != the tree's leaves + detached panes \(message)", file: file, line: line,
        )
        XCTAssertEqual(
            store.allSessions.count,
            panes.count,
            "registry has duplicate/extra handles \(message)",
            file: file,
            line: line,
        )
        for id in panes {
            let handle = store.handle(for: id)
            XCTAssertNotNil(handle, "no handle for pane \(id) \(message)", file: file, line: line)
            XCTAssertEqual(handle?.id, id, "handle.id != its pane id (adopt failed) \(message)", file: file, line: line)
        }
    }

    // MARK: - in-flight video-cap accounting does not perturb the registry invariant (ITEM #3)

    /// The ITEM #3 in-flight-teardown video accounting (`tearingDownVideo`) is a SEPARATE bookkeeping
    /// set from the registry: closing a live `.desktop` pane removes its key from the registry
    /// SYNCHRONOUSLY (the invariant `registry.keys == tree.allPaneIDs()` holds the instant the close
    /// returns) even while its teardown — and hence its in-flight cap slot — is still parked. The cap
    /// accounting must never leak into or perturb the registry/pane-set invariant.
    func testInFlightVideoAccountingDoesNotPerturbRegistryInvariant() async throws {
        // Two desktop panes, each in its own window — the only shape a `.desktop` pane has.
        let store = makeStore()
        let ids = (0..<2).map { store.openDesktopWindow(displayID: UInt32($0)) }
        XCTAssertEqual(Set(ids).count, 2)
        assertInvariant(store, "two desktop panes beside the default terminal leaf")

        // Park the close-victim's teardown so its in-flight cap slot is held across the assertions.
        let gate = FakeTeardownGate()
        fake(store, ids[0])?.teardownGate = gate
        XCTAssertTrue(store.activateVideo(ids[0]), "ids[0] holds a live video stack")

        store.closePaneTree(ids[0])

        // The registry invariant holds SYNCHRONOUSLY even though ids[0]'s teardown (and its in-flight
        // cap slot) is still parked: the registry excludes the orphan the instant the close returns.
        XCTAssertNil(store.handle(for: ids[0]), "orphan removed from the registry synchronously")
        assertInvariant(store, "registry invariant holds while teardown (and its cap slot) is in flight")

        // Release + drain: the invariant still holds, and now no teardown / in-flight slot is pending.
        gate.release()
        await store.quiesce()
        assertInvariant(store, "registry invariant holds after the in-flight teardown completes")
        XCTAssertEqual(try XCTUnwrap(fake(store, ids[1])?.teardownCount), 0, "the survivor was never torn down")
    }

    // MARK: - quiesce awaits a teardown task spawned DURING its own drain (BUG-J)

    /// BUG-J: a teardown task spawned by a `reconcile()` that runs WHILE `quiesce()` is awaiting an
    /// earlier teardown must still be awaited — `quiesce()` loops to a fixpoint rather than snapshotting
    /// once. We park the first close's teardown on a gate, start `quiesce()` (it suspends awaiting that
    /// task), then — while it is suspended — close a SECOND pane (spawning a new teardown task), release
    /// the gate, and confirm BOTH teardowns completed once `quiesce()` returns. A single-snapshot drain
    /// would have dropped the second task.
    func testQuiesceAwaitsTeardownSpawnedDuringDrain() async throws {
        // Three terminal leaves in one tab so we can close two of them independently and keep a survivor.
        let store = makeStore()
        store.splitActivePane(axis: .horizontal, kind: .terminal)
        store.splitActivePane(axis: .vertical, kind: .terminal)
        let leaves = paneIDs(store)
        XCTAssertEqual(leaves.count, 3, "three leaves to close two of")
        let a0 = leaves[0], a1 = leaves[1], a2 = leaves[2]
        let gate0 = FakeTeardownGate()
        let h0 = try XCTUnwrap(fake(store, a0))
        let h1 = try XCTUnwrap(fake(store, a1))
        h0.teardownGate = gate0 // the first close's teardown will park here

        // First close → spawns teardown task #1, which parks on gate0.
        store.closePaneTree(a0)
        XCTAssertNil(store.handle(for: a0))

        // Start quiesce; it will suspend awaiting task #1 (parked on gate0). Run it as a child task so
        // the test body can interleave a second close while quiesce is mid-drain.
        let quiesced = Task { @MainActor in await store.quiesce() }

        // Wait until task #1's teardown body has actually entered (and parked on) the gate, so quiesce is
        // genuinely suspended mid-drain before we spawn the second teardown (no fixed-sleep race).
        let entered = await waitUntil { gate0.waiterCount == 1 }
        XCTAssertTrue(entered, "the first teardown parked on the gate — quiesce is suspended mid-drain")

        // While quiesce is suspended, close a SECOND pane → spawns teardown task #2 (no gate → it will
        // complete immediately once it runs). With a single-snapshot drain this task would be dropped.
        store.closePaneTree(a1)
        XCTAssertNil(store.handle(for: a1))

        // Release the first teardown; quiesce's loop must now re-check teardownTasks, find task #2, and
        // await it too before returning.
        gate0.release()
        await quiesced.value

        XCTAssertEqual(h0.teardownCount, 1, "the gated first teardown ran exactly once")
        XCTAssertEqual(
            h1.teardownCount,
            1,
            "the teardown spawned DURING quiesce's drain was still awaited (BUG-J fixpoint loop)",
        )
        // After the fixpoint loop, nothing is pending: a second quiesce is a no-op.
        await store.quiesce()
        XCTAssertEqual(h0.teardownCount, 1)
        XCTAssertEqual(h1.teardownCount, 1)
        XCTAssertEqual(fake(store, a2)?.teardownCount, 0, "the survivor was never torn down")
    }

    // MARK: - Helpers

    /// Polls a `@MainActor` predicate until true or the deadline passes (avoids fixed sleeps). Mirrors
    /// the `waitUntil` used by `ScenePhaseFanOutTests` / the connection tests.
    private func waitUntil(
        timeout: Duration = .seconds(5),
        _ predicate: @MainActor () -> Bool,
    ) async -> Bool {
        let start = ContinuousClock.now
        while ContinuousClock.now - start < timeout {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return predicate()
    }
}
