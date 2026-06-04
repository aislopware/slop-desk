#if canImport(VideoToolbox)
import XCTest
@testable import RworkVideoClient
import RworkVideoProtocol

/// BUG-I regression: the decoder must NOT tear down + recreate its VTDecompressionSession
/// on a byte-identical keyframe.
///
/// `VideoDecoder.decode()` previously called `configure(parameterSets:)` on EVERY
/// keyframe — including the ~1s heartbeat IDR and every forced-recovery IDR — which
/// invalidates and recreates the `VTDecompressionSession`, stalling an otherwise-healthy
/// stream roughly once a second. The fix gates the reconfigure on
/// `VideoDecoder.needsReconfigure(current:incoming:)`: rebuild only when the extracted
/// parameter sets actually differ. That decision is pure (`Equatable` value compare, no
/// VideoToolbox session) so it is unit-testable without driving a real decode.
final class VideoDecoderReuseTests: XCTestCase {
    private func sets(_ vps: [UInt8], _ sps: [UInt8], _ pps: [UInt8]) -> HEVCParameterSets.ParameterSets {
        HEVCParameterSets.ParameterSets(vps: Data(vps), sps: Data(sps), pps: Data(pps))
    }

    func testFirstKeyframeAlwaysReconfigures() {
        // No session yet (current == nil) → must build it.
        XCTAssertTrue(VideoDecoder.needsReconfigure(current: nil, incoming: sets([0x40], [0x42], [0x44])))
    }

    func testIdenticalParameterSetsDoNotReconfigure() {
        let running = sets([0x40, 0x01], [0x42, 0x02], [0x44, 0x03])
        // The heartbeat / recovery IDR carries byte-identical VPS/SPS/PPS → reuse session.
        let identicalIDR = sets([0x40, 0x01], [0x42, 0x02], [0x44, 0x03])
        XCTAssertEqual(running, identicalIDR) // sanity: value equality
        XCTAssertFalse(VideoDecoder.needsReconfigure(current: running, incoming: identicalIDR))
    }

    func testChangedSPSReconfigures() {
        let running = sets([0x40], [0x42, 0x02], [0x44])
        // A real resolution change carries a different SPS → must rebuild the session.
        let resized = sets([0x40], [0x42, 0x99], [0x44])
        XCTAssertTrue(VideoDecoder.needsReconfigure(current: running, incoming: resized))
    }

    func testChangedVPSOrPPSReconfigures() {
        let running = sets([0x40], [0x42], [0x44])
        XCTAssertTrue(VideoDecoder.needsReconfigure(current: running, incoming: sets([0x4F], [0x42], [0x44])))
        XCTAssertTrue(VideoDecoder.needsReconfigure(current: running, incoming: sets([0x40], [0x42], [0x4F])))
    }

    // MARK: - FIX #3: hard decode failure forces a byte-identical keyframe to rebuild

    /// FIX #3: on a HARD decode failure the session is invalidated; the next keyframe —
    /// even one whose VPS/SPS/PPS are BYTE-IDENTICAL to the dead session's — must
    /// reconfigure (rebuild a fresh `VTDecompressionSession`). Otherwise, on a fixed
    /// capture size the forced recovery IDR carries the
    /// same parameter sets, `needsReconfigure` returns false, and the malfunctioning
    /// session is reused forever — freezing the pane permanently.
    ///
    /// Modelled WITHOUT a real session: seed the cached sets (a healthy decoder), then
    /// `invalidateSession()` (the hard-failure path) must clear the cache so the next
    /// identical keyframe is seen as `current == nil` ⇒ reconfigure.
    func testHardFailureForcesByteIdenticalKeyframeToRebuild() {
        let decoder = VideoDecoder { _ in }
        let running = sets([0x40, 0x01], [0x42, 0x02], [0x44, 0x03])
        decoder.seedCachedParameterSetsForTesting(running)

        // Healthy steady state: a byte-identical recovery/heartbeat IDR reuses the session.
        let identicalIDR = sets([0x40, 0x01], [0x42, 0x02], [0x44, 0x03])
        XCTAssertFalse(
            VideoDecoder.needsReconfigure(current: decoder.cachedParameterSetsForTesting, incoming: identicalIDR),
            "without a failure a byte-identical keyframe must REUSE (BUG-I preserved)"
        )

        // Simulate a hard decode failure → the VIDEO-CLIENT-1 catch invalidates the session.
        decoder.invalidateSession()
        XCTAssertNil(decoder.cachedParameterSetsForTesting, "invalidateSession clears the cached sets")

        // Now the byte-identical recovery IDR MUST reconfigure (rebuild the session).
        XCTAssertTrue(
            VideoDecoder.needsReconfigure(current: decoder.cachedParameterSetsForTesting, incoming: identicalIDR),
            "after a hard failure a byte-identical keyframe must REBUILD the session"
        )
    }

    /// FIX #3 negative control: WITHOUT a failure (no `invalidateSession`), a byte-identical
    /// keyframe still reuses — the healthy heartbeat-IDR path (BUG-I) is untouched.
    func testNoFailureKeepsByteIdenticalKeyframeReusing() {
        let decoder = VideoDecoder { _ in }
        let running = sets([0x40], [0x42, 0x02], [0x44])
        decoder.seedCachedParameterSetsForTesting(running)
        let identicalIDR = sets([0x40], [0x42, 0x02], [0x44])
        XCTAssertFalse(
            VideoDecoder.needsReconfigure(current: decoder.cachedParameterSetsForTesting, incoming: identicalIDR),
            "no failure ⇒ byte-identical keyframe reuses the live session"
        )
    }
}
#endif
