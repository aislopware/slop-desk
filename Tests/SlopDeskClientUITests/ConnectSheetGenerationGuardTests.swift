// ConnectSheetGenerationGuardTests — the Connect-sheet stale-completion guard (stability audit).
//
// FINDING (ConnectHostView): `connectAndClose()` spawned a fire-and-forget `Task { await connect();
// closeConnect() }`. Cancel only closed the sheet — the Task kept running, and when the slow connect
// finally resolved it unconditionally called `closeConnect()` again, dismissing a freshly REOPENED sheet
// mid-edit. The fix is double-guarded: the view stores + cancels the Task, AND the completion goes through
// ``OverlayCoordinator/closeConnect(ifCurrent:)`` against the ``OverlayCoordinator/connectGeneration``
// captured at Task start — bumped by EVERY open and close, so any present/dismiss since the Task started
// invalidates the stale close. These tests pin the coordinator-level guard headlessly.

import XCTest
@testable import SlopDeskClientUI

@MainActor
final class ConnectSheetGenerationGuardTests: XCTestCase {
    /// Every presentation EDGE (open and close alike) bumps the generation — the property the guard rests
    /// on: no two presentations of the sheet can share a generation.
    func testEveryOpenAndCloseBumpsTheGeneration() {
        let overlay = OverlayCoordinator()
        let g0 = overlay.connectGeneration

        overlay.openConnect()
        XCTAssertEqual(overlay.connectGeneration, g0 + 1, "open bumps")
        overlay.closeConnect()
        XCTAssertEqual(overlay.connectGeneration, g0 + 2, "close bumps")
        overlay.openConnect()
        XCTAssertEqual(overlay.connectGeneration, g0 + 3, "reopen bumps again — never reuses a generation")
    }

    /// The happy path: the sheet stays open while the connect runs, so the generation captured at Task
    /// start still matches at completion → the guarded close DOES close.
    func testCurrentCompletionClosesTheSheet() {
        let overlay = OverlayCoordinator()
        overlay.openConnect()
        let captured = overlay.connectGeneration // what connectAndClose() captures at Task start

        overlay.closeConnect(ifCurrent: captured) // the connect Task's completion
        XCTAssertFalse(overlay.connectVisible, "an un-interrupted connect completion closes the sheet")
    }

    /// THE BUG: Connect pressed (slow host) → Cancel → sheet reopened mid-edit → the OLD Task's completion
    /// arrives. Pre-fix it called `closeConnect()` unconditionally and dismissed the fresh sheet; the
    /// generation guard makes it a no-op.
    func testStaleCompletionCannotDismissAReopenedSheet() {
        let overlay = OverlayCoordinator()
        overlay.openConnect()
        let captured = overlay.connectGeneration // the slow connect Task starts here

        overlay.closeConnect() // user hits Cancel (the sheet closes; pre-fix the Task kept running)
        overlay.openConnect() // user reopens and starts editing

        overlay.closeConnect(ifCurrent: captured) // the slow connect finally resolves
        XCTAssertTrue(
            overlay.connectVisible,
            "a stale connect completion must NOT dismiss the freshly reopened sheet",
        )
    }

    /// Same guard, one edge earlier: the sheet was merely CLOSED (not reopened) after the Task started —
    /// the stale completion is still a no-op (idempotent, doesn't churn `connectVisible`/generation).
    func testStaleCompletionAfterPlainCloseIsANoOp() {
        let overlay = OverlayCoordinator()
        overlay.openConnect()
        let captured = overlay.connectGeneration

        overlay.closeConnect() // Cancel / Esc
        let afterClose = overlay.connectGeneration

        overlay.closeConnect(ifCurrent: captured)
        XCTAssertFalse(overlay.connectVisible)
        XCTAssertEqual(
            overlay.connectGeneration, afterClose,
            "a rejected stale close must not bump the generation (no phantom presentation edge)",
        )
    }
}
