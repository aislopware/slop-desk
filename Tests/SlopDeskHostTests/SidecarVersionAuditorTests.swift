import Foundation
import XCTest
@testable import SlopDeskHost

/// The auditor: what it reports, and the ONE thing it is allowed to do about a mismatch.
///
/// Everything that touches a live daemon is a closure here, which is the whole reason the type is
/// shaped this way — the decision is testable without a process tree.
final class SidecarVersionAuditorTests: XCTestCase {
    /// Records what a subject's restart closure did, across the auditor's `await`.
    private final class RestartLog: @unchecked Sendable {
        private let lock = NSLock()
        private var tools: [String] = []

        func record(_ tool: String) {
            lock.lock()
            tools.append(tool)
            lock.unlock()
        }

        var restarted: [String] {
            lock.lock()
            defer { lock.unlock() }
            return tools
        }
    }

    private func subject(
        _ tool: String, running: String?, installed: String?, log: RestartLog?,
    ) -> SidecarVersionAuditor.Subject {
        var restart: (@Sendable () async -> Void)?
        if let log {
            restart = { @Sendable in log.record(tool) }
        }
        return SidecarVersionAuditor.Subject(
            tool: tool,
            running: { running },
            installed: { installed },
            restart: restart,
        )
    }

    func testAStaleSidecarHostdOwnsIsRestartedAndTheRestAreOnlyReported() async {
        let log = RestartLog()
        let auditor = SidecarVersionAuditor(subjects: [
            subject("slopdesk-superd", running: "0.1.0", installed: "0.2.0", log: log),
            subject("slopdesk-screend", running: "0.1.0", installed: "0.2.0", log: log),
            subject("slopdesk-dropd", running: "0.1.0", installed: "0.2.0", log: log),
            subject("slopdesk-inspectord", running: "0.1.0", installed: "0.1.0", log: log),
        ])
        var lines: [String] = []
        let reports = await auditor.run { lines.append($0) }

        XCTAssertEqual(log.restarted, ["slopdesk-dropd"])
        XCTAssertEqual(reports.count, 4)
        XCTAssertEqual(lines.count, 4, "every sidecar is reported, restarted or not")
        XCTAssertEqual(reports.map(\.tool), [
            "slopdesk-superd", "slopdesk-screend", "slopdesk-dropd", "slopdesk-inspectord",
        ], "the order is the subjects' — a report whose order shifts is a report nobody diffs")
    }

    /// The policy says what MAY be done; the closure says what this caller CAN do. A manager that
    /// never came up has nothing to restart, and that must not become a crash or a claim.
    func testAnAutomaticSidecarWithNothingToRestartIsStillReported() async {
        let auditor = SidecarVersionAuditor(subjects: [
            subject("slopdesk-dropd", running: "0.1.0", installed: "0.2.0", log: nil),
        ])
        var lines: [String] = []
        let reports = await auditor.run { lines.append($0) }
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(reports[0].restartable)
    }

    /// A daemon that is down reads `unknown` and is left alone — the audit must never be the thing
    /// that takes a host down.
    func testADaemonThatIsDownIsNeitherRestartedNorTreatedAsCurrent() async {
        let log = RestartLog()
        let auditor = SidecarVersionAuditor(subjects: [
            subject("slopdesk-dropd", running: nil, installed: "0.2.0", log: log),
        ])
        let reports = await auditor.run { _ in }
        XCTAssertEqual(log.restarted, [])
        guard case .unknown = reports[0].verdict else {
            XCTFail("a daemon that did not answer is unknown")
            return
        }
    }

    func testACurrentSidecarIsNeverRestarted() async {
        let log = RestartLog()
        let auditor = SidecarVersionAuditor(subjects: [
            subject("slopdesk-dropd", running: "0.2.0", installed: "0.2.0", log: log),
            subject("slopdesk-androidd", running: "0.2.0", installed: "0.2.0", log: log),
        ])
        _ = await auditor.run { _ in }
        XCTAssertEqual(log.restarted, [])
    }
}
