import XCTest
@testable import SlopDeskClientUI
@testable import SlopDeskWorkspaceCore

/// E21 WI-3 (F3) — the `🔒 READ ONLY ×` pill mounts on a read-only `.remoteGUI` video pane.
///
/// Carry-overs §2.3 / plan WI-3 require the E17 read-only pill on a read-only `.remoteGUI` pane so a locked
/// remote window is a VISUAL peer of a read-only terminal leaf (the input gate already withholds keys/clicks,
/// but on un-fixed code there was ZERO in-pane feedback and no `×` exit affordance). ``GuiLeafView`` now gates
/// the pill through the PURE ``GuiLeafView/showReadOnlyPill(staticMirror:isReadOnly:)`` — this suite pins that
/// gate (the body's mount predicate) plus the `×` release path through the store's convergent set.
///
/// Hang-safety (CLAUDE.md rule #6): NO `SCStream`/`VTCompression`/`VTDecompression`/Metal/`NSWindow`/`WKWebView`
/// is instantiated — only the pure static gate and the store's value-level read-only ops are exercised.
@MainActor
final class GuiLeafReadOnlyPillTests: XCTestCase {
    /// The gate is the AND of "is read-only" with "not the static-mirror snapshot path": it lights only for a
    /// live, locked pane. On un-fixed code ``GuiLeafView`` had no pill gate at all (the helper did not exist),
    /// so this is the revert-to-confirm-fail driver. The cases are hand-enumerated (not derived from the gate's
    /// own expression), so the test is not tautological.
    func testReadOnlyPillGateLightsOnlyWhenLockedAndLive() {
        XCTAssertTrue(
            GuiLeafView.showReadOnlyPill(staticMirror: false, isReadOnly: true),
            "a live, read-only remote window shows the lock pill",
        )
        XCTAssertFalse(
            GuiLeafView.showReadOnlyPill(staticMirror: false, isReadOnly: false),
            "a writable remote window shows no pill",
        )
        XCTAssertFalse(
            GuiLeafView.showReadOnlyPill(staticMirror: true, isReadOnly: true),
            "the static-mirror snapshot path renders no live chrome even when read-only",
        )
    }

    /// End-to-end through the store: a `.remoteGUI` pane that is locked feeds a TRUE gate, and the pill's `×`
    /// release path (``WorkspaceStore/setPaneReadOnly(_:_:)`` with `false`) clears the convergent set so the
    /// gate falls back to false — proving the in-pane exit affordance the body wires actually unlocks the pane.
    func testReadOnlyPillReleasesTheRemoteWindowLock() {
        let store = WorkspaceStore(liveModel: .tree, makeSession: { MountTestPaneSession($0) })
        let video = store.newRemoteWindowTab(windowID: 7, title: "Safari", appName: "Safari")

        XCTAssertFalse(
            GuiLeafView.showReadOnlyPill(staticMirror: false, isReadOnly: store.isReadOnly(for: video)),
            "a fresh remote window is writable ⇒ no pill",
        )

        store.setPaneReadOnly(video, true)
        XCTAssertTrue(
            GuiLeafView.showReadOnlyPill(staticMirror: false, isReadOnly: store.isReadOnly(for: video)),
            "locking the `.remoteGUI` pane lights the pill",
        )

        // The pill `×` wires exactly this call (a video pane has no `terminalModel.exitReadOnly()`).
        store.setPaneReadOnly(video, false)
        XCTAssertFalse(
            GuiLeafView.showReadOnlyPill(staticMirror: false, isReadOnly: store.isReadOnly(for: video)),
            "clicking `×` releases the lock through the convergent set ⇒ the pill clears",
        )
    }
}
