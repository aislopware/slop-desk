import XCTest
@testable import SlopDeskWorkspaceCore

/// WB3 — the ``PreferencesStore`` block-bookmark persistence (`settings.blockBookmarks.v1`): a
/// per-session `sessionUUID → [block index]` map, round-tripped through an isolated `UserDefaults` suite.
/// This is CLIENT-only display state — never folded into the env overlay / sidecar — so the golden corpus
/// is untouched.
@MainActor
final class PreferencesStoreBlockBookmarksTests: XCTestCase {
    private func makeIsolatedDefaults(_ name: String = #function) -> UserDefaults {
        let suite = "PreferencesStoreBlockBookmarksTest." + name
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    func testBlockBookmarksRoundTripPerSession() {
        let defaults = makeIsolatedDefaults()
        let store = PreferencesStore(defaults: defaults, sidecarURL: nil)

        // Fresh install — no bookmarks.
        XCTAssertEqual(store.blockBookmarks(for: "session-A"), [])

        store.setBlockBookmarks([0, 3, 7], for: "session-A")
        store.setBlockBookmarks([2], for: "session-B")
        XCTAssertEqual(store.blockBookmarks(for: "session-A"), [0, 3, 7])
        XCTAssertEqual(store.blockBookmarks(for: "session-B"), [2])
        XCTAssertEqual(store.blockBookmarks(for: "unknown"), [], "an unknown session has none")

        // A fresh store over the SAME defaults reads the persisted map back (durability).
        let store2 = PreferencesStore(defaults: defaults, sidecarURL: nil)
        XCTAssertEqual(store2.blockBookmarks(for: "session-A"), [0, 3, 7], "persisted across store instances")
        XCTAssertEqual(store2.blockBookmarks(for: "session-B"), [2])
    }

    func testEmptySetRemovesTheSessionEntry() {
        let defaults = makeIsolatedDefaults()
        let store = PreferencesStore(defaults: defaults, sidecarURL: nil)
        store.setBlockBookmarks([1, 2], for: "s")
        XCTAssertEqual(store.blockBookmarks(for: "s"), [1, 2])
        store.setBlockBookmarks([], for: "s") // un-star everything
        XCTAssertEqual(store.blockBookmarks(for: "s"), [], "clearing removes the entry")
        let store2 = PreferencesStore(defaults: defaults, sidecarURL: nil)
        XCTAssertEqual(store2.blockBookmarks(for: "s"), [], "the cleared entry stays gone after reload")
    }
}
