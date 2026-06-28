import Foundation
import XCTest
@testable import AislopdeskClientUI
@testable import AislopdeskWorkspaceCore

/// E16 / M1 — the recipe command-palette source. The command palette is one of otty's THREE documented recipe
/// surfaces (Settings ▸ Recipes, File ▸ Recipe menu, the command palette) and is the ONLY cross-platform one,
/// so a `RecipePaletteSource` must surface "Save Recipe…" / "Open Recipe…" verb rows (arming the store's
/// `requestSaveRecipe()` / `requestOpenRecipe()` edges) plus one row per saved `.ottyrecipe`. This also makes
/// Save / Open Recipe reachable on iOS (no menu, no ⌘S). Headless: the source is a pure value over a snapshot,
/// the row actions run against a store with NO NSWindow / view.
@MainActor
final class RecipePaletteSourceTests: XCTestCase {
    /// A fresh temp `HOME` per test so the recipe library + trust store are isolated.
    private lazy var tempHome: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("aislopdesk-recipe-palette-\(UUID().uuidString)", isDirectory: true)

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempHome)
        super.tearDown()
    }

    private func makeStore() -> WorkspaceStore {
        let store = WorkspaceStore(liveModel: .tree, makeSession: { MountTestPaneSession($0) })
        store.recipes.environment = ["HOME": tempHome.path]
        return store
    }

    /// The two FIXED verb rows are present and their `.store` actions route to the matching store edges. This
    /// FAILS on the un-fixed source (no `RecipePaletteSource` exists ⇒ no rows, recipes unreachable from the
    /// palette / iOS). Asserts via the live store's `pending*` flags, not the row's own derivation.
    func testSaveAndOpenVerbRowsRouteToStore() throws {
        let store = makeStore()
        let rows = RecipePaletteSource(entries: []).candidates(query: "")

        let save = try XCTUnwrap(rows.first { $0.id == "recipe.save" })
        let open = try XCTUnwrap(rows.first { $0.id == "recipe.open" })
        XCTAssertEqual(save.title, "Save Recipe…")
        XCTAssertEqual(open.title, "Open Recipe…")
        XCTAssertEqual(save.filter, .actions, "recipe rows ride the verbs-only Actions filter")

        XCTAssertFalse(store.recipes.pendingSaveRecipe)
        guard case let .store(runSave) = save.action else {
            XCTFail("Save row is not a store action")
            return
        }
        runSave(store)
        XCTAssertTrue(store.recipes.pendingSaveRecipe, "Save Recipe… arms requestSaveRecipe()")

        XCTAssertFalse(store.recipes.pendingOpenRecipe)
        guard case let .store(runOpen) = open.action else {
            XCTFail("Open row is not a store action")
            return
        }
        runOpen(store)
        XCTAssertTrue(store.recipes.pendingOpenRecipe, "Open Recipe… arms requestOpenRecipe()")
    }

    /// A snapshot lists one row per saved `.ottyrecipe` ("Open Recipe: <name>"), opening it from the library.
    func testSnapshotProducesRowPerSavedRecipe() throws {
        let store = makeStore()
        _ = try XCTUnwrap(store.saveRecipe(scope: .window, content: .layoutOnly, name: "Layout A"))

        let rows = RecipePaletteSource.snapshot(store).candidates(query: "")
        let saved = rows.first { $0.title == "Open Recipe: Layout A" }
        XCTAssertNotNil(saved, "the saved recipe surfaces as an 'Open Recipe: <name>' palette row")
        XCTAssertEqual(saved?.filter, .actions)
    }

    /// Through the live mixer, the recipe rows surface under a "Recipes" section header for a matching query;
    /// an unrelated query surfaces none.
    func testMixerSurfacesRecipesUnderSection() {
        let store = makeStore()
        let mixer = SearchMixer(sources: [RecipePaletteSource.snapshot(store)])

        let hit = mixer.results(query: "Save Recipe")
        XCTAssertTrue(hit.contains { $0.id == "recipe.save" }, "a query surfaces the Save Recipe verb")
        XCTAssertTrue(
            hit.contains { $0.isSeparator && $0.title == "Recipes" },
            "recipe rows group under a Recipes section header",
        )

        let miss = SearchMixer.selectable(mixer.results(query: "zzzzqqqq"))
        XCTAssertFalse(miss.contains { $0.id == "recipe.save" }, "an unrelated query surfaces no recipe row")
    }
}
