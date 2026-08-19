// StatusMarkShapeTests — the SwiftUI renderer's own geometry, where the drawing IS the assertion.
//
// Every VALUE behind the mark is pinned one floor down (`SlopDeskSlateTests/StatusDotTests`): the
// footprint, the ring's diameter and dot count, the spinner's tempo and its closed-form integral.
// What can only be pinned HERE is what the `Shape` actually draws from them — a phase or radius slip
// produces a plausible ring that is subtly off its own column, and no value says so.

#if os(macOS)
import SlopDeskSlate
import SwiftUI
import XCTest
@testable import SlopDeskClientUI

final class StatusMarkShapeTests: XCTestCase {
    /// The dots ride ON the ring's circle at even turns from 12 o'clock, so the mark keeps the
    /// four-fold symmetry that makes eight small shapes read as one circle. Pinned through the
    /// `Shape` itself — the path IS the artwork, and a phase or radius slip draws a plausible ring
    /// that is subtly off its own column.
    func testTheRingDotsSitOnTheCircleStartingAtTwelveOClock() {
        let side = StatusDot.ringDiameter
        let box = CGRect(origin: .zero, size: CGSize(width: side, height: side))
        let bounds = DottedRing().path(in: box).boundingRect
        // Eight dots on a Ø10 circle, each spilling half its width outside it — exactly as the
        // stroke they replaced did, so the ring's visual diameter is unchanged.
        let spread = side + StatusDot.ringDotDiameter
        XCTAssertEqual(bounds.width, spread, accuracy: 0.001, "dots at 3 and 9 o'clock set the width")
        XCTAssertEqual(bounds.height, spread, accuracy: 0.001, "dots at 12 and 6 set the height")
        XCTAssertEqual(bounds.midX, box.midX, accuracy: 0.001, "the ring is centred in its box")
        XCTAssertEqual(bounds.midY, box.midY, accuracy: 0.001, "the ring is centred in its box")
    }
}
#endif
