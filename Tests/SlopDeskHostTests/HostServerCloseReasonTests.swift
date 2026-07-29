import Foundation
import XCTest
@testable import SlopDeskHost
@testable import SlopDeskProtocol
@testable import SlopDeskTransport

/// The host's two pane closes say WHICH they are, and they say it on the wire.
///
/// `reapPanesRemovedFromTopology` (the document deleted the pane) and `wireSubscriberEviction` (a
/// laggard removed to protect the session) both end at `MuxNWConnection.closeChannel`, and above the
/// transport they are the same stream ending. They demand opposite answers though: a reaped pane's
/// session id is about to stop existing, so re-opening it is a SPAWN; an evicted subscriber's pane
/// is still running and still in its topology, so the client is looking at something it may
/// reattach to — and if it is not told, it never will.
///
/// Driven over a REAL mux loopback: the assertion is what the far end RECEIVES, so nothing between
/// the eviction seam and the client's read can quietly drop the distinction. Headless — unspawned
/// `PTYProcess` (no PTY, no read loop), server never `start()`ed.
final class HostServerCloseReasonTests: XCTestCase {
    private struct Rig {
        let server: HostServer
        let client: MuxNWConnection
        let host: MuxNWConnection
        let connectionID: UUID
    }

    private func makeRig() async -> Rig {
        let server = HostServer(port: 0, shellPath: "/bin/cat")
        let (clientControl, hostControl) = LoopbackMuxLink.pair()
        let (clientData, hostData) = LoopbackMuxLink.pair()
        let host = MuxNWConnection(role: .host, controlLink: hostControl, dataLink: hostData)
        let client = MuxNWConnection(role: .client, controlLink: clientControl, dataLink: clientData)
        // Accept every open without spawning anything: the pane's session is registered by hand
        // below, so the PTY spawn path stays out of a unit test.
        await host.setHostOpenHandler { open in
            Task { await host.sendOpenAck(open.channelID, accepted: true) }
        }
        await host.start()
        await client.start()
        return Rig(server: server, client: client, host: host, connectionID: host.connectionID)
    }

    private func makeSession(sessionID: UUID) -> MuxChannelSession {
        MuxChannelSession(
            channelID: 1,
            pty: PTYProcess(), // unspawned: no PTY, no read loop
            data: MuxSubChannel(channelID: 1, channel: .data) { _, _ in },
            control: MuxSubChannel(channelID: 1, channel: .control) { _, _ in },
            sessionID: sessionID,
        )
    }

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

    /// The eviction close names itself. Without this the evicted client reads it as "the host
    /// reaped my pane", latches the never-dial-again guard the reap needs, and renders a pane it can
    /// never reattach to — the pane is still in its topology and nothing will ever remove it.
    func testAnEvictedSubscriberIsToldItWasEvicted() async throws {
        let rig = await makeRig()
        defer { Task { await rig.server.stop() } }
        let pane = UUID()
        let pair = try await rig.client.openChannel(sessionID: pane, lastReceivedSeq: 0)
        let session = makeSession(sessionID: pane)
        let key = MuxSessionKey(connectionID: rig.connectionID, channelID: pair.data.channelID)
        rig.server.registerJoinedKeyForTesting(session, key: key)
        rig.server.armSubscriberEvictionForTesting(session, on: rig.host, connectionID: rig.connectionID)

        // What `evictLaggingSubscribers` does once a member is past `SLOPDESK_SUB_LAG_BYTES`.
        let evict = try XCTUnwrap(session.onEvictSubscriber, "the eviction seam is wired")
        evict(1)

        await pollUntil("the eviction to reach the evicted client") { await pair.data.isFinished }
        let reason = await pair.data.peerCloseReason
        XCTAssertEqual(reason, .subscriberEvicted, "the laggard is told its PANE survived it")
    }

    /// …and the document's reap keeps saying the other thing, in the same rig, because the
    /// recovery the eviction reason unlocks must not leak to the close that means the pane is gone.
    func testAReapedPaneIsToldItWasRetired() async throws {
        let rig = await makeRig()
        defer { Task { await rig.server.stop() } }
        let pane = UUID()
        let pair = try await rig.client.openChannel(sessionID: pane, lastReceivedSeq: 0)
        let session = makeSession(sessionID: pane)
        let key = MuxSessionKey(connectionID: rig.connectionID, channelID: pair.data.channelID)
        rig.server.registerMuxSessionForTesting(session, key: key)
        rig.server.armSubscriberEvictionForTesting(session, on: rig.host, connectionID: rig.connectionID)

        rig.server.reapPanesRemovedFromTopologyForTesting([pane])

        await pollUntil("the reap to reach the client") { await pair.data.isFinished }
        let reason = await pair.data.peerCloseReason
        XCTAssertEqual(reason, .retired, "the pane is leaving the layout; its session id is going with it")
    }
}
