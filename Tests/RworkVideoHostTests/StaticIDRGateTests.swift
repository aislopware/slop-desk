import XCTest
@testable import RworkVideoHost

/// PURE env-gate parse for `RWORK_VIDEO_STATICIDR` (VIDEO-HOST-1). Mirrors the mux-gate
/// truthiness vocabulary. No process env mutation — the parse takes an injected dict.
final class StaticIDRGateTests: XCTestCase {
    func testUnsetIsOff() {
        XCTAssertFalse(StaticIDRGate.enabledFromEnvironment([:]))
    }

    func testTruthyValuesAreOn() {
        for v in ["1", "true", "yes", "on", "TRUE", "Yes", "On", "YES"] {
            XCTAssertTrue(StaticIDRGate.enabledFromEnvironment(["RWORK_VIDEO_STATICIDR": v]),
                          "\(v) should be ON")
        }
    }

    func testFalsyAndGarbageAreOff() {
        for v in ["0", "off", "false", "no", "", "2", "enabled", "  ", "onish"] {
            XCTAssertFalse(StaticIDRGate.enabledFromEnvironment(["RWORK_VIDEO_STATICIDR": v]),
                           "\(v) should be OFF")
        }
    }

    func testIgnoresUnrelatedKeys() {
        XCTAssertFalse(StaticIDRGate.enabledFromEnvironment(["RWORK_VIDEO_MUX": "1"]))
    }
}
