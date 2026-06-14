import XCTest
@testable import AislopdeskVideoProtocol

/// WF-6 (#8) FULL-RANGE COLOR — the headless-testable half of the change: the pure
/// coefficient math. Rendered-pixel correctness is HW-only-verifiable (Metal GPU);
/// these tests prove (a) the `.video` coefficients are byte-identical to the shader's
/// current literals (so DEFAULT OFF is unchanged), (b) `.full` changes ONLY the luma,
/// and (c) both ranges map black→black / white→white / mid→mid for their own swing.
final class YCbCrConversionTests: XCTestCase {
    /// Mirror of the Metal fragment shader's YCbCr→RGB math, in Float (byte values 0..255).
    private func rgb(yByte: Float, cbByte: Float, crByte: Float, _ c: YCbCrCoefficients) -> SIMD3<Float> {
        let y = yByte / 255.0, cb = cbByte / 255.0, cr = crByte / 255.0
        let yy = (y - c.lumaBias) * c.lumaScale
        let cbc = cb - c.chromaBias
        let crc = cr - c.chromaBias
        return SIMD3(
            yy + c.crToR * crc,
            yy - c.cbToG * cbc - c.crToG * crc,
            yy + c.cbToB * cbc,
        )
    }

    // MARK: (a) .video == today's shader literals, byte-for-byte

    func testVideoRangeCoefficientsMatchShaderLiterals() {
        let v = YCbCrConversion.coefficients(.video)
        // EXACT shader literals (MetalVideoRenderer.shaderSource), computed in the SAME
        // Float context the helper uses — a mismatch here means the OFF path is no longer
        // byte-identical and would change the rendered output / trigger a decoder rebuild.
        let lumaScale: Float = 255.0 / 219.0
        let lumaBias: Float = 16.0 / 255.0
        let chromaBias: Float = 128.0 / 255.0
        XCTAssertEqual(v.lumaScale, lumaScale)
        XCTAssertEqual(v.lumaBias, lumaBias)
        XCTAssertEqual(v.chromaBias, chromaBias)
        XCTAssertEqual(v.crToR, Float(1.5748))
        XCTAssertEqual(v.cbToG, Float(0.1873))
        XCTAssertEqual(v.crToG, Float(0.4681))
        XCTAssertEqual(v.cbToB, Float(1.8556))
    }

    // MARK: (b) .full differs ONLY in luma; chroma + matrix identical to .video

    func testFullRangeChangesOnlyLuma() {
        let v = YCbCrConversion.coefficients(.video)
        let f = YCbCrConversion.coefficients(.full)
        // Luma: identity expansion (the entire documented difference).
        XCTAssertEqual(f.lumaScale, Float(1.0))
        XCTAssertEqual(f.lumaBias, Float(0.0))
        // Chroma centre + all four matrix coefficients are RANGE-INDEPENDENT → byte-identical.
        XCTAssertEqual(f.chromaBias, v.chromaBias)
        XCTAssertEqual(f.crToR, v.crToR)
        XCTAssertEqual(f.cbToG, v.cbToG)
        XCTAssertEqual(f.crToG, v.crToG)
        XCTAssertEqual(f.cbToB, v.cbToB)
        // And the two ranges are NOT equal overall (the luma really did change).
        XCTAssertNotEqual(f, v)
    }

    // MARK: (c) black→black, white→white, mid→mid for each range's own swing

    func testVideoRangeGreyscaleRoundsCorrectly() {
        let v = YCbCrConversion.coefficients(.video)
        // Studio-swing achromatic samples (Cb=Cr=128 → no colour).
        assertRGB(rgb(yByte: 16, cbByte: 128, crByte: 128, v), SIMD3(0, 0, 0)) // black floor 16
        assertRGB(rgb(yByte: 235, cbByte: 128, crByte: 128, v), SIMD3(1, 1, 1)) // white ceiling 235
        // Mid: Y=126 → (126-16)/219 = 110/219 ≈ 0.50228.
        assertRGB(rgb(yByte: 126, cbByte: 128, crByte: 128, v), SIMD3(110.0 / 219.0, 110.0 / 219.0, 110.0 / 219.0))
    }

    func testFullRangeGreyscaleRoundsCorrectly() {
        let f = YCbCrConversion.coefficients(.full)
        // Full-swing achromatic samples (Cb=Cr=128 → no colour).
        assertRGB(rgb(yByte: 0, cbByte: 128, crByte: 128, f), SIMD3(0, 0, 0)) // black floor 0
        assertRGB(rgb(yByte: 255, cbByte: 128, crByte: 128, f), SIMD3(1, 1, 1)) // white ceiling 255
        assertRGB(rgb(yByte: 128, cbByte: 128, crByte: 128, f), SIMD3(128.0 / 255.0, 128.0 / 255.0, 128.0 / 255.0))
    }

    func testMatrixCoefficientsApplyToChroma() {
        // A coloured sample exercises the (range-independent) matrix. White luma + a Cb offset
        // must lift B and drop G by the documented coefficients; R is unaffected by Cb.
        let v = YCbCrConversion.coefficients(.video)
        let out = rgb(yByte: 235, cbByte: 255, crByte: 128, v) // yy=1, crc=0, cbc=(255-128)/255
        let cbc = Float(255.0 / 255.0 - 128.0 / 255.0)
        assertRGB(out, SIMD3(1.0, 1.0 - v.cbToG * cbc, 1.0 + v.cbToB * cbc))
    }

    private func assertRGB(_ got: SIMD3<Float>, _ want: SIMD3<Float>, line: UInt = #line) {
        XCTAssertEqual(got.x, want.x, accuracy: 1e-5, line: line)
        XCTAssertEqual(got.y, want.y, accuracy: 1e-5, line: line)
        XCTAssertEqual(got.z, want.z, accuracy: 1e-5, line: line)
    }
}
