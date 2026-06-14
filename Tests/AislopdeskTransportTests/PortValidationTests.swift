import XCTest
@testable import AislopdeskTransport

/// R16 HOSTVIEW-1 regression: the host port field accepted negative / out-of-range values that were
/// silently coerced (`-5 → 0`, `99999 → 65535`) and persisted, desyncing the displayed port from the
/// actually-bound one. The pure validator rejects them so the UI can disable Start instead.
final class PortValidationTests: XCTestCase {
    func testIsValid() {
        XCTAssertFalse(PortValidation.isValid(-5))
        XCTAssertFalse(PortValidation.isValid(-1))
        XCTAssertTrue(PortValidation.isValid(0), "0 = OS-assigned, allowed")
        XCTAssertTrue(PortValidation.isValid(7779))
        XCTAssertTrue(PortValidation.isValid(65535))
        XCTAssertFalse(PortValidation.isValid(65536))
        XCTAssertFalse(PortValidation.isValid(99999))
    }

    func testPortRejectsOutOfRangeInsteadOfCoercing() {
        XCTAssertNil(PortValidation.port(-5), "negative must be rejected, NOT coerced to 0")
        XCTAssertNil(PortValidation.port(65536), "over-range must be rejected, NOT clamped to 65535")
        XCTAssertNil(PortValidation.port(99999))
        XCTAssertEqual(PortValidation.port(0), 0)
        XCTAssertEqual(PortValidation.port(7779), 7779)
        XCTAssertEqual(PortValidation.port(65535), 65535)
    }

    func testClampedNormalizes() {
        XCTAssertEqual(PortValidation.clamped(-5), 0)
        XCTAssertEqual(PortValidation.clamped(-1), 0)
        XCTAssertEqual(PortValidation.clamped(99999), 65535)
        XCTAssertEqual(PortValidation.clamped(65536), 65535)
        XCTAssertEqual(PortValidation.clamped(0), 0)
        XCTAssertEqual(PortValidation.clamped(7779), 7779)
    }
}
