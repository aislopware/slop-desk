#if os(macOS)
import SlopDeskVideoProtocol
import XCTest
@testable import SlopDeskVideoHost

/// HANG-SAFETY: never touches the AAC arm's lazy `AudioConverter` build (that only happens inside
/// `encode`/`encodePCM`'s AAC path on the first block) — these only construct the encoder object and
/// call `resetConverterState()`/`resetAccumulator()` directly, both safe with a nil converter.
final class AudioStreamEncoderTests: XCTestCase {
    // The AAC arm's converter is nil until the first encoded block; resetConverterState() before
    // that must be a harmless no-op (guard-let, no AudioConverterReset call on a nil converter).
    func testResetConverterStateNoOpBeforeConverterBuilds() {
        let encoder = AudioStreamEncoder(format: .aacEld, bitrateBps: 128_000)
        encoder.resetConverterState() // must not crash / touch AudioToolbox with no converter
    }

    // The PCM arm never builds a converter at all — resetConverterState() must stay a no-op for its
    // whole lifetime.
    func testResetConverterStateNoOpForPCMArm() {
        let encoder = AudioStreamEncoder(format: .pcmS16LE, bitrateBps: 128_000)
        let block = Array(
            repeating: Float(0),
            count: AudioStreamEncoder.samplesPerFrame * AudioStreamEncoder.channelCount,
        )
        _ = encoder.encodePCM(block, frameCount: AudioStreamEncoder.samplesPerFrame)
        encoder.resetConverterState() // still a no-op — PCM never builds `converter`
    }

    // resetAccumulator + resetConverterState together (the actual OFF→ON call site pairing) must
    // drop the PCM sub-block remainder without disturbing config/format state.
    func testResetAccumulatorAndConverterStateTogetherDropsRemainder() {
        let encoder = AudioStreamEncoder(format: .pcmS16LE, bitrateBps: 128_000)
        // Push a partial (sub-480) block so `pending` retains a remainder.
        let partial = Array(repeating: Float(0.5), count: 240 * AudioStreamEncoder.channelCount)
        XCTAssertEqual(encoder.encodePCM(partial, frameCount: 240), [], "a sub-block remainder produces no frame yet")

        encoder.resetAccumulator()
        encoder.resetConverterState()

        // After the reset, the OLD partial block must not silently complete a frame once combined
        // with fresh samples — pushing another 240-frame half must NOT yield an encoded block
        // (proves the stale 240 was dropped, not carried over to combine with the fresh 240).
        let fresh = Array(repeating: Float(-0.5), count: 240 * AudioStreamEncoder.channelCount)
        XCTAssertEqual(
            encoder.encodePCM(fresh, frameCount: 240),
            [],
            "the pre-reset remainder must not have survived to complete this block",
        )
    }
}
#endif
