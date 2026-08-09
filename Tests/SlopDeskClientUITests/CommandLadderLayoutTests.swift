// CommandLadderLayoutTests — pins the ladder's evenly-pitched fit rule (round 14): the pitch
// compresses from the preferred 14pt down to the 6pt floor before any tick is dropped, and past
// the floor the ladder DROPS oldest ticks rather than fusing them. Pure geometry, headless.
//
// Plus the QUANTIZATION the rail's stability rests on (2026-08-09): the pitch may only take a value
// off `pitchLadder`, so a pane that is running commands does not re-lay its whole ladder out by a
// fraction of a point per command.

import XCTest
@testable import SlopDeskClientUI

final class CommandLadderLayoutTests: XCTestCase {
    func testFewTicksKeepThePreferredPitch() {
        let fit = CommandLadderLayout.fit(count: 5, available: 400)
        XCTAssertEqual(fit.shown, 5)
        XCTAssertEqual(fit.pitch, CommandLadderLayout.preferredPitch)
    }

    func testPitchCompressesBeforeAnyTickDrops() {
        // 50 ticks in 300pt: the preferred pitch (700pt) does not fit, the floor (300pt) does —
        // every tick stays, at the 6pt floor.
        let fit = CommandLadderLayout.fit(count: 50, available: 300)
        XCTAssertEqual(fit.shown, 50)
        XCTAssertEqual(fit.pitch, 6, accuracy: 0.0001)
    }

    func testPastTheFloorTheLadderDropsOldestTicks() {
        // 64 ticks in 100pt: at the 6pt floor only 16 fit — the ladder shows the newest 16.
        let fit = CommandLadderLayout.fit(count: 64, available: 100)
        XCTAssertEqual(fit.shown, 16)
        XCTAssertEqual(fit.pitch, 6, accuracy: 0.0001)
    }

    func testDegenerateHeightShowsNothing() {
        XCTAssertEqual(CommandLadderLayout.fit(count: 10, available: 0).shown, 0)
        XCTAssertEqual(CommandLadderLayout.fit(count: 10, available: -50).shown, 0)
        XCTAssertEqual(CommandLadderLayout.fit(count: 0, available: 400).shown, 0)
    }

    func testPitchIsAlwaysARungOfTheLadder() {
        // Every count/height combination a live pane can present resolves to a rung — never to an
        // in-between spacing derived from the height.
        for available in stride(from: 40.0, through: 900.0, by: 17.0) {
            for count in 1...64 {
                let fit = CommandLadderLayout.fit(count: count, available: available)
                guard fit.shown > 0 else { continue }
                XCTAssertTrue(
                    CommandLadderLayout.pitchLadder.contains(fit.pitch),
                    "pitch \(fit.pitch) is off the ladder (count \(count), available \(available))",
                )
                XCTAssertLessThanOrEqual(CGFloat(fit.shown) * fit.pitch, available + 0.0001)
            }
        }
    }

    func testOneMoreCommandDoesNotRepitchTheWholeRail() {
        // 300pt holds 50 ticks at the 6pt rung and 60 at 5 — inside a rung the pitch is IDENTICAL
        // command after command, so the ticks already drawn do not move.
        let pitches = (40...50).map { CommandLadderLayout.fit(count: $0, available: 300).pitch }
        XCTAssertEqual(Set(pitches), [6])
    }

    func testEveryTickStaysWhileAnyRungStillHoldsThem() {
        // 42 ticks do not fit at 8pt in 260pt, but they do at the 6pt floor — the ladder steps down
        // the rung rather than dropping the oldest command.
        let fit = CommandLadderLayout.fit(count: 42, available: 260)
        XCTAssertEqual(fit.shown, 42)
        XCTAssertEqual(fit.pitch, 6, accuracy: 0.0001)
    }

    /// A pane mid-layout can be proposed a NON-FINITE height; the ladder draws nothing rather than
    /// resolving a tick count out of it (`Int(available / minPitch)` on an infinity traps).
    func testNonFiniteHeightShowsNothing() {
        XCTAssertEqual(CommandLadderLayout.fit(count: 10, available: .nan).shown, 0)
        XCTAssertEqual(CommandLadderLayout.fit(count: 10, available: .infinity).shown, 0)
    }

    func testExactFloorCapacityBoundary() {
        // 12pt fits exactly two floor-pitch ticks.
        let fit = CommandLadderLayout.fit(count: 3, available: 12)
        XCTAssertEqual(fit.shown, 2)
        XCTAssertEqual(fit.pitch, 6, accuracy: 0.0001)
    }
}
