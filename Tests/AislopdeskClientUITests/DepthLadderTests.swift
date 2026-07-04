import XCTest
@testable import AislopdeskClientUI

/// Depth-ladder canvas (2026-07-04 v4): the margin behind the pane cards must sit a REAL lift-step
/// below the card tone on every theme — the exact invariant whose absence sank the v1 (margin ≈ card)
/// and v3 (bare glass ≈ card on a dark desktop) canvases.
@MainActor
final class DepthLadderThemeTests: XCTestCase {
    /// Relative luminance proxy on the raw sRGB bytes (BT.709 weights) — good enough to order two
    /// tones of the same hue family.
    private func luminance(_ hex: String) -> Double {
        let v = UInt32(hex, radix: 16) ?? 0
        let r = Double((v >> 16) & 0xFF), g = Double((v >> 8) & 0xFF), b = Double(v & 0xFF)
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    private let themes: [SlateTheme] = [
        .paper, .dark,
        .monokaiProClassic, .monokaiProClassicLight, .monokaiProOctagon,
        .monokaiProMachine, .monokaiProRistretto, .monokaiProSpectrum,
    ]

    func testCanvasBackdropSitsBelowTheCardOnEveryTheme() {
        for theme in themes {
            let backdrop = luminance(theme.canvasBackdropHex)
            let card = luminance(theme.terminalBackgroundHex)
            XCTAssertLessThan(
                backdrop, card,
                "\(theme.id): margin must be darker than the card (the depth read)",
            )
            if !theme.isLight {
                // Dark themes must drop a HARD step (×0.55 channel scale ⇒ ≤ ~0.62 luminance) — a
                // near-identical margin is exactly the v1 failure this ladder exists to prevent.
                XCTAssertLessThanOrEqual(
                    backdrop, card * 0.62,
                    "\(theme.id): dark margin must be a full lift-step below the card, not a nudge",
                )
            }
        }
    }

    func testScaledHexDerivationPinned() {
        // The two shipped factors, pinned end-to-end (round-half-away-from-zero per channel).
        XCTAssertEqual(SlateTheme.scaledHex(0x2D2A2E, by: 0.55), 0x191719)
        XCTAssertEqual(SlateTheme.scaledHex(0xFCFBF9, by: 0.94), 0xEDECEA)
        // Clamp + degenerate ends.
        XCTAssertEqual(SlateTheme.scaledHex(0xFFFFFF, by: 2.0), 0xFFFFFF)
        XCTAssertEqual(SlateTheme.scaledHex(0x000000, by: 0.5), 0x000000)
        // The paper/dark literals must equal what the shared derivation would produce (hand-computed
        // constants can silently drift from the formula otherwise).
        XCTAssertEqual(SlateTheme.scaledHex(0xFCFBF9, by: 0.94), 0xEDECEA, "paper literal")
        XCTAssertEqual(SlateTheme.scaledHex(0x161616, by: 0.55), 0x0C0C0C, "dark literal")
    }
}

/// The grain tile is a FIXED-SEED SplitMix64 stream — byte-identical across launches so the canvas
/// texture can never shimmer between builds.
final class GrainTextureTests: XCTestCase {
    func testPixelsAreDeterministicAndPinned() {
        let a = GrainTexture.pixels()
        let b = GrainTexture.pixels()
        XCTAssertEqual(a.count, GrainTexture.tileSize * GrainTexture.tileSize)
        XCTAssertEqual(a, b, "same seed ⇒ same bytes, always")
        // First 8 bytes of the shipped roll (seed 0x5EED_A150_D35C) — bump ONLY when the seed changes.
        XCTAssertEqual(Array(a.prefix(8)), [239, 1, 173, 180, 6, 168, 83, 247])
    }

    func testDifferentSeedRollsDifferentTexture() {
        XCTAssertNotEqual(
            GrainTexture.pixels(seed: GrainTexture.seed &+ 1), GrainTexture.pixels(),
            "the seed must actually drive the stream",
        )
    }

    func testTileImageMaterializes() {
        XCTAssertNotNil(GrainTexture.image, "the CGImage build path must succeed on this platform")
    }
}
