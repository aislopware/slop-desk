import AislopdeskClient
import AislopdeskProtocol
import AislopdeskTransport
import Foundation
import XCTest
@testable import AislopdeskWorkspaceCore

/// WI-4 (E4) — the client-side host-metadata round-trip: ``MetadataRequestRegistry`` (correlation +
/// never-hangs timeout), ``MetadataClient`` (typed decode + per-pane cache + validate-then-drop), and the
/// full wire path through a real ``AislopdeskClient`` + a fake ``ClientTransporting`` that echoes canned
/// `metadataResponse` frames. Every behavior has a test that FAILS on the un-fixed code:
/// - drop the registry timeout → the timeout tests hang;
/// - resolve ignoring `requestID` → the interleaved-correlation test swaps the replies;
/// - decode without `try?`/the status gate → the malformed/non-ok tests crash or return wrong data.
@MainActor
final class MetadataClientTests: XCTestCase {
    // MARK: - MetadataRequestRegistry

    func testNextIsMonotonicDistinctAndNeverZero() {
        let registry = MetadataRequestRegistry()
        var seen: [UInt32] = []
        for _ in 0..<100 { seen.append(registry.next()) }
        XCTAssertEqual(seen.first, 1, "the first minted id is 1")
        XCTAssertFalse(seen.contains(0), "id 0 is never handed out")
        XCTAssertEqual(Set(seen).count, seen.count, "every minted id is distinct")
        XCTAssertEqual(seen, seen.sorted(), "ids are monotonic")
    }

    func testReplyTimesOutToErrorEmptyNeverHangs() async {
        // No resolve() is EVER called → the registry's own timeout must resolve the await to (error,
        // empty). A short timeout keeps the green path fast; removing the timeout arming hangs this test.
        let registry = MetadataRequestRegistry(timeout: .milliseconds(50))
        let id = registry.next()
        let reply = await registry.reply(for: id)
        XCTAssertEqual(reply.status, MetadataStatus.error.rawValue)
        XCTAssertTrue(reply.payload.isEmpty)
    }

    func testResolveCorrelatesInterleavedRepliesByID() async {
        // Two requests in flight; replies arrive OUT OF ORDER. Each must route to its own id — the
        // correlation guarantee. (A resolve that ignored requestID would resume the wrong waiter.)
        let registry = MetadataRequestRegistry(timeout: .seconds(30))
        let idA = registry.next()
        let idB = registry.next()
        XCTAssertNotEqual(idA, idB)

        let taskA = Task { @MainActor in await registry.reply(for: idA) }
        let taskB = Task { @MainActor in await registry.reply(for: idB) }
        await waitUntil { registry.isPending(idA) && registry.isPending(idB) }

        registry.resolve(requestID: idB, status: MetadataStatus.ok.rawValue, payload: Data([0xBB]))
        registry.resolve(requestID: idA, status: MetadataStatus.notFound.rawValue, payload: Data([0xAA]))

        let replyA = await taskA.value
        let replyB = await taskB.value
        XCTAssertEqual(replyA.status, MetadataStatus.notFound.rawValue)
        XCTAssertEqual(replyA.payload, Data([0xAA]))
        XCTAssertEqual(replyB.status, MetadataStatus.ok.rawValue)
        XCTAssertEqual(replyB.payload, Data([0xBB]))
    }

    func testCancelAllUnblocksPendingToErrorEmpty() async {
        // A long timeout so ONLY cancelAll() can resolve the await — proves teardown unblocks a façade
        // mid-flight (instead of waiting out the timeout).
        let registry = MetadataRequestRegistry(timeout: .seconds(30))
        let id = registry.next()
        let task = Task { @MainActor in await registry.reply(for: id) }
        await waitUntil { registry.isPending(id) }
        registry.cancelAll()
        let reply = await task.value
        XCTAssertEqual(reply.status, MetadataStatus.error.rawValue)
        XCTAssertTrue(reply.payload.isEmpty)
    }

    func testResolveOfUnknownIDIsDroppedNotBuffered() async {
        // A stray/late reply for an id nobody awaits is dropped (not buffered) — so a subsequent request
        // that happens to reuse the id is not falsely pre-resolved. Here the unknown resolve is a no-op
        // and a real await for the SAME id then times out (proving the stale reply was discarded).
        let registry = MetadataRequestRegistry(timeout: .milliseconds(50))
        registry.resolve(requestID: 7, status: MetadataStatus.ok.rawValue, payload: Data([0x01]))
        XCTAssertFalse(registry.isPending(7))
        let reply = await registry.reply(for: 7)
        XCTAssertEqual(reply.status, MetadataStatus.error.rawValue, "the stray reply was not buffered → times out")
        XCTAssertTrue(reply.payload.isEmpty)
    }

    // MARK: - MetadataClient (typed decode via the echoing send seam)

    func testProcessesDecodesEchoedReply() async {
        let responder = EchoResponder()
        let client = MetadataClient(send: responder.send)
        responder.client = client
        responder.replies[MetadataVerb.processes.rawValue] = (
            status: MetadataStatus.ok.rawValue,
            payload: MetadataCodec.encodeProcessList([
                .init(pid: 42, uptimeSec: 7, name: "claude"),
                .init(pid: 9, uptimeSec: 0, name: "-zsh"),
            ]),
        )
        let processes = await client.processes()
        XCTAssertEqual(processes, [
            MetadataCodec.ProcessInfo(pid: 42, uptimeSec: 7, name: "claude"),
            MetadataCodec.ProcessInfo(pid: 9, uptimeSec: 0, name: "-zsh"),
        ])
        XCTAssertEqual(responder.captured.map(\.verb), [MetadataVerb.processes.rawValue])
    }

    func testPortsEmptyListDecodes() async {
        let responder = EchoResponder()
        let client = MetadataClient(send: responder.send)
        responder.client = client
        responder.replies[MetadataVerb.ports.rawValue] = (
            status: MetadataStatus.ok.rawValue,
            payload: MetadataCodec.encodePortList([]),
        )
        let ports = await client.ports()
        XCTAssertTrue(ports.isEmpty, "an empty ok PortList decodes to [] (the 'No listening ports' state)")
    }

    func testCwdDecodesUTF8AndCaches() async {
        let responder = EchoResponder()
        let client = MetadataClient(send: responder.send)
        responder.client = client
        responder.replies[MetadataVerb.cwd.rawValue] = (
            status: MetadataStatus.ok.rawValue,
            payload: Data("/Users/foo/repo".utf8),
        )
        let cwd = await client.cwd()
        XCTAssertEqual(cwd, "/Users/foo/repo")
        XCTAssertEqual(client.cachedCwd, "/Users/foo/repo", "an ok cwd is cached for the inspector's lastKnownCwd")
    }

    func testGitStatusNoRepoDecodes() async {
        let responder = EchoResponder()
        let client = MetadataClient(send: responder.send)
        responder.client = client
        responder.replies[MetadataVerb.gitStatus.rawValue] = (
            status: MetadataStatus.ok.rawValue,
            payload: MetadataCodec.encodeGitStatus(.noRepo),
        )
        let status = await client.gitStatus()
        XCTAssertEqual(status, .noRepo)
        XCTAssertEqual(status?.hasRepo, false)
    }

    func testGitDiffReturnsRawBytes() async {
        let responder = EchoResponder()
        let client = MetadataClient(send: responder.send)
        responder.client = client
        let diff = Data("@@ -1 +1 @@\n-old\n+new\n".utf8)
        responder.replies[MetadataVerb.gitDiff.rawValue] = (status: MetadataStatus.ok.rawValue, payload: diff)
        let result = await client.gitDiff(file: "src/main.swift")
        XCTAssertEqual(result, diff)
        // The request payload carries the repo-relative file path verbatim.
        XCTAssertEqual(responder.captured.first?.payload, Data("src/main.swift".utf8))
    }

    func testNonOkStatusReturnsEmpty() async {
        let responder = EchoResponder()
        let client = MetadataClient(send: responder.send)
        responder.client = client
        // status = error with a NON-empty payload: the façade must still return [] (the status gate, not
        // the payload, decides).
        responder.replies[MetadataVerb.processes.rawValue] = (
            status: MetadataStatus.error.rawValue,
            payload: MetadataCodec.encodeProcessList([.init(pid: 1, uptimeSec: 1, name: "x")]),
        )
        let processes = await client.processes()
        XCTAssertTrue(processes.isEmpty, "a non-ok status returns empty regardless of payload")
    }

    func testUnknownStatusByteClampsToErrorReturnsEmpty() async {
        let responder = EchoResponder()
        let client = MetadataClient(send: responder.send)
        responder.client = client
        // An unknown future status byte (99) is forward-tolerantly clamped to .error → empty.
        responder.replies[MetadataVerb.ports.rawValue] = (
            status: 99,
            payload: MetadataCodec.encodePortList([.init(port: 8080, proto: 0, procName: "node")]),
        )
        let ports = await client.ports()
        XCTAssertTrue(ports.isEmpty, "an unknown status byte clamps to error → empty (never trusts the payload)")
    }

    func testMalformedOkPayloadReturnsEmptyNeverThrows() async {
        // ES-E4-5: an ok status whose payload is a HOSTILE/truncated codec body (count says 5 entries, body
        // is empty) must be swallowed to [] — never trap, never throw to the caller.
        let responder = EchoResponder()
        let client = MetadataClient(send: responder.send)
        responder.client = client
        responder.replies[MetadataVerb.processes.rawValue] = (
            status: MetadataStatus.ok.rawValue,
            payload: Data([0x00, 0x05]), // UInt16 count = 5, then zero entry bytes → decode throws truncated
        )
        let processes = await client.processes()
        XCTAssertTrue(processes.isEmpty, "a malformed ok payload decodes to [] (validate-then-drop), never crashes")
    }

    func testRequestTimesOutToEmptyWhenReplyDropped() async {
        // The transport never echoes (dropAll) → the registry timeout resolves the façade to empty. A short
        // timeout keeps it fast; removing the timeout hangs this test.
        let responder = EchoResponder()
        responder.dropAll = true
        let client = MetadataClient(timeout: .milliseconds(50), send: responder.send)
        responder.client = client
        let processes = await client.processes()
        XCTAssertTrue(processes.isEmpty, "a dropped reply times out to empty — the panel never hangs")
    }

    func testRequestIDsAreUniqueAndMonotonicAcrossVerbs() async {
        let responder = EchoResponder()
        let client = MetadataClient(send: responder.send)
        responder.client = client
        responder.replies[MetadataVerb.processes.rawValue] = (
            MetadataStatus.ok.rawValue,
            MetadataCodec.encodeProcessList([]),
        )
        responder.replies[MetadataVerb.ports.rawValue] = (MetadataStatus.ok.rawValue, MetadataCodec.encodePortList([]))
        responder.replies[MetadataVerb.cwd.rawValue] = (MetadataStatus.ok.rawValue, Data("/x".utf8))
        _ = await client.processes()
        _ = await client.ports()
        _ = await client.cwd()
        let ids = responder.captured.map(\.requestID)
        XCTAssertEqual(ids.count, 3)
        XCTAssertEqual(Set(ids).count, 3, "each request carries a distinct correlation id")
        XCTAssertEqual(ids, ids.sorted(), "ids are monotonic across verbs")
        XCTAssertFalse(ids.contains(0))
    }

    func testListDirectoryCachesAndInvalidates() async {
        let responder = EchoResponder()
        let client = MetadataClient(send: responder.send)
        responder.client = client
        responder.replies[MetadataVerb.listDirectory.rawValue] = (
            status: MetadataStatus.ok.rawValue,
            payload: MetadataCodec.encodeDirListing([.init(isDir: true, name: "Sources")]),
        )
        let first = await client.listDirectory(path: "a")
        XCTAssertEqual(first, [MetadataCodec.DirEntry(isDir: true, name: "Sources")])
        XCTAssertEqual(responder.captured.count, 1)

        // Second call for the SAME path is served from cache — no new wire request.
        let second = await client.listDirectory(path: "a")
        XCTAssertEqual(second, first)
        XCTAssertEqual(responder.captured.count, 1, "a cached path does not re-fetch")

        // After invalidation the next call re-fetches.
        client.invalidateDirectoryCache()
        _ = await client.listDirectory(path: "a")
        XCTAssertEqual(responder.captured.count, 2, "invalidation forces a re-fetch")
    }

    // MARK: - PaneMetadataModel

    func testPaneModelRefreshPopulatesFromClient() async {
        let responder = EchoResponder()
        let client = MetadataClient(send: responder.send)
        responder.client = client
        responder.replies[MetadataVerb.processes.rawValue] = (
            MetadataStatus.ok.rawValue, MetadataCodec.encodeProcessList([.init(pid: 1, uptimeSec: 5, name: "claude")]),
        )
        responder.replies[MetadataVerb.ports.rawValue] = (
            MetadataStatus.ok.rawValue, MetadataCodec.encodePortList([.init(port: 3000, proto: 0, procName: "vite")]),
        )
        responder.replies[MetadataVerb.cwd.rawValue] = (MetadataStatus.ok.rawValue, Data("/repo".utf8))
        responder.replies[MetadataVerb.gitStatus.rawValue] = (
            MetadataStatus.ok.rawValue,
            MetadataCodec.encodeGitStatus(.init(
                hasRepo: true, branch: "main", remoteURL: "git@host:r.git", ahead: 1, behind: 0,
                files: [.init(statusCode: 0x20, path: "a.txt")],
            )),
        )
        responder.replies[MetadataVerb.listAgentSessions.rawValue] = (
            MetadataStatus.ok.rawValue,
            MetadataCodec.encodeAgentSessionList([
                .init(agentKindByte: 0, id: "s1", title: "t", cwd: "/repo", mtimeMS: 100),
            ]),
        )
        responder.replies[MetadataVerb.listDirectory.rawValue] = (
            MetadataStatus.ok.rawValue, MetadataCodec.encodeDirListing([.init(isDir: false, name: "README.md")]),
        )

        let model = PaneMetadataModel(client: client)
        await model.refresh()

        XCTAssertEqual(model.processes.map(\.name), ["claude"])
        XCTAssertEqual(model.ports.map(\.port), [3000])
        XCTAssertEqual(model.cwd, "/repo")
        XCTAssertEqual(model.gitStatus?.branch, "main")
        XCTAssertEqual(model.gitStatus?.ahead, 1)
        XCTAssertEqual(model.agentSessions.map(\.id), ["s1"])
        XCTAssertEqual(model.rootEntries.map(\.name), ["README.md"])
        XCTAssertFalse(model.isRefreshing)
    }

    func testPaneModelExpandThenCollapseKeepsChildren() async {
        let responder = EchoResponder()
        let client = MetadataClient(send: responder.send)
        responder.client = client
        responder.replies[MetadataVerb.listDirectory.rawValue] = (
            MetadataStatus.ok.rawValue, MetadataCodec.encodeDirListing([.init(isDir: false, name: "main.swift")]),
        )
        let model = PaneMetadataModel(client: client)
        await model.expand(path: "Sources")
        XCTAssertTrue(model.expandedPaths.contains("Sources"))
        XCTAssertEqual(model.childrenByPath["Sources"]?.map(\.name), ["main.swift"])
        model.collapse(path: "Sources")
        XCTAssertFalse(model.expandedPaths.contains("Sources"))
        XCTAssertEqual(model.childrenByPath["Sources"]?.map(\.name), ["main.swift"], "collapse keeps cached children")
    }

    func testPaneModelNoClientIsInertNeverHangs() async {
        let model = PaneMetadataModel(client: nil)
        await model.refresh() // must return immediately (no client)
        XCTAssertTrue(model.processes.isEmpty)
        XCTAssertFalse(model.isConnected)
        let diff = await model.gitDiff(file: "x")
        XCTAssertNil(diff)
    }

    // MARK: - Full wire path: AislopdeskClient + echoing ClientTransporting + fold

    func testEndToEndEchoedReplyDecodesThroughClientAndFold() async throws {
        let transport = RecordingMetadataTransport()
        let canned = MetadataCodec.encodeProcessList([.init(pid: 42, uptimeSec: 7, name: "claude")])
        await transport.setReply(
            verb: MetadataVerb.processes.rawValue, status: MetadataStatus.ok.rawValue, payload: canned,
        )
        let client = AislopdeskClient(makeTransport: { transport })
        try await client.connect(host: "h", port: 1)

        let metadataClient = MetadataClient(timeout: .seconds(2), send: { [weak client] requestID, verb, payload in
            try? await client?.requestMetadata(requestID: requestID, verb: verb, payload: payload)
        })

        // Fold .metadataResponse events into the façade registry — exactly ConnectionViewModel.foldEvent.
        let events = client.events
        let folder = Task { @MainActor in
            for await event in events {
                if case let .metadataResponse(id, status, payload) = event {
                    metadataClient.resolve(requestID: id, status: status, payload: payload)
                }
            }
        }

        let processes = await metadataClient.processes()
        folder.cancel()
        await client.close()

        XCTAssertEqual(processes, [MetadataCodec.ProcessInfo(pid: 42, uptimeSec: 7, name: "claude")])
        let requested = await transport.requested
        XCTAssertEqual(requested.count, 1)
        XCTAssertEqual(requested.first?.verb, MetadataVerb.processes.rawValue)
        XCTAssertNotEqual(requested.first?.requestID, 0)
    }

    func testRequestMetadataBeforeConnectThrows() async {
        let client = AislopdeskClient(makeTransport: { RecordingMetadataTransport() })
        do {
            try await client.requestMetadata(requestID: 1, verb: MetadataVerb.cwd.rawValue, payload: Data())
            XCTFail("requestMetadata before connect must throw, never silently no-op")
        } catch {
            // expected — invalidState
        }
        await client.close()
    }

    // MARK: - Helpers

    /// Polls `condition` on the main actor until true or `timeout`, yielding between checks so parked
    /// continuations / scheduled resolves get to run. Returns silently on timeout (the assertion that
    /// follows then fails attributably rather than the whole suite hanging).
    private func waitUntil(_ timeout: Duration = .seconds(2), _ condition: () -> Bool) async {
        let start = ContinuousClock.now
        while !condition() {
            if ContinuousClock.now - start > timeout { return }
            await Task.yield()
        }
    }
}

// MARK: - Fakes

/// A fake `send` seam for ``MetadataClient``: records every request and ECHOES a canned reply per verb,
/// DEFERRING the resolve to a later main-actor turn (mimicking the async wire — the real reply arrives via
/// the inbound pump well after `send` returns and the façade has registered its continuation).
@MainActor
private final class EchoResponder {
    weak var client: MetadataClient?
    var replies: [UInt8: (status: UInt8, payload: Data)] = [:]
    var dropAll = false
    private(set) var captured: [(requestID: UInt32, verb: UInt8, payload: Data)] = []

    func send(_ requestID: UInt32, _ verb: UInt8, _ payload: Data) {
        captured.append((requestID: requestID, verb: verb, payload: payload))
        guard !dropAll else { return }
        let reply = replies[verb] ?? (status: MetadataStatus.unsupportedVerb.rawValue, payload: Data())
        Task { @MainActor [weak self] in
            self?.client?.resolve(requestID: requestID, status: reply.status, payload: reply.payload)
        }
    }
}

/// A fake ``ClientTransporting`` that records `sendMetadataRequest` and echoes a canned `metadataResponse`
/// (per verb) straight back onto the inbound stream — the "fake transport that echoes canned responses".
private actor RecordingMetadataTransport: ClientTransporting {
    private var _sessionID: UUID?
    var sessionID: UUID? { _sessionID }
    var resumeFromSeq: Int64 { 0 }
    var returningClient: Bool { false }
    private(set) var requested: [(requestID: UInt32, verb: UInt8, payload: Data)] = []
    private var replies: [UInt8: (status: UInt8, payload: Data)] = [:]

    private let continuation: AsyncThrowingStream<WireMessage, Error>.Continuation
    nonisolated let inbound: AsyncThrowingStream<WireMessage, Error>

    init() {
        var c: AsyncThrowingStream<WireMessage, Error>.Continuation!
        inbound = AsyncThrowingStream { c = $0 }
        continuation = c
    }

    func setReply(verb: UInt8, status: UInt8, payload: Data) {
        replies[verb] = (status: status, payload: payload)
    }

    func connect(
        host _: String,
        port _: UInt16,
        resume _: UUID,
        lastReceivedSeq _: Int64,
        handshakeTimeout _: Duration,
    ) {
        _sessionID = UUID()
    }

    func sendInput(_: Data) {}
    func sendResize(cols _: UInt16, rows _: UInt16, pxWidth _: UInt16, pxHeight _: UInt16) {}
    func sendAck(seq _: Int64) {}
    func sendBye() {}
    func sendMetadataRequest(requestID: UInt32, verb: UInt8, payload: Data) {
        requested.append((requestID: requestID, verb: verb, payload: payload))
        guard let reply = replies[verb] else { return }
        continuation.yield(.metadataResponse(requestID: requestID, status: reply.status, payload: reply.payload))
    }

    func close() { continuation.finish() }
}
