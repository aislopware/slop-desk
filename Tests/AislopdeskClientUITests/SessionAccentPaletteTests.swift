import XCTest
@testable import AislopdeskClientUI
@testable import AislopdeskWorkspaceCore

/// The UI palette must stay index-aligned with the core's slot contract.
final class SessionAccentPaletteTests: XCTestCase {
    func testPaletteCountMatchesTheCoreContract() {
        XCTAssertEqual(SessionAccentPalette.colors.count, SessionAccent.paletteCount)
    }

    func testNilSessionYieldsNilSoCallersFallBackToTheme() {
        XCTAssertNil(SessionAccentPalette.color(for: nil))
    }

    func testEverySessionResolvesToAPaletteColour() {
        for _ in 0..<16 {
            XCTAssertNotNil(SessionAccentPalette.color(for: SessionID()))
        }
    }
}
