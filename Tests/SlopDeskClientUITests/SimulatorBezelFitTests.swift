// SimulatorBezelFitTests — the bezel's one layout compensation.
//
// Everything about ORIENTATION itself — the wire spellings, which quarter-turn each value is, which
// two are landscape — is the panel's domain and is pinned in
// `SlopDeskDevicePanelsTests/SimulatorChromeTests`. What is left here is the part that exists only
// because of how the rendering framework treats a rotation, so it is pinned beside the view that
// applies it.

#if os(macOS)
import SlopDeskDevicePanels
import XCTest
@testable import SlopDeskClientUI

final class SimulatorBezelFitTests: XCTestCase {
    func testATurnedDeviceIsFittedAgainstSwappedBoundsSoItDoesNotOverflowTheSidebar() {
        // `rotationEffect` does not change layout, so fitting a quarter-turned phone against the
        // panel's real bounds sizes it to a width it will never occupy.
        let bounds = CGSize(width: 300, height: 900)
        XCTAssertEqual(SimulatorBezelView.footprint(bounds, turned: false), bounds)
        XCTAssertEqual(
            SimulatorBezelView.footprint(bounds, turned: true), CGSize(width: 900, height: 300),
        )
    }
}
#endif
