// ConnectionPillTests — the SwiftUI half of the connection surface: the video model's kbps dirty-guard
// behind the tooltip's bitrate.
//
// Everything the pill SAYS is pinned one floor down (`ConnectionReadingTests`, SlopDeskClientCore),
// where the Mac's AppKit island reads it too. The alarm ladder's `Color` / `Font.Weight` left with
// docs/56 batch 3: `ConnectionPill.alarmInk`/`.alarmWeight` were a per-renderer table resolving a name
// both halves already agreed on, and that resolution is now `Slate.connectionAlarmInk(_:)` /
// `Slate.connectionAlarmWeight(_:)` themselves (`SlateSharedInkTests`, `SlopDeskSlateTests`) — a shared
// function has nothing left for a UI half's test to pin.

import XCTest
@testable import SlopDeskPhoneUI
@testable import SlopDeskWorkspaceCore

@MainActor
final class ConnectionPillTests: XCTestCase {
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
