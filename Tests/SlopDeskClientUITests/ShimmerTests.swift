// ShimmerTests — pins the travelling highlight the GENERATING agent's row wears on its title. The
// effect is a mask over the row's own glyphs, so what can be asserted headlessly is its shape in
// time: a band that starts and ends dark (no flash at the wrap), one crest, a floor the title never
// drops below, and a width that lights a short title whole instead of slicing it. Where the band
// LANDS is the render's job (`SlateSnapshotRender.testRenderWorkingRowShimmer`).

import SwiftUI
import XCTest
@testable import SlopDeskClientUI

final class ShimmerTests: XCTestCase {
    /// The band closes: dark at both ends, exactly one full-strength crest, stops in order. A band
    /// that ended lit would put a hard edge at the wrap — a once-per-lap twitch, which is the thing
    /// a settled rail is never allowed (docs/DECISIONS.md round 19).
    func testTheBandClosesWithoutASeam() {
        let stops = Slate.Shimmer.stops
        XCTAssertEqual(stops.first?.color, .clear)
        XCTAssertEqual(stops.last?.color, .clear)
        XCTAssertEqual(stops.first?.location, 0)
        XCTAssertEqual(stops.last?.location, 1)
        XCTAssertEqual(stops.map(\.location), stops.map(\.location).sorted(), "stops run in order")
        let crests = stops.filter { $0.color == .white }
        XCTAssertEqual(crests.count, 1, "one crest per pass")
        XCTAssertEqual(crests.first?.location, 0.5, "…centred in the band")
        XCTAssertGreaterThan(stops.count, 3, "the band needs a ramp, not two edges")
    }

    /// ⚠️ The title never drops out of the reading. The floor exists because a working row must read
    /// BRIGHTER than a resting one at every instant of the lap — rendered at 0.55 the unlit title sat
    /// below the resting rows' secondary ink, so for most of every pass the row doing the work looked
    /// asleep and the sleeping ones looked awake.
    func testTheTitleNeverDropsOutOfTheReading() {
        XCTAssertGreaterThan(Slate.Shimmer.base, 0.6, "the unlit title stays above the resting ink")
        XCTAssertLessThan(Slate.Shimmer.base, 1, "…and the band has somewhere to brighten TO")
        XCTAssertGreaterThan(Slate.Shimmer.period, 0)
    }

    /// ⚠️ The band is a FRACTION of the run, never the whole of it. Shipped first at 0.45 with a
    /// 60pt floor, which on the rail's short titles (a project name, a bare `api`) covered the run
    /// end to end — so the title blinked on and off instead of being swept, and the wrap read as a
    /// jerk back to the head rather than a band leaving.
    func testTheBandNeverCoversTheWholeRun() {
        for width: CGFloat in [24, 40, 80, 160, 400] {
            let band = Slate.Shimmer.bandWidth(for: width)
            XCTAssertGreaterThan(band, 0)
            XCTAssertLessThan(
                band, width, "a band as wide as the run is a blink, not a sweep (run \(width))",
            )
        }
        XCTAssertEqual(Slate.Shimmer.bandWidth(for: 400), 400 * Slate.Shimmer.widthFraction)
        XCTAssertEqual(
            Slate.Shimmer.bandWidth(for: 20), Slate.Shimmer.minimumWidth,
            "below the floor the band is the floor — the ramp stays a ramp",
        )
    }

    /// ⚠️⚠️ The pass's two ENDPOINTS must differ, and the travel must be monotonic. SwiftUI animates
    /// the resulting offset between a transaction's endpoints — it does not sample the function over
    /// time — so a phase that wraps (tried once, to make a mid-pass restart seamless) makes both ends
    /// identical, the interpolation a no-op, and the shimmer silently STOP EXISTING. It compiles, it
    /// passes every pinned-phase render, and nothing catches it short of looking at the app.
    func testThePassActuallyTravels() {
        for run: CGFloat in [24, 80, 240] {
            let start = Slate.Shimmer.offset(phase: 0, runWidth: run)
            let end = Slate.Shimmer.offset(phase: 1, runWidth: run)
            XCTAssertNotEqual(start, end, "a pass whose ends match animates NOTHING (run \(run))")
            XCTAssertEqual(
                end - start, run + Slate.Shimmer.bandWidth(for: run), accuracy: 1e-9,
                "one pass carries the band across the run and its own width",
            )
            // Monotonic: every step forward moves the band forward.
            var previous = start
            for step in 1...20 {
                let next = Slate.Shimmer.offset(phase: CGFloat(step) / 20, runWidth: run)
                XCTAssertGreaterThan(next, previous, "the band must never step back")
                previous = next
            }
        }
    }

    /// A pass begins fully off the HEAD and ends fully off the TAIL — the band creeps in and creeps
    /// out rather than being switched on at full width somewhere in the middle of the run.
    func testTheBandStartsAndEndsOffTheRun() {
        let run: CGFloat = 160
        let band = Slate.Shimmer.bandWidth(for: run)
        XCTAssertEqual(
            Slate.Shimmer.offset(phase: 0, runWidth: run), -band, accuracy: 1e-9,
            "at the start the band's trailing edge is exactly at the run's head",
        )
        XCTAssertEqual(
            Slate.Shimmer.offset(phase: 1, runWidth: run), run, accuracy: 1e-9,
            "at the end its leading edge is exactly at the run's tail",
        )
    }
}
