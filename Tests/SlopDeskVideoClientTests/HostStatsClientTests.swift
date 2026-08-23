import XCTest
@testable import SlopDeskVideoClient
@testable import SlopDeskVideoProtocol

/// Client-side fold of the `hostStats` control message (type 27, stats HUD): the pure state
/// machine emits `.applyHostStats` only while streaming (a stray/late reading must never touch a
/// torn-down pane), and the decode-wall EWMA the session pairs it with folds pure (first sample
/// seeds whole, later samples fold at the pacer alpha).
final class HostStatsClientTests: XCTestCase {
    // MARK: Session-logic fold

    private func streamingSM() -> VideoClientStateMachine {
        var sm = VideoClientStateMachine(requestedWindowID: 7, viewport: VideoSize(width: 800, height: 600))
        _ = sm.start()
        _ = sm.handleControl(.helloAck(
            accepted: true,
            streamID: 1,
            captureWidth: 800,
            captureHeight: 600,
            windowBoundsCG: VideoRect(x: 0, y: 0, width: 800, height: 600),
            fullRange: false,
        ))
        return sm
    }

    func testHostStatsWhileStreamingEmitsApplyEffect() {
        var sm = streamingSM()
        XCTAssertEqual(
            sm.handleControl(.hostStats(rttTenthsMillis: 123, encodeTenthsMillis: 45)),
            [.applyHostStats(rttTenthsMillis: 123, encodeTenthsMillis: 45)],
        )
        // Zeros flow — 0 means "no reading yet", which the model maps to a dash (never a fake 0.0).
        XCTAssertEqual(
            sm.handleControl(.hostStats(rttTenthsMillis: 0, encodeTenthsMillis: 0)),
            [.applyHostStats(rttTenthsMillis: 0, encodeTenthsMillis: 0)],
        )
    }

    func testHostStatsIgnoredWhenNotStreaming() {
        var idle = VideoClientStateMachine(requestedWindowID: 7, viewport: VideoSize(width: 800, height: 600))
        XCTAssertEqual(idle.handleControl(.hostStats(rttTenthsMillis: 1, encodeTenthsMillis: 1)), [], "idle ⇒ inert")

        var connecting = VideoClientStateMachine(requestedWindowID: 7, viewport: VideoSize(width: 800, height: 600))
        _ = connecting.start()
        XCTAssertEqual(
            connecting.handleControl(.hostStats(rttTenthsMillis: 1, encodeTenthsMillis: 1)), [],
            "connecting ⇒ inert",
        )

        var stopped = streamingSM()
        _ = stopped.stop()
        XCTAssertEqual(
            stopped.handleControl(.hostStats(rttTenthsMillis: 1, encodeTenthsMillis: 1)), [],
            "stopped ⇒ a stray/late reading is inert",
        )
    }

    // The decode-wall EWMA moved with the decoder: `slopdesk_video::decoder_state` folds it, and its
    // own tests cover the seed, the weight and the convergence this pair used to.
}
