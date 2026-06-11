import XCTest
import AislopdeskClient
import AislopdeskInspector
import AislopdeskTransport
@testable import AislopdeskClientUI

/// An `AislopdeskClient` whose transport factory is inert (never invoked — these `.claudeCode` panes are
/// never connected: the inspector fold is driven over an in-process loopback channel, no socket).
@Sendable private func makeUnconnectedClient() -> AislopdeskClient {
    AislopdeskClient(makeTransport: {
        MuxClientTransport(
            acquire: { _, _, _, _ in throw AislopdeskTransportError.notConnected("inert test transport") },
            release: { _, _, _ in }
        )
    })
}

/// WF5 — Inspector pane-content glue.
///
/// These tests prove the `.claudeCode` pane's structured inspector folds host events correctly
/// **using only the genuine in-process seam** `LoopbackByteChannel.pair()` (docs/22 §0, §8) — the
/// same seam the existing `InspectorTransportTests` use. There is:
///
///   - **NO `HostServer`** (project memory: pool deadlock; forbidden for new tests),
///   - **NO real network / `NWConnection`** (the live `liveMakeInspector` builder is exercised only
///     for its *pure* port-convention math, never dialed),
///   - **NO real `AislopdeskClient`** and **NO terminal byte stream** touched (PATH 1 is independent).
///
/// The fold under test is `InspectorViewModel.apply(_:)` driven through the real client transport
/// (`InspectorClient.events()`), fed by a real host `InspectorSource.send(_:)` over the loopback.
/// Two surfaces are covered:
///
///   1. The raw view-model fold over the transport (tool-card upsert/dedup, todos replace, session,
///      subagents) — the InspectorPanel's own `.task` would drive exactly this stream.
///   2. The `LivePaneSession` glue: a `.claudeCode` session whose `makeInspector` returns a
///      loopback-backed `InspectorClient`, driven via the single fold point `subscribeInspector()`
///      (the leaf's `.task` on appear, WF5) — proving the production glue path folds, that it
///      subscribes (`fromSeq: 0`), and that the single-consumer rule holds.
///
/// Single-consumer rule (LOAD-BEARING, author note 1): `InspectorClient.events()` spawns a task that
/// drains `channel.inbound`; calling it twice on the SAME client splits the stream. So a given client
/// is driven by EXACTLY ONE of { `subscribeInspector()` fold, a standalone `consume(client.events())`
/// fold } — never both. Each test below respects that.
@MainActor
final class InspectorGlueTests: XCTestCase {

    // MARK: - Deterministic wait helper

    /// Awaits until `predicate` holds (re-checked each main-actor hop) or a deadline elapses. The
    /// loopback fold hops to the MainActor per `apply`, so a bounded yield-poll is the deterministic
    /// in-process wait (no wall-clock dependency on success — only the failure path bounds time).
    private func waitUntil(
        _ predicate: () -> Bool,
        _ message: @autoclosure () -> String = "",
        timeout: TimeInterval = 2.0,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() {
            if Date() >= deadline {
                XCTFail("waitUntil timed out: \(message())", file: file, line: line)
                return
            }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000) // 1ms — keeps the failure path bounded
        }
    }

    private func sampleCard(
        id: String = "t1",
        name: String = "Bash",
        command: String = "ls",
        output: String? = nil,
        status: ToolCard.Status = .pending
    ) -> ToolCard {
        ToolCard(
            id: id,
            name: name,
            input: .object(["command": .string(command)]),
            output: output,
            status: status
        )
    }

    // MARK: - 1. Raw view-model fold over the real transport (the InspectorPanel `.task` stream)

    /// A tool-card upsert: a `pending` card then a re-emitted `completed` card with the SAME id must
    /// UPDATE in place (one card, dedup holds) — never append a duplicate. This is the doc-16
    /// pairing contract folded through the client transport, not just the EventBuilder.
    func testToolCardUpsertFoldsThroughTransportAndDedups() async throws {
        let (hostCh, clientCh) = LoopbackByteChannel.pair()
        let source = InspectorSource(channel: hostCh)
        let client = InspectorClient(channel: clientCh)
        let vm = InspectorViewModel()

        // Single consumer of this client: the view model's consume of events().
        let fold = Task { await vm.consume(client.events()) }
        defer { fold.cancel() }

        // pending tool_use → then its tool_result completes the SAME id.
        try await source.send(.toolCard(sampleCard(status: .pending)))
        try await source.send(.toolCard(sampleCard(output: "files", status: .completed)))

        await waitUntil({ vm.toolCards.first?.status == .completed }, "card never reached completed")

        XCTAssertEqual(vm.toolCards.count, 1, "re-emitted card with same id updates in place — no duplicate")
        XCTAssertEqual(vm.toolCards.first?.id, "t1")
        XCTAssertEqual(vm.toolCards.first?.status, .completed)
        XCTAssertEqual(vm.toolCards.first?.output, "files")

        await source.close()
    }

    /// Two distinct tool ids both appear, in arrival order; a third event re-touching the first id
    /// still leaves exactly two cards (dedup is per-id, ordering preserved).
    func testDistinctToolCardsAppendInOrderWhileDedupHoldsPerID() async throws {
        let (hostCh, clientCh) = LoopbackByteChannel.pair()
        let source = InspectorSource(channel: hostCh)
        let client = InspectorClient(channel: clientCh)
        let vm = InspectorViewModel()

        let fold = Task { await vm.consume(client.events()) }
        defer { fold.cancel() }

        try await source.send(.toolCard(sampleCard(id: "a", name: "Read", command: "open")))
        try await source.send(.toolCard(sampleCard(id: "b", name: "Grep", command: "find")))
        try await source.send(.toolCard(sampleCard(id: "a", name: "Read", command: "open", output: "done", status: .completed)))

        await waitUntil({ vm.toolCards.count == 2 && vm.toolCards.first?.status == .completed },
                        "expected exactly two cards with the first completed")

        XCTAssertEqual(vm.toolCards.map(\.id), ["a", "b"], "arrival order preserved across the upsert")
        XCTAssertEqual(vm.toolCards.first?.status, .completed)
        XCTAssertEqual(vm.toolCards.last?.status, .pending)

        await source.close()
    }

    /// A `sessionStarted` event populates header metadata, and `todosUpdated` REPLACES the list
    /// wholesale on each emission (latest-wins, doc 16) — folded through the transport.
    func testSessionAndTodosFoldThroughTransport() async throws {
        let (hostCh, clientCh) = LoopbackByteChannel.pair()
        let source = InspectorSource(channel: hostCh)
        let client = InspectorClient(channel: clientCh)
        let vm = InspectorViewModel()

        let fold = Task { await vm.consume(client.events()) }
        defer { fold.cancel() }

        try await source.send(.sessionStarted(SessionInfo(sessionID: "s1", model: "claude-opus-4-8", cwd: "/repo")))
        try await source.send(.todosUpdated([
            TodoItem(content: "a", status: .completed),
            TodoItem(content: "b", status: .inProgress, activeForm: "doing b"),
        ]))

        await waitUntil({ vm.session != nil && vm.todos.count == 2 }, "session/todos never folded")

        XCTAssertEqual(vm.session?.model, "claude-opus-4-8")
        XCTAssertEqual(vm.session?.cwd, "/repo")
        XCTAssertEqual(vm.todos.map(\.content), ["a", "b"])

        // A second todos emission replaces (not appends) — latest-wins.
        try await source.send(.todosUpdated([TodoItem(content: "c", status: .pending)]))
        await waitUntil({ vm.todos.map(\.content) == ["c"] }, "todos were appended instead of replaced")
        XCTAssertEqual(vm.todos.count, 1, "todosUpdated replaces the list wholesale")

        await source.close()
    }

    /// A subagent node plus a tool card addressed to it lands under that subagent's bucket, NOT the
    /// main timeline (the `.claudeCode` tree-attach contract), folded through the transport.
    func testSubagentCardAttachesUnderNodeNotMainTimeline() async throws {
        let (hostCh, clientCh) = LoopbackByteChannel.pair()
        let source = InspectorSource(channel: hostCh)
        let client = InspectorClient(channel: clientCh)
        let vm = InspectorViewModel()

        let fold = Task { await vm.consume(client.events()) }
        defer { fold.cancel() }

        try await source.send(.subagentUpdated(SubagentNode(id: "deadbeef", agentType: "Ariadne", status: .running)))
        try await source.send(.subagentToolCard(
            agentID: "deadbeef",
            card: ToolCard(id: "sa1", name: "Grep", input: .object([:]), output: "hit", status: .completed)
        ))

        await waitUntil({ vm.subagentCards["deadbeef"]?.count == 1 }, "subagent card never attached")

        XCTAssertTrue(vm.toolCards.isEmpty, "a subagent card must not leak into the main timeline")
        XCTAssertEqual(vm.subagents["deadbeef"]?.agentType, "Ariadne")
        XCTAssertEqual(vm.subagentCards["deadbeef"]?.first?.id, "sa1")
        XCTAssertEqual(vm.subagentTree.first?.cards.first?.id, "sa1", "tree projection carries the card")

        await source.close()
    }

    /// Keep-alive frames (host liveness) must be swallowed by the event stream — they never reach the
    /// fold, so the view model state is untouched. (Mirrors the transport-level guarantee, asserted
    /// here at the fold boundary the pane actually renders from.)
    func testKeepAliveIsSwallowedAndDoesNotPerturbTheFold() async throws {
        let (hostCh, clientCh) = LoopbackByteChannel.pair()
        let source = InspectorSource(channel: hostCh)
        let client = InspectorClient(channel: clientCh)
        let vm = InspectorViewModel()

        let fold = Task { await vm.consume(client.events()) }
        defer { fold.cancel() }

        try await source.sendKeepAlive()                       // must NOT fold to any state
        try await source.send(.toolCard(sampleCard(id: "real", status: .pending)))

        await waitUntil({ vm.toolCards.count == 1 }, "real card after keep-alive never folded")

        XCTAssertEqual(vm.toolCards.first?.id, "real")
        XCTAssertEqual(vm.unknownLineCount, 0, "keep-alive must not register as an unknown line")
        XCTAssertEqual(vm.toolCards.count, 1, "keep-alive added no spurious card")

        await source.close()
    }

    // MARK: - 2. The LivePaneSession glue path (the production .claudeCode fold point)

    /// Builds a `.claudeCode` `LivePaneSession` whose `makeInspector` returns a loopback-backed
    /// `InspectorClient`, then drives the SINGLE fold point `subscribeInspector()` (the WF5 leaf
    /// `.task`). Asserts the session's own `inspector` view model folds host events — proving the
    /// production glue, not just the raw transport.
    func testLivePaneSessionClaudeCodeFoldsViaSubscribeInspector() async throws {
        let (hostCh, clientCh) = LoopbackByteChannel.pair()
        let source = InspectorSource(channel: hostCh)

        // The store's makeInspector seam: hand the session a loopback-backed client (no network).
        let session = LivePaneSession.make(
            PaneSpec(kind: .claudeCode, title: "claude"),
            makeClient: { makeUnconnectedClient() },
            makeInspector: { _ in InspectorClient(channel: clientCh) }
        )

        XCTAssertEqual(session.kind, .claudeCode)
        let vm = try XCTUnwrap(session.inspector, "a claudeCode session must own an InspectorViewModel")

        // subscribeInspector is the single fold point (the WF5 leaf .task). It subscribes(fromSeq:0)
        // then consumes client.events() into the session's own view model.
        let fold = Task { await session.subscribeInspector() }
        defer { fold.cancel() }

        try await source.send(.toolCard(sampleCard(id: "x", name: "Bash", command: "echo hi", status: .pending)))
        try await source.send(.toolCard(sampleCard(id: "x", name: "Bash", command: "echo hi", output: "hi", status: .completed)))

        await waitUntil({ vm.toolCards.first?.status == .completed }, "session inspector never folded the card")

        XCTAssertEqual(vm.toolCards.count, 1, "dedup holds through the LivePaneSession fold")
        XCTAssertEqual(vm.toolCards.first?.output, "hi")

        await source.close()
    }

    /// The client side of `subscribeInspector()` MUST send a `subscribe(fromSeq: 0)` control to the
    /// host (full replay request) before folding — that is what a real host would key replay off.
    /// Assert the host observes exactly that control over the loopback.
    func testSubscribeInspectorSendsFullReplaySubscribeControl() async throws {
        let (hostCh, clientCh) = LoopbackByteChannel.pair()
        let source = InspectorSource(channel: hostCh)

        let session = LivePaneSession.make(
            PaneSpec(kind: .claudeCode, title: "claude"),
            makeClient: { makeUnconnectedClient() },
            makeInspector: { _ in InspectorClient(channel: clientCh) }
        )

        // Observe the host's inbound control channel.
        let controls = await source.controls()
        let observed = Task { () -> InspectorWireMessage? in
            for try await message in controls { return message }
            return nil
        }
        defer { observed.cancel() }

        let fold = Task { await session.subscribeInspector() }
        defer { fold.cancel() }

        let got = try await observed.value
        XCTAssertEqual(got, .subscribe(fromSeq: 0), "subscribeInspector requests a full replay (fromSeq 0)")

        await source.close()
    }

    /// `subscribeInspector()` is idempotent: a second call while a client is already live must NOT
    /// open a second consumer (which would split the stream — the single-consumer rule). Drive it
    /// twice and assert the fold still produces exactly one, correct card.
    func testSubscribeInspectorIsIdempotentNoDoubleConsumer() async throws {
        let (hostCh, clientCh) = LoopbackByteChannel.pair()
        let source = InspectorSource(channel: hostCh)

        var clientHandedOut = 0
        let session = LivePaneSession.make(
            PaneSpec(kind: .claudeCode, title: "claude"),
            makeClient: { makeUnconnectedClient() },
            makeInspector: { _ in
                clientHandedOut += 1
                return InspectorClient(channel: clientCh)
            }
        )
        let vm = try XCTUnwrap(session.inspector)

        // First subscribe starts the live fold.
        let fold1 = Task { await session.subscribeInspector() }
        defer { fold1.cancel() }

        try await source.send(.toolCard(sampleCard(id: "only", status: .pending)))
        await waitUntil({ vm.toolCards.count == 1 }, "first fold never folded the card")

        // Second subscribe must early-out (client already live) — no new client, no second consumer.
        await session.subscribeInspector()
        XCTAssertEqual(clientHandedOut, 1, "a live inspector must not be rebuilt / re-subscribed")

        try await source.send(.toolCard(sampleCard(id: "only", output: "ok", status: .completed)))
        await waitUntil({ vm.toolCards.first?.status == .completed }, "single consumer should still receive updates")

        XCTAssertEqual(vm.toolCards.count, 1, "no split stream / duplicate cards from a second subscribe")
        XCTAssertEqual(vm.toolCards.first?.output, "ok")

        await source.close()
    }

    /// Resume re-spawns a detached re-subscribe; a teardown in the SAME main-actor turn (before the
    /// re-subscribe task gets to run) must cancel it so the re-subscribe closes the just-built client
    /// rather than leaving a live consumer after teardown (the "T builds a client after teardown"
    /// window — fix: tracked + cancellable `inspectorTask` + cancellation re-checks in
    /// `subscribeInspector()`). We assert the session does not fold events after teardown and that the
    /// loopback host channel ends finished (the client was closed).
    func testResumeThenTeardownInSameTurnCancelsResubscribeAndClosesClient() async throws {
        let (hostCh, clientCh) = LoopbackByteChannel.pair()
        let source = InspectorSource(channel: hostCh)

        let session = LivePaneSession.make(
            PaneSpec(kind: .claudeCode, title: "claude"),
            makeClient: { makeUnconnectedClient() },
            makeInspector: { _ in InspectorClient(channel: clientCh) }
        )
        let vm = try XCTUnwrap(session.inspector)

        // resume() spawns the detached re-subscribe; teardown() in the SAME turn must cancel it BEFORE
        // it stores/uses a client, so no live consumer lingers. (No `await Task.yield()` between them —
        // that is the race window being closed.)
        await session.resume()
        await session.teardown()

        // Give the cancelled re-subscribe task a chance to run its cancellation branch (close + return).
        await Task.yield()
        try? await Task.sleep(nanoseconds: 20_000_000)

        // An event sent now must NOT be folded — the session is torn down, no live consumer remains.
        try? await source.send(.toolCard(sampleCard(id: "post", status: .pending)))
        await Task.yield()
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertTrue(vm.toolCards.isEmpty, "no card folds after teardown — the re-subscribe was cancelled")

        await source.close()
    }

    /// A non-`.claudeCode` session (`.terminal`) owns NO inspector and `subscribeInspector()` is a
    /// no-op (it must never reach for a second channel) — the terminal pane has only PATH 1.
    func testTerminalSessionHasNoInspectorAndSubscribeIsNoOp() async throws {
        var makeInspectorCalled = false
        let session = LivePaneSession.make(
            PaneSpec(kind: .terminal, title: "term"),
            makeClient: { makeUnconnectedClient() },
            makeInspector: { _ in
                makeInspectorCalled = true
                return nil
            }
        )

        XCTAssertNil(session.inspector, "a terminal pane has no structured inspector")

        await session.subscribeInspector()   // must be a clean no-op
        XCTAssertFalse(makeInspectorCalled, "a terminal session must never open a second channel")
    }

    // MARK: - 3. The real makeInspector wiring — pure port convention (no socket dialed)

    /// Binds to the real production wiring (author note): the inspector second channel rides the
    /// terminal port **+ `inspectorPortOffset`**. Pure math — never opens a socket. Pins the
    /// single-source convention so a host that later advertises a distinct port is a one-line change.
    func testInspectorPortConventionIsTerminalPortPlusOffset() {
        XCTAssertEqual(WorkspaceStore.inspectorPortOffset, 1, "documented single-source offset")
        XCTAssertEqual(
            WorkspaceStore.inspectorPort(for: ConnectionTarget(host: "127.0.0.1", port: 7420)),
            7421,
            "inspector NWConnection #2 = terminal port + offset"
        )
    }

    /// The convention saturates safely: a terminal on the TOP port has no room above it, so the
    /// inspector port is `nil` (and `liveMakeInspector` then returns `nil` — no inspector, terminal
    /// unaffected). Guards the `addingReportingOverflow` boundary.
    func testInspectorPortReturnsNilWhenTerminalIsOnTopPort() {
        XCTAssertNil(
            WorkspaceStore.inspectorPort(for: ConnectionTarget(host: "127.0.0.1", port: .max)),
            "no port above UInt16.max → inspector unavailable, not a crash"
        )
    }
}
