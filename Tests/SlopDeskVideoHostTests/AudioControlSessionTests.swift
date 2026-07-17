import SlopDeskVideoProtocol
import XCTest
@testable import SlopDeskVideoHost

/// PURE logic for the client's `audioControl` (wire type 26): the host state machine must
/// route the wish to the actor's audio gate as an `.applyAudioControl` effect ONLY while
/// streaming — the exact `streamSettings` gating twin. No live SCStream / AudioConverter /
/// socket is touched (hang-safety rule): the actuator wiring (the send gate + encoder) is
/// HW-gated, so the effect layer is the headlessly-verifiable seam, exactly like
/// ``UserStreamSettingsTests``.
final class AudioControlSessionTests: XCTestCase {
    private let bounds = VideoRect(x: 0, y: 0, width: 800, height: 600)
    private let acceptAll: (UInt32, VideoSize) -> (UInt16, UInt16)? = { _, _ in (800, 600) }

    /// A state machine advanced into `.streaming` via an accepted hello.
    private func streamingSM() -> VideoSessionStateMachine {
        var sm = VideoSessionStateMachine()
        _ = sm.start()
        let hello = VideoControlMessage.hello(
            protocolVersion: SlopDeskVideoProtocol.version,
            requestedWindowID: 42,
            viewport: VideoSize(width: 800, height: 600),
        )
        _ = sm.handleControl(hello, windowBoundsCG: bounds, resolveCaptureSize: acceptAll)
        return sm
    }

    func testAudioControlWhileStreamingEmitsApplyEffect() {
        var sm = streamingSM()
        let effects = sm.handleControl(
            .audioControl(enabled: true),
            windowBoundsCG: bounds,
            resolveCaptureSize: acceptAll,
        )
        XCTAssertEqual(
            effects,
            [.applyAudioControl(enabled: true)],
            "a streaming session routes the wish to the actor's audio gate",
        )
        XCTAssertEqual(sm.state, .streaming, "the audio toggle never changes the session lifecycle")
    }

    func testAudioControlWhileListeningIsDropped() {
        var sm = VideoSessionStateMachine()
        _ = sm.start()
        let effects = sm.handleControl(
            .audioControl(enabled: true),
            windowBoundsCG: bounds,
            resolveCaptureSize: acceptAll,
        )
        XCTAssertTrue(effects.isEmpty, "no audio lane to gate pre-stream — the client re-sends after its hello")
    }

    func testSecondAudioControlReplacesTheFirst() {
        // The SM is stateless about the value — each message yields its own apply effect; the
        // ACTOR's single stored bool is what makes the latest wish authoritative.
        var sm = streamingSM()
        _ = sm.handleControl(
            .audioControl(enabled: true),
            windowBoundsCG: bounds, resolveCaptureSize: acceptAll,
        )
        let second = sm.handleControl(
            .audioControl(enabled: false),
            windowBoundsCG: bounds, resolveCaptureSize: acceptAll,
        )
        XCTAssertEqual(second, [.applyAudioControl(enabled: false)], "OFF replaces ON wholesale")
    }
}
