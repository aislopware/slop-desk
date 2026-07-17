#if canImport(AudioToolbox)
import AudioToolbox
import Foundation
import OSLog
import SlopDeskVideoProtocol

/// Building the decoder for a received ``AudioStreamConfig`` failed — the config is dropped
/// (validate-then-drop; the host keeps re-sending, so a transient failure self-heals).
public enum AudioStreamDecoderError: Error {
    /// `AudioConverterNew` refused the format (no AAC-ELD decoder available).
    case converterCreationFailed(OSStatus)
    /// The AAC magic cookie was rejected — without it the converter would emit garbage.
    case magicCookieRejected(OSStatus)
}

/// Decodes one wire audio payload (an AAC-ELD access unit, or a block of s16le PCM) to
/// interleaved Float32 — the ``AudioJitterBuffer``'s sample format. One instance per locked
/// ``AudioStreamConfig``; a config CHANGE rebuilds the decoder (the session's job).
///
/// PUBLIC because the loopback harness (`slopdesk-loopback-validate --audio`) drives the real
/// AudioConverter through it headlessly — AudioConverter is an in-process codec (no
/// window-server / TCC), safe off-GUI. ⚠️ XCTest still NEVER constructs one (repo hang-safety
/// discipline); unit coverage stays on the pure ring/router types.
///
/// `@unchecked Sendable`: the converter and its scratch buffers are touched from exactly ONE
/// serial queue (the session's `audioQueue`; the loopback's single thread) — the annotation only
/// lets the reference cross the actor → queue dispatch, mirroring ``VideoDecoder``.
public final class AudioStreamDecoder: @unchecked Sendable {
    private static let log = Logger(subsystem: "slopdesk.video.client", category: "AudioStreamDecoder")

    /// The config this decoder was built for (the session compares a re-sent config against it).
    public let config: AudioStreamConfig

    private let channels: Int
    /// `nil` for ``AudioWireFormat/pcmS16LE`` (no codec — just a sample-format convert).
    private var converter: AudioConverterRef?

    /// Output frames one `decode` call can produce. AAC-ELD emits 480 frames per access unit at
    /// 48 kHz; ×4 headroom costs a few KB and makes a converter that flushes more inert.
    private static let maxOutputFrames = 1920

    /// Decoded-sample scratch, reused across calls (decode runs on one serial queue).
    private let scratch: UnsafeMutablePointer<Float>
    private let scratchCapacity: Int

    // In-flight input for the converter's pull callback (valid only inside one
    // `AudioConverterFillComplexBuffer` call; the callback runs synchronously within it).
    private var inflightBytes: UnsafeRawPointer?
    private var inflightByteCount: UInt32 = 0
    /// Heap-allocated (not a stored struct property) so the pull callback can hand the converter
    /// a pointer with a guaranteed-stable address.
    private let inflightPacket: UnsafeMutablePointer<AudioStreamPacketDescription>
    private var inflightServed = false

    /// The pull callback's "that was the whole packet" status: any non-zero value private to
    /// this decoder — `AudioConverterFillComplexBuffer` surfaces it once input runs out, which
    /// is the NORMAL end of a one-packet decode, not an error.
    private static let noMoreData: OSStatus = -1

    public init(config: AudioStreamConfig) throws {
        self.config = config
        channels = Int(config.channels)
        scratchCapacity = Self.maxOutputFrames * channels
        scratch = UnsafeMutablePointer<Float>.allocate(capacity: scratchCapacity)
        inflightPacket = UnsafeMutablePointer<AudioStreamPacketDescription>.allocate(capacity: 1)
        switch config.format {
        case .pcmS16LE:
            converter = nil
        case .aacEld:
            var inDesc = AudioStreamBasicDescription(
                mSampleRate: Float64(config.sampleRate),
                mFormatID: kAudioFormatMPEG4AAC_ELD,
                mFormatFlags: 0,
                mBytesPerPacket: 0,
                mFramesPerPacket: 480,
                mBytesPerFrame: 0,
                mChannelsPerFrame: UInt32(config.channels),
                mBitsPerChannel: 0,
                mReserved: 0,
            )
            var outDesc = Self.floatPCMDescription(sampleRate: Float64(config.sampleRate), channels: channels)
            var ref: AudioConverterRef?
            let status = AudioConverterNew(&inDesc, &outDesc, &ref)
            guard status == noErr, let ref else {
                scratch.deallocate()
                inflightPacket.deallocate()
                throw AudioStreamDecoderError.converterCreationFailed(status)
            }
            if !config.cookie.isEmpty {
                let cookieStatus = config.cookie.withUnsafeBytes { raw -> OSStatus in
                    guard let base = raw.baseAddress else { return noErr }
                    return AudioConverterSetProperty(
                        ref,
                        kAudioConverterDecompressionMagicCookie,
                        UInt32(raw.count),
                        base,
                    )
                }
                guard cookieStatus == noErr else {
                    AudioConverterDispose(ref)
                    scratch.deallocate()
                    inflightPacket.deallocate()
                    throw AudioStreamDecoderError.magicCookieRejected(cookieStatus)
                }
            }
            converter = ref
        }
    }

    deinit {
        if let converter { AudioConverterDispose(converter) }
        scratch.deallocate()
        inflightPacket.deallocate()
    }

    /// Decodes one wire frame payload to interleaved Float32. Empty result = drop the frame
    /// (corrupt payload / converter hiccup) — the jitter ring conceals a missing frame anyway,
    /// so a decode miss is deliberately indistinguishable from wire loss.
    public func decode(_ payload: Data) -> [Float] {
        switch config.format {
        case .pcmS16LE: decodePCM(payload)
        case .aacEld: decodeAACELD(payload)
        }
    }

    /// Interleaved Float32 output description (the jitter ring / output AU format).
    static func floatPCMDescription(sampleRate: Float64, channels: Int) -> AudioStreamBasicDescription {
        let bytesPerFrame = UInt32(MemoryLayout<Float>.size * channels)
        return AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: bytesPerFrame,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32,
            mReserved: 0,
        )
    }

    /// s16le → Float32: a pure sample-format convert. A payload that is not whole interleaved
    /// frames is corrupt → drop (validate-then-drop; never a partial frame into the ring).
    private func decodePCM(_ payload: Data) -> [Float] {
        let bytesPerFrame = 2 * channels
        guard !payload.isEmpty, payload.count.isMultiple(of: bytesPerFrame) else { return [] }
        let sampleCount = payload.count / 2
        var out = [Float](repeating: 0, count: sampleCount)
        payload.withUnsafeBytes { raw in
            for i in 0..<sampleCount {
                // Little-endian on the wire; assemble bytes (a raw slice offers no alignment).
                let lo = UInt16(raw[i * 2])
                let hi = UInt16(raw[i * 2 + 1])
                out[i] = Float(Int16(bitPattern: hi << 8 | lo)) / 32768.0
            }
        }
        return out
    }

    /// One AAC-ELD access unit through the converter. The converter keeps decoder state across
    /// calls (frames of one stream), so it is NOT reset per frame — only after an error, so a
    /// corrupt access unit cannot poison every later frame.
    private func decodeAACELD(_ payload: Data) -> [Float] {
        guard let converter, !payload.isEmpty else { return [] }
        return payload.withUnsafeBytes { raw -> [Float] in
            guard let base = raw.baseAddress else { return [] }
            inflightBytes = base
            inflightByteCount = UInt32(raw.count)
            inflightPacket.pointee = AudioStreamPacketDescription(
                mStartOffset: 0,
                mVariableFramesInPacket: 0,
                mDataByteSize: UInt32(raw.count),
            )
            inflightServed = false
            var ioFrames = UInt32(Self.maxOutputFrames)
            var outBuffers = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: UInt32(channels),
                    mDataByteSize: UInt32(scratchCapacity * MemoryLayout<Float>.size),
                    mData: UnsafeMutableRawPointer(scratch),
                ),
            )
            let status = AudioConverterFillComplexBuffer(
                converter,
                Self.pullInput,
                Unmanaged.passUnretained(self).toOpaque(),
                &ioFrames,
                &outBuffers,
                nil,
            )
            inflightBytes = nil
            // `noMoreData` is the pull callback reporting the single packet is exhausted — the
            // normal end of a one-packet decode; whatever frames were produced are valid.
            guard status == noErr || status == Self.noMoreData, ioFrames > 0 else {
                if status != noErr, status != Self.noMoreData {
                    Self.log.error("AAC-ELD decode failed (\(status)) — resetting converter")
                    AudioConverterReset(converter)
                }
                return []
            }
            return Array(UnsafeBufferPointer(start: scratch, count: Int(ioFrames) * channels))
        }
    }

    /// The converter's input pull: serves the ONE in-flight access unit, then reports
    /// end-of-data (``noMoreData``) so the converter returns what it decoded. A zero-capture
    /// closure (C function pointer); the decoder rides in as the `userData` context.
    private static let pullInput: AudioConverterComplexInputDataProc = { _, ioNumPackets, ioData, outDesc, userData in
        guard let userData else {
            ioNumPackets.pointee = 0
            return AudioStreamDecoder.noMoreData
        }
        let decoder = Unmanaged<AudioStreamDecoder>.fromOpaque(userData).takeUnretainedValue()
        guard !decoder.inflightServed, let bytes = decoder.inflightBytes else {
            ioNumPackets.pointee = 0
            return AudioStreamDecoder.noMoreData
        }
        decoder.inflightServed = true
        ioNumPackets.pointee = 1
        ioData.pointee.mNumberBuffers = 1
        ioData.pointee.mBuffers.mNumberChannels = UInt32(decoder.channels)
        ioData.pointee.mBuffers.mDataByteSize = decoder.inflightByteCount
        ioData.pointee.mBuffers.mData = UnsafeMutableRawPointer(mutating: bytes)
        outDesc?.pointee = decoder.inflightPacket
        return noErr
    }
}
#endif
