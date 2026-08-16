import Foundation
import SlopDeskSupervisor
import XCTest
@testable import SlopDeskHost

/// The out-of-band sniff, end to end through a real `slopdesk-superd`.
///
/// hostd no longer runs an OSC state machine over every byte of every pane: superd's pump does the
/// scan, because it already holds the bytes before anyone else sees one, and hostd receives the
/// ANSWER on a `0x04` frame that rides immediately ahead of the chunk it describes
/// (`rust/slopdesk-superd/src/sniffer.rs`, `docs/51` §6.4).
///
/// Everything below drives a real daemon and a real shell. What no unit test can cover, and what
/// these exist for, is the SEAM: that the events cross the socket at all, decode into the vocabulary
/// hostd folds, and arrive paired with their own bytes.
///
/// Skips by name when superd is not built (`make superd`, or `make test`, which does).
final class SupervisedSniffTests: XCTestCase {
    private var superd: SuperdFixture?
    /// One collector per pane, kept alive for the test — a `PaneOutput` unsubscribes on `deinit`.
    private var collectors: [PaneOutput] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        superd = try SuperdFixture()
    }

    override func tearDown() {
        collectors.removeAll()
        superd = nil
        super.tearDown()
    }

    private func spawn(_ script: String, shellIntegration: Bool) throws -> PaneOutput {
        let pty = try PTYProcess(supervisor: XCTUnwrap(superd).client)
        var environment = HostEnvironment.curated()
        environment["TERM"] = "xterm-256color"
        try pty.spawnForTest(
            "/bin/sh",
            arguments: ["-c", script],
            environment: environment,
            shellIntegration: shellIntegration,
        )
        let output = try PaneOutput(pty)
        collectors.append(output)
        return output
    }

    /// The whole path in one assertion: a shell writes an OSC 2, superd's pump finds it in the
    /// chunk it just read, frames it, and hostd decodes it into the title the pane publishes.
    func testATitleWrittenByTheShellArrivesAsASniffedEvent() throws {
        let pane = try spawn("printf '\\033]2;a title\\007'; sleep 1", shellIntegration: true)
        XCTAssertTrue(
            pane.waitForSniffed(timeout: 10) { $0.contains(.title("a title")) },
            "superd must report the title it read — got \(pane.sniffed)",
        )
    }

    /// The pairing, which is the reason the events ride the output stream rather than a channel of
    /// their own: by the time an event is delivered, the bytes it was found in have been handed on.
    /// A title latched ahead of its own chunk would be a title the client is told about before the
    /// escape that set it has been forwarded.
    func testTheEventsArriveWithTheBytesTheyWereFoundIn() throws {
        let pane = try spawn("printf '\\033]2;t\\007marker-after'; sleep 1", shellIntegration: true)
        XCTAssertTrue(
            pane.waitForSniffed(timeout: 10) { $0.contains(.title("t")) },
            "the title must arrive — got \(pane.sniffed)",
        )
        XCTAssertTrue(
            pane.text.contains("marker-after"),
            "and the chunk that carried it is already forwarded, bytes untouched",
        )
    }

    /// The gate. A pane that did not ask for shell integration has no prompt machinery and says
    /// nothing out of band, so superd does not scan it — the same bytes produce no events at all,
    /// and a panel backend's stdout never pays for a scan it cannot benefit from.
    func testAPaneThatDidNotAskForShellIntegrationIsNotSniffed() throws {
        let pane = try spawn("printf '\\033]2;unwatched\\007seen'; sleep 1", shellIntegration: false)
        _ = pane.waitFor("seen", timeout: 10)
        // Deliberately after the bytes have arrived: the negative is only meaningful once the chunk
        // that WOULD have produced an event has provably been through the pump.
        XCTAssertTrue(pane.text.contains("seen"), "the bytes still flow — the gate is on the scan")
        XCTAssertEqual(pane.sniffed, [], "an unsniffed pane reports nothing")
    }

    /// The OSC 133 marks the shim emits, as a command status hostd can latch. `D;3` carries the
    /// exit code that answers ctl `list-panes`' `lastExitCode` without a blocks tap.
    func testTheCommandMarksArriveAsAStatusWithItsExitCode() throws {
        let pane = try spawn(
            "printf '\\033]133;C\\007'; printf '\\033]133;D;3\\007'; sleep 1",
            shellIntegration: true,
        )
        XCTAssertTrue(
            pane.waitForSniffed(timeout: 10) { events in
                events.contains(.commandRunning)
                    && events.contains { event in
                        if case let .commandIdle(exitCode, _) = event { return exitCode == 3 }
                        return false
                    }
            },
            "the C→D pair must arrive as running then idle(3) — got \(pane.sniffed)",
        )
    }
}
