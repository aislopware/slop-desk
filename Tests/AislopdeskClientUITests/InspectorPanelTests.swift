import XCTest
import AislopdeskInspector
@testable import AislopdeskClientUI

/// Verifies the inspector composition the panel relies on: an `InspectorClient` fed events over
/// an in-process `LoopbackByteChannel` folds into the `@MainActor @Observable`
/// `InspectorViewModel` exactly as the `InspectorPanel`'s `.task` drives it (subscribe → consume).
/// The views themselves are logic-free (AislopdeskInspector); here we prove the data path the panel
/// composes.
@MainActor
final class InspectorPanelTests: XCTestCase {

    func testClientEventStreamFoldsIntoViewModel() async throws {
        let (hostChannel, clientChannel) = LoopbackByteChannel.pair()
        let source = InspectorSource(channel: hostChannel)
        let client = InspectorClient(channel: clientChannel)
        let model = InspectorViewModel()

        // The panel's consume loop, run inline.
        let consumeTask = Task { @MainActor in
            await model.consume(client.events())
        }

        // Host emits a representative slice of the taxonomy.
        try await source.send(.sessionStarted(SessionInfo(model: "claude-opus", cwd: "/work")))
        try await source.send(.toolCard(ToolCard(id: "t1", name: "Read", input: .string("/a.swift"))))
        try await source.send(.toolCard(ToolCard(id: "t1", name: "Read", input: .string("/a.swift"),
                                                  output: "ok", status: .completed)))
        try await source.send(.todosUpdated([
            TodoItem(content: "wire UI", status: .inProgress),
            TodoItem(content: "tests", status: .pending),
        ]))
        try await source.send(.thinking(ThinkingMarker(isPlaceholder: true, signature: "abc123")))

        // Poll the model until the events have folded in.
        let ok = await waitUntil {
            model.session?.model == "claude-opus" &&
            model.toolCards.count == 1 &&
            model.toolCards.first?.status == .completed &&
            model.todos.count == 2 &&
            model.lastThinking?.isPlaceholder == true
        }
        XCTAssertTrue(ok, """
            view-model folded the inspector stream:
            session=\(String(describing: model.session)) cards=\(model.toolCards.count) \
            todos=\(model.todos.count) thinking=\(String(describing: model.lastThinking))
            """)

        // The re-emitted t1 card updated in place (no duplicate) — the upsert the panel needs.
        XCTAssertEqual(model.toolCards.count, 1, "re-emitted tool card upserts, not duplicates")

        consumeTask.cancel()
        await source.close()
        await client.close()
    }

    private func waitUntil(timeout: Duration = .seconds(5), _ predicate: @MainActor () -> Bool) async -> Bool {
        let start = ContinuousClock.now
        while ContinuousClock.now - start < timeout {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return predicate()
    }
}
