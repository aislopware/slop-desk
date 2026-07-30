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
        // The VERDICT is the eyebrow, set explicitly: no flavour encodes "reattached vs reconnected", and
        // `.success` alone would derive the generic `FINISHED`. That frees the subject line to say what the
        // verdict MEANS for the user's context, in the card's lower-case instrument register.
        XCTAssertEqual(toast.eyebrow, "REATTACHED")
        XCTAssertEqual(toast.title, "session preserved")
        XCTAssertNil(toast.body, "the subject says it all — a detail line here would only repeat it")
        XCTAssertEqual(toast.id, "pane.PANE-1", "the toast is keyed to its pane so it de-dupes")
        // A reconnect verdict is an EVENT at a pane, not an agent's lifecycle ⇒ the outcome dot, not a ring.
        XCTAssertEqual(toast.source, .command)
        // The card is a DOOR: the reconnect happened somewhere the user is not looking, so it must carry the
        // pane to land on. A nil `paneKey` here would render the notification as a dead end.
        XCTAssertEqual(toast.paneKey, "PANE-1", "the toast must be able to jump back to its pane")
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
        XCTAssertEqual(toast.eyebrow, "RECONNECTED")
        XCTAssertEqual(toast.title, "fresh shell")
        // Instrument register (see the resumed case) — a lower-case readout fragment, not a sentence.
        XCTAssertEqual(toast.body, "previous session ended")
        XCTAssertEqual(toast.id, "pane.PANE-2")
        XCTAssertEqual(toast.paneKey, "PANE-2", "the toast must be able to jump back to its pane")

        // The two determinate outcomes must not collide — otherwise the toast can't tell them apart. The
        // EYEBROW is now the load-bearing distinction (it is what the user reads first), so pin that too.
        let resumed = try XCTUnwrap(Toast.sessionResume(paneIDKey: "PANE-2", outcome: .resumedSession))
        XCTAssertNotEqual(toast.flavor, resumed.flavor, "fresh vs resumed must read as different flavours")
        XCTAssertNotEqual(toast.eyebrow, resumed.eyebrow, "fresh vs resumed must announce different events")
        XCTAssertNotEqual(toast.title, resumed.title, "fresh vs resumed must carry different copy")
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
