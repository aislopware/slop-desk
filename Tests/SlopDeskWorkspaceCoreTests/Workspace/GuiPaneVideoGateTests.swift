import XCTest
@testable import SlopDeskWorkspaceCore

// MARK: - GuiPaneVideoGateTests (WS-A / A6)

/// Pins the WS-A broadening of the headless test double's video gate (A6): ``FakePaneSession``'s
/// `setVideoActive`/`pause`/`resume` now gate on `kind.isVideo` — mirroring ``LivePaneSession/setVideoActive``
/// (which gates on `kind.isVideo`) — instead of the narrower `kind == .remoteGUI`. So the auto-managed
/// ``PaneKind/systemDialog`` video kind (and any future video kind) accounts against the ``WorkspaceStore``
/// `liveVideoCap` faithfully, the same way a `.remoteGUI` pane does — WITHOUT ever instantiating
/// `VideoWindowView`/SCStream/VT/Metal (the double is pure).
///
/// REVERT-TO-CONFIRM-FAIL: with the pre-A6 `kind == .remoteGUI` gate every assertion below that a
/// `.systemDialog` pane activates / suspends / restores video FAILS — `setVideoActive` was a no-op for
/// `.systemDialog`, so `activateVideo` returned `false`, the cap never counted it, and pause/resume never
/// toggled it.
@MainActor
final class GuiPaneVideoGateTests: XCTestCase {
    private func fake(_ handle: (any PaneSessionHandle)?) -> FakePaneSession {
        guard let f = handle as? FakePaneSession else { fatalError("expected a FakePaneSession") }
        return f
    }

    // MARK: - systemDialog activates + counts against the cap (the A6 broadening)

    /// A `.systemDialog` pane is a video kind, so `activateVideo` admits it through the cap exactly like a
    /// `.remoteGUI` pane. (Pre-A6 the double's `setVideoActive` no-op'd for `.systemDialog`, so this
    /// returned `false`.)
    func testSystemDialogPaneActivatesVideoThroughTheCap() throws {
        let store = WorkspaceStore(makeSession: { FakePaneSession($0) }, liveVideoCap: 2)
        let dialogID = store.addSystemDialogPane(windowID: 1966, owner: "SecurityAgent", title: "", isSecure: true)
        let dialog = try XCTUnwrap(store.handle(for: dialogID) as? FakePaneSession)
        XCTAssertEqual(dialog.kind, .systemDialog)
        XCTAssertTrue(dialog.kind.isVideo, "systemDialog is a video kind")

        XCTAssertTrue(store.activateVideo(dialogID), "a systemDialog video pane is admitted through the cap")
        XCTAssertTrue(dialog.isVideoActive, "the broadened gate flipped its video-active flag")
        XCTAssertEqual(dialog.events, [.adopt(dialogID), .videoActive(true)])
    }

    /// A `.systemDialog` video pane COUNTS against the `liveVideoCap` alongside a `.remoteGUI` pane — two
    /// live video stacks of mixed kinds saturate a cap of 2 and gate a third. (Pre-A6 the systemDialog
    /// never counted, so the third would have been wrongly admitted.)
    func testSystemDialogAndRemoteGUIShareTheCap() throws {
        let store = WorkspaceStore(makeSession: { FakePaneSession($0) }, liveVideoCap: 2)
        store.addPane(kind: .remoteGUI)
        let guiID = try XCTUnwrap(store.focusedPane)
        let dialogID = store.addSystemDialogPane(windowID: 7, owner: "SecurityAgent", title: "Unlock", isSecure: true)
        store.addPane(kind: .remoteGUI)
        let gui2ID = try XCTUnwrap(store.focusedPane)

        XCTAssertTrue(store.activateVideo(guiID), "1st (remoteGUI) admitted")
        XCTAssertTrue(store.activateVideo(dialogID), "2nd (systemDialog) admitted — at the cap of 2")
        XCTAssertFalse(store.activateVideo(gui2ID), "3rd gated — the systemDialog occupies a real cap slot")

        let activeIDs = Set(store.allSessions.filter(\.isVideoActive).map(\.id))
        XCTAssertEqual(activeIDs, Set([guiID, dialogID]), "exactly the cap=2 live; the systemDialog counted")
    }

    /// `deactivateVideo` on a live `.systemDialog` pane frees its slot and nudges the promotion generation,
    /// so a previously-gated sibling can then activate.
    func testDeactivatingSystemDialogFreesItsSlot() throws {
        let store = WorkspaceStore(makeSession: { FakePaneSession($0) }, liveVideoCap: 1)
        let dialogID = store.addSystemDialogPane(windowID: 7, owner: "SecurityAgent", title: "", isSecure: true)
        store.addPane(kind: .remoteGUI)
        let guiID = try XCTUnwrap(store.focusedPane)

        XCTAssertTrue(store.activateVideo(dialogID), "the single slot admits the systemDialog")
        XCTAssertFalse(store.activateVideo(guiID), "cap=1 saturated by the live systemDialog")

        let beforeGen = store.videoPromotionGeneration
        store.deactivateVideo(dialogID)
        XCTAssertGreaterThan(store.videoPromotionGeneration, beforeGen, "freeing the systemDialog slot nudges")
        XCTAssertTrue(store.activateVideo(guiID), "the freed slot admits the previously-gated remoteGUI pane")
    }

    // MARK: - scene-phase fan-out covers a video-active systemDialog (mirrors A6's pause/resume)

    /// A video-active `.systemDialog` pane SUSPENDS on `pauseAll()` and RESTORES on `resumeAll()` — the
    /// same iOS-background contract as a `.remoteGUI` pane (A6 broadened the double's pause/resume from
    /// `kind == .remoteGUI` to `kind.isVideo`). Pre-A6 the systemDialog's video never toggled.
    func testVideoActiveSystemDialogSuspendsAndRestoresAcrossFanOut() async throws {
        let store = WorkspaceStore(makeSession: { FakePaneSession($0) }, liveVideoCap: 2)
        let dialogID = store.addSystemDialogPane(windowID: 1966, owner: "SecurityAgent", title: "", isSecure: true)
        XCTAssertTrue(store.activateVideo(dialogID))
        let dialog = try XCTUnwrap(store.handle(for: dialogID) as? FakePaneSession)
        XCTAssertTrue(dialog.isVideoActive, "active before background")

        await store.pauseAll()
        XCTAssertFalse(dialog.isVideoActive, "pauseAll suspended the systemDialog video stack")

        await store.resumeAll()
        XCTAssertTrue(dialog.isVideoActive, "resumeAll restored the systemDialog video active before pause")
        XCTAssertEqual(
            dialog.events,
            [.adopt(dialogID), .videoActive(true), .pause, .videoActive(false), .resume, .videoActive(true)],
            "the suspend/restore fan-out is recorded for the systemDialog video pane",
        )
    }

    /// An IDLE (never-activated) `.systemDialog` pane is not spuriously activated by the resume fan-out.
    func testIdleSystemDialogStaysInactiveAcrossFanOut() async throws {
        let store = WorkspaceStore(makeSession: { FakePaneSession($0) }, liveVideoCap: 2)
        let dialogID = store.addSystemDialogPane(windowID: 1966, owner: "SecurityAgent", title: "", isSecure: true)
        let dialog = try XCTUnwrap(store.handle(for: dialogID) as? FakePaneSession)
        XCTAssertFalse(dialog.isVideoActive, "never activated")

        await store.pauseAll()
        await store.resumeAll()
        XCTAssertFalse(dialog.isVideoActive, "an idle systemDialog video pane is not spuriously activated")
    }
}
