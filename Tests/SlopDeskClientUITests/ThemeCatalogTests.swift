// ThemeCatalog tests (E15 WI-6) — the built-in theme directory ClientUI uses. Pure logic only: the built-in
// id table round-trip. No SCStream/VT/Metal/surface is touched.

#if canImport(SwiftUI)
import XCTest
@testable import SlopDeskClientUI

@MainActor
final class ThemeCatalogTests: XCTestCase {
    /// The built-in id table round-trips: every shipped theme in `builtinThemes` resolves back to itself via
    /// `builtin(id:)` (catches a drift between the list and the id→theme table).
    func testBuiltinThemesRoundTrip() {
        for theme in ThemeCatalog.builtinThemes {
            XCTAssertEqual(ThemeCatalog.builtin(id: theme.id)?.id, theme.id, "\(theme.id) must resolve to itself")
        }
        XCTAssertNil(ThemeCatalog.builtin(id: "nope"), "an unknown built-in id looks up to nil")
    }

    /// The shipped list stays complete + ordered (the Theme-picker order) — guards an accidental drop.
    func testBuiltinThemeListPinned() {
        XCTAssertEqual(
            ThemeCatalog.builtinThemes.map(\.id),
            [
                "monokai-classic", "monokai-classic-light", "monokai-octagon", "monokai-machine",
                "monokai-ristretto", "monokai-spectrum", "paper", "dark",
            ],
        )
    }
}
#endif
