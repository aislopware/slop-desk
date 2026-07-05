// ToastSessionResumeTests — pins the C8 improvement-1 mapping from a completed reconnect's
// `SessionResumeOutcome` to the transient toast the user sees (`Toast.sessionResume`). This is the
// "outcome -> banner-model mapping" the improvement calls for: a warm reattach must read as reassuring
// (session preserved), a fresh shell must warn that context ended, and the undetermined (not-yet-resolved)
// verdict must produce NO toast. Headless — a pure value mapping, no view / no socket.

import SlopDeskClient
import XCTest
@testable import SlopDeskClientUI

final class ToastSessionResumeTests: XCTestCase {
    /// A PATH-A reattach (the same live shell resumed) is reassuring — a `.success` toast that tells the user
    /// the session survived the drop. REVERT-TO-FAIL: a builder that returned `nil` (or the wrong flavour /
    /// copy) for `.resumedSession` would fail here.
    func testResumedSessionMapsToSuccessToast() throws {
        let toast = try XCTUnwrap(
            Toast.sessionResume(paneIDKey: "PANE-1", outcome: .resumedSession),
            "a resumed session surfaces a toast",
        )
        XCTAssertEqual(toast.flavor, .success, "a preserved session reads as success")
        XCTAssertEqual(toast.title, "Reattached")
        XCTAssertEqual(toast.body, "Session preserved.")
        XCTAssertEqual(toast.id, "pane.PANE-1", "the toast is keyed to its pane so it de-dupes")
    }

    /// A fresh shell (the previous session ended) is a soft warning — an `.attention` toast so the user knows
    /// scrollback/history context is gone. It must be VISUALLY DISTINCT from the resumed case (different flavour
    /// + copy) or the signal is useless.
    func testFreshShellMapsToAttentionToast() throws {
        let toast = try XCTUnwrap(
            Toast.sessionResume(paneIDKey: "PANE-2", outcome: .freshShell),
            "a fresh shell surfaces a toast",
        )
        XCTAssertEqual(toast.flavor, .attention, "a fresh shell reads as attention, not success")
        XCTAssertEqual(toast.title, "Reconnected")
        XCTAssertEqual(toast.body, "Fresh shell — previous session ended.")
        XCTAssertEqual(toast.id, "pane.PANE-2")

        // The two determinate outcomes must not collide — otherwise the toast can't tell them apart.
        let resumed = try XCTUnwrap(Toast.sessionResume(paneIDKey: "PANE-2", outcome: .resumedSession))
        XCTAssertNotEqual(toast.flavor, resumed.flavor, "fresh vs resumed must read as different flavours")
        XCTAssertNotEqual(toast.body, resumed.body, "fresh vs resumed must carry different copy")
    }

    /// The verdict has not resolved yet (`.undetermined`) — there is nothing to tell the user, so NO toast is
    /// produced. Pins that a not-yet-known outcome never flashes a spurious banner.
    func testUndeterminedOutcomeProducesNoToast() {
        XCTAssertNil(
            Toast.sessionResume(paneIDKey: "PANE-3", outcome: .undetermined),
            "an unresolved verdict must not surface any toast",
        )
    }
}
