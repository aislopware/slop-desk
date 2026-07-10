import XCTest
@testable import SlopDeskVideoClient

/// Send-path viability for the shared client UDP flow (wifi-flap hardening): while the media
/// connection reports `.waiting` (dead path — Network.framework would buffer every datagram
/// in-process indefinitely) or is dead, the periodic senders (20 Hz NetworkStats, 5 s
/// keepalive) must skip their fire. Pure mapping — no socket.
final class UDPSendPathPolicyTests: XCTestCase {
    func testWaitingRevokesViability() {
        XCTAssertEqual(
            UDPSendPathPolicy.viability(after: .waiting), false,
            ".waiting is the dead-path state — periodic sends must stop buffering in-process",
        )
    }

    func testFailedAndCancelledRevokeViability() {
        XCTAssertEqual(UDPSendPathPolicy.viability(after: .failed), false)
        XCTAssertEqual(UDPSendPathPolicy.viability(after: .cancelled), false)
    }

    func testReadyRestoresViability() {
        XCTAssertEqual(
            UDPSendPathPolicy.viability(after: .ready), true,
            "path recovery must resume the periodic senders",
        )
    }

    func testBringUpStatesLeaveViabilityUnchanged() {
        // setup/preparing carry no path verdict: initial bring-up keeps the optimistic
        // default, and a waiting→preparing→ready recovery stays non-viable until .ready.
        XCTAssertNil(UDPSendPathPolicy.viability(after: .setup))
        XCTAssertNil(UDPSendPathPolicy.viability(after: .preparing))
    }
}

#if canImport(QuartzCore) && canImport(Metal) && canImport(VideoToolbox)
import SlopDeskVideoProtocol

/// The per-pane transport surfaces the SHARED flow's viability to the session (the seam the
/// periodic-send gate reads), and defaults optimistic before a flow is bound.
final class VideoMuxTransportViabilityTests: XCTestCase {
    /// In-memory ``VideoMuxClientFlowing`` with a settable path verdict — no socket.
    private final class FakeFlow: VideoMuxClientFlowing, @unchecked Sendable {
        private let lock = NSLock()
        private var viable = true
        var isSendPathViable: Bool { lock.withLock { viable } }
        func setViable(_ value: Bool) { lock.withLock { viable = value } }
        func startIfNeeded() {}
        func registerLane(
            channelID _: UInt32,
            onMedia _: @Sendable (VideoChannel, Data) -> Void,
            onCursor _: @Sendable (Data) -> Void,
        ) {}
        func unregisterLane(channelID _: UInt32) {}
        func send(_: Data, on _: VideoChannel, channelID _: UInt32) {}
        func close() {}
    }

    func testTransportMirrorsFlowViabilityAndDefaultsTrue() async {
        let flow = FakeFlow()
        let transport = VideoMuxClientTransport(
            host: "example.invalid",
            mediaPort: 9000,
            cursorPort: 9001,
            acquire: { VideoMuxAcquisition(channelID: 7, flow: flow) },
            release: { _ in },
        )
        // Before start no flow is bound → optimistic (sends are no-ops then anyway).
        XCTAssertTrue(transport.sendPathViable)
        await transport.start(onMedia: { _, _ in }, onCursor: { _ in })
        XCTAssertTrue(transport.sendPathViable)
        flow.setViable(false) // the media conn went .waiting — dead path
        XCTAssertFalse(transport.sendPathViable, "the periodic-send gate must see the dead path")
        flow.setViable(true) // .ready again
        XCTAssertTrue(transport.sendPathViable)
    }
}
#endif
