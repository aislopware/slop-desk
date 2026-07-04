import AislopdeskWorkspaceCore
import SwiftUI
import XCTest
@testable import AislopdeskClientUI

/// Pins the per-leaf glow decision of the ambient light engine (big-swing A): video palette wins,
/// busy shell casts accent, idle casts nothing (intensity 0, colours still valid for the fade-out).
@MainActor
final class AmbientGlowStyleTests: XCTestCase {
    private let bluePalette = AmbientPalette(
        primary: VideoPaneTint(red: 0.1, green: 0.2, blue: 0.85),
        secondary: VideoPaneTint(red: 0.3, green: 0.3, blue: 0.5),
        strength: 0.8,
    )

    func testVideoPaletteWinsOverBusyShell() {
        let glow = AmbientGlowStyle.resolve(palette: bluePalette, shellBusy: true, accent: .orange)
        XCTAssertEqual(glow.intensity, 0.8, accuracy: 1e-9)
        XCTAssertNotEqual(glow.inner, Color.orange)
    }

    func testZeroStrengthPaletteFallsThroughToBusy() {
        let grey = AmbientPalette(
            primary: VideoPaneTint(red: 0.5, green: 0.5, blue: 0.5),
            secondary: VideoPaneTint(red: 0.5, green: 0.5, blue: 0.5),
            strength: 0,
        )
        let glow = AmbientGlowStyle.resolve(palette: grey, shellBusy: true, accent: .orange)
        XCTAssertEqual(glow.inner, Color.orange)
        XCTAssertGreaterThan(glow.intensity, 0)
    }

    /// Restraint pass (2026-07-04): an idle pane casts NOTHING — the glow is an activity cue, not
    /// decoration. Colours stay valid so the fade-out animates instead of snapping to clear.
    func testIdleCastsNothing() {
        let glow = AmbientGlowStyle.resolve(palette: nil, shellBusy: false, accent: .orange)
        XCTAssertEqual(glow.intensity, 0)
        XCTAssertEqual(glow.inner, Color.orange)
    }
}
