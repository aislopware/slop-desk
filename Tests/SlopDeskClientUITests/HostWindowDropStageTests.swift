// The rail-drag drop's ONE verb under the Stage re-scope: a release anywhere over the canvas opens
// the dragged window in the STAGE. The old zone grammar (split / dock / new-tab / keep) died with the
// terminal-only tree — these pins cover what remains: the hover chip's copy.

import XCTest
@testable import SlopDeskClientUI

final class HostWindowDropStageTests: XCTestCase {
    func testStageLabelNamesTheVerbPerStagedState() {
        XCTAssertEqual(
            HostWindowDropOverlay.stageLabel(name: "Safari", alreadyStaged: false),
            "Safari — open in Stage",
            "a fresh window's release MINTS a stage tab",
        )
        XCTAssertEqual(
            HostWindowDropOverlay.stageLabel(name: "Safari", alreadyStaged: true),
            "Safari — show in Stage",
            "an already-staged window's release ACTIVATES its tab — the copy must not promise a duplicate",
        )
    }
}
