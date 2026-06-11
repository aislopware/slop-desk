import XCTest
@testable import AislopdeskVideoHost

#if os(macOS)
/// `InputInjector.clampToInt32` is the can't-trap backstop for a wire-supplied scroll delta.
/// `CGEvent(scrollWheelEvent2Source:…)` takes `Int32`, and the `Int32(Double)` initializer
/// TRAPS (fatal error) on NaN/±infinity or any value outside the `Int32` range — so a single
/// crafted scroll datagram (`dx`/`dy` = 1e300 / NaN / ±inf) could crash the entire host
/// process. The protocol layer rejects non-finite deltas at decode; this clamp guarantees no
/// finite-but-huge value can trap either. The one invariant: it NEVER traps.
final class InputInjectorClampTests: XCTestCase {
    func testClampToInt32NeverTrapsAndSaturates() {
        // In-range values round to the nearest Int32.
        XCTAssertEqual(InputInjector.clampToInt32(0), 0)
        XCTAssertEqual(InputInjector.clampToInt32(12.7), 13)
        XCTAssertEqual(InputInjector.clampToInt32(-12.7), -13)

        // NaN → 0 (must be handled before any comparison).
        XCTAssertEqual(InputInjector.clampToInt32(.nan), 0)

        // ±infinity and absurd finite magnitudes (the DoS trigger values) saturate.
        XCTAssertEqual(InputInjector.clampToInt32(.infinity), Int32.max)
        XCTAssertEqual(InputInjector.clampToInt32(-.infinity), Int32.min)
        XCTAssertEqual(InputInjector.clampToInt32(1e300), Int32.max)
        XCTAssertEqual(InputInjector.clampToInt32(-1e300), Int32.min)

        // Exactly at / just past the boundaries.
        XCTAssertEqual(InputInjector.clampToInt32(Double(Int32.max)), Int32.max)
        XCTAssertEqual(InputInjector.clampToInt32(Double(Int32.min)), Int32.min)
        XCTAssertEqual(InputInjector.clampToInt32(Double(Int32.max) + 1000), Int32.max)
        XCTAssertEqual(InputInjector.clampToInt32(Double(Int32.min) - 1000), Int32.min)
    }

    /// `scaledScrollDelta` (AISLOPDESK_SCROLL_GAIN) multiplies BEFORE the clamp, so the gained value
    /// inherits the same never-traps guarantee — and gain 1.0 is byte-identical to the bare clamp.
    func testScaledScrollDeltaGainsAndNeverTraps() {
        // Gain 1.0 (the default) == bare clamp for every interesting input.
        for v in [0.0, 12.7, -12.7, 1e300, -1e300, .infinity, -.infinity, .nan] {
            XCTAssertEqual(InputInjector.scaledScrollDelta(v, gain: 1.0), InputInjector.clampToInt32(v))
        }
        // Ordinary gain scales (then rounds).
        XCTAssertEqual(InputInjector.scaledScrollDelta(10, gain: 1.5), 15)
        XCTAssertEqual(InputInjector.scaledScrollDelta(-10, gain: 1.5), -15)
        XCTAssertEqual(InputInjector.scaledScrollDelta(3, gain: 0.5), 2) // 1.5 → .rounded() half-away-from-zero
        // Hostile value × gain still saturates, never traps.
        XCTAssertEqual(InputInjector.scaledScrollDelta(1e300, gain: 10), Int32.max)
        XCTAssertEqual(InputInjector.scaledScrollDelta(-1e300, gain: 10), Int32.min)
        XCTAssertEqual(InputInjector.scaledScrollDelta(.nan, gain: 2), 0)
        XCTAssertEqual(InputInjector.scaledScrollDelta(.infinity, gain: 0.1), Int32.max)
    }
}
#endif
