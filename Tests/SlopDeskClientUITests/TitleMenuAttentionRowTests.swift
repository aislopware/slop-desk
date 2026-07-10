// TitleMenuAttentionRowTests — pins the pure view-side helpers behind the NEEDS-ATTENTION menu rows:
// the per-badge caption fallback (the second line when the host sent no agent label) and the compact
// relative-age bucketing (the trailing readout). Headless VALUE assertions — no SwiftUI render.

import SlopDeskWorkspaceCore
import XCTest
@testable import SlopDeskClientUI

@MainActor
final class TitleMenuAttentionRowTests: XCTestCase {
    /// Every attention-class badge carries a meaningful caption; the activity/privilege kinds (which
    /// never reach the list) are empty, not garbage.
    func testWaitingCaptions() {
        XCTAssertEqual(TitlePaneMenu.waitingCaption(.awaitingInput), "Needs your input")
        XCTAssertEqual(TitlePaneMenu.waitingCaption(.error), "Failed")
        XCTAssertEqual(TitlePaneMenu.waitingCaption(.completed), "Finished")
        XCTAssertEqual(TitlePaneMenu.waitingCaption(.finished), "Finished")
        XCTAssertEqual(TitlePaneMenu.waitingCaption(.running), "")
    }

    /// The age buckets: seconds under a minute, then minutes, hours, days — and the guards: an unknown
    /// instant shows nothing, and a FUTURE instant (clock skew) shows nothing rather than `-3s`.
    func testRelativeAgeBuckets() {
        let now = Date(timeIntervalSinceReferenceDate: 100_000)
        func age(_ secondsAgo: TimeInterval) -> String? {
            TitlePaneMenu.relativeAge(of: now.addingTimeInterval(-secondsAgo), now: now)
        }
        XCTAssertEqual(age(0), "0s")
        XCTAssertEqual(age(42), "42s")
        XCTAssertEqual(age(60), "1m")
        XCTAssertEqual(age(59 * 60), "59m")
        XCTAssertEqual(age(3600), "1h")
        XCTAssertEqual(age(90000), "1d")
        XCTAssertNil(TitlePaneMenu.relativeAge(of: nil, now: now), "unknown instant → no age")
        XCTAssertNil(age(-5), "future instant (clock skew) → no age, never a negative readout")
    }
}
