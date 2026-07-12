import XCTest
@testable import SlopDeskVideoHost

/// The PURE decision ladder for a failed DIALOG-EXPAND capture rebuild
/// (`applyCaptureRegion`'s `newCapturer.start` threw AFTER the old capturer was stopped): degrade
/// to a plain window-frame capturer; if even that fallback fails, send `.bye` + stop (a visible
/// disconnect the client's reconnect UI handles) — NEVER leave a `.streaming` session with
/// capturer/encoder nil (the silent forever-freeze). The SCK/VT side effects stay in the actor;
/// this locks the rung selection.
final class CaptureRegionFailureRecoveryTests: XCTestCase {
    // First rung: the union-region start failed and our dead refs are still the installed ones →
    // rebuild the plain window-frame capturer (the stream degrades to the un-expanded window).
    func testUnionStartFailureRebuildsPlainWindow() {
        XCTAssertEqual(
            CaptureRegionFailureRecovery.action(mediaFlowing: true, superseded: false, isFallbackRebuild: false),
            .rebuildPlainWindow,
        )
    }

    // Last rung: the plain-window fallback ALSO failed → disconnect (bye + stop). A visible
    // disconnect beats a silent freeze.
    func testFallbackFailureDisconnects() {
        XCTAssertEqual(
            CaptureRegionFailureRecovery.action(mediaFlowing: true, superseded: false, isFallbackRebuild: true),
            .disconnect,
        )
    }

    // A bye/stop teardown raced the rebuild (mediaFlowing false) → abandon; the teardown owns
    // cleanup, and a bye/stop from here would double-tear.
    func testTornDownSessionAbandons() {
        XCTAssertEqual(
            CaptureRegionFailureRecovery.action(mediaFlowing: false, superseded: false, isFallbackRebuild: false),
            .abandon,
        )
        XCTAssertEqual(
            CaptureRegionFailureRecovery.action(mediaFlowing: false, superseded: false, isFallbackRebuild: true),
            .abandon,
        )
    }

    // A NEWER owner installed its own capturer/encoder while we were suspended (superseded) →
    // abandon; rebuilding (or disconnecting) would orphan ITS live SCStream.
    func testSupersededRefsAbandon() {
        XCTAssertEqual(
            CaptureRegionFailureRecovery.action(mediaFlowing: true, superseded: true, isFallbackRebuild: false),
            .abandon,
        )
        XCTAssertEqual(
            CaptureRegionFailureRecovery.action(mediaFlowing: true, superseded: true, isFallbackRebuild: true),
            .abandon,
        )
    }
}
