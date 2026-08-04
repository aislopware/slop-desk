// SimulatorLogLineTests — the console's parse, which is the one part of the log path that can be
// wrong silently.
//
// A dropped envelope shows as an empty console and gets noticed. A line split at the wrong token
// does not: it renders, it is the right length, and it is simply attributed to the wrong process at
// the wrong severity. Every case here is a real shape taken off a live `log stream --style compact`
// (measured 2026-08-04), including the banners that are not log lines at all.

#if os(macOS)
import XCTest
@testable import SlopDeskClientUI

final class SimulatorLogLineTests: XCTestCase {
    // MARK: The compact grammar

    func testAWellFormedLineSplitsIntoTimeSeverityProcessAndMessage() {
        let line = SimulatorLogLine.parse(
            "2026-08-04 13:50:19.565 Df Unity2025Poster[76037:219b94d] [com.acme:ui] laid out",
        )
        // The DATE is dropped and the time kept: every row in a console opened now carries the same
        // date, so printing it spends a third of a sidebar's width saying nothing.
        XCTAssertEqual(line.time, "13:50:19.565")
        XCTAssertEqual(line.process, "Unity2025Poster")
        XCTAssertEqual(line.message, "[com.acme:ui] laid out")
        // `Df` is default, which is the ordinary case and stays uninked — see the alphabet test.
        XCTAssertEqual(line.severity, .plain)
    }

    func testTheProcessLosesItsPidAndThreadButKeepsItsName() {
        // `[76037:219b94d]` is noise at a sidebar's width, and the name is what anyone scans for.
        let line = SimulatorLogLine.parse("2026-08-04 13:50:19.565 I SpringBoard[112:5f] up")
        XCTAssertEqual(line.process, "SpringBoard")
    }

    func testAnEmitterWithNoBracketKeepsItsWholeToken() {
        // Kernel-side emitters arrive without the pid pair; truncating at a bracket that is not there
        // must leave the name whole rather than empty.
        let line = SimulatorLogLine.parse("2026-08-04 13:50:19.565 E kernel something failed")
        XCTAssertEqual(line.process, "kernel")
        XCTAssertEqual(line.message, "something failed")
    }

    func testTheSeverityAlphabetCollapsesToWhatAConsoleCanInk() {
        // The six tokens counted off ten thousand real compact lines (2026-08-04): Db, Df, E, I, A,
        // F. Coarser than the log's own alphabet on purpose — the question at a glance is "is
        // anything wrong", and six tints answer it worse than three.
        func severity(_ token: String) -> SimulatorLogLine.Severity {
            SimulatorLogLine.parse("2026-08-04 13:50:19.565 \(token) proc[1:2] m").severity
        }
        XCTAssertEqual(severity("F"), .fault)
        XCTAssertEqual(severity("E"), .error)
        XCTAssertEqual(severity("I"), .info)
        XCTAssertEqual(severity("Db"), .debug)
        XCTAssertEqual(severity("A"), .debug)
        // `Df` (default) is the ordinary case and by far the largest share after debug. Inking it
        // would light most of the console and leave the errors no louder than everything else.
        XCTAssertEqual(severity("Df"), .plain)
        // A token the shape accepts but this build has not seen inks as plain rather than guessing.
        XCTAssertEqual(severity("Z"), .plain)
    }

    // MARK: Everything that is not a log line

    func testAServerBannerIsKeptVerbatimRatherThanDropped() {
        // `log stream` prefaces its output with its own notices. Swallowing them makes a console look
        // like it silently lost the first second, which is the failure hardest to diagnose.
        let text = "getpwuid_r did not find a match for uid 501"
        let line = SimulatorLogLine.parse(text)
        XCTAssertEqual(line.message, text)
        XCTAssertEqual(line.time, "")
        XCTAssertEqual(line.process, "")
        XCTAssertEqual(line.severity, .plain)
    }

    func testALineThatOnlyLooksLikeTheGrammarIsNotSplitIntoOne() {
        // Three tokens in the right places, none of them the right shape. Splitting this would
        // attribute a plain sentence to a process called "at".
        let text = "Filtering the log data using \"level\" and more words"
        XCTAssertEqual(SimulatorLogLine.parse(text).message, text)
        // A date-shaped first token is not enough on its own either.
        let almost = "2026-08-04 not-a-time Df proc[1:2] m"
        XCTAssertEqual(SimulatorLogLine.parse(almost).message, almost)
    }

    func testAnEmptyLineSurvivesAsAnEmptyRowRatherThanCrashing() {
        XCTAssertEqual(SimulatorLogLine.parse("").message, "")
    }

    func testAMessageKeepsItsInternalSpacingOnceTheHeaderIsOff() {
        // Only the leading gap after the process token is trimmed. A log line's own alignment is
        // information — a padded table in someone's output must survive the parse.
        let line = SimulatorLogLine.parse("2026-08-04 13:50:19.565 I p[1:2]   a    b")
        XCTAssertEqual(line.message, "a    b")
    }

    // MARK: The envelope

    func testTheStartedEnvelopeIsItsOwnCaseSoAQuietDeviceIsNotADeadOne() {
        XCTAssertEqual(SimulatorLogMessage.decode(#"{"type":"log_started"}"#), .started)
    }

    func testALogEnvelopeCarriesItsBatchAndAnEmptyOneIsStillABatch() {
        XCTAssertEqual(
            SimulatorLogMessage.decode(#"{"type":"log","lines":["a","b"]}"#), .lines(["a", "b"]),
        )
        // The server batches on a timer, so a tick with nothing to say is a real message.
        XCTAssertEqual(SimulatorLogMessage.decode(#"{"type":"log"}"#), .lines([]))
    }

    func testAnythingElseDecodesToUnknownRatherThanThrowing() {
        // Validate-then-drop, the same as every other untrusted payload in this app.
        XCTAssertEqual(SimulatorLogMessage.decode("not json"), .unknown)
        XCTAssertEqual(SimulatorLogMessage.decode("[]"), .unknown)
        XCTAssertEqual(SimulatorLogMessage.decode(#"{"lines":["a"]}"#), .unknown)
        XCTAssertEqual(SimulatorLogMessage.decode(#"{"type":"heartbeat"}"#), .unknown)
        // A `lines` of the wrong element type is not a batch of strings, and must not become one.
        XCTAssertEqual(SimulatorLogMessage.decode(#"{"type":"log","lines":3}"#), .lines([]))
    }

    // MARK: The level set

    func testTheLevelSetIsExactlyWhatTheServersChildAccepts() {
        // Closed on purpose: an invented level still UPGRADES the socket and only dies later when
        // `log stream` refuses it, which reads as a console that connects and never prints.
        XCTAssertEqual(
            SimulatorLogLevel.allCases.map(\.rawValue),
            ["debug", "info", "notice", "error", "fault"],
        )
        // The wire value stays lowercase; the title is display only.
        XCTAssertEqual(SimulatorLogLevel.notice.title, "Notice")
        XCTAssertEqual(SimulatorLogLevel.notice.rawValue, "notice")
    }
}
#endif
