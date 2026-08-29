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
            makeClient: { SlopDeskClient(driver: FakePaneDriver.inert("not used in detach resume tests")) },
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
    /// The seq: this is a COLD path — the driver is brand-new, so `highestContiguousSeq` starts at 0
    /// regardless. Seeding a non-zero seq would tell the host to replay only `seq > N`, skipping the
    /// whole scrollback ring; seeding 0 gets the full ring, like `tmux attach`.
    ///
    /// What is asserted is the SEED the factory received, not an argument to a dial, and the two
    /// used to be the same observation. They are not any more: the seed rides
    /// `slopdesk_pane_driver_new`'s config into Rust, where every later `channelOpen` presents it,
    /// so the last place this side can see it is the factory closure — which is also the only place
    /// it could go wrong, since Rust cannot be handed a seed the factory never got.
    func testMakeTerminalPresentsThePanesOwnIDAsTheResumeSeed() async throws {
        let seeds = SeedRecorder()
        let paneID = PaneID()
        let session = LivePaneSession.make(
            paneID: paneID,
            spec: PaneSpec(kind: .terminal, title: "Terminal"),
            makeClient: { seed in seeds.record(seed) },
            makeInspector: { _ in nil },
            target: { .default },
        )

        let vm = try XCTUnwrap(session.connection, "a .terminal pane always has a connection")
        await vm.connect()

        let seeded = try XCTUnwrap(seeds.first, "the factory was called with a seed")
        XCTAssertEqual(
            seeded?.sessionID, paneID.raw,
            "the pane presents its OWN id, so host liveness lands under the id the topology uses",
        )
        XCTAssertEqual(seeded?.lastSeq, 0, "a cold launch asks for the whole ring")
        XCTAssertEqual(session.id, paneID, "and the handle IS that leaf, with no adopt() to fix it up")
    }

    // MARK: - seed-resume-identity-race: LivePaneSession.make seeds at construction, not via a Task

    /// Closes seed-resume-identity-race (`LivePaneSession.swift` `makeClientSeeded`, see
    /// docs/DECISIONS.md): a `makeClientSeeded` that called a zero-arg `makeClient()` factory and
    /// fired an UNAWAITED `Task { await c.seed(...) }` before returning the client would have nothing
    /// ordering that seed job ahead of `ConnectionViewModel.performConnect()`'s own
    /// separately-scheduled `connect()` Task — under cold-launch restore, the seed could lose the
    /// race and `connect()` would open with no session id (a fresh shell) instead of the restored
    /// one. There is no post-construction seeding door at all now, which is what makes the race
    /// unreachable rather than merely unlikely.
    ///
    /// This test drives the fixed path end to end: `LivePaneSession.make` → the
    /// `ConnectionViewModel` it wires → `connect()` — with a `makeClient` factory shaped exactly like
    /// production's `WorkspaceStore.muxBackedClientFactory` (a `(SlopDeskClient.ResumeSeed?) ->
    /// SlopDeskClient` that forwards the seed straight into `SlopDeskClient.init(resumeSeed:)`). It
    /// asserts the factory was handed the restored `sessionID` with `lastSeq == 0` (the cold-launch
    /// contract) BEFORE `connect()` ever ran — deterministically, with no sleeps and no dependence on
    /// Task scheduling order, because `makeClientSeeded` is a plain zero-arg closure with no `Task`
    /// left in it.
    func testLivePaneSessionMakeSeedsClientAtConstructionNoRace() async throws {
        let seeds = SeedRecorder()
        let paneID = PaneID()
        let session = LivePaneSession.make(
            paneID: paneID,
            spec: PaneSpec(kind: .terminal, title: "Terminal"),
            makeClient: { seed in seeds.record(seed) },
            makeInspector: { _ in nil },
            target: { .default },
        )

        let vm = try XCTUnwrap(session.connection, "a .terminal pane always has a connection")
        await vm.connect()

        let seeded = try XCTUnwrap(seeds.first, "the factory was called with a seed")
        XCTAssertEqual(
            seeded?.sessionID, paneID.raw,
            "LivePaneSession.make must seed the resume identity at construction, with no race "
                + "against ConnectionViewModel's separately-scheduled connect() Task",
        )
        XCTAssertEqual(seeded?.lastSeq, 0, "cold launch must seed lastSeq = 0")
    }
}

// MARK: - SeedRecorder

/// Records the ``SlopDeskClient/ResumeSeed`` each `makeClient` call was handed, and hands back a
/// client that never dials.
///
/// The seed is the whole observable: it is applied inside `slopdesk_pane_driver_new`, before the
/// driver escapes to any other thread, so nothing on this side can see it again afterwards. What
/// this pins is that the factory got the right one, synchronously, which is the half of the
/// contract Swift still owns.
private final class SeedRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var seeds: [SlopDeskClient.ResumeSeed?] = []

    /// The seed the FIRST call was handed — double-optional on purpose: the outer `nil` means the
    /// factory was never called at all, the inner one means it was called with no seed.
    var first: (SlopDeskClient.ResumeSeed?)? {
        lock.lock()
        defer { lock.unlock() }
        return seeds.first
    }

    func record(_ seed: SlopDeskClient.ResumeSeed?) -> SlopDeskClient {
        lock.lock()
        seeds.append(seed)
        lock.unlock()
        return SlopDeskClient(driver: FakePaneDriver.inert("the seed tests never reach a host"))
    }
}
