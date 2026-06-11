import XCTest
@testable import AislopdeskVideoClient

/// DISPLAY-NATIVE TICK (latency audit, 2026-06-10): the display link runs at the display's
/// native refresh, floored at the host content fps, with `AISLOPDESK_TICK_HZ` as the A/B override.
/// Pure resolution matrix — the GUI wiring (reading the view's screen) is GUI-only.
final class FramePacerTickRateTests: XCTestCase {

    func testDisplayRateWinsWhenAboveContentFloor() {
        // ProMotion panel: tick at 120 so a frame waits ≤8.3ms for a tick, not ≤16.7ms.
        XCTAssertEqual(FramePacer.resolveTickRate(envOverride: nil, displayMaxHz: 120, floor: 60), 120)
        // Standard 60Hz panel: unchanged behavior.
        XCTAssertEqual(FramePacer.resolveTickRate(envOverride: nil, displayMaxHz: 60, floor: 60), 60)
    }

    func testFloorGuardsDegenerateScreenReadings() {
        // Unknown screen (0) or a reading below the content fps never drops the tick rate.
        XCTAssertEqual(FramePacer.resolveTickRate(envOverride: nil, displayMaxHz: 0, floor: 60), 60)
        XCTAssertEqual(FramePacer.resolveTickRate(envOverride: nil, displayMaxHz: 30, floor: 60), 60)
    }

    func testEnvOverrideWinsAndClamps() {
        // AISLOPDESK_TICK_HZ beats the resolved display rate (A/B without rebuild).
        XCTAssertEqual(FramePacer.resolveTickRate(envOverride: "60", displayMaxHz: 120, floor: 60), 60)
        XCTAssertEqual(FramePacer.resolveTickRate(envOverride: "90", displayMaxHz: 60, floor: 60), 90)
        // Clamped to the sane band [30, 240].
        XCTAssertEqual(FramePacer.resolveTickRate(envOverride: "1000", displayMaxHz: 60, floor: 60), 240)
        XCTAssertEqual(FramePacer.resolveTickRate(envOverride: "1", displayMaxHz: 60, floor: 60), 30)
        // Junk values fall back to the resolved rate.
        XCTAssertEqual(FramePacer.resolveTickRate(envOverride: "abc", displayMaxHz: 120, floor: 60), 120)
        XCTAssertEqual(FramePacer.resolveTickRate(envOverride: "inf", displayMaxHz: 120, floor: 60), 120)
        XCTAssertEqual(FramePacer.resolveTickRate(envOverride: "nan", displayMaxHz: 120, floor: 60), 120)
    }
}
