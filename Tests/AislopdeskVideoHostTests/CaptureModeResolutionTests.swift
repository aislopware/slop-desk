#if os(macOS)
import XCTest
@testable import AislopdeskVideoHost

/// `WindowCapturer.resolveCaptureMode` — the pure capture-path selector behind the
/// `AISLOPDESK_DISPLAY_CAPTURE` A/B seam and the VD-parked default (docs: the tooltip
/// 1px-shift fix — display-anchored crops are immune to the child-window bounding-rect nudge).
final class CaptureModeResolutionTests: XCTestCase {
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
