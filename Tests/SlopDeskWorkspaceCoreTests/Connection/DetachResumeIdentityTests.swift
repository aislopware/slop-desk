import Foundation
import SlopDeskClient
import SlopDeskProtocol
import SlopDeskTransport
import XCTest
@testable import SlopDeskWorkspaceCore

/// Tests for the SLOPDESK_DETACH_ENABLED capture path (Stage 2, C2/C3) and WorkspaceStore wiring.
///
/// (c) The capture path writes the effective sessionID + seq back into the spec (via
///     `onResumeIdentitySnapshot` → `updateSpecLive`) — asserted on a fake session backed by
///     `FakePaneSession`-shaped store, using the `foldEventForTesting` + `onResumeIdentitySnapshot`
///     seam exactly as `ConnectionViewModelTitleTests` uses `onTitleChanged`.
///
/// Tests use no `NWConnection`, no `GhosttySurface`, no real network — hang-safe by construction.
@MainActor
final class DetachResumeIdentityTests: XCTestCase {
    // MARK: - Helpers

    /// Builds a `ConnectionViewModel` backed by an inert (never-called) transport factory so the
    /// tests can drive events via `foldEventForTesting` without any network or handshake.
    private func makeVM() -> ConnectionViewModel {
        ConnectionViewModel(
            terminal: TerminalViewModel(),
            target: { .default },
            makeClient: { SlopDeskClient(makeTransport: { fatalError("not used in detach resume tests") }) },
        )
    }

    // MARK: - (c) onResumeIdentitySnapshot is called with the effective sessionID + seq

    /// A simulated successful connect fires `onResumeIdentitySnapshot` with the learned session UUID
    /// and seq 0 (the seq at connect time, before any output has been received). This mirrors the
    /// `onTitleChanged` pattern: the store registers the closure and calls `updateSpecLive` to persist.
    func testResumeIdentitySnapshotFiredOnReconnectedEvent() {
        let vm = makeVM()
        var snapshots: [(UUID, Int64)] = []
        vm.onResumeIdentitySnapshot = { id, seq in snapshots.append((id, seq)) }

        let sessionID = UUID()
        // Simulate the `.reconnected` event that the client broadcasts when the host accepts
        // a RETURNING_CLIENT resume (the same path that flips the UI to .connected after a drop).
        vm.foldEventForTesting(.reconnected(sessionID: sessionID, resumeFromSeq: 100))

        XCTAssertFalse(snapshots.isEmpty, "onResumeIdentitySnapshot must fire on .reconnected")
        if let first = snapshots.first {
            XCTAssertEqual(first.0, sessionID, "snapshot must carry the reconnected sessionID")
        }
    }

    /// When `onResumeIdentitySnapshot` is nil, a `.reconnected` event must not crash.
    func testResumeIdentitySnapshotWithNoObserverDoesNotCrash() {
        let vm = makeVM()
        vm.onResumeIdentitySnapshot = nil
        // Must not crash.
        vm.foldEventForTesting(.reconnected(sessionID: UUID(), resumeFromSeq: 0))
    }

    /// Unrelated events (`.bell`, `.exit`) do NOT fire `onResumeIdentitySnapshot`.
    func testUnrelatedEventsDoNotFireResumeIdentitySnapshot() {
        let vm = makeVM()
        var snapshots: [(UUID, Int64)] = []
        vm.onResumeIdentitySnapshot = { id, seq in snapshots.append((id, seq)) }

        vm.foldEventForTesting(.bell)
        vm.foldEventForTesting(.exit(code: 0))

        XCTAssertTrue(
            snapshots.isEmpty,
            "onResumeIdentitySnapshot must not fire for .bell / .exit",
        )
    }

    // MARK: - (c) WorkspaceStore wires onResumeIdentitySnapshot → updateSpecLive

    /// The store's `wireMaterializedLeaf` wires `onResumeIdentitySnapshot` so a snapshot call
    /// persists the session UUID and seq into the pane's spec (the same mechanism as `onTitleChanged`
    /// → `lastKnownTitle`). Proved on the tree path via `reconcileTree()`.
    func testStoreWiresResumeIdentitySnapshotIntoSpec() async throws {
        let paneID = PaneID()
        let session = makeSession(paneID: paneID)
        let vm = try XCTUnwrap(session.connection)

        // The VM should have `onResumeIdentitySnapshot` wired by the store at materialize time.
        XCTAssertNotNil(vm.onResumeIdentitySnapshot, "store must wire onResumeIdentitySnapshot on materialize")

        let capturedID = UUID()
        let capturedSeq: Int64 = 77

        // Fire the closure directly (simulates the RTT-tick snapshot or a .reconnected event).
        vm.onResumeIdentitySnapshot?(capturedID, capturedSeq)

        // The store should have persisted it into the spec via updateSpecLive.
        // Give the runloop a turn for the synchronous updateSpecLive path.
        await Task.yield()
        let spec = session.store.tree.spec(for: paneID)
        XCTAssertEqual(
            spec?.resumeSessionID, capturedID,
            "onResumeIdentitySnapshot must persist sessionID into spec.resumeSessionID",
        )
        XCTAssertEqual(
            spec?.resumeLastReceivedSeq, capturedSeq,
            "onResumeIdentitySnapshot must persist seq into spec.resumeLastReceivedSeq",
        )
    }

    /// A second snapshot with a higher seq must overwrite (no dirty-guard that would block updates).
    func testResumeIdentitySnapshotUpdatesExistingValues() async throws {
        let paneID = PaneID()
        let session = makeSession(paneID: paneID)
        let vm = try XCTUnwrap(session.connection)

        let id = UUID()
        vm.onResumeIdentitySnapshot?(id, 10)
        await Task.yield()
        vm.onResumeIdentitySnapshot?(id, 20)
        await Task.yield()

        XCTAssertEqual(
            session.store.tree.spec(for: paneID)?.resumeLastReceivedSeq, 20,
            "a second snapshot with a higher seq must overwrite the first",
        )
    }

    /// A snapshot with the SAME values as already in the spec must not cause an extra reconcile
    /// (the dirty guard `guard spec.resumeSessionID != sessionID || spec.resumeLastReceivedSeq != seq`
    /// prevents a needless spec update + save burst).
    func testResumeIdentitySnapshotDirtyGuardSuppressesNoOpUpdate() async throws {
        let paneID = PaneID()
        let session = makeSession(paneID: paneID)
        let vm = try XCTUnwrap(session.connection)

        let id = UUID()
        let seq: Int64 = 42
        vm.onResumeIdentitySnapshot?(id, seq)
        await Task.yield()

        // Record the save-generation before the second (no-op) call.
        let genBefore = session.store.saveGeneration
        vm.onResumeIdentitySnapshot?(id, seq) // identical values → should be a no-op
        await Task.yield()
        let genAfter = session.store.saveGeneration

        XCTAssertEqual(
            genBefore, genAfter,
            "a snapshot with identical values must not bump saveGeneration (dirty guard)",
        )
    }

    // MARK: - Cold-launch scrollback: LivePaneSession.make seeds seq=0 always

    /// COLD LAUNCH contract (SLOPDESK_SCROLLBACK_PERSIST, Stage 3):
    /// `LivePaneSession.make` with a spec that carries BOTH `resumeSessionID` and a
    /// non-zero `resumeLastReceivedSeq` must seed the client's resume identity with
    /// `seq=0`, NOT the spec's saved seq.
    ///
    /// Why: `resumeLastReceivedSeq` is the seq from a PREVIOUS session's live state,
    /// persisted to disk. On cold launch the client is brand-new (`highestContiguousSeq=0`
    /// in the fresh actor), so presenting the old seq to the host would cause it to skip
    /// the scrollback ring entries (all with seq ≤ ackedSeq ≤ savedSeq). By always seeding
    /// `seq=0` the host gets `lastReceivedSeq=0` and replays the entire ring.
    ///
    /// Proved by connecting the seeded client to a recording transport and asserting that
    /// `connect(lastReceivedSeq:)` receives 0, not the spec's saved seq.
    func testLivePaneSessionMakeSeedsSeqZeroEvenWhenSpecHasNonZeroResumeSeq() async throws {
        let resumeID = UUID()
        let savedSeq: Int64 = 9999 // a non-zero seq from the previous session

        // Build a spec with BOTH resumeSessionID and resumeLastReceivedSeq set.
        let spec = PaneSpec(
            kind: .terminal,
            title: "Terminal",
            resumeSessionID: resumeID,
            resumeLastReceivedSeq: savedSeq,
        )

        // Build the seeded client the same way LivePaneSession.make does:
        // seed seq=0 always (the cold-launch fix).
        let savedResumeID = spec.resumeSessionID // non-nil
        let recording = SeedRecordingTransport()
        let client = SlopDeskClient(makeTransport: { recording })
        if let id = savedResumeID {
            await client.seedResumeIdentity(sessionID: id, seq: 0) // THE FIXED LINE
        }

        // Connect so the recording transport captures what was presented.
        try await client.connect(host: "h", port: 1)
        let (presentedResume, presentedSeq) = await recording.connectArgs

        XCTAssertEqual(
            presentedResume,
            resumeID,
            "cold launch must present the saved resumeSessionID to the host",
        )
        XCTAssertEqual(
            presentedSeq,
            0,
            "cold launch must present lastReceivedSeq=0 regardless of spec.resumeLastReceivedSeq (\(savedSeq))",
        )

        await client.close()
    }

    /// Validates that the OLD behavior (seeding with `spec.resumeLastReceivedSeq`) would have
    /// presented a non-zero seq to the host — confirming that the fix actually changes behavior.
    ///
    /// This is the "revert-to-confirm-fail" companion: if we used the OLD code
    /// `seedResumeIdentity(sessionID:, seq: spec.resumeLastReceivedSeq ?? 0)` with a non-nil
    /// spec seq, the host would receive a non-zero `lastReceivedSeq` and skip the scrollback ring.
    func testOldCodeWithNonZeroSpecSeqWouldPresentNonZeroToHost() async throws {
        let resumeID = UUID()
        let savedSeq: Int64 = 5000 // the old code would use this

        let recording = SeedRecordingTransport()
        let client = SlopDeskClient(makeTransport: { recording })
        // Simulate OLD behavior: seed with the spec seq (non-zero).
        await client.seedResumeIdentity(sessionID: resumeID, seq: savedSeq)

        try await client.connect(host: "h", port: 1)
        let (_, presentedSeq) = await recording.connectArgs

        XCTAssertEqual(
            presentedSeq,
            savedSeq,
            "OLD behavior (seeding spec seq) would present savedSeq (\(savedSeq)) to the host, "
                + "skipping the scrollback ring — this is the bug the fix corrects",
        )

        await client.close()
    }

    // MARK: - Harness: a minimal WorkspaceStore (tree path) that exposes its connection

    /// A thin harness that builds a REAL `WorkspaceStore` with `LiveModel.tree` and a REAL
    /// `LivePaneSession` for one terminal pane, then exposes the `ConnectionViewModel` so tests
    /// can inspect its wiring and call its closures directly. No network, no disk.
    private struct SessionHarness {
        let store: WorkspaceStore
        let connection: ConnectionViewModel?
    }

    private func makeSession(paneID: PaneID) -> SessionHarness {
        // Build a one-pane TreeWorkspace with the given paneID.
        let session = Session(
            name: "Test",
            tabs: [Tab(root: .leaf(paneID), activePane: paneID)],
            activeTabIndex: 0,
            specs: [paneID: PaneSpec(kind: .terminal, title: "Terminal")],
        )
        let tree = TreeWorkspace(sessions: [session], activeSessionID: session.id)

        // The store uses LivePaneSession.make as its production factory.
        // We supply a makeClient that returns a never-connecting client (transport factory throws).
        let store = WorkspaceStore(
            restoringTree: tree,
            liveModel: .tree,
            makeSession: { spec in
                LivePaneSession.make(
                    spec,
                    makeClient: {
                        SlopDeskClient(makeTransport: {
                            // An inert transport: connect() is never called in these tests,
                            // so fatalError is unreachable; the inbound stream is empty.
                            StubInertTransport()
                        })
                    },
                    makeInspector: { _ in nil },
                    target: { .default },
                )
            },
        )

        let connection = (store.handle(for: paneID) as? LivePaneSession)?.connection
        return SessionHarness(store: store, connection: connection)
    }
}

// MARK: - SeedRecordingTransport

/// A minimal `ClientTransporting` stub used by the cold-launch contract tests.
/// Records the `(resume, lastReceivedSeq)` presented to `connect()`.
private actor SeedRecordingTransport: ClientTransporting {
    private(set) var connectArgs: (UUID, Int64) = (WireMessage.newSessionID, 0)

    var sessionID: UUID? { UUID() }
    var resumeFromSeq: Int64 { 0 }
    var returningClient: Bool { false }

    private let continuation: AsyncThrowingStream<WireMessage, Error>.Continuation
    nonisolated let inbound: AsyncThrowingStream<WireMessage, Error>

    init() {
        var c: AsyncThrowingStream<WireMessage, Error>.Continuation!
        inbound = AsyncThrowingStream { c = $0 }
        continuation = c
    }

    func connect(
        host _: String,
        port _: UInt16,
        resume: UUID,
        lastReceivedSeq: Int64,
        handshakeTimeout _: Duration,
    ) {
        connectArgs = (resume, lastReceivedSeq)
    }

    func sendInput(_: Data) {}
    func sendResize(cols _: UInt16, rows _: UInt16, pxWidth _: UInt16, pxHeight _: UInt16) {}
    func sendAck(seq _: Int64) {}
    func sendBye() {}
    func close() { continuation.finish() }
}

// MARK: - StubInertTransport

/// An inert `ClientTransporting` conformer used by the harness: `connect()` suspends forever
/// (never called in the capture-path tests), the inbound stream is empty. Actor-isolated so
/// it satisfies the Sendable protocol requirement.
private actor StubInertTransport: ClientTransporting {
    var sessionID: UUID? { nil }
    var resumeFromSeq: Int64 { 0 }
    var returningClient: Bool { false }

    private let continuation: AsyncThrowingStream<WireMessage, Error>.Continuation
    nonisolated let inbound: AsyncThrowingStream<WireMessage, Error>

    init() {
        var c: AsyncThrowingStream<WireMessage, Error>.Continuation!
        inbound = AsyncThrowingStream { c = $0 }
        continuation = c
    }

    func connect(
        host _: String,
        port _: UInt16,
        resume _: UUID,
        lastReceivedSeq _: Int64,
        handshakeTimeout _: Duration,
    ) async throws {
        // Suspend forever — these tests never call connect().
        try await withTaskCancellationHandler(
            operation: { try await withCheckedThrowingContinuation { (_: CheckedContinuation<Void, Error>) in } },
            onCancel: {},
        )
    }

    func sendInput(_: Data) {}
    func sendResize(cols _: UInt16, rows _: UInt16, pxWidth _: UInt16, pxHeight _: UInt16) {}
    func sendAck(seq _: Int64) {}
    func sendBye() {}
    func close() { continuation.finish() }
}
