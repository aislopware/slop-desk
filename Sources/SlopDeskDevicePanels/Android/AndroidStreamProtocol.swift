// AndroidStreamProtocol — the marshalling for the `scrcpy-server` stream, as the host bridge relays
// it verbatim.
//
// The FRAMING is `slopdesk_androidd::stream`, and the Annex-B walk is `slopdesk_video::annexb`.
// What is left here is the hand-off: a handle the connection owns, the buffer sizing, the UTF-8
// read, and the vocabulary SwiftUI names.
//
// ## Why the decoding moved
//
// A FOREIGN wire, like the simulator panel's: `scrcpy` defines it, we speak it. So there are no
// golden vectors to pin and no version byte we control, and what a decoder for it owes is what every
// untrusted decoder in the project owes — optional parses, validate-then-drop, no byte read without
// a bounds check. That is Rust's argument in one sentence, and the bridge relaying the stream
// verbatim is why nothing in Rust had ever read it. `docs/DECISIONS.md`'s stage-17 rule puts each
// protocol's client end in the crate that owns the protocol; `slopdesk-androidd` owns scrcpy's
// dialect already. The measurements behind the layout are in `docs/48-android-panel.md`.
//
// The port also paid for itself on the hot path. The Swift reassembler re-based its buffer on every
// message — its own comment named the copy and accepted it, to dodge `Data`'s non-zero-based slice
// indices after a `removeFirst`. Rust has no such hazard, so the head is a cursor and the buffer
// compacts once per 64 KiB instead of once per frame.
//
// ## The layout, and where it is now stated
//
// One four-byte codec id, then twelve-byte headers, each either a session packet or a media packet
// with a payload. `rust/slopdesk-androidd/src/stream.rs` carries the diagram and the reasoning; it
// is not restated here, because a second copy of a foreign wire's layout is the thing this change
// removed.

import CSlopDeskFFI
import Foundation

/// One thing the stream said.
package enum AndroidStreamMessage: Equatable {
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

/// A stateful reassembler over the TCP byte stream, held in Rust across calls.
///
/// A CLASS, where the Swift original was a value type: the parser is one buffer per mirror session
/// with a lifetime, which is what `deinit` is for. Copying it would either double-free the handle or
/// silently share it, and neither is a thing a `struct` can prevent.
package final class AndroidStreamParser {
    private let handle: OpaquePointer

    /// A parser at the head of a fresh stream.
    package init() {
        guard let handle = slopdesk_android_stream_new() else {
            preconditionFailure("the android stream parser could not be built")
        }
        self.handle = handle
    }

    deinit { slopdesk_android_stream_free(handle) }

    /// Whether the stream has said something impossible.
    ///
    /// Terminal: a desynchronised byte stream has no start markers to hunt for, so the connection is
    /// torn down and redialled rather than resynchronised.
    package private(set) var isCorrupt = false

    /// The payload buffer, kept across calls so a steady stream stops allocating.
    ///
    /// Starts EMPTY so a session that never receives a frame allocates nothing, and grows only when
    /// the door says a payload did not fit — `AGAIN` consumes nothing, so the retry reads the same
    /// message the short call refused. Sizing it from what the parser has buffered instead would
    /// allocate and zero the whole backlog once per frame.
    private var body: [UInt8] = []

    /// What the first growth rounds up to, so an ordinary run of frames grows the buffer once.
    private static let bodyFloor = 64 * 1024

    /// Feed the parser and take every message that is now complete.
    package func consume(_ incoming: Data) -> [AndroidStreamMessage] {
        guard !isCorrupt, !incoming.isEmpty else { return [] }
        incoming.withUnsafeBytes { bytes in
            slopdesk_android_stream_append(
                handle, bytes.baseAddress?.assumingMemoryBound(to: UInt8.self), bytes.count,
            )
        }
        var messages: [AndroidStreamMessage] = []
        while let message = next() {
            messages.append(message)
        }
        return messages
    }

    private func next() -> AndroidStreamMessage? {
        while true {
            var record = SlopDeskAndroidStreamMessage()
            let verdict = body.withUnsafeMutableBufferPointer { buffer in
                slopdesk_android_stream_next(handle, &record, buffer.baseAddress, buffer.count)
            }
            switch verdict {
            case SLOPDESK_ANDROID_STREAM_OK:
                return message(record)
            case SLOPDESK_ANDROID_STREAM_AGAIN:
                // Nothing was consumed: the message is still there, so grow once and ask again.
                body = [UInt8](repeating: 0, count: Swift.max(Int(record.payload_len), Self.bodyFloor))
            case SLOPDESK_ANDROID_STREAM_CORRUPT:
                isCorrupt = true
                return nil
            // PENDING, and any verdict a newer door might add: nothing to hand up, nothing broken.
            default:
                return nil
            }
        }
    }

    private func message(_ record: SlopDeskAndroidStreamMessage) -> AndroidStreamMessage? {
        let payload = body.withUnsafeBytes { bytes in
            Data(UnsafeRawBufferPointer(rebasing: bytes[0..<Int(record.payload_len)]))
        }
        switch UInt32(record.kind) {
        case SLOPDESK_ANDROID_STREAM_KIND_CODEC:
            // Non-failable on purpose: the door proved the four bytes are UTF-8 before it read them
            // as a name, and a stream whose id is not decodes as corrupt rather than as an empty
            // string.
            // swiftlint:disable:next optional_data_string_conversion
            return .codec(String(decoding: payload, as: UTF8.self))
        case SLOPDESK_ANDROID_STREAM_KIND_SESSION:
            return .session(width: Int(record.width), height: Int(record.height))
        case SLOPDESK_ANDROID_STREAM_KIND_CONFIGURATION:
            return .configuration(payload)
        case SLOPDESK_ANDROID_STREAM_KIND_ACCESS_UNIT:
            return .accessUnit(payload, isKeyframe: record.is_keyframe)
        default:
            return nil
        }
    }
}

/// Annex-B ⇄ AVCC. `scrcpy` sends what `MediaCodec` produces; CoreMedia takes length-prefixed NALs.
package enum AndroidAnnexB {
    /// Splits an Annex-B buffer into its NAL units, start codes removed.
    ///
    /// The door answers WHERE each unit sits and the bytes stay in the caller's buffer, which is the
    /// convention `slopdesk_nal_split` already crosses under; the copy happens here only because a
    /// `Data` per unit is what the two callers want.
    package static func nalUnits(in data: Data) -> [Data] {
        spans(in: data) { bytes, out, cap in
            slopdesk_annexb_split(bytes.baseAddress, bytes.count, out, cap)
        }
    }

    /// Rewrites an Annex-B access unit as AVCC: every NAL prefixed with its 4-byte big-endian length.
    ///
    /// Returns `nil` for a buffer with no start code at all rather than passing it through — a
    /// payload that is already length-prefixed would be silently mis-framed, and the panel would show
    /// a decoder that produces nothing with no clue why.
    package static func avccAccessUnit(from data: Data) -> Data? {
        let bytes = [UInt8](data)
        return bytes.withUnsafeBufferPointer { input -> Data? in
            let needed = slopdesk_annexb_to_avcc(input.baseAddress, input.count, nil, 0)
            // Zero is REFUSED, not "did not fit": a real rewrite costs at least its length prefix.
            guard needed > 0 else { return nil }
            var out = [UInt8](repeating: 0, count: needed)
            let written = out.withUnsafeMutableBufferPointer { room in
                slopdesk_annexb_to_avcc(input.baseAddress, input.count, room.baseAddress, room.count)
            }
            guard written == needed else { return nil }
            return Data(out)
        }
    }

    /// The parameter sets a config packet carries, in the order CoreMedia wants them (SPS first).
    ///
    /// Filtered by NAL type rather than taking every unit: `MediaCodec` is free to put an access
    /// unit delimiter or SEI in the same buffer, and
    /// `CMVideoFormatDescriptionCreateFromH264ParameterSets` rejects the whole set if one member is
    /// not a parameter set.
    package static func parameterSets(inConfiguration data: Data, codec: AndroidVideoCodec) -> [Data] {
        let hevc = codec == .h265
        return spans(in: data) { bytes, out, cap in
            slopdesk_annexb_parameter_sets(bytes.baseAddress, bytes.count, hevc, out, cap)
        }
    }

    /// The measure-then-fill retry both walks share, and the slicing their answers name.
    private static func spans(
        in data: Data,
        _ walk: (UnsafeBufferPointer<UInt8>, UnsafeMutablePointer<SlopDeskNalSpan>?, Int) -> Int,
    ) -> [Data] {
        let bytes = [UInt8](data)
        return bytes.withUnsafeBufferPointer { input -> [Data] in
            let count = walk(input, nil, 0)
            guard count > 0 else { return [] }
            var spans = [SlopDeskNalSpan](repeating: SlopDeskNalSpan(), count: count)
            let filled = spans.withUnsafeMutableBufferPointer { room in
                walk(input, room.baseAddress, room.count)
            }
            guard filled == count else { return [] }
            return spans.map { span in
                Data(bytes[Int(span.offset)..<Int(span.offset) + Int(span.length)])
            }
        }
    }
}

/// The codecs the panel can actually display. AV1 is deliberately absent: `VTDecompressionSession`
/// gains AV1 only on M3-class hardware and later, so offering it would make the panel's ability to
/// show anything depend on which Mac the CLIENT is running — a failure that would present as a black
/// rectangle. The bridge can still be asked for it; nothing here will decode it.
package enum AndroidVideoCodec: String, Equatable {
    case h264
    case h265

    /// The door decides WHICH identifiers decode; this maps the accepted one onto the case the
    /// decode session is configured from, so the refusal is stated once rather than twice.
    package init?(streamIdentifier: String) {
        let bytes = Array(streamIdentifier.utf8)
        let decodable = bytes.withUnsafeBufferPointer { input in
            slopdesk_android_stream_decodable_codec(input.baseAddress, input.count)
        }
        guard decodable, let codec = Self(rawValue: streamIdentifier) else { return nil }
        self = codec
    }
}
