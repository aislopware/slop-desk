// SimulatorWireProtocol — the pure codec for the host simulator server's stream dialect.
//
// This is a FOREIGN wire, not one of SlopDesk's own: `baguette serve` defines it and the client
// speaks it. So the rules that govern `SlopDeskProtocol` do not apply here — there are no golden
// vectors to pin and no version byte we control. What this file owes instead is the discipline every
// untrusted decoder in the project owes: optional/throwing parses, validate-then-drop, and not one
// byte read without a bounds check. The frames arrive over the WireGuard mesh from a process the
// user installed, and a malformed one must yield `nil`, never a trap.
//
// The dialect, measured against `baguette serve` v2 (see `docs/47-simulator-panel.md`):
//
//   BINARY message = [1 byte type][payload]
//     0x01  avcC decoder configuration record (SPS/PPS)
//     0x02  H.264 IDR       — AVCC, length-prefixed NALs (NOT Annex-B start codes)
//     0x03  H.264 delta     — same framing
//     0x04  JPEG seed frame — painted before the first IDR lands, so the surface is never blank
//   TEXT message = JSON; carries errors and control, never pixels.
//
// Upstream (client → host) is JSON only: gestures, hardware buttons, keys, clipboard. Encoding lives
// in ``SimulatorInputEnvelope`` and is hand-built rather than `Codable` for one reason — the envelope
// is a flat heterogeneous bag whose key set changes per type (`tap` carries x/y, `touch2-move`
// carries x1/y1/x2/y2), which `Codable` models far more awkwardly than a dictionary literal does.
//
// Everything here is a pure function over bytes. Nothing constructs a socket, a decompression
// session or a display layer — those live in the runtime types alongside, under the hang-safety rule.

#if os(macOS)
import Foundation

/// One decoded downstream message. `unknown` is a first-class case on purpose: a newer server that
/// adds a type must degrade to "ignore that message" rather than to a dropped connection.
package enum SimulatorStreamMessage: Equatable {
    /// The avcC configuration record, payload sans the type byte.
    case configuration(Data)
    /// An access unit. `isKeyframe` distinguishes 0x02 from 0x03.
    case accessUnit(Data, isKeyframe: Bool)
    /// A JPEG still, painted until the first access unit decodes.
    case jpeg(Data)
    /// A type byte this build does not know.
    case unknown(UInt8)
}

package enum SimulatorWireProtocol {
    // MARK: Downstream envelope

    package static let configurationType: UInt8 = 0x01
    package static let keyframeType: UInt8 = 0x02
    package static let deltaType: UInt8 = 0x03
    package static let jpegType: UInt8 = 0x04

    /// Split a binary websocket message into its type byte and payload.
    ///
    /// A message shorter than two bytes yields `nil` rather than an empty-payload message: the
    /// server never sends a bodiless frame, so one on the wire means the stream is not what we think
    /// it is, and the honest response is to drop it. (The page's own decoder applies the same
    /// `byteLength < 2` floor.)
    package static func decode(_ message: Data) -> SimulatorStreamMessage? {
        guard message.count >= 2 else { return nil }
        let type = message[message.startIndex]
        let payload = Data(message.dropFirst())
        switch type {
        case configurationType: return .configuration(payload)
        case keyframeType: return .accessUnit(payload, isKeyframe: true)
        case deltaType: return .accessUnit(payload, isKeyframe: false)
        case jpegType: return .jpeg(payload)
        default: return .unknown(type)
        }
    }

    // MARK: avcC

    /// The parameter sets and NAL length size carried by an avcC record — everything
    /// `CMVideoFormatDescriptionCreateFromH264ParameterSets` needs, and nothing else.
    package struct AVCConfiguration: Equatable {
        package var parameterSets: [Data]
        /// 1, 2 or 4. Every observed stream uses 4; the field is parsed rather than assumed because
        /// a wrong guess here decodes as garbage instead of failing loudly.
        package var nalUnitHeaderLength: Int
        /// Profile / compatibility / level, kept only so a mismatch is diagnosable from a log.
        package var profile: UInt8
        package var levelIndication: UInt8
    }

    /// Parse an avcC record. Returns `nil` on any truncation, an unknown configuration version, or a
    /// record carrying no SPS — each of which would otherwise become a format description that
    /// decodes nothing, which is far harder to diagnose than a refusal at the door.
    ///
    /// Layout (ISO/IEC 14496-15 §5.2.4.1): version, profile, compatibility, level, then a byte whose
    /// low two bits are `lengthSizeMinusOne`, then a byte whose low five bits are the SPS count,
    /// then length-prefixed SPS blobs, then a PPS count byte and its length-prefixed blobs.
    package static func parseAVCConfiguration(_ record: Data) -> AVCConfiguration? {
        var reader = ByteReader(record)
        guard let version = reader.byte(), version == 1,
              let profile = reader.byte(),
              reader.byte() != nil,
              let level = reader.byte(),
              let lengthByte = reader.byte(),
              let spsCountByte = reader.byte()
        else { return nil }

        var sets: [Data] = []
        guard reader.readParameterSets(count: Int(spsCountByte & 0x1F), into: &sets), !sets.isEmpty
        else { return nil }
        // The PPS count and its sets are absent from a truncated record. That is tolerated: an SPS
        // alone still yields a usable format description, and refusing here would turn a recoverable
        // stream into a dead panel.
        if let ppsCountByte = reader.byte() {
            guard reader.readParameterSets(count: Int(ppsCountByte), into: &sets) else { return nil }
        }

        return AVCConfiguration(
            parameterSets: sets,
            nalUnitHeaderLength: Int(lengthByte & 0x03) + 1,
            profile: profile,
            levelIndication: level,
        )
    }

    /// A cursor that can only move forward and never past the end. Every read is bounds-checked and
    /// returns an optional — the shape the untrusted-input invariant asks for.
    private struct ByteReader {
        private let bytes: [UInt8]
        private var offset = 0

        package init(_ data: Data) { bytes = Array(data) }

        package mutating func byte() -> UInt8? {
            guard offset < bytes.count else { return nil }
            defer { offset += 1 }
            return bytes[offset]
        }

        package mutating func blob(length: Int) -> Data? {
            guard length >= 0, offset + length <= bytes.count else { return nil }
            defer { offset += length }
            return Data(bytes[offset..<(offset + length)])
        }

        /// `count` consecutive `[UInt16 BE length][bytes]` blobs. A zero-length set is skipped rather
        /// than appended — an empty parameter set is meaningless to the decoder and would only make
        /// the format description fail later, further from the cause.
        package mutating func readParameterSets(count: Int, into sets: inout [Data]) -> Bool {
            for _ in 0..<count {
                guard let high = byte(), let low = byte() else { return false }
                let length = Int(high) << 8 | Int(low)
                guard let blob = blob(length: length) else { return false }
                if !blob.isEmpty { sets.append(blob) }
            }
            return true
        }
    }
}
#endif
