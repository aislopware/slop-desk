#if canImport(Metal) && canImport(QuartzCore)
import AislopdeskVideoProtocol
import XCTest
@testable import AislopdeskVideoClient

/// W12 P1 — REACHES-CONSUMER for the client unsharp strength (`AISLOPDESK_SHARPEN`). Drives the REAL
/// consumer function `MetalVideoRenderer.resolveSharpenStrength()` (extracted from the `static let` so
/// it's testable without forcing the Metal-touching renderer type) through the settings overlay: a GUI
/// slider value reaches the strength, and an EMPTY overlay yields today's default (0 = off). The
/// function only reads env via ``EnvConfig`` — no Metal device is created (hang-safety rule honoured).
final class SharpenResolutionTests: XCTestCase {
    override func tearDown() {
        EnvConfig.overlay = [:]
        super.tearDown()
    }

    func testOverlayReachesSharpenStrength() throws {
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["AISLOPDESK_SHARPEN"] != nil,
            "a real env var would win over the overlay (decision #16)",
        )
        EnvConfig.overlay = [:]
        XCTAssertEqual(MetalVideoRenderer.resolveSharpenStrength(), 0, "empty overlay ⇒ sharpen off (default)")
        EnvConfig.overlay["AISLOPDESK_SHARPEN"] = "0.6"
        XCTAssertEqual(MetalVideoRenderer.resolveSharpenStrength(), 0.6, accuracy: 1e-6, "overlay 0.6 ⇒ 0.6")
        EnvConfig.overlay["AISLOPDESK_SHARPEN"] = "10"
        XCTAssertEqual(MetalVideoRenderer.resolveSharpenStrength(), 4, "overlay above 4 ⇒ clamped to 4")
    }
}
#endif
