import XCTest
@testable import SlopDeskVideoHost

/// Pins the swipe-back flick recogniser: WHAT fires (short, decisively horizontal, completed
/// on-glass gestures), what must NEVER fire (vertical/diagonal pans, slow drags, momentum,
/// wheel notches, cancelled gestures), and the ⌘[ / ⌘] app allowlist policy.
final class SwipeNavRecognizerTests: XCTestCase {
    /// Drives a whole gesture through the recogniser: began at `t0`, `changed` deltas 8 ms apart,
    /// ended at `endedAt` (default = right after the last changed). Returns the ended verdict.
    private func run(
        deltas: [(dx: Double, dy: Double)],
        t0: TimeInterval = 100,
        endedAt: TimeInterval? = nil,
        continuous: Bool = true,
    ) -> SwipeNavRecognizer.Direction? {
        var rec = SwipeNavRecognizer()
        XCTAssertNil(rec.ingest(dx: 2, dy: 0, scrollPhase: 1, momentumPhase: 0, continuous: continuous, now: t0))
        var t = t0
        for d in deltas {
            t += 0.008
            XCTAssertNil(rec.ingest(
                dx: d.dx, dy: d.dy, scrollPhase: 2, momentumPhase: 0, continuous: continuous, now: t,
            ))
        }
        return rec.ingest(
            dx: 0, dy: 0, scrollPhase: 4, momentumPhase: 0, continuous: continuous, now: endedAt ?? t + 0.008,
        )
    }

    func testCrispRightwardFlickFiresBack() {
        // Fingers move right (natural scrolling) → history BACK.
        XCTAssertEqual(run(deltas: Array(repeating: (dx: 30.0, dy: 1.0), count: 8)), .back)
    }

    func testCrispLeftwardFlickFiresForward() {
        XCTAssertEqual(run(deltas: Array(repeating: (dx: -30.0, dy: -1.0), count: 8)), .forward)
    }

    func testVerticalScrollNeverFires() {
        XCTAssertNil(run(deltas: Array(repeating: (dx: 0.0, dy: 40.0), count: 10)))
    }

    func testDiagonalPanNeverFires() {
        // |ΣX| = 240 clears travel, but |ΣY| = 100 breaks the 3× dominance requirement.
        XCTAssertNil(run(deltas: Array(repeating: (dx: 30.0, dy: 12.5), count: 8)))
    }

    func testSlowHorizontalDragNeverFires() {
        // Plenty of travel, decisively horizontal — but 0.6 s from began to ended is a content
        // pan (spreadsheet / wide code), not a navigation flick.
        XCTAssertNil(run(deltas: Array(repeating: (dx: 30.0, dy: 0.0), count: 8), t0: 100, endedAt: 100.6))
    }

    func testShortTravelNeverFires() {
        XCTAssertNil(run(deltas: Array(repeating: (dx: 10.0, dy: 0.0), count: 8))) // Σ=82 < 120
    }

    func testBoundaryTravelAndDominanceFire() {
        // Σdx = 2 (began) + 118 = 120 exactly; Σdy = 40 → dominance exactly 3×. `>=` on both.
        XCTAssertEqual(run(deltas: [(dx: 118.0, dy: 40.0)]), .back)
    }

    func testWheelNotchStreamNeverFires() {
        // A classic wheel carries phase 0 / momentum 0 — no began ever arrives.
        var rec = SwipeNavRecognizer()
        for i in 0..<20 {
            XCTAssertNil(rec.ingest(
                dx: 40, dy: 0, scrollPhase: 0, momentumPhase: 0, continuous: false, now: 100 + Double(i) * 0.008,
            ))
        }
    }

    func testNonContinuousGestureNeverFires() {
        XCTAssertNil(run(deltas: Array(repeating: (dx: 30.0, dy: 0.0), count: 8), continuous: false))
    }

    func testMomentumNeverInitiatesOrFinishes() {
        var rec = SwipeNavRecognizer()
        // Momentum-only stream (fingers lifted after a pan in some earlier session state).
        XCTAssertNil(rec.ingest(dx: 60, dy: 0, scrollPhase: 0, momentumPhase: 1, continuous: true, now: 100))
        XCTAssertNil(rec.ingest(dx: 60, dy: 0, scrollPhase: 0, momentumPhase: 2, continuous: true, now: 100.01))
        XCTAssertNil(rec.ingest(dx: 0, dy: 0, scrollPhase: 0, momentumPhase: 3, continuous: true, now: 100.02))
        // And momentum arriving MID-candidate contributes nothing to the sums.
        XCTAssertNil(rec.ingest(dx: 2, dy: 0, scrollPhase: 1, momentumPhase: 0, continuous: true, now: 101))
        XCTAssertNil(rec.ingest(dx: 500, dy: 0, scrollPhase: 0, momentumPhase: 2, continuous: true, now: 101.01))
        XCTAssertNil(rec.ingest(dx: 10, dy: 0, scrollPhase: 4, momentumPhase: 0, continuous: true, now: 101.02))
    }

    func testCancelledGestureNeverFires() {
        var rec = SwipeNavRecognizer()
        XCTAssertNil(rec.ingest(dx: 2, dy: 0, scrollPhase: 1, momentumPhase: 0, continuous: true, now: 100))
        XCTAssertNil(rec.ingest(dx: 200, dy: 0, scrollPhase: 2, momentumPhase: 0, continuous: true, now: 100.05))
        XCTAssertNil(rec.ingest(dx: 0, dy: 0, scrollPhase: 8, momentumPhase: 0, continuous: true, now: 100.1))
        // The abandoned accumulation must not leak into a later ended without a fresh began.
        XCTAssertNil(rec.ingest(dx: 0, dy: 0, scrollPhase: 4, momentumPhase: 0, continuous: true, now: 100.2))
    }

    func testEndedWithoutBeganNeverFires() {
        var rec = SwipeNavRecognizer()
        XCTAssertNil(rec.ingest(dx: 300, dy: 0, scrollPhase: 4, momentumPhase: 0, continuous: true, now: 100))
    }

    func testOneFirePerGesture() {
        var rec = SwipeNavRecognizer()
        XCTAssertNil(rec.ingest(dx: 2, dy: 0, scrollPhase: 1, momentumPhase: 0, continuous: true, now: 100))
        XCTAssertNil(rec.ingest(dx: 200, dy: 0, scrollPhase: 2, momentumPhase: 0, continuous: true, now: 100.05))
        XCTAssertEqual(
            rec.ingest(dx: 0, dy: 0, scrollPhase: 4, momentumPhase: 0, continuous: true, now: 100.1),
            .back,
        )
        // A duplicate/stray ended (raw UDP duplication/reordering on the fire-and-forget input
        // channel — the client sends each scroll exactly once; only mouse-ups and modifier
        // key-ups are re-sent, and those never reach this recognizer) must not re-fire.
        XCTAssertNil(rec.ingest(dx: 0, dy: 0, scrollPhase: 4, momentumPhase: 0, continuous: true, now: 100.11))
    }

    func testFreshBeganResetsAccumulation() {
        var rec = SwipeNavRecognizer()
        XCTAssertNil(rec.ingest(dx: 2, dy: 0, scrollPhase: 1, momentumPhase: 0, continuous: true, now: 100))
        XCTAssertNil(rec.ingest(dx: 300, dy: 0, scrollPhase: 2, momentumPhase: 0, continuous: true, now: 100.05))
        // New gesture begins — the 300 pt from the abandoned one must be gone.
        XCTAssertNil(rec.ingest(dx: 2, dy: 0, scrollPhase: 1, momentumPhase: 0, continuous: true, now: 101))
        XCTAssertNil(rec.ingest(dx: 10, dy: 0, scrollPhase: 2, momentumPhase: 0, continuous: true, now: 101.01))
        XCTAssertNil(rec.ingest(dx: 0, dy: 0, scrollPhase: 4, momentumPhase: 0, continuous: true, now: 101.02))
    }

    // MARK: Allowlist policy

    func testKnownBrowsersAndFinderAreNavigable() {
        for id in ["com.apple.Safari", "com.google.Chrome", "org.mozilla.firefox", "com.apple.finder"] {
            XCTAssertTrue(SwipeNavPolicy.isNavigable(bundleID: id), id)
        }
    }

    func testUnknownAndNilAppsAreNotNavigable() {
        XCTAssertFalse(SwipeNavPolicy.isNavigable(bundleID: "com.microsoft.VSCode")) // ⌘[ = outdent!
        XCTAssertFalse(SwipeNavPolicy.isNavigable(bundleID: "com.apple.dt.Xcode"))
        XCTAssertFalse(SwipeNavPolicy.isNavigable(bundleID: nil))
    }

    func testExtraAppsParseAndExtend() {
        let extras = SwipeNavPolicy.extraApps(from: " com.example.One , com.example.Two,,")
        XCTAssertEqual(extras, ["com.example.One", "com.example.Two"])
        XCTAssertTrue(SwipeNavPolicy.isNavigable(bundleID: "com.example.One", extraApps: extras))
        XCTAssertFalse(SwipeNavPolicy.isNavigable(bundleID: "com.example.Three", extraApps: extras))
        XCTAssertEqual(SwipeNavPolicy.extraApps(from: nil), [])
    }
}
