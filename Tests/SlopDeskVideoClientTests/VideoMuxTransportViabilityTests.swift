#if canImport(QuartzCore) && canImport(Metal) && canImport(VideoToolbox)
import Foundation
import SlopDeskVideoProtocol
import XCTest
@testable import SlopDeskVideoClient

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
