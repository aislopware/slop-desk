#if os(macOS)
import AislopdeskVideoProtocol
import XCTest
@testable import AislopdeskVideoHost

/// `WindowCapturer.resolveCaptureMode` — the pure capture-path selector behind the
/// `AISLOPDESK_DISPLAY_CAPTURE` A/B seam and the VD-parked default (docs: the tooltip
/// 1px-shift fix — display-anchored crops are immune to the child-window bounding-rect nudge).
final class CaptureModeResolutionTests: XCTestCase {
    override func tearDown() {
        EnvConfig.overlay = [:] // process-wide overlay — never leak across tests
        super.tearDown()
    }

    // MARK: W12 — the settings overlay REACHES the capture-mode + QP-decouple consumers

    /// REACHES-CONSUMER (P1): the live `WindowCapturer` call site now resolves
    /// `AISLOPDESK_DISPLAY_CAPTURE` through ``EnvConfig`` (overlay → env). This asserts the integrated
    /// expression the call site uses — `resolveCaptureMode(envValue: EnvConfig.string(...))` — so a GUI
    /// override of the capture filter actually forces the mode. An EMPTY overlay (and no env in the test
    /// runner) keeps today's VD-parked default.
    func testOverlayReachesDisplayCaptureSelection() throws {
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["AISLOPDESK_DISPLAY_CAPTURE"] != nil,
            "a real env var would win over the overlay (decision #16)",
        )
        EnvConfig.overlay = [:]
        // Empty overlay ⇒ today's default (VD-parked ⇒ display-including).
        XCTAssertEqual(
            WindowCapturer.resolveCaptureMode(
                envValue: EnvConfig.string("AISLOPDESK_DISPLAY_CAPTURE"), preferDisplayAnchored: true,
            ),
            .displayIncluding,
        )
        // A settings override forces the window-composite mode even on a VD-parked window.
        EnvConfig.overlay["AISLOPDESK_DISPLAY_CAPTURE"] = "window"
        XCTAssertEqual(
            WindowCapturer.resolveCaptureMode(
                envValue: EnvConfig.string("AISLOPDESK_DISPLAY_CAPTURE"), preferDisplayAnchored: true,
            ),
            .window,
            "overlay AISLOPDESK_DISPLAY_CAPTURE=window forces .window",
        )
    }

    /// REACHES-CONSUMER (P1): the `VideoEncoder.qpDecouple` consumer resolves `AISLOPDESK_QP_DECOUPLE`
    /// via `EnvConfig.boolDefaultOn` (the exact expression migrated at the `static let`). This asserts
    /// that expression honours the overlay (default-ON: only `"0"` disables) — empty overlay ⇒ ON.
    func testOverlayReachesQPDecoupleResolution() throws {
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["AISLOPDESK_QP_DECOUPLE"] != nil,
            "a real env var would win over the overlay (decision #16)",
        )
        EnvConfig.overlay = [:]
        XCTAssertTrue(EnvConfig.boolDefaultOn("AISLOPDESK_QP_DECOUPLE"), "empty overlay ⇒ decouple ON (default)")
        EnvConfig.overlay["AISLOPDESK_QP_DECOUPLE"] = "0"
        XCTAssertFalse(EnvConfig.boolDefaultOn("AISLOPDESK_QP_DECOUPLE"), "overlay \"0\" ⇒ decouple OFF")
    }

    /// `canResizeInPlace` gate — in-place `updateConfiguration` resize is allowed ONLY when the flag
    /// is on, the capture is display-anchored, and the crop is not a poller-owned union.
    func testCanResizeInPlaceGate() {
        // Allowed: flag on + display-anchored + not union.
        XCTAssertTrue(WindowCapturer.canResizeInPlace(flagEnabled: true, isDisplayAnchored: true, isUnion: false))
        // Flag off → restart-fallback.
        XCTAssertFalse(WindowCapturer.canResizeInPlace(flagEnabled: false, isDisplayAnchored: true, isUnion: false))
        // .window mode (not display-anchored) → restart-fallback.
        XCTAssertFalse(WindowCapturer.canResizeInPlace(flagEnabled: true, isDisplayAnchored: false, isUnion: false))
        // Union (DIALOG-EXPAND poller-owned crop) → restart-fallback.
        XCTAssertFalse(WindowCapturer.canResizeInPlace(flagEnabled: true, isDisplayAnchored: true, isUnion: true))
    }

    // Env forces win regardless of VD parking.
    func testEnvForcesWindowMode() {
        XCTAssertEqual(WindowCapturer.resolveCaptureMode(envValue: "window", preferDisplayAnchored: true), .window)
        XCTAssertEqual(WindowCapturer.resolveCaptureMode(envValue: "0", preferDisplayAnchored: true), .window)
    }

    func testEnvForcesDisplayExcluding() {
        XCTAssertEqual(
            WindowCapturer.resolveCaptureMode(envValue: "1", preferDisplayAnchored: false),
            .displayExcluding,
        )
        XCTAssertEqual(
            WindowCapturer.resolveCaptureMode(envValue: "display", preferDisplayAnchored: false),
            .displayExcluding,
        )
    }

    func testEnvForcesDisplayIncluding() {
        XCTAssertEqual(
            WindowCapturer.resolveCaptureMode(envValue: "include", preferDisplayAnchored: false),
            .displayIncluding,
        )
        XCTAssertEqual(
            WindowCapturer.resolveCaptureMode(envValue: "display-include", preferDisplayAnchored: false),
            .displayIncluding,
        )
    }

    // No env: VD-parked windows default to the occlusion-proof display-anchored mode;
    // free-roaming (non-VD) windows keep the follow-anywhere window composite.
    func testDefaultFollowsVDParking() {
        XCTAssertEqual(WindowCapturer.resolveCaptureMode(envValue: nil, preferDisplayAnchored: true), .displayIncluding)
        XCTAssertEqual(WindowCapturer.resolveCaptureMode(envValue: nil, preferDisplayAnchored: false), .window)
    }

    // An unrecognized value must not crash or force an exotic mode — fall to the default rule.
    func testUnrecognizedEnvFallsToDefault() {
        XCTAssertEqual(WindowCapturer.resolveCaptureMode(envValue: "banana", preferDisplayAnchored: false), .window)
        XCTAssertEqual(
            WindowCapturer.resolveCaptureMode(envValue: "banana", preferDisplayAnchored: true),
            .displayIncluding,
        )
    }
}
#endif
