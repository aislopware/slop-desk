// PaneImmersiveCaptureTests — the immersive seam's WISH arms, and only those.
//
// HANG-SAFETY, first, because it is what shapes the whole file. Engaging immersive capture creates a
// filtering `.cgSessionEventTap`: on a machine that has granted this process Accessibility trust — a
// developer's, not CI's — that tap swallows the TEST RUNNER's keyboard and the session's with it. So the
// rule `SystemKeyCaptureController` states is absolute, and it is stated here as a property of the CASES
// rather than as a hope: every path exercised below is blocked from ``PaneImmersiveCapture/engage(model:)``
// by TWO independent guards, not one.
//
//   • the model is never opened and never given a `systemKeyInjector`, so `canInjectSystemKeys` is `false`
//     — the guard that stands immediately before the trust check and the tap;
//   • and each case enters `toggle(model:)` with `immersiveEffective` already `true`, which returns one arm
//     earlier still.
//
// A regression that deleted either guard would still be stopped by the other, which is the only reason a
// test may call `toggle` at all. Nothing here calls `autoEngage(model:isFocused:)` with its five clauses
// arranged to pass, and nothing constructs a controller with a window: those have ONE guard between them
// and a live tap, and a test whose failure mode is "the developer's keyboard stops working" is not a test.
// (Constructing `PaneImmersiveCapture` is safe on its own — the controller's `init` allocates nothing; the
// tap is created in `engage(forward:keyWindow:)` and nowhere else.)
//
// What is left is worth pinning because it is the arm nothing else covers: a LATCHED wish whose tap is not
// live. That state is real — Accessibility trust revoked between the relaunch that restored the wish and
// the user's next click — and the chip's tint is claiming a mode that is not on. The fix is that the click
// drops the wish instead of trying to engage, and it has to drop the fullscreen auto-arm with it, because
// an escape hatch that leaves half the arming behind is not an escape hatch (docs/DECISIONS.md 2026-07-22,
// the Moonlight lesson). The tap lifecycle itself stays GUI-verified, and the decision table underneath is
// `SystemKeyCapturePolicyTests`.

import SlopDeskWorkspaceCore
import XCTest
@testable import SlopDeskClientCore

@MainActor
final class PaneImmersiveCaptureTests: XCTestCase {
    /// The capability the footer reads to decide whether the immersive chip EXISTS. A chip drawn where the
    /// tap is a no-op is the "listed and inert" defect the palette and binding tables closed.
    ///
    /// Only the Mac's answer is reachable from here: this is a COMPILED gate, so the runner can only report
    /// the slice it is. The phone's `false` is unaskable — which is precisely the argument for the platform
    /// declaration becoming DATA the way `BindingRowPlatform.lists(_:mac:)` is, and precisely what this test
    /// cannot do for it today.
    func testTheCapabilityIsTheCompiledSlicesOwnAnswer() {
        #if canImport(AppKit)
        XCTAssertTrue(PaneImmersiveCapture.isSupported, "AppKit is here, so the CGEvent tap is reachable")
        #else
        XCTAssertFalse(PaneImmersiveCapture.isSupported, "no AppKit, no tap — the footer omits the chip")
        #endif
        XCTAssertFalse(PaneImmersiveCapture().isEngaged, "a fresh seam owns no tap until someone engages")
    }

    /// A wish that survived a relaunch while the tap did NOT (Accessibility trust revoked in between): the
    /// click must drop the wish rather than reach for a tap it cannot get, so the chip stops claiming a mode
    /// that is not on. Reaching `engage` here would be the bug — and is blocked twice over (see the header).
    func testTogglingALatchedWishWithNoLiveTapDropsTheWish() {
        let capture = PaneImmersiveCapture()
        let model = RemoteWindowModel(windowID: "42", title: "Safari")
        model.setImmersiveDesired(true)
        XCTAssertTrue(model.immersiveEffective)
        XCTAssertFalse(model.canInjectSystemKeys, "no stream and no sink — the tap is unreachable from here")

        capture.toggle(model: model)

        XCTAssertFalse(model.immersiveDesired, "the stale latch is dropped, not re-engaged")
        XCTAssertFalse(capture.isEngaged, "and no tap was created on the way")
    }

    /// The fullscreen auto-arm is an `immersiveEffective` the user never latched, and the toggle is the ONLY
    /// in-stream way out of it. Clearing the latch but leaving the override armed would re-engage on the next
    /// focus edge — capture with no working off switch, which is the trap the auto-arm decision named.
    func testTogglingOffClearsTheFullscreenAutoArmToo() {
        let capture = PaneImmersiveCapture()
        let model = RemoteWindowModel(windowID: "42", title: "Safari")
        model.noteFullscreenPresentation(true)
        XCTAssertTrue(model.immersiveEffective, "fullscreen arms capture without the latch")
        XCTAssertFalse(model.immersiveDesired, "the latch itself was never set")

        capture.toggle(model: model)

        XCTAssertFalse(model.fullscreenImmersiveOverride, "the explicit off drops the auto-arm")
        XCTAssertFalse(model.immersiveEffective, "so nothing re-engages on the next focus edge")
        XCTAssertFalse(capture.isEngaged)
    }
}
