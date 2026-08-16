import Foundation
import SlopDeskSupervisor
import XCTest
@testable import SlopDeskHost

/// The user-visible promise, at the level the user experiences it: **edit a host file, restart
/// hostd, and the agent that was running is still running.**
///
/// `SupervisedPaneSurvivalTests` proves the mechanism (a master fd outlives its holder).
/// This proves the PRODUCT: a whole `HostServer` lifetime ends, a second one begins, and the pane
/// comes back — same pid, same shell, parked and claimable. Both halves have to be true and they
/// are separately breakable, because between them sits every place hostd used to reach for a
/// signal on the way out.
///
/// Skips when `slopdesk-superd` is not built — see ``SuperdFixture``.
final class HostRestartSurvivalTests: XCTestCase {
    private var superd: SuperdFixture?
    private var stateDirectory: URL?

    override func setUpWithError() throws {
        superd = try SuperdFixture()
        // `HostServer.start()` loads and saves the workspace document. Without this it would
        // overwrite the developer's real one (`CLAUDE.md`).
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("slopdesk-restart-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        setenv("SLOPDESK_WORKSPACE_STATE_DIR", directory.path, 1)
        stateDirectory = directory
    }

    override func tearDownWithError() throws {
        unsetenv("SLOPDESK_WORKSPACE_STATE_DIR")
        if let stateDirectory { try? FileManager.default.removeItem(at: stateDirectory) }
        stateDirectory = nil
        superd = nil
        try XCTSkipIf(false)
    }

    private func makeServer() -> HostServer {
        HostServer(port: 0, detachEnabled: true, resumeOnRecovery: true)
    }

    /// One full restart cycle.
    func testAPaneSurvivesAWholeHostdLifetimeAndIsAdoptedByTheNext() async throws {
        _ = try XCTUnwrap(superd)

        // ── hostd, life one ──────────────────────────────────────────────────────────────────
        let first = makeServer()
        try await first.start()
        let paneID = try await first.spawnStandalonePane(
            cmd: ["/bin/sh", "-c", "printf 'up\\n'; sleep 30"],
            cwd: NSTemporaryDirectory(),
            env: nil,
            rows: 24,
            cols: 80,
        )
        let sessionID = try XCTUnwrap(UUID(uuidString: paneID))
        let spawned = try XCTUnwrap(first.listPanesForControl().first { $0.paneId == paneID })
        let child = spawned.pid
        XCTAssertGreaterThan(child, 0)
        XCTAssertTrue(spawned.isAlive)

        // ── the restart ──────────────────────────────────────────────────────────────────────
        // `stop()` is the whole point. It used to SIGHUP → SIGTERM → SIGKILL every pane on its way
        // out; it now relinquishes them.
        await first.stop()
        usleep(300_000)
        XCTAssertEqual(
            kill(child, 0), 0,
            "THE regression: a hostd stop must not kill a pane. This failing means every restart "
                + "throws away whatever the user's agents were mid-way through.",
        )

        // ── hostd, life two ──────────────────────────────────────────────────────────────────
        let second = makeServer()
        try await second.start()
        defer { Task { await second.stop() } }

        let adopted = try XCTUnwrap(
            second.listPanesForControl().first { $0.paneId == paneID },
            "the new hostd must find the surviving pane and take it back",
        )
        XCTAssertEqual(adopted.pid, child, "the same shell, not a fresh one")
        XCTAssertTrue(adopted.isAlive)
        XCTAssertTrue(
            second.detachedStoreForTesting?.storedIDsForTesting.contains(sessionID) ?? false,
            "an adopted pane must be PARKED — that is what makes the returning client's "
                + "channelOpen take the reattach path instead of spawning a second shell",
        )

        // Tidy: this one really is over. `killPaneForControl` is the deliberate close, and it must
        // still work on a pane this process never spawned.
        XCTAssertTrue(second.killPaneForControl(paneId: paneID))
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, kill(child, 0) == 0 { usleep(20000) }
        XCTAssertNotEqual(kill(child, 0), 0, "a deliberately killed pane must actually end")
    }

    /// Adoption stops at the panes that are actually free.
    ///
    /// `adoptSurvivingPanes` runs at every `start()` and asks superd for everything it holds — and
    /// superd holds ONE registry for the machine, not one per daemon. Nothing in a pane id says
    /// which hostd forked it (the rekey to bare session UUIDs took that away), so without the
    /// `attached` check a second daemon booting alongside a live one would adopt its panes out from
    /// under it: two hostds subscribed to one pane, and the first one's client watching its terminal
    /// go quiet mid-agent.
    func testASecondHostdDoesNotAdoptTheLiveOnesPanes() async throws {
        let fixture = try XCTUnwrap(superd)

        // The other daemon, modelled as what it IS to superd: another connection holding a pane.
        // (Two whole `HostServer`s in one process is not the same scenario — they would share
        // `HostServiceSupervisor.shared` and the panel managers, which are per-PROCESS singletons.)
        let other = SupervisorClient(socketPath: fixture.socketPath)
        try other.connect(clientName: "slopdesk-tests-other-hostd")
        defer { other.disconnect() }
        let session = UUID()
        let theirs = PTYProcess(supervisor: other)
        try theirs.spawn(
            "/bin/sh",
            arguments: ["-c", "sleep 30"],
            environment: ["PATH": "/usr/bin:/bin"],
            // A BARE session UUID, exactly like every hostd pane — so the id parses and only
            // `attached` can stop the adoption.
            paneID: session.uuidString,
            sessionID: session.uuidString,
        )
        defer {
            theirs.release(kill: true)
            theirs.closeMaster()
        }

        let server = makeServer()
        try await server.start()
        defer { Task { await server.stop() } }

        XCTAssertNil(
            server.listPanesForControl().first { $0.paneId == session.uuidString },
            "a pane another live hostd is attached to is that daemon's — adopting it would leave "
                + "two subscribers on one stream and two writers on one journal",
        )
        XCTAssertFalse(
            server.detachedStoreForTesting?.storedIDsForTesting.contains(session) ?? false,
            "and it must not be parked either: an eviction from this store would SIGHUP a shell "
                + "the other daemon's client is using",
        )
        XCTAssertEqual(
            tcgetpgrp(theirs.masterFD), theirs.pid,
            "the holder's master is untouched by the visit",
        )
    }

    /// And it stops at the panes another daemon has merely PUT DOWN for a moment.
    ///
    /// `attached` cannot carry this on its own: it is false for the whole ~0.2 s of the other
    /// hostd's restart, which is exactly when a second daemon starting up looks at the registry.
    /// The pane says who owns it (`SpawnRequest.owner`), and an owner that is not ours means "not
    /// ours" whatever the flag says — otherwise the stranger's `claude` lands in this daemon's
    /// detached store, on this daemon's TTL clock, and the owner that comes back finds it attached
    /// to somebody else and leaves it alone forever.
    func testASecondHostdDoesNotAdoptAStrangersRelinquishedPanes() async throws {
        let fixture = try XCTUnwrap(superd)

        let other = SupervisorClient(socketPath: fixture.socketPath)
        try other.connect(clientName: "slopdesk-tests-other-hostd")
        let session = UUID()
        let theirs = PTYProcess(supervisor: other)
        try theirs.spawn(
            "/bin/sh",
            arguments: ["-c", "sleep 30"],
            environment: ["PATH": "/usr/bin:/bin"],
            paneID: session.uuidString,
            sessionID: session.uuidString,
            owner: "hostd port=65000 state=another-daemon",
        )
        // The other daemon stopping: its duplicate goes, its connection goes, and superd's record
        // says unattached — a pane in the middle of somebody else's restart.
        theirs.closeMaster()
        other.disconnect()

        let server = makeServer()
        try await server.start()
        defer { Task { await server.stop() } }

        XCTAssertNil(
            server.listPanesForControl().first { $0.paneId == session.uuidString },
            "an unattached pane belonging to another hostd was adopted — the flag says free, the "
                + "owner says otherwise, and the owner is the one that knows",
        )
        XCTAssertFalse(
            server.detachedStoreForTesting?.storedIDsForTesting.contains(session) ?? false,
            "and it must not be parked: an eviction here would SIGHUP a shell that is coming back "
                + "to its own daemon",
        )

        let janitor = SupervisorClient(socketPath: fixture.socketPath)
        try janitor.connect(clientName: "slopdesk-tests-janitor")
        try? janitor.release(paneID: session.uuidString, kill: true)
        janitor.disconnect()
    }

    /// The other direction, so the first test cannot pass by simply never killing anything:
    /// a pane closed BEFORE the restart must not come back from the dead.
    func testAPaneClosedBeforeTheRestartDoesNotComeBack() async throws {
        _ = try XCTUnwrap(superd)

        let first = makeServer()
        try await first.start()
        let paneID = try await first.spawnStandalonePane(
            cmd: ["/bin/sh", "-c", "sleep 30"],
            cwd: NSTemporaryDirectory(),
            env: nil,
            rows: 24,
            cols: 80,
        )
        XCTAssertTrue(first.killPaneForControl(paneId: paneID))
        await first.stop()

        let second = makeServer()
        try await second.start()
        defer { Task { await second.stop() } }
        XCTAssertNil(
            second.listPanesForControl().first { $0.paneId == paneID },
            "a deliberately closed pane must stay closed across a restart",
        )
    }
}
