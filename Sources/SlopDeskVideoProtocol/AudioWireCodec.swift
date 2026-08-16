import CSlopDeskFFI
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

    /// Header size in bytes, vended by the codec that writes it.
    public static let headerSize = slopdesk_audio_constant(0)
    /// Hostile-input cap on `payloadLen` — generous over the real maximum (a 1920-byte PCM
    /// frame; AAC-ELD frames are far smaller) while bounding what a corrupt length can make
    /// the receiver allocate. Enforced at decode, on the Rust side, not here.
    public static let maxPayloadBytes = slopdesk_audio_constant(1)

    /// Serialises the datagram (header then payload). `rust/slopdesk-video`'s `audio_wire` lays
    /// the bytes down — both the header and, for a config, its nested payload — so the two
    /// grammars exist once each. The CALLER (host) keeps payloads within ``maxPayloadBytes``.
    public func encode() -> Data {
        let span =
            switch self {
            case let .config(_, _, config): config.cookie
            case let .frame(_, _, payload): payload
            }
        let needed = span.withUnsafeBytes { bytes in
            slopdesk_audio_encode(wire, bytes.baseAddress, bytes.count, nil, 0)
        }
        precondition(needed > 0, "the audio codec refused a message this type can express")
        var out = Data(count: needed)
        let written = out.withUnsafeMutableBytes { buffer in
            span.withUnsafeBytes { bytes in
                slopdesk_audio_encode(wire, bytes.baseAddress, bytes.count, buffer.baseAddress, buffer.count)
            }
        }
        precondition(written == needed, "the audio codec sized a datagram differently than it wrote it")
        return out
    }

    /// Parses one datagram. Every guard is the Rust codec's, and they are the guards that keep a
    /// corrupt length from turning into an allocation: over the cap is `.malformed`, past the end
    /// is `.truncated`, and a trailing byte is `.malformed`. The config grammar is checked the same
    /// way — unknown format, zero sample rate or channels, a cookie length that does not consume
    /// the payload exactly. Reserved flag bits are ignored, so a future sender may set them.
    public static func decode(_ data: Data) throws -> Self {
        var flat = SlopDeskAudioMessage()
        // The span — a codec frame, or a config's cookie — is copied out inside the same borrow
        // that validated it: `dropFirst().prefix()` would build two intermediate `Data` values,
        // each with its own retain on the parent, to describe bytes that are about to be copied
        // once anyway. The offsets are the codec's, and it only reports them after proving the
        // datagram holds them.
        let (verdict, span) = data.withUnsafeBytes { bytes -> (UInt32, Data) in
            let verdict = slopdesk_audio_decode(bytes.baseAddress, bytes.count, &flat)
            guard verdict == UInt32(SLOPDESK_METADATA_DECODE_OK) else { return (verdict, Data()) }
            let start = Int(flat.span_offset)
            let end = start + Int(flat.span_length)
            return (verdict, Data(UnsafeRawBufferPointer(rebasing: bytes[start..<end])))
        }
        switch verdict {
        case UInt32(SLOPDESK_METADATA_DECODE_TRUNCATED): throw VideoProtocolError.truncated
        case UInt32(SLOPDESK_METADATA_DECODE_MALFORMED):
            throw VideoProtocolError.malformed("unacceptable audio datagram")
        default: break
        }
        guard flat.is_config else {
            return .frame(seq: flat.seq, hostSendTsMillis: flat.host_send_ts_millis, payload: span)
        }
        // The format was checked against the ones the wire admits before the offset was reported.
        let format = AudioWireFormat(rawValue: flat.format) ?? .aacEld
        return .config(
            seq: flat.seq, hostSendTsMillis: flat.host_send_ts_millis,
            config: AudioStreamConfig(
                format: format, sampleRate: flat.sample_rate, channels: flat.channels, cookie: span,
            ),
        )
    }

    /// The message flattened for the boundary: the header's fields, plus the config's parameters
    /// when it is one. The span itself travels beside it rather than inside it.
    private var wire: SlopDeskAudioMessage {
        var flat = SlopDeskAudioMessage()
        switch self {
        case let .config(seq, hostSendTsMillis, config):
            flat.seq = seq
            flat.host_send_ts_millis = hostSendTsMillis
            flat.is_config = true
            flat.format = config.format.rawValue
            flat.sample_rate = config.sampleRate
            flat.channels = config.channels
        case let .frame(seq, hostSendTsMillis, _):
            flat.seq = seq
            flat.host_send_ts_millis = hostSendTsMillis
        }
        return flat
    }
}
