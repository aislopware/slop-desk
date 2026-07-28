import Foundation
import SlopDeskProtocol
import XCTest
@testable import SlopDeskTransport

/// A channel that ended knows WHY: the peer closed it (`channelClose`, with the reason it gave) or
/// the link went away.
///
/// Everything above the mux keys the difference to decide whether the end is recoverable — a link
/// drop is the reconnect campaign's job, a per-channel close is the host stating that this
/// attachment is over. And the two host closes are opposites: a REAPED pane must never be dialled
/// again (re-opening its session id is a spawn), while an EVICTED subscriber's pane is still there
/// to reattach to. The mux is the only layer that can still tell any of them apart: by the time the
/// merged inbound stream ends, all three look identical.
final class MuxPeerCloseMarkTests: XCTestCase {
    private func makeClient() async -> (
        client: MuxNWConnection,
        peerData: InMemoryMuxLink,
        peerControl: InMemoryMuxLink,
    ) {
        let (peerControl, clientControl) = InMemoryMuxLink.pair()
        let (peerData, clientData) = InMemoryMuxLink.pair()
        let client = MuxNWConnection(role: .client, controlLink: clientControl, dataLink: clientData)
        await client.start()
        return (client, peerData, peerControl)
    }

    /// Polls a condition on a bounded deadline (the receive loop routes asynchronously).
    private func pollUntil(
        _ what: String,
        _ condition: @Sendable () async -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line,
    ) async {
        for _ in 0..<200 {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("timed out waiting for \(what)", file: file, line: line)
    }

    /// The signal itself: a peer `channelClose` marks the sub-channel it retired.
    func testPeerChannelCloseMarksTheSubChannel() async throws {
        let (client, peerData, _) = await makeClient()
        let pair = try await client.openChannel(sessionID: UUID(), lastReceivedSeq: 0)
        let data = pair.data
        let live = await data.closedByPeer
        XCTAssertFalse(live, "precondition: a live channel is not retired")

        peerData.send(MuxEnvelopeCodec.encode(.channelClose(channelID: 1)))

        await pollUntil("the peer close to be routed") { data.isFinished }
        let marked = await data.closedByPeer
        XCTAssertTrue(marked, "a `channelClose` is the peer retiring THIS channel, and it says so")
    }

    /// A REFUSED `channelOpenAck` also lands the router on `.closed` and also finishes the
    /// sub-channel — and it is NOT a retirement. It is an answer about an open this side is still
    /// making (`attachedElsewhere` is the shipped one), and the campaign that retries it must keep
    /// running. So the discriminator is the FRAME, never the resulting state.
    func testARefusedOpenAckIsNotAPeerClose() async throws {
        let (client, peerData, _) = await makeClient()
        let pair = try await client.openChannel(sessionID: UUID(), lastReceivedSeq: 0)
        let data = pair.data

        peerData.send(MuxEnvelopeCodec.encode(
            .channelOpenAck(channelID: 1, accepted: false, resumeFromSeq: 0),
        ))

        await pollUntil("the refusal to be routed") { data.isFinished }
        let marked = await data.closedByPeer
        XCTAssertFalse(marked, "a refusal is a verdict on an open, not a channel the host retired")
    }

    /// A link that FAILS under the channel says nothing about it: every channel on that link dies,
    /// and recovering them is exactly what a reconnect campaign is for.
    func testALinkFailureIsNotAPeerClose() async throws {
        let (client, peerData, peerControl) = await makeClient()
        let pair = try await client.openChannel(sessionID: UUID(), lastReceivedSeq: 0)
        let data = pair.data

        peerData.fail()
        peerControl.fail()

        await pollUntil("the link failure to reach the channel") { data.isFinished }
        let marked = await data.closedByPeer
        XCTAssertFalse(marked, "a dead link implicates no particular channel")
        _ = client
    }

    /// The property the client actually reads, end to end: one peer `channelClose` and the pane
    /// transport reports the host retired its channel.
    func testClientTransportReportsAHostClosedChannel() async throws {
        let (client, peerData, _) = await makeClient()
        let transport = MuxClientTransport(
            acquire: { _, _, sessionID, lastReceivedSeq, channelClass, _ in
                let pair = try await client.openChannel(
                    sessionID: sessionID,
                    lastReceivedSeq: lastReceivedSeq,
                    channelClass: channelClass,
                )
                // The client allocator hands out odd ids from 1, and this is its first channel.
                return MuxAcquisition(channelID: 1, data: pair.data, control: pair.control)
            },
            release: { _, _, _ in },
        )
        try await transport.connect(
            host: "h", port: 1, resume: WireMessage.newSessionID,
            lastReceivedSeq: 0, handshakeTimeout: .seconds(1),
        )
        let before = await transport.hostCloseReason
        XCTAssertNil(before, "precondition: a live channel is not closed")

        peerData.send(MuxEnvelopeCodec.encode(.channelClose(channelID: 1)))

        await pollUntil("the transport to see the retirement") { await transport.hostCloseReason != nil }
        let reason = await transport.hostCloseReason
        XCTAssertEqual(reason, .retired, "a close with no stated reason is a retirement")
    }

    // MARK: - The two host closes, told apart

    /// The eviction close carries its reason all the way to the seam the client reads. Without this
    /// the laggard eviction and the document's reap arrive as the same fact, and the client's
    /// "never dial this pane again" latch — correct for a reaped pane — strands an evicted
    /// subscriber on a pane that is still there, for the process lifetime.
    func testAnEvictionCloseIsDistinguishableFromARetirement() async throws {
        let (client, peerData, _) = await makeClient()
        let pair = try await client.openChannel(sessionID: UUID(), lastReceivedSeq: 0)
        let data = pair.data

        peerData.send(MuxEnvelopeCodec.encode(
            .channelClose(channelID: 1, reason: .subscriberEvicted),
        ))

        await pollUntil("the eviction close to be routed") { data.isFinished }
        let reason = await data.peerCloseReason
        XCTAssertEqual(reason, .subscriberEvicted, "the host said WHY, and the mux is where that survives")
        let marked = await data.closedByPeer
        XCTAssertTrue(marked, "an eviction is still a peer close — the channel is gone either way")
    }

    /// `closeChannel` is the host's ONLY close path and both of its callers reach it, so the reason
    /// it is handed is the reason the far end learns. Driven host connection → real encode → link →
    /// client router → sub-channel, so nothing between the eviction seam and the client's read can
    /// silently drop it.
    func testCloseChannelCarriesItsReasonToTheOtherEnd() async throws {
        let (clientControl, hostControl) = InMemoryMuxLink.pair()
        let (clientData, hostData) = InMemoryMuxLink.pair()
        let client = MuxNWConnection(role: .client, controlLink: clientControl, dataLink: clientData)
        let host = MuxNWConnection(role: .host, controlLink: hostControl, dataLink: hostData)
        await host.setHostOpenHandler { open in
            Task { await host.sendOpenAck(open.channelID, accepted: true) }
        }
        await client.start()
        await host.start()
        let pair = try await client.openChannel(sessionID: UUID(), lastReceivedSeq: 0)
        let data = pair.data

        await host.closeChannel(data.channelID, reason: .subscriberEvicted)

        await pollUntil("the close to reach the client") { data.isFinished }
        let reason = await data.peerCloseReason
        XCTAssertEqual(reason, .subscriberEvicted, "the eviction reason survives the whole path")
    }
}
