#if canImport(VideoToolbox) && canImport(ScreenCaptureKit)
import XCTest
@testable import SlopDeskVideoHost

/// The Parsec-parity `MaxFrameDelayCount` probe sequence
/// (``VideoEncoder/frameDelayCandidates(_:)``). Pins the exact clone of parsecd's session-setup:
/// unset ⇒ probe 0→6 smallest-first, `off`/`-1` ⇒ leave the key unset (legacy), a numeric `0…6` ⇒
/// pin. The wiring keeps the FIRST accepted candidate, so the ordering (smallest delay first) is the
/// load-bearing property this pins — a resequenced probe would silently raise pipeline latency.
final class FrameDelayCandidatesTests: XCTestCase {
    private func candidates(_ raw: String?) -> [Int] {
        VideoEncoder.frameDelayCandidates(raw)
    }

    // Unset (the default) ⇒ the full Parsec probe, ASCENDING from 0 (smallest latency wins first).
    func testUnsetProbesZeroThroughSixAscending() {
        XCTAssertEqual(candidates(nil), [0, 1, 2, 3, 4, 5, 6])
        // Load-bearing: strictly ascending and starts at 0 (the minimum-latency candidate is tried
        // first, so it is the one that gets pinned on an encoder that accepts it).
        let seq = candidates(nil)
        XCTAssertEqual(seq.first, 0)
        XCTAssertEqual(seq, seq.sorted())
    }

    // The escape hatch: `off` / `-1` (any case) ⇒ NO candidates ⇒ the key is left unset == the
    // pre-clone behaviour (VT's own kVTUnlimitedFrameDelayCount default).
    func testOffLeavesKeyUnset() {
        XCTAssertEqual(candidates("off"), [])
        XCTAssertEqual(candidates("OFF"), [])
        XCTAssertEqual(candidates("-1"), [])
    }

    // A parseable 0…6 pins exactly that single value (A/B override).
    func testNumericPinsSingleValue() {
        XCTAssertEqual(candidates("0"), [0])
        XCTAssertEqual(candidates("3"), [3])
        XCTAssertEqual(candidates("6"), [6])
    }

    // Out-of-range / garbage falls back to the probe (never an empty set that would silently disable
    // the lever, never an out-of-range pin VT would reject on every session).
    func testOutOfRangeAndGarbageFallBackToProbe() {
        for raw in ["7", "-2", "99", "", "abc", "3.5"] {
            XCTAssertEqual(candidates(raw), [0, 1, 2, 3, 4, 5, 6], "‘\(raw)’ must fall back to the probe")
        }
    }
}
#endif
