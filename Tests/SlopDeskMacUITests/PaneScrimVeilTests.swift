// PaneScrimVeilTests proves the two AppKit pane veils (docs/56 wave R, batch R1) keep the two
// promises their SwiftUI halves make and a compiler cannot check.
//
// 1. THEY ARE TRANSPARENT TO THE POINTER. A ⌃⇥ walk is abandoned by clicking the pane you can see
//    under the veil; a scrim that answered `hitTest` with itself would eat that click and the walk
//    would have no escape but the keyboard. `.allowsHitTesting(false)` is one modifier in SwiftUI
//    and an override here, which is exactly the kind of promise that survives a port by luck.
//
// 2. THE TWO ARE NOT THE SAME VEIL. They cover the same rectangle and mean opposite things — one
//    hides a surface whose pixels are briefly wrong, the other keeps a surface legible while marking
//    it as not-the-subject. The only thing distinguishing them is the rung each is drawn at, so a
//    port that reached for the nearer token would compile, run, and read as "the walk stopped
//    dimming". This pins that they DIFFER, and that the recede rung is the lighter of the two.
//
// Headless: an `NSView`'s layer and `hitTest` need no window (the hang-safety rule forbids an
// `NSWindow` in a test), so nothing here mounts one.

#if os(macOS)
import AppKit
import SlopDeskSlate
import XCTest
@testable import SlopDeskMacUI

@MainActor
final class PaneScrimVeilTests: XCTestCase {
    func testBothVeilsAreTransparentToThePointer() {
        for (name, veil) in [("resize", MacPaneVeil.resize()), ("recede", MacPaneVeil.recede())] {
            veil.frame = NSRect(x: 0, y: 0, width: 200, height: 120)
            XCTAssertNil(
                veil.hitTest(NSPoint(x: 100, y: 60)),
                "a click in the middle of the \(name) veil must reach the pane under it — a walk is abandoned by clicking",
            )
        }
    }

    func testTheTwoVeilsAreDrawnAtDifferentRungs() {
        // Read through the layer, which is what actually ships — asserting the tokens against each
        // other would pass while both factories drew the same one.
        let resize = MacPaneVeil.resize()
        let recede = MacPaneVeil.recede()
        let resizeAlpha = resize.layer?.backgroundColor?.alpha
        let recedeAlpha = recede.layer?.backgroundColor?.alpha
        XCTAssertNotNil(resizeAlpha, "the resize scrim never painted its layer")
        XCTAssertNotNil(recedeAlpha, "the recede scrim never painted its layer")
        XCTAssertNotEqual(
            resizeAlpha, recedeAlpha,
            "both scrims are drawn at one rung — the walk's dimming and a resize haze are not the same veil",
        )
    }

    func testTheRecedeRungLeavesThePaneReadable() {
        // The walk's veil must subtract LESS than the backdrop a readout stands on, or a dimmed pane
        // stops being something you can look at and the walk is a jump between blanks. Pinned against
        // `scrim` rather than as a bare number so the rung can be re-measured without editing a test.
        XCTAssertLessThan(
            Slate.Opacity.recede, Slate.Opacity.scrim,
            "the recede veil has reached backdrop strength — a receded pane must stay readable",
        )
        XCTAssertGreaterThan(
            Slate.Opacity.recede, Slate.Opacity.muted,
            "the recede veil no longer separates the subject pane from the rest of the walk",
        )
    }
}
#endif
