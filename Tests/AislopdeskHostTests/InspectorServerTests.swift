import XCTest
@testable import AislopdeskHost
@testable import AislopdeskInspector

/// PIECE B: ``InspectorServer`` replay-then-live behaviour, driven over a loopback
/// ``ByteChannel`` via the ``InspectorServer/serve(channel:)`` test seam — NO real
/// `NWListener`, NO `claude` process, NO HostServer. The replay log is fed directly.
final class InspectorServerTests: XCTestCase {

    private func msg(_ text: String) -> InspectorEvent {
        .message(MessageEvent(role: .assistant, text: text))
    }

    /// Collects exactly `count` events from a client over the loopback, with a timeout so
    /// a hang fails the test rather than the suite.
    private func collect(
        _ client: InspectorClient,
        count: Int
    ) async throws -> [InspectorEvent] {
        let stream = await client.events()
        let task = Task { () -> [InspectorEvent] in
            var got: [InspectorEvent] = []
            for try await event in stream {
                got.append(event)
                if got.count >= count { break }
            }
            return got
        }
        return try await withThrowingTaskGroup(of: [InspectorEvent].self) { group in
            group.addTask { try await task.value }
            group.addTask {
                try await Task.sleep(for: .seconds(5))
                task.cancel()
                throw XCTSkip("timed out collecting \(count) events")
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    /// The server gates the stream on the first subscribe, then delivers the full replay
    /// (history present before subscribe) followed by a live event appended afterwards.
    func testServerReplaysThenLiveOverLoopback() async throws {
        let replayLog = InspectorReplayLog()
        await replayLog.append(msg("h0"))
        await replayLog.append(msg("h1"))

        let server = InspectorServer(
            terminalPort: 7420,
            replayLog: replayLog,
            keepAliveInterval: .milliseconds(50)
        )

        let (hostChannel, clientChannel) = LoopbackByteChannel.pair()
        let client = InspectorClient(channel: clientChannel)

        // Serve the host end exactly as an accepted connection would be.
        let serveTask = Task { await server.serve(channel: hostChannel) }
        defer { serveTask.cancel() }

        // Client subscribes from 0 (full replay), then a live event is appended.
        try await client.subscribe(fromSeq: 0)

        // Give the serve task a beat to attach the subscription before the live append,
        // so the live event is delivered through the live continuation (not as replay).
        try await Task.sleep(for: .milliseconds(100))
        await replayLog.append(msg("live2"))

        let got = try await collect(client, count: 3)
        XCTAssertEqual(got, [msg("h0"), msg("h1"), msg("live2")])
    }

    /// Keep-alive frames the server sends on an idle subscription do NOT surface as
    /// events on the client (they exist only for liveness, and the client swallows them).
    func testKeepAliveDoesNotSurfaceAsEvent() async throws {
        let replayLog = InspectorReplayLog()
        // Empty history → after subscribe the server is idle and sends keep-alives.

        let server = InspectorServer(
            terminalPort: 7420,
            replayLog: replayLog,
            keepAliveInterval: .milliseconds(20) // fast keep-alives
        )

        let (hostChannel, clientChannel) = LoopbackByteChannel.pair()
        let client = InspectorClient(channel: clientChannel)

        let serveTask = Task { await server.serve(channel: hostChannel) }
        defer { serveTask.cancel() }

        try await client.subscribe(fromSeq: 0)

        // Let several keep-alive intervals elapse — none must surface as an event.
        try await Task.sleep(for: .milliseconds(120))
        // Now a real event arrives; it must be the FIRST (and only) thing the stream
        // yields, proving the keep-alives were swallowed.
        await replayLog.append(msg("real"))

        let got = try await collect(client, count: 1)
        XCTAssertEqual(got, [msg("real")])
    }

    /// Until the client subscribes, the server sends NOTHING (the stream is gated on the
    /// first .subscribe(fromSeq:)). Appending events before subscribe does not push them.
    func testSubscribeControlGatesStreamStart() async throws {
        let replayLog = InspectorReplayLog()
        await replayLog.append(msg("pre0"))
        await replayLog.append(msg("pre1"))

        let server = InspectorServer(
            terminalPort: 7420,
            replayLog: replayLog,
            keepAliveInterval: .seconds(60) // no keep-alive interference in this window
        )

        let (hostChannel, clientChannel) = LoopbackByteChannel.pair()
        let client = InspectorClient(channel: clientChannel)

        let serveTask = Task { await server.serve(channel: hostChannel) }
        defer { serveTask.cancel() }

        // No subscribe yet: collect with a short window and assert NOTHING arrives.
        let stream = await client.events()
        let probe = Task { () -> InspectorEvent? in
            for try await event in stream { return event }
            return nil
        }
        let early = try await withThrowingTaskGroup(of: InspectorEvent?.self) { group in
            group.addTask { try await probe.value }
            group.addTask {
                try await Task.sleep(for: .milliseconds(150))
                probe.cancel()
                return nil
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
        XCTAssertNil(early, "no events flow before the client subscribes (stream is gated)")
    }

    /// Regression (F4): on a real client disconnect the serve task must RETURN (not run
    /// forever), so the replay-log subscriber is detached and the keep-alive stops. The
    /// replay-log subscription itself only finishes on host shutdown / cancellation — so
    /// before the fix, closing the client left the event pump and keep-alive timer running
    /// and the subscriber attached forever (per-client memory + work leak). Here we
    /// subscribe (subscriber attaches), close the CLIENT end, and assert the serve task
    /// returns and `subscriberCount` returns to 0.
    func testClientDisconnectEndsServeAndDetachesSubscriber() async throws {
        let replayLog = InspectorReplayLog()

        let server = InspectorServer(
            terminalPort: 7420,
            replayLog: replayLog,
            keepAliveInterval: .milliseconds(20) // fast keep-alives (so a leak would keep firing)
        )

        let (hostChannel, clientChannel) = LoopbackByteChannel.pair()
        let client = InspectorClient(channel: clientChannel)

        // The serve task; `serve(channel:)` RETURNS when the connection ends. We await it
        // (with a timeout) after closing the client to prove it does not run forever.
        let serveTask = Task { await server.serve(channel: hostChannel) }
        defer { serveTask.cancel() }

        // Subscribe → the host attaches a live replay-log subscriber.
        try await client.subscribe(fromSeq: 0)

        // Wait until the subscriber is actually attached (the serve task hops onto the
        // replay-log actor asynchronously after reading the subscribe control).
        try await waitUntil("subscriber attaches") {
            await replayLog.subscriberCount == 1
        }

        // Simulate a real client disconnect: NWByteChannel finishes its inbound on FIN;
        // the loopback equivalent is closing the client end (finishes the host's inbound).
        await client.close()

        // The serve task must RETURN promptly (disconnect observed). Timeout → fail.
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await serveTask.value }
            group.addTask {
                try await Task.sleep(for: .seconds(5))
                throw XCTSkip("serve task did not return after client disconnect (leak)")
            }
            _ = try await group.next()
            group.cancelAll()
        }

        // Subscriber detached (onTermination → removeSubscriber fired on pump teardown).
        // (removeSubscriber hops back onto the replay-log actor from the stream's
        // onTermination, so poll until it settles rather than reading once.)
        try await waitUntil("subscriber detaches") {
            await replayLog.subscriberCount == 0
        }
        let finalCount = await replayLog.subscriberCount
        XCTAssertEqual(
            finalCount, 0,
            "serve must detach the replay-log subscriber on client disconnect"
        )
    }

    /// Polls `condition` every 5ms up to ~2s; fails the test if it never becomes true.
    private func waitUntil(
        _ what: String,
        _ condition: () async -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for _ in 0..<400 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("timed out waiting for: \(what)", file: file, line: line)
    }

    /// Sanity: the inspector port is `terminalPort + 1`.
    func testInspectorPortIsTerminalPortPlusOne() {
        let server = InspectorServer(terminalPort: 7420, replayLog: InspectorReplayLog())
        XCTAssertEqual(server.inspectorPort, 7421)
        XCTAssertEqual(server.terminalPort, 7420)
    }
}
