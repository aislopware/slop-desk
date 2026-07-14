// ViKeyHintBarTests — the HONESTY invariant of the vi key-hint bar: it advertises ONLY
// keys slopdesk's copy-mode engine actually wires (a faithful subset of full vi), never a dead key. Pure
// data assertion over ``ViKeyHintBar/advertisedKeys`` (the same static arrays the view body renders from), so
// no SwiftUI view is constructed and nothing renderer/VT/Metal is touched.

#if canImport(SwiftUI)
import XCTest
@testable import SlopDeskClientUI

@MainActor
final class ViKeyHintBarTests: XCTestCase {
    /// The deliberately-unwired screen-relative jumps (`H`/`M`/`L`) stay unadvertised — the one honesty
    /// omission left after the E17 ceiling lift wired the cursor motions (DECISIONS.md 2026-07-14).
    func testHintBarDoesNotAdvertiseUnwiredKeys() {
        for dead in ["H", "M", "L"] {
            XCTAssertFalse(
                ViKeyHintBar.advertisedKeys.contains(dead),
                "the hint bar must not advertise the unwired motion `\(dead)`",
            )
        }
    }

    /// Positive control (guards against the test passing by listing nothing): the wired keys are present —
    /// including the CURSOR motions + `o` (swap ends) + `Y` (yank line) that joined with the ceiling lift.
    /// `?` pins the wired backward-find; `f` pins the Hint Mode entry (its own `beginHint` seam).
    func testHintBarAdvertisesTheWiredKeys() {
        let keys = Set(ViKeyHintBar.advertisedKeys)
        let wiredKeys = [
            "h", "j", "k", "l", "w", "b", "e", "0", "^", "$", "o", "Y",
            "g", "G", "v", "V", "y", "/", "?", "n", "N", "f",
        ]
        for wired in wiredKeys {
            XCTAssertTrue(keys.contains(wired), "the hint bar advertises the wired key `\(wired)`")
        }
    }
}
#endif
