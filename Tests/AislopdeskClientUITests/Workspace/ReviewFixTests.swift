import XCTest
import CoreGraphics
@testable import AislopdeskClientUI

/// Pins the fixes from the session self-review:
/// F1 switchToLayoutPreset clears pendingClose/pendingRename; F3 OSC notification rate limiter;
/// F5 saveBookmark uses the live shell title. (F2 animation scope + F4 ⌘N default are covered by
/// CanvasView eyeball / PaneCreationCommandTests respectively.)
@MainActor
final class ReviewFixTests: XCTestCase {

    private func makeStore(restoring: Workspace? = nil) -> WorkspaceStore {
        WorkspaceStore(restoring: restoring, makeSession: { FakePaneSession($0) }, liveVideoCap: 5)
    }

    // MARK: - F1: layout switch clears pending dialogs

    func testSwitchLayoutClearsPendingClose() {
        let a = PaneID()
        let ws = Workspace(canvas: Canvas(items: [
            CanvasItem(id: a, spec: PaneSpec(kind: .terminal, title: "A"),
                       frame: CGRect(x: 0, y: 0, width: 480, height: 320), z: 0)]), focusedPane: a)
        let store = makeStore(restoring: ws)
        store.saveLayoutPreset(name: "x")
        (store.handle(for: a) as? FakePaneSession)?.isShellBusy = true
        store.requestClosePane(a)
        XCTAssertEqual(store.pendingClose, a, "a busy-shell close parks here")

        store.switchToLayoutPreset(name: "x")

        XCTAssertNil(store.pendingClose, "a layout switch orphans the pending id → no phantom dialog")
        XCTAssertNil(store.pendingRename)
    }

    // MARK: - F5: bookmark uses the live title

    func testBookmarkNameFallsBackToSpecTitleWithoutLiveTitle() {
        // The FakePaneSession has no live terminal title, so displayTitle falls back to spec.title.
        let a = PaneID()
        let ws = Workspace(canvas: Canvas(items: [
            CanvasItem(id: a, spec: PaneSpec(kind: .terminal, title: "MyShell"),
                       frame: CGRect(x: 0, y: 0, width: 480, height: 320), z: 0)]), focusedPane: a)
        let store = makeStore(restoring: ws)
        store.saveBookmark(1)
        XCTAssertEqual(store.workspace.bookmarks[1]?.name, "MyShell",
                       "bookmark name resolves through displayTitle (live title when present, else spec)")
    }

    /// displayTitle (now used by the carousel tab + top bar, not just the pill/sidebar) masks secrets,
    /// so a secret in the OSC/window title never leaks into ANY title surface.
    func testDisplayTitleRedactsSecretsAcrossEveryTitleSurface() {
        let spec = PaneSpec(kind: .terminal, title: "PASSWORD=hunter2secretvalue")
        let shown = PanePresentation.displayTitle(nil, spec: spec)
        XCTAssertTrue(shown.contains(SecretRedactor.mask), "the title is redacted")
        XCTAssertFalse(shown.contains("hunter2secretvalue"), "the raw secret never reaches a title surface")
    }

    // MARK: - F3: notification rate limiter (pure)

    func testRateLimiterAllowsBurstThenThrottles() {
        var limiter = NotificationRateLimiter(capacity: 3, refillPerSecond: 1, now: 0)
        XCTAssertTrue(limiter.allow(now: 0))
        XCTAssertTrue(limiter.allow(now: 0))
        XCTAssertTrue(limiter.allow(now: 0))
        XCTAssertFalse(limiter.allow(now: 0), "the 4th in a burst is dropped")
        XCTAssertFalse(limiter.allow(now: 0.5), "half a token refilled — still dropped")
        XCTAssertTrue(limiter.allow(now: 1.0), "one token refilled after 1s")
        XCTAssertFalse(limiter.allow(now: 1.0))
    }

    func testRateLimiterCapsAtCapacity() {
        var limiter = NotificationRateLimiter(capacity: 2, refillPerSecond: 1, now: 0)
        // A long idle refills to capacity, not beyond.
        XCTAssertTrue(limiter.allow(now: 100))
        XCTAssertTrue(limiter.allow(now: 100))
        XCTAssertFalse(limiter.allow(now: 100), "tokens cap at capacity (2), not 100")
    }
}
