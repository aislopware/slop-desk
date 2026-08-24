import XCTest
@testable import SlopDeskClientCore
@testable import SlopDeskWorkspaceCore

/// The `🔒 READ ONLY ×` pill mounts on a read-only video pane.
///
/// A locked remote window needs to be a VISUAL peer of a read-only terminal leaf (the input gate already
/// withholds keys/clicks, but without the pill there is ZERO in-pane feedback and no `×` exit affordance).
/// `GuiLeafView` gates the pill through the PURE ``GuiPaneReadout/showsReadOnlyPill(isReadOnly:)``
/// — this suite pins that gate (the body's mount predicate) plus the `×` release path through the store's
/// convergent set.
///
/// THE GATE USED TO HAVE A SECOND INPUT AND THIS FILE WAS ONE OF ITS THREE PRODUCERS. It read
/// `!staticMirror && isReadOnly`, for a headless `ImageRenderer` snapshot path that arrived as a
/// defaulted parameter threaded down through the pane canvas; no caller in `Sources/`, `Apps/` or
/// `ThirdParty/` ever passed `true`, so the flag and every branch on it were deleted whole in
/// increment 56d and the assertion that produced the only `true` went with them — deleted, not
/// rewritten to pass, because it was the branch's sole reason to exist. `slopdesk-invariants` fails
/// the build if the name comes back.
///
/// Hang-safety (CLAUDE.md rule #6): NO `SCStream`/`VTCompression`/`VTDecompression`/Metal/`NSWindow`/`WKWebView`
/// is instantiated — only the pure static gate and the store's value-level read-only ops are exercised.
@MainActor
final class GuiLeafReadOnlyPillTests: XCTestCase {
    /// The gate lights for a locked pane and for nothing else. This pins the gate itself so a
    /// regression that drops or inverts it fails here first. The cases are hand-enumerated (not
    /// derived from the gate's own expression), so the test is not tautological.
    func testReadOnlyPillGateLightsOnlyWhenLocked() {
        XCTAssertTrue(
            GuiPaneReadout.showsReadOnlyPill(isReadOnly: true),
            "a read-only remote window shows the lock pill",
        )
        XCTAssertFalse(
            GuiPaneReadout.showsReadOnlyPill(isReadOnly: false),
            "a writable remote window shows no pill",
        )
    }

    /// End-to-end through the store: a `.desktop` pane that is locked feeds a TRUE gate, and the pill's `×`
    /// release path (``WorkspaceStore/setPaneReadOnly(_:_:)`` with `false`) clears the convergent set so the
    /// gate falls back to false — proving the in-pane exit affordance the body wires actually unlocks the pane.
    func testReadOnlyPillReleasesTheRemoteWindowLock() {
        let store = WorkspaceStore(makeSession: { seed in RecordingPaneSession(seed.spec) })
        store.attachLoopbackWorkspaceDocument()
        let video = store.openDesktopWindow()

        XCTAssertFalse(
            GuiPaneReadout.showsReadOnlyPill(isReadOnly: store.isReadOnly(for: video)),
            "a fresh video pane is writable ⇒ no pill",
        )

        store.setPaneReadOnly(video, true)
        XCTAssertTrue(
            GuiPaneReadout.showsReadOnlyPill(isReadOnly: store.isReadOnly(for: video)),
            "locking the `.desktop` pane lights the pill",
        )

        // The pill `×` wires exactly this call (a video pane has no `terminalModel.exitReadOnly()`).
        store.setPaneReadOnly(video, false)
        XCTAssertFalse(
            GuiPaneReadout.showsReadOnlyPill(isReadOnly: store.isReadOnly(for: video)),
            "clicking `×` releases the lock through the convergent set ⇒ the pill clears",
        )
    }
}
