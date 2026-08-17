// AndroidLogLineTests — gone; what is left is the FILTER MENU.
//
// The grammar's cases live in `rust/slopdesk-devicelog/src/logcat.rs`, including the pid-width
// regression this file existed for: `logcat` right-aligns the pid into a fixed-width field, so
// `( 1234):` splits the header across two whitespace-delimited tokens while `(12345):` closes inside
// the first one, and a parser that handles only the narrow one silently drops the entire message of
// every wide-pid line. The marshalling is ``DeviceLogLineTests``.

#if os(macOS)
import XCTest
@testable import SlopDeskDevicePanels

final class AndroidLogLevelTests: XCTestCase {
    func testTheLevelSpecIsAClosedSetOfLogcatsOwnLetters() {
        // The letter is interpolated into `*:<level>` and reaches an argument vector; `logcat`
        // treats an unparsable filter spec as a fatal error, which reads as a console that connects
        // and immediately dies.
        XCTAssertEqual(AndroidLogLevel.allCases.map(\.rawValue), ["V", "D", "I", "W", "E"])
        XCTAssertEqual(AndroidLogLevel.warning.title, "Warning")
    }
}
#endif
