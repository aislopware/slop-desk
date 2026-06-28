import CoreGraphics
import Foundation
import XCTest
@testable import AislopdeskWorkspaceCore

/// Pins WI-1 of E16: the `Snippet.alias` field (no-spaces normalizer + additive Codable) and the pure
/// `SnippetAliasIndex.match(typed:snippets:)` at-prompt lookup, plus the `WorkspaceStore` CRUD threading.
/// Everything here is headless — no view, no NSWindow.
@MainActor
final class SnippetAliasTests: XCTestCase {
    // MARK: - alias normalizer (spaces stripped)

    func testAliasStripsAllWhitespaceOnConstruction() {
        XCTAssertEqual(Snippet(name: "n", body: "b", alias: "g co").alias, "gco", "interior space stripped")
        XCTAssertEqual(Snippet(name: "n", body: "b", alias: "  deploy  ").alias, "deploy", "edge spaces stripped")
        XCTAssertEqual(Snippet(name: "n", body: "b", alias: "a\tb\nc").alias, "abc", "tabs/newlines stripped too")
        XCTAssertEqual(Snippet(name: "n", body: "b").alias, "", "no alias defaults to empty")
        // The normalizer is the single source of truth and is idempotent.
        XCTAssertEqual(Snippet.normalizeAlias(Snippet.normalizeAlias("g co")), "gco")
    }

    // MARK: - Codable round-trip + additive decode

    func testAliasRoundTripsThroughCodable() throws {
        let s = Snippet(name: "checkout", body: "git checkout {{cursor}}", alias: "gco")
        let data = try JSONEncoder().encode(s)
        let decoded = try JSONDecoder().decode(Snippet.self, from: data)
        XCTAssertEqual(decoded, s, "the whole value (incl. alias) round-trips")
        XCTAssertEqual(decoded.alias, "gco")
    }

    func testOldBlobWithoutAliasDecodesToEmptyAlias() throws {
        // A pre-E16 Workspace.snippets element carries no `alias` key — it must decode (no keyNotFound throw)
        // with alias defaulting to "".
        let oldBlob: [String: Any] = ["id": UUID().uuidString, "name": "deploy", "body": "make deploy<Enter>"]
        let data = try JSONSerialization.data(withJSONObject: oldBlob)
        let decoded = try JSONDecoder().decode(Snippet.self, from: data)
        XCTAssertEqual(decoded.alias, "", "a missing alias key decodes to the empty 'no alias' default")
        XCTAssertEqual(decoded.name, "deploy")
        XCTAssertEqual(decoded.body, "make deploy<Enter>")
    }

    func testDecodeReNormalizesAStraySpaceInAPersistedAlias() throws {
        // Defense: even if a hand-edited blob smuggles a space into the alias, decode strips it so an alias
        // is space-free regardless of how it reached disk.
        let blob: [String: Any] = ["id": UUID().uuidString, "name": "n", "body": "b", "alias": "g co"]
        let data = try JSONSerialization.data(withJSONObject: blob)
        XCTAssertEqual(try JSONDecoder().decode(Snippet.self, from: data).alias, "gco")
    }

    // MARK: - SnippetAliasIndex.match (trailing-word-boundary lookup)

    private var gco: Snippet { Snippet(name: "checkout", body: "git checkout {{cursor}}", alias: "gco") }
    private var ll: Snippet { Snippet(name: "long-list", body: "ls -la", alias: "ll") }

    func testMatchFindsAliasAsTheTrailingWord() {
        let snippets = [gco, ll]
        // Whole line is the alias (start-of-line boundary).
        XCTAssertEqual(SnippetAliasIndex.match(typed: "gco", snippets: snippets)?.alias, "gco")
        // Alias is the trailing word after a whitespace boundary.
        XCTAssertEqual(SnippetAliasIndex.match(typed: "git status && gco", snippets: snippets)?.alias, "gco")
        // A newline counts as a boundary too.
        XCTAssertEqual(SnippetAliasIndex.match(typed: "echo hi\nll", snippets: snippets)?.alias, "ll")
    }

    func testMatchReturnsNilMidWord() {
        // "gco" is a SUFFIX of "mygco" but there is no boundary in front of it → not a trailing word →
        // ordinary typing is never corrupted.
        XCTAssertNil(SnippetAliasIndex.match(typed: "mygco", snippets: [gco]))
        XCTAssertNil(SnippetAliasIndex.match(typed: "ll", snippets: [gco]), "different alias still nil")
    }

    func testMatchReturnsNilForUnknownEmptyOrCompletedWord() {
        let snippets = [gco, ll]
        XCTAssertNil(SnippetAliasIndex.match(typed: "deploy", snippets: snippets), "unknown alias → nil")
        XCTAssertNil(SnippetAliasIndex.match(typed: "", snippets: snippets), "empty line → nil")
        XCTAssertNil(
            SnippetAliasIndex.match(typed: "gco ", snippets: snippets),
            "trailing space → word already submitted → nil",
        )
        XCTAssertNil(SnippetAliasIndex.match(typed: "anything", snippets: []), "no snippets → nil")
    }

    func testMatchNeverMatchesAnEmptyAlias() {
        // A snippet with no alias (run-by-name-only) must never be triggered at the prompt.
        let noAlias = Snippet(name: "x", body: "y")
        XCTAssertNil(SnippetAliasIndex.match(typed: "x", snippets: [noAlias]))
        XCTAssertNil(SnippetAliasIndex.match(typed: "", snippets: [noAlias]))
    }

    // MARK: - Store CRUD threads the alias

    private func store() -> WorkspaceStore {
        let pane = CanvasItem(
            id: PaneID(),
            spec: PaneSpec(kind: .terminal, title: "t"),
            frame: CGRect(x: 0, y: 0, width: 300, height: 200),
            z: 0,
        )
        return WorkspaceStore(
            restoring: Workspace(canvas: Canvas(items: [pane]), focusedPane: pane.id),
            makeSession: { FakePaneSession($0) },
            liveVideoCap: 5,
        )
    }

    func testAddSnippetThreadsAndNormalizesAlias() {
        let st = store()
        let s = st.addSnippet(name: "checkout", body: "git checkout {{cursor}}", alias: "g co")
        XCTAssertEqual(s.alias, "gco", "addSnippet normalizes the alias")
        XCTAssertEqual(st.snippets.first?.alias, "gco", "and persists it on the workspace")
    }

    func testUpdateSnippetReNormalizesAlias() {
        let st = store()
        let s = st.addSnippet(name: "checkout", body: "git checkout", alias: "gco")
        st.updateSnippet(s.id, name: "checkout", body: "git checkout", alias: " gco2 ")
        XCTAssertEqual(st.snippets.first?.alias, "gco2", "updateSnippet re-normalizes + persists the alias")
    }

    func testAliasSurvivesWorkspaceCodableRoundTrip() throws {
        let st = store()
        st.addSnippet(name: "checkout", body: "git checkout {{cursor}}", alias: "gco")
        let data = try JSONEncoder().encode(st.workspace)
        let decoded = try JSONDecoder().decode(Workspace.self, from: data)
        XCTAssertEqual(decoded.snippets.first?.alias, "gco", "alias persists through the whole-workspace blob")
    }

    func testNormalizingCollectionsPreservesAliasWhenRemintingADuplicateID() {
        // A duplicate snippet id is re-minted on load; the re-mint must NOT drop the alias.
        let shared = UUID()
        let ws = Workspace(
            canvas: Canvas(items: []),
            focusedPane: nil,
            snippets: [
                Snippet(id: shared, name: "a", body: "x", alias: "aa"),
                Snippet(id: shared, name: "b", body: "y", alias: "bb"),
            ],
        )
        let normalized = ws.normalizingCollections()
        XCTAssertEqual(normalized.snippets.map(\.alias), ["aa", "bb"], "both aliases survive the re-mint")
        XCTAssertEqual(Set(normalized.snippets.map(\.id)).count, 2, "the duplicate id is re-minted")
    }
}
