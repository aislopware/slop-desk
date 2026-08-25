import Foundation
import XCTest
@testable import SlopDeskWorkspaceCore

/// The Jump-To panel's rows — the CROSSING and the row VALUES, not the tables.
///
/// WHICH detections and WHICH blocks earn a row is `slopdesk_workspace::jump_to`'s and pinned there:
/// the collapse of four path forms into one badge, the dedup, the ceiling, the skip of a block still
/// being captured. So are the badge and the glyph each kind wears, which are the picker's own
/// (`open_quickly::Kind`). A second copy of any of those here would be the same table in two
/// languages.
///
/// What only Swift can get wrong is everything the door does NOT carry. It answers INDICES into the
/// arrays this side holds, so an index landing on the wrong element would give a row someone else's
/// title, `Act` and timestamp — silently, because every field would still be well-formed. These pin
/// that landing, the two id spaces, the ordering of the two halves, and the ⌘J binding.
final class JumpToModelTests: XCTestCase {
    // MARK: - Fixtures

    private func link(_ kind: DetectedLinkKind, raw: String, resolved: String? = nil) -> DetectedLink {
        DetectedLink(row: 0, colStart: 0, colEnd: raw.count, kind: kind, raw: raw, resolvedAbsolute: resolved)
    }

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - The crossing lands on the right elements

    func testEveryRowCrossesBackOntoTheElementItWasBuiltFrom() {
        let links = [
            link(.absolutePath, raw: "/usr/local/bin/foo", resolved: "/usr/local/bin/foo"),
            link(.url, raw: "https://example.test/x"),
            link(.fileURL, raw: "file:///a/b.txt", resolved: "/a/b.txt"),
        ]
        let blocks = [
            BlockSummary(index: 7, commandText: "git status", firstSeen: t0),
            BlockSummary(index: 6, commandText: "ls -la", firstSeen: t0),
        ]
        let items = JumpToModel.items(links: links, blocks: blocks)

        XCTAssertEqual(items.count, 5, "3 links + 2 commands")
        // Links lead, in detection order — and each row wears ITS OWN detection's text, which is what
        // an index landing one slot over would quietly break.
        XCTAssertEqual(items.prefix(3).map(\.title), links.map(\.raw))
        XCTAssertEqual(items.prefix(3).map(\.kind), [.path, .url, .fileURL])
        XCTAssertEqual(items.prefix(3).compactMap(\.timestamp), [], "a link row carries no timestamp")
        if case let .link(carried) = items[0].act {
            XCTAssertEqual(carried, links[0], "the row carries the detection it was built from, whole")
        } else {
            XCTFail("a link row's act must be .link")
        }

        // Then the blocks, in the order given — the caller passes newest-first.
        XCTAssertEqual(items.suffix(2).map(\.title), ["git status", "ls -la"])
        XCTAssertEqual(items.suffix(2).map(\.kind), [.command, .command])
        XCTAssertEqual(items[3].timestamp, t0, "a command row carries the block's first-seen timestamp")
        if case let .block(index) = items[3].act {
            XCTAssertEqual(index, 7, "the row jumps to its OWN block's index, not to its position")
        } else {
            XCTFail("a command row's act must be .block")
        }
    }

    /// A skipped block leaves a GAP in the index space, so the rows after it must still land on their
    /// own summaries rather than shifting up by one.
    func testASkippedBlockDoesNotShiftTheRowsAfterIt() {
        let blocks = [
            BlockSummary(index: 2, commandText: "make build"),
            BlockSummary(index: 3, commandText: "", firstSeen: t0), // still-forming — no row
            BlockSummary(index: 4, commandText: "swift test", firstSeen: t0),
        ]
        let items = JumpToModel.items(links: [], blocks: blocks)
        XCTAssertEqual(items.map(\.title), ["make build", "swift test"])
        XCTAssertEqual(items.compactMap { item -> UInt32? in
            guard case let .block(index) = item.act else { return nil }
            return index
        }, [2, 4], "the surviving rows keep their own block indices")
    }

    /// The dedup keeps the FIRST sighting, and that is the detection the row must carry: a later one
    /// sits at a different row/column in the scrollback.
    func testADedupedRowCarriesTheFirstSighting() {
        let first = DetectedLink(
            row: 3, colStart: 0, colEnd: 10, kind: .absolutePath, raw: "/etc/hosts", resolvedAbsolute: "/etc/hosts",
        )
        let later = DetectedLink(
            row: 40, colStart: 4, colEnd: 14, kind: .absolutePath, raw: "/etc/hosts", resolvedAbsolute: "/etc/hosts",
        )
        let items = JumpToModel.items(links: [first, later], blocks: [])
        XCTAssertEqual(items.count, 1, "the same path printed twice is ONE row")
        if case let .link(carried) = items[0].act {
            XCTAssertEqual(carried, first)
        } else {
            XCTFail("a link row's act must be .link")
        }
    }

    /// The two id spaces are what `ForEach` and the fuzzy dedup key on, so they must stay disjoint and
    /// unique — including for a path and the `file://` URL naming it, which are two rows.
    func testTheTwoIDSpacesStayUniqueAndDisjoint() {
        let items = JumpToModel.items(
            links: [
                link(.absolutePath, raw: "/etc/hosts"),
                link(.fileURL, raw: "file:///etc/hosts", resolved: "/etc/hosts"),
            ],
            blocks: [BlockSummary(index: 1, commandText: "echo hi")],
        )
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(Set(items.map(\.id)).count, 3, "ids stay unique across kinds and across halves")
        XCTAssertEqual(items.filter { $0.id.hasPrefix("block:") }.count, 1)
    }

    func testPromptBlocksBadgeApartFromCommandsAndKeepTheirText() {
        let items = JumpToModel.items(
            links: [],
            blocks: [
                BlockSummary(index: 9, commandText: "现在 agent history viewer", isPrompt: true, firstSeen: t0),
                BlockSummary(index: 8, commandText: "git log", firstSeen: t0),
            ],
        )
        XCTAssertEqual(items.map(\.kind), [.prompt, .command], "isPrompt is this side's fact, not the door's")
        XCTAssertEqual(items[0].title, "现在 agent history viewer", "CJK survives the arena round trip")
        XCTAssertNotEqual(items[0].badge, items[1].badge, "the two kinds must not read alike")
    }

    /// The ceiling is the door's, and it is the SURVIVING rows it bounds — this pins that the near side
    /// reads the same number back rather than truncating a longer answer.
    func testLinkRowsStopAtTheSharedCeiling() {
        let many = (0..<(JumpToModel.maxLinkItems + 50)).map { link(.absolutePath, raw: "/p/\($0)") }
        let items = JumpToModel.items(links: many, blocks: [])
        XCTAssertEqual(items.count, JumpToModel.maxLinkItems)
        XCTAssertEqual(items.last?.title, "/p/\(JumpToModel.maxLinkItems - 1)", "the cap keeps a PREFIX")
    }

    func testNothingDetectedAndNothingCapturedAssemblesNoRows() {
        XCTAssertTrue(JumpToModel.items(links: [], blocks: []).isEmpty)
    }

    /// Every kind crosses for its two readings, and no two read alike — the words themselves are the
    /// picker's and pinned in `open_quickly`, so what is checked here is that the face resolves them.
    func testEveryKindCrossesWithADistinctBadgeAndGlyph() {
        let kinds = JumpToItemKind.allCases
        for kind in kinds {
            XCTAssertFalse(kind.badge.isEmpty, "\(kind) crossed unbadged")
            XCTAssertFalse(kind.symbol.isEmpty, "\(kind) crossed with no glyph")
        }
        XCTAssertEqual(Set(kinds.map(\.badge)).count, kinds.count)
        XCTAssertEqual(Set(kinds.map(\.symbol)).count, kinds.count)
    }

    // MARK: - Filter / fuzzy ordering

    func testFilteredDropsNonMatchesAndOrdersByScore() {
        let items = JumpToModel.items(
            links: [],
            blocks: [
                BlockSummary(index: 3, commandText: "git status"), // "gs": both letters start a word
                BlockSummary(index: 2, commandText: "regis status"), // "gs": g mid-word → lower score
                BlockSummary(index: 1, commandText: "ls"), // no "g" → dropped
            ],
        )
        let filtered = JumpToModel.filtered(items, query: "gs")
        XCTAssertEqual(filtered.map(\.title), ["git status", "regis status"], "drops 'ls'; front match ranks first")
    }

    func testFilteredEmptyQueryReturnsAllUnchanged() {
        let items = JumpToModel.items(
            links: [link(.absolutePath, raw: "/a")],
            blocks: [BlockSummary(index: 1, commandText: "echo hi")],
        )
        let filtered = JumpToModel.filtered(items, query: "   ")
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
        let filtered = JumpToModel.filtered(items, query: "abc")
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
