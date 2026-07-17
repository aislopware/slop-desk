import Foundation

/// The codec the host's app-audio rides the wire in. A `UInt8` on the wire (the config
/// packet's `formatID`); an unknown value decodes as `.malformed` so a client that doesn't
/// speak a future format DROPS the config (and with it the stream) instead of feeding
/// garbage to a decoder.
public enum AudioWireFormat: UInt8, Sendable, Equatable {
    /// AAC-ELD access units (the default: low-delay, ~10 ms frames). The config `cookie`
    /// carries the AAC magic cookie the decoder needs.
    case aacEld = 1
    /// Interleaved signed 16-bit little-endian PCM, 480 samples × channels per frame — the
    /// codec-free fallback (`SLOPDESK_AUDIO_CODEC=pcm`). `cookie` is empty.
    case pcmS16LE = 2
}

/// The audio stream's decode parameters, carried by an ``AudioChannelMessage/config(seq:hostSendTsMillis:config:)``
/// packet. The client (re)builds its decoder only when a received config DIFFERS from the
/// one in force — the host re-sends it ~1 s apart (UDP may drop any single copy), so
/// re-application must be, and is, idempotent.
///
/// Config payload layout (inside the 11-byte-header payload), big-endian:
/// ```
/// off 0: UInt8  formatID   — ``AudioWireFormat`` raw value; unknown ⇒ .malformed
/// off 1: UInt32 sampleRate — Hz (48000); 0 ⇒ .malformed
/// off 5: UInt8  channels   — interleaved channel count (2); 0 ⇒ .malformed
/// off 6: UInt16 cookieLen  — must equal the remaining byte count exactly
/// off 8: cookie[cookieLen] — AAC magic cookie; empty for pcmS16LE
/// ```
public struct AudioStreamConfig: Equatable, Sendable {
    public let format: AudioWireFormat
    /// Sample rate in Hz (48000 on the live host path).
    public let sampleRate: UInt32
    /// Interleaved channel count (2 on the live host path).
    public let channels: UInt8
    /// The AAC magic cookie the decoder is initialised from; empty for ``AudioWireFormat/pcmS16LE``.
    public let cookie: Data

    public init(format: AudioWireFormat, sampleRate: UInt32, channels: UInt8, cookie: Data) {
        self.format = format
        self.sampleRate = sampleRate
        self.channels = channels
        self.cookie = cookie
    }
}

/// Host → client app-audio datagram (media socket, channel tag 6 — the socket-selection
/// predicate already routes every non-cursor tag there). ONE datagram per message, sent
/// IMMEDIATE — no packetizer, no FEC, no retransmit: a lost ~10 ms audio frame is cheaper
/// to conceal (the client's jitter ring underruns to silence) than to wait for, and audio
/// must never delay video or vice versa.
///
/// Header, fixed 11 bytes big-endian:
/// ```
/// off 0: UInt32 seq              — ONE monotonic counter for ALL tag-6 packets of a session
///                                  (config + frames share it; the client orders/late-drops on it)
/// off 4: UInt32 hostSendTsMillis — host-monotonic ms, same contract as FrameFragmentHeader
///                                  (relative to the host session; NEVER cross-clock arithmetic)
/// off 8: UInt8  flags            — bit0 = config packet; bits 1-7 reserved (encode 0, decode ignores)
/// off 9: UInt16 payloadLen       — must equal the remaining byte count EXACTLY; ≤ 8192
/// off11: payload[payloadLen]
/// ```
/// A frame payload is one encoded codec frame (an AAC-ELD access unit, or `480 × channels × 2`
/// bytes of interleaved s16le PCM); a config payload is an ``AudioStreamConfig``.
public enum AudioChannelMessage: Equatable, Sendable {
    /// The stream's decode parameters. Sent when audio is (re-)enabled and re-sent ~1 s apart
    /// so a client that missed one copy (or attached late) still locks on; the client rebuilds
    /// its decoder only when the config CHANGES.
    case config(seq: UInt32, hostSendTsMillis: UInt32, config: AudioStreamConfig)
    /// One encoded ~10 ms audio frame.
    case frame(seq: UInt32, hostSendTsMillis: UInt32, payload: Data)

    /// Header size in bytes.
    public static let headerSize = 11
    /// Hostile-input cap on `payloadLen` — generous over the real maximum (a 1920-byte PCM
    /// frame; AAC-ELD frames are far smaller) while bounding what a corrupt length can make
    /// the receiver allocate.
    public static let maxPayloadBytes = 8192
    /// Header flags bit0: the payload is an ``AudioStreamConfig``, not a codec frame.
    static let configFlag: UInt8 = 1 << 0

    /// Serialises the datagram (header then payload). The CALLER (host) keeps payloads within
    /// ``maxPayloadBytes`` — the encoder emits ≤ ~2 KB frames by construction; `payloadLen`
    /// truncates to `UInt16` like every wire count.
    public func encode() -> Data {
        switch self {
        case let .config(seq, hostSendTsMillis, config):
            Self.encodeMessage(
                seq: seq,
                hostSendTsMillis: hostSendTsMillis,
                flags: Self.configFlag,
                payload: Self.encodeConfigPayload(config),
            )
        case let .frame(seq, hostSendTsMillis, payload):
            Self.encodeMessage(seq: seq, hostSendTsMillis: hostSendTsMillis, flags: 0, payload: payload)
        }
    }

    /// Parses one datagram. Throws ``VideoProtocolError`` on a short/inconsistent datagram
    /// (a corrupt single packet must not crash the receiver — same contract as the
    /// reassembler): a declared payload past the datagram end is `.truncated`, an over-cap
    /// length or trailing bytes are `.malformed`. Reserved flag bits (1–7) are IGNORED so a
    /// future sender can set them without breaking this decoder; only bit0 selects the
    /// payload grammar.
    public static func decode(_ data: Data) throws -> Self {
        var reader = VideoByteReader(data)
        let seq = try reader.readUInt32()
        let hostSendTsMillis = try reader.readUInt32()
        let flags = try reader.readUInt8()
        let payloadLen = try Int(reader.readUInt16())
        guard payloadLen <= maxPayloadBytes else {
            throw VideoProtocolError.malformed("audio payloadLen \(payloadLen) exceeds cap \(maxPayloadBytes)")
        }
        // `readBytes` bounds-checks against the buffer BEFORE reading, so a corrupt length
        // drops the datagram (`.truncated`) rather than over-reading or over-allocating.
        let payload = try reader.readBytes(payloadLen)
        guard reader.bytesRemaining == 0 else {
            throw VideoProtocolError.malformed("audio datagram carries \(reader.bytesRemaining) trailing bytes")
        }
        guard flags & configFlag != 0 else {
            return .frame(seq: seq, hostSendTsMillis: hostSendTsMillis, payload: payload)
        }
        return try .config(seq: seq, hostSendTsMillis: hostSendTsMillis, config: decodeConfigPayload(payload))
    }

    private static func encodeMessage(seq: UInt32, hostSendTsMillis: UInt32, flags: UInt8, payload: Data) -> Data {
        var out = Data(capacity: headerSize + payload.count)
        out.appendBE(seq)
        out.appendBE(hostSendTsMillis)
        out.append(flags)
        out.appendBE(UInt16(truncatingIfNeeded: payload.count))
        out.append(payload)
        return out
    }

    private static func encodeConfigPayload(_ config: AudioStreamConfig) -> Data {
        var out = Data(capacity: 8 + config.cookie.count)
        out.append(config.format.rawValue)
        out.appendBE(config.sampleRate)
        out.append(config.channels)
        // The cookie is an AAC magic cookie (tens of bytes); `cookieLen` truncates to
        // `UInt16` like every wire count.
        out.appendBE(UInt16(truncatingIfNeeded: config.cookie.count))
        out.append(config.cookie)
        return out
    }

    /// Validate-then-drop for the config grammar: unknown format, a zero sample rate or
    /// channel count, and a cookie length that does not consume the payload exactly are all
    /// corruption/hostile — the client catches and drops the datagram.
    private static func decodeConfigPayload(_ payload: Data) throws -> AudioStreamConfig {
        var reader = VideoByteReader(payload)
        let formatID = try reader.readUInt8()
        guard let format = AudioWireFormat(rawValue: formatID) else {
            throw VideoProtocolError.malformed("unknown audio wire format \(formatID)")
        }
        let sampleRate = try reader.readUInt32()
        let channels = try reader.readUInt8()
        guard sampleRate != 0, channels != 0 else {
            throw VideoProtocolError.malformed("audio config with zero sampleRate/channels")
        }
        let cookieLen = try Int(reader.readUInt16())
        let cookie = try reader.readBytes(cookieLen)
        guard reader.bytesRemaining == 0 else {
            throw VideoProtocolError.malformed("audio config carries \(reader.bytesRemaining) trailing cookie bytes")
        }
        return AudioStreamConfig(format: format, sampleRate: sampleRate, channels: channels, cookie: cookie)
    }
}
