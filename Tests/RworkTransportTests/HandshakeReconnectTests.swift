import XCTest
import Network
import RworkProtocol
@testable import RworkTransport

/// Full-stack handshake + reconnect-resume tests over real loopback `NWConnection`s.
final class HandshakeReconnectTests: XCTestCase {

    /// Starts a ``HostTransport`` on 127.0.0.1:0 and returns it plus the bound port.
    private func startHost() async throws -> (host: HostTransport, port: UInt16) {
        let host = HostTransport()
        try await host.start(port: 0)
        let boundPort = await host.boundPort
        let port = try XCTUnwrap(boundPort, "host must report its ephemeral port")
        XCTAssertNotEqual(port, 0)
        return (host, port)
    }

    /// Awaits the next NEW session the host publishes, with a bounded timeout.
    private func nextSession(_ host: HostTransport, timeout: Duration = .seconds(5)) async throws -> HostSessionTransport {
        try await withThrowingTaskGroup(of: HostSessionTransport.self) { group in
            group.addTask {
                for await session in host.sessions_ { return session }
                throw RworkTransportError.timedOut("no session published")
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw RworkTransportError.timedOut("session wait")
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    /// Reads the next message of the client's merged inbound stream, bounded.
    private func nextInbound(_ client: ClientTransport, timeout: Duration = .seconds(5)) async throws -> WireMessage {
        try await withThrowingTaskGroup(of: WireMessage.self) { group in
            group.addTask {
                for try await message in client.inbound { return message }
                throw RworkTransportError.timedOut("client inbound ended")
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw RworkTransportError.timedOut("inbound wait")
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    // MARK: NEW session handshake

    func testNewSessionHandshakeReturnsFreshIDAndNotReturning() async throws {
        let (host, port) = try await startHost()
        defer { Task { await host.stop() } }

        let client = ClientTransport()
        try await client.connect(host: "127.0.0.1", port: port) // default = newSessionID, lastReceivedSeq 0

        // Host minted a NEW session and published it.
        let session = try await nextSession(host)

        let clientSessionID = await client.sessionID
        let id = try XCTUnwrap(clientSessionID)
        let returning = await client.returningClient
        let resumeFromSeq = await client.resumeFromSeq
        XCTAssertNotEqual(id, WireMessage.newSessionID, "host must mint a fresh non-zero sessionID")
        XCTAssertEqual(id, session.sessionID, "client's authoritative id must match the host session")
        XCTAssertFalse(returning, "a zero-id hello is NOT a returning client")
        XCTAssertEqual(resumeFromSeq, 0)

        await client.close()
    }

    // MARK: Basic end-to-end output/input round-trip

    func testOutputAndInputRoundTrip() async throws {
        let (host, port) = try await startHost()
        defer { Task { await host.stop() } }

        let client = ClientTransport()
        try await client.connect(host: "127.0.0.1", port: port)
        let session = try await nextSession(host)

        // Host → client output.
        let seq = try await session.sendOutput(Data("hello".utf8))
        XCTAssertEqual(seq, 1)
        let inbound = try await nextInbound(client)
        XCTAssertEqual(inbound, .output(seq: 1, bytes: Data("hello".utf8)))

        // Client → host input.
        try await client.sendInput(Data("keys".utf8))
        var got: Data?
        try await withThrowingTaskGroup(of: Data?.self) { group in
            group.addTask { for await bytes in session.inboundInput { return bytes }; return nil }
            group.addTask { try await Task.sleep(for: .seconds(5)); return nil }
            got = try await group.next()!
            group.cancelAll()
        }
        XCTAssertEqual(got, Data("keys".utf8))

        await client.close()
    }

    // MARK: Host receives control inbound (ack/resize) after the hello handoff

    func testHostReceivesAckAndResizeAfterHandshake() async throws {
        let (host, port) = try await startHost()
        defer { Task { await host.stop() } }

        let client = ClientTransport()
        try await client.connect(host: "127.0.0.1", port: port)
        let session = try await nextSession(host)

        // Client → host control messages, sent after the handshake completed. These
        // must reach the session's forwarder (the next consumer after `hello`).
        try await client.sendResize(cols: 120, rows: 40, pxWidth: 1200, pxHeight: 800)
        try await client.sendAck(seq: 0) // benign ack (nothing retained yet) — still delivered.

        var gotResize: WireMessage?
        try await withThrowingTaskGroup(of: WireMessage?.self) { group in
            group.addTask { for await m in session.inboundResize { return m }; return nil }
            group.addTask { try await Task.sleep(for: .seconds(5)); return nil }
            gotResize = try await group.next()!
            group.cancelAll()
        }
        XCTAssertEqual(gotResize, .resize(cols: 120, rows: 40, pxWidth: 1200, pxHeight: 800))

        await client.close()
    }

    // MARK: Reconnect RESUME (the headline test)

    func testReconnectReplaysExactMissingTailInOrder() async throws {
        let (host, port) = try await startHost()
        defer { Task { await host.stop() } }

        // 1. Connect a fresh client.
        let client1 = ClientTransport()
        try await client1.connect(host: "127.0.0.1", port: port)
        let session = try await nextSession(host)
        let client1SessionID = await client1.sessionID
        let sessionID = try XCTUnwrap(client1SessionID)

        // 2. Host sends output seq 1..N.
        let n = 8
        for i in 1...n {
            _ = try await session.sendOutput(Data("line-\(i)\n".utf8))
        }

        // 3. Client receives all N (collect them so we know it got them) and acks up to K.
        let k = 3
        var receivedSeqs: [Int64] = []
        while receivedSeqs.count < n {
            let msg = try await nextInbound(client1)
            if case let .output(seq, _) = msg { receivedSeqs.append(seq) }
        }
        XCTAssertEqual(receivedSeqs, Array(1...Int64(n)))
        try await client1.sendAck(seq: Int64(k))

        // Give the host a beat to process the ack on the control channel.
        try await waitUntil(timeout: .seconds(5)) {
            await session.highestSeq == Int64(n) // host already at N
        }

        // 4. Simulate client drop.
        await client1.close()
        // Let the host observe the channel teardown (client offline).
        try await Task.sleep(for: .milliseconds(200))

        // 5. Reconnect presenting the sessionID + lastReceivedSeq = K.
        let client2 = ClientTransport()
        try await client2.connect(
            host: "127.0.0.1",
            port: port,
            resume: sessionID,
            lastReceivedSeq: Int64(k)
        )
        let client2Returning = await client2.returningClient
        let client2ResumeFrom = await client2.resumeFromSeq
        let client2SessionID = await client2.sessionID
        XCTAssertTrue(client2Returning, "host must recognize the resuming sessionID")
        XCTAssertEqual(client2ResumeFrom, Int64(k))
        XCTAssertEqual(client2SessionID, sessionID)

        // 6. Assert the host replays exactly seq K+1..N, in order, no gap/dup.
        var replayedSeqs: [Int64] = []
        var replayedBytes: [Data] = []
        while replayedSeqs.count < (n - k) {
            let msg = try await nextInbound(client2)
            guard case let .output(seq, bytes) = msg else {
                return XCTFail("expected replayed output, got \(msg)")
            }
            replayedSeqs.append(seq)
            replayedBytes.append(bytes)
        }
        XCTAssertEqual(replayedSeqs, Array(Int64(k + 1)...Int64(n)), "replay tail must be exactly K+1..N in order")
        let expectedBytes = (k + 1...n).map { Data("line-\($0)\n".utf8) }
        XCTAssertEqual(replayedBytes, expectedBytes, "replayed bytes must be byte-exact")

        // 7. Live streaming resumes after replay: a new output gets seq N+1.
        let liveSeq = try await session.sendOutput(Data("after-resume\n".utf8))
        XCTAssertEqual(liveSeq, Int64(n + 1))
        let live = try await nextInbound(client2)
        XCTAssertEqual(live, .output(seq: Int64(n + 1), bytes: Data("after-resume\n".utf8)))

        await client2.close()
    }

    // MARK: Reconnect DEDUP when received > acked (acks lag receipt — the iOS-background case)

    /// The realistic background case: the client *received* all N outputs but its `ack`
    /// only reached K (< N) before the connection dropped (acks lag receipt). On
    /// reconnect a correct client reports its TRUE highest received seq (N), not its
    /// acked seq (K). The host must replay NOTHING — `messages(after: N)` is empty —
    /// so no already-displayed output is duplicated. The very next data-channel message
    /// must be the live seq N+1.
    ///
    /// This guards the dedup-on-reconnect path: it proves the host keys replay off the
    /// client-reported `lastReceivedSeq`, not off `ackedSeq`. (The K-based case above
    /// covers the genuinely-lost-tail scenario where lastReceivedSeq == acked.)
    func testReconnectWithReceivedAboveAckedReplaysNothing() async throws {
        let (host, port) = try await startHost()
        defer { Task { await host.stop() } }

        // 1. Connect a fresh client.
        let client1 = ClientTransport()
        try await client1.connect(host: "127.0.0.1", port: port)
        let session = try await nextSession(host)
        let client1SessionID = await client1.sessionID
        let sessionID = try XCTUnwrap(client1SessionID)

        // 2. Host sends output seq 1..N.
        let n = 8
        for i in 1...n {
            _ = try await session.sendOutput(Data("line-\(i)\n".utf8))
        }

        // 3. Client RECEIVES all N (tracks true highest received = N) but only ACKS K < N
        //    (the ack lagged receipt — exactly what happens when iOS suspends the app
        //    right after delivery but before the ack round-trips).
        let k = 3
        var highestReceived: Int64 = 0
        while highestReceived < Int64(n) {
            let msg = try await nextInbound(client1)
            if case let .output(seq, _) = msg { highestReceived = max(highestReceived, seq) }
        }
        XCTAssertEqual(highestReceived, Int64(n), "client received the full 1..N stream")
        try await client1.sendAck(seq: Int64(k)) // ack only reached K

        // Host has produced all N; the ack only released up to K (so 4..N are retained).
        try await waitUntil(timeout: .seconds(5)) { await session.highestSeq == Int64(n) }

        // 4. Client drops.
        await client1.close()
        try await Task.sleep(for: .milliseconds(200))

        // 5. Reconnect reporting the TRUE highest received seq = N (NOT the acked K).
        let client2 = ClientTransport()
        try await client2.connect(
            host: "127.0.0.1",
            port: port,
            resume: sessionID,
            lastReceivedSeq: highestReceived // == N
        )
        let client2Returning = await client2.returningClient
        let client2ResumeFrom = await client2.resumeFromSeq
        let client2SessionID = await client2.sessionID
        XCTAssertTrue(client2Returning, "host must recognize the resuming sessionID")
        XCTAssertEqual(client2ResumeFrom, Int64(n))
        XCTAssertEqual(client2SessionID, sessionID)

        // 6. The host must replay NOTHING: messages(after: N) is empty, so no retained
        //    (un-acked but already-received) output is re-sent. Prove it by sending one
        //    live output and asserting the FIRST thing the client sees is the live
        //    seq N+1 — never a duplicate of any seq <= N.
        //
        //    This is the empty-tail case: `after-resume` is the FIRST send on the freshly
        //    associated data channel (no replay loop preceded it to let the channel
        //    settle). On loopback the prior connection's connect/close churn can drive the
        //    new channel to `.cancelled` right after it reaches `.ready` — the production
        //    fix retains the bytes and marks the client offline rather than throwing, but
        //    in this single-shot test we want the live send to actually land, so retry the
        //    first post-resume send until it reaches a genuinely-ready channel.
        let liveSeq = try await sendOutputWhenReady(session, Data("after-resume\n".utf8))
        XCTAssertEqual(liveSeq, Int64(n + 1))

        let first = try await nextInbound(client2)
        guard case let .output(seq, bytes) = first else {
            return XCTFail("expected the live output, got \(first)")
        }
        XCTAssertEqual(seq, Int64(n + 1), "first post-reconnect output must be the live N+1, not a replayed duplicate")
        XCTAssertEqual(bytes, Data("after-resume\n".utf8))

        await client2.close()
    }

    // MARK: Reconnect re-delivers a missed exit marker (no zombie session)

    /// If the child exits while the client is offline, the `exit` marker (which is NOT
    /// sequenced/replayed via the ReplayBuffer) would otherwise be lost: the reconnecting
    /// client replays the final output but never sees the stream terminate — a "zombie
    /// session". The fix records the exit code and re-sends it AFTER the replayed output
    /// tail on resume. This test drives the real reconnect path and asserts the client
    /// receives the replayed tail followed by the exit marker, in that order.
    func testReconnectRedeliversMissedExitAfterTail() async throws {
        let (host, port) = try await startHost()
        defer { Task { await host.stop() } }

        // 1. Connect, capture the session id.
        let client1 = ClientTransport()
        try await client1.connect(host: "127.0.0.1", port: port)
        let session = try await nextSession(host)
        let client1SessionID = await client1.sessionID
        let sessionID = try XCTUnwrap(client1SessionID)

        // 2. Host sends output 1..N, client receives all, acks nothing.
        let n = 4
        for i in 1...n { _ = try await session.sendOutput(Data("out-\(i)\n".utf8)) }
        var received = 0
        while received < n {
            if case .output = try await nextInbound(client1) { received += 1 }
        }

        // 3. Client drops; THEN the child "exits" while offline (host sends exit, which
        //    no-ops on the wire but is recorded for replay).
        await client1.close()
        try await Task.sleep(for: .milliseconds(200))
        try await session.sendExit(code: 143)

        // 4. Reconnect from lastReceivedSeq 0 so the whole tail 1..N replays first.
        let client2 = ClientTransport()
        try await client2.connect(host: "127.0.0.1", port: port, resume: sessionID, lastReceivedSeq: 0)
        let client2Returning = await client2.returningClient
        XCTAssertTrue(client2Returning)

        // 5. Expect output 1..N in order, then the exit marker LAST.
        var seqs: [Int64] = []
        var sawExit: Int32?
        while sawExit == nil {
            switch try await nextInbound(client2) {
            case let .output(seq, _): seqs.append(seq)
            case let .exit(code): sawExit = code
            default: break
            }
        }
        XCTAssertEqual(seqs, Array(1...Int64(n)), "the full tail must replay before the exit marker")
        XCTAssertEqual(sawExit, 143, "the missed exit code must be re-delivered on reconnect")

        await client2.close()
    }

    // MARK: Helpers

    /// Sends one live `output` only once the session's freshly-rebound data channel has
    /// settled at `.ready`, so the empty-tail "first post-resume send" cannot race the
    /// loopback connect/close churn that can drive the new channel to `.cancelled` right
    /// after it reaches `.ready`. Polls readiness before the single send; throws if the
    /// channel never settles (or goes offline) within the bound.
    private func sendOutputWhenReady(
        _ session: HostSessionTransport,
        _ bytes: Data,
        timeout: Duration = .seconds(5)
    ) async throws -> Int64 {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await session.dataChannelState == .ready { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard await session.dataChannelState == .ready else {
            throw RworkTransportError.timedOut("data channel never reached .ready post-resume")
        }
        return try await session.sendOutput(bytes)
    }

    /// Polls `condition` until true or `timeout`, with a small sleep between tries.
    private func waitUntil(timeout: Duration, _ condition: @Sendable () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        if await condition() { return }
        throw RworkTransportError.timedOut("waitUntil condition")
    }
}
