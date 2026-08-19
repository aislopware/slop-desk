// ConnectionPillTests — the SwiftUI half of the connection surface: the ALARM LADDER's palette, and
// the video model's kbps dirty-guard behind the tooltip's bitrate.
//
// Everything the pill SAYS is pinned one floor down (`ConnectionReadingTests`, SlopDeskClientCore),
// where the Mac's AppKit island reads it too. What is left here is the part that is genuinely this
// framework's: which `Color` and which `Font.Weight` an alarm rung resolves to.

import SlopDeskClientCore
import SlopDeskSlate
import XCTest
@testable import SlopDeskClientUI
@testable import SlopDeskWorkspaceCore

@MainActor
final class ConnectionPillTests: XCTestCase {
    /// The island spends BRIGHTNESS and WEIGHT, never hue: `quiet` is the metadata grey every healthy
    /// reading rests in, `raised` steps up to the body-secondary ink at semibold, `loud` to the primary
    /// ink at bold. Three distinct rungs on BOTH channels — a rung that only moved one of them would be
    /// invisible on a theme whose greys sit close, or on a line already full of medium-weight type.
    func testAlarmLadderClimbsBrightnessAndWeightTogether() {
        XCTAssertEqual(ConnectionPill.alarmInk(.quiet), Slate.Text.tertiary)
        XCTAssertEqual(ConnectionPill.alarmInk(.raised), Slate.Text.secondary)
        XCTAssertEqual(ConnectionPill.alarmInk(.loud), Slate.Text.primary)
        XCTAssertEqual(ConnectionPill.alarmWeight(.quiet), .regular)
        XCTAssertEqual(ConnectionPill.alarmWeight(.raised), .semibold)
        XCTAssertEqual(ConnectionPill.alarmWeight(.loud), .bold)
        let inks = [ConnectionAlarm.quiet, .raised, .loud].map(ConnectionPill.alarmInk)
        XCTAssertEqual(Set(inks).count, 3, "every rung is its own ink — no two states paint the same")
        for alarm in [ConnectionAlarm.quiet, .raised, .loud] {
            XCTAssertNotEqual(
                ConnectionPill.alarmInk(alarm), Slate.StatusInk.warn,
                "the island has no hue register — \(alarm) must not reach for a status colour",
            )
            XCTAssertNotEqual(ConnectionPill.alarmInk(alarm), Slate.StatusInk.err)
        }
    }

    func testNoteStreamKbpsKeepsZeroAndDropsNegative() {
        let model = RemoteWindowModel()
        XCTAssertNil(model.streamKbps)
        model.noteStreamKbps(2400)
        XCTAssertEqual(model.streamKbps, 2400)
        // Idle-skip: a real 0 reading REPLACES the last value (the instrument shows the stream breathing).
        model.noteStreamKbps(0)
        XCTAssertEqual(model.streamKbps, 0)
        // Nonsense negative is dropped — the last reading stands.
        model.noteStreamKbps(-5)
        XCTAssertEqual(model.streamKbps, 0)
    }
}
