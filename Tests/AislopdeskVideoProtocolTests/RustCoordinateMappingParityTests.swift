import XCTest
@testable import AislopdeskVideoProtocol

/// Differential parity: every value `CoordinateMappingTests` pins is now produced by the
/// Rust-backed path (the swap is in `CoordinateMapping`). These re-pin the same exact values
/// through the FFI, and the fuzz proves window_point / cg_rect_to_cocoa / window_point_from_pixel
/// match the pure Swift formula bit-for-bit across unbounded inputs. `coordinate_mapping` is
/// fully env-free (nothing resolved Swift-side).
final class RustCoordinateMappingParityTests: XCTestCase {
    private func nativeWindowPoint(_ n: VideoPoint, _ b: VideoRect) -> VideoPoint {
        VideoPoint(x: b.origin.x + n.x * b.size.width, y: b.origin.y + n.y * b.size.height)
    }

    private func nativeCGToCocoa(_ r: VideoRect, _ h: Double) -> VideoRect {
        VideoRect(x: r.origin.x, y: h - r.origin.y - r.size.height, width: r.size.width, height: r.size.height)
    }

    private func nativePixel(_ p: VideoPoint, _ b: VideoRect, _ s: Double) -> VideoPoint {
        VideoPoint(x: b.origin.x + p.x / s, y: b.origin.y + p.y / s)
    }

    private func nativeBackingScale(_ winCG: VideoRect, _ screens: [ScreenInfo], _ h: Double) -> Double? {
        let cocoa = nativeCGToCocoa(winCG, h)
        var best: (area: Double, scale: Double)?
        for s in screens {
            let area = cocoa.intersectionArea(s.cocoaFrame)
            if area > 0, best == nil || area > best!.area { best = (area, s.backingScaleFactor) }
        }
        return best?.scale
    }

    func testPinnedValues() {
        let b = VideoRect(x: 100, y: 200, width: 800, height: 600)
        XCTAssertEqual(
            CoordinateMapping.windowPoint(normalized: VideoPoint(x: 0.5, y: 0.5), windowBounds: b),
            VideoPoint(x: 500, y: 500),
        )
        XCTAssertEqual(
            CoordinateMapping.windowPoint(normalized: VideoPoint(x: 1, y: 1), windowBounds: b),
            VideoPoint(x: 900, y: 800),
        )
        XCTAssertEqual(
            CoordinateMapping.cgRectToCocoa(VideoRect(x: 0, y: 0, width: 400, height: 200), primaryHeight: 1080),
            VideoRect(x: 0, y: 880, width: 400, height: 200),
        )
        XCTAssertEqual(
            CoordinateMapping
                .windowPoint(pixel: VideoPoint(x: 400, y: 300), windowBoundsCG: b, backingScaleFactor: 2.0),
            VideoPoint(x: 300, y: 350),
        )
    }

    func testBackingScaleMultiMonitorAndNil() {
        let primary = ScreenInfo(cocoaFrame: VideoRect(x: 0, y: 0, width: 1920, height: 1080), backingScaleFactor: 1.0)
        let retina = ScreenInfo(
            cocoaFrame: VideoRect(x: 0, y: 1080, width: 2560, height: 1440),
            backingScaleFactor: 2.0,
        )
        XCTAssertEqual(
            CoordinateMapping.backingScaleFactor(forWindowBoundsCG: VideoRect(
                x: 100,
                y: -1000,
                width: 1280,
                height: 800,
            ), screens: [primary, retina], primaryHeight: 1080),
            2.0,
        )
        XCTAssertNil(CoordinateMapping.backingScaleFactor(
            forWindowBoundsCG: VideoRect(x: 10000, y: 0, width: 100, height: 100),
            screens: [primary],
            primaryHeight: 1080,
        ))
        XCTAssertNil(CoordinateMapping.backingScaleFactor(
            forWindowBoundsCG: VideoRect(x: 0, y: 0, width: 10, height: 10),
            screens: [],
            primaryHeight: 1080,
        ))
    }

    func testFuzzWindowPointAndPixelMatchNative() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<5000 {
            let n = VideoPoint(x: Double.random(in: -2...2, using: &rng), y: Double.random(in: -2...2, using: &rng))
            let b = VideoRect(
                x: Double.random(in: -4000...4000, using: &rng),
                y: Double.random(in: -4000...4000, using: &rng),
                width: Double.random(in: 0...4000, using: &rng),
                height: Double.random(in: 0...4000, using: &rng),
            )
            let g = CoordinateMapping.windowPoint(normalized: n, windowBounds: b)
            let w = nativeWindowPoint(n, b)
            XCTAssertEqual(g.x.bitPattern, w.x.bitPattern)
            XCTAssertEqual(g.y.bitPattern, w.y.bitPattern)

            let p = VideoPoint(x: Double.random(in: 0...4000, using: &rng), y: Double.random(in: 0...4000, using: &rng))
            let s = Double.random(in: 0.5...3.0, using: &rng)
            let gp = CoordinateMapping.windowPoint(pixel: p, windowBoundsCG: b, backingScaleFactor: s)
            let wp = nativePixel(p, b, s)
            XCTAssertEqual(gp.x.bitPattern, wp.x.bitPattern)
            XCTAssertEqual(gp.y.bitPattern, wp.y.bitPattern)
        }
    }

    func testFuzzBackingScaleMatchesNative() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<3000 {
            let count = Int.random(in: 0...4, using: &rng)
            let screens = (0..<count).map { _ in
                ScreenInfo(
                    cocoaFrame: VideoRect(
                        x: Double.random(in: -3000...3000, using: &rng),
                        y: Double.random(in: -3000...3000, using: &rng),
                        width: Double.random(in: 0...3000, using: &rng),
                        height: Double.random(in: 0...3000, using: &rng),
                    ),
                    backingScaleFactor: [1.0, 2.0, 3.0].randomElement(using: &rng)!,
                )
            }
            let winCG = VideoRect(
                x: Double.random(in: -3000...3000, using: &rng),
                y: Double.random(in: -3000...3000, using: &rng),
                width: Double.random(in: 0...3000, using: &rng),
                height: Double.random(in: 0...3000, using: &rng),
            )
            let h = Double.random(in: 0...6000, using: &rng)
            XCTAssertEqual(
                CoordinateMapping.backingScaleFactor(forWindowBoundsCG: winCG, screens: screens, primaryHeight: h),
                nativeBackingScale(winCG, screens, h),
            )
        }
    }
}
