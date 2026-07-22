import SlopDeskVideoProtocol
import XCTest
@testable import SlopDeskVideoHost

/// PURE logic for the client's `privacyMode` (wire type 28): the host state machine routes the wish
/// to the actor's ``HostPrivacyBlank`` as an `.applyPrivacyMode` effect ONLY while streaming AND
/// ONLY for a DISPLAY target (a window session has no whole display to blank) — the display-scoped
/// `audioControl` gating twin. No real CGDisplayGammaTable / CGEventTap is touched (hang-safety); the
/// effect layer is the headlessly-verifiable seam.
final class PrivacyModeSessionTests: XCTestCase {
    private let bounds = VideoRect(x: 0, y: 0, width: 1920, height: 1080)
    private let acceptAll: (UInt32, VideoSize) -> (UInt16, UInt16)? = { _, _ in (1920, 1080) }

    /// A DISPLAY session advanced into `.streaming` via an accepted `helloDisplay`.
    private func streamingDisplaySM() -> VideoSessionStateMachine {
        var sm = VideoSessionStateMachine()
        _ = sm.start()
        let hello = VideoControlMessage.helloDisplay(
            protocolVersion: SlopDeskVideoProtocol.version,
            requestedDisplayID: 1,
            viewport: VideoSize(width: 1920, height: 1080),
        )
        _ = sm.handleControl(
            hello, windowBoundsCG: bounds,
            resolveCaptureSize: { _, _ in nil },
            resolveDisplayCaptureSize: acceptAll,
        )
        return sm
    }

    /// A WINDOW session advanced into `.streaming` via an accepted `hello`.
    private func streamingWindowSM() -> VideoSessionStateMachine {
        var sm = VideoSessionStateMachine()
        _ = sm.start()
        let hello = VideoControlMessage.hello(
            protocolVersion: SlopDeskVideoProtocol.version,
            requestedWindowID: 42,
            viewport: VideoSize(width: 1920, height: 1080),
        )
        _ = sm.handleControl(hello, windowBoundsCG: bounds, resolveCaptureSize: acceptAll)
        return sm
    }

    func testPrivacyModeWhileStreamingDisplayEmitsApplyEffect() {
        var sm = streamingDisplaySM()
        XCTAssertTrue(sm.isDisplayTarget)
        let effects = sm.handleControl(
            .privacyMode(enabled: true),
            windowBoundsCG: bounds, resolveCaptureSize: acceptAll, resolveDisplayCaptureSize: acceptAll,
        )
        XCTAssertEqual(effects, [.applyPrivacyMode(enabled: true)], "a streaming display routes the blank wish")
        XCTAssertEqual(sm.state, .streaming, "privacy never changes the session lifecycle")
    }

    func testPrivacyModeOnAWindowSessionIsDropped() {
        var sm = streamingWindowSM()
        XCTAssertFalse(sm.isDisplayTarget)
        let effects = sm.handleControl(
            .privacyMode(enabled: true),
            windowBoundsCG: bounds, resolveCaptureSize: acceptAll,
        )
        XCTAssertTrue(effects.isEmpty, "a window session has no whole display to blank — dropped")
    }

    func testPrivacyModeWhileListeningIsDropped() {
        var sm = VideoSessionStateMachine()
        _ = sm.start()
        let effects = sm.handleControl(
            .privacyMode(enabled: true),
            windowBoundsCG: bounds, resolveCaptureSize: acceptAll,
        )
        XCTAssertTrue(effects.isEmpty, "no display session to blank pre-stream — the client re-sends after its hello")
    }

    func testSecondPrivacyModeReplacesTheFirst() {
        var sm = streamingDisplaySM()
        _ = sm.handleControl(
            .privacyMode(enabled: true),
            windowBoundsCG: bounds, resolveCaptureSize: acceptAll, resolveDisplayCaptureSize: acceptAll,
        )
        let second = sm.handleControl(
            .privacyMode(enabled: false),
            windowBoundsCG: bounds, resolveCaptureSize: acceptAll, resolveDisplayCaptureSize: acceptAll,
        )
        XCTAssertEqual(second, [.applyPrivacyMode(enabled: false)], "OFF replaces ON wholesale")
    }
}
