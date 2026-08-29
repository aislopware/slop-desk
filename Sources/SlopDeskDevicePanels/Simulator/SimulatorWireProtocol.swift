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

    // NOTE: the avcC record's parse LEFT (2026-08-29). `AVCConfiguration`, `parseAVCConfiguration`
    // and the run-length walk that split the door's delivery all existed to feed
    // `CMVideoFormatDescriptionCreateFromH264ParameterSets`, which is now
    // `slopdesk_panel_video_configure_avcc`'s to call. The record travels to that door WHOLE, so
    // neither its parameter sets nor its `nalUnitHeaderLength` becomes a Swift value that could
    // disagree with the description built from them, and `slopdesk_sim_avcc_parse` — the door this
    // read through — went with it. `slopdesk_devicepanel::sim_stream` still owns the layout, and
    // pins it.
}
