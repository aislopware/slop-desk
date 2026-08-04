// AndroidStreamProtocol — the pure codec for the `scrcpy-server` stream, as the host bridge relays
// it verbatim.
//
// A FOREIGN wire, like the simulator panel's: `scrcpy` defines it, we speak it. So there are no
// golden vectors to pin and no version byte we control, and what this file owes instead is what
// every untrusted decoder in the project owes — optional parses, validate-then-drop, no byte read
// without a bounds check. The measurements behind the layout are in `docs/48-android-panel.md`.
//
// ## Two differences from the simulator's dialect that shape everything downstream
//
// **1. This is a BYTE STREAM, not a sequence of messages.** The simulator panel receives websocket
// messages, so its decoder is a function from one complete message to one event. Here the transport
// is a plain TCP connection and a `receive` hands back whatever happened to arrive: half a header,
// three frames, a header and two bytes of its payload. So the decoder is a stateful reassembler that
// consumes what it can and keeps the rest. Getting this wrong does not fail loudly — it decodes
// garbage — which is why the reassembly is the part the tests cover hardest.
//
// **2. The payloads are Annex-B, not AVCC.** `scrcpy` forwards raw `MediaCodec` output, whose NALs
// are separated by `00 00 00 01` start codes. CoreMedia wants 4-byte big-endian LENGTHS instead, so
// every access unit is rewritten on the way through (``AndroidAnnexB``). The simulator panel asks
// its server for `format=avcc` precisely to avoid this cost; `scrcpy` offers no such option.
//
// ## The framing
//
// ```
// [4 bytes BE codec id]   "h264" / "h265" / "\0av1"   — once, at the head of the stream
// then repeatedly, a 12-byte header:
//
//   MSB SET → session packet (video only), no payload:
//     byte 0: 1000000 0                       byte 3 bit 0: client-resized flag
//     bytes 4..7:  width  (u32 BE)            bytes 8..11: height (u32 BE)
//
//   MSB CLEAR → media packet, followed by <size> bytes:
//     bytes 0..7:  0 C K <61-bit PTS>         C = config packet, K = key frame
//     bytes 8..11: size (u32 BE)
// ```

#if os(macOS)
import Foundation

/// One thing the stream said.
enum AndroidStreamMessage: Equatable {
    /// The stream's codec, as its four ASCII bytes. Read once, before anything else.
    case codec(String)
    /// The video size changed (or was announced). Sent at the head of the stream and again whenever
    /// the device rotates or a new display is bound.
    case session(width: Int, height: Int)
    /// Parameter sets — SPS/PPS in Annex-B. Never displayed; it is what the format description is
    /// built from.
    case configuration(Data)
    /// One access unit, still in Annex-B.
    case accessUnit(Data, isKeyframe: Bool)
}

/// A stateful reassembler over the TCP byte stream. A value type holding a buffer: no locks, no
/// callbacks, no socket — the connection feeds it bytes and drains the events.
struct AndroidStreamParser {
    /// Bytes received and not yet consumed by a complete message.
    private var buffer = Data()
    /// The four-byte codec id is read exactly once, at the head.
    private var hasReadCodec = false
    /// Refuses a payload length no real stream produces. A corrupted or misaligned header otherwise
    /// asks for a multi-gigabyte allocation, which is how a decode bug becomes a memory panic
    /// instead of a dropped frame.
    static let maximumPacketSize = 32 * 1024 * 1024

    /// Set once the stream has said something impossible. A desynchronised byte stream cannot be
    /// resynchronised — there are no start markers to hunt for — so the only honest response is to
    /// stop parsing and let the connection be torn down and redialled.
    private(set) var isCorrupt = false

    static let headerSize = 12
    static let configFlag: UInt8 = 0x40
    static let keyFrameFlag: UInt8 = 0x20
    static let sessionFlag: UInt8 = 0x80

    /// Feed the parser and take every message that is now complete.
    mutating func consume(_ incoming: Data) -> [AndroidStreamMessage] {
        guard !isCorrupt else { return [] }
        buffer.append(incoming)
        var messages: [AndroidStreamMessage] = []
        while let message = next() {
            messages.append(message)
        }
        return messages
    }

    private mutating func next() -> AndroidStreamMessage? {
        if !hasReadCodec {
            guard buffer.count >= 4 else { return nil }
            let identifier = take(4)
            hasReadCodec = true
            // A leading NUL is how three-letter codecs are spelled (`\0av1`); it is stripped so the
            // caller compares against the name rather than the padding.
            let name = String(bytes: identifier.drop { $0 == 0 }, encoding: .utf8) ?? ""
            guard !name.isEmpty else {
                isCorrupt = true
                return nil
            }
            return .codec(name)
        }

        guard buffer.count >= Self.headerSize else { return nil }
        let header = [UInt8](buffer.prefix(Self.headerSize))

        if header[0] & Self.sessionFlag != 0 {
            _ = take(Self.headerSize)
            return .session(
                width: Int(readUInt32(header, at: 4)), height: Int(readUInt32(header, at: 8)),
            )
        }

        let size = Int(readUInt32(header, at: 8))
        guard size > 0, size <= Self.maximumPacketSize else {
            // Length zero is what `scrcpy`'s own demuxer rejects outright, and an absurd length means
            // the stream is no longer where we think it is.
            isCorrupt = true
            return nil
        }
        // Wait for the whole payload rather than delivering it in pieces: an access unit is only
        // meaningful whole, and CoreMedia takes it that way.
        guard buffer.count >= Self.headerSize + size else { return nil }
        _ = take(Self.headerSize)
        let payload = take(size)

        if header[0] & Self.configFlag != 0 { return .configuration(payload) }
        return .accessUnit(payload, isKeyframe: header[0] & Self.keyFrameFlag != 0)
    }

    /// Removes and returns the first `count` bytes, re-basing the buffer.
    ///
    /// `Data`'s slice indices are NOT zero-based after a `removeFirst`, which is the single most
    /// common way a reassembler like this reads the wrong bytes. Re-wrapping in a fresh `Data` costs
    /// a copy of the remainder and buys freedom from that whole class of bug; the remainder is at
    /// most one partial frame.
    private mutating func take(_ count: Int) -> Data {
        let head = Data(buffer.prefix(count))
        buffer = Data(buffer.dropFirst(count))
        return head
    }

    private func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        (UInt32(bytes[offset]) << 24) | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8) | UInt32(bytes[offset + 3])
    }
}

/// Annex-B ⇄ AVCC. `scrcpy` sends what `MediaCodec` produces; CoreMedia takes length-prefixed NALs.
enum AndroidAnnexB {
    /// Splits an Annex-B buffer into its NAL units, start codes removed.
    ///
    /// Both start-code lengths occur in one stream: `MediaCodec` writes the 4-byte form ahead of
    /// parameter sets and the first slice, and the 3-byte form between the slices of one frame.
    /// Handling only the 4-byte form yields NALs with `00 00 00 01` embedded in them, which decode
    /// as corruption rather than failing.
    static func nalUnits(in data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var starts: [(offset: Int, codeLength: Int)] = []
        var index = 0
        while index + 3 <= bytes.count {
            if bytes[index] == 0, bytes[index + 1] == 0 {
                if bytes[index + 2] == 1 {
                    starts.append((index, 3))
                    index += 3
                    continue
                }
                if index + 4 <= bytes.count, bytes[index + 2] == 0, bytes[index + 3] == 1 {
                    starts.append((index, 4))
                    index += 4
                    continue
                }
            }
            index += 1
        }
        guard !starts.isEmpty else { return [] }

        var units: [Data] = []
        for (position, start) in starts.enumerated() {
            let begin = start.offset + start.codeLength
            let end = position + 1 < starts.count ? starts[position + 1].offset : bytes.count
            guard begin < end else { continue }
            units.append(Data(bytes[begin..<end]))
        }
        return units
    }

    /// Rewrites an Annex-B access unit as AVCC: every NAL prefixed with its 4-byte big-endian length.
    ///
    /// Returns `nil` for a buffer with no start code at all rather than passing it through — a
    /// payload that is already length-prefixed would be silently mis-framed, and the panel would show
    /// a decoder that produces nothing with no clue why.
    static func avccAccessUnit(from data: Data) -> Data? {
        let units = nalUnits(in: data)
        guard !units.isEmpty else { return nil }
        var out = Data(capacity: data.count + 4 * units.count)
        for unit in units {
            let length = UInt32(unit.count)
            out.append(UInt8(truncatingIfNeeded: length >> 24))
            out.append(UInt8(truncatingIfNeeded: length >> 16))
            out.append(UInt8(truncatingIfNeeded: length >> 8))
            out.append(UInt8(truncatingIfNeeded: length))
            out.append(unit)
        }
        return out
    }

    /// The parameter sets a config packet carries, in the order CoreMedia wants them (SPS first).
    ///
    /// Filtering by NAL type rather than taking every unit: `MediaCodec` is free to put an access
    /// unit delimiter or SEI in the same buffer, and
    /// `CMVideoFormatDescriptionCreateFromH264ParameterSets` rejects the whole set if one member is
    /// not a parameter set.
    static func parameterSets(inConfiguration data: Data, codec: AndroidVideoCodec) -> [Data] {
        nalUnits(in: data).filter { unit in
            guard let first = unit.first else { return false }
            switch codec {
            case .h264:
                // Type is the low 5 bits: 7 = SPS, 8 = PPS.
                let type = first & 0x1F
                return type == 7 || type == 8
            case .h265:
                // HEVC's type is bits 1..6 of the first header byte: 32 = VPS, 33 = SPS, 34 = PPS.
                let type = (first >> 1) & 0x3F
                return type == 32 || type == 33 || type == 34
            }
        }
    }
}

/// The codecs the panel can actually display. AV1 is deliberately absent: `VTDecompressionSession`
/// gains AV1 only on M3-class hardware and later, so offering it would make the panel's ability to
/// show anything depend on which Mac the CLIENT is running — a failure that would present as a black
/// rectangle. The bridge can still be asked for it; nothing here will decode it.
enum AndroidVideoCodec: String, Equatable {
    case h264
    case h265

    init?(streamIdentifier: String) {
        switch streamIdentifier {
        case "h264": self = .h264
        case "h265": self = .h265
        default: return nil
        }
    }
}
#endif
