#if os(macOS)
import CoreMedia
import CSlopDeskFFI
import Foundation
import SlopDeskVideoProtocol

/// The face of the app-audio encoder. Every decision behind it is Rust's.
///
/// This was 395 lines, of which about forty were rule and the rest were `AudioConverter` bookkeeping
/// — a converter built lazily, its magic cookie fetched through a two-call size-then-read, an
/// interleaved Float32 accumulator carrying the sub-block remainder between capture buffers, a
/// `AudioConverterComplexInputDataProc` walking a cursor over that accumulator, and a channel fold
/// from whatever `ScreenCaptureKit` delivered down to stereo. All of it is
/// `rust/slopdesk-apple-audio` and `slopdesk_video::audio_source` now.
///
/// The old header carried a HANG-SAFETY warning: XCTest must never reach the AAC arm, because
/// building a real `AudioConverter` under the test runner was the failure mode, so the proof lived
/// in `slopdesk-loopback-validate --audio` instead of in a test. That warning is void — the round
/// trip is `cargo test` now (`slopdesk-apple-audio`'s `the_aac_pair_decodes_what_it_encoded_to_the_
/// wire_cadence` builds both converters and asserts the wire cadence), and the loopback's `--audio`
/// arm went with it.
///
/// Threading: NO internal threading. Every method runs on the CALLER's queue — the live path is the
/// capturer's dedicated audio sample-handler queue, serialised by the session's lane lock — which is
/// the single-owner discipline the far side's handle requires.
public final class AudioStreamEncoder {
    /// Fixed wire sample rate (Hz). The SCStream tap is configured to exactly this through
    /// `SlopDeskCaptureDesc.audio_sample_rate`, and the far side derives its block cadence from the
    /// same number — which is why it is one door and not two constants.
    public static let sampleRate = UInt32(slopdesk_audio_source_constant(0))
    /// Fixed wire channel count (interleaved stereo).
    public static let channelCount = Int(slopdesk_audio_source_constant(1))
    /// Samples per encoded frame per channel: 480 @ 48 kHz = 10 ms — the AAC-ELD 480-frame variant,
    /// and the PCM chunk size, so both arms share one wire cadence.
    public static let samplesPerFrame = Int(slopdesk_audio_source_constant(2))

    /// What the C callback's context points at: the payloads completed by one push.
    ///
    /// A class rather than the array's address, because the door's terms say the context must
    /// outlive the handle, and an `inout` array's address does not survive a reallocation.
    private final class Sink {
        var payloads: [Data] = []
    }

    private let sink = Sink()
    private var handle: OpaquePointer?

    public init(format: AudioWireFormat, bitrateBps: Int) {
        handle = slopdesk_audio_encoder_new(format.rawValue, UInt32(clamping: bitrateBps))
    }

    deinit {
        if let handle { slopdesk_audio_encoder_free(handle) }
    }

    /// The wire config the client needs to decode this stream, or nil while there is none.
    ///
    /// nil until the first frame can be produced — the PCM arm answers from init, the AAC arm once
    /// its converter has built — and the sender holds its config packet until this is non-nil.
    public var config: AudioStreamConfig? {
        guard let handle else { return nil }
        var raw = SlopDeskAudioEncoderConfig()
        guard slopdesk_audio_encoder_config(handle, &raw) else { return nil }
        guard let format = AudioWireFormat(rawValue: raw.format) else { return nil }
        var cookie = Data()
        if raw.cookie_len > 0 {
            var bytes = [UInt8](repeating: 0, count: raw.cookie_len)
            let written = bytes.withUnsafeMutableBufferPointer { buffer in
                slopdesk_audio_encoder_cookie(handle, buffer.baseAddress, buffer.count)
            }
            guard written > 0, written <= bytes.count else { return nil }
            cookie = Data(bytes.prefix(written))
        }
        return AudioStreamConfig(
            format: format,
            sampleRate: raw.sample_rate,
            channels: raw.channels,
            cookie: cookie,
        )
    }

    /// Whether the converter refused to build: a permanently silent lane, not a transient.
    public var hasFailed: Bool {
        guard let handle else { return true }
        return slopdesk_audio_encoder_failed(handle)
    }

    /// Drops the sub-block remainder AND the codec's carried state — the enable transition.
    ///
    /// One call where the Swift original had two. `resetAccumulator()` and `resetConverterState()`
    /// were only ever called together, one line apart, and a caller that reset one without the other
    /// would emit a fresh block continuing a bit reservoir from before an arbitrarily long gap.
    public func reset() {
        guard let handle else { return }
        slopdesk_audio_encoder_reset(handle)
    }

    /// Live-path entry: one capture buffer in, zero or more wire payloads out.
    ///
    /// A short buffer completes none, and a buffer whose format is not the configured Float32 LPCM
    /// is DROPPED rather than reinterpreted — the far side validates before it reads a sample.
    public func encode(sampleBuffer: CMSampleBuffer) -> [Data] {
        guard let handle else { return [] }
        sink.payloads.removeAll(keepingCapacity: true)
        let context = Unmanaged.passUnretained(sink).toOpaque()
        _ = slopdesk_audio_encoder_push_sample_buffer(
            handle,
            Unmanaged.passUnretained(sampleBuffer).toOpaque(),
            { context, bytes, len in
                guard let context, let bytes, len > 0 else { return }
                // The bytes are borrowed for THIS CALL. `Data(bytes:count:)` is the copy the door's
                // terms require, and at ~160 bytes per 10 ms frame it is not a cost worth a shape.
                let sink = Unmanaged<Sink>.fromOpaque(context).takeUnretainedValue()
                sink.payloads.append(Data(bytes: bytes, count: len))
            },
            context,
        )
        return sink.payloads
    }
}
#endif
