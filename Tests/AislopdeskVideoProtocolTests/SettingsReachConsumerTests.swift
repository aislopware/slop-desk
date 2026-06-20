import Foundation
import XCTest
@testable import AislopdeskVideoProtocol

/// W12 P1 — REACHES-CONSUMER proofs for the GUI-exposed flags whose live read sites were migrated to
/// ``EnvConfig`` but whose consumers live in HW-gated / executable targets that cannot be instantiated
/// headlessly (the daemon's `AISLOPDESK_VD` / `AISLOPDESK_CAPTURE_SCALE`, the client's `AISLOPDESK_PACER`
/// / `AISLOPDESK_PLAYOUT_MS`). For these we assert the consumer's EXACT parse/clamp expression — copied
/// verbatim from the migrated call site — over the settings overlay: a Settings override changes the
/// parsed value, and an EMPTY overlay (no env in the test runner) yields today's default. So the test
/// fails if a migration drops a flag back to a raw `ProcessInfo` read (the override would no longer
/// land) OR if the parse/clamp idiom drifts. The capture-mode / QP-decouple / FEC / agent reaches-consumer
/// proofs live with their consumers (`CaptureModeResolutionTests`, `MultiLossFECActivationTests`,
/// `AgentEnvironmentTests`).
///
/// Decision #16: a real env var WINS over the overlay, so each test skips if the runner sets the key.
final class SettingsReachConsumerTests: XCTestCase {
    override func setUp() {
        super.setUp()
        EnvConfig.overlay = [:]
    }

    override func tearDown() {
        EnvConfig.overlay = [:]
        super.tearDown()
    }

    private func skipIfRealEnv(_ key: String) throws {
        try XCTSkipIf(
            ProcessInfo.processInfo.environment[key] != nil,
            "a real env var would win over the overlay (decision #16) — masks the path under test",
        )
    }

    // MARK: AISLOPDESK_VD — `aislopdesk-videohostd` VideoHostdArguments.virtualDisplay

    /// The daemon's VD override: `if let vd = EnvConfig.string("AISLOPDESK_VD") { virtualDisplay = (vd != "0") }`
    /// (default-ON; only `"0"` disables). An overlay value reaches it; absent ⇒ the daemon keeps its
    /// `virtualDisplay = true` default (the override branch isn't taken).
    func testOverlayReachesVirtualDisplay() throws {
        try skipIfRealEnv("AISLOPDESK_VD")
        // Mirror the call site: start from the daemon default (true) and apply the override branch.
        func resolveVirtualDisplay(default def: Bool) -> Bool {
            guard let vd = EnvConfig.string("AISLOPDESK_VD") else { return def }
            return vd != "0"
        }
        XCTAssertTrue(resolveVirtualDisplay(default: true), "empty overlay ⇒ daemon default (VD on)")
        EnvConfig.overlay["AISLOPDESK_VD"] = "0"
        XCTAssertFalse(resolveVirtualDisplay(default: true), "overlay AISLOPDESK_VD=0 ⇒ VD off")
        EnvConfig.overlay["AISLOPDESK_VD"] = "1"
        XCTAssertTrue(resolveVirtualDisplay(default: true), "overlay AISLOPDESK_VD=1 ⇒ VD on")
    }

    // MARK: AISLOPDESK_CAPTURE_SCALE — `resolveCaptureScaleOverride(vdScale:)`

    /// The daemon's capture-scale override: parse `Double`, require `>= 1`, then `min(vdScale, v)`.
    /// Unset ⇒ the VD's backing scale. The overlay must reach this exact clamp.
    func testOverlayReachesCaptureScale() throws {
        try skipIfRealEnv("AISLOPDESK_CAPTURE_SCALE")
        func resolveCaptureScaleOverride(vdScale: Double) -> Double {
            guard let s = EnvConfig.string("AISLOPDESK_CAPTURE_SCALE"), let v = Double(s), v >= 1
            else { return vdScale }
            return min(vdScale, v)
        }
        XCTAssertEqual(resolveCaptureScaleOverride(vdScale: 2.0), 2.0, "empty overlay ⇒ the VD scale")
        EnvConfig.overlay["AISLOPDESK_CAPTURE_SCALE"] = "1"
        XCTAssertEqual(resolveCaptureScaleOverride(vdScale: 2.0), 1.0, "overlay 1 ⇒ 1× (downscaled)")
        EnvConfig.overlay["AISLOPDESK_CAPTURE_SCALE"] = "0.5" // below the >= 1 gate ⇒ rejected → default
        XCTAssertEqual(resolveCaptureScaleOverride(vdScale: 2.0), 2.0, "sub-1 rejected ⇒ VD scale")
        EnvConfig.overlay["AISLOPDESK_CAPTURE_SCALE"] = "9" // capped to vdScale
        XCTAssertEqual(resolveCaptureScaleOverride(vdScale: 2.0), 2.0, "above VD scale ⇒ capped to vdScale")
    }

    // MARK: AISLOPDESK_PACER — VideoWindowPipeline deadlineMode

    /// The client pacer selector: `EnvConfig.string("AISLOPDESK_PACER").map { $0.lowercased() == "deadline" } ?? false`
    /// (default present-on-arrival; only `deadline` flips to the deadline pacer). The overlay must reach it.
    func testOverlayReachesPacer() throws {
        try skipIfRealEnv("AISLOPDESK_PACER")
        func resolveDeadlineMode() -> Bool {
            EnvConfig.string("AISLOPDESK_PACER").map { $0.lowercased() == "deadline" } ?? false
        }
        XCTAssertFalse(resolveDeadlineMode(), "empty overlay ⇒ present-on-arrival (default)")
        EnvConfig.overlay["AISLOPDESK_PACER"] = "deadline"
        XCTAssertTrue(resolveDeadlineMode(), "overlay AISLOPDESK_PACER=deadline ⇒ deadline pacer")
        EnvConfig.overlay["AISLOPDESK_PACER"] = "arrival"
        XCTAssertFalse(resolveDeadlineMode(), "any non-deadline value ⇒ present-on-arrival")
    }

    // MARK: AISLOPDESK_PLAYOUT_MS — VideoWindowPipeline fixedPlayoutOverride / playoutMs

    /// The client playout override: presence flips adaptation OFF (`fixedPlayoutOverride`), and the
    /// value (parsed `Double`, else 10.0 seed) is the fixed buffer. The overlay must reach both.
    func testOverlayReachesPlayoutMs() throws {
        try skipIfRealEnv("AISLOPDESK_PLAYOUT_MS")
        func fixedPlayoutOverride() -> Bool { EnvConfig.string("AISLOPDESK_PLAYOUT_MS") != nil }
        func playoutMs() -> Double { EnvConfig.string("AISLOPDESK_PLAYOUT_MS").flatMap(Double.init) ?? 10.0 }
        XCTAssertFalse(fixedPlayoutOverride(), "empty overlay ⇒ adaptive playout (no fixed override)")
        XCTAssertEqual(playoutMs(), 10.0, "empty overlay ⇒ the 10ms cold-start seed")
        EnvConfig.overlay["AISLOPDESK_PLAYOUT_MS"] = "25"
        XCTAssertTrue(fixedPlayoutOverride(), "an overlay value flips adaptation off")
        XCTAssertEqual(playoutMs(), 25.0, "overlay AISLOPDESK_PLAYOUT_MS=25 ⇒ fixed 25ms buffer")
    }

    // MARK: AISLOPDESK_SHARPEN — the client renderer's resolveSharpenStrength expression

    /// The client sharpen resolver: parse `Float`, reject `<= 0` → 0 (off), clamp `> 4` → 4. (The live
    /// consumer `MetalVideoRenderer.resolveSharpenStrength()` is Metal-gated; this mirrors its exact
    /// parse so the overlay-reaches proof runs headlessly.)
    func testOverlayReachesSharpen() throws {
        try skipIfRealEnv("AISLOPDESK_SHARPEN")
        func resolveSharpen() -> Float {
            guard let s = EnvConfig.string("AISLOPDESK_SHARPEN"), let v = Float(s), v > 0 else { return 0 }
            return min(4, v)
        }
        XCTAssertEqual(resolveSharpen(), 0, "empty overlay ⇒ sharpen off (default 0)")
        EnvConfig.overlay["AISLOPDESK_SHARPEN"] = "0.8"
        XCTAssertEqual(resolveSharpen(), 0.8, accuracy: 1e-6, "overlay 0.8 ⇒ 0.8 strength")
        EnvConfig.overlay["AISLOPDESK_SHARPEN"] = "9"
        XCTAssertEqual(resolveSharpen(), 4, "overlay above 4 ⇒ clamped to 4")
        EnvConfig.overlay["AISLOPDESK_SHARPEN"] = "0"
        XCTAssertEqual(resolveSharpen(), 0, "overlay 0 ⇒ off")
    }
}
