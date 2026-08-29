// SimulatorLogLineTests — gone; what is left is the ENVELOPE and the filter menu.
//
// The grammar's cases live in `rust/slopdesk-devicelog/src/unified.rs` — the compact split, the
// process losing its `[pid:tid]`, the bracket-less kernel emitter, the whole severity alphabet, and
// the banners that are not log lines at all. The marshalling is ``DeviceLogLineTests``.
//
// What stays is what is the SIMULATOR SERVER's rather than the log's: the batch it wraps lines in
// — whose grammar has descended to `slopdesk_devicepanel::sim_log`, leaving one crossing test here
// — and the levels its `log stream` child accepts, which are a menu and stay.

#if os(macOS)
import XCTest
@testable import SlopDeskDevicePanels

final class SimulatorLogMessageTests: XCTestCase {
    // The GRAMMAR is `slopdesk_devicepanel::sim_log` and is pinned there — which `type` words this
    // build has a case for, what an unrecognised one costs, and that a malformed entry costs its
    // own line rather than the batch. What is left here is the MARSHALLING: that the three cases
    // survive the crossing as themselves, which is the one claim neither side can make alone.
    func testEachEnvelopeCrossesAsItself() {
        // `started` is its own case because it is the only signal separating a quiet device from a
        // dead one, and it must not arrive as the empty batch.
        XCTAssertEqual(SimulatorLogMessage.decode(#"{"type":"log_started"}"#), .started)
        XCTAssertEqual(
            SimulatorLogMessage.decode(#"{"type":"log","lines":["a","b"]}"#), .lines(["a", "b"]),
        )
        // The server batches on a timer, so a tick with nothing to say is a real message — and the
        // count rides inside the delivery so it cannot be read as the refusal.
        XCTAssertEqual(SimulatorLogMessage.decode(#"{"type":"log"}"#), .lines([]))
        // A refusal costs the panel that MESSAGE and never the socket.
        XCTAssertEqual(SimulatorLogMessage.decode(#"{"type":"heartbeat"}"#), .unknown)
        XCTAssertEqual(SimulatorLogMessage.decode("not json"), .unknown)
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
