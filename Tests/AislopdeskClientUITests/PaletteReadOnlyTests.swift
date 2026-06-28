import XCTest
@testable import AislopdeskClientUI
@testable import AislopdeskWorkspaceCore

/// E17 ES-E17-1 / WI-2 — the command palette's "Read Only" row + its spec-accepted search synonyms.
/// `terminal-features__read-only-mode.md` §Behaviors: the palette accepts "read only" plus `readonly`,
/// `lock`, `freeze`, `view only`. The synonyms ride the row's HIDDEN ``PaletteItem/keywords``, folded into
/// the ``SearchMixer`` BELOW the title / subtitle tiers, so they surface the row without being rendered.
@MainActor
final class PaletteReadOnlyTests: XCTestCase {
    private func mixer() -> SearchMixer { SearchMixer(sources: [ActionsPaletteSource()]) }

    /// The selectable row ids the mixer returns for `query`.
    private func ids(_ query: String) -> [String] {
        SearchMixer.selectable(mixer().results(query: query)).map(\.id)
    }

    /// The catalog carries a "Read Only" row under the SHELL section (otty's "Shell → Read Only" placement)
    /// with no hint chip (otty ships no default chord ⇒ the registry glyph resolves to nil).
    func testReadOnlyRowExistsUnderShellWithNoChord() throws {
        let row = try XCTUnwrap(ActionsPaletteSource.catalog.first { $0.id == "action.toggleReadOnly" })
        XCTAssertEqual(row.title, "Read Only")
        XCTAssertEqual(row.category, .shell, "Read Only sits under the Shell section (otty parity)")
        XCTAssertNil(row.shortcut, "otty documents no default chord ⇒ no hint chip")
    }

    /// Every spec-accepted term surfaces the Read Only row — "read only" plus the synonyms `readonly` /
    /// `lock` / `freeze` / `view only`. FAILS before the row + the hidden-keyword search exist (the title
    /// "Read Only" alone is matched by none of `lock` / `freeze` / `view only`).
    func testReadOnlySynonymsAllMatchTheRow() {
        for term in ["read only", "readonly", "lock", "freeze", "view only"] {
            XCTAssertTrue(
                ids(term).contains("action.toggleReadOnly"),
                "the query \"\(term)\" surfaces the Read Only palette row",
            )
        }
    }

    /// Control: a synonym (`freeze`) reaches the row PURELY via the hidden keywords — it is a subsequence of
    /// neither the title nor any rendered subtitle — proving the keyword fold is what makes it searchable
    /// (not an accidental title fuzzy-match). Guards against the synonyms being silently unreachable.
    func testFreezeMatchesOnlyViaHiddenKeywords() throws {
        let row = try XCTUnwrap(ActionsPaletteSource.catalog.first { $0.id == "action.toggleReadOnly" })
        XCTAssertNil(FuzzyMatcher.score("freeze", row.title), "‘freeze’ is not a subsequence of the title")
        XCTAssertNil(row.subtitle, "the row renders no subtitle, so ‘freeze’ can only match the hidden keywords")
        XCTAssertTrue(ids("freeze").contains("action.toggleReadOnly"), "yet ‘freeze’ still finds the row")
    }

    // MARK: - E21 WI-3 — the Read Only palette verb is a first-class peer for a `.remoteGUI` active pane

    /// The "Read Only" palette verb is KIND-GENERIC: its `.store` run-arm (`toggleReadOnlyInActivePane`) reaches
    /// a `.remoteGUI` active pane (a remote host window streamed over the video path), flipping the SAME
    /// convergent ``WorkspaceStore/paneReadOnly`` set the pill `🔒 READ ONLY ×` + the sidebar lock read — and
    /// thereby the video seam's `inputEnabled` gate. Drives the catalog row's run-arm against a store whose
    /// active pane is a video pane, proving the palette path does not silently exclude the video kind. Fails on
    /// any build that gated the read-only verb to a terminal pane (it would no-op here and the lock never set).
    func testReadOnlyPaletteVerbReachesARemoteGUIActivePane() throws {
        let store = WorkspaceStore(liveModel: .tree, makeSession: { MountTestPaneSession($0) })
        let video = store.newRemoteWindowTab(windowID: 11, title: "Safari", appName: "Safari")
        store.focusPaneTree(video)
        XCTAssertEqual(store.activePaneID, video, "the remote window is the active pane")
        XCTAssertFalse(store.isReadOnly(for: video), "a fresh remote window is writable")

        let row = try XCTUnwrap(ActionsPaletteSource.catalog.first { $0.id == "action.toggleReadOnly" })
        guard case let .store(run) = row.action else {
            XCTFail("Read Only is a `.store` run-arm")
            return
        }

        run(store)
        XCTAssertTrue(store.isReadOnly(for: video), "the palette Read Only verb locks the `.remoteGUI` active pane")
        run(store)
        XCTAssertFalse(store.isReadOnly(for: video), "and the same verb unlocks it (kind-generic toggle)")
    }
}
