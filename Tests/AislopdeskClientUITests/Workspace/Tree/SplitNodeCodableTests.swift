import Foundation
import XCTest
@testable import AislopdeskClientUI

/// Decode-time repair + round-trip stability for ``SplitNode`` (W1, docs/42 Phase C1).
///
/// `SplitNode` is the persisted geometry/identity tree, so a hand-edited / older / hostile file must
/// **repair, never trap** (CLAUDE.md "validate-then-repair on untrusted persisted data"). These pin the
/// repairs the plan enumerates: drop empty splits, collapse single-child splits into their child,
/// flatten a same-axis child split (Zellij merge), re-mint duplicate `PaneID`s, clamp non-finite/≤0
/// weights, and cap depth — plus that a healthy tree round-trips byte-stable.
final class SplitNodeCodableTests: XCTestCase {
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    private let decoder = JSONDecoder()

    private func decode(_ json: String) throws -> SplitNode {
        try decoder.decode(SplitNode.self, from: Data(json.utf8))
    }

    // ``PaneID``/``SplitNodeID`` are `{ raw: UUID }` structs, so they serialize as `{"raw":"<uuid>"}`
    // (synthesized Codable) — these helpers build fixture JSON in exactly that wire shape so the
    // hand-authored fixtures match what the persistence file actually contains.
    private func paneJSON(_ uuid: UUID) -> String { "{\"raw\":\"\(uuid.uuidString)\"}" }
    private func idJSON(_ uuid: UUID = UUID()) -> String { "{\"raw\":\"\(uuid.uuidString)\"}" }
    private func leafJSON(_ uuid: UUID) -> String { "{\"leaf\":\(paneJSON(uuid))}" }

    // MARK: Round-trip

    func testHealthyTreeRoundTrips() throws {
        let a = PaneID(), b = PaneID(), c = PaneID()
        let original = SplitNode.split(
            id: SplitNodeID(),
            axis: .horizontal,
            children: [
                WeightedChild(weight: .flex(1), node: .leaf(a)),
                WeightedChild(weight: .flex(2), node: .split(
                    id: SplitNodeID(),
                    axis: .vertical,
                    children: [
                        WeightedChild(weight: .flex(1), node: .leaf(b)),
                        WeightedChild(weight: .flex(1), node: .leaf(c)),
                    ],
                )),
            ],
        )
        let data = try encoder.encode(original)
        let back = try decoder.decode(SplitNode.self, from: data)
        XCTAssertEqual(back, original, "a well-formed tree must survive encode→decode unchanged")
        // Stable: re-encoding the decoded value yields identical bytes.
        XCTAssertEqual(try encoder.encode(back), data, "round-trip must be byte-stable")
    }

    func testLeafRoundTrips() throws {
        let a = PaneID()
        let original = SplitNode.leaf(a)
        let back = try decoder.decode(SplitNode.self, from: encoder.encode(original))
        XCTAssertEqual(back, original)
    }

    // MARK: Repairs

    func testEmptySplitCollapsesAwayLosslessly() throws {
        // A split with zero children is degenerate — the decoder must not surface an empty `.split`.
        // With a real leaf alongside it, the empty split is dropped and the survivor promoted.
        let keep = UUID()
        let json = """
        {"split":{"axis":"horizontal","id":\(idJSON()),"children":[
          {"weight":{"flex":1},"node":{"split":{"axis":"vertical","id":\(idJSON()),"children":[]}}},
          {"weight":{"flex":1},"node":\(leafJSON(keep))}
        ]}}
        """
        let node = try decode(json)
        // The empty inner split vanished; only the real leaf remains, collapsed up to the root.
        XCTAssertEqual(node.allPaneIDs(), [PaneID(raw: keep)], "empty split dropped, single survivor collapsed")
        XCTAssertEqual(node.leafCount, 1)
    }

    func testSingleChildSplitCollapsesIntoItsChild() throws {
        let only = UUID()
        let json = """
        {"split":{"axis":"vertical","id":\(idJSON()),"children":[
          {"weight":{"flex":1},"node":\(leafJSON(only))}
        ]}}
        """
        let node = try decode(json)
        XCTAssertEqual(node, .leaf(PaneID(raw: only)), "a one-child split collapses into the child itself")
    }

    func testSameAxisChildSplitIsFlattenedZellijMerge() throws {
        // A horizontal split whose child is itself a horizontal split → flatten the grandchildren up.
        let a = UUID(), b = UUID(), c = UUID()
        let json = """
        {"split":{"axis":"horizontal","id":\(idJSON()),"children":[
          {"weight":{"flex":1},"node":\(leafJSON(a))},
          {"weight":{"flex":1},"node":{"split":{"axis":"horizontal","id":\(idJSON()),"children":[
            {"weight":{"flex":1},"node":\(leafJSON(b))},
            {"weight":{"flex":1},"node":\(leafJSON(c))}
          ]}}}
        ]}}
        """
        let node = try decode(json)
        guard case let .split(_, axis, children) = node else {
            XCTFail("expected a flattened split, got \(node)")
            return
        }
        XCTAssertEqual(axis, .horizontal)
        XCTAssertEqual(children.count, 3, "same-axis nested split flattened to 3 sibling leaves")
        XCTAssertEqual(node.allPaneIDs(), [PaneID(raw: a), PaneID(raw: b), PaneID(raw: c)])
    }

    func testDuplicatePaneIDsAreReMinted() throws {
        let dup = UUID()
        let json = """
        {"split":{"axis":"horizontal","id":\(idJSON()),"children":[
          {"weight":{"flex":1},"node":\(leafJSON(dup))},
          {"weight":{"flex":1},"node":\(leafJSON(dup))}
        ]}}
        """
        let node = try decode(json)
        let ids = node.allPaneIDs()
        XCTAssertEqual(ids.count, 2, "both leaves survive")
        XCTAssertEqual(Set(ids).count, 2, "the duplicate PaneID was re-minted to a unique one")
        XCTAssertTrue(ids.contains(PaneID(raw: dup)), "the first occurrence keeps the original id")
    }

    func testNonFiniteAndNonPositiveWeightsAreClamped() throws {
        let a = UUID(), b = UUID(), c = UUID()
        // A wrong-typed weight ("nan" string), zero, and a negative weight must all clamp to ≥ minWeight
        // (never reach the solver) — validate-then-repair, no decode failure.
        let json = """
        {"split":{"axis":"horizontal","id":\(idJSON()),"children":[
          {"weight":{"flex":"nan"},"node":\(leafJSON(a))},
          {"weight":{"flex":0},"node":\(leafJSON(b))},
          {"weight":{"flex":-5},"node":\(leafJSON(c))}
        ]}}
        """
        let node = try decode(json)
        guard case let .split(_, _, children) = node else {
            XCTFail("expected split")
            return
        }
        XCTAssertEqual(children.count, 3, "all three leaves survive the weight repair")
        for child in children {
            guard case let .flex(w) = child.weight else {
                XCTFail("expected flex weight")
                continue
            }
            XCTAssertTrue(w.isFinite, "no NaN/inf weight survives decode")
            XCTAssertGreaterThanOrEqual(w, SplitWeight.minWeight, "weights clamped to ≥ minWeight")
        }
    }

    func testOverDeepTreeIsCappedAtMaxDepth() throws {
        // Build a JSON split nested far past the depth cap; the decoder must not stack-blow nor keep the
        // over-deep structure — it caps and still yields a finite, valid tree. Each level has TWO
        // children (a descending chain + a terminal leaf) and alternates axis so neither the
        // single-child-collapse nor the same-axis-flatten repair shortens the chain — the depth cap is
        // the only thing that bounds it.
        func nested(_ depth: Int) -> String {
            if depth == 0 {
                return leafJSON(UUID())
            }
            let axis = depth.isMultiple(of: 2) ? "horizontal" : "vertical"
            return """
            {"split":{"axis":"\(axis)","id":\(idJSON()),"children":[
              {"weight":{"flex":1},"node":\(nested(depth - 1))},
              {"weight":{"flex":1},"node":\(leafJSON(UUID()))}
            ]}}
            """
        }
        // 40 levels deep — well past maxDepth (12).
        let node = try decode(nested(40))
        XCTAssertLessThanOrEqual(node.depth, SplitNode.maxDepth, "tree depth is capped at maxDepth")
        XCTAssertGreaterThanOrEqual(node.leafCount, 1, "the cap keeps at least one leaf — never empties the tree")
    }

    func testGarbageDoesNotTrap() throws {
        // A structurally invalid node (neither leaf nor split discriminator) must throw a clean decode
        // error (caught by the persistence layer), never trap.
        XCTAssertThrowsError(try decode("{\"bogus\":42}"))
    }

    func testPathologicallyDeepJSONFailsSoftWithoutStackOverflow() throws {
        // The decode recursion (`init(from:)`/`decodeRaw`) runs BEFORE `normalized()`'s depth cap applies,
        // so the cap cannot be what protects decode from a stack-overflow on hostile/hand-edited JSON. The
        // actual guard is JSONDecoder's OWN nesting bound (~512 levels): a JSON nested far past it is
        // rejected by the parser with a clean `DecodingError` — `WorkspacePersistence.load()` catches that
        // (→ default + `.corrupt` sidecar). This pins the fail-SOFT contract: a 2000-deep chain throws,
        // never traps. (A depth comfortably within JSONDecoder's bound is exercised by the maxDepth test.)
        func nested(_ depth: Int) -> String {
            if depth == 0 { return leafJSON(UUID()) }
            return """
            {"split":{"axis":"horizontal","id":\(idJSON()),"children":[
              {"weight":{"flex":1},"node":\(nested(depth - 1))}
            ]}}
            """
        }
        XCTAssertThrowsError(
            try decode(nested(2000)),
            "JSON nested past JSONDecoder's nesting bound is rejected (throws), never a stack overflow",
        )
    }
}
