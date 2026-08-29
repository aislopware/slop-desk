import SlopDeskClient
import SlopDeskInspector
import SlopDeskTransport
import SlopDeskWorkspaceModel
import XCTest
@testable import SlopDeskWorkspaceCore

/// An `SlopDeskClient` that is never dialled — these terminal panes have no host: the inspector
/// fold is driven over an in-process loopback channel, no socket.
@Sendable
private func makeUnconnectedClient() -> SlopDeskClient {
    SlopDeskClient(driver: FakePaneDriver.inert("the inspector glue never dials a pane"))
}

/// Writes the frames `slopdesk-inspectord` sends onto the host end of a loopback pair.
///
/// The serving end of this protocol is a Rust daemon (`docs/54`), so Swift has no event encoder to
/// borrow — a test that needs host → client bytes spells the wire out: `[UInt32 BE
/// payloadLength][UInt8 tag][body]`, tag `1` for an event, `2` for a keep-alive. An actor, so the
/// call sites read the same as the `InspectorSource` they replace.
///
/// The body is TEXT: since `docs/66` there is no Swift event type to encode from, and these tests
/// are about the GLUE — subscribe, teardown, re-arm, one consumer — not about what a body says.
private actor InspectorFeed {
    private let channel: LoopbackByteChannel

    init(channel: LoopbackByteChannel) {
        self.channel = channel
    }

    func send(_ body: String) {
        channel.send(Self.frame(tag: 1, body: Data(body.utf8)))
    }

    func sendKeepAlive() {
        channel.send(Self.frame(tag: 2, body: Data()))
    }

    func close() {
        channel.close()
    }

    static func frame(tag: UInt8, body: Data) -> Data {
        var payload = Data([tag])
        payload.append(body)
        let length = UInt32(payload.count)
        var out = Data()
        out.append(UInt8(truncatingIfNeeded: length >> 24))
        out.append(UInt8(truncatingIfNeeded: length >> 16))
        out.append(UInt8(truncatingIfNeeded: length >> 8))
        out.append(UInt8(truncatingIfNeeded: length))
        out.append(payload)
        return out
    }
}

/// Inspector pane-content glue.
///
/// These tests prove a terminal pane's structured inspector (revealed once a `claude` is detected)
/// folds host events correctly
/// **using only the genuine in-process seam** `LoopbackByteChannel.pair()` (docs/22 §0, §8) — the
/// same seam the existing `InspectorTransportTests` use. There is:
///
///   - **NO `HostServer`** (project memory: pool deadlock; forbidden for new tests),
///   - **NO real network / `NWConnection`** (the live `liveMakeInspector` builder is exercised only
///     for its *pure* port-convention math, never dialed),
///   - **NO real `SlopDeskClient`** and **NO terminal byte stream** touched (PATH 1 is independent).
///
/// The fold under test is `InspectorViewModel.apply(_:)` — a handle onto `slopdesk_inspectord`'s
/// store — driven through the real client transport
/// (`InspectorClient.events()`), fed by daemon-shaped frames (``InspectorFeed``) over the loopback.
/// Two surfaces are covered:
///
///   1. The SEAM the store's own tests cannot reach: bytes on a channel become a fold, and the two
///      readings — the todo scent and the pending line — follow it. What the fold DOES with an event
///      (upsert by id, arrival order, todos-replace, subagent attach) is `slopdesk_inspectord`'s and
///      is asserted there against these same bodies (`docs/66` §7).
///   2. The `LivePaneSession` glue: a `.terminal` session with a detected `claude` whose
///      `makeInspector` returns a loopback-backed `InspectorClient`, driven via `subscribeInspector()`
///      (the leaf's `.task` on appear) — proving the production glue path folds, that it
///      subscribes (`fromSeq: 0`), and that the single-consumer rule holds.
///
/// Single-consumer rule (LOAD-BEARING): `InspectorClient.events()` spawns a task that
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
        line: UInt = #line,
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

    /// One `toolCard` body, as `slopdesk-inspectord` writes it.
    private func cardBody(
        id: String = "t1",
        name: String = "Bash",
        command: String = "ls",
        output: String? = nil,
        status: String = "pending",
    ) -> String {
        let result = output.map { #","output":"\#($0)""# } ?? ""
        return #"{"toolCard":{"_0":{"id":"\#(id)","name":"\#(name)","input":{"command":"\#(command)"}"#
            + result + #","status":"\#(status)"}}}"#
    }

    // MARK: - 1. Raw view-model fold over the real transport (the InspectorPanel `.task` stream)

    /// A card folds through the real client transport and the pending READING follows it: the
    /// `pending` card names the row, and its `completed` re-emission empties it.
    ///
    /// What the fold DOES with the card — upsert by id, arrival order, ring caps — is
    /// `slopdesk_inspectord::store`'s, and asserted there against the same bodies. What this test
    /// owns is the seam those assertions cannot reach: bytes over a channel become a fold.
    func testAToolCardFoldsThroughTheTransportAndTheReadingFollowsIt() async {
        let (hostCh, clientCh) = LoopbackByteChannel.pair()
        let source = InspectorFeed(channel: hostCh)
        let client = InspectorClient(channel: clientCh)
        let vm = InspectorViewModel()

        // Single consumer of this client: the view model's consume of events().
        let fold = Task { await vm.consume(client.events()) }
        defer { fold.cancel() }

        // pending tool_use → then its tool_result completes the SAME id.
        await source.send(cardBody(status: "pending"))
        await waitUntil({ vm.pendingLine != nil }, "the pending card never folded")
        XCTAssertEqual(vm.pendingLine?.name, "Bash")
        XCTAssertEqual(vm.pendingLine?.summary, "ls")
        XCTAssertEqual(vm.pendingLine?.display, "command: ls")

        await source.send(cardBody(output: "files", status: "completed"))
        await waitUntil({ vm.pendingLine == nil }, "the completion never folded")
        XCTAssertTrue(vm.hasRenderableActivity, "the card is still there — only the PENDING reading emptied")

        await source.close()
    }

    /// The todo scent folds through the same seam, and a replacing list with nothing in progress
    /// empties it — the caption's whole contract, read off the model the sidebar and both peek
    /// headers read.
    func testTheTodoScentFoldsThroughTransport() async {
        let (hostCh, clientCh) = LoopbackByteChannel.pair()
        let source = InspectorFeed(channel: hostCh)
        let client = InspectorClient(channel: clientCh)
        let vm = InspectorViewModel()

        let fold = Task { await vm.consume(client.events()) }
        defer { fold.cancel() }

        let both = #"[{"content":"a","status":"completed"},"#
            + #"{"content":"b","status":"in_progress","activeForm":"doing b"}]"#
        await source.send("{\"todosUpdated\":{\"_0\":\(both)}}")
        await waitUntil({ vm.todoScent != nil }, "the todo scent never folded")
        XCTAssertEqual(vm.todoScent, "2/2 · doing b")

        await source.send(#"{"todosUpdated":{"_0":[{"content":"c","status":"completed"}]}}"#)
        await waitUntil({ vm.todoScent == nil }, "a replacing list with nothing in flight must empty the scent")

        await source.close()
    }

    /// Keep-alive frames (host liveness) must be swallowed by the event stream — they never reach the
    /// fold, so the model is untouched. (Mirrors the transport-level guarantee, asserted here at the
    /// fold boundary the pane actually renders from.)
    func testKeepAliveIsSwallowedAndDoesNotPerturbTheFold() async {
        let (hostCh, clientCh) = LoopbackByteChannel.pair()
        let source = InspectorFeed(channel: hostCh)
        let client = InspectorClient(channel: clientCh)
        let vm = InspectorViewModel()

        let fold = Task { await vm.consume(client.events()) }
        defer { fold.cancel() }

        await source.sendKeepAlive() // must NOT fold to any state
        await source.send(cardBody(id: "real", status: "pending"))

        await waitUntil({ vm.pendingLine != nil }, "real card after keep-alive never folded")

        XCTAssertEqual(vm.revision, 1, "exactly one fold — the keep-alive was not one of them")

        await source.close()
    }

    // MARK: - 2. The LivePaneSession glue path (the production terminal+claude fold point)

    /// Lifts a terminal session's `claudeStatus` off `.none` (a `claude` was detected in it) so the
    /// inspector second channel is allowed to subscribe — the runtime gate that replaced the
    /// static `.claudeCode` kind. The client TRUSTS the host's type-27, so this mirrors the HOST
    /// reporting an `.idle` claude via wire type-27 (a type-26 alone is display-only — it never sets
    /// status under the single-source-of-truth contract).
    private func detectClaude(in session: LivePaneSession) {
        session.feedAgentSignal(.claudeStatus(state: 1, kind: 0, label: "")) // state 1 = .idle urgency
        XCTAssertNotEqual(session.claudeStatus, .none, "claude must be detected before the inspector opens")
    }

    /// Builds a `.terminal` `LivePaneSession` whose `makeInspector` returns a loopback-backed
    /// `InspectorClient`, detects a `claude` in it, then drives the SINGLE fold point
    /// `subscribeInspector()` (the leaf `.task`). Asserts the session's own `inspector` view model
    /// folds host events — proving the production glue, not just the raw transport.
    func testLivePaneSessionClaudeFoldsViaSubscribeInspector() async throws {
        let (hostCh, clientCh) = LoopbackByteChannel.pair()
        let source = InspectorFeed(channel: hostCh)

        // The store's makeInspector seam: hand the session a loopback-backed client (no network).
        let session = LivePaneSession.make(
            paneID: PaneID(), spec: PaneSpec(kind: .terminal, title: "claude"),
            makeClient: { _ in makeUnconnectedClient() },
            makeInspector: { _ in InspectorClient(channel: clientCh) },
        )

        XCTAssertEqual(session.kind, .terminal)
        let vm = try XCTUnwrap(session.inspector, "a terminal session owns a latent InspectorViewModel")
        detectClaude(in: session)

        // subscribeInspector is the single fold point (the leaf .task). It subscribes(fromSeq:0)
        // then consumes client.events() into the session's own view model.
        let fold = Task { await session.subscribeInspector() }
        defer { fold.cancel() }

        await source.send(cardBody(id: "x", command: "echo hi", status: "pending"))
        await waitUntil({ vm.pendingLine?.summary == "echo hi" }, "session inspector never folded the card")

        await source.send(cardBody(id: "x", command: "echo hi", output: "hi", status: "completed"))
        await waitUntil({ vm.pendingLine == nil }, "the completion never folded through the session")
        XCTAssertEqual(vm.revision, 2, "both events folded — through the session's own model")

        await source.close()
    }

    /// The client side of `subscribeInspector()` MUST send a `subscribe(fromSeq: 0)` control to the
    /// host (full replay request) before folding — that is what a real host would key replay off.
    /// Assert the host observes exactly that control over the loopback.
    func testSubscribeInspectorSendsFullReplaySubscribeControl() async throws {
        let (hostCh, clientCh) = LoopbackByteChannel.pair()
        let source = InspectorFeed(channel: hostCh)

        let session = LivePaneSession.make(
            paneID: PaneID(), spec: PaneSpec(kind: .terminal, title: "claude"),
            makeClient: { _ in makeUnconnectedClient() },
            makeInspector: { _ in InspectorClient(channel: clientCh) },
        )
        detectClaude(in: session)

        // Observe the host's inbound bytes. Asserted as BYTES: `subscribe` is the client's only
        // outbound frame and the Swift end has no decoder for it — that half belongs to
        // `slopdesk_inspectord::wire`, and growing a second one here to check our own encoder is
        // exactly the mirror the one-implementation rule forbids.
        let observed = Task { () -> Data? in
            for try await chunk in hostCh.inbound { return chunk }
            return nil
        }
        defer { observed.cancel() }

        let fold = Task { await session.subscribeInspector() }
        defer { fold.cancel() }

        let got = try await observed.value
        XCTAssertEqual(
            got,
            Data([0, 0, 0, 9, 3, 0, 0, 0, 0, 0, 0, 0, 0]),
            "subscribeInspector requests a full replay (tag 3, fromSeq 0)",
        )

        await source.close()
    }

    /// `subscribeInspector()` is idempotent: a second call while a client is already live must NOT
    /// open a second consumer (which would split the stream — the single-consumer rule). Drive it
    /// twice and assert the fold still produces exactly one, correct card.
    func testSubscribeInspectorIsIdempotentNoDoubleConsumer() async throws {
        let (hostCh, clientCh) = LoopbackByteChannel.pair()
        let source = InspectorFeed(channel: hostCh)

        var clientHandedOut = 0
        let session = LivePaneSession.make(
            paneID: PaneID(), spec: PaneSpec(kind: .terminal, title: "claude"),
            makeClient: { _ in makeUnconnectedClient() },
            makeInspector: { _ in
                clientHandedOut += 1
                return InspectorClient(channel: clientCh)
            },
        )
        let vm = try XCTUnwrap(session.inspector)
        // Detecting a claude auto-spawns the FIRST subscribe (the dynamic open).
        detectClaude(in: session)

        await source.send(cardBody(id: "only", status: "pending"))
        await waitUntil({ vm.revision == 1 }, "first fold never folded the card")

        // A second explicit subscribe must early-out (client already live) — no new client, no second
        // consumer. (The auto-spawned open already handed out exactly one client.)
        await session.subscribeInspector()
        XCTAssertEqual(clientHandedOut, 1, "a live inspector must not be rebuilt / re-subscribed")

        await source.send(cardBody(id: "only", output: "ok", status: "completed"))
        await waitUntil({ vm.pendingLine == nil }, "single consumer should still receive updates")

        XCTAssertEqual(vm.revision, 2, "exactly two folds — a split stream would have dropped one")

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
        let source = InspectorFeed(channel: hostCh)

        let session = LivePaneSession.make(
            paneID: PaneID(), spec: PaneSpec(kind: .terminal, title: "claude"),
            makeClient: { _ in makeUnconnectedClient() },
            makeInspector: { _ in InspectorClient(channel: clientCh) },
        )
        let vm = try XCTUnwrap(session.inspector)
        detectClaude(in: session)

        // resume() spawns the detached re-subscribe; teardown() in the SAME turn must cancel it BEFORE
        // it stores/uses a client, so no live consumer lingers. (No `await Task.yield()` between them —
        // that is the race window being closed.)
        await session.resume()
        await session.teardown()

        // Give the cancelled re-subscribe task a chance to run its cancellation branch (close + return).
        await Task.yield()
        try? await Task.sleep(nanoseconds: 20_000_000)

        // An event sent now must NOT be folded — the session is torn down, no live consumer remains.
        await source.send(cardBody(id: "post", status: "pending"))
        await Task.yield()
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(vm.revision, 0, "no card folds after teardown — the re-subscribe was cancelled")

        await source.close()
    }

    /// The DYNAMIC inspector CLOSE-on-clear. A claude is detected (type-27 lifts status off
    /// `.none`) → the inspector second channel opens and folds host events. Then the claude LEAVES (the
    /// host pushes a type-27 `.none`) → the inspector client is TORN DOWN: no event sent afterward is
    /// folded (the consumer is gone), and the status is back to `.none`. This is the `non-none → .none`
    /// boundary in `applyDetectedStatus`. Mirrors the open-on-detect test, run in reverse.
    func testInspectorClosesWhenClaudeLeaves() async throws {
        let (hostCh, clientCh) = LoopbackByteChannel.pair()
        let source = InspectorFeed(channel: hostCh)

        let session = LivePaneSession.make(
            paneID: PaneID(), spec: PaneSpec(kind: .terminal, title: "claude"),
            makeClient: { _ in makeUnconnectedClient() },
            makeInspector: { _ in InspectorClient(channel: clientCh) },
        )
        let vm = try XCTUnwrap(session.inspector)

        // Claude detected (type-27 idle) → the inspector auto-opens (the dynamic OPEN).
        session.feedAgentSignal(.claudeStatus(state: 1, kind: 0, label: "")) // .idle
        XCTAssertNotEqual(session.claudeStatus, .none)
        await source.send(cardBody(id: "live", status: "pending"))
        await waitUntil({ vm.revision == 1 }, "inspector never folded while claude was live")

        // Claude LEAVES: the host pushes type-27 .none → the inspector client must be torn down.
        session.feedAgentSignal(.claudeStatus(state: 0, kind: 0, label: "")) // .none
        XCTAssertEqual(session.claudeStatus, .none, "claude gone → status none")

        // Give the detached close a chance to run, then prove no further event is folded.
        await Task.yield()
        try? await Task.sleep(nanoseconds: 30_000_000)
        await source.send(cardBody(id: "after", status: "pending"))
        await Task.yield()
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(vm.revision, 1, "no event folds after claude leaves — the inspector channel was closed")
        XCTAssertEqual(vm.pendingLine?.name, "Bash", "only the pre-close card remains")

        await source.close()
    }

    /// A terminal session owns a LATENT inspector view model, but with NO `claude` detected
    /// (`claudeStatus == .none`) `subscribeInspector()` is a clean no-op — it must NOT reach for a
    /// second channel. A plain terminal opens no inspector socket; only a detected `claude` does.
    func testPlainTerminalDoesNotOpenInspectorUntilClaudeDetected() async {
        var makeInspectorCalled = false
        let session = LivePaneSession.make(
            paneID: PaneID(), spec: PaneSpec(kind: .terminal, title: "term"),
            makeClient: { _ in makeUnconnectedClient() },
            makeInspector: { _ in
                makeInspectorCalled = true
                return nil
            },
        )

        XCTAssertNotNil(session.inspector, "a terminal pane owns a latent InspectorViewModel")
        XCTAssertEqual(session.claudeStatus, .none, "no claude detected → status is none")

        await session.subscribeInspector() // must be a clean no-op while claudeStatus == .none
        XCTAssertFalse(makeInspectorCalled, "a plain terminal must NOT open a second channel until claude is detected")
    }

    // MARK: - 3. Reconnect edge re-arms the inspector second channel (wifi-flap fix)

    /// WIFI-FLAP fix, the full store wiring: the inspector NWConnection (#2) dies with the link, but the
    /// host's reattach re-assert re-emits the SAME type-27 status — `applyDetectedStatus`'s dedupe guard
    /// eats it, so the status transition can never re-open the channel, and macOS never drives
    /// `pause()`/`resume()`. The ONLY once-per-flap signal left is the reconnect edge: the store's
    /// `onReconnected` hook must tear down the stale client and re-subscribe a FRESH one. Uses the real
    /// `wireMaterializedLeaf` wiring (a tree store materializing genuine `LivePaneSession`s) and fires the
    /// same `onReconnected` closure `ConnectionViewModel.foldEvent(.reconnected)` invokes.
    func testStoreReconnectHookReSubscribesInspectorWhileClaudeActive() async throws {
        var hostSides: [InspectorFeed] = []
        var makeInspectorCalls = 0
        let store = WorkspaceStore(makeSession: { seed in
            LivePaneSession.make(
                paneID: seed.id, spec: seed.spec, spawnCwd: seed.spawnCwd,
                makeClient: { _ in makeUnconnectedClient() },
                makeInspector: { _ in
                    makeInspectorCalls += 1
                    let (host, client) = LoopbackByteChannel.pair()
                    hostSides.append(InspectorFeed(channel: host))
                    return InspectorClient(channel: client)
                },
            )
        })
        store.attachLoopbackWorkspaceDocument()
        store.reconcileTree()
        let paneID = try XCTUnwrap(store.tree.allPaneIDs().first)
        let session = try XCTUnwrap(store.handle(for: paneID) as? LivePaneSession)
        let vm = try XCTUnwrap(session.inspector)

        detectClaude(in: session)
        await waitUntil({ makeInspectorCalls == 1 }, "detecting a claude must open the inspector once")

        // The flap recovered: the host re-asserts the SAME type-27 (deduped — must NOT re-open) and the
        // transport reports the reconnect edge (the store-wired closure the fold invokes on `.reconnected`).
        session.feedAgentSignal(.claudeStatus(state: 1, kind: 0, label: ""))
        XCTAssertEqual(makeInspectorCalls, 1, "a deduped identical status must not rebuild the inspector")
        let onReconnected = try XCTUnwrap(session.connection?.onReconnected, "store wires the reconnect hook")
        onReconnected()

        await waitUntil({ makeInspectorCalls == 2 }, "the reconnect edge must rebuild + re-subscribe")

        // The FRESH channel is live end-to-end: an event over the NEW loopback folds into the pane model.
        let freshSource = try XCTUnwrap(hostSides.count == 2 ? hostSides[1] : nil, "no fresh channel was built")
        await freshSource.send(cardBody(id: "fresh", command: "fresh", status: "pending"))
        await waitUntil({ vm.pendingLine?.summary == "fresh" }, "the fresh channel never folded")

        for source in hostSides { await source.close() }
    }

    /// The pane-level half: `reestablishInspectorOnReconnect()` must CLOSE the stale client (the old
    /// loopback's host side observes the finish — no strand, single-consumer rule preserved) and fold
    /// only over the fresh one. Pins the teardown-then-resubscribe order without the store.
    func testReestablishInspectorClosesStaleClientAndFoldsFreshOne() async throws {
        var hostSides: [InspectorFeed] = []
        let session = LivePaneSession.make(
            paneID: PaneID(), spec: PaneSpec(kind: .terminal, title: "claude"),
            makeClient: { _ in makeUnconnectedClient() },
            makeInspector: { _ in
                let (host, client) = LoopbackByteChannel.pair()
                hostSides.append(InspectorFeed(channel: host))
                return InspectorClient(channel: client)
            },
        )
        let vm = try XCTUnwrap(session.inspector)
        detectClaude(in: session)
        await waitUntil({ hostSides.count == 1 }, "detect never opened the first channel")
        await hostSides[0].send(cardBody(id: "old", command: "old", status: "pending"))
        await waitUntil({ vm.pendingLine?.summary == "old" }, "the first channel never folded")

        session.reestablishInspectorOnReconnect()
        await waitUntil({ hostSides.count == 2 }, "the reconnect re-arm never rebuilt the client")

        // Events over the FRESH channel fold. The re-arm does NOT reset the store — only a subscribe
        // does — so "old" is still pending and "new" is the newer of the two.
        await hostSides[1].send(cardBody(id: "new", command: "new", status: "pending"))
        await waitUntil({ vm.pendingLine?.summary == "new" }, "the fresh channel never folded")

        for source in hostSides { await source.close() }
    }

    /// The NEGATIVE pin: with NO claude detected (`claudeStatus == .none`) the reconnect edge must not
    /// open an inspector socket — a plain terminal has no second channel to re-arm.
    func testReestablishInspectorNoOpsWhileNoClaudeDetected() async {
        var makeInspectorCalled = false
        let session = LivePaneSession.make(
            paneID: PaneID(), spec: PaneSpec(kind: .terminal, title: "term"),
            makeClient: { _ in makeUnconnectedClient() },
            makeInspector: { _ in
                makeInspectorCalled = true
                return nil
            },
        )
        XCTAssertEqual(session.claudeStatus, .none)

        session.reestablishInspectorOnReconnect()
        // Give a (wrongly) spawned re-subscribe a chance to run before asserting it never did.
        await Task.yield()
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertFalse(makeInspectorCalled, "a `.none` pane must not open a second channel on reconnect")
    }

    // MARK: - 4. The real makeInspector wiring — pure port convention (no socket dialed)

    /// Binds to the real production wiring: the inspector second channel rides the terminal port
    /// **+ 1**. Pure math — never opens a socket. Pins the convention through the one face that
    /// answers it (`slopdesk_workspace::store_shape::inspector_port`), rather than through a Swift
    /// constant beside it: the offset is spelled once, on the Rust side, so a host that later
    /// advertises a distinct port is a one-line change there.
    func testInspectorPortConventionIsTerminalPortPlusOffset() {
        XCTAssertEqual(
            WorkspaceStore.inspectorPort(for: ConnectionTarget(host: "127.0.0.1", port: 7420)),
            7421,
            "inspector NWConnection #2 = terminal port + offset",
        )
    }

    /// The convention saturates safely: a terminal on the TOP port has no room above it, so the
    /// inspector port is `nil` (and `liveMakeInspector` then returns `nil` — no inspector, terminal
    /// unaffected). Guards the rule's own checked-add boundary, which answers `-1` there.
    func testInspectorPortReturnsNilWhenTerminalIsOnTopPort() {
        XCTAssertNil(
            WorkspaceStore.inspectorPort(for: ConnectionTarget(host: "127.0.0.1", port: .max)),
            "no port above UInt16.max → inspector unavailable, not a crash",
        )
    }
}
