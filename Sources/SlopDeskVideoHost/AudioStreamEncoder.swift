#if os(macOS)
import AudioToolbox
import CoreMedia
import Foundation
import OSLog
import SlopDeskVideoProtocol

/// Encodes the SCStream `.audio` tap into ~10 ms wire frames (``AudioChannelMessage`` payloads):
/// AAC-ELD access units via `AudioConverter` (the default — low-delay, ~160 bytes/frame at
/// 128 kbps) or raw interleaved s16le PCM (`SLOPDESK_AUDIO_CODEC=pcm`, the codec-free A/B arm).
///
/// Threading: NO internal threading — every method runs on the CALLER's queue (live path: the
/// capturer's dedicated audio sample-handler queue, serialized by the session's lane lock). The
/// accumulator + converter are therefore plain single-owner state.
///
/// ⚠️ **HANG-SAFETY:** the AAC arm lazily builds an `AudioConverter`, which unit tests must never
/// instantiate — this type is exercised by `slopdesk-loopback-validate --audio` (the real
/// AudioConverter encode→decode proof), not by XCTest. ``encodePCM(_:frameCount:)`` is the
/// headless-testable core the loopback drives directly (no CMSampleBuffer needed).
public final class AudioStreamEncoder {
    /// Fixed wire sample rate (Hz) — the SCStream tap is configured to exactly this
    /// (``WindowCapturer/makeConfiguration(width:height:fps:captureScale:fullRange:)``).
    public static let sampleRate: UInt32 = 48000
    /// Fixed wire channel count (interleaved stereo).
    public static let channelCount = 2
    /// Samples per encoded frame per channel: 480 @ 48 kHz = 10 ms — the AAC-ELD 480-frame
    /// variant, and the PCM chunk size, so both arms share one wire cadence.
    public static let samplesPerFrame = 480

    /// The wire config the client needs to decode this stream. `nil` until the first frame can be
    /// produced (PCM: from init; AAC: once the converter builds and its magic cookie is fetched) —
    /// the sender holds its config packet until this is non-nil.
    public private(set) var config: AudioStreamConfig?

    private let format: AudioWireFormat
    private let bitrateBps: Int
    /// Interleaved Float32 accumulator carrying the sub-frame remainder between capture buffers
    /// (SCK delivery sizes are not multiples of 480).
    private var pending: [Float] = []
    /// The lazily-built AAC-ELD converter (nil for the PCM arm, and until the first AAC frame).
    private var converter: AudioConverterRef?
    /// One-shot failure latch: a converter that cannot build never retries per-buffer (the config
    /// stays nil, the session lane sends nothing — silence, not a log storm).
    private var converterFailed = false
    /// The converter's own worst-case packet size (queried once), capped at the wire payload cap.
    private var maxPacketBytes = 0

    private let log = Logger(subsystem: "slopdesk.video.host", category: "AudioStreamEncoder")
    private static let debugStderr = ProcessInfo.processInfo.environment["SLOPDESK_AUDIO_DEBUG"] == "1"

    public init(format: AudioWireFormat, bitrateBps: Int) {
        self.format = format
        self.bitrateBps = bitrateBps
        if format == .pcmS16LE {
            // The PCM arm needs no codec state — the config is known immediately (empty cookie).
            config = AudioStreamConfig(
                format: .pcmS16LE,
                sampleRate: Self.sampleRate,
                channels: UInt8(Self.channelCount),
                cookie: Data(),
            )
        }
        pending.reserveCapacity(Self.samplesPerFrame * Self.channelCount * 4)
    }

    deinit {
        if let converter { AudioConverterDispose(converter) }
    }

    /// Live-path entry: extract the tap buffer's Float32 PCM, interleave it to the fixed stereo
    /// layout, and run the shared 480-frame chunking/encode. Returns zero or more encoded frame
    /// payloads (a short capture buffer may complete none). A buffer whose format is not the
    /// configured Float32 LPCM is DROPPED (validate-then-drop — SCK is trusted, but a surprise
    /// format must not be reinterpreted as samples).
    public func encode(sampleBuffer: CMSampleBuffer) -> [Data] {
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0,
              CMSampleBufferDataIsReady(sampleBuffer),
              let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee,
              asbd.mFormatID == kAudioFormatLinearPCM,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              asbd.mBitsPerChannel == 32
        else { return [] }
        // Length-check before allocate: the buffer-list copy below is sized by the channel count,
        // so bound it (the tap is configured stereo; anything wider than a sane layout is corrupt).
        let sourceChannels = Int(asbd.mChannelsPerFrame)
        guard sourceChannels >= 1, sourceChannels <= 16 else { return [] }
        let interleavedSource = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0

        // Copy the AudioBufferList out (the block buffer keeps the sample memory alive for the
        // scope of this call). Bound the list at the source channel count.
        let bufferList = AudioBufferList.allocate(maximumBuffers: sourceChannels)
        defer { free(bufferList.unsafeMutablePointer) }
        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: bufferList.unsafeMutablePointer,
            bufferListSize: AudioBufferList.sizeInBytes(maximumBuffers: sourceChannels),
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer,
        )
        guard status == noErr, blockBuffer != nil else { return [] }

        // Interleave into the fixed stereo layout. Mono duplicates into both channels; extra
        // source channels beyond 2 are dropped (the tap is configured stereo — defensive only).
        var interleaved = [Float](repeating: 0, count: frames * Self.channelCount)
        let bytesPerChannel = frames * MemoryLayout<Float>.size
        if interleavedSource {
            guard let buffer = bufferList.first, let data = buffer.mData,
                  Int(buffer.mDataByteSize) >= frames * sourceChannels * MemoryLayout<Float>.size
            else { return [] }
            let source = data.assumingMemoryBound(to: Float.self)
            if sourceChannels == Self.channelCount {
                interleaved.withUnsafeMutableBufferPointer { dest in
                    dest.baseAddress?.update(from: source, count: frames * Self.channelCount)
                }
            } else {
                for frame in 0..<frames {
                    let left = source[frame * sourceChannels]
                    let right = sourceChannels > 1 ? source[frame * sourceChannels + 1] : left
                    interleaved[frame * 2] = left
                    interleaved[frame * 2 + 1] = right
                }
            }
        } else {
            guard bufferList.count >= 1, let leftData = bufferList[0].mData,
                  Int(bufferList[0].mDataByteSize) >= bytesPerChannel
            else { return [] }
            let left = leftData.assumingMemoryBound(to: Float.self)
            var right = UnsafePointer(left) // mono ⇒ duplicate into both wire channels
            if bufferList.count > 1, let rightData = bufferList[1].mData,
               Int(bufferList[1].mDataByteSize) >= bytesPerChannel
            {
                right = UnsafePointer(rightData.assumingMemoryBound(to: Float.self))
            }
            for frame in 0..<frames {
                interleaved[frame * 2] = left[frame]
                interleaved[frame * 2 + 1] = right[frame]
            }
        }
        return encodePCM(interleaved, frameCount: frames)
    }

    /// Drops the sub-block remainder. Called on the enable transition: samples accumulated before
    /// a disable are minutes-stale by re-enable time — splicing them into the first fresh frame
    /// would play a ~10 ms shard of old audio.
    public func resetAccumulator() {
        pending.removeAll(keepingCapacity: true)
    }

    /// HEADLESS core (loopback-driven): append `frameCount` interleaved-stereo sample frames and
    /// encode every completed 480-frame block. `interleaved.count` must be exactly
    /// `frameCount × 2`; a mismatched call is dropped (a length lie must not shear the
    /// channel interleave). Sub-block remainder samples stay accumulated for the next call.
    public func encodePCM(_ interleaved: [Float], frameCount: Int) -> [Data] {
        guard frameCount > 0, interleaved.count == frameCount * Self.channelCount else { return [] }
        pending.append(contentsOf: interleaved)
        var out: [Data] = []
        let blockSamples = Self.samplesPerFrame * Self.channelCount
        while pending.count >= blockSamples {
            // Consume the block UNCONDITIONALLY (even when the AAC arm fails to produce) so a
            // dead converter can never grow the accumulator without bound.
            var block = Array(pending[..<blockSamples])
            pending.removeFirst(blockSamples)
            switch format {
            case .pcmS16LE:
                out.append(Self.packS16LE(block))
            case .aacEld:
                out.append(contentsOf: encodeAACBlock(&block))
            }
        }
        return out
    }

    /// Float32 → interleaved s16le. Saturating (an inter-sample over must clamp, not wrap);
    /// little-endian per the wire contract (`pcmS16LE`), unlike the big-endian header ints.
    static func packS16LE(_ samples: [Float]) -> Data {
        var out = Data(capacity: samples.count * 2)
        for sample in samples {
            let clamped = Double.maximum(-1.0, Double.minimum(1.0, Double(sample)))
            let scaled = Int16((clamped * 32767.0).rounded())
            out.append(UInt8(truncatingIfNeeded: scaled))
            out.append(UInt8(truncatingIfNeeded: scaled >> 8))
        }
        return out
    }

    // MARK: AAC-ELD arm

    /// Sentinel the input proc returns once the current block is fully handed over, so
    /// `AudioConverterFillComplexBuffer` stops asking instead of blocking for more input. The
    /// converter still returns any packet it completed alongside this status.
    private static let noMoreInputStatus: OSStatus = 0x736C_6F70 // 'slop'

    /// Input-proc cursor over one 480-frame interleaved block (lives on the caller's stack for
    /// the duration of the fill calls).
    private struct AACFeed {
        var base: UnsafeMutablePointer<Float>
        var totalFrames: UInt32
        var nextFrame: UInt32
        var channels: UInt32
    }

    /// Hands the converter up to the requested number of input packets (LPCM: 1 packet == 1
    /// frame) from the current block; `noMoreInputStatus` once exhausted. C-convention — all
    /// state rides in `AACFeed` behind the user-data pointer.
    private static let aacInputProc: AudioConverterComplexInputDataProc =
        { _, ioNumberDataPackets, ioData, _, inUserData in
            guard let inUserData else {
                ioNumberDataPackets.pointee = 0
                return AudioStreamEncoder.noMoreInputStatus
            }
            let feed = inUserData.assumingMemoryBound(to: AudioStreamEncoder.AACFeed.self)
            let available = feed.pointee.totalFrames - feed.pointee.nextFrame
            guard available > 0 else {
                ioNumberDataPackets.pointee = 0
                return AudioStreamEncoder.noMoreInputStatus
            }
            let provide = min(ioNumberDataPackets.pointee, available)
            let channels = feed.pointee.channels
            let bytesPerFrame = channels * UInt32(MemoryLayout<Float>.size)
            ioData.pointee.mNumberBuffers = 1
            ioData.pointee.mBuffers.mNumberChannels = channels
            ioData.pointee.mBuffers.mData =
                UnsafeMutableRawPointer(feed.pointee.base + Int(feed.pointee.nextFrame) * Int(channels))
            ioData.pointee.mBuffers.mDataByteSize = provide * bytesPerFrame
            feed.pointee.nextFrame += provide
            ioNumberDataPackets.pointee = provide
            return noErr
        }

    /// Builds the AAC-ELD converter on first use (48 kHz stereo Float32 → ELD @ 480
    /// frames/packet), stages the bitrate, and publishes the wire config with the fetched magic
    /// cookie. A failed build latches `converterFailed` — the encoder goes permanently silent
    /// (loudly logged) rather than retrying per buffer.
    private func ensureConverter() -> AudioConverterRef? {
        if let converter { return converter }
        guard !converterFailed else { return nil }
        var inDesc = AudioStreamBasicDescription(
            mSampleRate: Float64(Self.sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(MemoryLayout<Float>.size * Self.channelCount),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(MemoryLayout<Float>.size * Self.channelCount),
            mChannelsPerFrame: UInt32(Self.channelCount),
            mBitsPerChannel: 32,
            mReserved: 0,
        )
        // `mFramesPerPacket = 480` selects the ELD 480-frame variant so one packet is exactly one
        // 10 ms wire frame (the 512-frame default would beat against the fixed wire cadence).
        var outDesc = AudioStreamBasicDescription(
            mSampleRate: Float64(Self.sampleRate),
            mFormatID: kAudioFormatMPEG4AAC_ELD,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: UInt32(Self.samplesPerFrame),
            mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(Self.channelCount),
            mBitsPerChannel: 0,
            mReserved: 0,
        )
        var created: AudioConverterRef?
        let status = AudioConverterNew(&inDesc, &outDesc, &created)
        guard status == noErr, let converterRef = created else {
            converterFailed = true
            log.error("AAC-ELD AudioConverterNew failed: \(status) — audio lane silent (try SLOPDESK_AUDIO_CODEC=pcm)")
            diag("AudioConverterNew(kAudioFormatMPEG4AAC_ELD) failed: \(status)")
            return nil
        }
        // Best-effort: an unsupported rate keeps the encoder's own default rather than failing the lane.
        var rate = UInt32(clamping: bitrateBps)
        _ = AudioConverterSetProperty(
            converterRef,
            kAudioConverterEncodeBitRate,
            UInt32(MemoryLayout<UInt32>.size),
            &rate,
        )
        // The magic cookie (AudioSpecificConfig) rides the wire config — the client decoder
        // cannot initialise ELD without it.
        var cookie = Data()
        var cookieSize: UInt32 = 0
        if AudioConverterGetPropertyInfo(
            converterRef, kAudioConverterCompressionMagicCookie, &cookieSize, nil,
        ) == noErr, cookieSize > 0 {
            var bytes = [UInt8](repeating: 0, count: Int(cookieSize))
            if AudioConverterGetProperty(
                converterRef, kAudioConverterCompressionMagicCookie, &cookieSize, &bytes,
            ) == noErr {
                cookie = Data(bytes[..<Int(cookieSize)])
            }
        }
        var maxPacket: UInt32 = 0
        var maxPacketSize = UInt32(MemoryLayout<UInt32>.size)
        if AudioConverterGetProperty(
            converterRef, kAudioConverterPropertyMaximumOutputPacketSize, &maxPacketSize, &maxPacket,
        ) == noErr, maxPacket > 0 {
            maxPacketBytes = min(Int(maxPacket), AudioChannelMessage.maxPayloadBytes)
        } else {
            maxPacketBytes = AudioChannelMessage.maxPayloadBytes
        }
        converter = converterRef
        config = AudioStreamConfig(
            format: .aacEld,
            sampleRate: Self.sampleRate,
            channels: UInt8(Self.channelCount),
            cookie: cookie,
        )
        diag("AAC-ELD converter up: bitrate=\(rate)bps cookie=\(cookie.count)B maxPacket=\(maxPacketBytes)B")
        return converterRef
    }

    /// Feeds one 480-frame block and drains every completed access unit. The converter's
    /// internal priming/lookahead may withhold output on the first block(s) — output frames then
    /// lag input by a constant, which the wire does not care about (frames carry no PTS; the
    /// client's jitter ring paces by seq).
    private func encodeAACBlock(_ block: inout [Float]) -> [Data] {
        guard let converter = ensureConverter() else { return [] }
        var out: [Data] = []
        block.withUnsafeMutableBufferPointer { samples in
            guard let base = samples.baseAddress else { return }
            var feed = AACFeed(
                base: base,
                totalFrames: UInt32(Self.samplesPerFrame),
                nextFrame: 0,
                channels: UInt32(Self.channelCount),
            )
            withUnsafeMutablePointer(to: &feed) { feedPointer in
                // Each successful fill yields ONE packet; loop until the input runs dry (the
                // sentinel) in case buffered priming input completes a second packet.
                while true {
                    var packet = [UInt8](repeating: 0, count: maxPacketBytes)
                    var stop = false
                    packet.withUnsafeMutableBytes { raw in
                        var outputList = AudioBufferList(
                            mNumberBuffers: 1,
                            mBuffers: AudioBuffer(
                                mNumberChannels: UInt32(Self.channelCount),
                                mDataByteSize: UInt32(raw.count),
                                mData: raw.baseAddress,
                            ),
                        )
                        var packetCount: UInt32 = 1
                        var packetDescription = AudioStreamPacketDescription()
                        let status = AudioConverterFillComplexBuffer(
                            converter,
                            Self.aacInputProc,
                            UnsafeMutableRawPointer(feedPointer),
                            &packetCount,
                            &outputList,
                            &packetDescription,
                        )
                        if packetCount > 0, let outBase = raw.baseAddress {
                            let byteCount = min(Int(outputList.mBuffers.mDataByteSize), raw.count)
                            if byteCount > 0 { out.append(Data(bytes: outBase, count: byteCount)) }
                        }
                        if status != noErr || packetCount == 0 {
                            stop = true
                            if status != noErr, status != Self.noMoreInputStatus {
                                self.diag("AAC-ELD fill failed: \(status) — dropping block")
                            }
                        }
                    }
                    if stop { break }
                }
            }
        }
        return out
    }

    /// Opt-in stderr diagnostics (`SLOPDESK_AUDIO_DEBUG=1`) — OSLog debug isn't persisted, and a
    /// silent audio lane needs a headless-readable trail. No-op in production.
    private func diag(_ message: @autoclosure () -> String) {
        guard Self.debugStderr else { return }
        FileHandle.standardError.write(Data("slopdesk-audio[encoder]: \(message())\n".utf8))
    }
}
#endif
