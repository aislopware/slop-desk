import AislopdeskProtocol
import XCTest
@testable import AislopdeskTransport

/// The headless E2E for the TCP mux: two ``MuxSubChannel``s riding ONE shared ``MuxNWConnection``
/// (client) talking to a host ``MuxNWConnection`` over a pair of IN-MEMORY links — NO socket, NO
/// `HostServer`, NO PTY. Proves the headline property the whole feature turns on: interleaved
/// frames from two channels on one connection demux onto the CORRECT per-channel inbound streams,
/// and that channelOpen / Ack / Close lifecycle works.
final class MuxLoopbackTests: XCTestCase {
    /// Wires a client + host shared connection over in-memory CONTROL + DATA links, with the host
    /// auto-accepting + echoing every peer-opened channel. Returns both ends. Per-channel credit
    /// flow control is always on (DATA armed, CONTROL infinite).
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
                        // Credit-at-consumption: the consumer reports what it processed,
                        // or the peer's sender parks after one window.
                        await open.data.noteConsumed(message.wireByteCount)
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
    private static func collect(
        _ channel: MuxSubChannel,
        count: Int,
        timeout: Duration = .seconds(2),
    ) async -> [WireMessage] {
        await withTaskGroup(of: [WireMessage]?.self) { group in
            group.addTask {
                var out: [WireMessage] = []
                do {
                    for try await message in channel.inbound {
                        out.append(message)
                        // Credit-at-consumption (every data-sub-channel consumer must).
                        await channel.noteConsumed(message.wireByteCount)
                        if out.count >= count { break }
                    }
                } catch { /* finished */ }
                return out
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil // timeout sentinel
            }
            // `group.next()` is `[WireMessage]??`; the `?? nil` flattens the double-optional.
            // swiftlint:disable:next redundant_nil_coalescing
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
        guard case let .output(_, aBytes) = aMessages.first
        else { XCTFail("A: expected output, got \(aMessages)")
            return
        }
        guard case let .output(_, bBytes) = bMessages.first
        else { XCTFail("B: expected output, got \(bMessages)")
            return
        }
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
        XCTAssertEqual(
            received,
            Array(0..<n),
            "frames must arrive in EXACT send order (per-channel order = wire order)",
        )
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
        actor Closed { var ids: [UInt32] = []
            func add(_ id: UInt32) { ids.append(id) }
        }
        let closed = Closed()
        await host.setHostOpenHandler { _ in } // accept opens (no echo needed here)
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
        XCTAssertEqual(
            firedIDs,
            [chA.data.channelID],
            "host close hook must fire exactly once, for the closed channel only (not the live sibling B)",
        )
        XCTAssertNotEqual(chA.data.channelID, chB.data.channelID)
    }

    // MARK: - Per-channel credit flow control (always on)

    /// HEADLINE S2 PROPERTY: a channel flooding the shared connection does NOT starve a sibling
    /// channel's small "keystroke", AND ordering within the flooded channel is preserved, AND the
    /// closed credit loop (receiver emits windowAdjust → sender's suspended window wakes) keeps the
    /// flood flowing rather than deadlocking.
    ///
    /// Headless: a real client + host `MuxNWConnection` over in-memory links with flow control ON.
    /// The host echoes each input back as output on the SAME channel. Channel A floods MANY frames
    /// (far exceeding the 256 KiB window, so A's sender MUST suspend on the window and only proceed
    /// as the host's windowAdjusts grant credit); channel B sends ONE small keystroke. We assert B's
    /// echo arrives promptly (no starvation) AND every one of A's frames arrives in EXACT send order.
    func testFloodDoesNotStarveSiblingAndPreservesOrder() async throws {
        let (client, _) = await makeLoopback()
        let chA = try await client.openChannel(sessionID: UUID(), lastReceivedSeq: 0)
        let chB = try await client.openChannel(sessionID: UUID(), lastReceivedSeq: 0)

        // A floods enough total bytes to overflow the 256 KiB window several times over, forcing the
        // suspend/grant credit cycle. Each frame's payload encodes its index so we can verify order.
        let floodCount = 80
        let chunk = String(repeating: "x", count: 8 * 1024) // 8 KiB/frame ⇒ ~640 KiB total ≫ window
        async let aOut = Self.collect(chA.data, count: floodCount, timeout: .seconds(10))
        async let bOut = Self.collect(chB.data, count: 1, timeout: .seconds(10))
        try await Task.sleep(for: .milliseconds(50)) // host registers + acks both opens

        // Launch A's flood as a detached task so B's single keystroke can interleave even while A's
        // sender is parked on its window — the anti-starvation property.
        let flood = Task {
            for i in 0..<floodCount {
                try? await chA.data.send(.input(Data("\(i):\(chunk)".utf8)))
            }
        }
        // B's keystroke: must get its echo back promptly even though A is mid-flood.
        try await chB.data.send(.input(Data("B-keystroke".utf8)))

        let bMessages = await bOut
        XCTAssertEqual(bMessages.count, 1, "sibling B's keystroke echo must arrive despite A's flood (no starvation)")
        guard case let .output(_, bBytes) = bMessages.first
        else { XCTFail("B: expected output, got \(bMessages)")
            return
        }
        XCTAssertEqual(bBytes, Data("B-keystroke".utf8), "B must receive ONLY its own bytes")

        let aMessages = await aOut
        _ = await flood.value
        XCTAssertEqual(
            aMessages.count,
            floodCount,
            "all of A's flooded frames must arrive (credit loop keeps it flowing, no deadlock)",
        )
        let indices = aMessages.compactMap { msg -> Int? in
            guard case let .output(_, bytes) = msg, let s = String(data: bytes, encoding: .utf8),
                  let colon = s.firstIndex(of: ":") else { return nil }
            return Int(s[s.startIndex..<colon])
        }
        XCTAssertEqual(indices, Array(0..<floodCount), "flooded frames must arrive in EXACT send order")
    }

    /// A received `windowAdjust` must WAKE a sender suspended on an exhausted window. Here we drive
    /// the receipt end-to-end: the client floods until its send window is exhausted (the host does
    /// NOT echo, so no organic grant), then we inject a windowAdjust from the host side and confirm
    /// the previously-stuck flood completes.
    func testReceivedWindowAdjustWakesSuspendedSender() async throws {
        let (clientControl, hostControl) = InMemoryMuxLink.pair()
        let (clientData, hostData) = InMemoryMuxLink.pair()
        let client = MuxNWConnection(role: .client, controlLink: clientControl, dataLink: clientData)
        let host = MuxNWConnection(role: .host, controlLink: hostControl, dataLink: hostData)
        // Host accepts opens but NEVER reads/echoes — so the only credit the client can ever get is
        // the explicit windowAdjust we inject below.
        await host.setHostOpenHandler { open in Task { await host.sendOpenAck(open.channelID, accepted: true) } }
        await client.start()
        await host.start()

        let ch = try await client.openChannel(sessionID: UUID(), lastReceivedSeq: 0)
        try await Task.sleep(for: .milliseconds(50))

        // Flood > 256 KiB so the client's send window is guaranteed to exhaust and the task parks.
        let done = expectation(description: "flood completes after the injected grant")
        let bigFrame = Data(repeating: 0x79, count: 64 * 1024) // 64 KiB
        let flood = Task {
            for _ in 0..<8 { try? await ch.data.send(.input(bigFrame)) } // 512 KiB ≫ 256 KiB window
            done.fulfill()
        }
        try await Task.sleep(for: .milliseconds(200))
        // The flood must still be parked (window exhausted) — fulfilling would mean no backpressure.
        // We cannot assert "not fulfilled" directly; instead we inject grants and assert completion.
        // Inject generous windowAdjust grants from the host onto the client's DATA link.
        for _ in 0..<8 {
            await host.grantWindowForTest(channelID: ch.data.channelID, bytesToAdd: 64 * 1024)
            try await Task.sleep(for: .milliseconds(10))
        }
        await fulfillment(of: [done], timeout: 5)
        _ = await flood.value
    }

    // MARK: - FIX #2: windowAdjust grant rides the CONTROL link, not the flooded DATA link

    /// FIX #2 (bidirectional-flood deadlock): the receiver must NOT emit its windowAdjust grant on
    /// the DATA link — under a sustained flood that link is congested, so emitting the grant there
    /// INLINE on the DATA receive loop blocks the only task draining inbound DATA on a write that
    /// cannot complete; the peer is symmetrically stuck → credit deadlock. The grant must ride the
    /// (fast-draining, flow-OFF) CONTROL link instead.
    ///
    /// We prove the property STRUCTURALLY (and WITHOUT risking a deadlock-hang in the test process):
    /// a ``RecordingMuxLink`` spy wraps BOTH the host's CONTROL and DATA links and classifies every
    /// frame written, counting `windowAdjust` frames per link. A client floods > 256 KiB on one
    /// channel so the host's ``ReceiveWindowAccountant`` crosses the half-window threshold and emits
    /// grants. We assert: at least one `windowAdjust` was written on the CONTROL link, and ZERO on
    /// the DATA link — i.e. the grant rides CONTROL (FIX #2), so it can never be starved behind a
    /// flooded DATA link. (The under-the-hood non-blocking ``InMemoryMuxLink`` keeps the test bounded
    /// — it can never deadlock — while the spy gives the exact per-link routing assertion the
    /// blocking-link deadlock repro only shows indirectly.)
    func testWindowAdjustGrantRidesControlLinkNotDataLink() async throws {
        let (clientControl, hostControlRaw) = InMemoryMuxLink.pair()
        let (clientData, hostDataRaw) = InMemoryMuxLink.pair()
        let hostControl = RecordingMuxLink(wrapping: hostControlRaw)
        let hostData = RecordingMuxLink(wrapping: hostDataRaw)
        let client = MuxNWConnection(role: .client, controlLink: clientControl, dataLink: clientData)
        let host = MuxNWConnection(role: .host, controlLink: hostControl, dataLink: hostData)
        // Host: ack the open and DRAIN + CONSUME the inbound flood (no echo) — reported
        // consumption (noteConsumed) is what makes the host's accountant cross the
        // half-window threshold and EMIT windowAdjust grants, which the spy records.
        await host.setHostOpenHandler { open in
            Task {
                await host.sendOpenAck(open.channelID, accepted: true)
                do {
                    for try await message in open.data.inbound {
                        await open.data.noteConsumed(message.wireByteCount)
                    }
                } catch {}
            }
        }
        await client.start()
        await host.start()

        let ch = try await client.openChannel(sessionID: UUID(), lastReceivedSeq: 0)
        try await Task.sleep(for: .milliseconds(80)) // host registers + acks the open

        // Flood several windows' worth so the host crosses the threshold (multiple times) and grants.
        let chunk = Data(repeating: 0x79, count: 8 * 1024) // 8 KiB/frame
        for _ in 0..<64 { try await ch.data.send(.input(chunk)) } // ~512 KiB ⇒ several grants
        // Give the host receive loop time to drain + emit its grants on the CONTROL link.
        try await Task.sleep(for: .milliseconds(200))

        let controlGrants = hostControl.windowAdjustCount
        let dataGrants = hostData.windowAdjustCount
        XCTAssertGreaterThan(
            controlGrants,
            0,
            "the host must emit windowAdjust grants on the CONTROL link (FIX #2)",
        )
        XCTAssertEqual(
            dataGrants,
            0,
            "NO windowAdjust may be emitted on the flooded DATA link (would deadlock under a bidirectional flood)",
        )
    }

    /// FIX #2 blocking-link variant: drive the flood over BLOCKING links (``BlockingMuxLink``) whose
    /// DATA-link `send` actually backpressures (suspends) — the real shape the deadlock arises in,
    /// which the non-blocking ``InMemoryMuxLink`` cannot exhibit. The host's outbound DATA direction
    /// is GATED SHUT, so the only way its windowAdjust grants can reach the client (and replenish the
    /// client's exhausted send window so the flood can complete) is via the CONTROL link (FIX #2). We
    /// assert the flood COMPLETES — but bound the wait with a racing timeout sentinel that ALWAYS
    /// returns, so a regression (grant on the gated DATA link) FAILS the assertion rather than hanging
    /// the test process.
    func testBlockingLinkFloodCompletesWhenGrantRidesControl() async throws {
        let (clientControl, hostControl) = BlockingMuxLink.pair(capacity: 64) // CONTROL: open, fast
        let (clientData, hostData) = BlockingMuxLink.pair(capacity: 8) // DATA: client→host open
        let client = MuxNWConnection(role: .client, controlLink: clientControl, dataLink: clientData)
        let host = MuxNWConnection(role: .host, controlLink: hostControl, dataLink: hostData)
        await host.setHostOpenHandler { open in
            Task {
                await host.sendOpenAck(open.channelID, accepted: true)
                do {
                    for try await message in open.data.inbound {
                        await open.data.noteConsumed(message.wireByteCount)
                    }
                } catch {}
            }
        }
        await client.start()
        await host.start()

        let ch = try await client.openChannel(sessionID: UUID(), lastReceivedSeq: 0)
        try await Task.sleep(for: .milliseconds(80)) // host registers + acks the open (on DATA)
        // Shut the host's outbound DATA: a grant emitted there would park forever; on CONTROL it flows.
        // (With pipelined data sends the gate no longer parks the enqueue itself, but the grant-routing
        // assertion is unchanged: only grants arriving via CONTROL can replenish the client's window.)
        hostData.setOutboundGateClosed(true)

        let chunk = Data(repeating: 0x79, count: 8 * 1024) // 8 KiB/frame ⇒ ~512 KiB ≫ 256 KiB window
        // Run the flood in a DETACHED task whose completion flips a flag, and POLL for that flag with
        // a bounded budget. We never `await` the flood task's value, so even a regression (grant on
        // the gated DATA link → flood parks forever in a non-cancellable continuation) FAILS the
        // assertion at the budget instead of hanging the test process.
        let completedFlag = BoolFlagBox(false)
        let flood = Task {
            for _ in 0..<64 { try? await ch.data.send(.input(chunk)) }
            completedFlag.set(true)
        }
        var completed = false
        for _ in 0..<120 { // up to ~6 s
            try await Task.sleep(for: .milliseconds(50))
            if completedFlag.get() { completed = true
                break
            }
        }
        flood.cancel() // best-effort; a parked send is not cancellable, but we never await it.
        XCTAssertTrue(
            completed,
            "the flood must complete — host grants reached the client via CONTROL despite the gated DATA link (FIX #2)",
        )
    }
}

/// A tiny thread-safe boolean box for the detached-flood completion poll (avoids awaiting a possibly-
/// parked task) — a plain `NSLock`-guarded flag.
private final class BoolFlagBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool
    init(_ initial: Bool) { value = initial }
    func get() -> Bool { lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ v: Bool) { lock.lock()
        value = v
        lock.unlock()
    }
}
