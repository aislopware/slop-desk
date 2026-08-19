// PaneGrabPillTests — what the AppKit grab pill (docs/56 wave R, batch R8) promises that a compiler
// cannot check.
//
// 1. THE PILL IS THE FLOOR'S SIZE. ``Slate/GrabPill/stripWidth(forLeafWidth:)`` is asked by three
//    drawings, and two of them are compared inside a SINGLE drag: merging a detached pane home means
//    grabbing the satellite window's pill, crossing into the main window and releasing on the leaf whose
//    own pill you were aiming at. A port that reached for `0.4 * width` by hand would compile, run, and
//    read as the thing in the user's hand changing size — so the clamp ends are pinned against the
//    function itself rather than against numbers copied out of it.
// 2. ONLY THE TOP STRIP IS HIT-TESTABLE. The handle FILLS its leaf and lets everything below the strip
//    through to the terminal. In SwiftUI that was a `Spacer`; here it is one `hitTest` override, which
//    is exactly the kind of promise a port keeps by luck. A handle that answered for its whole leaf
//    would make the top of every pane un-clickable, and nothing on screen would say why.
// 3. A NON-INTERACTIVE TAB TRACKS NO HOVER. docs/56 risk 3: an `NSTrackingArea` is rect-based and keeps
//    firing under a subtree at `alphaValue = 0`, so a hidden tab's pills would reveal over the visible
//    tab's panes — invisibly, at the place it goes wrong. The gate is a predicate for exactly this
//    reason, and this is the only way to ask it without a window.
// 4. ESCAPE IS BALANCED, AND STICKY. A local `.keyDown` monitor left installed after a drag swallows
//    Escape for the WHOLE APP with no crash and no log; and a cancel that un-cancels on the next mouse
//    tremor is worse than no cancel, because the user has stopped watching. Both are counted through
//    the controller's injected seams — no real monitor is installed, which is also what makes the count
//    possible.
//
// Headless: `hitTest`, `layout()`, a layer and a tracking-area predicate all need no window, and the
// hang-safety rule forbids an `NSWindow` in a test — so nothing here mounts one. The gesture is driven
// through the handle's point-level seam rather than through synthesised `NSEvent`s, for the reason
// ``PaneMoveEscapeMonitorController`` injects its own: the event object is not what any of this decides
// on.

#if os(macOS)
import AppKit
import SlopDeskClientCore
import SlopDeskSlate
import SlopDeskWorkspaceModel
import XCTest
@testable import SlopDeskMacUI

@MainActor
final class PaneGrabPillTests: XCTestCase {
    /// Escape's hardware code, reached through the real FFI by the controller's own reader — the same
    /// number `PaneMoveEscapeMonitorControllerTests` pins one floor down.
    private let keyEscape: UInt16 = 53

    // MARK: The pill's size is the floor's

    /// Both clamp ends and the share between them, asked of the handle and of the floor. A leaf narrow
    /// enough to resolve under the floor keeps a GRABBABLE pill rather than a proportionally honest one;
    /// a leaf wide enough to resolve over the ceiling stops growing, which is where the satellite
    /// window's strip already sits.
    func testTheStripWidthIsTheFloorsAtBothClampEndsAndBetween() {
        let handle = makeHandle()
        // Narrow (under the floor), mid (the share applies), wide (over the ceiling).
        for width in [40.0, 120.0, 300.0, 2000.0] as [CGFloat] {
            handle.frame = NSRect(x: 0, y: 0, width: width, height: 400)
            XCTAssertEqual(
                handle.stripFrame.width, Slate.GrabPill.stripWidth(forLeafWidth: width),
                "the AppKit pill stopped agreeing with the satellite window's at leaf width \(width)",
            )
        }
    }

    /// Centred, and flush to the leaf's TOP edge. The strip's whole placement argument is that it sits
    /// inside the pane's own top padding band rather than over the first line of terminal text.
    func testTheStripIsCentredOnTheLeafsTopEdge() {
        let handle = makeHandle()
        handle.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        let strip = handle.stripFrame
        XCTAssertEqual(strip.midX, handle.bounds.midX, accuracy: 0.001)
        XCTAssertEqual(strip.minY, 0, "the strip left the leaf's top edge")
        XCTAssertEqual(strip.height, Slate.GrabPill.stripHeight)
    }

    // MARK: The hit footprint

    func testOnlyTheTopStripIsHitTestable() {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let handle = makeHandle()
        handle.frame = host.bounds
        host.addSubview(handle)
        // The point arrives in the HOST's coordinates, which are bottom-left; the handle is flipped, so
        // its top strip lives at the host's high y.
        let strip = handle.stripFrame
        XCTAssertIdentical(
            handle.hitTest(NSPoint(x: strip.midX, y: host.bounds.maxY - strip.midY)), handle,
            "the grab strip stopped answering the pointer — the pane can no longer be moved",
        )
        XCTAssertNil(
            handle.hitTest(NSPoint(x: host.bounds.midX, y: host.bounds.midY)),
            "the handle claimed the middle of its leaf — every click there stops reaching the terminal",
        )
        XCTAssertNil(
            handle.hitTest(NSPoint(x: 2, y: host.bounds.maxY - 2)),
            "the handle claimed the leaf's top CORNER — the strip is short and centred, not full-width",
        )
    }

    /// A hidden tab's handle answers nothing, the way its SwiftUI half was `.allowsHitTesting(false)`.
    func testANonInteractiveHandleIsTransparentToThePointer() {
        let handle = makeHandle()
        handle.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        handle.isInteractive = false
        XCTAssertNil(
            handle.hitTest(NSPoint(x: 200, y: 4)),
            "a hidden tab's grab strip is still taking clicks over the visible tab's pane",
        )
    }

    // MARK: docs/56 risk 3 — the tracking area

    /// The one rule in the port whose failure is invisible where it happens: a tracking area under a
    /// hidden tab fires over the VISIBLE tab's panes. All three conditions have to hold.
    func testHoverIsTrackedOnlyForAMountedInteractiveLeaf() {
        XCTAssertTrue(
            MacPaneMoveHandle.tracksHover(interactive: true, hidden: false, hasWindow: true),
        )
        XCTAssertFalse(
            MacPaneMoveHandle.tracksHover(interactive: false, hidden: false, hasWindow: true),
            "a hidden tab's pill reveals on hover — at alpha 0, over the tab the user is looking at",
        )
        XCTAssertFalse(
            MacPaneMoveHandle.tracksHover(interactive: true, hidden: true, hasWindow: true),
            "a zoom-collapsed leaf still tracks the pointer",
        )
        XCTAssertFalse(
            MacPaneMoveHandle.tracksHover(interactive: true, hidden: false, hasWindow: false),
            "an unmounted handle installed a tracking area with nothing to track in",
        )
    }

    /// No window, so no area — and, crucially, no DUPLICATE either. AppKit calls `updateTrackingAreas`
    /// on every frame change, and an add without the matching remove leaves one live area per resize.
    func testUpdatingTrackingAreasNeverAccumulatesThem() {
        let handle = makeHandle()
        handle.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        for _ in 0..<8 { handle.updateTrackingAreas() }
        XCTAssertLessThanOrEqual(handle.trackingAreas.count, 1)
    }

    // MARK: The reveal

    /// At rest the pill is NOT there. It is a hover affordance; a pill that shipped revealed would be
    /// permanent chrome sitting on the top line of every pane in the app.
    func testTheRestingPillIsInvisible() {
        let handle = makeHandle()
        handle.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        handle.needsLayout = true
        handle.layoutSubtreeIfNeeded()
        XCTAssertFalse(handle.subviews.isEmpty, "the handle drew no pill at all")
        for pill in handle.subviews {
            XCTAssertEqual(pill.alphaValue, 0, "the grab pill is visible with no pointer over it")
        }
    }

    // MARK: Escape — the balance, and the stickiness

    /// A drag that is torn out mid-flight (the pane closed while the button was down) still disarms
    /// Escape and still tells its owner the move is over. Neither is optional: a monitor left behind
    /// swallows Escape app-wide, and a drag never reported as ended wedges every OTHER pill dead.
    func testATornOutDragDisarmsEscapeAndReportsTheInterruption() {
        let probe = EscapeProbe()
        var interruptions = 0
        let handle = makeHandle(escape: probe.make(), onInterrupted: { _ in interruptions += 1 })
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        handle.frame = host.bounds
        host.addSubview(handle)

        handle.press(at: .zero)
        handle.dragged(to: CGPoint(x: 60, y: 60))
        XCTAssertEqual(probe.installs, 1, "a live drag has no cancel key")

        handle.removeFromSuperview()
        XCTAssertEqual(probe.removes, 1, "the monitor outlived the drag — Escape is now dead app-wide")
        XCTAssertEqual(interruptions, 1, "a drag torn out mid-flight was never reported as over")
    }

    /// A press that never travels is a TAP (it focuses the pane), and it arms nothing — the top strip is
    /// not a focus dead-zone, and a click is not a move.
    func testAPressBelowTheSlopIsATapAndArmsNothing() {
        let probe = EscapeProbe()
        var taps = 0
        var frames = 0
        let handle = makeHandle(
            escape: probe.make(), onChanged: { _, _ in frames += 1 }, onTap: { _ in taps += 1 },
        )
        handle.press(at: .zero)
        handle.dragged(to: CGPoint(x: 1, y: 1))
        handle.released(at: CGPoint(x: 1, y: 1))
        XCTAssertEqual(frames, 0, "a one-pixel tremor published a pane move")
        XCTAssertEqual(taps, 1, "the strip stopped focusing the pane on a plain click")
        XCTAssertEqual(probe.installs, 0, "a click armed the drag's cancel key")
    }

    /// ESCAPE IS STICKY UNTIL THE RELEASE, and this is the one place the port deliberately differs from
    /// its SwiftUI half. There, Escape cleared the drag state while the gesture kept running, so the
    /// next mouse movement published a fresh drag and the release committed the very landing the user
    /// had just bailed out of. Here the gesture absorbs everything left of itself.
    func testEscapeEndsTheDragAndNothingAfterItIsReported() {
        let probe = EscapeProbe()
        var interruptions = 0
        var frames = 0
        var commits = 0
        var taps = 0
        let handle = makeHandle(
            escape: probe.make(),
            onChanged: { _, _ in frames += 1 },
            onEnded: { _, _ in commits += 1 },
            onTap: { _ in taps += 1 },
            onInterrupted: { _ in interruptions += 1 },
        )
        handle.press(at: .zero)
        handle.dragged(to: CGPoint(x: 60, y: 60))
        XCTAssertEqual(frames, 1)

        // The real path: the controller's own reader, on the key the crate names.
        XCTAssertEqual(probe.reader?(keyEscape), true, "Escape was not read, or was not swallowed")
        XCTAssertEqual(interruptions, 1)
        XCTAssertEqual(probe.removes, 1, "the cancel left its own monitor installed")

        // The button is still down. Everything from here commits nothing.
        handle.dragged(to: CGPoint(x: 120, y: 120))
        handle.released(at: CGPoint(x: 120, y: 120))
        XCTAssertEqual(frames, 1, "a cancelled drag resumed on the next mouse move")
        XCTAssertEqual(commits, 0, "a cancelled drag committed its landing anyway")
        XCTAssertEqual(taps, 0, "a cancelled drag's release was mistaken for a click")
    }

    // MARK: The overlay

    /// Purely visual, all the way down. A live drag's events belong to the handle that captured the
    /// mouse, and a decoration that answered a hit test would end the gesture it exists to describe.
    func testTheDragOverlayIsTransparentToThePointer() {
        let overlay = MacPaneMoveOverlay()
        overlay.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        overlay.show(
            drag: PaneMoveDrag(source: PaneID(), location: CGPoint(x: 400, y: 300), zone: .none),
            frames: [:], container: overlay.bounds, sourceTitle: nil,
        )
        XCTAssertNil(overlay.hitTest(NSPoint(x: 400, y: 300)))
    }

    /// The three zone previews land on ``PaneDropGeometry``'s rectangles and not on rectangles of their
    /// own. The preview and the commit are two halves of one round trip: a renderer that placed the rail
    /// by eye would promise a full-span column at a size the tree op does not make.
    func testTheDockRailIsDrawnAtTheSharedGeometrysRect() {
        let container = CGRect(x: 0, y: 0, width: 800, height: 600)
        for edge in PaneDropEdge.allCases {
            XCTAssertEqual(
                MacPaneMovePreview.rail(in: container, edge: edge).frame,
                PaneDropGeometry.railRect(in: container, edge: edge),
                "the \(edge.rawValue) dock preview drifted from the geometry the drop resolves through",
            )
        }
    }

    // MARK: -

    private func makeHandle(
        escape: PaneMoveEscapeMonitorController = PaneMoveEscapeMonitorController(),
        onChanged: @escaping (PaneID, CGPoint) -> Void = { _, _ in },
        onEnded: @escaping (PaneID, CGPoint) -> Void = { _, _ in },
        onTap: @escaping (PaneID) -> Void = { _ in },
        onInterrupted: @escaping (PaneID) -> Void = { _ in },
    ) -> MacPaneMoveHandle {
        MacPaneMoveHandle(
            paneID: PaneID(), escape: escape, onChanged: onChanged, onEnded: onEnded, onTap: onTap,
            onInterrupted: onInterrupted,
        )
    }

    /// A counting stand-in for `NSEvent.addLocalMonitorForEvents` / `removeMonitor` — the same shape
    /// `PaneMoveEscapeMonitorControllerTests` uses, and for the same reason: a test that installed a
    /// real monitor would attach to the test runner's own keyDown stream and could count nothing.
    @MainActor
    private final class EscapeProbe {
        private(set) var installs = 0
        private(set) var removes = 0
        /// The per-event decision the last install was handed, so Escape can be delivered for real.
        private(set) var reader: PaneMoveEscapeMonitorController.KeyReader?

        func make() -> PaneMoveEscapeMonitorController {
            PaneMoveEscapeMonitorController(
                install: { reader in
                    self.reader = reader
                    self.installs += 1
                    return NSObject()
                },
                remove: { _ in self.removes += 1 },
            )
        }
    }
}
#endif
