// HostedRasterTests — the rig proving itself, on every gate run.
//
// This suite is the answer to docs/62 §5.2's "single most dangerous silent failure": the old
// `ImageRenderer` harness could photograph an EMPTY BOX where a `UIViewRepresentable` stood, hand back
// a valid `UIImage`, write a valid PNG, and stay green. Every assertion below reads PIXELS back out of
// the bitmap, so "the rig rendered nothing" is now a red test rather than a blank sheet nobody opened.
//
// ⚠️ TWO TESTS WERE DELETED FROM THIS SUITE, and their absence is not a coverage loss.
// `testHostedSwiftUIReachesTheBitmap` and `testRepresentableIsPhotographedNotPlaceheld` proved the
// rig could photograph hosted SwiftUI and a `UIViewRepresentable` — the second was even labelled "THE
// ONE THAT MATTERS", because a representable is exactly what `ImageRenderer` used to refuse. Both
// were written during a planned coexistence period that was cancelled hours later: all SwiftUI is
// being deleted from the tree, so there is no representable left to photograph and no hosted tree to
// mount. A test that guards a bridge outlives its usefulness the moment the bridge is removed.
//
// What they were guarding survives in `testUIKitViewReachesTheBitmap`, which reads the same pixels
// back through the same road. The silent-blank failure mode was never about SwiftUI — it was about a
// harness that returns a valid `UIImage` full of nothing — and a bare `UIView` capture catches that
// just as loudly.
//
// Tolerances: the comparisons allow ±2 per 8-bit channel. The capture round-trips through a
// device-RGB context, and an exact-equality assertion on a colour-managed draw is a flake waiting for
// a simulator update — while a rig that photographed nothing is off by 255, not by 2.

import UIKit
import XCTest
@testable import SlopDeskSlate

@MainActor
final class HostedRasterTests: XCTestCase {
    /// ⚠️ THE ONE THAT MATTERS. A bare `UIView` — the shape every `Slate*` tile now is — reaches the
    /// bitmap with its own fill, not the ground tone. If this ever comes back as the ground, the rig
    /// has silently stopped photographing and every sheet in the bundle is lying.
    func testUIKitViewReachesTheBitmap() throws {
        let tile = UIView()
        tile.backgroundColor = UIColor(slateHex: 0x11AA33)

        let image = HostedRaster.image(tile, width: 40, height: 40, scale: 2)
        XCTAssertEqual(image.size, CGSize(width: 40, height: 40))
        let pixel = try XCTUnwrap(image.slatePixel(atX: 20, y: 20), "the capture has a readable centre")
        assertChannels(pixel, r: 0x11, g: 0xAA, b: 0x33, what: "a bare UIView's fill")
    }

    /// The ground is the authored cream, not the semantic system backdrop — the fixture-ground rule
    /// `SlateSnapshotRender`'s header states, checked rather than restated.
    func testTheGroundIsTheAuthoredCream() throws {
        let image = HostedRaster.image(UIView(), width: 20, height: 20)
        let pixel = try XCTUnwrap(image.slatePixel(atX: 10, y: 10))
        var (r, g, b, a): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        HostedRaster.ground.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
            .getRed(&r, green: &g, blue: &b, alpha: &a)
        assertChannels(
            pixel, r: UInt8(r * 255), g: UInt8(g * 255), b: UInt8(b * 255), what: "the fixture ground",
        )
    }

    /// The render scale is the BITMAP's, not a transform: a 2× capture of a 40pt tile is 80px wide, and
    /// the magnified mark strips depend on it being the vector redrawn rather than a blown-up bitmap.
    func testRenderScaleSizesTheBitmap() {
        let one = HostedRaster.image(UIView(), width: 40, height: 40, scale: 1)
        let three = HostedRaster.image(UIView(), width: 40, height: 40, scale: 3)
        XCTAssertEqual(one.cgImage?.width, 40)
        XCTAssertEqual(three.cgImage?.width, 120)
        XCTAssertEqual(one.size, three.size, "point size is the same; only the backing differs")
    }

    /// A view sized by Auto Layout alone gets the window grown to its fitting height — the sheets lay
    /// rows out this way and a zero-height capture would be another quiet blank.
    func testIntrinsicHeightGrowsTheWindow() {
        let label = UILabel()
        label.text = "one line of chrome"
        label.font = .systemFont(ofSize: 17)

        let image = HostedRaster.image(label, width: 200)
        XCTAssertGreaterThan(image.size.height, 1, "the fitting height replaced the placeholder height")
        XCTAssertEqual(image.size.width, 200)
    }

    // MARK: - Support

    private func assertChannels(
        _ pixel: (r: UInt8, g: UInt8, b: UInt8, a: UInt8), r: UInt8, g: UInt8, b: UInt8, what: String,
        file: StaticString = #filePath, line: UInt = #line,
    ) {
        XCTAssertEqual(Int(pixel.r), Int(r), accuracy: 2, "\(what): red", file: file, line: line)
        XCTAssertEqual(Int(pixel.g), Int(g), accuracy: 2, "\(what): green", file: file, line: line)
        XCTAssertEqual(Int(pixel.b), Int(b), accuracy: 2, "\(what): blue", file: file, line: line)
        XCTAssertEqual(Int(pixel.a), 255, "\(what): opaque", file: file, line: line)
    }
}
