import XCTest
@testable import SlopDeskTransport

/// R16 HOSTVIEW-1 regression: the host port field accepted negative / out-of-range values that were
/// silently coerced (`-5 → 0`, `99999 → 65535`) and persisted, desyncing the displayed port from the
/// actually-bound one. The validator rejects them so the UI can disable Start instead.
///
/// The rule itself is `slopdesk-workspace`'s `listen` and is tested there. What these pin is the
/// DOOR: that the face converts `Int` to the crate's `i64` without clipping a value at either end,
/// which is the one thing a face can get wrong on its own.
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

    /// `Int` is 64-bit and the door takes an `i64`, so the extremes must cross as themselves rather
    /// than wrap into the valid range. A face that truncated would answer `true` for `Int.min`.
    func testTheExtremesCrossWithoutWrapping() {
        XCTAssertFalse(PortValidation.isValid(Int.min))
        XCTAssertFalse(PortValidation.isValid(Int.max))
        XCTAssertFalse(PortValidation.isValid(Int(UInt32.max)))
    }
}
