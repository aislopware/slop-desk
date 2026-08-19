import Foundation
import XCTest
@testable import SlopDeskWorkspaceModel

/// What a hand-edited workspace file costs when one word in it is wrong.
///
/// `SplitNode+Codable.swift` and `rust/slopdesk-workspace/src/persist.rs` both open by promising the
/// same thing — validate-then-repair, never trap — and they disagreed about it. SWIFT had the bug and
/// RUST was right: `decode_raw_node` answers `Some("vertical") => Vertical, _ => Horizontal` and reads
/// a non-uuid id as absent, while Swift wrote `decodeIfPresent(…) ?? .horizontal`, which THROWS on a
/// key that is present with a value the type refuses rather than answering `nil`. The `??` never ran.
///
/// The blast radius is the reason these are pinned rather than left to the round-trip tests: the throw
/// unwinds the whole `TreeWorkspace` decode, so `WorkspacePersistence.load()` falls back to the default
/// workspace and files the old one away as `.corrupt`. One typo, and every session, tab and split the
/// user had arranged is gone. Under Rust they lose nothing, which is the bar these hold Swift to.
final class SplitNodeDecodeRepairTests: XCTestCase {
    private let decoder = JSONDecoder()

    private func decode(_ json: String) throws -> SplitNode {
        try decoder.decode(SplitNode.self, from: Data(json.utf8))
    }

    /// `PaneID`/`SplitNodeID` are single-field structs, so they persist as `{"raw":"<uuid>"}` — the
    /// fixtures are written in that shape because that is what is actually on disk.
    private func idJSON(_ uuid: UUID) -> String { "{\"raw\":\"\(uuid.uuidString)\"}" }

    private func leafJSON(_ uuid: UUID) -> String {
        "{\"weight\":{\"flex\":1},\"node\":{\"leaf\":\(idJSON(uuid))}}"
    }

    // MARK: - The axis

    /// An axis nobody has ever had reads as `.horizontal`, exactly as Rust's `_ =>` arm does.
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
    /// the assertion that fails loudest under the old `decodeIfPresent` — not with a wrong axis, but
    /// with no tree at all.
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

    /// The same trap, one line up: `decodeIfPresent(SplitNodeID.self, …)` throws on an id that is
    /// present but is not the `{"raw":"<uuid>"}` shape. Rust's `decode_optional_id` reads that as
    /// absent and fills, and a split whose divider group lost its NAME still describes a real
    /// arrangement — so the fill is the whole repair.
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

    // MARK: - The children

    /// The same trap again, on the key that holds the STRUCTURE. Rust reads a `children` that is not
    /// an array as no children (`.and_then(Json::array).unwrap_or_default()`) and the user keeps the
    /// rest of their workspace; Swift threw and `WorkspacePersistence.load()` filed the whole file
    /// away as `.corrupt`. The cost of the repair is real and bounded — the malformed split is
    /// emptied and `normalized()` drops it — which is one seam against every seam in the file.
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

    /// A weight that is not even an object — `"weight": 5`, not the `{"flex":…}` shape. The weight
    /// decoder is tolerant of a wrong-typed value UNDER a key, but its own `container(keyedBy:)`
    /// threw before that tolerance could run, and `decodeIfPresent` carried the throw past the
    /// `?? .flex(1)`. Rust folds it to the equal share (`decode_weight`'s trailing `Flex(1.0)`),
    /// which is the right answer: a divider position is the one thing a repair can invent.
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
    /// a malformed one is a fault rather than a pane that silently vanishes out of an arrangement the
    /// rest of which decoded. Rust refuses the same child ("a split child has no node").
    func testAMalformedChildElementIsStillAFault() {
        let a = UUID()
        XCTAssertThrowsError(try decode("""
        {"split":{"id":\(idJSON(UUID())),"axis":"vertical","children":[\(leafJSON(a)),{"weight":{"flex":1}}]}}
        """), "a child with no node is corruption, not a repair")
    }

    // MARK: - What is still a fault

    /// The repair must not become a guess. A node with NEITHER discriminator describes no
    /// arrangement, so it stays a clean throw — the same line Rust draws ("a split node has neither a
    /// leaf nor a split" is an `Err`), and the reason `try?` is spelled per FIELD rather than wrapped
    /// around the whole decode.
    func testANodeWithNoDiscriminatorIsStillAFault() {
        XCTAssertThrowsError(try decode("{\"bogus\":42}"))
    }
}
