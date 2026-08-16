import Darwin
import Foundation
import SlopDeskHost
import SlopDeskSupervisor
import XCTest

/// The reason `slopdesk-superd` exists, stated as a test: **a hostd restart must not kill a pane.**
///
/// Everything else in `docs/51` is machinery in service of this one assertion. Editing a host file
/// used to mean either shipping late or throwing away whatever `claude` was mid-way through,
/// because hostd held the only PTY master and the last close of a master `SIGHUP`s the foreground
/// process group. Here the pane is spawned through the daemon, hostd's whole connection is torn
/// down — its master duplicate closed, its socket dropped, exactly what an exiting hostd does — and
/// the child is then found alive, re-adopted by a fresh client, and driven again.
///
/// ## Why this lives here and not in `SlopDeskSupervisorTests`
/// It used to be `testChildSurvivesOneHolderClosingWhileAnotherHolds`, which forked a `/bin/sh` in
/// Swift and passed its master across a `socketpair` — a hand-built stand-in for the daemon. Swift
/// can no longer do either half of that (it cannot fork a pane and it cannot send an fd), and the
/// stand-in was never the thing that ships. This runs against the real `slopdesk-superd`, so it
/// pins Rust's `SCM_RIGHTS` writer against Swift's reader and Rust's registry against hostd's
/// release policy at the same time.
///
/// Skips, by name, when the daemon is not built — see ``SuperdFixture``.
final class SupervisedPaneSurvivalTests: XCTestCase {
    private var superd: SuperdFixture?

    override func setUpWithError() throws {
        superd = try SuperdFixture()
    }

    override func tearDown() {
        superd = nil
    }

    /// The other end of the same coupling: a pane may finish before anybody is listening, and its
    /// output must survive it.
    ///
    /// Once `read` moved into superd, a pane's bytes lived in that pane's ring — and the pane died
    /// with its child, at whichever microsecond the reaper got to it. `slopdesk-ctl spawn --cmd ls`
    /// completes long before hostd's `subscribe` makes the round trip, so the subscribe hit a pane
    /// that no longer existed, and the pane rendered EMPTY. Not slowly, not partially: nothing at
    /// all, every time the command was fast. Fixed by superd keeping the ring of an exited pane
    /// (its "graveyard") and saying `ended` in the subscribe reply, since the `exited` notice that
    /// would normally end the stream went out before this subscriber existed.
    func testAPaneThatFinishesBeforeAnyoneSubscribesStillDeliversItsOutput() throws {
        let fixture = try XCTUnwrap(superd)
        let pane = try fixture.pty(
            "/bin/sh",
            arguments: ["-c", "printf 'all of it\\n'"],
            environment: ["PATH": "/usr/bin:/bin"],
            paneID: "quick-\(UUID().uuidString.prefix(8))",
        )

        // Deliberately let it finish first. Nothing has subscribed, so this is exactly the race the
        // fix is for — made deterministic rather than hoped for.
        let deadline = Date().addingTimeInterval(10)
        while kill(pane.pid, 0) == 0, Date() < deadline {
            usleep(10000)
        }
        XCTAssertNotEqual(kill(pane.pid, 0), 0, "the child must be gone before the subscription")
        usleep(200_000) // and reaped, entombed, and announced to nobody

        let output = try PaneOutput(pane)
        XCTAssertTrue(
            output.waitFor("all of it", timeout: 5).contains("all of it"),
            "a late subscriber must still get the whole run; got: \(output.text.debugDescription)",
        )
        XCTAssertTrue(
            output.waitForEnd(),
            "and must be told the stream is over, or the session waits forever for an end that "
                + "already happened",
        )
    }

    /// A hostd restart, end to end: spawn, prove the child is live, drop everything hostd holds,
    /// reconnect as a new hostd, adopt the same `paneID`, and drive the same shell.
    func testAPaneOutlivesTheHostdThatSpawnedIt() throws {
        let fixture = try XCTUnwrap(superd)
        // Stable across the "restart", exactly as a real paneID must be (`docs/51` §5).
        let paneID = "survivor-\(UUID().uuidString.prefix(8))"

        let pane = try fixture.pty(
            "/bin/sh",
            arguments: ["-c", "printf 'up\\n'; sleep 30"],
            environment: ["PATH": "/usr/bin:/bin"],
            paneID: paneID,
        )
        let child = pane.pid
        XCTAssertGreaterThan(child, 0)
        let output = try PaneOutput(pane)
        XCTAssertTrue(
            output.waitFor("up", timeout: 5).contains("up\r\n"),
            "the pane's subscription must carry the child's output; got: \(output.text.debugDescription)",
        )

        // ── hostd exits ──────────────────────────────────────────────────────────────────────
        // Both halves of it, and in the order a real exit does them: the duplicate master is closed
        // (`closeMaster`, NOT `release` — release is the user closing a tab) and the control socket
        // goes away. Nothing here is a request to superd; superd only notices the peer vanish.
        pane.closeMaster()
        fixture.client.disconnect()
        usleep(300_000)

        XCTAssertEqual(
            kill(child, 0), 0,
            "the child must survive hostd closing its duplicate of the master",
        )

        // ── a new hostd starts ───────────────────────────────────────────────────────────────
        let restarted = SupervisorClient(socketPath: fixture.socketPath)
        try restarted.connect(clientName: "slopdesk-tests-restarted")
        defer { restarted.disconnect() }

        let listed = try restarted.list()
        let found = try XCTUnwrap(
            listed.first { $0.paneID == paneID },
            "a pane whose holder went away must still be listed — it is live, just unattached",
        )
        XCTAssertEqual(found.pid, child)
        XCTAssertFalse(found.attached, "nobody holds it yet")

        let adopted = try restarted.adopt(paneID: paneID)
        defer { close(adopted.masterFD) }
        XCTAssertEqual(adopted.record.pid, child, "the same child, not a fresh shell")
        XCTAssertEqual(
            tcgetpgrp(adopted.masterFD), child,
            "the re-adopted master must still address the child's foreground process group",
        )

        // Not merely open — usable. A master that reads and resizes is a pane the user can go back
        // to work in, which is the whole claim.
        var resized = winsize(ws_row: 40, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)
        XCTAssertEqual(ioctl(adopted.masterFD, TIOCSWINSZ, &resized), 0)
        var readback = winsize()
        XCTAssertEqual(ioctl(adopted.masterFD, TIOCGWINSZ, &readback), 0)
        XCTAssertEqual(readback.ws_row, 40)
        XCTAssertEqual(readback.ws_col, 120)

        // Tidy: this pane really is over now, so say so — the one call that DOES hang the shell up.
        try restarted.release(paneID: paneID, kill: true)
    }

    /// A `spawn` onto a pane id that is still alive TAKES IT OVER instead of failing.
    ///
    /// The route matters as much as the outcome. This is not the restart path (`adoptSurvivingPanes`,
    /// which runs at `start()` and knows what it is looking for) — it is a client asking for a pane
    /// hostd believes it has never spawned, because adoption was off or skipped that one pane. Before
    /// this, superd's correct refusal of a duplicate id surfaced as a dead tab per surviving shell,
    /// permanently, curable only by killing superd — which is killing the agents.
    func testSpawningOntoASurvivingPaneAdoptsItRatherThanFailing() throws {
        let fixture = try XCTUnwrap(superd)
        let paneID = "readopt-\(UUID().uuidString.prefix(8))"

        // The pane the previous hostd left behind. Its own connection, so dropping it leaves the
        // pane live and UNATTACHED — the state a relinquished pane is really in.
        let departed = SupervisorClient(socketPath: fixture.socketPath)
        try departed.connect(clientName: "slopdesk-tests-departed")
        let first = PTYProcess(supervisor: departed)
        try first.spawn(
            "/bin/sh",
            arguments: ["-c", "printf 'up\\n'; sleep 30"],
            environment: ["PATH": "/usr/bin:/bin"],
            paneID: paneID,
            sessionID: paneID,
        )
        let child = first.pid
        XCTAssertGreaterThan(child, 0)
        first.closeMaster()
        departed.disconnect()
        usleep(300_000)

        // The new hostd, which has no idea this pane exists and simply spawns.
        let successor = PTYProcess(supervisor: fixture.client)
        try successor.spawn(
            "/bin/sh",
            arguments: ["-c", "printf 'never\\n'; sleep 30"],
            environment: ["PATH": "/usr/bin:/bin"],
            paneID: paneID,
            sessionID: paneID,
        )
        XCTAssertEqual(
            successor.pid, child,
            "the duplicate must be resolved by ADOPTING the survivor — a second fork under one id "
                + "would orphan the first child, and a refusal would strand the user's tab",
        )
        XCTAssertGreaterThan(
            successor.paneSpawnedAt, 0,
            "the adopted pane must carry the LIFE it was forked in, or a resume offset from some "
                + "other fork will one day be applied to this stream",
        )

        successor.release(kill: true)
        successor.closeMaster()
    }

    /// And the theft case, which is the same code path with one bit flipped: a pane another live
    /// hostd is ATTACHED to is that daemon's, so the spawn fails rather than pulling the master out
    /// from under it. After the rekey to bare session UUIDs, `attached` is the only thing that tells
    /// one daemon's panes from another's.
    func testSpawningOntoAPaneAnotherHostdHoldsFailsInsteadOfStealingIt() throws {
        let fixture = try XCTUnwrap(superd)
        let paneID = "held-\(UUID().uuidString.prefix(8))"

        let holder = SupervisorClient(socketPath: fixture.socketPath)
        try holder.connect(clientName: "slopdesk-tests-holder")
        defer { holder.disconnect() }
        let theirs = PTYProcess(supervisor: holder)
        try theirs.spawn(
            "/bin/sh",
            arguments: ["-c", "sleep 30"],
            environment: ["PATH": "/usr/bin:/bin"],
            paneID: paneID,
            sessionID: paneID,
        )
        defer {
            theirs.release(kill: true)
            theirs.closeMaster()
        }

        let intruder = PTYProcess(supervisor: fixture.client)
        XCTAssertThrowsError(
            try intruder.spawn(
                "/bin/sh",
                arguments: ["-c", "sleep 30"],
                environment: ["PATH": "/usr/bin:/bin"],
                paneID: paneID,
                sessionID: paneID,
            ),
            "a pane held by a live daemon must not be adoptable — the error the caller sees is "
                + "superd's own refusal of the duplicate",
        )
        XCTAssertEqual(
            tcgetpgrp(theirs.masterFD), theirs.pid,
            "and the rightful holder's master must be untouched by the attempt",
        )
    }

    /// The other side of the line: `release` is the deliberate close, and it does end the child.
    ///
    /// Pinned next to the survival case on purpose. If both facts were not true at once, the design
    /// would have solved the restart problem by simply leaking every pane forever.
    func testReleaseEndsTheChildForGood() throws {
        let fixture = try XCTUnwrap(superd)
        let paneID = "closer-\(UUID().uuidString.prefix(8))"
        let pane = try fixture.pty(
            "/bin/sh",
            arguments: ["-c", "printf 'up\\n'; sleep 30"],
            environment: ["PATH": "/usr/bin:/bin"],
            paneID: paneID,
        )
        let child = pane.pid
        let output = try PaneOutput(pane)
        output.waitFor("up", timeout: 5)

        pane.release(kill: true)
        pane.closeMaster()

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, kill(child, 0) == 0 { usleep(20000) }
        XCTAssertNotEqual(kill(child, 0), 0, "a released pane's child must be gone")
        XCTAssertNil(
            try fixture.client.list().first { $0.paneID == paneID },
            "and superd must have dropped its record",
        )
    }
}
