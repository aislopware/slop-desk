// RailRowReadoutTests — pins the row's line-2 precedence ladder (question > scent > working label >
// final line > error line > strayed cwd > nothing), the per-source truncation (prose keeps its head,
// a path keeps both ends), the error-line assembly, and the agent-session classification that holds
// the tall row shell. Headless VALUE assertions over the pure resolvers.

import SlopDeskAgentDetect
import XCTest
@testable import SlopDeskClientUI

final class RailRowReadoutTests: XCTestCase {
    // MARK: - Precedence

    /// The blocked question outranks everything — including a live scent (the agent is stopped; what
    /// it WAS doing no longer matters).
    func testQuestionWins() {
        let line = RailRowReadout.resolve(
            question: "Allow edit to Config.swift?", scent: "3/5 · Editing", workingLabel: "Wiring",
            doneLine: "Done", errorLine: "exit 1 · make", strayedCwd: "packages/api",
        )
        XCTAssertEqual(line, RailRowReadout.Line(text: "Allow edit to Config.swift?", truncation: .tail))
    }

    /// The inspector scent outranks the wire-27 label fallback while working.
    func testScentBeatsWorkingLabel() {
        let line = RailRowReadout.resolve(
            question: nil, scent: "3/5 · Editing TokenRefresh.swift", workingLabel: "Wiring rotation",
            doneLine: nil, errorLine: nil, strayedCwd: nil,
        )
        XCTAssertEqual(line?.text, "3/5 · Editing TokenRefresh.swift")
    }

    /// Feed cold: the last assistant line carries the readout.
    func testWorkingLabelFallback() {
        let line = RailRowReadout.resolve(
            question: nil, scent: nil, workingLabel: "Wiring refresh-token rotation",
            doneLine: nil, errorLine: nil, strayedCwd: "packages/api",
        )
        XCTAssertEqual(line, RailRowReadout.Line(text: "Wiring refresh-token rotation", truncation: .tail))
    }

    /// Done-unseen: the agent's final line — read the result without focusing the tab.
    func testDoneLineBeatsStructuralCwd() {
        let line = RailRowReadout.resolve(
            question: nil, scent: nil, workingLabel: nil,
            doneLine: "All 34 tests pass, pushed", errorLine: nil, strayedCwd: "packages/api",
        )
        XCTAssertEqual(line?.text, "All 34 tests pass, pushed")
        XCTAssertEqual(line?.truncation, .tail)
    }

    /// Error: the `exit N · command` line.
    func testErrorLineBeatsStructuralCwd() {
        let line = RailRowReadout.resolve(
            question: nil, scent: nil, workingLabel: nil,
            doneLine: nil, errorLine: "exit 137 · npm test", strayedCwd: "packages/api",
        )
        XCTAssertEqual(line?.text, "exit 137 · npm test")
    }

    /// The structural strayed-cwd is the LOWEST rung — it returns when the row settles, with the
    /// path-shaped `.middle` truncation (the one non-prose source).
    func testStrayedCwdIsLastAndMiddleTruncated() {
        let line = RailRowReadout.resolve(
            question: nil, scent: nil, workingLabel: nil,
            doneLine: nil, errorLine: nil, strayedCwd: "packages/api",
        )
        XCTAssertEqual(line, RailRowReadout.Line(text: "packages/api", truncation: .middle))
    }

    /// Nothing at all: `nil` — the agent row's reserved blank, never a placeholder.
    func testNothingIsNil() {
        XCTAssertNil(RailRowReadout.resolve(
            question: nil, scent: nil, workingLabel: nil,
            doneLine: nil, errorLine: nil, strayedCwd: nil,
        ))
    }

    // MARK: - The error line

    func testErrorLineComposition() {
        XCTAssertEqual(RailRowReadout.errorLine(exitCode: 137, commandText: "npm test"), "exit 137 · npm test")
        XCTAssertEqual(RailRowReadout.errorLine(exitCode: 1, commandText: "  "), "exit 1")
        XCTAssertEqual(RailRowReadout.errorLine(exitCode: 1, commandText: nil), "exit 1")
        XCTAssertNil(RailRowReadout.errorLine(exitCode: nil, commandText: "npm test"))
    }

    // MARK: - Agent-session classification (the tall-shell rung)

    /// ANY agent-status verdict makes a session — `.idle` included: an agent resting at its prompt is
    /// still a session, so the rung holds instead of breathing between turns.
    func testAnyAgentStatusIsASession() {
        for status in [ClaudeStatus.idle, .working, .done, .needsPermission] {
            XCTAssertTrue(
                RailRowsBuilder.isAgentSession(status: status, processLabel: nil),
                "\(status) is an agent session",
            )
        }
    }

    /// A known agent CLI in the foreground classifies BEFORE any verdict lands (the pre-detector
    /// window); path + login-dash forms are cleaned first.
    func testAgentProcessClassifies() {
        XCTAssertTrue(RailRowsBuilder.isAgentSession(status: .none, processLabel: "claude"))
        XCTAssertTrue(RailRowsBuilder.isAgentSession(status: .none, processLabel: "/usr/local/bin/codex"))
        XCTAssertTrue(RailRowsBuilder.isAgentSession(status: .none, processLabel: "Claude"))
    }

    /// Plain shells and ordinary programs are NOT sessions — their rows keep the compact rung.
    func testShellsAndCommandsAreNotSessions() {
        XCTAssertFalse(RailRowsBuilder.isAgentSession(status: .none, processLabel: nil))
        XCTAssertFalse(RailRowsBuilder.isAgentSession(status: .none, processLabel: "zsh"))
        XCTAssertFalse(RailRowsBuilder.isAgentSession(status: .none, processLabel: "-zsh"))
        XCTAssertFalse(RailRowsBuilder.isAgentSession(status: .none, processLabel: "make"))
        XCTAssertFalse(RailRowsBuilder.isAgentSession(status: .none, processLabel: "vim"))
    }
}
