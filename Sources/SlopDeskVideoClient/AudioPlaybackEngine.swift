import CSlopDeskFFI
import Foundation

/// The face of client audio playback. Every decision behind it is Rust's.
///
/// Three files were behind this one: `AudioPlaybackEngine` (205 lines of `AUHAL`/`RemoteIO` — the
/// component description, the stream format write, the render callback, the iOS `AVAudioSession`
/// category) and `AudioJitterBuffer` (363 more — a Swift face over the jitter stage, a lock-free
/// `AudioSampleRing`, and an `AudioPlaybackPump` that asked the stage for its budgets and moved
/// samples between the two). All of it is `rust/slopdesk-audio-out` now: the ring is `rtrb`, the
/// pump is arithmetic the stage already published, and the output unit is `cpal`.
///
/// That crate is `forbid(unsafe_code)`, which is the point of picking `cpal` over another
/// `AudioToolbox` wrapper: the one real-time deadline in the client now carries no hand-written
/// unsafe at all.
///
/// **One behaviour this port had to ADD rather than move.** `AUHAL` converted from the wire rate to
/// the device's own; `cpal` does not, so the far side resamples on the producer side. On every Mac
/// and iOS output this has been pointed at, the device offers 48 kHz and the conversion is literally
/// a copy — it matters only on a device pinned to 44.1 kHz, where the alternative is playing
/// everything a semitone sharp.
///
/// Threading: NO internal threading past the handle. Every method runs on the CALLER's queue — the
/// client session confines this to its serial audio queue — and the render thread holds the other
/// half of a wait-free SPSC hand-off and nothing else. It never reaches the stage, so there is no
/// lock for a real-time deadline to miss. `@unchecked Sendable` is the promise that carries that
/// confinement past the compiler, unchanged from the Swift original.
public final class AudioPlaybackEngine: @unchecked Sendable {
    /// The wire rate this engine was locked to. A config that moves it REBUILDS the engine: the
    /// resampler's ratio, the hand-off's capacity and the device's stream all derive from the pair.
    public let sampleRate: Double
    /// The wire channel count this engine was locked to.
    public let channels: Int

    private var handle: OpaquePointer?

    public init(sampleRate: Double, channels: Int) {
        self.sampleRate = sampleRate
        self.channels = max(1, channels)
        handle = slopdesk_audio_player_new(sampleRate, self.channels)
    }

    deinit {
        // Freeing stops the stream and JOINS its device thread, so nothing outlives this call.
        if let handle { slopdesk_audio_player_free(handle) }
    }

    /// Whether a real output device was found. False means this engine is permanently mute — which
    /// is what a headless machine answers, and is not a fault to report.
    public var hasDevice: Bool {
        guard let handle else { return false }
        return slopdesk_audio_player_has_device(handle)
    }

    /// One decoded frame, keyed by its wire sequence. The stage re-orders and late-drops on it.
    public func enqueue(seq: UInt32, samples: [Float]) {
        guard let handle, !samples.isEmpty else { return }
        samples.withUnsafeBufferPointer { buffer in
            slopdesk_audio_player_enqueue(handle, seq, buffer.baseAddress, buffer.count)
        }
    }

    /// Starts output. Idempotent — which is what lets the host's ~1 s config re-send restart a
    /// stopped engine without this caller tracking whether it is already running.
    public func start() {
        guard let handle else { return }
        slopdesk_audio_player_start(handle)
    }

    /// Stops output, keeping the device for a cheap restart. Idempotent.
    public func stop() {
        guard let handle else { return }
        slopdesk_audio_player_stop(handle)
    }

    /// Drops everything buffered — the pane falls silent on the next render pass rather than after
    /// a ring drain, which is what "silent NOW" can honestly mean.
    public func flushBuffered() {
        guard let handle else { return }
        slopdesk_audio_player_flush(handle)
    }

    /// Retires this engine for good. A retired engine is inert, not broken: every method above
    /// answers a no-op afterwards, so a racing enqueue from an in-flight decode cannot fault.
    public func invalidate() {
        guard let handle else { return }
        self.handle = nil
        slopdesk_audio_player_free(handle)
    }
}
