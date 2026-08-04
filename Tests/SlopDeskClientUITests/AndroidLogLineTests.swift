// AndroidLogLineTests — `logcat -v time`, decoded.
//
// The case worth writing a file for is the PID WIDTH. `logcat` right-aligns the pid into a
// fixed-width field, so `( 1234):` carries a leading space and splits the header across two
// whitespace-delimited tokens while `(12345):` closes inside the first one. Both shapes occur on the
// same device within one session, and a parser that handles only the narrow one silently drops the
// entire message of every wide-pid line — a console that looks like it is printing empty rows.

#if os(macOS)
import Foundation
import XCTest
@testable import SlopDeskClientUI

final class AndroidLogLineTests: XCTestCase {
    func testTheOrdinaryLineSplitsIntoTimeTagAndMessage() {
        let line = AndroidLogLine.parse("08-04 13:50:19.565 D/ActivityManager( 1234): started up")
        XCTAssertEqual(line.time, "13:50:19.565")
        XCTAssertEqual(line.tag, "ActivityManager")
        XCTAssertEqual(line.message, "started up")
        XCTAssertEqual(line.severity, .plain)
    }

    func testAWidePidKeepsItsMessage() {
        // The regression this file exists for: with five pid digits the `):` closes the first token
        // and the message lives in the remainder.
        let line = AndroidLogLine.parse("08-04 13:50:19.565 E/Zygote(12345): boom")
        XCTAssertEqual(line.tag, "Zygote")
        XCTAssertEqual(line.message, "boom")
        XCTAssertEqual(line.severity, .error)
    }

    func testATagContainingAColonIsNotCutShort() {
        // The colon is searched for AFTER the bracket, so a tag allowed to contain one does not
        // truncate the header.
        let line = AndroidLogLine.parse("08-04 13:50:19.565 I/Choreographer:x(12345): skipped 30")
        XCTAssertEqual(line.tag, "Choreographer:x")
        XCTAssertEqual(line.message, "skipped 30")
    }

    func testTheMessageKeepsItsOwnColons() {
        let line = AndroidLogLine.parse("08-04 13:50:19.565 W/Net( 999): GET https://x/y: 404")
        XCTAssertEqual(line.message, "GET https://x/y: 404")
        XCTAssertEqual(line.severity, .warning)
    }

    func testTheDateIsDroppedAndTheTimeIsKept() {
        // A console shows the recent past, and the day is the same one in every row of it.
        let line = AndroidLogLine.parse("08-04 13:50:19.565 I/X( 1): hi")
        XCTAssertEqual(line.time, "13:50:19.565")
        XCTAssertFalse(line.time.contains("08-04"))
    }

    // MARK: Severity

    func testEachPriorityLetterLandsInItsBucket() {
        let cases: [(Character, AndroidLogLine.Severity)] = [
            ("F", .fatal),
            // `A` is logcat's ASSERT, which is what a native abort prints: same bucket, because both
            // mean the process is going away.
            ("A", .fatal),
            ("E", .error),
            ("W", .warning),
            ("I", .info),
            ("V", .plain),
        ]
        for (letter, expected) in cases {
            let line = AndroidLogLine.parse("08-04 13:50:19.565 \(letter)/Tag( 1): x")
            XCTAssertEqual(line.severity, expected, "priority \(letter)")
        }
    }

    func testDebugIsDeliberatelyNotInked() {
        // It is the largest share of a busy device's output by a wide margin, so tinting it would
        // light up most of the console and leave the errors no louder than anything else.
        XCTAssertEqual(
            AndroidLogLine.parse("08-04 13:50:19.565 D/Tag( 1): x").severity, .plain,
        )
    }

    // MARK: Everything that is not a log line

    func testALogcatBannerSurvivesVerbatim() {
        // A swallowed banner is a console that looks like it lost the boundary between two runs —
        // precisely the line someone reading a crash is looking for.
        let banner = "--------- beginning of crash"
        let line = AndroidLogLine.parse(banner)
        XCTAssertEqual(line.message, banner)
        XCTAssertEqual(line.severity, .plain)
        XCTAssertTrue(line.tag.isEmpty)
        XCTAssertTrue(line.time.isEmpty)
    }

    func testALineWhoseThirdTokenMerelyStartsWithACapitalIsNotASeverity() {
        // Without the priority check, any prose beginning with `E` would become an error row.
        let line = AndroidLogLine.parse("08-04 13:50:19.565 Everything is fine")
        XCTAssertEqual(line.severity, .plain)
        XCTAssertEqual(line.message, "08-04 13:50:19.565 Everything is fine")
    }

    func testAnEmptyLineIsAnEmptyRowRatherThanACrash() {
        XCTAssertEqual(AndroidLogLine.parse("").message, "")
    }

    func testAMessageThatIsEmptyDoesNotBorrowTheNextField() {
        let line = AndroidLogLine.parse("08-04 13:50:19.565 I/Tag(12345): ")
        XCTAssertEqual(line.tag, "Tag")
        XCTAssertEqual(line.message, "")
    }

    // MARK: The filter menu

    func testTheLevelSpecIsAClosedSetOfLogcatsOwnLetters() {
        // The letter is interpolated into `*:<level>` and reaches an argument vector; `logcat` treats
        // an unparsable filter spec as a fatal error, which reads as a console that connects and
        // immediately dies.
        XCTAssertEqual(
            AndroidLogLevel.allCases.map(\.rawValue), ["V", "D", "I", "W", "E"],
        )
    }
}
#endif
