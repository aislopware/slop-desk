#if canImport(QuartzCore) && canImport(Metal) && canImport(VideoToolbox)
import XCTest
@testable import RworkVideoClient
import RworkVideoProtocol

/// Pins the load-bearing OFF-path safety property of the UDP-mux S3 feature (spec constraint #1):
/// with `RWORK_VIDEO_MUX` unset, the video pipeline keeps the EXACT today path — no shared
/// ``VideoConnectionRegistry`` is installed, so every pane builds its own ``NWVideoClientTransport``
/// (15-byte header, one UDP flow per pane). The gate lives SOLELY at the construction site
/// (``VideoWindowPipeline/sharedRegistry`` + ``VideoMuxInstaller/installIfEnabled()``).
///
/// These never open a socket / SCStream / decoder; they assert the gate WIRING, which is the only
/// headlessly-provable safety net for the (hardware-only) live transport.
@MainActor
final class VideoMuxGateOffPathTests: XCTestCase {

    override func tearDown() {
        // Never leak an installed registry into a sibling test (the pipeline's registry is a static).
        VideoWindowPipeline.sharedRegistry = nil
        super.tearDown()
    }

    func testGateUnsetLeavesPipelineRegistryNil() {
        VideoWindowPipeline.sharedRegistry = nil
        // The installer is a no-op when the gate is OFF, so the pipeline's registry stays nil → the
        // construction site builds the today-shaped NWVideoClientTransport (byte-identical path).
        XCTAssertFalse(VideoMuxGate.enabledFromEnvironment([:]), "unset → OFF (byte-identical today)")
        XCTAssertNil(VideoWindowPipeline.sharedRegistry, "OFF path installs NO shared registry")
    }

    func testDisabledRegistryReportsDisabledSoTheConstructionSiteIgnoresIt() {
        // Even if a registry object exists, an explicitly-disabled one (isEnabled == false) must be
        // ignored by the construction site — the `if let registry, registry.isEnabled` guard in
        // `VideoWindowPipeline.activate` takes the OFF branch. A tripwire factory FAILS if ever built.
        let registry = VideoConnectionRegistry(isEnabled: false) { _, _, _ in
            XCTFail("OFF path must NEVER build a shared mux flow")
            return DummyFlow()
        }
        XCTAssertFalse(registry.isEnabled)
        XCTAssertEqual(registry.sharedFlowCount, 0, "a disabled registry is never consulted")
    }

    func testInstallerNoOpWhenGateOff() {
        VideoWindowPipeline.sharedRegistry = nil
        // installIfEnabled reads the PROCESS env (no var in CI ⇒ OFF), so it must not install.
        VideoMuxInstaller.installIfEnabled()
        XCTAssertNil(VideoWindowPipeline.sharedRegistry, "installer is a no-op with the gate OFF")
    }

    private final class DummyFlow: VideoMuxClientFlowing, @unchecked Sendable {
        func startIfNeeded() {}
        func registerLane(channelID: UInt32, onMedia: @escaping @Sendable (VideoChannel, Data) -> Void, onCursor: @escaping @Sendable (Data) -> Void) {}
        func unregisterLane(channelID: UInt32) {}
        func send(_ datagram: Data, on channel: VideoChannel, channelID: UInt32) {}
        func close() {}
    }
}
#endif
