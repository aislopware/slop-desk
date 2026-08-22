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
        spans(in: data) { bytes, count, out, cap in
            slopdesk_annexb_split(bytes, count, out, cap)
        }
    }

    /// How much bigger than its Annex-B input an AVCC rewrite can be, before the retry.
    ///
    /// A rewrite trades each start code for a four-byte length, so it GROWS by one byte per NAL
    /// that arrived under a three-byte start code and by nothing otherwise. An access unit is a
    /// handful of NALs — a `MediaCodec` frame is one slice plus at most an AUD and an SEI — so this
    /// slack covers two hundred and fifty-six of them and the retry below never runs. A buffer
    /// pathological enough to exceed it still gets the right answer, at exactly what the discarded
    /// probe used to cost.
    private static let avccSlack = 256

    /// Rewrites an Annex-B access unit as AVCC: every NAL prefixed with its 4-byte big-endian length.
    ///
    /// Returns `nil` for a buffer with no start code at all rather than passing it through — a
    /// payload that is already length-prefixed would be silently mis-framed, and the panel would show
    /// a decoder that produces nothing with no clue why.
    ///
    /// ## Why the buffer is GUESSED and not asked for
    /// This runs once per ACCESS UNIT — sixty times a second while a device is mirrored. Asking
    /// `(NULL, 0)` for the length first walked the whole buffer, built the rewritten `Vec` and threw
    /// it away, then did it again. Measured against the shipped `macos-arm64` slice, `swiftc -O`,
    /// two runs agreeing: a 40 KB delta frame went **62.0/63.4 µs → 35.3/33.7 µs**, a 300 KB
    /// keyframe **500.9/474.9 µs → 265.3/234.2 µs**. The `[UInt8](data)` that used to precede it is
    /// gone too: `Data` already owns contiguous bytes and lending them is what `withUnsafeBytes` is
    /// for, so a whole frame no longer crosses into an array on its way to a door that only reads it.
    package static func avccAccessUnit(from data: Data) -> Data? {
        data.withUnsafeBytes { raw -> Data? in
            let input = raw.baseAddress?.assumingMemoryBound(to: UInt8.self)
            var out = [UInt8](repeating: 0, count: raw.count + avccSlack)
            var needed = out.withUnsafeMutableBufferPointer { room in
                slopdesk_annexb_to_avcc(input, raw.count, room.baseAddress, room.count)
            }
            if needed > out.count {
                out = [UInt8](repeating: 0, count: needed)
                needed = out.withUnsafeMutableBufferPointer { room in
                    slopdesk_annexb_to_avcc(input, raw.count, room.baseAddress, room.count)
                }
            }
            // Zero is REFUSED, not "did not fit": a real rewrite costs at least its length prefix.
            guard needed > 0, needed <= out.count else { return nil }
            out.removeLast(out.count - needed)
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
        return spans(in: data) { bytes, count, out, cap in
            slopdesk_annexb_parameter_sets(bytes, count, hevc, out, cap)
        }
    }

    /// How many units the first array offers, before the retry.
    ///
    /// A config packet carries two or three parameter sets and an access unit a handful of NALs, so
    /// this is the same "generous by an order of magnitude" guess ``avccSlack`` is. Sixteen
    /// sixteen-byte records is a stack-sized allocation against a walk over a whole frame.
    private static let spanFloor = 16

    /// The guess-then-fill retry both walks share, and the slicing their answers name.
    ///
    /// Asking `(NULL, 0)` for the count first walked the entire buffer for a number the walk that
    /// follows re-derives — the same 2× the rewrite above measured, over the same bytes. The walk
    /// answers WHERE each unit sits and the payloads never crossed; now the buffer they sit in does
    /// not cross into a `[UInt8]` either, which for a keyframe was a third of a megabyte copied to
    /// be read.
    private static func spans(
        in data: Data,
        _ walk: (UnsafePointer<UInt8>?, Int, UnsafeMutablePointer<SlopDeskNalSpan>?, Int) -> Int,
    ) -> [Data] {
        data.withUnsafeBytes { raw -> [Data] in
            let input = raw.baseAddress?.assumingMemoryBound(to: UInt8.self)
            var spans = [SlopDeskNalSpan](repeating: SlopDeskNalSpan(), count: spanFloor)
            var count = spans.withUnsafeMutableBufferPointer { room in
                walk(input, raw.count, room.baseAddress, room.count)
            }
            if count > spans.count {
                spans = [SlopDeskNalSpan](repeating: SlopDeskNalSpan(), count: count)
                count = spans.withUnsafeMutableBufferPointer { room in
                    walk(input, raw.count, room.baseAddress, room.count)
                }
            }
            guard count > 0, count <= spans.count else { return [] }
            return spans.prefix(count).map { span in
                Data(UnsafeRawBufferPointer(
                    rebasing: raw[Int(span.offset)..<Int(span.offset) + Int(span.length)],
                ))
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
    /// decode session is configured from.
    ///
    /// The second `guard` clause is not a second opinion — `slopdesk_android_stream_decodable_codec`
    /// accepts exactly the identifiers this case list spells, so it cannot fire without the two
    /// having diverged. It is there because Swift's `RawRepresentable` init is failable and there is
    /// no total spelling of the same lookup. Read it as the tax, not as the rule: the set of
    /// displayable codecs is `slopdesk_androidd::scrcpy`'s, and this type may narrow that set by
    /// having fewer cases but may never widen it by accepting a string the door refused.
    package init?(streamIdentifier: String) {
        let bytes = Array(streamIdentifier.utf8)
        let decodable = bytes.withUnsafeBufferPointer { input in
            slopdesk_android_stream_decodable_codec(input.baseAddress, input.count)
        }
        guard decodable, let codec = Self(rawValue: streamIdentifier) else { return nil }
        self = codec
    }
}
