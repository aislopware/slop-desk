// PaneEmptyCopyTests — the CROSSING behind the typed empty-state copy, not the wording.
//
// WHICH four things each cause says are `slopdesk_workspace::pane_empty`'s and pinned there; a second
// copy of the table here would be the same sentences in two languages. What only Swift can get wrong
// is the marshalling: that the four strings come back from ONE call in their own slots, that the
// host and the reason are read from the slot each belongs in rather than from the one beside it, and
// that an ABSENT action stays absent instead of arriving as an empty label — because a button offered
// under "Connection Lost" would tell the user to act on a redial the supervisor is already driving.
//
// It was `SlateEmptyStateTests` in `SlopDeskClientUITests` until R12, and it followed the tables down
// twice: to `PaneEmptyCause` (docs/56 §3, P6 — a frameworkless value goes to the floor), and from
// there to the crate both floors read.

import XCTest
@testable import SlopDeskClientCore

final class PaneEmptyCopyTests: XCTestCase {
    /// All four crossings answer, in their own slots — a reading that read its head at the wrong
    /// offset would come back with a right title beside an empty symbol.
    func testEveryCauseCrossesWithAllFourAnswers() {
        let causes: [PaneEmptyCause] = [
            .neverConnected, .linkDown(host: "mac-studio"), .noTabs,
            .connectFailed(reason: "Connection refused"),
        ]
        for cause in causes {
            XCTAssertFalse(cause.symbolName.isEmpty, "\(cause) crossed with no glyph")
            XCTAssertFalse(cause.title.isEmpty, "\(cause) crossed headless")
            XCTAssertFalse(cause.caption.isEmpty, "\(cause) crossed with nothing under the title")
        }
        XCTAssertEqual(
            Set(causes.map(\.symbolName)).count, causes.count,
            "the glyph is part of the distinction the copy is spent making",
        )
        XCTAssertEqual(
            Set(causes.map(\.title)).count, causes.count,
            "four causes that read alike are one surface pretending to be four",
        )
    }

    /// The host rides in its own span and the reason in the next one, so a caption drawn from the
    /// wrong slot would name the wrong thing confidently.
    func testTheHostAndTheReasonCrossInTheirOwnSlots() {
        XCTAssertEqual(PaneEmptyCause.linkDown(host: "mac-studio").caption, "Reconnecting to mac-studio…")
        XCTAssertEqual(PaneEmptyCause.connectFailed(reason: "Connection refused").caption, "Connection refused")
        XCTAssertFalse(
            PaneEmptyCause.noTabs.caption.contains("Reconnecting"),
            "a cause that names nobody must not borrow a neighbour's slot",
        )
    }

    /// The action's ABSENCE is a flag on the crossing rather than an empty string, which is what stops
    /// a redial being drawn with a button the user is not meant to press.
    func testAnAbsentActionIsNotAnEmptyOne() {
        XCTAssertNil(PaneEmptyCause.linkDown(host: "mac-studio").actionLabel)
        for cause in [PaneEmptyCause.neverConnected, .noTabs, .connectFailed(reason: "r")] {
            XCTAssertEqual(cause.actionLabel?.isEmpty, false, "\(cause) crossed with an unlabelled button")
        }
    }
}
