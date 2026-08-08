// CommandLadderLayoutTests — pins the ladder's evenly-pitched fit rule (round 14): the pitch
// compresses from the preferred 10pt down to the 4pt floor before any tick is dropped, and past
// the floor the ladder DROPS oldest ticks rather than fusing them. Pure geometry, headless.

import XCTest
@testable import SlopDeskClientUI

final class CommandLadderLayoutTests: XCTestCase {
    func testFewTicksKeepThePreferredPitch() {
        let fit = CommandLadderLayout.fit(count: 5, available: 400)
        XCTAssertEqual(fit.shown, 5)
        XCTAssertEqual(fit.pitch, CommandLadderLayout.preferredPitch)
    }

    func testPitchCompressesBeforeAnyTickDrops() {
        // 50 ticks in 300pt: preferred pitch (500pt) does not fit, the floor (200pt) does —
        // every tick stays, at 6pt pitch.
        let fit = CommandLadderLayout.fit(count: 50, available: 300)
        XCTAssertEqual(fit.shown, 50)
        XCTAssertEqual(fit.pitch, 6, accuracy: 0.0001)
    }

    func testPastTheFloorTheLadderDropsOldestTicks() {
        // 64 ticks in 100pt: at the 4pt floor only 25 fit — the ladder shows the newest 25.
        let fit = CommandLadderLayout.fit(count: 64, available: 100)
        XCTAssertEqual(fit.shown, 25)
        XCTAssertEqual(fit.pitch, 4, accuracy: 0.0001)
    }

    func testDegenerateHeightShowsNothing() {
        XCTAssertEqual(CommandLadderLayout.fit(count: 10, available: 0).shown, 0)
        XCTAssertEqual(CommandLadderLayout.fit(count: 10, available: -50).shown, 0)
        XCTAssertEqual(CommandLadderLayout.fit(count: 0, available: 400).shown, 0)
    }

    func testExactFloorCapacityBoundary() {
        // 8pt fits exactly two floor-pitch ticks.
        let fit = CommandLadderLayout.fit(count: 3, available: 8)
        XCTAssertEqual(fit.shown, 2)
        XCTAssertEqual(fit.pitch, 4, accuracy: 0.0001)
    }
}
