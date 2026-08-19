// SimulatorBezelFitTests — the bezel's one layout compensation.
//
// Everything about ORIENTATION itself — the wire spellings, which quarter-turn each value is, which
// two are landscape — is pinned in `SimulatorChromeTests`. What is left here is the part that exists
// only because of how a rendering framework treats a rotation.
//
// IT MOVED DOWN IN docs/56 INCREMENT 52, with the fold it tests. The compensation is not a SwiftUI
// fact: `rotationEffect` does not change layout, and neither does a `CATransform3DRotate` on a
// layer's frame, so BOTH renderers have to fit a quarter-turned phone against swapped bounds. Left in
// the SwiftUI half's test target it would have pinned one of the two and passed while the other
// sized a landscape iPad to a portrait width.

import SlopDeskDevicePanels
import XCTest

final class SimulatorBezelFitTests: XCTestCase {
    func testATurnedDeviceIsFittedAgainstSwappedBoundsSoItDoesNotOverflowTheSidebar() {
        // Fitting a quarter-turned phone against the panel's real bounds sizes it to a width it will
        // never occupy — the rotation is drawn, not laid out.
        let bounds = CGSize(width: 300, height: 900)
        XCTAssertEqual(SimulatorPresentation.footprint(bounds, turned: false), bounds)
        XCTAssertEqual(
            SimulatorPresentation.footprint(bounds, turned: true), CGSize(width: 900, height: 300),
        )
    }
}
