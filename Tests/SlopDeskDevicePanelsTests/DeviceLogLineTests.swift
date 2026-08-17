// DeviceLogLineTests — the MARSHALLING for both device consoles' parses, not the grammars.
//
// The grammars are `rust/slopdesk-devicelog`: `logcat -v time` in its `logcat` module and
// `log stream --style compact` in its `unified` one. Every behaviour case the two Swift suites used
// to carry was ported there unchanged — the pid-width regression, the tag containing a colon, the
// banner kept verbatim, the whole severity alphabet of each source. Repeating them here would be
// the cross-language mirror fixture the tree forbids: two suites that can only ever agree or be a
// bug.
//
// What is left is what only exists on THIS side of the door and can only fail here:
//
// - the SLICING — the door answers byte offsets into a buffer this side built from a `String`, and
//   an off-by-one there is silent: the row renders, at the right length, with the wrong text;
// - the routing — two doors that must not be swapped, since either answers a record for any line;
// - the severity mapping — a `UInt8` becoming the case the console views ink from.
//
// What each console does with that case is a VIEW decision and is pinned next to the views, in
// `SlopDeskClientUITests/DeviceConsoleInkTests`.

#if os(macOS)
import XCTest
@testable import SlopDeskDevicePanels

final class DeviceLogLineTests: XCTestCase {
    // MARK: The slicing

    /// Every field is cut out of the caller's own buffer at the offset the door named. Distinct
    /// values throughout, so a crossed or shifted span cannot pass by coincidence.
    func testEveryFieldIsCutAtTheOffsetTheDoorNamed() {
        let line = DeviceLogLine.logcat("08-04 13:50:19.565 E/Zygote(12345): boom")
        XCTAssertEqual(line.time, "13:50:19.565")
        XCTAssertEqual(line.name, "Zygote")
        XCTAssertEqual(line.message, "boom")
        XCTAssertEqual(line.severity, .error)
    }

    /// The offsets are BYTE offsets and the buffer is UTF-8, so a multi-byte character anywhere
    /// ahead of a field shifts every later one. Swift's own `String` indices would have hidden this.
    func testAMultiByteCharacterDoesNotShiftTheLaterFields() {
        let line = DeviceLogLine.unified("2026-08-04 13:50:19.565 E Café[1:2] naïve — done")
        XCTAssertEqual(line.name, "Café")
        XCTAssertEqual(line.message, "naïve — done")
    }

    /// An unrecognised line comes back whole, which is the case a wrong span would truncate.
    func testAnUnrecognisedLineComesBackWhole() {
        let banner = "--------- beginning of crash"
        XCTAssertEqual(DeviceLogLine.logcat(banner).message, banner)
        let notice = "getpwuid_r did not find a match for uid 501"
        XCTAssertEqual(DeviceLogLine.unified(notice).message, notice)
    }

    func testAnEmptyLineCrossesAsAnEmptyRow() {
        XCTAssertEqual(DeviceLogLine.logcat(""), DeviceLogLine())
        XCTAssertEqual(DeviceLogLine.unified(""), DeviceLogLine())
    }

    // MARK: The routing

    /// Two doors, and either answers a record for any line — so a console wired to the wrong one
    /// would render rows that look plausible. Each must decline the other's grammar.
    func testEachDoorReadsItsOwnGrammarAndNotTheOthers() {
        let logcat = "08-04 13:50:19.565 E/Zygote(12345): boom"
        XCTAssertEqual(DeviceLogLine.unified(logcat).message, logcat)
        let unified = "2026-08-04 13:50:19.565 Df Poster[1:2] laid out"
        XCTAssertEqual(DeviceLogLine.logcat(unified).message, unified)
    }

    // MARK: The severity mapping

    /// Each door's byte reaches the case the console views switch on. One scale for both, and a
    /// superset of each: `logcat` never answers `.debug` and the unified log never answers
    /// `.warning`, because neither alphabet has the bucket.
    func testEachSeverityByteBecomesItsCase() {
        func logcat(_ letter: String) -> DeviceLogSeverity {
            DeviceLogLine.logcat("08-04 13:50:19.565 \(letter)/Tag( 1): x").severity
        }
        XCTAssertEqual(logcat("F"), .fatal)
        XCTAssertEqual(logcat("E"), .error)
        XCTAssertEqual(logcat("W"), .warning)
        XCTAssertEqual(logcat("I"), .info)
        XCTAssertEqual(logcat("D"), .plain)

        func unified(_ token: String) -> DeviceLogSeverity {
            DeviceLogLine.unified("2026-08-04 13:50:19.565 \(token) p[1:2] x").severity
        }
        XCTAssertEqual(unified("F"), .fatal)
        XCTAssertEqual(unified("E"), .error)
        XCTAssertEqual(unified("I"), .info)
        XCTAssertEqual(unified("Db"), .debug)
        XCTAssertEqual(unified("Df"), .plain)
    }
}
#endif
