// ViKeyHintBarTests (E17 ES-E17-2 / WI-5) — the HONESTY invariant of the vi key-hint bar: it advertises ONLY
// keys aislopdesk's copy-mode engine actually wires (a faithful subset of full vi), never a dead key. Pure
// data assertion over ``ViKeyHintBar/advertisedKeys`` (the same static arrays the view body renders from), so
// no SwiftUI view is constructed and nothing renderer/VT/Metal is touched.

#if canImport(SwiftUI)
import XCTest
@testable import AislopdeskClientUI

@MainActor
final class ViKeyHintBarTests: XCTestCase {
    /// The bar must NOT list `o` ("Swap ends"): the pinned libghostty fork exposes no swap-ends / set-selection
    /// action, so `handleCopyModeKey`'s `o` case is a documented NO-OP (DECISIONS.md E17). Advertising it would
    /// claim a dead key — the exact dishonesty the bar avoids for the other unwired motions (h/l/w/b/e/…).
    /// Revert-to-confirm-fail: the pre-fix `selection` column carried `Hint(keys: ["o"], label: "Swap ends")`,
    /// so this assertion fails on it.
    func testHintBarDoesNotAdvertiseTheDeadSwapEndsKey() {
        XCTAssertFalse(
            ViKeyHintBar.advertisedKeys.contains("o"),
            "the hint bar must not advertise the dead `o` (swap ends) key — it is a documented no-op",
        )
        // None of the other deliberately-unwired vi motions are advertised either (the documented omissions).
        for dead in ["h", "l", "w", "b", "e", "0", "$", "^", "H", "M", "L", "f"] {
            XCTAssertFalse(
                ViKeyHintBar.advertisedKeys.contains(dead),
                "the hint bar must not advertise the unwired motion `\(dead)`",
            )
        }
    }

    /// Positive control (guards against the test passing by listing nothing): the keys copy-mode DOES wire — the
    /// scroll/visual motions, yank, and BOTH search directions `/` and `?` — are present. `?` in particular pins
    /// that the bar reflects the now-wired backward-find (ES-E17-3), not just a forward `/`.
    func testHintBarAdvertisesTheWiredKeys() {
        let keys = Set(ViKeyHintBar.advertisedKeys)
        for wired in ["j", "k", "g", "G", "v", "V", "y", "/", "?", "n", "N"] {
            XCTAssertTrue(keys.contains(wired), "the hint bar advertises the wired key `\(wired)`")
        }
    }
}
#endif
