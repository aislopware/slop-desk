import XCTest
@testable import RworkVideoHost

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
}
#endif
