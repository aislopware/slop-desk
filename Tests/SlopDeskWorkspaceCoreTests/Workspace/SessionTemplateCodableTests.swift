import Foundation
import XCTest
@testable import SlopDeskWorkspaceCore

/// The ``TemplateNode`` / ``SessionTemplate`` hand-written `Codable` (it persists on `workspace.json`): a
/// well-formed layout round-trips byte-stably, and the validate-then-repair decode tolerates a degenerate /
/// hostile file (a < 2-child split collapses, an over-deep layout is capped) instead of trapping — the
/// CLAUDE.md untrusted-persisted-data contract.
final class SessionTemplateCodableTests: XCTestCase {
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    // MARK: Round-trip

    func testSessionTemplateRoundTrips() throws {
        let template = SessionTemplate(
            name: "Dev", symbol: "hammer",
            layout: .split(axis: .horizontal, children: [
                .pane(TemplatePane(kind: .terminal, title: "A", cwd: "/proj", command: "nvim .")),
                .split(axis: .vertical, children: [
                    .pane(TemplatePane(title: "B")),
                    .pane(TemplatePane(title: "C", command: "ls")),
                ]),
            ]),
        )
        let back = try decoder.decode(SessionTemplate.self, from: encoder.encode(template))
        XCTAssertEqual(back, template)
    }

    func testTemplatePaneDefaultsAndOptionalsRoundTrip() throws {
        let pane = TemplatePane(title: "X")
        let back = try decoder.decode(TemplatePane.self, from: encoder.encode(pane))
        XCTAssertEqual(back.kind, .terminal)
        XCTAssertNil(back.cwd)
        XCTAssertNil(back.command)
        XCTAssertEqual(back, pane)
    }

    // MARK: Validate-then-repair

    /// A `.split` with a single child collapses to that child on decode (the parser builds the JSON by
    /// hand so it exercises the REAL `init(from:)`, not an encode-of-our-own-model derivation).
    func testSingleChildSplitCollapsesToItsChild() throws {
        let json = """
        {"kind":"split","axis":"horizontal","children":[{"kind":"pane","pane":{"kind":"terminal","title":"Solo"}}]}
        """
        let node = try decoder.decode(TemplateNode.self, from: Data(json.utf8))
        XCTAssertEqual(node, .pane(TemplatePane(kind: .terminal, title: "Solo")))
    }

    /// A childless `.split` is a hard-corrupt node with no leaf — it decodes to a default terminal pane
    /// (the layout always yields ≥ 1 pane) rather than trapping.
    func testChildlessSplitBecomesDefaultPane() throws {
        let json = #"{"kind":"split","axis":"vertical","children":[]}"#
        let node = try decoder.decode(TemplateNode.self, from: Data(json.utf8))
        if case let .pane(pane) = node {
            XCTAssertEqual(pane.kind, .terminal)
        } else { XCTFail("expected a repaired default pane") }
    }

    /// A layout nested far past ``SplitNode/maxDepth`` is capped — the over-deep node collapses to its
    /// first leaf pane, so the later SplitNode build can never exceed the tree's own depth bound.
    func testOverDeepLayoutIsCapped() throws {
        // Build a degenerate deeply-nested 2-child split chain (depth ≫ maxDepth).
        func deep(_ levels: Int) -> TemplateNode {
            guard levels > 0 else { return .pane(TemplatePane(title: "leaf")) }
            return .split(axis: .horizontal, children: [
                .pane(TemplatePane(title: "side")),
                deep(levels - 1),
            ])
        }
        let overDeep = deep(SplitNode.maxDepth + 5)
        // Encode the over-deep value, then decode — the decode must cap it.
        let decoded = try decoder.decode(TemplateNode.self, from: encoder.encode(overDeep))
        XCTAssertLessThanOrEqual(decoded.depth, SplitNode.maxDepth, "over-deep layout capped on decode")
    }

    /// A WELL-FORMED layout at exactly the depth bound survives intact (the cap only fires past maxDepth).
    func testLayoutAtDepthBoundSurvives() throws {
        func chain(_ levels: Int) -> TemplateNode {
            guard levels > 1 else { return .pane(TemplatePane(title: "leaf")) }
            return .split(axis: .horizontal, children: [.pane(TemplatePane(title: "side")), chain(levels - 1)])
        }
        let atBound = chain(SplitNode.maxDepth) // depth == maxDepth
        XCTAssertEqual(atBound.depth, SplitNode.maxDepth)
        let decoded = try decoder.decode(TemplateNode.self, from: encoder.encode(atBound))
        XCTAssertEqual(decoded, atBound, "a layout at the depth bound is not altered")
    }
}
