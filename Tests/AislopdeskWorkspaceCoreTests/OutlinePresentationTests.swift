import Foundation
import XCTest
@testable import AislopdeskWorkspaceCore

/// E9 — the Outline tab's PURE presentation mapping: otty-style relative-time bucketing (with an injected
/// fixed `now`) and the exit-status → gutter classification. Headless (no view / theme read).
final class OutlinePresentationTests: XCTestCase {
    // MARK: relativeTime boundaries

    func testRelativeTimeBoundaries() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func rel(_ ago: TimeInterval) -> String {
            OutlinePresentation.relativeTime(from: now.addingTimeInterval(-ago), now: now)
        }
        // The boundary table from the plan — the Outline row carries the "ago" suffix (outline-panel.png /
        // user-interface__outline.md / user-interface__details-panel.md), except the sub-second "now".
        XCTAssertEqual(rel(0), "now")
        XCTAssertEqual(rel(59), "59s ago")
        XCTAssertEqual(rel(60), "1m ago")
        XCTAssertEqual(rel(3599), "59m ago")
        XCTAssertEqual(rel(3600), "1h ago")
        XCTAssertEqual(rel(86399), "23h ago")
        XCTAssertEqual(rel(86400), "1d ago")
        // The spec's example shapes ("now"/"34s ago"/"4m ago"/"2h ago"/"3d ago").
        XCTAssertEqual(rel(34), "34s ago")
        XCTAssertEqual(rel(240), "4m ago")
        XCTAssertEqual(rel(7200), "2h ago")
        XCTAssertEqual(rel(259_200), "3d ago")
    }

    func testRelativeTimeTruncatesSubSecondToNow() {
        let now = Date(timeIntervalSince1970: 1000)
        // A fraction of a second elapsed truncates to 0 → "now" (not "0s").
        XCTAssertEqual(OutlinePresentation.relativeTime(from: now.addingTimeInterval(-0.4), now: now), "now")
    }

    func testRelativeTimeClampsFutureToNow() {
        let now = Date(timeIntervalSince1970: 1000)
        // A `from` in the future (clock skew) clamps to "now" rather than emitting a negative string.
        XCTAssertEqual(OutlinePresentation.relativeTime(from: now.addingTimeInterval(5), now: now), "now")
    }

    // MARK: gutter classification

    func testGutterMapping() {
        let running = CommandBlock(index: 0, commandText: "x", complete: false)
        XCTAssertEqual(OutlinePresentation.gutter(for: running), .running, "a running block (no D) is grey")

        let ok0 = CommandBlock(index: 1, commandText: "x", exitCode: 0, complete: true)
        XCTAssertEqual(OutlinePresentation.gutter(for: ok0), .succeeded, "exit 0 is green")

        let okNil = CommandBlock(index: 2, commandText: "x", exitCode: nil, complete: true)
        XCTAssertEqual(
            OutlinePresentation.gutter(for: okNil), .succeeded,
            "a completed block with no reported exit code is treated as success (green)",
        )

        let fail = CommandBlock(index: 3, commandText: "x", exitCode: 137, complete: true)
        XCTAssertEqual(OutlinePresentation.gutter(for: fail), .failed, "a non-zero exit is red")
    }
}
