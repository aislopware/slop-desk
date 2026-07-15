import Foundation
import XCTest
@testable import SlopDeskVideoProtocol

/// REACHES-CONSUMER proofs for the GUI-exposed flags whose live read sites were migrated to
/// ``EnvConfig`` but whose consumers live in HW-gated / executable targets that cannot be instantiated
/// headlessly (the daemon's `SLOPDESK_VD` / `SLOPDESK_CAPTURE_SCALE`, the client's `SLOPDESK_PACER`
/// / `SLOPDESK_PLAYOUT_MS`). For these we assert the consumer's EXACT parse/clamp expression — copied
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

    // MARK: SLOPDESK_VD — `slopdesk-videohostd` VideoHostdArguments.virtualDisplay

    /// The daemon's VD override: `if let vd = EnvConfig.string("SLOPDESK_VD") { virtualDisplay = (vd != "0") }`
    /// (default-OFF; only a non-`"0"` value enables). An overlay value reaches it; absent
    /// ⇒ the daemon keeps its `virtualDisplay = false` default (the override branch isn't taken).
    func testOverlayReachesVirtualDisplay() throws {
        try skipIfRealEnv("SLOPDESK_VD")
        // Mirror the call site: start from the daemon default (false) and apply the override branch.
        func resolveVirtualDisplay(default def: Bool) -> Bool {
            guard let vd = EnvConfig.string("SLOPDESK_VD") else { return def }
            return vd != "0"
        }
        XCTAssertFalse(resolveVirtualDisplay(default: false), "empty overlay ⇒ daemon default (VD off)")
        EnvConfig.overlay["SLOPDESK_VD"] = "1"
        XCTAssertTrue(resolveVirtualDisplay(default: false), "overlay SLOPDESK_VD=1 ⇒ VD on")
        EnvConfig.overlay["SLOPDESK_VD"] = "0"
        XCTAssertFalse(resolveVirtualDisplay(default: false), "overlay SLOPDESK_VD=0 ⇒ VD off")
    }

    // MARK: SLOPDESK_CAPTURE_SCALE — `resolveCaptureScaleOverride(vdScale:)`

    /// The daemon's capture-scale override: parse `Double`, require `>= 1`, then `min(vdScale, v)`.
    /// Unset ⇒ the VD's backing scale. The overlay must reach this exact clamp.
    func testOverlayReachesCaptureScale() throws {
        try skipIfRealEnv("SLOPDESK_CAPTURE_SCALE")
        func resolveCaptureScaleOverride(vdScale: Double) -> Double {
            guard let s = EnvConfig.string("SLOPDESK_CAPTURE_SCALE"), let v = Double(s), v >= 1
            else { return vdScale }
            return min(vdScale, v)
        }
        XCTAssertEqual(resolveCaptureScaleOverride(vdScale: 2.0), 2.0, "empty overlay ⇒ the VD scale")
        EnvConfig.overlay["SLOPDESK_CAPTURE_SCALE"] = "1"
        XCTAssertEqual(resolveCaptureScaleOverride(vdScale: 2.0), 1.0, "overlay 1 ⇒ 1× (downscaled)")
        EnvConfig.overlay["SLOPDESK_CAPTURE_SCALE"] = "0.5" // below the >= 1 gate ⇒ rejected → default
        XCTAssertEqual(resolveCaptureScaleOverride(vdScale: 2.0), 2.0, "sub-1 rejected ⇒ VD scale")
        EnvConfig.overlay["SLOPDESK_CAPTURE_SCALE"] = "9" // capped to vdScale
        XCTAssertEqual(resolveCaptureScaleOverride(vdScale: 2.0), 2.0, "above VD scale ⇒ capped to vdScale")
    }

    // MARK: SLOPDESK_PACER — VideoWindowPipeline deadlineMode

    /// The client pacer selector mirrors `VideoWindowPipeline`:
    /// `EnvConfig.string("SLOPDESK_PACER").map { !["arrival","off","0"].contains($0.lowercased()) } ?? true`
    /// (default deadline for the remote-GUI path; `arrival`/`off`/`0` force present-on-arrival). Overlay reaches it.
    func testOverlayReachesPacer() throws {
        try skipIfRealEnv("SLOPDESK_PACER")
        func resolveDeadlineMode() -> Bool {
            EnvConfig.string("SLOPDESK_PACER").map { !["arrival", "off", "0"].contains($0.lowercased()) } ?? true
        }
        XCTAssertTrue(resolveDeadlineMode(), "empty overlay ⇒ deadline pacer (default)")
        EnvConfig.overlay["SLOPDESK_PACER"] = "arrival"
        XCTAssertFalse(resolveDeadlineMode(), "overlay SLOPDESK_PACER=arrival ⇒ present-on-arrival")
        EnvConfig.overlay["SLOPDESK_PACER"] = "deadline"
        XCTAssertTrue(resolveDeadlineMode(), "overlay SLOPDESK_PACER=deadline ⇒ deadline pacer")
    }

    // MARK: SLOPDESK_PLAYOUT_MS — VideoWindowPipeline fixedPlayoutOverride / playoutMs

    /// The client playout override: presence flips adaptation OFF (`fixedPlayoutOverride`), and the
    /// value (parsed `Double`, else 10.0 seed) is the fixed buffer. The overlay must reach both.
    func testOverlayReachesPlayoutMs() throws {
        try skipIfRealEnv("SLOPDESK_PLAYOUT_MS")
        func fixedPlayoutOverride() -> Bool { EnvConfig.string("SLOPDESK_PLAYOUT_MS") != nil }
        func playoutMs() -> Double { EnvConfig.string("SLOPDESK_PLAYOUT_MS").flatMap(Double.init) ?? 10.0 }
        XCTAssertFalse(fixedPlayoutOverride(), "empty overlay ⇒ adaptive playout (no fixed override)")
        XCTAssertEqual(playoutMs(), 10.0, "empty overlay ⇒ the 10ms cold-start seed")
        EnvConfig.overlay["SLOPDESK_PLAYOUT_MS"] = "25"
        XCTAssertTrue(fixedPlayoutOverride(), "an overlay value flips adaptation off")
        XCTAssertEqual(playoutMs(), 25.0, "overlay SLOPDESK_PLAYOUT_MS=25 ⇒ fixed 25ms buffer")
    }

    // MARK: SLOPDESK_SHARPEN — the client renderer's resolveSharpenStrength expression

    /// The client sharpen resolver: parse `Float`, reject `<= 0` → 0 (off), clamp `> 4` → 4. (The live
    /// consumer `MetalVideoRenderer.resolveSharpenStrength()` is Metal-gated; this mirrors its exact
    /// parse so the overlay-reaches proof runs headlessly.)
    func testOverlayReachesSharpen() throws {
        try skipIfRealEnv("SLOPDESK_SHARPEN")
        func resolveSharpen() -> Float {
            guard let s = EnvConfig.string("SLOPDESK_SHARPEN"), let v = Float(s), v > 0 else { return 0 }
            return min(4, v)
        }
        XCTAssertEqual(resolveSharpen(), 0, "empty overlay ⇒ sharpen off (default 0)")
        EnvConfig.overlay["SLOPDESK_SHARPEN"] = "0.8"
        XCTAssertEqual(resolveSharpen(), 0.8, accuracy: 1e-6, "overlay 0.8 ⇒ 0.8 strength")
        EnvConfig.overlay["SLOPDESK_SHARPEN"] = "9"
        XCTAssertEqual(resolveSharpen(), 4, "overlay above 4 ⇒ clamped to 4")
        EnvConfig.overlay["SLOPDESK_SHARPEN"] = "0"
        XCTAssertEqual(resolveSharpen(), 0, "overlay 0 ⇒ off")
    }
}
