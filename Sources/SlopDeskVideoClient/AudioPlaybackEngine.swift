#if canImport(AudioToolbox)
import AudioToolbox
import Foundation
import OSLog
#if os(iOS) && canImport(AVFAudio)
import AVFAudio
#endif

/// The client's audio OUTPUT: one system output AudioUnit (macOS `kAudioUnitSubType_HALOutput`,
/// iOS `kAudioUnitSubType_RemoteIO`) whose render callback consumes interleaved Float32 from a
/// lock-free ``AudioSampleRing``. One instance per locked `(sampleRate, channels)` — a config
/// change that moves either rebuilds the engine (the session's job).
///
/// ⚠️ **GUI/DEVICE-ONLY**: starting the AU opens a real HAL/RemoteIO I/O proc — NEVER
/// constructed in a test (repo hang-safety; same class as `SCStream`/VT sessions). The buffering
/// POLICY it drives (``AudioJitterBuffer`` + ``AudioPlaybackPump`` + ``AudioSampleRing``) is
/// pure and IS unit-tested.
///
/// Threading contract (`@unchecked Sendable`):
/// - The PRODUCER side (``enqueue(seq:samples:)`` / ``flushBuffered()``) and the AU lifecycle
///   (``start()`` / ``stop()`` / ``invalidate()``) are confined to the session's serial
///   `audioQueue` — the same single-owner discipline as ``VideoDecoder`` on the decode queue.
/// - The render callback shares ONLY `ring` with the producer — a wait-free SPSC hand-off.
///   The real-time thread must never block on a lock a preemptible pusher can hold (priority
///   inversion = audible dropout), so there is NO lock anywhere on this path.
final class AudioPlaybackEngine: @unchecked Sendable {
    private let log = Logger(subsystem: "slopdesk.video.client", category: "AudioPlaybackEngine")

    /// The stream format the engine was built for (the session compares a new config against it).
    let sampleRate: Double
    let channels: Int

    /// Producer-side jitter stage + hand-off pump. audioQueue-confined — the render callback
    /// never touches it (a mutable struct read cross-thread would violate exclusivity anyway).
    private var pump: AudioPlaybackPump
    /// The SPSC hand-off the render callback drains — the ONE thing shared with the real-time
    /// thread. Held strongly here: ``invalidate()`` / `deinit` stop the AU (AudioOutputUnitStop
    /// waits out an in-flight render) before this reference — and with it the ring's storage —
    /// can go away, so the unretained refcon never dangles.
    private let ring: AudioSampleRing

    /// The output AU (`nil` until the first ``start()`` builds it; `nil` again after
    /// ``invalidate()``). audioQueue-confined.
    private var unit: AudioComponentInstance?
    private var running = false

    init(sampleRate: Double, channels: Int) {
        self.sampleRate = sampleRate
        self.channels = max(1, channels)
        let stage = AudioJitterBuffer(channels: self.channels)
        // Hand-off STORAGE = a high-water worth of ~10 ms frames, but the pump tops the fill up
        // only to the stage's target depth: the render side needs ~2 frames of headroom, and any
        // backlog beyond that must stay STAGED, where the pump's combined depth bound can still
        // shed it (samples committed to the ring are the consumer's — the producer can never
        // take them back). The spare capacity is slack so a flush's not-yet-skipped span never
        // blocks the re-primed hand-off.
        let samplesPerFrame = max(1, Int(sampleRate / 100)) * self.channels
        ring = AudioSampleRing(capacity: stage.highWaterFrames * samplesPerFrame)
        pump = AudioPlaybackPump(stage: stage, ring: ring, samplesPerFrame: samplesPerFrame)
    }

    deinit {
        // Defensive teardown for a dropped-without-invalidate reference: the render callback
        // holds `self` unretained, so the unit must stop (AudioOutputUnitStop waits out an
        // in-flight render cycle) before the memory goes away.
        invalidate()
    }

    /// One decoded frame from the audio decode queue → the jitter stage (reorder/late/overflow
    /// policy lives in ``AudioJitterBuffer``), then whatever is playable hands off to the ring.
    func enqueue(seq: UInt32, samples: [Float]) {
        pump.enqueue(seq: seq, samples: samples)
    }

    /// Drops everything buffered (local disable) — playback falls silent NOW, not after the
    /// ring drains.
    func flushBuffered() {
        pump.flush()
    }

    /// Starts output (idempotent). Builds the AU lazily on first start; a build/start failure
    /// leaves the engine silent-but-inert (logged) and the next start retries — audio is an
    /// accessory, never worth failing the session over.
    func start() {
        guard !running else { return }
        if unit == nil { unit = makeOutputUnit() }
        guard let unit else { return }
        #if os(iOS) && canImport(AVFAudio)
        // Playback category so the stream is audible with the mute switch on; mix — a coding
        // tool must not silence the user's own audio. Best-effort (a refusal just means the
        // system default category rules apply).
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        let status = AudioOutputUnitStart(unit)
        guard status == noErr else {
            log.error("audio output start failed (\(status))")
            return
        }
        running = true
    }

    /// Stops output (idempotent). The AU is kept for a cheap restart; the ring keeps its
    /// frontier so a re-enable resumes cleanly.
    func stop() {
        guard running, let unit else { return }
        AudioOutputUnitStop(unit)
        running = false
    }

    /// Full teardown (session bye/stop/config rebuild): stop + dispose the AU. The engine is
    /// dead afterwards — the session builds a fresh one for the next config.
    func invalidate() {
        stop()
        guard let unit else { return }
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        self.unit = nil
    }

    #if os(macOS)
    /// AUHAL — the device output unit (defaults to the system default output device).
    private static let outputSubType = kAudioUnitSubType_HALOutput
    #else
    /// RemoteIO — the iOS hardware I/O unit.
    private static let outputSubType = kAudioUnitSubType_RemoteIO
    #endif

    /// Builds + initialises the output AU: interleaved Float32 on input scope bus 0 (the ring's
    /// exact sample layout — one buffer per render, no deinterleave step) and the pull-from-ring
    /// render callback. `nil` on any refusal (logged; the caller degrades to silence).
    private func makeOutputUnit() -> AudioComponentInstance? {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: Self.outputSubType,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0,
        )
        guard let component = AudioComponentFindNext(nil, &desc) else {
            log.error("no system output audio component")
            return nil
        }
        var instance: AudioComponentInstance?
        var status = AudioComponentInstanceNew(component, &instance)
        guard status == noErr, let unit = instance else {
            log.error("audio output instantiation failed (\(status))")
            return nil
        }
        var format = AudioStreamDecoder.floatPCMDescription(sampleRate: sampleRate, channels: channels)
        status = AudioUnitSetProperty(
            unit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input,
            0,
            &format,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
        )
        if status == noErr {
            // Unretained refCon: `invalidate()` (or deinit) stops the unit before this engine
            // can be released, so the callback never sees a dangling pointer.
            var callback = AURenderCallbackStruct(
                inputProc: Self.renderCallback,
                inputProcRefCon: Unmanaged.passUnretained(self).toOpaque(),
            )
            status = AudioUnitSetProperty(
                unit,
                kAudioUnitProperty_SetRenderCallback,
                kAudioUnitScope_Input,
                0,
                &callback,
                UInt32(MemoryLayout<AURenderCallbackStruct>.size),
            )
        }
        if status == noErr { status = AudioUnitInitialize(unit) }
        guard status == noErr else {
            log.error("audio output configuration failed (\(status))")
            AudioComponentInstanceDispose(unit)
            return nil
        }
        return unit
    }

    /// The real-time render pull: a wait-free SPSC consume plus a zero-fill of the shortfall
    /// (priming / underrun silence — the conceal the jitter policy calls for). No lock, no
    /// allocation, no syscall: the render deadline can never wait on the (preemptible) decode
    /// side, so a busy pusher costs zero render-thread stall.
    private static let renderCallback: AURenderCallback = { inRefCon, _, _, _, _, ioData in
        guard let ioData else { return noErr }
        let engine = Unmanaged<AudioPlaybackEngine>.fromOpaque(inRefCon).takeUnretainedValue()
        let buffers = UnsafeMutableAudioBufferListPointer(ioData)
        for buffer in buffers {
            guard let base = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            let out = UnsafeMutableBufferPointer(start: base, count: count)
            let copied = engine.ring.consume(into: out)
            if copied < count { (base + copied).update(repeating: 0, count: count - copied) }
        }
        return noErr
    }
}
#endif
