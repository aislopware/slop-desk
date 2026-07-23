// RailRowReadoutTests — pins the row's readout precedence ladder (question > scent > working label >
// final line > error line > running command > NOTHING — a settled row is its title alone), the
// title-echo gate on the command-shaped rungs, the error-line assembly, the header's act-now tally,
// and the agent-session classification. Headless VALUE assertions over the pure resolvers.

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
            doneLine: "Done", errorLine: "make",
        )
        XCTAssertEqual(line, "Allow edit to Config.swift?")
    }

    /// The inspector scent outranks the wire-27 label fallback while working.
    func testScentBeatsWorkingLabel() {
        let line = RailRowReadout.resolve(
            question: nil, scent: "3/5 · Editing TokenRefresh.swift", workingLabel: "Wiring rotation",
            doneLine: nil, errorLine: nil,
        )
        XCTAssertEqual(line, "3/5 · Editing TokenRefresh.swift")
    }

    /// Feed cold: the last assistant line carries the readout.
    func testWorkingLabelFallback() {
        let line = RailRowReadout.resolve(
            question: nil, scent: nil, workingLabel: "Wiring refresh-token rotation",
            doneLine: nil, errorLine: nil,
        )
        XCTAssertEqual(line, "Wiring refresh-token rotation")
    }

    /// Done-unseen: the agent's final line — read the result without focusing the tab.
    func testDoneLineBeatsErrorLine() {
        let line = RailRowReadout.resolve(
            question: nil, scent: nil, workingLabel: nil,
            doneLine: "All 34 tests pass, pushed", errorLine: "npm test",
        )
        XCTAssertEqual(line, "All 34 tests pass, pushed")
    }

    /// Error: the failing-command line (the badge's `!<code>` carries the number), outranking the
    /// running command.
    func testErrorLineBeatsCommandLine() {
        let line = RailRowReadout.resolve(
            question: nil, scent: nil, workingLabel: nil,
            doneLine: nil, errorLine: "npm test", commandLine: "make check",
        )
        XCTAssertEqual(line, "npm test")
    }

    /// The RUNNING command is the floor — a busy shell's row says what it is doing.
    func testCommandLineIsTheFloor() {
        let line = RailRowReadout.resolve(
            question: nil, scent: nil, workingLabel: nil,
            doneLine: nil, errorLine: nil, commandLine: "make check",
        )
        XCTAssertEqual(line, "make check")
    }

    /// Nothing live: `nil` — the row shows its title alone; there is no filler rung and no placeholder.
    func testSettledRowResolvesNothing() {
        XCTAssertNil(RailRowReadout.resolve(
            question: nil, scent: nil, workingLabel: nil,
            doneLine: nil, errorLine: nil, commandLine: nil, title: "api",
        ))
    }

    // MARK: - The title-echo gate

    /// A command-shaped line that only repeats the title is dropped: equal, the command extending the
    /// title word (`npm` → `npm test`), or the title extending the command — case-insensitive.
    func testCommandEchoingTitleIsDropped() {
        XCTAssertNil(RailRowReadout.resolve(
            question: nil, scent: nil, workingLabel: nil,
            doneLine: nil, errorLine: nil, commandLine: "make check", title: "make check",
        ))
        XCTAssertNil(RailRowReadout.resolve(
            question: nil, scent: nil, workingLabel: nil,
            doneLine: nil, errorLine: nil, commandLine: "npm test", title: "npm",
        ))
        XCTAssertNil(RailRowReadout.resolve(
            question: nil, scent: nil, workingLabel: nil,
            doneLine: nil, errorLine: "Make Check", commandLine: nil, title: "make check",
        ))
    }

    /// A command that genuinely differs from the title (a folder-titled row running a build) shows.
    func testCommandDifferingFromTitleShows() {
        let line = RailRowReadout.resolve(
            question: nil, scent: nil, workingLabel: nil,
            doneLine: nil, errorLine: nil, commandLine: "npm test", title: "SlopDeskClientUI",
        )
        XCTAssertEqual(line, "npm test")
    }

    /// The echo gate is WORD-bounded (`api` never swallows `apitool run`) and never touches the
    /// prose rungs — a question quoting the title is still news.
    func testEchoGateIsWordBoundedAndProseExempt() {
        XCTAssertFalse(RailRowReadout.echoesTitle("apitool run", title: "api"))
        XCTAssertTrue(RailRowReadout.echoesTitle("npm test", title: "npm"))
        XCTAssertTrue(RailRowReadout.echoesTitle("npm", title: "npm test"))
        XCTAssertFalse(RailRowReadout.echoesTitle("", title: "npm"))
        let question = RailRowReadout.resolve(
            question: "make check", scent: nil, workingLabel: nil,
            doneLine: nil, errorLine: nil, title: "make check",
        )
        XCTAssertEqual(question, "make check")
    }

    // MARK: - The ASCII spinner cadence

    /// Frames advance one per beat off the wall clock and wrap — a pure function of the date, so a
    /// re-render can never skip or reset a cycle, and every spinning row reads the same frame.
    func testSpinnerFrameAdvancesPerBeatAndWraps() {
        let frames = AsciiStatusBadge.agentFrames
        let beat = AsciiStatusBadge.agentBeat
        let epoch = Date(timeIntervalSinceReferenceDate: 0)
        XCTAssertEqual(AsciiStatusBadge.frame(at: epoch, frames: frames, beat: beat), frames[0])
        XCTAssertEqual(
            AsciiStatusBadge.frame(at: epoch.addingTimeInterval(beat * 3), frames: frames, beat: beat),
            frames[3],
        )
        XCTAssertEqual(
            AsciiStatusBadge.frame(
                at: epoch.addingTimeInterval(beat * Double(frames.count)), frames: frames, beat: beat,
            ),
            frames[0],
        )
        XCTAssertEqual(AsciiStatusBadge.frame(at: epoch, frames: [], beat: beat), "")
    }

    // MARK: - The header's act-now tally

    /// The tally splits by WHY: `?` counts blocked questions, `!` counts failures; every other badge
    /// (spinners, finishes, privilege markers, none) is not attention data.
    func testAttentionCountsSplitByBadge() {
        let counts = SidebarSectionHeaderRow.attentionCounts([
            .awaitingInput, .error, .awaitingInput, .running, .commandBusy, .completed, .sudo, nil,
        ])
        XCTAssertEqual(counts.questions, 2)
        XCTAssertEqual(counts.failures, 1)
        let quiet = SidebarSectionHeaderRow.attentionCounts([.running, nil])
        XCTAssertEqual(quiet.questions, 0)
        XCTAssertEqual(quiet.failures, 0)
    }

    /// The tally's VoiceOver reading spells out only the non-zero classes.
    func testAttentionLabelSpellsNonZeroClasses() {
        XCTAssertEqual(
            SidebarSectionHeaderRow.attentionLabel(questions: 2, failures: 1),
            "2 waiting for input, 1 failed",
        )
        XCTAssertEqual(SidebarSectionHeaderRow.attentionLabel(questions: 0, failures: 3), "3 failed")
        XCTAssertEqual(SidebarSectionHeaderRow.attentionLabel(questions: 1, failures: 0), "1 waiting for input")
    }

    // MARK: - The two-line header's non-repo place line

    /// The header's line-2 fallback: the project's `~`-abbreviated PARENT path — where it lives —
    /// absent for keyless/root-level keys where there is nothing above the name worth printing.
    func testHeaderParentPlace() {
        XCTAssertEqual(
            SidebarSectionHeaderRow.parentPlace(of: "/Users/abner/Workplace/slop-desk"), "~/Workplace",
        )
        XCTAssertEqual(SidebarSectionHeaderRow.parentPlace(of: "/Users/abner/api"), "~")
        XCTAssertEqual(SidebarSectionHeaderRow.parentPlace(of: "/opt/build/repo/"), "/opt/build")
        XCTAssertNil(SidebarSectionHeaderRow.parentPlace(of: "/tmp"))
        XCTAssertNil(SidebarSectionHeaderRow.parentPlace(of: nil))
        XCTAssertNil(SidebarSectionHeaderRow.parentPlace(of: "relative/path"))
    }

    // MARK: - The error line

    /// The error readout is the failing COMMAND alone — the exit code rides the badge's `!<code>`
    /// reading, so the pair never repeats a number. No failure evidence (nil code) or no command →
    /// `nil` (the badge stands alone; the row stays single-line).
    func testErrorLineComposition() {
        XCTAssertEqual(RailRowReadout.errorLine(exitCode: 137, commandText: "npm test"), "npm test")
        XCTAssertEqual(RailRowReadout.errorLine(exitCode: 137, commandText: " npm test\n"), "npm test")
        XCTAssertNil(RailRowReadout.errorLine(exitCode: 1, commandText: "  "))
        XCTAssertNil(RailRowReadout.errorLine(exitCode: 1, commandText: nil))
        XCTAssertNil(RailRowReadout.errorLine(exitCode: nil, commandText: "npm test"))
    }

    /// The badge's error reading: `!` fused with the exit code; bare `!` without one, and an
    /// out-of-band code (>4 characters as text) degrades to the bare `!` rather than widening the row.
    func testErrorReadingFusesBangAndCode() {
        XCTAssertEqual(AsciiStatusBadge.errorReading(exitCode: 137), "!137")
        XCTAssertEqual(AsciiStatusBadge.errorReading(exitCode: 1), "!1")
        XCTAssertEqual(AsciiStatusBadge.errorReading(exitCode: -11), "!-11")
        XCTAssertEqual(AsciiStatusBadge.errorReading(exitCode: nil), "!")
        XCTAssertEqual(AsciiStatusBadge.errorReading(exitCode: 100_000), "!")
    }

    // MARK: - Agent-session classification

    /// ANY agent-status verdict makes a session — `.idle` included: an agent resting at its prompt is
    /// still a session, so the classification holds instead of breathing between turns.
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

    /// Plain shells and ordinary programs are NOT sessions.
    func testShellsAndCommandsAreNotSessions() {
        XCTAssertFalse(RailRowsBuilder.isAgentSession(status: .none, processLabel: nil))
        XCTAssertFalse(RailRowsBuilder.isAgentSession(status: .none, processLabel: "zsh"))
        XCTAssertFalse(RailRowsBuilder.isAgentSession(status: .none, processLabel: "-zsh"))
        XCTAssertFalse(RailRowsBuilder.isAgentSession(status: .none, processLabel: "make"))
        XCTAssertFalse(RailRowsBuilder.isAgentSession(status: .none, processLabel: "vim"))
    }
}
