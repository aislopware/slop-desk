import CSlopDeskFFI
import Foundation
import XCTest
@testable import SlopDeskWorkspaceModel

/// The template layout's repair, held against the other implementation of it.
///
/// **The repo's second differential suite, and the first one written for a pair that is still
/// DOUBLE.** `TreeWorkspaceRepairDifferentialTests` pins two doors onto one Rust rule after the
/// Swift copy was deleted; this pins two languages, because the Swift copy could not go. A
/// ``SessionTemplate`` is `Codable` and is the currency of the device-preferences file, so
/// ``TemplateNode/init(from:)`` is how a person's saved layouts actually come back — deleting it
/// would delete the store's ability to read its own file. `docs/55` §7 step 6 is exactly that case
/// and says what is owed instead: **pin it**. Same inputs to both sides, assert the same output.
///
/// `docs/55` §8's sharper finding is what picks the inputs. Rust's `persist.rs` was written as a
/// REPAIR PASS and Swift's decoders as PARSERS, and *a parser and a repairer agree on every
/// well-formed input and disagree on every malformed one* — which is the input class no test covers
/// and every hand-edited file eventually produces. So nothing here is a well-formed layout except
/// as a control: the corpus is empty splits, one-child splits, nesting past the cap, and every
/// combination of the three, and the interesting assertion is that the two sides land on one tree.
///
/// Both of the things the precedent does that a normal suite does not are here:
///
/// - **A vocabulary walked by COUNT rather than named.** `TemplatePane` carries a ``PaneKind``, and a
///   test naming `.terminal` and `.desktop` would agree forever while the crate grew a third. It
///   loops `0..<slopdesk_ws_pane_kind_count()` instead, so a kind added on one side only fails here
///   rather than in a restored layout. The depth CAP gets the same treatment: it is asked for
///   through `slopdesk_ws_max_depth`, and where the cap FIRES is asserted rather than assumed.
/// - **Two doors on one input, asserted to converge.** Repair-here-then-there against
///   repair-there-then-here. That property is checkable without knowing what either door does, and
///   it is the one that would have caught the `TreeWorkspace.normalized` row: two repairs that
///   disagree cannot commute.
final class SessionTemplateRepairDifferentialTests: XCTestCase {
    // MARK: - The two doors

    /// The NEAR side: the repair a persisted layout actually runs, which is the `Codable` decode.
    ///
    /// Driven through a real encode/decode rather than by calling anything directly, because the
    /// repair does not exist as a function on this side — it is written INTO `init(from:)`, and a
    /// helper that reproduced it here would be a third implementation of the very rule under test.
    private func repairedHere(_ layout: TemplateNode) throws -> TemplateNode {
        try JSONDecoder().decode(TemplateNode.self, from: JSONEncoder().encode(layout))
    }

    /// The FAR side: `slopdesk_workspace::templates::TemplateNode::repaired`.
    private func repairedThere(_ layout: TemplateNode) throws -> TemplateNode {
        try XCTUnwrap(
            SessionTemplateCrossing.repairedByTheCrate(layout),
            "the crossing refused a layout it encoded itself — the two grammars have drifted",
        )
    }

    // MARK: - The corpus, which is deliberately almost all malformed

    private func pane(_ title: String, cwd: String? = nil, command: String? = nil) -> TemplateNode {
        .pane(TemplatePane(kind: .terminal, title: title, cwd: cwd, command: command))
    }

    /// A chain of `levels` splits, each holding the chain and one filler leaf. Depth == `levels + 1`.
    private func chain(_ levels: Int, innermost: String = "Deepest") -> TemplateNode {
        var node = pane(innermost)
        for _ in 0..<levels {
            node = .split(axis: .horizontal, children: [node, pane("Filler")])
        }
        return node
    }

    /// Every shape worth disagreeing about, named so a failure says which one.
    ///
    /// The names are the assertion messages, so a divergence points at the shape rather than at an
    /// index into an array.
    private func corpus() -> [(String, TemplateNode)] {
        let cap = SplitNode.maxDepth
        let empty = TemplateNode.split(axis: .vertical, children: [])
        var cases: [(String, TemplateNode)] = []

        cases.append(("a lone pane", pane("Solo")))
        cases.append(("a sound two-child split", .split(axis: .horizontal, children: [pane("A"), pane("B")])))
        cases.append(("a childless split", empty))
        cases.append(("a one-child split", .split(axis: .horizontal, children: [pane("Only")])))
        cases.append(("a one-child split of a one-child split", .split(axis: .vertical, children: [
            .split(axis: .horizontal, children: [pane("Buried")]),
        ])))
        cases.append(("a split whose only child is childless", .split(axis: .horizontal, children: [empty])))
        cases.append(("a split of two childless splits", .split(axis: .horizontal, children: [empty, empty])))
        cases.append(("a sound split with one degenerate sibling", .split(axis: .horizontal, children: [
            pane("Kept"), empty,
        ])))
        cases.append(("a sound split with a collapsing sibling", .split(axis: .horizontal, children: [
            pane("Kept"),
            .split(axis: .vertical, children: [pane("Collapses")]),
        ])))

        cases.append(("a layout exactly at the depth cap", chain(cap - 1)))
        cases.append(("a layout one level past the cap", chain(cap)))
        cases.append(("a layout far past the cap", chain(cap + 5)))

        var endingEmpty = empty
        for _ in 0..<(cap + 3) {
            endingEmpty = .split(axis: .horizontal, children: [endingEmpty, pane("Filler")])
        }
        cases.append(("an over-deep chain ending in a childless split", endingEmpty))

        var lonely = pane("Buried")
        for _ in 0..<(cap + 4) { lonely = .split(axis: .horizontal, children: [lonely]) }
        cases.append(("an over-deep chain of ONE-child splits", lonely))

        // The fields the repair copies through untouched. They are here because "untouched" is a
        // claim about BOTH sides, and an absent value and an empty one are different values — both
        // reach `keystrokes` as "no directory", so nothing downstream could report the day one side
        // started rewriting one into the other.
        cases.append(("a pane carrying an absent cwd and an empty command", .split(
            axis: .horizontal,
            children: [pane("A", cwd: nil, command: ""), pane("B", cwd: "", command: nil)],
        )))
        cases.append((
            "a pane whose path is hostile shell input",
            pane("", cwd: "/tmp/proj<Enter>rm -rf x", command: "it's"),
        ))
        cases.append(("a pane carrying non-ASCII", pane("Éditeur · 日本語", cwd: "/tmp/ünïcode", command: "echo ✓")))
        return cases
    }

    // MARK: - The differential itself

    func testEveryDegenerateLayoutIsRepairedTheSameWayOnBothSidesOfTheBoundary() throws {
        for (name, layout) in corpus() {
            let here = try repairedHere(layout)
            let there = try repairedThere(layout)
            XCTAssertEqual(here, there, "the two repairs disagree about \(name)")
        }
    }

    func testTheTwoRepairsConvergeHoweverTheyAreOrdered() throws {
        // The precedent's property, at a language boundary rather than a door boundary: it must not
        // matter whether a broken layout is repaired by the file it was read from or by the crate
        // that was handed it. Two rules that disagree anywhere cannot commute everywhere, so this
        // fails on a divergence the pairwise assertion above could only see input by input.
        for (name, layout) in corpus() {
            let hereThenThere = try repairedThere(repairedHere(layout))
            let thereThenHere = try repairedHere(repairedThere(layout))
            XCTAssertEqual(hereThenThere, thereThenHere, "the repairs do not commute over \(name)")
        }
    }

    func testNeitherRepairFindsAnythingLeftToDoOnItsOwnAnswer() throws {
        // A repair that is not idempotent is not a repair — it is a transformation, and a layout
        // saved and reopened twice would keep moving. Asserted on BOTH sides, because one side
        // settling and the other not is exactly how the pair above could keep agreeing on the first
        // pass and diverge on the second.
        for (name, layout) in corpus() {
            let here = try repairedHere(layout)
            XCTAssertEqual(here, try repairedHere(here), "this side's repair is not idempotent over \(name)")
            let there = try repairedThere(layout)
            XCTAssertEqual(there, try repairedThere(there), "the crate's repair is not idempotent over \(name)")
        }
    }

    // MARK: - The depth cap, asked for rather than assumed

    func testTheDepthCapIsTheCratesAndBothSidesFireAtTheSameLevel() throws {
        let cap = Int(slopdesk_ws_max_depth())
        // A tautology today and deliberately kept: ``SplitNode/maxDepth`` IS this door as of
        // 2026-08-20, so this line can only start failing if somebody transcribes the number back.
        // The assertions below are the ones with teeth — a shared constant is only worth anything
        // where it DECIDES something, and what it decides is at which level the collapse happens.
        XCTAssertEqual(SplitNode.maxDepth, cap, "this side transcribed a cap the crate no longer owns")
        XCTAssertGreaterThan(cap, 1)

        // At the bound: kept whole, by both. One past it: collapsed to the first pane, by both. The
        // number itself proves nothing — where it FIRES is the behaviour a hand-edited file meets.
        let atBound = chain(cap - 1)
        XCTAssertEqual(atBound.depth, cap)
        XCTAssertEqual(try repairedHere(atBound), atBound, "a layout at the bound was altered here")
        XCTAssertEqual(try repairedThere(atBound), atBound, "a layout at the bound was altered there")

        let past = chain(cap, innermost: "Deepest")
        XCTAssertEqual(past.depth, cap + 1)
        let repaired = try repairedThere(past)
        XCTAssertEqual(try repairedHere(past), repaired)
        XCTAssertLessThanOrEqual(repaired.depth, cap, "the kept layout stays inside the tree's own bound")
        XCTAssertEqual(
            repaired, pane("Deepest"),
            "the collapse keeps the innermost leaf rather than synthesizing a fallback",
        )
    }

    // MARK: - The kind vocabulary, walked rather than named

    func testEveryPaneKindSurvivesTheCrossingAndTheRepairIdentically() throws {
        // `PaneKind` has two cases today, so a test naming them would agree forever while the crate
        // grew a third — the same argument `TreeWorkspaceRepairDifferentialTests` makes about the
        // video predicate, one type over. A template pane carries a kind, and a kind lost in the
        // crossing is a `.desktop` leaf that comes back a terminal.
        let count = slopdesk_ws_pane_kind_count()
        XCTAssertGreaterThan(count, 0, "the crate reports no pane kinds at all")
        for raw in 0..<count {
            let kind = WorkspacePaneKindTag.kind(for: UInt8(raw))
            XCTAssertEqual(
                WorkspacePaneKindTag.byte(for: kind), UInt8(raw),
                "byte \(raw) does not round-trip through this side's kind vocabulary — the crate grew a kind",
            )
            let layout = TemplateNode.split(axis: .vertical, children: [
                .pane(TemplatePane(kind: kind, title: "kind \(raw)")),
                .split(axis: .horizontal, children: []),
            ])
            XCTAssertEqual(
                try repairedThere(layout), try repairedHere(layout),
                "the two sides disagree about a layout holding kind \(raw)",
            )
        }
    }

    // MARK: - The shipped tables, which are constants NO LONGER written twice

    /// A built-in's id is FIXED rather than minted so that re-seeding a workspace or resetting the
    /// settings matches the existing row instead of appending a second copy of it. That used to make
    /// the table a set of constants in TWO languages, and this pair of tests asserted the two agreed
    /// — a drift of one byte in sixteen would otherwise surface as a duplicated menu row weeks later
    /// with nothing in any log, and nothing else in the repo could have seen it
    /// (`slopdesk-invariants` pins names and numbers it was told about, and nobody told it about
    /// these).
    ///
    /// Since 2026-08-22 there is one table. ``SessionTemplate/builtIns`` IS this crossing, so an
    /// equality assertion between them would compare a value to itself. What is left worth asserting
    /// is what the seed has to BE, and that is asserted on the shipped names and ids by
    /// `SessionTemplateEngineTests`/`LaunchPresetEngineTests` — which now, for free, pin the crate's
    /// table rather than a literal beside it. This keeps only the part those cannot see: that the
    /// crossing yields a non-empty table at all (an empty seed is how a grammar disagreement would
    /// present), that the ids are distinct, and that every shipped layout is already sound.
    func testTheShippedSessionTemplatesArriveSoundAndDistinct() throws {
        let shipped = SessionTemplate.builtIns
        XCTAssertFalse(
            shipped.isEmpty,
            "the crossing answered nothing — a fresh device would seed with no templates at all",
        )
        XCTAssertEqual(Set(shipped.map(\.id)).count, shipped.count, "a re-seed must match a row, not append one")
        XCTAssertTrue(shipped.allSatisfy(\.isBuiltIn))
        // Every shipped layout is already sound — a default a fresh workspace has to repair would
        // mean the table itself is the corrupt file. Asked of BOTH repairs, because that is still a
        // rule written in two languages.
        for template in shipped {
            XCTAssertEqual(try repairedThere(template.layout), template.layout)
            XCTAssertEqual(try repairedHere(template.layout), template.layout)
        }
    }

    func testTheShippedLaunchPresetsArriveSoundAndDistinct() {
        let shipped = LaunchPreset.builtIns
        XCTAssertFalse(
            shipped.isEmpty,
            "the crossing answered nothing — a fresh device would seed with no launch presets at all",
        )
        XCTAssertEqual(Set(shipped.map(\.id)).count, shipped.count, "a re-seed must match a row, not append one")
        XCTAssertTrue(shipped.allSatisfy(\.isBuiltIn))
        XCTAssertTrue(
            shipped.allSatisfy { !$0.command.isEmpty },
            "a built-in preset with no command opens a bare shell the menu row promised would run something",
        )
    }

    // MARK: - The crossing itself, which must not be where a difference comes from

    func testTheStreamCarriesEveryFieldTheRepairLeavesAlone() throws {
        // The differential above compares a value that went through the crossing against one that
        // did not, so a field the crossing DROPPED would read as a repair the crate performed. This
        // is the control: a sound layout carrying every field survives the encode/decode untouched,
        // and absent is not empty at either end of it.
        let layout = TemplateNode.split(axis: .vertical, children: [
            .pane(TemplatePane(kind: .terminal, title: "A", cwd: "/proj", command: "nvim .")),
            .pane(TemplatePane(kind: .desktop, title: "", cwd: "", command: nil)),
            .split(axis: .horizontal, children: [
                .pane(TemplatePane(title: "C", cwd: nil, command: "")),
                .pane(TemplatePane(title: "D")),
            ]),
        ])
        XCTAssertEqual(SessionTemplateCrossing.decodeLayout(SessionTemplateCrossing.encode(layout)), layout)
        XCTAssertEqual(try repairedThere(layout), layout, "a sound layout was altered by the crate")
    }

    func testAStreamTheReaderCannotConsumeExactlyIsRefusedRatherThanGuessedAt() {
        // The walk IS the contract on both sides — nothing is seekable, and a stream that does not
        // land exactly on the end is a shape disagreement between two encoders, never a degenerate
        // layout. A degenerate layout has a defined repair and always answers one, which is why the
        // refusal cannot be confused with an answer.
        let sound = SessionTemplateCrossing.encode(pane("A"))
        XCTAssertNotNil(SessionTemplateCrossing.decodeLayout(sound))
        XCTAssertNil(SessionTemplateCrossing.decodeLayout([]))
        XCTAssertNil(SessionTemplateCrossing.decodeLayout(Array(sound.dropLast())))
        XCTAssertNil(SessionTemplateCrossing.decodeLayout(sound + [0]), "a trailing byte is refused, not ignored")
        XCTAssertNil(SessionTemplateCrossing.decodeLayout([7]), "a tag that is neither pane nor split")
        XCTAssertNil(
            SessionTemplateCrossing.decodeLayout([1, 0, 0xFF, 0xFF, 0xFF, 0xFF]),
            "a child count no stream this short could satisfy",
        )
    }
}
