#if canImport(VideoToolbox) && canImport(ScreenCaptureKit)
import XCTest
@testable import SlopDeskVideoHost

/// The DELTA send-pace FLOOR (`SLOPDESK_DELTA_PACE_FLOOR_BPS`). Pins the PURE target selection
/// (``SlopDeskVideoHostSession/paceTargetBps(keyframe:abr:kfFloorBps:deltaFloorBps:)``) and its effect on
/// the pacing gap (``SlopDeskVideoHostSession/adaptivePaceGapNanos``): a low-ABR delta paces FASTER when
/// floored (shorter gap ⇒ shorter send-span ⇒ less depth-1 present jitter), a delta whose ABR already
/// clears the floor is untouched, keyframes keep their own floor, and `deltaFloor == 0` is a
/// byte-identical no-op (the default-OFF contract — send timing identical to the pre-floor path).
final class PaceTargetFloorTests: XCTestCase {
    private let kfFloor = 12_000_000

    private func target(_ keyframe: Bool, _ abr: Int, deltaFloor: Int) -> Int {
        SlopDeskVideoHostSession.paceTargetBps(
            keyframe: keyframe, abr: abr, kfFloorBps: kfFloor, deltaFloorBps: deltaFloor,
        )
    }

    // The pacing gap for a given target (same clamps as the shipped call site).
    private func gap(_ bps: Int) -> UInt64 {
        SlopDeskVideoHostSession.adaptivePaceGapNanos(
            targetBps: bps, fallbackBps: 12_000_000,
            chunkFragments: 8, datagramSize: 1200,
            floorNanos: 200_000, ceilNanos: 40_000_000, rateMultiplier: 2.5,
        )
    }

    // A stale-low static-window ABR (4Mbps) is LIFTED to the floor for a delta — the whole point.
    func testDeltaFloorLiftsLowABR() {
        XCTAssertEqual(target(false, 4_000_000, deltaFloor: 12_000_000), 12_000_000)
    }

    // A delta whose ABR already clears the floor is untouched (an active scene already paces fast) —
    // the floor only ever RAISES the target, never lowers it.
    func testDeltaFloorInertWhenABRClearsFloor() {
        XCTAssertEqual(target(false, 40_000_000, deltaFloor: 12_000_000), 40_000_000)
        XCTAssertEqual(target(false, 12_000_000, deltaFloor: 12_000_000), 12_000_000) // exactly at floor
    }

    // floor == 0 (the default/OFF) is a byte-identical no-op: the delta target is the raw ABR for
    // EVERY input, including the pre-warmup ABR == 0 (⇒ the gap math's fallback, unchanged).
    func testDeltaFloorZeroIsRawABRNoOp() {
        for abr in [0, 1, 4_000_000, 8_000_000, 40_000_000, 1_000_000_000] {
            XCTAssertEqual(target(false, abr, deltaFloor: 0), abr, "delta floor 0 must pass ABR through")
        }
    }

    // Keyframes keep THEIR floor and are indifferent to the delta floor (the delta floor never
    // touches the keyframe branch — recovery pacing is governed by kfPaceFloorBps alone).
    func testKeyframeUsesOwnFloorIgnoringDeltaFloor() {
        XCTAssertEqual(target(true, 4_000_000, deltaFloor: 0), kfFloor) // kf floor applies even with delta off
        XCTAssertEqual(target(true, 4_000_000, deltaFloor: 30_000_000), kfFloor) // delta floor irrelevant to kf
        XCTAssertEqual(target(true, 40_000_000, deltaFloor: 0), 40_000_000) // above kf floor ⇒ raw
    }

    // The causal chain that matters: flooring a low-ABR delta SHRINKS its pacing gap (⇒ send-span ⇒
    // present jitter). Floored 4Mbps→12Mbps delta gap < un-floored 4Mbps delta gap.
    func testFlooredTargetShrinksTheGap() {
        let floored = gap(target(false, 4_000_000, deltaFloor: 12_000_000))
        let raw = gap(target(false, 4_000_000, deltaFloor: 0))
        XCTAssertLessThan(floored, raw, "flooring the delta target must produce a shorter (faster) pace gap")
    }

    // floor == 0 produces the IDENTICAL gap to feeding the raw ABR straight in — proves the OFF path
    // changes not one nanosecond of send timing at the gap level, across the ABR range.
    func testFloorZeroGapByteIdenticalToRawABR() {
        for abr in [0, 4_000_000, 8_000_000, 40_000_000] {
            XCTAssertEqual(gap(target(false, abr, deltaFloor: 0)), gap(abr), "floor 0 gap must equal raw-ABR gap")
        }
    }
}
#endif
