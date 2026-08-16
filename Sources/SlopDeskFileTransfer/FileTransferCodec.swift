import CSlopDeskFFI
import Foundation
import SlopDeskArena

/// PATH 4's **client end** — requests out, replies in.
///
/// Every layout lives in `rust/slopdesk-dropd`'s `client` module, beside the `protocol` module that
/// decodes what this encodes. That is the whole reason the client end is there and not here: the
/// round trip is a TEST — one walks every frame type through both ends — where two languages agreed
/// by review and nothing failed when they stopped agreeing.
///
/// This type is the Swift face of it. A request crosses as its type byte plus the scalars any frame
/// could carry and ONE borrowed blob (a name for an offer, a body for a chunk); a chunk's 256 KiB is
/// borrowed all the way to the frame rather than copied on the way. A reply crosses as a flat record
/// plus a small arena for the one string it can hold.
///
/// Validate-then-drop on untrusted bytes is unchanged and is enforced in the crate that owns the
/// layout: every read is length-checked before it slices, unknown types and truncated bodies are
/// refused rather than guessed at, and no peer-chosen length drives an allocation before it is
/// bounded by the already-capped frame payload.
public enum FileTransferCodec {
    public enum DecodeError: Error, Equatable, Sendable {
        case empty
        case unknownType(UInt8)
        case truncated
        case badUTF8
    }

    // MARK: - Encode (client → host)

    /// The full framed bytes for `request`: `[UInt32 BE payloadLength][UInt8 type][body]`.
    public static func encodeFrame(_ request: FileTransferRequest) -> Data {
        request.lent { kind, transferId, scalar, blob, blobLength in
            sized { out, cap in
                slopdesk_drop_encode_request(
                    kind, transferId, scalar, blob?.assumingMemoryBound(to: UInt8.self), blobLength,
                    out, cap,
                )
            }
        }
    }

    /// The payload only (`[UInt8 type][body]`), for callers that frame separately (e.g. tests).
    public static func encodePayload(_ request: FileTransferRequest) -> Data {
        encodeFrame(request).dropFirst(prefixByteCount)
    }

    // MARK: - Decode (host → client)

    /// Decodes one reply payload (`[UInt8 type][body]`). Throws on empty, an unknown or
    /// client-bound type, a truncated body, or invalid UTF-8 — the caller drops the frame (and
    /// typically the connection).
    ///
    /// Types 1–5 are the CLIENT's own vocabulary. Seeing one arrive means the peer is not a dropd,
    /// so they are rejected as unknown rather than decoded into something to ignore.
    public static func decodeReplyPayload(_ payload: Data) throws -> FileTransferReply {
        try withUnsafeTemporaryAllocation(of: UInt8.self, capacity: Swift.max(payload.count, 1)) { arena in
            var record = SlopDeskDropReply()
            let verdict = payload.spanning { bytes, length in
                slopdesk_drop_decode_reply(
                    bytes?.assumingMemoryBound(to: UInt8.self), length,
                    &record, arena.baseAddress, arena.count,
                )
            }
            guard verdict == SLOPDESK_DROP_OK else { throw decodeError(verdict, record.detail) }
            return reply(record, UnsafeRawBufferPointer(arena))
        }
    }

    // MARK: - Shared with the frame splitter

    /// The `[UInt32 BE payloadLength]` every frame opens with.
    static let prefixByteCount = 4

    /// The error a non-OK verdict names. `frameTooLarge` is the splitter's and never reaches here.
    static func decodeError(_ verdict: UInt32, _ detail: UInt64) -> Error {
        switch verdict {
        case SLOPDESK_DROP_UNKNOWN_TYPE: DecodeError.unknownType(UInt8(truncatingIfNeeded: detail))
        case SLOPDESK_DROP_BAD_UTF8: DecodeError.badUTF8
        case SLOPDESK_DROP_EMPTY: DecodeError.empty
        case SLOPDESK_DROP_FRAME_TOO_LARGE: FileTransferFrameDecoderError.frameTooLarge(Int(detail))
        default: DecodeError.truncated
        }
    }

    /// The reply a flattened record and its arena describe.
    static func reply(_ record: SlopDeskDropReply, _ arena: UnsafeRawBufferPointer) -> FileTransferReply {
        switch record.kind {
        case 6: .helloAck(accepted: record.accepted)
        case 7: .accept(transferId: record.transfer_id)
        case 8: .complete(transferId: record.transfer_id)
        default: .failed(transferId: record.transfer_id, reason: text(arena, record.reason))
        }
    }

    /// Reads the one string a reply can carry out of the arena the decode filled.
    ///
    /// The second of the two faces that answered `""` where the crate repairs; see ``ArenaText``.
    private static func text(_ arena: UnsafeRawBufferPointer, _ field: SlopDeskDropText) -> String {
        ArenaText.text(arena, field.offset, field.length)
    }

    /// A frame past this is carrying a BODY, and its buffer is handed over uninitialized: that is
    /// the difference between one pass over a 256 KiB chunk and two, since `Data(count:)` zero-fills
    /// every byte the encoder is about to overwrite and a gigabyte upload is four thousand chunks.
    /// Below it the frame is control traffic a few bytes long, where `Data`'s own storage costs less
    /// than the `malloc`/`free` pair that would replace it.
    private static let bodyBearingFrame = 4096

    /// Encodes by the §4 convention: ask for the size, then fill exactly that.
    ///
    /// The sizing call is free on the path that matters — a chunk's frame length is arithmetic on
    /// the body length, not a frame built and thrown away.
    private static func sized(_ call: (UnsafeMutablePointer<UInt8>?, Int) -> Int) -> Data {
        let needed = call(nil, 0)
        guard needed > 0 else { return Data() }
        guard needed >= bodyBearingFrame else {
            var out = Data(count: needed)
            out.withUnsafeMutableBytes { buffer in
                filled(call, buffer.baseAddress?.assumingMemoryBound(to: UInt8.self), needed)
            }
            return out
        }
        guard let room = malloc(needed)?.assumingMemoryBound(to: UInt8.self) else {
            preconditionFailure("out of memory framing a \(needed)-byte drop request")
        }
        filled(call, room, needed)
        return Data(bytesNoCopy: room, count: needed, deallocator: .free)
    }

    /// Fills `room` and asserts the encoder wrote exactly what it asked for.
    private static func filled(
        _ call: (UnsafeMutablePointer<UInt8>?, Int) -> Int,
        _ room: UnsafeMutablePointer<UInt8>?,
        _ needed: Int,
    ) {
        let written = call(room, needed)
        precondition(written == needed, "the drop codec sized a frame differently than it wrote it")
    }
}

private extension FileTransferRequest {
    /// Hands this request to `body` as the door's arguments, borrowing its one variable-length blob.
    ///
    /// A chunk's body is never copied to get here: it is lent straight through to the frame writer,
    /// which is the difference between one copy per 256 KiB and three.
    func lent<R>(
        _ body: (UInt8, UInt32, UInt64, UnsafeRawPointer?, Int) -> R,
    ) -> R {
        switch self {
        case let .hello(version):
            body(1, 0, UInt64(version), nil, 0)
        case let .offer(transferId, fileSize, name):
            // `withUTF8` lends the string's own storage when it is already UTF-8, which a filename
            // read from the filesystem is; `Array(name.utf8)` would copy it to say the same thing.
            withUnsafeUTF8(name) { body(2, transferId, fileSize, $0, $1) }
        case let .chunk(transferId, data):
            data.spanning { bytes, length in body(3, transferId, 0, bytes, length) }
        case let .finish(transferId):
            body(4, transferId, 0, nil, 0)
        case let .cancel(transferId):
            body(5, transferId, 0, nil, 0)
        }
    }
}

/// Hands `string`'s UTF-8 to `body` as a `(pointer, length)` pair, borrowing rather than copying
/// whenever the string is already stored as UTF-8.
private func withUnsafeUTF8<R>(_ string: String, _ body: (UnsafeRawPointer?, Int) -> R) -> R {
    var string = string
    return string.withUTF8 { body($0.baseAddress, $0.count) }
}

extension Data {
    /// Hands this buffer to `body` as the `(pointer, length)` pair the door's C entries take.
    ///
    /// An EMPTY buffer short-circuits to `(nil, 0)` rather than borrowing: `finish` and `cancel`
    /// carry no blob at all, and `withUnsafeBytes` on nothing is a borrow bought for nothing.
    @inline(__always)
    func spanning<R>(_ body: (UnsafeRawPointer?, Int) throws -> R) rethrows -> R {
        try isEmpty ? body(nil, 0) : withUnsafeBytes { try body($0.baseAddress, $0.count) }
    }
}
