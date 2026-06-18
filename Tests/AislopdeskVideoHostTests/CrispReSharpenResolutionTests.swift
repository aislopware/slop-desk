import XCTest
@testable import AislopdeskVideoHost

/// PURE resolution of the crisp re-sharpen timing knobs (2026-06-16 latency-first reframe).
///
/// The static-IDR timer re-encodes the cached frame as a crisp near-lossless IDR once the screen
/// has been quiet for `quietWindow`, polled every `tick`. The coding-tool reframe wants "vừa dừng
/// là nét" — text crisp ~300ms after motion stops, not the old ~1s. These two resolvers own the
/// defaults + clamps so the change is one tested place (mirrors `resolveCaptureHz`). Pure, no
/// SCStream/VT — safe under `swift test --filter CrispReSharpenResolutionTests`.
final class CrispReSharpenResolutionTests: XCTestCase {
    private let heartbeat: TimeInterval = 2.5

    // MARK: quiet window (AISLOPDESK_QUIET_MS, milliseconds)

    func testQuietWindowDefaultIs300ms() {
        // The reframe: default crisp-after-stop window is 300ms (was min(1.0, heartbeat) = 1.0s).
        XCTAssertEqual(WindowCapturer.resolveQuietWindow(envValue: nil, heartbeat: heartbeat), 0.3, accuracy: 1e-9)
    }

    func testQuietWindowEnvOverrideMsToSeconds() {
        XCTAssertEqual(WindowCapturer.resolveQuietWindow(envValue: "200", heartbeat: heartbeat), 0.2, accuracy: 1e-9)
        XCTAssertEqual(WindowCapturer.resolveQuietWindow(envValue: "500", heartbeat: heartbeat), 0.5, accuracy: 1e-9)
    }

    func testQuietWindowClampsToFloor() {
        // Too-aggressive value floors at 50ms so a one-frame motion pause can't trip a crisp re-encode.
        XCTAssertEqual(WindowCapturer.resolveQuietWindow(envValue: "10", heartbeat: heartbeat), 0.05, accuracy: 1e-9)
        XCTAssertEqual(WindowCapturer.resolveQuietWindow(envValue: "0", heartbeat: heartbeat), 0.05, accuracy: 1e-9)
    }

    func testQuietWindowClampsToHeartbeat() {
        // Never longer than the heartbeat — a longer quiet window would stretch recovery suppression.
        XCTAssertEqual(
            WindowCapturer.resolveQuietWindow(envValue: "10000", heartbeat: heartbeat),
            heartbeat,
            accuracy: 1e-9,
        )
        XCTAssertEqual(WindowCapturer.resolveQuietWindow(envValue: "5000", heartbeat: 1.0), 1.0, accuracy: 1e-9)
    }

    func testQuietWindowGarbageFallsBackToDefault() {
        XCTAssertEqual(WindowCapturer.resolveQuietWindow(envValue: "abc", heartbeat: heartbeat), 0.3, accuracy: 1e-9)
        XCTAssertEqual(WindowCapturer.resolveQuietWindow(envValue: "", heartbeat: heartbeat), 0.3, accuracy: 1e-9)
    }

    // MARK: IDR poll tick (AISLOPDESK_IDR_TICK_MS, milliseconds)

    func testPollTickDefaultIs80ms() {
        // Tightened 250ms → 80ms so worst-case time-to-crisp ≈ quietWindow + tick ≈ 0.38s.
        XCTAssertEqual(WindowCapturer.resolveIDRPollTick(envValue: nil), 0.08, accuracy: 1e-9)
    }

    func testPollTickEnvOverride() {
        XCTAssertEqual(WindowCapturer.resolveIDRPollTick(envValue: "50"), 0.05, accuracy: 1e-9)
        XCTAssertEqual(WindowCapturer.resolveIDRPollTick(envValue: "250"), 0.25, accuracy: 1e-9)
    }

    func testPollTickClamps() {
        XCTAssertEqual(WindowCapturer.resolveIDRPollTick(envValue: "1"), 0.02, accuracy: 1e-9, "floor 20ms")
        XCTAssertEqual(WindowCapturer.resolveIDRPollTick(envValue: "100000"), 1.0, accuracy: 1e-9, "ceiling 1s")
    }

    func testPollTickGarbageFallsBackToDefault() {
        XCTAssertEqual(WindowCapturer.resolveIDRPollTick(envValue: "xyz"), 0.08, accuracy: 1e-9)
    }
}
