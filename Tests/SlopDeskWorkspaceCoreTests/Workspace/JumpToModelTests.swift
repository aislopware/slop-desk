import Foundation
import XCTest
@testable import SlopDeskWorkspaceCore

/// The pure Jump-To panel model. These pin the ASSEMBLY (detected links first, then
/// the OSC-133 command/prompt index; empty commands skipped; duplicate links deduped; the right type
/// badge/icon/timestamp per row; the right scrollback-jump / link `Act`) and the FILTER (an injected
/// scorer drops non-matches and orders survivors by score descending with a STABLE tie-break; an empty
/// query returns the list unchanged). Plus the ⌘J binding presence + chord-uniqueness.
///
/// Each assertion is revert-to-confirm-fail — it fails on a model that forgets to dedup links, emits a row
/// for an empty command, mis-orders the groups, loses a timestamp, or fails to drop a non-matching item.
final class JumpToModelTests: XCTestCase {
    // MARK: - Fixtures

    private func link(_ kind: DetectedLinkKind, raw: String, resolved: String? = nil) -> DetectedLink {
        DetectedLink(row: 0, colStart: 0, colEnd: raw.count, kind: kind, raw: raw, resolvedAbsolute: resolved)
    }

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Assembly

    func testItemsAssembleLinksFirstThenBlocks() {
        let links = [
            link(.absolutePath, raw: "/usr/local/bin/foo", resolved: "/usr/local/bin/foo"),
            link(.url, raw: "https://chatgpt.com/x"),
            link(.fileURL, raw: "file:///a/b.txt", resolved: "/a/b.txt"),
        ]
        let blocks = [
            BlockSummary(index: 7, commandText: "git status", firstSeen: t0),
            BlockSummary(index: 6, commandText: "ls -la", firstSeen: t0),
        ]
        let items = JumpToModel.items(links: links, blocks: blocks)

        XCTAssertEqual(items.count, 5, "3 links + 2 commands")
        // Links lead, in detection order.
        XCTAssertEqual(items[0].kind, .path)
        XCTAssertEqual(items[0].title, "/usr/local/bin/foo")
        XCTAssertEqual(items[0].badge, "Path")
        XCTAssertEqual(items[1].kind, .url)
        XCTAssertEqual(items[1].badge, "URL")
        XCTAssertEqual(items[2].kind, .fileURL)
        XCTAssertEqual(items[2].badge, "File")
        // Then the blocks, in the order given (caller passes newest-first).
        XCTAssertEqual(items[3].kind, .command)
        XCTAssertEqual(items[3].badge, "Cmd")
        XCTAssertEqual(items[3].title, "git status")
        XCTAssertEqual(items[3].timestamp, t0, "a command row carries the block's first-seen timestamp")
        if case let .block(index) = items[3].act {
            XCTAssertEqual(index, 7, "the command row jumps to its block index")
        } else {
            XCTFail("a command row's act must be .block")
        }
        XCTAssertNil(items[0].timestamp, "a link row carries no timestamp")
        if case .link = items[0].act {} else { XCTFail("a link row's act must be .link") }
    }

    func testItemsSkipEmptyCommandBlocks() {
        let blocks = [
            BlockSummary(index: 2, commandText: "make build"),
            BlockSummary(index: 3, commandText: "", firstSeen: t0), // still-forming block — no row
        ]
        let items = JumpToModel.items(links: [], blocks: blocks)
        XCTAssertEqual(items.count, 1, "the empty-command block is skipped")
        XCTAssertEqual(items.first?.title, "make build")
    }

    func testDuplicateLinksAreDeduped() {
        let dup = link(.absolutePath, raw: "/etc/hosts", resolved: "/etc/hosts")
        let items = JumpToModel.items(links: [dup, dup, dup], blocks: [])
        XCTAssertEqual(items.count, 1, "the same path printed three times is ONE row")
    }

    func testSamePathDifferentKindAreDistinctRows() {
        // A `/etc/hosts` absolute path and a `file:///etc/hosts` URL are different rows (kind in the id).
        let items = JumpToModel.items(
            links: [
                link(.absolutePath, raw: "/etc/hosts"),
                link(.fileURL, raw: "file:///etc/hosts", resolved: "/etc/hosts"),
            ],
            blocks: [],
        )
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(Set(items.map(\.id)).count, 2, "ids stay unique across kinds")
    }

    func testPromptBlockGetsPromptBadge() {
        let items = JumpToModel.items(
            links: [],
            blocks: [BlockSummary(index: 9, commandText: "现在 agent history viewer", isPrompt: true, firstSeen: t0)],
        )
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].kind, .prompt)
        XCTAssertEqual(items[0].badge, "Prompt", "CJK prompt text survives + badges as Prompt (outline.md CJK)")
        XCTAssertEqual(items[0].title, "现在 agent history viewer")
    }

    func testLinkItemsAreBoundedToCap() {
        // A pathological scrollback with thousands of DISTINCT paths is bounded (validate-then-bound).
        let many = (0..<(JumpToModel.maxLinkItems + 50)).map { link(.absolutePath, raw: "/p/\($0)") }
        let items = JumpToModel.items(links: many, blocks: [])
        XCTAssertEqual(items.count, JumpToModel.maxLinkItems, "link rows are capped at maxLinkItems")
    }

    // MARK: - Filter / fuzzy ordering

    /// A deterministic, fzf-shaped stand-in scorer for the headless test: returns `nil` unless every query
    /// character appears in order (subsequence), else a score that rewards an EARLIER first-match position
    /// (so a closer-to-front match ranks higher). This exercises the model's filter+order contract without
    /// pulling the view-module `FuzzyMatcher` into the headless test.
    private func subsequenceScore(_ query: String, _ haystack: String) -> Int? {
        let h = Array(haystack.lowercased())
        var hi = 0
        var firstMatch: Int?
        for qc in query.lowercased() {
            var found = false
            while hi < h.count {
                if h[hi] == qc {
                    if firstMatch == nil { firstMatch = hi }
                    hi += 1
                    found = true
                    break
                }
                hi += 1
            }
            if !found { return nil }
        }
        // Higher score for an earlier first match (front-loaded matches rank first).
        return 1000 - (firstMatch ?? 0)
    }

    func testFilteredDropsNonMatchesAndOrdersByScore() {
        let items = JumpToModel.items(
            links: [],
            blocks: [
                BlockSummary(index: 3, commandText: "git status"), // "gs": g@0
                BlockSummary(index: 2, commandText: "regis status"), // "gs": g@3 (later → lower score)
                BlockSummary(index: 1, commandText: "ls"), // no "g" → dropped
            ],
        )
        let filtered = JumpToModel.filtered(items, query: "gs", score: subsequenceScore)
        XCTAssertEqual(filtered.map(\.title), ["git status", "regis status"], "drops 'ls'; front match ranks first")
    }

    func testFilteredEmptyQueryReturnsAllUnchanged() {
        let items = JumpToModel.items(
            links: [link(.absolutePath, raw: "/a")],
            blocks: [BlockSummary(index: 1, commandText: "echo hi")],
        )
        let filtered = JumpToModel.filtered(items, query: "   ", score: subsequenceScore)
        XCTAssertEqual(filtered, items, "a blank query is the zero-state — every row, original order")
    }

    func testFilteredStableTieBreakKeepsAssemblyOrder() {
        // Two rows whose first-match position is identical (score ties) must keep their assembly order.
        let items = JumpToModel.items(
            links: [],
            blocks: [
                BlockSummary(index: 2, commandText: "abc one"),
                BlockSummary(index: 1, commandText: "abc two"),
            ],
        )
        let filtered = JumpToModel.filtered(items, query: "abc", score: subsequenceScore)
        XCTAssertEqual(filtered.map(\.title), ["abc one", "abc two"], "equal scores keep the original order")
    }

    // MARK: - ⌘J binding

    func testJumpToChordIsRegisteredAndUnique() {
        let chord = KeyChord(character: "j", [.command])
        XCTAssertEqual(WorkspaceBindingRegistry.chordTable[chord], .jumpTo, "⌘J maps to .jumpTo")

        let binding = WorkspaceBindingRegistry.allBindings.first { $0.id == "view.jumpTo" }
        XCTAssertNotNil(binding, "binding 'view.jumpTo' must exist")
        XCTAssertEqual(binding?.action, .jumpTo)

        // ⌘J must not collide with the shipped ⌘⇧J peek/reply (a different modifier set).
        let chords = WorkspaceBindingRegistry.allBindings.compactMap(\.chord)
        XCTAssertEqual(Set(chords).count, chords.count, "⌘J leaves the chord table collision-free")
    }
}
