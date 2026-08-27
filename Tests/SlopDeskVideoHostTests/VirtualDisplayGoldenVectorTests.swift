#if os(macOS)
import CoreGraphics
import XCTest
@testable import SlopDeskVideoHost

/// Replays the four virtual-display keys of `golden/golden_vectors.json` — `virtualDisplayGeometry`,
/// `vdOriginToRight`, `vdChipPixelLimit`, `vdRefreshRates` — through the live
/// ``VirtualDisplayGeometry`` and ``VirtualDisplayPlanner``.
///
/// ## Why this suite exists
///
/// All four are listed as frozen in `golden-check.sh` — kept in the corpus, not regenerated,
/// "XCTest-pinned". **Nothing read them.** The hand-written suite beside the code named three of the
/// keys, but only as `// MARK:` headings above assertions written by hand; the corpus file was never
/// opened there. `slopdesk-corevectors/main.swift` said the logic "lives solely in the Rust core
/// (`slopdesk_core::virtual_display_geometry`, reached via the C ABI)" and that `golden_parity`
/// validated it — there was no such crate and no such test. Twenty-nine cases were pinned by a
/// comment.
///
/// What they pin that hand-written assertions do not: the millimetre conversion is compared by BIT
/// PATTERN, so the `/ ppi * 25.4` operand order (never an FMA, never a reassociation) is fixed, and
/// so is the PPI floor that must send NaN to 1.0 rather than propagate it. Those are the properties
/// a port has to preserve, which is why these were worth reviving rather than dropping.
///
/// The comment is true now, of a different crate: the arithmetic IS a Rust core —
/// `slopdesk_video::virtual_display`, reached through `slopdesk-ffi` — and these vectors are
/// replayed from BOTH sides. This suite drives the Swift face, so the marshalling is covered;
/// `every_pinned_virtual_display_geometry_reports_what_swift_reported` and its three siblings in
/// `rust/slopdesk-video/tests/golden_vectors.rs` drive the rule itself.
///
/// The corpus is READ here, never written.
final class VirtualDisplayGoldenVectorTests: XCTestCase {
    private struct GeometryCase: Decodable {
        let pointWidth: Int
        let pointHeight: Int
        let scale: Int
        let maxHorizontalPixels: Int
        let ppiBits: UInt64
        let pixelWidth: Int
        let pixelHeight: Int
        let exceedsPixelLimit: Bool
        let mmWidthBits: UInt64
        let mmHeightBits: UInt64
    }

    private struct DisplayRect: Decodable {
        let xBits: UInt64
        let yBits: UInt64
        let wBits: UInt64
        let hBits: UInt64
    }

    private struct OriginCase: Decodable {
        let name: String
        let displays: [DisplayRect]
        let outXBits: UInt64
        let outYBits: UInt64
    }

    private struct ChipCase: Decodable {
        let cpuBrand: String
        let limit: Int
    }

    private struct RefreshCase: Decodable {
        let fps: Int
        let ratesBits: [UInt64]
    }

    func testGeometryVectorsStillHold() throws {
        let cases: [GeometryCase] = try GoldenCorpus.load("virtualDisplayGeometry")
        XCTAssertEqual(cases.count, 10, "the corpus lost cases — vectors are added, never dropped")

        for (index, testCase) in cases.enumerated() {
            // The RAW inputs, clamps included: several vectors carry a zero or negative point size
            // precisely to pin the `max(1, …)` the initialiser applies.
            let geometry = VirtualDisplayGeometry(
                pointWidth: testCase.pointWidth,
                pointHeight: testCase.pointHeight,
                scale: testCase.scale,
                maxHorizontalPixels: testCase.maxHorizontalPixels,
            )
            XCTAssertEqual(geometry.pixelWidth, testCase.pixelWidth, "case \(index): pixelWidth")
            XCTAssertEqual(geometry.pixelHeight, testCase.pixelHeight, "case \(index): pixelHeight")
            XCTAssertEqual(
                geometry.exceedsPixelLimit,
                testCase.exceedsPixelLimit,
                "case \(index): exceedsPixelLimit",
            )
            let millimetres = geometry.sizeInMillimeters(targetPPI: Double(bitPattern: testCase.ppiBits))
            XCTAssertEqual(Double(millimetres.width).bitPattern, testCase.mmWidthBits, "case \(index): mm width")
            XCTAssertEqual(Double(millimetres.height).bitPattern, testCase.mmHeightBits, "case \(index): mm height")
        }
    }

    func testOriginToRightVectorsStillHold() throws {
        let cases: [OriginCase] = try GoldenCorpus.load("vdOriginToRight")
        XCTAssertEqual(cases.count, 6, "the corpus lost cases — vectors are added, never dropped")

        for testCase in cases {
            let origin = VirtualDisplayPlanner.originToRight(of: testCase.displays.map {
                CGRect(
                    x: Double(bitPattern: $0.xBits),
                    y: Double(bitPattern: $0.yBits),
                    width: Double(bitPattern: $0.wBits),
                    height: Double(bitPattern: $0.hBits),
                )
            })
            XCTAssertEqual(Double(origin.x).bitPattern, testCase.outXBits, "\(testCase.name): x")
            XCTAssertEqual(Double(origin.y).bitPattern, testCase.outYBits, "\(testCase.name): y")
        }
    }

    func testChipPixelLimitVectorsStillHold() throws {
        let cases: [ChipCase] = try GoldenCorpus.load("vdChipPixelLimit")
        XCTAssertEqual(cases.count, 8, "the corpus lost cases — vectors are added, never dropped")

        for testCase in cases {
            XCTAssertEqual(
                VirtualDisplayPlanner.chipPixelLimit(cpuBrand: testCase.cpuBrand),
                testCase.limit,
                testCase.cpuBrand.isEmpty ? "<empty brand>" : testCase.cpuBrand,
            )
        }
    }

    /// **The one key of the five that DRIFTED, and the reason unread pins are worse than none.**
    ///
    /// `6281fae2` (2026-07-15, "VD advertises a 2x-encode-fps refresh mode — the beat-kill enabler")
    /// deliberately changed this function: `refreshRates(60)` went from `[60, 30]` to `[120, 60, 30]`
    /// so SCStream can oversample 2:1 instead of beating against the encode fps. It updated the
    /// hand-written suite beside the code and left the corpus alone — correctly, in the sense that
    /// nothing was reading it, and disastrously, in the sense that the vectors have recorded a
    /// superseded law ever since.
    ///
    /// So three of the five cases fail against the live planner (fps 60, 90 and 144 each lack the
    /// capped `min(120, 2 × fps)` oversample mode). The code is right and the corpus is stale, but
    /// refreshing a FROZEN vector is the owner's call, not a test's — `CLAUDE.md` forbids
    /// regenerating over this file, and this suite exists precisely because values that drift
    /// unwatched are how a corpus stops meaning anything.
    ///
    /// This USED to say "skipped, loudly, until that call is made". It was not loud. `just test`
    /// runs `swift test --parallel`, which prints one progress line per test and no skip reason at
    /// all — and `--xunit-output` records a skipped case as a plain passing `<testcase>`, so the
    /// machine-readable half loses it too. Measured: the reason string appears zero times in a full
    /// run's output. A skip nobody can see is the same shape as the stale vector it was announcing.
    ///
    /// So the test RUNS now, and pins the disagreement instead of hiding behind it. `knownStale` is
    /// the exact set of fps whose vectors predate `6281fae2`; every other case is asserted for real.
    /// Both directions fail: refreshing the corpus (the owner's call this is still waiting on) makes
    /// `knownStale` wrong and says so, and a NEW drift on 30 or 120 fails as a plain mismatch.
    func testRefreshRateVectorsStillHold() throws {
        let cases: [RefreshCase] = try GoldenCorpus.load("vdRefreshRates")
        XCTAssertEqual(cases.count, 5, "the corpus lost cases — vectors are added, never dropped")

        // Each lacks the capped `min(120, 2 × fps)` oversample mode the commit added.
        let knownStale: Set = [60, 90, 144]
        let live = cases.map { VirtualDisplayPlanner.refreshRates(fps: $0.fps).map(\.bitPattern) }
        let stale = Set(zip(cases, live).filter { $0.0.ratesBits != $0.1 }.map(\.0.fps))
        XCTAssertEqual(
            stale,
            knownStale,
            "the set of stale vdRefreshRates vectors moved. If the corpus was refreshed (owner's "
                + "call), delete knownStale and this assertion. If it was not, the planner changed "
                + "and a vector nobody was reading has drifted a second time.",
        )

        for (testCase, produced) in zip(cases, live) where !knownStale.contains(testCase.fps) {
            XCTAssertEqual(
                produced,
                testCase.ratesBits,
                "fps \(testCase.fps) — the ORDER is part of the answer (descending, deduped)",
            )
        }
    }
}
#endif
