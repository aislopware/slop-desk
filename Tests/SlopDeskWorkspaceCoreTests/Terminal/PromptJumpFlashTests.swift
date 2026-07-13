// PromptJumpFlashTests — pins the arm/settle honesty rules behind the prompt-jump landed flash: the
// observable epoch bumps ONLY for a jump whose scrollbar echo arrives in-window and NOT bottom-clamped
// (libghostty pins the prompt at viewport row 0 exactly then). Everything else — unsolicited scrolls,
// bottom-clamped landings, lapsed arms — must stay silent: absent, never wrong.

import XCTest
@testable import SlopDeskWorkspaceCore

@MainActor
final class PromptJumpFlashTests: XCTestCase {
    func testSettledJumpBumpsTheFlashEpochOnce() {
        let model = TerminalViewModel()
        XCTAssertEqual(model.promptJumpFlashEpoch, 0, "no flash before any jump")

        model.notePromptJumpIssued()
        model.noteViewportScroll(atBottom: false)
        XCTAssertEqual(model.promptJumpFlashEpoch, 1, "an in-window, pinned landing flashes")

        // The arm is CONSUMED: the next scroll echo (user wheel, streaming output) must not flash.
        model.noteViewportScroll(atBottom: false)
        XCTAssertEqual(model.promptJumpFlashEpoch, 1, "one jump ⇒ at most one flash")
    }

    func testBottomClampedLandingSuppressesTheFlashAndDisarms() {
        let model = TerminalViewModel()
        model.notePromptJumpIssued()
        model.noteViewportScroll(atBottom: true)
        XCTAssertEqual(
            model.promptJumpFlashEpoch, 0,
            "a forward jump clamped into the active area leaves the prompt row UNKNOWN — no flash",
        )
        model.noteViewportScroll(atBottom: false)
        XCTAssertEqual(model.promptJumpFlashEpoch, 0, "the clamped landing consumed the arm")
    }

    func testUnarmedScrollNeverFlashes() {
        let model = TerminalViewModel()
        model.noteViewportScroll(atBottom: false)
        XCTAssertEqual(model.promptJumpFlashEpoch, 0, "a scroll without a pending jump is just a scroll")
    }

    func testLapsedArmDoesNotFlash() {
        let model = TerminalViewModel()
        // Force the lapse deterministically: a zero settle window means every echo arrives "too late" —
        // the shape of a no-op jump whose echo never came, followed by a user scroll much later.
        model.promptJumpSettleWindow = .zero
        model.notePromptJumpIssued()
        model.noteViewportScroll(atBottom: false)
        XCTAssertEqual(model.promptJumpFlashEpoch, 0, "an echo outside the settle window cannot claim the arm")
    }

    // MARK: Store arming (the ⌃⌘[/] jump glue arms the ACTIVE pane's model)

    func testJumpToBlockArmsTheActivePaneModel() throws {
        let store = WorkspaceStore(
            restoringTree: .defaultWorkspace(),
            liveModel: .tree,
            makeSession: { RecordingTerminalPaneSession($0) },
            liveVideoCap: 2,
        )
        let active = try XCTUnwrap(store.tree.activeSession?.activeTab?.activePane)
        let session = try XCTUnwrap(store.handle(for: active) as? RecordingTerminalPaneSession)
        let model = try XCTUnwrap(session.terminalModel)

        store.jumpToBlockInActivePane(delta: -1)
        XCTAssertEqual(
            try XCTUnwrap(session.surfaceRecorder).actions, ["jump_to_prompt:-1"],
            "the jump still routes through the binding-action seam",
        )
        model.noteViewportScroll(atBottom: false)
        XCTAssertEqual(model.promptJumpFlashEpoch, 1, "the store's jump armed the pane model's landed flash")
    }
}
