import XCTest
import RworkProtocol
@testable import RworkTransport

/// The headless E2E for the TCP mux: two ``MuxSubChannel``s riding ONE shared ``MuxNWConnection``
/// (client) talking to a host ``MuxNWConnection`` over a pair of IN-MEMORY links — NO socket, NO
/// `HostServer`, NO PTY. Proves the headline property the whole feature turns on: interleaved
/// frames from two channels on one connection demux onto the CORRECT per-channel inbound streams,
/// and that channelOpen / Ack / Close lifecycle works.
final class MuxLoopbackTests: XCTestCase {

    /// Wires a client + host shared connection over in-memory CONTROL + DATA links, with the host
    /// auto-accepting + echoing every peer-opened channel. Returns both ends.
    private func makeLoopback() async -> (client: MuxNWConnection, host: MuxNWConnection) {
        let (clientControl, hostControl) = InMemoryMuxLink.pair()
        let (clientData, hostData) = InMemoryMuxLink.pair()
        let client = MuxNWConnection(role: .client, controlLink: clientControl, dataLink: clientData)
        let host = MuxNWConnection(role: .host, controlLink: hostControl, dataLink: hostData)
        // Host: on a peer channelOpen, ack it and ECHO every inbound DATA WireMessage straight back
        // on the SAME channel's data sub-channel (so the client can observe per-channel routing).
        await host.setHostOpenHandler { open in
            Task {
                await host.sendOpenAck(open.channelID, accepted: true)
                do {
                    for try await message in open.data.inbound {
                        if case let .input(bytes) = message {
                            // Echo the input back as output on the same channel.
                            try? await open.data.send(.output(seq: 1, bytes: bytes))
                        }
                    }
                } catch { /* channel closed */ }
            }
        }
        await client.start()
        await host.start()
        return (client, host)
    }

    /// Collects up to `count` messages from a sub-channel's inbound, with a bounded timeout so a
    /// missing message fails the test rather than hanging. Free function (no `self`) so it can be
    /// launched in an `async let` under strict concurrency.
    private static func collect(_ channel: MuxSubChannel, count: Int, timeout: Duration = .seconds(2)) async -> [WireMessage] {
        await withTaskGroup(of: [WireMessage]?.self) { group in
            group.addTask {
                var out: [WireMessage] = []
                do {
                    for try await message in channel.inbound {
                        out.append(message)
                        if out.count >= count { break }
                    }
                } catch { /* finished */ }
                return out
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil // timeout sentinel
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? []
        }
    }

    func testTwoChannelsDemuxToCorrectInboundStreams() async throws {
        let (client, _) = await makeLoopback()
        let id = UUID()
        let chA = try await client.openChannel(sessionID: id, lastReceivedSeq: 0)
        let chB = try await client.openChannel(sessionID: id, lastReceivedSeq: 0)
        XCTAssertNotEqual(chA.data.channelID, chB.data.channelID, "two channels must get distinct ids")
        XCTAssertEqual([chA.data.channelID, chB.data.channelID], [1, 3], "client allocates odd ids")

        // Pre-arm the collectors BEFORE sending so no echoed output is missed.
        async let aOut = Self.collect(chA.data, count: 1)
        async let bOut = Self.collect(chB.data, count: 1)
        // Give the host time to register + ack the opens before sending data.
        try await Task.sleep(for: .milliseconds(50))

        // Interleave A,B input — the host echoes each back on its OWN channel.
        try await chA.data.send(.input(Data("A-only".utf8)))
        try await chB.data.send(.input(Data("B-only".utf8)))

        let aMessages = await aOut
        let bMessages = await bOut

        XCTAssertEqual(aMessages.count, 1, "channel A inbound must receive exactly its own echo")
        XCTAssertEqual(bMessages.count, 1, "channel B inbound must receive exactly its own echo")
        guard case let .output(_, aBytes) = aMessages.first else { return XCTFail("A: expected output, got \(aMessages)") }
        guard case let .output(_, bBytes) = bMessages.first else { return XCTFail("B: expected output, got \(bMessages)") }
        XCTAssertEqual(aBytes, Data("A-only".utf8), "channel A must receive ONLY A's bytes (no cross-talk)")
        XCTAssertEqual(bBytes, Data("B-only".utf8), "channel B must receive ONLY B's bytes (no cross-talk)")
    }

    func testSingleChannelFloodPreservesOrder() async throws {
        // REGRESSION GUARD for the per-frame-ordering bug: MuxNWConnection.route must deliver
        // frames to a sub-channel IN WIRE ORDER. The prior code spawned a `Task` per frame, and
        // Swift gives no FIFO guarantee across separately-created Tasks hitting one actor, so a
        // flood on one channel could scramble. We round-trip N ordered frames (each byte-payload
        // encodes its index) through host-receive + echo + client-receive and assert exact order.
        // (testTwoChannelsDemuxToCorrectInboundStreams sends only ONE frame/channel, so it cannot
        // catch reordering — this one can.)
        let (client, _) = await makeLoopback()
        let ch = try await client.openChannel(sessionID: UUID(), lastReceivedSeq: 0)
        let n = 100
        async let out = Self.collect(ch.data, count: n, timeout: .seconds(5))
        try await Task.sleep(for: .milliseconds(50)) // let the host register + ack the open
        for i in 0..<n {
            try await ch.data.send(.input(Data("\(i)".utf8)))
        }
        let messages = await out
        XCTAssertEqual(messages.count, n, "all \(n) flooded frames must arrive")
        let received = messages.compactMap { msg -> Int? in
            guard case let .output(_, bytes) = msg, let s = String(data: bytes, encoding: .utf8) else { return nil }
            return Int(s)
        }
        XCTAssertEqual(received, Array(0..<n), "frames must arrive in EXACT send order (per-channel order = wire order)")
    }

    func testChannelOpenAckAcceptsChannel() async throws {
        // A host that accepts: openChannel succeeds and the channel can carry data.
        let (client, _) = await makeLoopback()
        let ch = try await client.openChannel(sessionID: UUID(), lastReceivedSeq: 0)
        async let out = Self.collect(ch.data, count: 1)
        try await Task.sleep(for: .milliseconds(50))
        try await ch.data.send(.input(Data("ping".utf8)))
        let messages = await out
        XCTAssertEqual(messages.count, 1, "an accepted channel routes data back")
    }

    func testCloseChannelFinishesOnlyThatChannelsInbound() async throws {
        let (client, _) = await makeLoopback()
        let chA = try await client.openChannel(sessionID: UUID(), lastReceivedSeq: 0)
        let chB = try await client.openChannel(sessionID: UUID(), lastReceivedSeq: 0)
        try await Task.sleep(for: .milliseconds(50))

        // Closing A finishes A's inbound; B stays live and still routes its own echo.
        await client.closeChannel(chA.data.channelID)

        // A's inbound is finished → its collector returns promptly with whatever it had (empty).
        let aTask = Task { () -> Int in
            var n = 0
            for try await _ in chA.data.inbound { n += 1 }
            return n
        }
        let aCount = await (try? aTask.value) ?? 0
        XCTAssertEqual(aCount, 0, "closed channel A delivers nothing further")

        // B still works.
        async let bOut = Self.collect(chB.data, count: 1)
        try await Task.sleep(for: .milliseconds(20))
        try await chB.data.send(.input(Data("still-live".utf8)))
        let bMessages = await bOut
        XCTAssertEqual(bMessages.count, 1, "channel B survives channel A's close (shared connection intact)")

        let hasLive = await client.hasLiveChannels
        XCTAssertTrue(hasLive, "B still live → connection must report live channels")
    }

    // MARK: - FIX #2: clean peer channelClose drives the host close hook (PTY/fd teardown)

    /// FIX #2: when the client cleanly closes a channel, the HOST's per-channel close hook must
    /// fire with that channelID, so the host relay can shut its `MuxChannelSession` (close the PTY
    /// + master fd). S1 has NO per-channel reconnect/resume, so a cleanly-closed channel's shell
    /// must NOT be kept alive — without this hook, every cleanly-closed pane leaked its shell.
    ///
    /// Headless: drives a real host + client `MuxNWConnection` over in-memory links (no socket, no
    /// PTY). The hook stands in for `HostServer.removeMuxSession`; here we assert it fires exactly
    /// once with the right id, and that an UNCLOSED sibling channel does NOT trip it.
    func testCleanChannelCloseFiresHostCloseHook() async throws {
        let (clientControl, hostControl) = InMemoryMuxLink.pair()
        let (clientData, hostData) = InMemoryMuxLink.pair()
        let client = MuxNWConnection(role: .client, controlLink: clientControl, dataLink: clientData)
        let host = MuxNWConnection(role: .host, controlLink: hostControl, dataLink: hostData)

        // Collect every channelID the host close hook is invoked for (the production wiring maps
        // this to removeMuxSession → MuxChannelSession.shutdown()).
        actor Closed { var ids: [UInt32] = []; func add(_ id: UInt32) { ids.append(id) } }
        let closed = Closed()
        await host.setHostOpenHandler { _ in }            // accept opens (no echo needed here)
        await host.setHostCloseHandler { id in Task { await closed.add(id) } }
        await client.start()
        await host.start()

        let chA = try await client.openChannel(sessionID: UUID(), lastReceivedSeq: 0)
        let chB = try await client.openChannel(sessionID: UUID(), lastReceivedSeq: 0)
        try await Task.sleep(for: .milliseconds(50)) // host registers both opens

        // Cleanly close ONLY channel A.
        await client.closeChannel(chA.data.channelID)
        try await Task.sleep(for: .milliseconds(50)) // let the close frame route on the host

        let firedIDs = await closed.ids
        XCTAssertEqual(firedIDs, [chA.data.channelID],
                       "host close hook must fire exactly once, for the closed channel only (not the live sibling B)")
        XCTAssertNotEqual(chA.data.channelID, chB.data.channelID)
    }
}
