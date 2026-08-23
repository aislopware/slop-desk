import CSlopDeskFFI
import Foundation
import SlopDeskVideoProtocol

/// The framework refused this config. One case where there were three.
///
/// `unsupportedFormat`, `converterCreateFailed` and `cookieRejected` all described the same thing to
/// every catch site — no decoder for this config — and the one caller matched none of them: it logs
/// "audio config rejected" and drops the config, because the host re-sends it about a second apart
/// and a transient refusal self-heals on the next copy. A distinction nothing reads is not a
/// distinction to carry across a boundary.
public struct AudioStreamDecoderError: Error {
    /// What the far side answered, for the log line. Zero when this build does not speak the format.
    public let status: OSStatus
}

/// The face of the app-audio decoder. Every decision behind it is Rust's.
///
/// This was 245 lines: an `AudioConverter` built from the config, the magic cookie pushed into it as
/// a decompression property, an `AudioConverterComplexInputDataProc` handing over one access unit
/// with a packet description whose address had to outlive the callback, and — for the PCM arm — a
/// sample-format convert that already existed in Rust and was called through a door. All of it is
/// `rust/slopdesk-apple-audio` now, and the door answers samples.
///
/// Threading: NO internal threading. Every method runs on the CALLER's queue — the client session
/// confines this to its serial audio queue, which is the single-owner discipline the far side's
/// handle requires. `@unchecked Sendable` is the promise that carries that confinement past the
/// compiler, and it is unchanged from the Swift original — a decoder is BUILT on the audio queue,
/// installed onto the session actor, and then only ever called back on the queue that built it.
public final class AudioStreamDecoder: @unchecked Sendable {
    /// Interleaved channel count this decoder answers, for sizing the destination.
    private let channels: Int
    private var handle: OpaquePointer?
    /// The destination, reused across calls. One decode answers at most four wire blocks' worth of
    /// samples — the far side's own ceiling — so this is sized once and never grows.
    private var scratch: [Float]

    /// Builds a decoder for one wire config, or throws the framework's refusal.
    ///
    /// The refusal is a real answer, not an error to retry: "this machine has no AAC-ELD decoder"
    /// does not become true a frame later. The caller drops the config and lets the host's ~1 s
    /// re-send decide whether to try again.
    public init(config: AudioStreamConfig) throws {
        channels = max(1, Int(config.channels))
        scratch = [Float](repeating: 0, count: Self.maxSamples(channels: channels))
        var cookie = [UInt8](config.cookie)
        handle = cookie.withUnsafeMutableBufferPointer { buffer in
            slopdesk_audio_decoder_new(
                config.format.rawValue,
                config.sampleRate,
                config.channels,
                buffer.baseAddress,
                buffer.count,
            )
        }
        guard handle != nil else { throw AudioStreamDecoderError(status: 0) }
    }

    deinit {
        if let handle { slopdesk_audio_decoder_free(handle) }
    }

    /// One wire payload in, interleaved normalised floats out.
    ///
    /// An empty answer means DROP: a corrupt access unit, a payload that is not a whole number of
    /// interleaved frames, or a decoder that refused. The caller conceals it exactly as it conceals
    /// wire loss, which is the only thing it could do with a partial one.
    public func decode(_ payload: Data) -> [Float] {
        guard let handle, !payload.isEmpty else { return [] }
        let written = payload.withUnsafeBytes { bytes -> Int in
            guard let base = bytes.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return scratch.withUnsafeMutableBufferPointer { room in
                slopdesk_audio_decoder_decode(handle, base, bytes.count, room.baseAddress, room.count)
            }
        }
        // Above the destination is the door's "nothing written, here is the room needed". It cannot
        // happen — the scratch is the far side's own ceiling — so treating it as a drop is right.
        guard written > 0, written <= scratch.count else { return [] }
        return Array(scratch[..<written])
    }

    /// The far side's per-call ceiling: four wire blocks. Read through the source constants so the
    /// two sides cannot disagree about the block size.
    private static func maxSamples(channels: Int) -> Int {
        Int(slopdesk_audio_source_constant(2)) * channels * 4
    }
}
