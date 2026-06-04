import XCTest
@testable import RworkVideoProtocol

/// Pure parse test for the `RWORK_VIDEO_KEEPALIVE` gate (CONCURRENCY-HOST-1 crash-without-bye
/// reaper), mirroring the project's `*GateTests` convention (`StaticIDRGateTests`, the mux gate's
/// off-path test). The OFF-path byte-identity argument hinges on this parse returning false for
/// unset/garbage, so it must be pinned. No socket/timer — safe under
/// `swift test --filter KeepaliveGateTests`.
final class KeepaliveGateTests: XCTestCase {
    func testUnsetIsOff() {
        XCTAssertFalse(KeepaliveGate.enabledFromEnvironment([:]))
    }

    func testTruthyValuesAreOn() {
        for v in ["1", "true", "yes", "on", "TRUE", "Yes", "On", "YES"] {
            XCTAssertTrue(KeepaliveGate.enabledFromEnvironment(["RWORK_VIDEO_KEEPALIVE": v]),
                          "\(v) should enable the gate")
        }
    }

    func testFalsyAndGarbageAreOff() {
        for v in ["0", "off", "false", "no", "", "2", "onish", "enable"] {
            XCTAssertFalse(KeepaliveGate.enabledFromEnvironment(["RWORK_VIDEO_KEEPALIVE": v]),
                           "\(v) should NOT enable the gate")
        }
    }

    func testIgnoresUnrelatedKeys() {
        XCTAssertFalse(KeepaliveGate.enabledFromEnvironment(["RWORK_VIDEO_MUX": "1",
                                                             "RWORK_VIDEO_RESIZE": "on"]))
    }
}
