import Foundation
import XCTest
@testable import AislopdeskWorkspaceCore

/// Pins WI-3 of E16: the `.ottyrecipe` TOML codec (``RecipeTOMLCodec``). `emit` matches the documented
/// byte-shape; `parse` is validate-then-drop on untrusted disk input — `nil` on malformed / missing
/// `[recipe]` / unknown `scope` / over-count panes, `size` clamped to `0…1` with ordered min/max, an
/// unknown `split` dropped (pane survives), and single-quoted literal cwds with `{{current_folder}}`
/// surviving verbatim. Fully headless — no view, no NSWindow, no disk, no `Date()`.
final class RecipeTOMLCodecTests: XCTestCase {
    // MARK: - the spec's `deploy-prod-debug` example as a value

    /// The exact recipe from `spec/customization__custom-commands.md` § "The `.ottyrecipe` File Format".
    private func specRecipe() -> Recipe {
        Recipe(
            name: "deploy-prod-debug",
            version: 1,
            scope: .window,
            window: RecipeWindow(tabs: [
                RecipeTab(title: "API", panes: [
                    RecipePane(cwd: "{{current_folder}}/api", commands: ["tail -F log/prod.log"]),
                    RecipePane(
                        cwd: "{{current_folder}}/api",
                        commands: ["make deploy"],
                        split: .right,
                        size: 0.5,
                    ),
                ]),
                RecipeTab(title: "Web", panes: [
                    RecipePane(cwd: "{{current_folder}}/web", commands: ["npm run preview"]),
                ]),
            ]),
        )
    }

    // MARK: - emit byte-shape

    func testEmitMatchesDocumentedByteShape() {
        // Pins the EXACT serialised shape (arrays-of-tables, key order, blank-line separators, trailing \n).
        let expected = """
        [recipe]
        name = "deploy-prod-debug"
        version = 1
        scope = "window"

        [[window.tabs]]
        title = "API"

        [[window.tabs.panes]]
        cwd = "{{current_folder}}/api"
        commands = ["tail -F log/prod.log"]

        [[window.tabs.panes]]
        cwd = "{{current_folder}}/api"
        split = "right"
        size = 0.5
        commands = ["make deploy"]

        [[window.tabs]]
        title = "Web"

        [[window.tabs.panes]]
        cwd = "{{current_folder}}/web"
        commands = ["npm run preview"]

        """
        XCTAssertEqual(RecipeTOMLCodec.emit(specRecipe()), expected)
    }

    // MARK: - round-trip (emit → parse → equal)

    func testRoundTripSpecExample() {
        let recipe = specRecipe()
        let emitted = RecipeTOMLCodec.emit(recipe)
        XCTAssertEqual(RecipeTOMLCodec.parse(emitted), recipe, "emit → parse must be an identity")
    }

    func testParsesLiteralSpecTextWithComments() {
        // The verbatim spec example, WITH trailing `#` comments — comment-stripping + arrays-of-tables
        // nesting must yield the same value as the round-trip recipe.
        let toml = """
        [recipe]
        name = "deploy-prod-debug"
        version = 1
        scope = "window"          # "tab" | "window" | "commands"

        [[window.tabs]]
        title = "API"

        [[window.tabs.panes]]
        cwd = "{{current_folder}}/api"
        commands = ["tail -F log/prod.log"]

        [[window.tabs.panes]]
        cwd = "{{current_folder}}/api"
        split = "right"           # relative to the previous pane
        size = 0.5                # 0.0-1.0 of the parent
        commands = ["make deploy"]

        [[window.tabs]]
        title = "Web"

        [[window.tabs.panes]]
        cwd = "{{current_folder}}/web"
        commands = ["npm run preview"]
        """
        XCTAssertEqual(RecipeTOMLCodec.parse(toml), specRecipe())
    }

    func testLayoutOnlyPaneRoundTripsWithCommandsOmitted() {
        // A Layout-Only pane has empty commands → emit OMITS the `commands` key → parse restores [].
        let recipe = Recipe(
            name: "layout",
            scope: .tab,
            window: RecipeWindow(tabs: [
                RecipeTab(title: "t", panes: [RecipePane(cwd: "/work")]),
            ]),
        )
        let emitted = RecipeTOMLCodec.emit(recipe)
        XCTAssertFalse(emitted.contains("commands"), "no commands key is emitted for a Layout-Only pane")
        XCTAssertEqual(RecipeTOMLCodec.parse(emitted), recipe)
    }

    func testCommandsWithQuotesAndBackslashRoundTrip() {
        // Verbatim shell commands containing `"` and `\` must survive the double-quoted-with-escapes emit.
        let recipe = Recipe(
            name: "escapes",
            scope: .commands,
            window: RecipeWindow(tabs: [
                RecipeTab(panes: [
                    RecipePane(commands: [#"echo "hi""#, #"printf 'a\b'"#, "a, b"]),
                ]),
            ]),
        )
        let emitted = RecipeTOMLCodec.emit(recipe)
        XCTAssertEqual(RecipeTOMLCodec.parse(emitted), recipe, "quotes / backslash / comma survive round-trip")
    }

    // MARK: - validate-then-drop: nil cases

    func testMalformedReturnsNil() {
        // Unterminated table header.
        XCTAssertNil(RecipeTOMLCodec.parse("[recipe\nname = \"x\"\nscope = \"tab\""))
        // A key with no enclosing table (a stray top-level assignment).
        XCTAssertNil(RecipeTOMLCodec.parse("name = \"x\""))
        // A garbage line that is neither a header nor a `key = value`.
        XCTAssertNil(RecipeTOMLCodec.parse("[recipe]\nname = \"x\"\nscope = \"tab\"\nthis is not toml"))
        // An unterminated string value.
        XCTAssertNil(RecipeTOMLCodec.parse("[recipe]\nname = \"unterminated\nscope = \"tab\""))
    }

    func testMissingRecipeTableReturnsNil() {
        // A file with tabs but NO `[recipe]` table → there is no recipe to open.
        let toml = """
        [[window.tabs]]
        title = "API"

        [[window.tabs.panes]]
        cwd = "/work"
        """
        XCTAssertNil(RecipeTOMLCodec.parse(toml))
    }

    func testMissingNameReturnsNil() {
        XCTAssertNil(RecipeTOMLCodec.parse("[recipe]\nscope = \"window\""))
        XCTAssertNil(RecipeTOMLCodec.parse("[recipe]\nname = \"\"\nscope = \"window\""), "empty name drops")
    }

    func testUnknownScopeReturnsNil() {
        XCTAssertNil(RecipeTOMLCodec.parse("[recipe]\nname = \"x\"\nscope = \"galaxy\""))
        XCTAssertNil(RecipeTOMLCodec.parse("[recipe]\nname = \"x\""), "missing scope also drops")
    }

    func testUnknownTableOrArraySectionReturnsNil() {
        XCTAssertNil(RecipeTOMLCodec.parse("[recipe]\nname = \"x\"\nscope = \"tab\"\n[mystery]\nk = \"v\""))
        // A pane header before any tab is malformed structure.
        XCTAssertNil(RecipeTOMLCodec.parse("[recipe]\nname = \"x\"\nscope = \"tab\"\n[[window.tabs.panes]]"))
    }

    // MARK: - size clamp (ordered min/max, never FMA)

    func testSizeAboveOneClampsToOne() {
        let toml = """
        [recipe]
        name = "x"
        scope = "window"

        [[window.tabs]]
        [[window.tabs.panes]]
        size = 1.7
        """
        let recipe = RecipeTOMLCodec.parse(toml)
        XCTAssertEqual(recipe?.window.tabs.first?.panes.first?.size, 1.0, "1.7 clamps to the 1.0 ceiling")
    }

    func testSizeBelowZeroClampsToZero() {
        let toml = """
        [recipe]
        name = "x"
        scope = "window"

        [[window.tabs]]
        [[window.tabs.panes]]
        size = -0.5
        """
        XCTAssertEqual(RecipeTOMLCodec.parse(toml)?.window.tabs.first?.panes.first?.size, 0.0)
    }

    func testClampSizeHelperIsNaNFaithfulOrderedMinMax() {
        // The helper itself (CLAUDE.md §2): ordered min/max, NEVER a bare `<`/`>` ternary, NEVER FMA.
        XCTAssertEqual(RecipePane.clampSize(0.5), 0.5, "an in-range value is unchanged")
        XCTAssertEqual(RecipePane.clampSize(0.0), 0.0)
        XCTAssertEqual(RecipePane.clampSize(1.0), 1.0)
        XCTAssertEqual(RecipePane.clampSize(2.0), 1.0)
        XCTAssertEqual(RecipePane.clampSize(-1.0), 0.0)
        // NaN resolves to the OTHER operand (0.0) — a bare `<` ternary would propagate NaN.
        XCTAssertEqual(RecipePane.clampSize(.nan), 0.0, "NaN clamps to 0.0, never propagates")
        XCTAssertEqual(RecipePane.clampSize(.infinity), 1.0)
        XCTAssertEqual(RecipePane.clampSize(-.infinity), 0.0)
    }

    // MARK: - unknown split: drop the field, keep the pane

    func testUnknownSplitIsDroppedButRecipeStillParses() {
        let toml = """
        [recipe]
        name = "x"
        scope = "window"

        [[window.tabs]]
        [[window.tabs.panes]]
        cwd = "/work"
        split = "diagonal"
        """
        let pane = RecipeTOMLCodec.parse(toml)?.window.tabs.first?.panes.first
        XCTAssertNotNil(pane, "an unknown split must NOT drop the whole file")
        XCTAssertNil(pane?.split, "the unknown split direction is dropped to nil")
        XCTAssertEqual(pane?.cwd, "/work", "the rest of the pane survives")
    }

    func testKnownSplitDirectionsParse() {
        for direction in RecipeSplit.allCases {
            let toml = """
            [recipe]
            name = "x"
            scope = "window"

            [[window.tabs]]
            [[window.tabs.panes]]
            split = "\(direction.rawValue)"
            """
            XCTAssertEqual(RecipeTOMLCodec.parse(toml)?.window.tabs.first?.panes.first?.split, direction)
        }
    }

    // MARK: - over-count panes validated BEFORE allocating (no crash, no force-unwrap)

    func testOverCountPanesAreValidatedAndDropped() {
        var toml = "[recipe]\nname = \"x\"\nscope = \"window\"\n\n[[window.tabs]]\n"
        // One more pane header than the bound → DROP (bounded allocation, no trap).
        for _ in 0...RecipeTOMLCodec.maxPanesPerTab {
            toml += "[[window.tabs.panes]]\n"
        }
        XCTAssertNil(RecipeTOMLCodec.parse(toml), "a structure past maxPanesPerTab is dropped, never crashes")
    }

    func testExactlyMaxPanesParse() {
        var toml = "[recipe]\nname = \"x\"\nscope = \"window\"\n\n[[window.tabs]]\n"
        for _ in 0..<RecipeTOMLCodec.maxPanesPerTab {
            toml += "[[window.tabs.panes]]\n"
        }
        let recipe = RecipeTOMLCodec.parse(toml)
        XCTAssertEqual(
            recipe?.window.tabs.first?.panes.count,
            RecipeTOMLCodec.maxPanesPerTab,
            "the bound itself is allowed",
        )
    }

    // MARK: - single-quoted literal cwd survives verbatim

    func testSingleQuotedLiteralCwdSurvives() {
        // A TOML LITERAL (single-quoted) string: no escapes, `{{…}}` survives verbatim.
        let toml = """
        [recipe]
        name = "x"
        scope = "window"

        [[window.tabs]]
        [[window.tabs.panes]]
        cwd = '{{current_folder}}/api'
        """
        XCTAssertEqual(
            RecipeTOMLCodec.parse(toml)?.window.tabs.first?.panes.first?.cwd,
            "{{current_folder}}/api",
            "the literal template path is preserved unescaped",
        )
    }

    func testLiteralStringWithHashIsNotTreatedAsComment() {
        // Inside a single-quoted literal a `#` is NOT a comment.
        let toml = """
        [recipe]
        name = "x"
        scope = "window"

        [[window.tabs]]
        [[window.tabs.panes]]
        cwd = '/work/#branch'
        """
        XCTAssertEqual(RecipeTOMLCodec.parse(toml)?.window.tabs.first?.panes.first?.cwd, "/work/#branch")
    }

    // MARK: - version handling

    func testVersionDefaultsToCurrentWhenAbsentAndIsTrapFreeOnHostileValue() {
        let parsed = RecipeTOMLCodec.parse("[recipe]\nname = \"x\"\nscope = \"tab\"")
        XCTAssertEqual(parsed?.version, Recipe.currentVersion, "absent version → current default")
        // A hostile out-of-range version must NOT trap `Int(Double)` — it keeps the default.
        let hostile = RecipeTOMLCodec.parse("[recipe]\nname = \"x\"\nscope = \"tab\"\nversion = 1e400")
        XCTAssertEqual(hostile?.version, Recipe.currentVersion, "a wild version is ignored, never traps")
    }
}
