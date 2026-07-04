import AislopdeskWorkspaceCore
import XCTest

/// Pins the taste contract of the ambient light engine's pure reduction step: colourful frames glow
/// with their own hue, grey/white/black frames must NOT light the canvas, garbage never traps.
final class AmbientPaletteTests: XCTestCase {
    private func tint(_ r: Double, _ g: Double, _ b: Double) -> VideoPaneTint {
        VideoPaneTint(red: r, green: g, blue: b)
    }

    func testEmptyAndAllGarbageReturnNil() {
        XCTAssertNil(AmbientPalette.reduce(samples: []))
        XCTAssertNil(AmbientPalette.reduce(samples: [
            tint(.nan, 0.5, 0.5), tint(0.1, .infinity, 0.2),
        ]))
    }

    func testGarbageSamplesAreSkippedNotFatal() throws {
        let palette = AmbientPalette.reduce(samples: [
            tint(.nan, .nan, .nan),
            tint(0.1, 0.2, 0.9),
        ])
        XCTAssertNotNil(palette)
        // The finite blue sample carries the hue.
        XCTAssertGreaterThan(try XCTUnwrap(palette?.primary.blue), try XCTUnwrap(palette?.primary.red))
    }

    func testPureBlueFrameGlowsBlueAtFullStrength() throws {
        let palette = try XCTUnwrap(AmbientPalette.reduce(samples: Array(repeating: tint(0.05, 0.15, 0.8), count: 16)))
        XCTAssertEqual(palette.strength, 1.0, accuracy: 1e-9)
        // Vivid normalization: brightest channel scaled to 0.85, hue ratios preserved.
        XCTAssertEqual(palette.primary.blue, 0.85, accuracy: 1e-9)
        XCTAssertEqual(palette.primary.red / palette.primary.blue, 0.05 / 0.8, accuracy: 1e-9)
    }

    func testGreyWhiteFrameHasZeroStrength() throws {
        // A blank white IDE / plain shell: zero saturation everywhere → the canvas must stay dark.
        let white = try XCTUnwrap(AmbientPalette.reduce(samples: Array(repeating: tint(0.95, 0.95, 0.95), count: 16)))
        XCTAssertEqual(white.strength, 0, accuracy: 1e-9)
        let grey = try XCTUnwrap(AmbientPalette.reduce(samples: Array(repeating: tint(0.4, 0.4, 0.4), count: 16)))
        XCTAssertEqual(grey.strength, 0, accuracy: 1e-9)
    }

    func testNearBlackFrameDecaysStrength() throws {
        // Saturated in ratio but essentially black — nothing real to reflect.
        let palette = try XCTUnwrap(AmbientPalette.reduce(samples: Array(repeating: tint(0.0, 0.0, 0.01), count: 16)))
        XCTAssertLessThan(palette.strength, 0.3)
    }

    func testSaturatedPixelWinsHueOverBrightWashedOut() throws {
        // One vivid red pixel among bright near-white ones: red carries the hue, the average stays pale.
        var samples = Array(repeating: tint(0.9, 0.88, 0.86), count: 15)
        samples.append(tint(0.8, 0.05, 0.05))
        let palette = try XCTUnwrap(AmbientPalette.reduce(samples: samples))
        XCTAssertGreaterThan(palette.primary.red, palette.primary.green * 3)
        XCTAssertGreaterThan(palette.secondary.green, 0.5) // average dominated by the pale field
    }

    func testAverageIsArithmeticMeanOfClampedSamples() throws {
        let palette = try XCTUnwrap(AmbientPalette.reduce(samples: [tint(0.0, 0.0, 0.0), tint(1.0, 0.5, 0.0)]))
        XCTAssertEqual(palette.secondary.red, 0.5, accuracy: 1e-9)
        XCTAssertEqual(palette.secondary.green, 0.25, accuracy: 1e-9)
        XCTAssertEqual(palette.secondary.blue, 0.0, accuracy: 1e-9)
    }

    func testOutOfRangeSamplesAreClamped() throws {
        let palette = try XCTUnwrap(AmbientPalette.reduce(samples: [tint(2.0, -1.0, 0.5)]))
        XCTAssertLessThanOrEqual(palette.secondary.red, 1.0)
        XCTAssertGreaterThanOrEqual(palette.secondary.green, 0.0)
    }
}
