import XCTest
@testable import AislopdeskClientUI
@testable import AislopdeskWorkspaceCore

/// E16 WI-7 — the saved-snippet command-palette source. Snippets are surfaced under the verbs-only ⌘⇧P
/// palette by name (otty "snippets appear in the command palette"), so a `SnippetPaletteSource` snapshot of
/// the store's snippets must produce one runnable row per snippet, searchable by name AND by alias. Headless:
/// the source is a pure value over a snapshot; no NSWindow / view.
@MainActor
final class SnippetPaletteSourceTests: XCTestCase {
    private func makeStore() -> WorkspaceStore {
        WorkspaceStore(liveModel: .tree, makeSession: { MountTestPaneSession($0) })
    }

    /// A snapshot yields exactly one row per snippet — id namespaced `snippet.<uuid>`, title = display name,
    /// the alias on BOTH the subtitle + the hidden keywords (nil when blank). FAILS before the source exists.
    func testSnapshotProducesRowPerSnippet() {
        let store = makeStore()
        let withAlias = store.addSnippet(name: "Deploy Prod", body: "make deploy", alias: "dp")
        let noAlias = store.addSnippet(name: "List Pods", body: "kubectl get pods", alias: "")

        let rows = SnippetPaletteSource.snapshot(store).candidates(query: "")
        XCTAssertEqual(rows.count, 2, "one row per snippet")

        let r0 = rows.first { $0.id == "snippet.\(withAlias.id.uuidString)" }
        XCTAssertEqual(r0?.title, "Deploy Prod")
        XCTAssertEqual(r0?.subtitle, "dp", "the alias renders as the subtitle")
        XCTAssertEqual(r0?.keywords, "dp", "the alias is also a hidden search keyword")
        XCTAssertEqual(r0?.filter, .actions, "snippets ride the verbs-only Actions filter")

        let r1 = rows.first { $0.id == "snippet.\(noAlias.id.uuidString)" }
        XCTAssertEqual(r1?.title, "List Pods")
        XCTAssertNil(r1?.subtitle, "no alias ⇒ no subtitle")
        XCTAssertNil(r1?.keywords, "no alias ⇒ no keyword")
    }

    /// A blank snippet name snapshots to the "Snippet" display fallback so the palette never shows an empty
    /// row (mirrors the store's `snippetName` normalization).
    func testBlankNameRendersDisplayFallback() {
        let store = makeStore()
        let blank = store.addSnippet(name: "   ", body: "echo hi", alias: "")
        let rows = SnippetPaletteSource.snapshot(store).candidates(query: "")
        XCTAssertEqual(rows.first { $0.id == "snippet.\(blank.id.uuidString)" }?.title, "Snippet")
    }

    /// Through the live mixer, a snippet surfaces under a "Snippets" section header when the query matches its
    /// NAME and, separately, when the query matches only its ALIAS (via the hidden keyword fold). Control: a
    /// query matching neither returns no snippet row. FAILS before the source is registered + keyword-folded.
    func testMixerSurfacesSnippetByNameAndAlias() {
        let store = makeStore()
        let snippet = store.addSnippet(name: "Deploy Prod", body: "make deploy", alias: "dpx")
        let mixer = SearchMixer(sources: [SnippetPaletteSource.snapshot(store)])
        let rowID = "snippet.\(snippet.id.uuidString)"

        let byName = mixer.results(query: "Deploy")
        XCTAssertTrue(byName.contains { $0.id == rowID }, "a name query surfaces the snippet")
        XCTAssertTrue(
            byName.contains { $0.isSeparator && $0.title == "Snippets" },
            "snippet rows group under a Snippets section header",
        )

        let byAlias = SearchMixer.selectable(mixer.results(query: "dpx"))
        XCTAssertTrue(byAlias.contains { $0.id == rowID }, "an alias query surfaces the snippet via keywords")

        let byNothing = SearchMixer.selectable(mixer.results(query: "zzzzqqqq"))
        XCTAssertFalse(byNothing.contains { $0.id == rowID }, "an unrelated query does not surface the snippet")
    }
}
