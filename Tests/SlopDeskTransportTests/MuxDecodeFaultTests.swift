import SlopDeskProtocol
import XCTest
@testable import SlopDeskTransport

/// Fail-stop behavior on decode faults, headless (in-memory links, no socket / HostServer):
///
/// - A LINK-LEVEL mux decode fault (bogus length prefix / malformed envelope) must synchronously
///   close BOTH byte links — on the client too, where nothing else proactively closes a socket —
///   so a peer that keeps the connection open cannot keep feeding a wedged decoder.
/// - A PER-CHANNEL inner-framing fault must finish that channel and stop the router from feeding
///   it, while sibling channels on the shared connection keep working; on the host the faulted
///   channel's session is reaped like a peer channelClose (no zombie PTY).
final class MuxDecodeFaultTests: XCTestCase {
    /// A mux frame whose 4-byte length prefix exceeds the cap — `MuxFrameDecoder.nextFrame()`
    /// throws on it without ever advancing past it.
    private func bogusLinkBytes() -> Data {
        var frame = Data()
        let oversized = UInt32(SlopDesk.maxFramePayloadLength + 1)
        frame.append(UInt8((oversized >> 24) & 0xFF))
        frame.append(UInt8((oversized >> 16) & 0xFF))
        frame.append(UInt8((oversized >> 8) & 0xFF))
        frame.append(UInt8(oversized & 0xFF))
        return frame
    }

    /// A `.channelData` envelope whose INNER payload is a bogus WireMessage length prefix — the
    /// per-channel `FrameDecoder` faults on it; the mux envelope itself is well-formed.
    private func corruptChannelData(channelID: UInt32) -> Data {
        MuxEnvelopeCodec.encode(.channelData(channelID: channelID, payload: bogusLinkBytes()))
    }

    // MARK: - Link-level fault → both links closed (client role)

    func testClientDecodeFaultClosesBothByteLinks() async throws {
        let (cc, hc) = InMemoryMuxLink.pair()
        let (cd, hd) = InMemoryMuxLink.pair()
        let client = MuxNWConnection(role: .client, controlLink: cc, dataLink: cd)
        await client.start()

        // Watch the RAW peer ends: when the client closes its links, each peer stream finishes.
        let controlEnded = Flag()
        let dataEnded = Flag()
        Task {
            do { for try await _ in hc.receiveChunks {} } catch {}
            controlEnded.set()
        }
        Task {
            do { for try await _ in hd.receiveChunks {} } catch {}
            dataEnded.set()
        }

        // One bogus length prefix on the DATA link: the mux decoder faults; the client must
        // close BOTH sockets at the fault, not just mark itself dead.
        hd.sendPipelined(bogusLinkBytes())

        try await pollUntil { await client.isDead }
        try await pollUntil { controlEnded.isSet && dataEnded.isSet }
        XCTAssertTrue(controlEnded.isSet, "the CONTROL byte link is closed on a DATA-link decode fault")
        XCTAssertTrue(dataEnded.isSet, "the DATA byte link is closed on its own decode fault")
    }

    // MARK: - Per-channel fault → channel dead, siblings unaffected (client role)

    func testPerChannelDecodeFaultFinishesOnlyThatChannel() async throws {
        let (cc, hc) = InMemoryMuxLink.pair()
        let (cd, hd) = InMemoryMuxLink.pair()
        let client = MuxNWConnection(role: .client, controlLink: cc, dataLink: cd)
        await client.start()
        let (badData, _) = try await client.openChannel(sessionID: UUID(), lastReceivedSeq: 0)
        let (goodData, _) = try await client.openChannel(sessionID: UUID(), lastReceivedSeq: 0)

        let badFaulted = Flag()
        Task {
            do {
                for try await _ in badData.inbound {}
            } catch {
                badFaulted.set() // the fault surfaces to the channel's consumer
            }
        }
        let goodReceived = Flag()
        Task {
            do {
                for try await message in goodData.inbound where message == .output(seq: 1, bytes: Data("ok".utf8)) {
                    goodReceived.set()
                }
            } catch {}
        }

        // Corrupt the FIRST channel's inner framing, twice (the second routed frame is what the
        // router observes against an already-finished target), then deliver clean data on the
        // sibling — it must still arrive: the fault is fatal for one channel, not the mux.
        hd.sendPipelined(corruptChannelData(channelID: badData.channelID))
        hd.sendPipelined(corruptChannelData(channelID: badData.channelID))
        hd.sendPipelined(MuxEnvelopeCodec.encode(.channelData(
            channelID: goodData.channelID,
            payload: WireMessage.output(seq: 1, bytes: Data("ok".utf8)).encode(),
        )))

        try await pollUntil { badFaulted.isSet && goodReceived.isSet }
        XCTAssertTrue(badFaulted.isSet, "the faulted channel's inbound finishes throwing")
        XCTAssertTrue(goodReceived.isSet, "a sibling channel on the shared connection keeps delivering")
        let dead = await client.isDead
        XCTAssertFalse(dead, "a per-channel fault never kills the shared connection")
        _ = (hc, hd)
    }

    // MARK: - Per-channel fault on the host → session reaped like a peer close

    func testHostPerChannelFaultReapsTheSessionViaCloseHandler() async throws {
        let (cc, hc) = InMemoryMuxLink.pair()
        let (cd, hd) = InMemoryMuxLink.pair()
        let host = MuxNWConnection(role: .host, controlLink: hc, dataLink: hd)
        let reaped = IDList()
        await host.setHostOpenHandler { _ in }
        await host.setHostCloseHandler { id in reaped.add(id) }
        await host.start()

        // Peer-initiated open (raw envelope — no client connection needed), then two corrupt
        // channelData frames: the first poisons the per-channel decoder and finishes the
        // sub-channel; the second makes the router observe the finished target and reap.
        let channelID: UInt32 = 1
        cd.sendPipelined(MuxEnvelopeCodec.encode(.channelOpen(
            channelID: channelID, sessionID: UUID(), lastReceivedSeq: 0, channelClass: 0, initialCwd: nil,
        )))
        cd.sendPipelined(corruptChannelData(channelID: channelID))
        cd.sendPipelined(corruptChannelData(channelID: channelID))

        try await pollUntil { reaped.ids.contains(channelID) }
        XCTAssertEqual(reaped.ids, [channelID], "the faulted channel's session is reaped exactly like a peer close")
        let dead = await host.isDead
        XCTAssertFalse(dead, "a per-channel fault never kills the shared connection")
        _ = (cc, hc)
    }

    /// The CONTROL-link twin: a fault in the control sub-channel's inner framing must reap the
    /// whole pair too — the pair anchors ONE session, and the peer (whose control channel is now
    /// finished) will never send the channelClose that would otherwise free the PTY.
    func testHostControlLinkFaultReapsTheSessionViaCloseHandler() async throws {
        let (cc, hc) = InMemoryMuxLink.pair()
        let (cd, hd) = InMemoryMuxLink.pair()
        let host = MuxNWConnection(role: .host, controlLink: hc, dataLink: hd)
        let reaped = IDList()
        await host.setHostOpenHandler { _ in }
        await host.setHostCloseHandler { id in reaped.add(id) }
        await host.start()

        let channelID: UInt32 = 1
        cd.sendPipelined(MuxEnvelopeCodec.encode(.channelOpen(
            channelID: channelID, sessionID: UUID(), lastReceivedSeq: 0, channelClass: 0, initialCwd: nil,
        )))
        cc.sendPipelined(corruptChannelData(channelID: channelID))
        cc.sendPipelined(corruptChannelData(channelID: channelID))

        try await pollUntil { reaped.ids.contains(channelID) }
        XCTAssertEqual(
            reaped.ids,
            [channelID],
            "a control-link fault reaps the DATA sibling + session, not just its own entry",
        )
        let dead = await host.isDead
        XCTAssertFalse(dead, "a per-channel fault never kills the shared connection")
        _ = (cc, hc)
    }

    // MARK: - Helpers

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock()
            value = true
            lock.unlock()
        }

        var isSet: Bool { lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private final class IDList: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [UInt32] = []
        func add(_ id: UInt32) { lock.lock()
            stored.append(id)
            lock.unlock()
        }

        var ids: [UInt32] { lock.lock()
            defer { lock.unlock() }
            return stored
        }
    }

    /// Polls `cond` until true or the timeout elapses (then fails the test).
    private func pollUntil(
        timeout: Duration = .seconds(2),
        _ cond: @Sendable () async -> Bool,
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await cond() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("condition not reached within \(timeout)")
    }
}
