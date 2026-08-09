// CommandLadderLayoutTests — pins the ladder's evenly-pitched fit rule (round 14): the pitch
// compresses from the preferred 14pt down to the 6pt floor before any tick is dropped, and past
// the floor the ladder DROPS oldest ticks rather than fusing them. Pure geometry, headless.
//
// Plus the QUANTIZATION the rail's stability rests on (2026-08-09): the pitch may only take a value
// off `pitchLadder`, so a pane that is running commands does not re-lay its whole ladder out by a
// fraction of a point per command.
//
// Plus the FOOT rung (2026-08-09): the live-prompt mark is reserved out of the height BEFORE the
// ticks are fitted — at the ladder's ordinary pitch, like any other rung — and it is the last thing
// the ladder gives up.

import XCTest
@testable import SlopDeskClientUI

final class CommandLadderLayoutTests: XCTestCase {
    func testFewTicksKeepThePreferredPitch() {
        let fit = CommandLadderLayout.fit(count: 5, available: 400)
        XCTAssertEqual(fit.shown, 5)
        XCTAssertEqual(fit.pitch, CommandLadderLayout.preferredPitch)
        XCTAssertTrue(fit.home)
        XCTAssertEqual(fit.rungs, 6)
    }

    func testPitchCompressesBeforeAnyTickDrops() {
        // 49 ticks + the foot rung in 300pt: the preferred pitch (700pt) does not fit, the floor
        // (300pt) does — every tick stays, at the 6pt floor.
        let fit = CommandLadderLayout.fit(count: 49, available: 300)
        XCTAssertEqual(fit.shown, 49)
        XCTAssertEqual(fit.pitch, 6, accuracy: 0.0001)
        XCTAssertEqual(fit.rungs, 50)
    }

    func testPastTheFloorTheLadderDropsOldestTicks() {
        // 64 ticks in 100pt: at the 6pt floor only 16 rungs fit — 15 ticks plus the foot rung.
        let fit = CommandLadderLayout.fit(count: 64, available: 100)
        XCTAssertEqual(fit.shown, 15)
        XCTAssertEqual(fit.rungs, 16)
        XCTAssertEqual(fit.pitch, 6, accuracy: 0.0001)
    }

    func testDegenerateHeightShowsNothing() {
        // Not even the foot mark — a rail with no room is drawn not at all, never half-drawn.
        for available in [0.0, -50.0] as [CGFloat] {
            let fit = CommandLadderLayout.fit(count: 10, available: available)
            XCTAssertEqual(fit.shown, 0)
            XCTAssertEqual(fit.rungs, 0)
            XCTAssertFalse(fit.home)
        }
    }

    func testPitchIsAlwaysARungOfTheLadder() {
        // Every count/height combination a live pane can present resolves to a rung — never to an
        // in-between spacing derived from the height.
        for available in stride(from: 40.0, through: 900.0, by: 17.0) {
            for count in 1...64 {
                let fit = CommandLadderLayout.fit(count: count, available: available)
                guard fit.rungs > 0 else { continue }
                XCTAssertTrue(
                    CommandLadderLayout.pitchLadder.contains(fit.pitch),
                    "pitch \(fit.pitch) is off the ladder (count \(count), available \(available))",
                )
                XCTAssertLessThanOrEqual(CGFloat(fit.rungs) * fit.pitch, available + 0.0001)
            }
        }
    }

    func testOneMoreCommandDoesNotRepitchTheWholeRail() {
        // 300pt holds 49 ticks (+ the foot rung) at the 6pt rung — inside a rung the pitch is
        // IDENTICAL command after command, so the ticks already drawn do not move.
        let pitches = (39...49).map { CommandLadderLayout.fit(count: $0, available: 300).pitch }
        XCTAssertEqual(Set(pitches), [6])
    }

    func testEveryTickStaysWhileAnyRungStillHoldsThem() {
        // 40 ticks + the foot rung do not fit at 8pt in 260pt, but they do at the 6pt floor — the
        // ladder steps down the rung rather than dropping the oldest command.
        let fit = CommandLadderLayout.fit(count: 40, available: 260)
        XCTAssertEqual(fit.shown, 40)
        XCTAssertEqual(fit.pitch, 6, accuracy: 0.0001)
    }

    /// A pane mid-layout can be proposed a NON-FINITE height; the ladder draws nothing rather than
    /// resolving a tick count out of it (`Int(available / minPitch)` on an infinity traps).
    func testNonFiniteHeightShowsNothing() {
        XCTAssertEqual(CommandLadderLayout.fit(count: 10, available: .nan).rungs, 0)
        XCTAssertEqual(CommandLadderLayout.fit(count: 10, available: .infinity).rungs, 0)
    }

    // MARK: The foot rung (the live-prompt mark)

    func testTheFootMarkIsReservedBeforeAnyTickIsFitted() {
        // A height that holds exactly 20 rungs carries 19 commands, not 20 — the foot mark is taken
        // out of the height FIRST, at every rung of the pitch ladder. Each case is also the
        // exact-capacity boundary for its own rung: 19 commands fill the height to the point, so
        // the widest pitch that still holds all 20 rungs is the one under test.
        for pitch in CommandLadderLayout.pitchLadder {
            let fit = CommandLadderLayout.fit(count: 19, available: pitch * 20)
            XCTAssertEqual(fit.shown, 19, "at pitch \(pitch)")
            XCTAssertEqual(fit.rungs, 20, "at pitch \(pitch)")
            XCTAssertEqual(fit.pitch, pitch, accuracy: 0.0001, "at pitch \(pitch)")
        }
    }

    func testTheFootMarkIsTheLastThingDropped() {
        // 6pt is ONE floor rung — and the ladder spends it on the way back to the cursor rather
        // than on a command from a scrollback the pane is far too short to index.
        let fit = CommandLadderLayout.fit(count: 3, available: 6)
        XCTAssertEqual(fit.shown, 0)
        XCTAssertTrue(fit.home)
        XCTAssertEqual(fit.rungs, 1)
        XCTAssertEqual(fit.pitch, 6, accuracy: 0.0001)
    }
}
