import CoreGraphics
import XCTest
@testable import AislopdeskClientUI

/// Pure tests for the kind-aware culling decision (docs/30 §1, §6, §9.1): terminals are NEVER culled
/// (no stale-replay risk), the focused pane is never culled, `.remoteGUI` panes ARE culled outside
/// viewport+margin (freeing a `liveVideoCap` slot), and the viewport-membership signal is
/// intersection-only with no margin / no kind filter.
final class CanvasCullingTests: XCTestCase {
    private func pid(_ n: Int) -> PaneID {
        PaneID(raw: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!)
    }

    private func item(_ n: Int, _ frame: CGRect, kind: PaneKind) -> CanvasItem {
        CanvasItem(id: pid(n), spec: PaneSpec(kind: kind, title: "p\(n)"), frame: frame, z: n)
    }

    private let viewport = CGSize(width: 1000, height: 800)
    private let onScreen = CGRect(x: 100, y: 100, width: 300, height: 200)
    /// Far beyond viewport + cullMargin (600) so it is definitely culled when cullable.
    private let farOff = CGRect(x: 5000, y: 5000, width: 300, height: 200)

    func testTerminalsAreNeverCulled() {
        let items = [item(1, onScreen, kind: .terminal), item(2, farOff, kind: .terminal)]
        let visible = CanvasGeometry.visibleItems(items, camera: .zero, viewport: viewport, focused: nil)
        XCTAssertEqual(Set(visible.map(\.id)), [pid(1), pid(2)], "terminals stay mounted even far off-viewport")
    }

    func testClaudeCodeAlsoNeverCulled() {
        let items = [item(1, farOff, kind: .claudeCode)]
        let visible = CanvasGeometry.visibleItems(items, camera: .zero, viewport: viewport, focused: nil)
        XCTAssertEqual(visible.map(\.id), [pid(1)])
    }

    func testVideoCulledOffViewport() {
        let items = [item(1, onScreen, kind: .remoteGUI), item(2, farOff, kind: .remoteGUI)]
        let visible = CanvasGeometry.visibleItems(items, camera: .zero, viewport: viewport, focused: nil)
        XCTAssertEqual(visible.map(\.id), [pid(1)], "off-viewport video is culled; on-screen video kept")
    }

    func testFocusedVideoNeverCulled() {
        let items = [item(2, farOff, kind: .remoteGUI)]
        let visible = CanvasGeometry.visibleItems(items, camera: .zero, viewport: viewport, focused: pid(2))
        XCTAssertEqual(visible.map(\.id), [pid(2)], "the focused pane is never culled, even video far off")
    }

    func testVideoWithinMarginKept() {
        // Just outside the viewport but within cullMargin (600) → kept warm.
        let nearEdge = CGRect(x: 1000 + 100, y: 100, width: 300, height: 200) // 100pt past the right edge
        let items = [item(1, nearEdge, kind: .remoteGUI)]
        let visible = CanvasGeometry.visibleItems(items, camera: .zero, viewport: viewport, focused: nil)
        XCTAssertEqual(visible.map(\.id), [pid(1)], "within cullMargin → still mounted")
    }

    func testViewportMembersIntersectionOnly() {
        let items = [
            item(1, onScreen, kind: .terminal), // intersects
            item(2, farOff, kind: .terminal), // does not
            item(
                3,
                CGRect(x: 1000 + 100, y: 100, width: 300, height: 200),
                kind: .remoteGUI,
            ), // within margin but NOT viewport
        ]
        let members = CanvasGeometry.viewportMembers(items, camera: .zero, viewport: viewport)
        XCTAssertEqual(members, [pid(1)], "membership is strict viewport intersection — no margin, no kind filter")
    }

    func testViewportMembersFollowCamera() {
        let items = [item(1, CGRect(x: 2000, y: 0, width: 300, height: 200), kind: .terminal)]
        // Not visible at origin…
        XCTAssertTrue(CanvasGeometry.viewportMembers(items, camera: .zero, viewport: viewport).isEmpty)
        // …but visible once the camera pans to it.
        let panned = CanvasCamera(origin: CGPoint(x: 1900, y: 0))
        XCTAssertEqual(CanvasGeometry.viewportMembers(items, camera: panned, viewport: viewport), [pid(1)])
    }
}
