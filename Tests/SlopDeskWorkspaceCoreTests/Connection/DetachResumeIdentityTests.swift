import Foundation
import SlopDeskClient
import SlopDeskProtocol
import SlopDeskTransport
import SlopDeskWorkspaceModel
import XCTest
@testable import SlopDeskWorkspaceCore

/// Tests for the SLOPDESK_DETACH_ENABLED capture path and WorkspaceStore wiring.
///
/// The capture path writes the effective sessionID + seq back into the spec (via
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

    // MARK: - onResumeIdentitySnapshot is called with the effective sessionID + seq

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

    // MARK: - Cold-launch reattach: the pane presents its OWN id

    /// THE NORTH-STAR REATTACH CONTRACT. `LivePaneSession.make` seeds the client's resume identity
    /// with the LEAF's own `PaneID` and `seq = 0`.
    ///
    /// The id: the client proposes object ids, so the pane the layout calls X is the pane the host
    /// files its PTY and its liveness under. A pane that has run before reattaches to its own shell;
    /// a brand-new one spawns a fresh shell under that same id (`HostServer.spawnFreshShell` branches
    /// only on the ZERO id), so nothing has to know which case it is in.
    ///
    /// The seq: this is a COLD path — the client actor is brand-new, so `highestContiguousSeq` starts
    /// at 0 regardless. Presenting a non-zero seq would tell the host to replay only `seq > N`,
    /// skipping the whole scrollback ring; presenting 0 gets the full ring, like `tmux attach`.
    func testMakeTerminalPresentsThePanesOwnIDAsTheResumeSeed() async throws {
        let paneID = PaneID()
        let recording = SeedRecordingTransport()
        let session = LivePaneSession.make(
            paneID: paneID,
            spec: PaneSpec(kind: .terminal, title: "Terminal"),
            makeClient: { seed in SlopDeskClient(makeTransport: { recording }, resumeSeed: seed) },
            makeInspector: { _ in nil },
            target: { .default },
        )

        let vm = try XCTUnwrap(session.connection, "a .terminal pane always has a connection")
        await vm.connect()

        let (presentedResume, presentedSeq) = await recording.connectArgs
        XCTAssertEqual(
            presentedResume, paneID.raw,
            "the pane presents its OWN id, so host liveness lands under the id the topology uses",
        )
        XCTAssertEqual(presentedSeq, 0, "a cold launch asks for the whole ring")
        XCTAssertEqual(session.id, paneID, "and the handle IS that leaf, with no adopt() to fix it up")
    }

    // MARK: - seed-resume-identity-race: LivePaneSession.make seeds at construction, not via a Task

    /// Closes seed-resume-identity-race (`LivePaneSession.swift` `makeClientSeeded`, see
    /// docs/DECISIONS.md): a `makeClientSeeded` that called a zero-arg `makeClient()` factory and
    /// fired an UNAWAITED `Task { await c.seedResumeIdentity(...) }` before returning the client
    /// would have nothing ordering that seed job ahead of `ConnectionViewModel.performConnect()`'s own
    /// separately-scheduled `connect()` Task — under cold-launch restore, the seed could lose the
    /// race against the actor's mailbox, and `connect()` would read a nil `sessionID` (fresh shell)
    /// instead of the restored one.
    ///
    /// This test drives the fixed path end to end: `LivePaneSession.make` → the
    /// `ConnectionViewModel` it wires → `connect()` — with a `makeClient` factory shaped exactly like
    /// production's `WorkspaceStore.muxBackedClientFactory` (a `(SlopDeskClient.ResumeSeed?) ->
    /// SlopDeskClient` that forwards the seed straight into `SlopDeskClient.init(resumeSeed:)`). It
    /// asserts the FIRST connect presents the restored `sessionID` with `lastReceivedSeq == 0` (the
    /// cold-launch contract) — deterministically, with no sleeps and no dependence on Task scheduling
    /// order, because the seed is set synchronously in `init` before `makeClientSeeded` (a plain
    /// zero-arg closure with no `Task` left in it) ever returns the client.
    func testLivePaneSessionMakeSeedsClientAtConstructionNoRace() async throws {
        let paneID = PaneID()
        let recording = SeedRecordingTransport()
        let session = LivePaneSession.make(
            paneID: paneID,
            spec: PaneSpec(kind: .terminal, title: "Terminal"),
            makeClient: { seed in SlopDeskClient(makeTransport: { recording }, resumeSeed: seed) },
            makeInspector: { _ in nil },
            target: { .default },
        )

        let vm = try XCTUnwrap(session.connection, "a .terminal pane always has a connection")
        await vm.connect()

        let (presentedResume, presentedSeq) = await recording.connectArgs
        XCTAssertEqual(
            presentedResume, paneID.raw,
            "LivePaneSession.make must seed the resume identity at construction, with no race "
                + "against ConnectionViewModel's separately-scheduled connect() Task",
        )
        XCTAssertEqual(
            presentedSeq, 0,
            "cold launch must present lastReceivedSeq=0",
        )
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
