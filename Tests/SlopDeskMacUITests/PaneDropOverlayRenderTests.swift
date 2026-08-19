// PaneDropOverlayRenderTests proves the AppKit drop chrome (docs/56 wave R, batch R7) keeps the
// promises its SwiftUI half makes with a modifier and a compiler cannot check.
//
// 1. THE OVERLAY IS TOP-LEFT. `PaneDropZoneLayout` answers in the CG convention Rust's
//    `slopdesk_drop_zone_shape` is written in — origin top-left, y down. An unflipped `NSView` would
//    place New Tab at the BOTTOM of the pane and nothing would fail: it would compile, run, hit-test
//    consistently with itself, and be upside down. The order of the central column is the pin.
//
// 2. THE SIDE ELLIPSES SPILL, AND THE PANE CLIPS THEM. Split Left / Split Right are centred ON the
//    pane edge, so half of each blob is outside the bounds; the visible half-circle exists only
//    because the overlay masks. Their LABELS must not spill with them — `labelCenter` insets them
//    back inside, and a renderer that centred the label on the blob would push half the word
//    off-pane.
//
// 3. IT IS TRANSPARENT TO THE POINTER. A drop overlay is decoration; the thing that takes the drag
//    is the receiver, an ancestor. An overlay that answered `hitTest` with itself would eat the tap
//    that focuses the pane.
//
// 4. IT IS FADED, NEVER HIDDEN (docs/56 risk 3). A hidden subtree does not run `layout()`, and every
//    blob in this view is placed from its own bounds.
//
// 5. THE WORDING IS THE FLOOR'S. `DropZonePresentation.label` is what the phone reads too; a Mac
//    that spelled "Open in place" its own way is the drift the presentation type was extracted to
//    stop.
//
// 6. THE RECEIVER REGISTERS THE GATE'S LIST. `PaneDropGate.acceptedTypes` is the one list the
//    registration and the validate query must both ask about — two lists is how a drag is advertised
//    as acceptable and then declined.
//
// Headless: an `NSView`'s frame, layer and `hitTest` need no window (the hang-safety rule forbids an
// `NSWindow` in a test), so nothing here mounts one.

#if os(macOS)
import AppKit
import SlopDeskClientCore
import SlopDeskWorkspaceModel
import UniformTypeIdentifiers
import XCTest
@testable import SlopDeskMacUI
@testable import SlopDeskWorkspaceCore

@MainActor
final class PaneDropOverlayRenderTests: XCTestCase {
    /// A pane-sized box. Wide enough that the two edge ellipses and the central column cannot
    /// degenerate into each other.
    private let pane = NSRect(x: 0, y: 0, width: 600, height: 400)

    private func makeOverlay(dragging: Bool) -> MacPaneDropOverlay {
        let model = PaneDropOverlayModel()
        // Set BEFORE the view is built: the first observation read is the one that lands unanimated,
        // which is what makes the alpha below readable without waiting on a runloop turn.
        if dragging { model.content = .folder("/tmp") }
        let overlay = MacPaneDropOverlay(model: model)
        overlay.frame = pane
        overlay.layoutSubtreeIfNeeded()
        return overlay
    }

    private func part(_ kind: String, _ zone: DropZone, in overlay: NSView) -> NSView? {
        overlay.subviews.first { $0.identifier?.rawValue == "drop.\(kind).\(zone.rawValue)" }
    }

    func testTheCentralColumnRunsTopToBottom() {
        let overlay = makeOverlay(dragging: true)
        XCTAssertTrue(overlay.isFlipped, "the drop layout is top-left origin — an unflipped overlay is upside down")
        guard let newTab = part("blob", .newTab, in: overlay),
              let insert = part("blob", .insertPath, in: overlay),
              let inPlace = part("blob", .openInPlace, in: overlay)
        else {
            XCTFail("the central column is not three blobs")
            return
        }
        XCTAssertLessThan(
            newTab.frame.midY, insert.frame.midY,
            "New Tab must sit ABOVE Insert Path — the overlay is reading the layout bottom-up",
        )
        XCTAssertLessThan(
            insert.frame.midY, inPlace.frame.midY,
            "Insert Path must sit ABOVE Open In-Place — the overlay is reading the layout bottom-up",
        )
    }

    func testTheEdgeEllipsesSpillAndThePaneClipsThem() {
        let overlay = makeOverlay(dragging: true)
        guard let left = part("blob", .splitLeft, in: overlay),
              let right = part("blob", .splitRight, in: overlay)
        else {
            XCTFail("the two edge ellipses are missing")
            return
        }
        XCTAssertLessThan(left.frame.minX, 0, "Split Left no longer hugs the edge — its off-pane half is gone")
        XCTAssertGreaterThan(
            right.frame.maxX, pane.width,
            "Split Right no longer hugs the edge — its off-pane half is gone",
        )
        XCTAssertEqual(
            overlay.layer?.masksToBounds, true,
            "the overlay stopped clipping — the edge ellipses spill over the pane's neighbours",
        )
    }

    func testTheEdgeLabelsStayOnThePane() {
        // The label's centre is `DropZonePresentation.labelCenter`'s, NOT the blob's: the blob's
        // centre is ON the pane edge, so a label centred there would be half clipped away.
        let overlay = makeOverlay(dragging: true)
        for zone in [DropZone.splitLeft, .splitRight] {
            guard let label = part("label", zone, in: overlay) else {
                XCTFail("\(zone.rawValue) has no label")
                return
            }
            XCTAssertGreaterThanOrEqual(
                label.frame.minX, 0, "\(zone.rawValue)'s label runs off the leading edge",
            )
            XCTAssertLessThanOrEqual(
                label.frame.maxX, pane.width, "\(zone.rawValue)'s label runs off the trailing edge",
            )
        }
    }

    func testEveryZoneIsDrawnAndWordedByTheFloor() {
        let overlay = makeOverlay(dragging: true)
        for zone in DropZone.allCases {
            XCTAssertNotNil(part("blob", zone, in: overlay), "\(zone.rawValue) has no blob")
            guard let label = part("label", zone, in: overlay) as? NSTextField else {
                XCTFail("\(zone.rawValue) has no label")
                return
            }
            XCTAssertEqual(
                label.stringValue, DropZonePresentation.label(zone),
                "\(zone.rawValue) is worded by the renderer instead of by DropZonePresentation",
            )
        }
    }

    func testTheOverlayIsTransparentToThePointer() {
        let overlay = makeOverlay(dragging: true)
        guard let insert = part("blob", .insertPath, in: overlay) else {
            XCTFail("the centre blob is missing")
            return
        }
        XCTAssertNil(
            overlay.hitTest(NSPoint(x: insert.frame.midX, y: insert.frame.midY)),
            "a click on the drop overlay must reach the pane under it — the overlay is decoration",
        )
    }

    func testTheOverlayIsFadedRatherThanHidden() {
        let resting = makeOverlay(dragging: false)
        XCTAssertEqual(resting.alphaValue, 0, "the overlay is visible with no drag over the pane")
        XCTAssertFalse(
            resting.isHidden,
            "the overlay was hidden rather than faded — a hidden subtree never runs layout(), so the blobs go stale",
        )
        XCTAssertEqual(makeOverlay(dragging: true).alphaValue, 1, "a supported drag did not raise the overlay")
    }

    // MARK: - The receiver

    private func makeReceiver() -> MacPaneDropReceiver {
        let store = WorkspaceStore(makeSession: { seed in MountTestPaneSession(seed.spec) })
        store.attachLoopbackWorkspaceDocument()
        return MacPaneDropReceiver(
            paneID: PaneID(),
            model: PaneDropOverlayModel(),
            store: store,
            terminalModel: { nil },
            overlayCoordinator: nil,
        )
    }

    func testTheReceiverRegistersExactlyTheGatesTypes() {
        XCTAssertEqual(
            makeReceiver().registeredDraggedTypes.map(\.rawValue),
            PaneDropGate.acceptedTypes.map(\.identifier),
            "the registration drifted from PaneDropGate.acceptedTypes — a drag is advertised and then declined",
        )
    }

    func testTheReceiverSharesTheOverlaysCoordinateSpace() {
        XCTAssertTrue(
            makeReceiver().isFlipped,
            "the receiver hit-tests draggingLocation against the top-left layout — unflipped, draw != hit",
        )
    }

    func testTheMountedContentSitsUnderTheOverlay() {
        let receiver = makeReceiver()
        receiver.mount(NSView())
        XCTAssertTrue(
            receiver.subviews.last is MacPaneDropOverlay,
            "the pane content was mounted OVER the drop overlay — the blobs would be invisible",
        )
    }
}
#endif
