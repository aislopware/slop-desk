import Foundation
import XCTest
@testable import AislopdeskWorkspaceCore

/// Pins WI-4 of E16: the recipe-cwd portable-path layer (``PortablePaths``). `portabilize` replaces the
/// LONGEST matching base prefix of an absolute cwd with its template token at SAVE; `resolve` re-expands the
/// token at OPEN. Boundary-aware (a base must match on a `/` boundary), tie-broken most-specific-first, and a
/// pure round-trip when the bases are consistent. Fully headless — no `FileManager`, no disk, no `Date`.
final class PortablePathsTests: XCTestCase {
    // MARK: - round-trip

    func testPortabilizeResolveRoundTrip() {
        let abs = "/work/api"
        let portable = PortablePaths.portabilize(
            abs, home: "/Users/me", currentFolder: "/work", recipeLocation: "/recipes",
        )
        XCTAssertEqual(portable, "{{current_folder}}/api")
        XCTAssertEqual(
            PortablePaths.resolve(portable, home: "/Users/me", currentFolder: "/work", recipeLocation: "/recipes"),
            abs,
            "resolve is the inverse of portabilize when the bases are consistent",
        )
    }

    // MARK: - longest-prefix wins

    func testLongestPrefixWins() {
        // home ⊂ currentFolder ⊂ path → the LONGEST matched base (current_folder) wins, NOT home.
        let abs = "/Users/me/proj/api"
        XCTAssertEqual(
            PortablePaths.portabilize(abs, home: "/Users/me", currentFolder: "/Users/me/proj", recipeLocation: ""),
            "{{current_folder}}/api",
        )
    }

    // MARK: - per-token coverage

    func testHomeFolderTemplate() {
        XCTAssertEqual(
            PortablePaths.portabilize(
                "/Users/me/notes",
                home: "/Users/me",
                currentFolder: "/elsewhere",
                recipeLocation: "",
            ),
            "{{home_folder}}/notes",
            "a path under the home dir (~) portabilizes to {{home_folder}}",
        )
        // An EXACT home match → the bare token (empty remainder).
        XCTAssertEqual(
            PortablePaths.portabilize("/Users/me", home: "/Users/me", currentFolder: "", recipeLocation: ""),
            "{{home_folder}}",
        )
        XCTAssertEqual(
            PortablePaths.resolve("{{home_folder}}/notes", home: "/Users/me", currentFolder: "", recipeLocation: ""),
            "/Users/me/notes",
        )
    }

    func testRecipeLocationTemplate() {
        XCTAssertEqual(
            PortablePaths.portabilize(
                "/recipes/shared/api",
                home: "",
                currentFolder: "",
                recipeLocation: "/recipes/shared",
            ),
            "{{recipe_location}}/api",
        )
        XCTAssertEqual(
            PortablePaths.resolve(
                "{{recipe_location}}/api",
                home: "",
                currentFolder: "",
                recipeLocation: "/recipes/shared",
            ),
            "/recipes/shared/api",
        )
    }

    // MARK: - non-matches + boundaries

    func testNoMatchingBaseLeavesPathUnchanged() {
        XCTAssertEqual(
            PortablePaths.portabilize(
                "/var/log",
                home: "/Users/me",
                currentFolder: "/work",
                recipeLocation: "/recipes",
            ),
            "/var/log",
        )
    }

    func testPrefixMatchRespectsPathBoundaries() {
        // "/Users/me" is a string prefix of "/Users/menlo/x" but NOT a path-boundary prefix → no match.
        XCTAssertEqual(
            PortablePaths.portabilize("/Users/menlo/x", home: "/Users/me", currentFolder: "", recipeLocation: ""),
            "/Users/menlo/x",
        )
    }

    func testTrailingSlashOnBaseIsNormalized() {
        XCTAssertEqual(
            PortablePaths.portabilize("/work/api", home: "", currentFolder: "/work/", recipeLocation: ""),
            "{{current_folder}}/api",
            "a base recorded with a trailing slash matches identically",
        )
    }

    func testEmptyBaseNeverMatches() {
        XCTAssertEqual(
            PortablePaths.portabilize("/anything", home: "", currentFolder: "", recipeLocation: ""),
            "/anything",
            "an empty base never matches (would otherwise swallow every path)",
        )
    }

    func testTieBreakPrefersCurrentFolder() {
        // current_folder and home are the SAME base → equal matched length → the higher-priority
        // current_folder token wins.
        XCTAssertEqual(
            PortablePaths.portabilize("/shared/x", home: "/shared", currentFolder: "/shared", recipeLocation: ""),
            "{{current_folder}}/x",
        )
    }

    // MARK: - resolve leaves foreign templates alone

    func testResolveLeavesUnknownTemplateVerbatim() {
        // Only the three closed recipe tokens are substituted; an unrelated `{{x}}` is left verbatim.
        XCTAssertEqual(
            PortablePaths.resolve("{{mystery}}/x", home: "/h", currentFolder: "/c", recipeLocation: "/r"),
            "{{mystery}}/x",
        )
    }
}
