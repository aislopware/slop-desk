import SlopDeskVideoProtocol
import XCTest
@testable import SlopDeskVideoHost

/// PURE logic for the client's live `streamSettings` (wire type 25): the host state machine must
/// route the message to the actor's actuators as an `.applyStreamSettings` effect ONLY while
/// streaming, and ``UserStreamSettingsPolicy`` owns the host-side clamps (fps 5…120, bitrate
/// 500 kbps…200 Mbps, 0 = auto) plus the governor⊓cap fps composition. No live
/// SCStream / VTCompressionSession / socket is touched (hang-safety rule) — the actuator wiring
/// (`WindowCapturer.setGovernedFPS` / `VideoEncoder.setExpectedFrameRate` /
/// `LiveCongestionController.setUserCeilingBps`) is HW-gated, so the effect + clamp layer is the
/// headlessly-verifiable seam, exactly like ``VideoSessionStateMachineTests``.
final class UserStreamSettingsTests: XCTestCase {
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

    // MARK: State machine → actuator effect

    func testStreamSettingsWhileStreamingEmitsApplyEffect() {
        var sm = streamingSM()
        let effects = sm.handleControl(
            .streamSettings(fpsCap: 24, bitrateCeilingBps: 8_000_000),
            windowBoundsCG: bounds,
            resolveCaptureSize: acceptAll,
        )
        XCTAssertEqual(
            effects,
            [.applyStreamSettings(fpsCap: 24, bitrateCeilingBps: 8_000_000)],
            "a streaming session routes the RAW wire values to the actor's apply/clamp step",
        )
        XCTAssertEqual(sm.state, .streaming, "settings never change the session lifecycle")
    }

    func testStreamSettingsWhileListeningIsDropped() {
        var sm = VideoSessionStateMachine()
        _ = sm.start()
        let effects = sm.handleControl(
            .streamSettings(fpsCap: 24, bitrateCeilingBps: 8_000_000),
            windowBoundsCG: bounds,
            resolveCaptureSize: acceptAll,
        )
        XCTAssertTrue(effects.isEmpty, "no live capture/encoder to actuate — the client re-sends after its hello")
    }

    func testSecondStreamSettingsReplacesTheFirstWholesale() {
        // The SM is stateless about the values — each message yields its own apply effect; the
        // ACTOR overwrite (re-assign both overrides) is what makes replacement wholesale.
        var sm = streamingSM()
        _ = sm.handleControl(
            .streamSettings(fpsCap: 24, bitrateCeilingBps: 8_000_000),
            windowBoundsCG: bounds, resolveCaptureSize: acceptAll,
        )
        let second = sm.handleControl(
            .streamSettings(fpsCap: 0, bitrateCeilingBps: 0),
            windowBoundsCG: bounds, resolveCaptureSize: acceptAll,
        )
        XCTAssertEqual(second, [.applyStreamSettings(fpsCap: 0, bitrateCeilingBps: 0)], "0s restore auto")
    }

    // MARK: Host-side clamps (validate-then-drop: length at decode, semantics here)

    func testFpsCapClampSemantics() {
        XCTAssertNil(UserStreamSettingsPolicy.fpsCap(fromWire: 0), "0 = auto (clear the override)")
        XCTAssertEqual(UserStreamSettingsPolicy.fpsCap(fromWire: 1), 5, "below the band clamps up to 5")
        XCTAssertEqual(UserStreamSettingsPolicy.fpsCap(fromWire: 5), 5)
        XCTAssertEqual(UserStreamSettingsPolicy.fpsCap(fromWire: 24), 24)
        XCTAssertEqual(UserStreamSettingsPolicy.fpsCap(fromWire: 120), 120)
        XCTAssertEqual(UserStreamSettingsPolicy.fpsCap(fromWire: 255), 120, "above the band clamps down to 120")
    }

    func testBitrateCeilingClampSemantics() {
        XCTAssertNil(UserStreamSettingsPolicy.bitrateCeiling(fromWire: 0), "0 = auto (clear the override)")
        XCTAssertEqual(UserStreamSettingsPolicy.bitrateCeiling(fromWire: 1), 500_000, "clamps up to 500 kbps")
        XCTAssertEqual(UserStreamSettingsPolicy.bitrateCeiling(fromWire: 500_000), 500_000)
        XCTAssertEqual(UserStreamSettingsPolicy.bitrateCeiling(fromWire: 8_000_000), 8_000_000)
        XCTAssertEqual(UserStreamSettingsPolicy.bitrateCeiling(fromWire: 200_000_000), 200_000_000)
        XCTAssertEqual(
            UserStreamSettingsPolicy.bitrateCeiling(fromWire: UInt32.max),
            200_000_000,
            "clamps down to 200 Mbps",
        )
    }

    // MARK: fps composition (governor ⊓ user cap)

    func testEffectiveFpsComposesGovernorAndCapByMin() {
        // Governor enabled and stepped below the cap: the governor rules.
        XCTAssertEqual(UserStreamSettingsPolicy.effectiveFps(governed: 15, userCap: 20), 15)
        // Governor above the cap: the cap rules.
        XCTAssertEqual(UserStreamSettingsPolicy.effectiveFps(governed: 60, userCap: 20), 20)
        // Governor disabled (governed == base fps): the cap applies directly.
        XCTAssertEqual(UserStreamSettingsPolicy.effectiveFps(governed: 30, userCap: 24), 24)
        // No cap ⇒ exactly the governed value (every pre-override path byte-identical).
        XCTAssertEqual(UserStreamSettingsPolicy.effectiveFps(governed: 30, userCap: nil), 30)
        // A cap above the governed/base rate never RAISES the cadence.
        XCTAssertEqual(UserStreamSettingsPolicy.effectiveFps(governed: 30, userCap: 120), 30)
    }
}
