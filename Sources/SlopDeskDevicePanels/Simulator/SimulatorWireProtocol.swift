// SimulatorWireProtocol — the face over the host simulator server's downstream dialect.
//
// The RULES live in `slopdesk_devicepanel::sim_stream`. This is a FOREIGN wire, not one of SlopDesk's
// own: `baguette serve` defines it and the client speaks it. So the rules that govern
// `SlopDeskProtocol` do not apply — there are no golden vectors to pin and no version byte we
// control. What the decoder owes instead is what every untrusted decoder owes, and it owes it in
// Rust now: validate-then-drop, and not one byte read without a bounds check.
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
// THE PAYLOAD DOES NOT CROSS THE BOUNDARY. The door answers a KIND; the payload is the message minus
// its first byte, which this side already holds. Handing it through Rust so it could come straight
// back would be a memcpy per access unit, sixty times a second, for bytes that never left this
// buffer.
//
// Upstream (client → host) is JSON only: gestures, hardware buttons, keys, clipboard. Encoding lives
// in ``SimulatorInputEnvelope``, which is the same story on the other half of the socket.

import CSlopDeskFFI
import Foundation
import SlopDeskArena

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

    /// Split a binary websocket message into its type byte and payload.
    ///
    /// A message the door refuses — shorter than two bytes — yields `nil` rather than an
    /// empty-payload message: the server never sends a bodiless frame, so one on the wire means the
    /// stream is not what we think it is, and the honest response is to drop it.
    package static func decode(_ message: Data) -> SimulatorStreamMessage? {
        var kind: UInt8 = 0
        let known = message.withUnsafeBytes { raw in
            slopdesk_sim_stream_kind(
                raw.baseAddress?.assumingMemoryBound(to: UInt8.self), raw.count, &kind,
            )
        }
        guard known else { return nil }

        // The payload is a SLICE of what the caller already handed us; only the copy `Data` makes
        // here crosses anything, and it is the copy the sink would have made anyway.
        let payload = Data(message.dropFirst())
        switch kind {
        case UInt8(SLOPDESK_SIM_STREAM_CONFIGURATION): return .configuration(payload)
        case UInt8(SLOPDESK_SIM_STREAM_KEYFRAME): return .accessUnit(payload, isKeyframe: true)
        case UInt8(SLOPDESK_SIM_STREAM_DELTA): return .accessUnit(payload, isKeyframe: false)
        case UInt8(SLOPDESK_SIM_STREAM_JPEG): return .jpeg(payload)
        default: return .unknown(message[message.startIndex])
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
    /// The record arrives ONCE per stream, so the delivery copy here is paid once and buys a single
    /// cut on this side instead of a reader walking the layout in two languages.
    package static func parseAVCConfiguration(_ record: Data) -> AVCConfiguration? {
        var header = SlopDeskAvcHeader()
        let blob = record.withUnsafeBytes { raw -> [UInt8] in
            ffiAnswerBytes(capacity: 512) { out, cap in
                slopdesk_sim_avcc_parse(
                    raw.baseAddress?.assumingMemoryBound(to: UInt8.self), raw.count,
                    &header, out, cap,
                )
            }
        }
        guard header.set_count > 0 else { return nil }

        let sets = parameterSets(blob, count: Int(header.set_count))
        guard sets.count == Int(header.set_count) else { return nil }
        return AVCConfiguration(
            parameterSets: sets,
            nalUnitHeaderLength: Int(header.nal_unit_header_length),
            profile: header.profile,
            levelIndication: header.level_indication,
        )
    }

    /// The delivery's own framing: `count` runs of `[UInt32 big-endian length][bytes]`.
    ///
    /// A run that would read past the end ends the walk rather than shifting into whatever follows —
    /// a short delivery means the door and this file disagree about the layout, and the caller reads
    /// the shortfall as a refusal rather than building a decoder from half a record.
    private static func parameterSets(_ blob: [UInt8], count: Int) -> [Data] {
        var sets: [Data] = []
        sets.reserveCapacity(count)
        var cursor = blob.startIndex
        for _ in 0..<count {
            guard cursor + 4 <= blob.endIndex else { break }
            let length = Int(
                UInt32(blob[cursor]) << 24 | UInt32(blob[cursor + 1]) << 16
                    | UInt32(blob[cursor + 2]) << 8 | UInt32(blob[cursor + 3]),
            )
            cursor += 4
            guard cursor + length <= blob.endIndex else { break }
            sets.append(Data(blob[cursor..<(cursor + length)]))
            cursor += length
        }
        return sets
    }
}
