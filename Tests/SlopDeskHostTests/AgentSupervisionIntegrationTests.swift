import Foundation
import SlopDeskAgentDetect
import XCTest
@testable import SlopDeskHost

/// Integration test — drives a REAL standalone PTY pane through `HostServer`
/// (PTYs are allowed in tests; only SCStream/VT/Metal/Ghostty/NSWindow are forbidden) to prove
/// the cross-pane plumbing end-to-end without a socket:
///   - a `report` transition fans the server-level `agent_status_changed` observer,
///   - `listPanesForControl()` surfaces the reported per-pane state,
///   - `spawnStandalonePane` injects the self-orientation env sentinel.
///
/// These fail without an `onAgentStatusChanged` hook, a server-level observer registry, a
/// `state` on `PaneInfo`, or a `SLOPDESK_CTL` sentinel.
final class AgentSupervisionIntegrationTests: XCTestCase {
    /// A report transition on a live pane invokes a registered cross-pane observer with the pane's
    /// id and the mapped supervision state.
    func testReportFansCrossPaneObserver() async throws {
        let server = HostServer(port: 0)
        defer { Task { await server.stop() } }

        let paneId = try await server.spawnStandalonePane(
            cmd: nil, cwd: nil, env: nil, rows: 24, cols: 80,
        )

        // Register a cross-pane observer and capture the first transition for THIS pane.
        final class Box: @unchecked Sendable {
            private let lock = NSLock()
            private var _hit: (paneId: String, state: String)?
            func set(_ pid: String, _ state: String) {
                lock.lock()
                defer { lock.unlock() }
                if _hit == nil { _hit = (pid, state) }
            }

            var hit: (paneId: String, state: String)? {
                lock.lock()
                defer { lock.unlock() }
                return _hit
            }
        }
        let box = Box()
        let obsID = UUID()
        server.registerAgentStatusObserver(id: obsID) { pid, state, _, _ in box.set(pid, state) }
        defer { server.removeAgentStatusObserver(id: obsID) }

        guard let session = server.lookupPaneForControl(paneId: paneId) else {
            XCTFail("spawned pane not found")
            return
        }
        // Self-report "working" → an authoritative transition (none → working) must fan out.
        session.reportAgentStatusForControl(state: "working", message: nil)

        // The fan-out runs synchronously on the report call's thread, but allow a brief poll for
        // robustness against any scheduling.
        for _ in 0..<40 where box.hit == nil {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let hit = box.hit
        XCTAssertEqual(hit?.paneId, paneId, "the fan-out carries the reporting pane's id")
        XCTAssertEqual(hit?.state, "working", "none → working transition fanned as 'working'")
    }

    /// `listPanesForControl()` reflects a reported state on the matching pane.
    func testListPanesReflectsReportedState() async throws {
        let server = HostServer(port: 0)
        defer { Task { await server.stop() } }

        let paneId = try await server.spawnStandalonePane(
            cmd: nil, cwd: nil, env: nil, rows: 24, cols: 80,
        )
        guard let session = server.lookupPaneForControl(paneId: paneId) else {
            XCTFail("pane not found")
            return
        }
        session.reportAgentStatusForControl(state: "blocked", message: "approve?")

        let panes = server.listPanesForControl()
        let mine = panes.first { $0.paneId == paneId }
        XCTAssertEqual(mine?.state, "blocked", "list-panes surfaces the reported supervision state")
    }

    /// `spawnStandalonePane` injects the full self-orientation env sentinel
    /// (`SLOPDESK_CTL=1`, `SLOPDESK_CTL_BIN`, `SLOPDESK_CONTROL_SOCKET`, `SLOPDESK_PANE_ID`)
    /// into the spawned child's environment. Proven by running a child that echoes those vars and
    /// reading the result back through the same scrollback path the `read` verb uses. This fails if
    /// the injection lines at `HostServer.spawnStandalonePane` are removed (the echoed line would be
    /// empty / missing the keys), unlike the constant-equality unit checks which never touch the wiring.
    func testSpawnInjectsSelfOrientationEnv() async throws {
        let socketPath = "/tmp/slopdesk-test-ctl-\(UUID().uuidString).sock"
        let ctlBin = "/tmp/slopdesk-test-ctl-bin-\(UUID().uuidString)"
        let server = HostServer(
            port: 0,
            agentControlSocketPath: socketPath,
            ctlBinaryPath: ctlBin,
        )
        defer { Task { await server.stop() } }

        // A child that prints each sentinel on its own clearly-delimited line, then exits.
        let script = """
        echo "CTL=$SLOPDESK_CTL"
        echo "BIN=$SLOPDESK_CTL_BIN"
        echo "SOCK=$SLOPDESK_CONTROL_SOCKET"
        echo "PANE=$SLOPDESK_PANE_ID"
        """
        let paneId = try await server.spawnStandalonePane(
            cmd: ["/bin/sh", "-c", script], cwd: nil, env: nil, rows: 24, cols: 80,
        )
        guard let session = server.lookupPaneForControl(paneId: paneId) else {
            XCTFail("spawned pane not found")
            return
        }

        // Poll the scrollback (the child's stdout flows into the ReplayBuffer) until all four
        // sentinels have landed or a generous deadline elapses.
        var text = ""
        for _ in 0..<100 {
            text = session.scrollbackTextForControl(ansiStrip: true)
            if text.contains("CTL=1"), text.contains("PANE=\(paneId)") { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertTrue(text.contains("CTL=1"), "SLOPDESK_CTL=1 injected; got:\n\(text)")
        XCTAssertTrue(text.contains("BIN=\(ctlBin)"), "SLOPDESK_CTL_BIN injected; got:\n\(text)")
        XCTAssertTrue(text.contains("SOCK=\(socketPath)"), "SLOPDESK_CONTROL_SOCKET injected; got:\n\(text)")
        XCTAssertTrue(text.contains("PANE=\(paneId)"), "SLOPDESK_PANE_ID == the returned paneId; got:\n\(text)")
    }

    /// Tearing down a pane that is currently `.working` must fan a final non-working agent status
    /// for that pane, so a `.working`-tracking observer (the `slopdesk-hostd` prevent-sleep driver)
    /// clears the dead paneId and releases its `IOPMAssertion`. This models the driver's exact
    /// working-set accounting and asserts teardown empties it — a leaked assertion otherwise keeps
    /// the Mac awake forever. Fails if `killPaneForControl` (and the `removeMuxSession` / child-exit
    /// teardown paths) fan nothing: the working report would be the last event, so the set would
    /// keep the closed pane forever.
    func testTeardownOfWorkingPaneReleasesPreventSleepTracking() async throws {
        let server = HostServer(port: 0)
        defer { Task { await server.stop() } }

        let paneId = try await server.spawnStandalonePane(
            cmd: nil, cwd: nil, env: nil, rows: 24, cols: 80,
        )

        // A faithful mirror of the daemon's PreventSleepDriver: insert on "working", remove on anything
        // else; `anyWorking` is what gates the IOPMAssertion (assert iff non-empty).
        final class WorkingSet: @unchecked Sendable {
            private let lock = NSLock()
            private var working: Set<String> = []
            func note(_ paneId: String, _ state: String) {
                lock.lock()
                defer { lock.unlock() }
                if state == "working" { working.insert(paneId) } else { working.remove(paneId) }
            }

            func contains(_ paneId: String) -> Bool {
                lock.lock()
                defer { lock.unlock() }
                return working.contains(paneId)
            }

            var anyWorking: Bool {
                lock.lock()
                defer { lock.unlock() }
                return !working.isEmpty
            }
        }
        let set = WorkingSet()
        let obsID = UUID()
        server.registerAgentStatusObserver(id: obsID) { pid, state, _, _ in set.note(pid, state) }
        defer { server.removeAgentStatusObserver(id: obsID) }

        guard let session = server.lookupPaneForControl(paneId: paneId) else {
            XCTFail("spawned pane not found")
            return
        }
        // The agent enters a turn → the driver would now hold the assertion.
        session.reportAgentStatusForControl(state: "working", message: nil)
        for _ in 0..<40 where !set.contains(paneId) { try? await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertTrue(set.contains(paneId), "precondition: the working pane is tracked (assertion held)")

        // Close the pane WHILE it is working (tab close / link drop / ctl kill all reach the same fan).
        XCTAssertTrue(server.killPaneForControl(paneId: paneId), "the working pane is found + killed")

        // The teardown fan must clear the pane → the working set empties → the assertion releases.
        for _ in 0..<40 where set.contains(paneId) { try? await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertFalse(
            set.contains(paneId),
            "teardown fans a final non-working status; the dead pane is pruned from the working set",
        )
        XCTAssertFalse(set.anyWorking, "no pane remains working ⇒ the prevent-sleep IOPMAssertion releases")
    }

    /// A freshly-spawned pane reports a state in the closed supervision set (a live pane with no
    /// claude → "idle"), never an enum case name or empty string.
    func testFreshPaneStateIsInClosedSet() async throws {
        let server = HostServer(port: 0)
        defer { Task { await server.stop() } }
        let paneId = try await server.spawnStandalonePane(
            cmd: nil, cwd: nil, env: nil, rows: 24, cols: 80,
        )
        let panes = server.listPanesForControl()
        let mine = panes.first { $0.paneId == paneId }
        XCTAssertNotNil(mine)
        XCTAssertTrue(
            AgentControlState.isValid(mine?.state ?? ""),
            "fresh pane state must be a valid supervision state",
        )
    }
}
