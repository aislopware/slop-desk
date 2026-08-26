import Foundation
import SlopDeskSupervisor
import XCTest
@testable import SlopDeskHost

// ``LineAssembler`` — the whole reason a panel backend may be held on a PTY — is
// `rust/slopdesk-sidecars`' `line_assembler` now, and the five cases that used to be asserted here
// are asserted there, beside four more the Swift never reached: what an over-cap drop does to the
// tail that follows it, that a residue of exactly the cap survives, that a multi-byte character
// split across a chunk boundary is not read as two broken halves, and that an undecodable line is
// dropped without taking its neighbours. What is left in this file is the process.

/// **A panel backend must outlive the hostd that started it.**
///
/// `docs/51` §8 used to list these as a non-goal, on the grounds that code-server and
/// `baguette serve` are addressed by port rather than by fd. That was an answer to "how would a new
/// hostd find them", and it skipped the part that actually cost the user time: `HostServer.stop()`
/// terminated them, so every host edit bought a Node reboot in the code panel. These tests pin the
/// reversal — spawn, let go, adopt, re-learn the port from the child's own words.
final class SupervisedServiceProcessTests: XCTestCase {
    /// Collects the assembled lines a handle reports.
    private final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []

        func record(_ line: String) {
            lock.lock()
            lines.append(line)
            lock.unlock()
        }

        var all: [String] {
            lock.lock()
            defer { lock.unlock() }
            return lines
        }

        /// Blocks until some line contains `needle`.
        func waitFor(_ needle: String, timeout: TimeInterval = 10) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if all.contains(where: { $0.contains(needle) }) { return true }
                Thread.sleep(forTimeInterval: 0.005)
            }
            return false
        }
    }

    /// A stand-in service: announces a port the way both real ones do, then stays up.
    ///
    /// `/bin/sh`, not code-server — this suite may not spawn a real backend (a multi-second Node
    /// boot, a Homebrew dependency), and what is under test is the holding, not the HTTP.
    private func announceThenIdle(_ port: Int) -> (binary: String, arguments: [String]) {
        ("/bin/sh", ["-c", "printf 'HTTP server listening on port \(port)\\n'; exec sleep 30"])
    }

    private func spawn(
        _ fixture: SuperdFixture, service: String, port: Int, log: Log,
    ) throws -> SupervisedServiceProcess {
        let recipe = announceThenIdle(port)
        return try SupervisedServiceProcess.spawnOrAdopt(
            service: service,
            binary: recipe.binary,
            arguments: recipe.arguments,
            environment: ["PATH": "/usr/bin:/bin"],
            supervisor: fixture.client,
            onLogLine: { line in log.record(line) },
        )
    }

    /// The plain path: superd forks it, and its announce line reaches the manager's parser.
    func testTheAnnounceLineReachesTheManagerThroughSuperd() throws {
        let fixture = try SuperdFixture()
        let log = Log()
        let handle = try spawn(fixture, service: "test-announce", port: 41234, log: log)
        defer { handle.terminate() }

        XCTAssertFalse(handle.adopted, "nothing was running under that name yet")
        XCTAssertTrue(
            log.waitFor("listening on port 41234"),
            "the port is learned from the child's own log line, never pre-allocated: \(log.all)",
        )
        XCTAssertTrue(
            log.all.allSatisfy { !$0.contains("\r") },
            "the PTY's carriage returns must not survive the assembler: \(log.all)",
        )
        XCTAssertTrue(handle.isRunning)
    }

    /// The reason this file exists. Letting go is not ending: hostd stops listening, the child
    /// keeps running, and the NEXT hostd adopts it and re-learns the port by replaying the ring
    /// from offset 0 — where the announce line still is.
    func testRelinquishingAServiceLetsTheNextHostdAdoptItAndRelearnThePort() throws {
        let fixture = try SuperdFixture()
        let first = Log()
        let original = try spawn(fixture, service: "test-adopt", port: 41235, log: first)
        XCTAssertTrue(first.waitFor("listening on port 41235"), "\(first.all)")

        // What `HostServer.stop()` does, and the whole difference from `terminate()`.
        original.relinquish()

        let second = Log()
        let successor = try spawn(fixture, service: "test-adopt", port: 41235, log: second)
        defer { successor.terminate() }

        XCTAssertTrue(successor.adopted, "the service ran straight through — it must not be respawned")
        XCTAssertTrue(
            second.waitFor("listening on port 41235"),
            "the successor re-learns the port from the ring, with no state file to go stale: \(second.all)",
        )
        XCTAssertTrue(successor.isRunning)
    }

    /// The counterpart. A deliberate stop really does end the service, and the name is then free
    /// for a fresh spawn rather than adopting a corpse.
    func testTerminateEndsTheServiceForGood() throws {
        let fixture = try SuperdFixture()
        let handle = try spawn(fixture, service: "test-terminate", port: 41236, log: Log())
        let paneID = SupervisedServiceProcess.paneID(for: "test-terminate")
        XCTAssertTrue(try fixture.client.list().contains { $0.paneID == paneID })

        handle.terminate()

        let deadline = Date().addingTimeInterval(5)
        var stillListed = true
        while Date() < deadline, stillListed {
            stillListed = try fixture.client.list().contains { $0.paneID == paneID }
            if stillListed { Thread.sleep(forTimeInterval: 0.01) }
        }
        XCTAssertFalse(stillListed, "terminate means over — superd must not still be holding it")

        let log = Log()
        let replacement = try spawn(fixture, service: "test-terminate", port: 41237, log: log)
        defer { replacement.terminate() }
        XCTAssertFalse(replacement.adopted, "the name is free again, so this is a real spawn")
        XCTAssertTrue(log.waitFor("listening on port 41237"), "\(log.all)")
    }

    /// A service that exits on its own (crash, bad flags) must flip `isRunning`, because that is
    /// the manager's only cue to respawn on the next `ensure`.
    func testAServiceThatDiesOnItsOwnStopsReportingItselfRunning() throws {
        let fixture = try SuperdFixture()
        let handle = try SupervisedServiceProcess.spawnOrAdopt(
            service: "test-crash",
            binary: "/bin/sh",
            arguments: ["-c", "printf 'starting\\n'; exit 3"],
            environment: ["PATH": "/usr/bin:/bin"],
            supervisor: fixture.client,
            onLogLine: { _ in },
        )
        defer { handle.terminate() }

        let deadline = Date().addingTimeInterval(10)
        while handle.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertFalse(handle.isRunning, "the stream ended, so the next ensure must respawn")
    }

    /// A survivor whose ring no longer reaches its announce line is RESTARTED, not adopted.
    ///
    /// Adoption re-learns the port by replaying the ring from offset 0, and that is the only copy
    /// of the number: there is no state file. A service that has since written more than the ring
    /// holds — an editor's hours of chatter — leaves the manager with a live handle and no port.
    /// `isRunning` says true, so `ensure` never respawns, and the panel says `starting` for the
    /// rest of the daemon's life with nothing in the log to explain it.
    func testAServiceWhoseRingLostTheAnnounceLineIsRestartedRatherThanAdopted() throws {
        let fixture = try SuperdFixture()
        // 6 MiB past the announce line, against superd's 4 MiB ring: the line is provably evicted
        // rather than probably. It arrives as one enormous unterminated "line", which the assembler
        // discards, so `FLOODED` is the marker that says the ring has really rolled.
        let flood = "printf 'listening on port 41240\\n'; "
            + "dd if=/dev/zero bs=65536 count=96 2>/dev/null | tr '\\0' 'x'; "
            + "printf '\\nFLOODED\\n'; sleep 30"
        let firstLog = Log()
        let original = try SupervisedServiceProcess.spawnOrAdopt(
            service: "test-lossy",
            binary: "/bin/sh",
            arguments: ["-c", flood],
            environment: ["PATH": "/usr/bin:/bin"],
            supervisor: fixture.client,
            onLogLine: { firstLog.record($0) },
        )
        XCTAssertTrue(firstLog.waitFor("listening on port 41240"), "\(firstLog.all)")
        XCTAssertTrue(firstLog.waitFor("FLOODED", timeout: 30), "the flood must finish: \(firstLog.all)")
        original.relinquish()

        let notes = Log()
        let secondLog = Log()
        let successor = try SupervisedServiceProcess.spawnOrAdopt(
            service: "test-lossy",
            binary: announceThenIdle(41241).binary,
            arguments: announceThenIdle(41241).arguments,
            environment: ["PATH": "/usr/bin:/bin"],
            supervisor: fixture.client,
            onLogLine: { secondLog.record($0) },
            onLog: { notes.record($0) },
        )
        defer { successor.terminate() }

        XCTAssertFalse(
            successor.adopted,
            "a handle whose port can never be re-learned is worse than a few seconds of boot",
        )
        XCTAssertTrue(
            notes.all.contains { $0.contains("no longer reaches the announce line") },
            "and the restart must say why, or it reads as an unexplained respawn: \(notes.all)",
        )
        XCTAssertTrue(secondLog.waitFor("listening on port 41241"), "\(secondLog.all)")
    }

    /// EVERY service hears the supervisor connection drop, not just the one registered last.
    ///
    /// superd holds the only master fd for a panel backend, so superd dying takes the child with
    /// it — and the `exited` notice would have travelled the connection that just died. The handles
    /// share one client, so a single `onDisconnect` PROPERTY meant the second service silently
    /// replaced the first's callback: code-server would sit there reporting itself healthy forever
    /// while its process was long gone.
    func testEveryServiceHearsTheSupervisorConnectionDrop() throws {
        let fixture = try SuperdFixture()
        let first = try spawn(fixture, service: "test-drop-a", port: 41242, log: Log())
        let second = try spawn(fixture, service: "test-drop-b", port: 41243, log: Log())
        XCTAssertTrue(first.isRunning)
        XCTAssertTrue(second.isRunning)

        fixture.killDaemon()

        let deadline = Date().addingTimeInterval(5)
        while first.isRunning || second.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertFalse(first.isRunning, "the FIRST service must hear it too — that is the regression")
        XCTAssertFalse(second.isRunning)
    }

    /// The pane id is `service:<name>` and never a UUID — that keeps these out of
    /// `HostServer.adoptSurvivingPanes()`, which parses one and leaves anything else running.
    func testTheServicePaneIDIsStableAndNotAUUID() {
        XCTAssertEqual(SupervisedServiceProcess.paneID(for: "code-server"), "service:code-server")
        XCTAssertNil(UUID(uuidString: SupervisedServiceProcess.paneID(for: "code-server")))
    }
}
