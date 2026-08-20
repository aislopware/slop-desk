import Foundation
import XCTest
@testable import SlopDeskWorkspaceModel

/// What a hand-edited workspace file costs when one word in it is wrong.
///
/// These used to hold `SplitNode+Codable.swift` to `rust/slopdesk-workspace/src/persist.rs`'s answer,
/// case by case, because the two opened by promising the same thing — validate-then-repair, never
/// trap — and disagreed about it. That file is gone: the crate's decoder is the only one now, reached
/// through ``WorkspaceFile``, so every case below asserts through the DOOR. What was a differential is
/// now a pin — the answers themselves are unchanged, which is the point of re-pointing rather than
/// deleting them.
///
/// The blast radius is why they are pinned at all: a throw out of a nested node used to unwind the
/// whole `TreeWorkspace` decode, so `WorkspacePersistence.loadTree()` fell back to the default
/// workspace and filed the old one away as `.corrupt`. One typo, and every session, tab and split the
/// user had arranged was gone.
final class SplitNodeDecodeRepairTests: XCTestCase {
    // MARK: - Fixtures (written in the shape that is actually on disk)

    /// `PaneID`/`SplitNodeID` are single-field structs, so they persist as `{"raw":"<uuid>"}` — the
    /// fixtures are written in that shape because that is what is actually on disk.
    private func idJSON(_ uuid: UUID) -> String { "{\"raw\":\"\(uuid.uuidString)\"}" }

    private func leafJSON(_ uuid: UUID) -> String {
        "{\"weight\":{\"flex\":1},\"node\":{\"leaf\":\(idJSON(uuid))}}"
    }

    /// A whole file around one tab root, which is the only shape the door reads. The spec side table
    /// is left empty on purpose: a leaf with no spec is re-seeded by the repair, so every fixture
    /// here says exactly one thing about the ARRANGEMENT and nothing about the panes' descriptions.
    private func fileJSON(root: String) -> String {
        """
        {"schemaVersion":\(TreeWorkspace.currentSchemaVersion),"sessions":[
          {"id":\(idJSON(UUID())),"name":"work","activeTabIndex":0,
           "tabs":[{"id":\(idJSON(UUID())),"title":"","root":\(root)}],
           "specs":[]}
        ]}
        """
    }

    /// The tab root as the door hands it back, repaired.
    private func decode(_ root: String) throws -> SplitNode {
        let tree = try WorkspaceFile.decode(Data(fileJSON(root: root).utf8))
        return try XCTUnwrap(tree.sessions.first?.tabs.first?.root)
    }

    // MARK: - The axis

    /// An axis nobody has ever had reads as `.horizontal`, exactly as the crate's `_ =>` arm does.
    func testAnUnknownAxisRepairsInsteadOfThrowing() throws {
        let a = UUID(), b = UUID()
        let node = try decode("""
        {"split":{"id":\(idJSON(UUID())),"axis":"diagonal","children":[\(leafJSON(a)),\(leafJSON(b))]}}
        """)
        guard case let .split(_, axis, children) = node else {
            XCTFail("the split survives — it is only its axis that was unreadable")
            return
        }
        XCTAssertEqual(axis, .horizontal, "the unreadable axis takes the same default a missing one does")
        XCTAssertEqual(children.count, 2, "both panes are still there")
    }

    /// The whole point: a typo one level down must not cost the panes at every other level. This is
    /// the assertion that failed loudest under the deleted `decodeIfPresent` — not with a wrong axis,
    /// but with no tree at all.
    func testATypoInOneNestedAxisKeepsEveryOtherPaneInTheTree() throws {
        let a = UUID(), b = UUID(), c = UUID()
        let node = try decode("""
        {"split":{"id":\(idJSON(UUID())),"axis":"vertical","children":[
          \(leafJSON(a)),
          {"weight":{"flex":1},"node":{"split":{"id":\(idJSON(UUID())),"axis":"horziontal","children":[
            \(leafJSON(b)),\(leafJSON(c))
          ]}}}
        ]}}
        """)
        XCTAssertEqual(
            Set(node.allPaneIDs().map(\.raw)),
            [a, b, c],
            "one misspelled word must cost one axis, not the user's whole arrangement",
        )
        guard case let .split(_, outer, children) = node,
              let tail = children.last,
              case let .split(_, inner, _) = tail.node
        else {
            XCTFail("the shape survives: a vertical parent with a repaired child split")
            return
        }
        XCTAssertEqual(outer, .vertical, "the axis that WAS readable is untouched")
        XCTAssertEqual(inner, .horizontal)
    }

    // MARK: - The id

    /// An id that is present but is not the `{"raw":"<uuid>"}` shape reads as ABSENT and is filled: a
    /// split whose divider group lost its NAME still describes a real arrangement.
    func testAnUnreadableSplitIDIsFilledRatherThanThrown() throws {
        let a = UUID(), b = UUID()
        let node = try decode("""
        {"split":{"id":7,"axis":"horizontal","children":[\(leafJSON(a)),\(leafJSON(b))]}}
        """)
        guard case let .split(_, _, children) = node else {
            XCTFail("an unnamed divider group is still a split")
            return
        }
        XCTAssertEqual(children.count, 2)
    }

    /// And an id that is a `{"raw":…}` object holding something that is not a uuid — the likelier
    /// hand edit, since it keeps the shape and only breaks the value.
    func testAnIDThatIsNotAUUIDIsFilledToo() throws {
        let a = UUID(), b = UUID()
        let node = try decode("""
        {"split":{"id":{"raw":"not-a-uuid"},"axis":"vertical","children":[\(leafJSON(a)),\(leafJSON(b))]}}
        """)
        guard case let .split(_, axis, children) = node else {
            XCTFail("the arrangement outlives its divider's name")
            return
        }
        XCTAssertEqual(axis, .vertical)
        XCTAssertEqual(children.count, 2)
    }

    /// **The defect this whole port exists to close, from the side a person feels it.**
    ///
    /// The name a divider group is filled with is DERIVED from where the split sits and what it
    /// holds, so two loads of one file agree. The deleted Swift decoder wrote `?? SplitNodeID()` — a
    /// fresh uuid on every load — and a divider's dragged position is persisted as
    /// `splitNode/<id>/weight`, so every seam the person had moved was orphaned on the next launch
    /// and snapped back to the default, with nothing logged.
    func testTheSameFileNamesTheSameDividersOnEveryLoad() throws {
        let a = UUID(), b = UUID()
        let file = Data(fileJSON(root: """
        {"split":{"axis":"horizontal","children":[\(leafJSON(a)),\(leafJSON(b))]}}
        """).utf8)

        let dividers = { (tree: TreeWorkspace) -> [SplitNodeID] in
            tree.sessions.flatMap { session in session.tabs.flatMap { Self.seams(of: $0.root) } }
        }
        let first = try dividers(WorkspaceFile.decode(file))
        let second = try dividers(WorkspaceFile.decode(file))
        XCTAssertFalse(first.isEmpty, "the fixture has a divider in it")
        XCTAssertEqual(
            first, second,
            "a divider's name is a function of the file, not of when the file was read",
        )
    }

    /// Every divider group in a tree, in visual order.
    private static func seams(of node: SplitNode) -> [SplitNodeID] {
        switch node {
        case .leaf:
            []
        case let .split(id, _, children):
            [id] + children.flatMap { seams(of: $0.node) }
        }
    }

    // MARK: - The children

    /// The same tolerance on the key that holds the STRUCTURE: a `children` that is not an array
    /// reads as no children and the user keeps the rest of their workspace. The cost of the repair is
    /// real and bounded — the malformed split is emptied and the repair drops it — which is one seam
    /// against every seam in the file.
    func testAnUnreadableChildrenValueCostsOneSplitRatherThanTheFile() throws {
        let a = UUID(), b = UUID(), c = UUID()
        let node = try decode("""
        {"split":{"id":\(idJSON(UUID())),"axis":"vertical","children":[
          \(leafJSON(a)),
          {"weight":{"flex":1},"node":{"split":{"id":\(idJSON(UUID())),"axis":"horizontal","children":5}}},
          \(leafJSON(b)),\(leafJSON(c))
        ]}}
        """)
        XCTAssertEqual(
            Set(node.allPaneIDs().map(\.raw)),
            [a, b, c],
            "the panes the file still describes all survive; only the emptied split is dropped",
        )
    }

    /// A `children` key that is absent entirely is the same answer, and it always was — pinned so the
    /// tolerant container cannot regress into treating the two differently.
    func testAMissingChildrenKeyIsTheSameAsAnUnreadableOne() throws {
        let node = try decode("{\"split\":{\"id\":\(idJSON(UUID())),\"axis\":\"vertical\"}}")
        if case .split = node {
            XCTFail("a split with no children repairs away to a fresh leaf, not to an empty split")
        }
    }

    /// A weight that is not even an object — `"weight": 5`, not the `{"flex":…}` shape — folds to the
    /// equal share, which is the right answer: a divider position is the one thing a repair can
    /// invent.
    func testAWeightThatIsNotAnObjectFoldsToTheEqualShare() throws {
        let a = UUID(), b = UUID()
        let node = try decode("""
        {"split":{"id":\(idJSON(UUID())),"axis":"vertical","children":[
          {"weight":5,"node":{"leaf":\(idJSON(a))}},\(leafJSON(b))
        ]}}
        """)
        guard case let .split(_, _, children) = node, let first = children.first else {
            XCTFail("both panes are still there — it is only the share that was unreadable")
            return
        }
        XCTAssertEqual(children.count, 2)
        XCTAssertEqual(first.weight, .flex(1))
    }

    /// And the line the tolerance must NOT cross: a child INSIDE the array still decodes strictly, so
    /// a malformed one is a refusal rather than a pane that silently vanishes out of an arrangement
    /// the rest of which decoded.
    func testAMalformedChildElementIsStillAFault() {
        let a = UUID()
        XCTAssertThrowsError(try decode("""
        {"split":{"id":\(idJSON(UUID())),"axis":"vertical","children":[\(leafJSON(a)),{"weight":{"flex":1}}]}}
        """), "a child with no node is corruption, not a repair") { error in
            XCTAssertEqual(error as? WorkspaceFile.FileError, .malformed)
        }
    }

    // MARK: - What is still a fault

    /// The repair must not become a guess. A node with NEITHER discriminator describes no
    /// arrangement, so it stays a clean refusal — the reason the tolerance is spelled per FIELD
    /// rather than wrapped around the whole load.
    func testANodeWithNoDiscriminatorIsStillAFault() {
        XCTAssertThrowsError(try decode("{\"bogus\":42}")) { error in
            XCTAssertEqual(error as? WorkspaceFile.FileError, .malformed)
        }
    }
}
