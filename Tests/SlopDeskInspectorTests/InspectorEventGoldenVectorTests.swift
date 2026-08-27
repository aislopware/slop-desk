import Foundation
import XCTest
@testable import SlopDeskInspector

/// Replays the `inspectorEvents` key of `golden/golden_vectors.json` through this end's decoder.
///
/// ## Why this suite exists
///
/// `InspectorEvent` is the one wire document whose two ends are asymmetric: `slopdesk-inspectord`
/// AUTHORS it and this target only reads it. There is no encoder here to round-trip against — and
/// deliberately so (`docs/54`, the one-implementation rule) — so nothing on this side could fail
/// when the daemon renamed a field. The corpus closes that: the daemon's crate asserts it encodes
/// these exact bytes, and this suite asserts the shipped decoder still reads them.
///
/// The vectors are HAND-AUTHORED rather than generated, because `slopdesk-corevectors` can only mint
/// what a Swift encoder produces and this type's synthesized encode is not the wire: ``ToolCard``
/// carries the two RENDERINGS the FFI door grafts on, not the wire's `input`.
///
/// ## Why the BARE decoder, not `InspectorCodec.event(_:)`
///
/// That path grafts ``ToolCard/inputDisplay`` and ``ToolCard/inputSummary`` on beside the decode,
/// from a rendering rule that is not on the wire at all. Asking through it would couple this schema
/// pin to that rule and would pass or fail for reasons the corpus says nothing about. The graft has
/// its own coverage (`InspectorWireFixture`); what is pinned here is the SCHEMA, which is why both
/// rendered fields are expected empty below — that is exactly what a wire frame carries.
///
/// The corpus is READ here, never written. A vector that disagrees is a regression in this decoder
/// or in the daemon, not a stale expectation to refresh.
final class InspectorEventGoldenVectorTests: XCTestCase {
    func testEveryPinnedEventDecodesToTheCaseItWasWrittenFrom() throws {
        let vectors = try loadVectors()
        XCTAssertEqual(vectors.count, 10, "the corpus must pin every case of the wire's taxonomy")

        var seen: Set<String> = []
        for vector in vectors {
            let name = try XCTUnwrap(vector["case"] as? String, "every record names its case")
            let json = try XCTUnwrap(vector["json"], "every record pins its JSON")
            let decoded = try JSONDecoder().decode(
                InspectorEvent.self,
                from: JSONSerialization.data(withJSONObject: json),
            )
            // Unwrapped BEFORE the assertion: an error thrown inside an autoclosure is reported
            // against a test whose own assertions all passed. A `nil` here is a record the corpus
            // carries and this suite has no expected value for — a failure, never a skip, which
            // would take the other nine records with it.
            let expected = try XCTUnwrap(Self.expected(name), "\(name): the corpus grew an unpinned case")
            XCTAssertEqual(decoded, expected, "\(name): the pinned JSON decodes to another value")
            XCTAssertTrue(seen.insert(name).inserted, "\(name) is pinned twice")
        }
        XCTAssertEqual(seen, Set(Self.everyCase), "the corpus lost a case — vectors are added, never dropped")
    }

    // MARK: The expected values

    /// Every case the wire carries. Named so a record the corpus DROPPED fails as loudly as one it
    /// changed: the pin is the whole taxonomy, not whichever part of it survived an edit.
    private static let everyCase = [
        "toolCard",
        "todosUpdated",
        "subagentUpdated",
        "subagentToolCard",
        "thinking",
        "message",
        "sessionStarted",
        "workflow",
        "unknownLine",
        "historyTruncated",
    ]

    /// The card two vectors share. Its two renderings stay at their defaults — the wire carries
    /// `input` as a JSON value and never these, so a bare decode must leave them empty.
    private static let pendingRead = ToolCard(id: "toolu_1", name: "Read", status: .pending)

    /// The value each pinned record describes, written out HERE rather than derived from the record,
    /// or `nil` for a case this suite does not pin.
    private static func expected(_ name: String) -> InspectorEvent? {
        switch name {
        case "toolCard":
            .toolCard(pendingRead)
        case "todosUpdated":
            .todosUpdated([TodoItem(content: "port it", status: .inProgress, activeForm: "porting it")])
        case "subagentUpdated":
            .subagentUpdated(SubagentNode(
                id: "a1",
                agentType: "Ariadne",
                status: .stopped,
                lastAssistantMessage: "done",
            ))
        case "subagentToolCard":
            .subagentToolCard(agentID: "a1", card: pendingRead)
        case "thinking":
            .thinking(ThinkingMarker(isPlaceholder: true, signature: "sig"))
        case "message":
            .message(MessageEvent(role: .assistant, text: "hi"))
        case "sessionStarted":
            .sessionStarted(SessionInfo(sessionID: "s1", model: "opus"))
        case "workflow":
            .workflow(WorkflowMarker(state: .running))
        case "unknownLine":
            .unknownLine(raw: "{not json")
        case "historyTruncated":
            .historyTruncated(droppedCount: 7)
        default:
            nil
        }
    }

    // MARK: Corpus

    private func loadVectors() throws -> [[String: Any]] {
        let corpus = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // SlopDeskInspectorTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // <package root>
            .appendingPathComponent("golden/golden_vectors.json")
        // Only THIS key is lifted: the corpus holds 53 keys of unrelated shapes, and typing the
        // whole file here would make every other vector's schema this suite's problem.
        let all = try JSONSerialization.jsonObject(with: Data(contentsOf: corpus)) as? [String: Any]
        let subtree = try XCTUnwrap(all?["inspectorEvents"], "the corpus lost the inspectorEvents key")
        return try XCTUnwrap(subtree as? [[String: Any]], "inspectorEvents is an array of records")
    }
}
