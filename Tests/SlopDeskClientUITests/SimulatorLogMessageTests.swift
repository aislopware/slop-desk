// SimulatorLogLineTests — gone; what is left is the ENVELOPE and the filter menu.
//
// The grammar's cases live in `rust/slopdesk-devicelog/src/unified.rs` — the compact split, the
// process losing its `[pid:tid]`, the bracket-less kernel emitter, the whole severity alphabet, and
// the banners that are not log lines at all. The marshalling is ``DeviceLogLineTests``.
//
// What stays is what is the SIMULATOR SERVER's rather than the log's: the batch it wraps lines in,
// which is JSON off a socket and therefore still a validate-then-drop this side owns.

#if os(macOS)
import XCTest
@testable import SlopDeskClientUI

final class SimulatorLogMessageTests: XCTestCase {
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
