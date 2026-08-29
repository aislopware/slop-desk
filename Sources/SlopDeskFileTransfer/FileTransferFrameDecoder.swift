import CSlopDeskFFI
import Foundation

/// Incremental splitter that turns arbitrary TCP chunks into whole ``FileTransferReply`` values.
///
/// The buffer, the read cursor, the lazy head compaction and the poison-on-fault all live in
/// `rust/slopdesk-dropd`'s `ReplyFrameDecoder`, beside the payload decode they hand bytes to. This
/// type is the handle: Rust owns the state, Swift owns the lifetime — the shape `SlopDeskProtocol.FrameDecoder`
/// and `SlopDeskReplay` already cross by, and the right one here because half a length prefix in one
/// `recv` and the rest in the next is the ordinary case, not the edge.
///
/// A partial frame is NOT an error — ``nextReply()`` returns `nil` and waits for more bytes. A
/// decode fault (oversize length, malformed payload) POISONS the decoder: the byte boundary for the
/// whole stream is lost, so every later byte is untrustworthy — further ``append(_:)`` is dropped and
/// ``nextReply()`` rethrows the original fault (fail-stop, never resync onto attacker bytes).
///
/// A reference type, intentionally NOT `Sendable`: it owns one Rust splitter and is driven by a
/// single per-connection receive loop. One decoder per physical connection.
public final class FileTransferFrameDecoder {
    private let handle: OpaquePointer

    public init() {
        guard let handle = slopdesk_drop_decoder_new() else {
            preconditionFailure("the drop splitter could not be built")
        }
        self.handle = handle
    }

    deinit { slopdesk_drop_decoder_free(handle) }

    /// Appends a freshly received chunk. A no-op once poisoned (the buffer was cleared at the fault,
    /// so a peer holding the socket open cannot grow it without bound).
    public func append(_ data: Data) {
        data.spanning { bytes, length in
            slopdesk_drop_decoder_append(handle, bytes?.assumingMemoryBound(to: UInt8.self), length)
        }
    }

    /// Test-only: buffered byte count — asserts a poisoned decoder cannot be grown further.
    var bufferedByteCountForTesting: Int { slopdesk_drop_decoder_buffered(handle) }

    /// Returns the next complete reply, or `nil` if a full frame is not yet buffered.
    ///
    /// The arena is sized by what is BUFFERED: a string inside the next frame cannot be longer than
    /// the bytes already held, so one call always suffices and there is no probing round trip.
    ///
    /// - Throws: ``FileTransferFrameDecoderError/frameTooLarge(_:)`` if a length prefix exceeds
    ///   ``FileTransferProtocolConstants/maxFramePayloadLength``, or any ``FileTransferCodec/DecodeError``
    ///   from a malformed payload.
    public func nextReply() throws -> FileTransferReply? {
        let buffered = slopdesk_drop_decoder_buffered(handle)
        return try withUnsafeTemporaryAllocation(of: UInt8.self, capacity: Swift.max(buffered, 1)) { arena in
            var record = SlopDeskDropReply()
            let verdict = slopdesk_drop_decoder_next(handle, &record, arena.baseAddress, arena.count)
            switch verdict {
            case SLOPDESK_DROP_PENDING: return nil
            case SLOPDESK_DROP_OK: return FileTransferCodec.reply(record, UnsafeRawBufferPointer(arena))
            default: throw FileTransferCodec.decodeError(verdict, record.detail)
            }
        }
    }
}

public enum FileTransferFrameDecoderError: Error, Equatable, Sendable {
    /// A length prefix exceeded the frame-payload cap — rejected before allocating or waiting.
    case frameTooLarge(Int)
}
