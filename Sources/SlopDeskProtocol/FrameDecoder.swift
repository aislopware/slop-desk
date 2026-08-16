import CSlopDeskFFI
import Foundation

/// Incremental, streaming decoder that turns arbitrary chunks of TCP bytes into whole
/// ``WireMessage`` values.
///
/// TCP is a byte stream with no message boundaries: one `recv` may deliver half a frame, three
/// frames, or a frame split across many reads. ``append(_:)`` takes raw bytes and ``nextMessage()``
/// yields complete messages, returning `nil` whenever no complete frame is buffered yet — a partial
/// frame is **not** an error, it is the normal case.
///
/// The buffering, the cursor that avoids a per-frame memmove, the fail-stop on a lost byte-boundary
/// and the decode itself all live in `rust/slopdesk-wire`. This is the handle: a `final class` (so
/// the per-channel decoder can be held by `let` and mutated through its reference, matching the
/// owning `MuxSubChannel`/test call sites) and intentionally **not** `Sendable` — it carries
/// mutable buffer state and belongs to a single actor or task. One decoder per channel per
/// connection.
///
/// The payload never crosses twice. A decoded message's opaque byte run stays in the decoder's own
/// buffer and is copied ONCE, straight into the `Data` this hands back — the Swift decoder that
/// used to be here sliced the payload out of its buffer first and then decoded that slice.
public final class FrameDecoder {
    /// The Rust decoder. Owned outright: one `new` here, one `free` in `deinit`.
    private let handle: OpaquePointer

    public init() {
        guard let handle = slopdesk_frame_decoder_new() else {
            preconditionFailure("out of memory for a frame decoder")
        }
        self.handle = handle
    }

    deinit { slopdesk_frame_decoder_free(handle) }

    /// Appends a freshly received chunk of bytes.
    /// Safe to call with empty data, a single byte, or many frames' worth.
    /// Dropped entirely once the decoder is poisoned by a prior decode fault.
    public func append(_ data: Data) {
        guard !data.isEmpty else { return }
        data.withUnsafeBytes { bytes in
            slopdesk_frame_decoder_append(handle, bytes.baseAddress, bytes.count)
        }
    }

    /// Test-only: current buffered byte count — asserts a poisoned decoder cannot be grown by
    /// further ``append(_:)`` traffic.
    var bufferedByteCountForTesting: Int { slopdesk_frame_decoder_buffered(handle) }

    /// Returns the next complete message, or `nil` if a full frame is not yet buffered (caller
    /// should `append` more bytes and retry).
    ///
    /// - Throws: ``SlopDeskError/frameTooLarge(_:)`` if a length prefix exceeds the wire's ceiling;
    ///   or any error a body decode raises (unknown type, malformed, truncated). Every one of them
    ///   is FAIL-STOP: the byte-boundary for the whole channel is lost, so the same fault is thrown
    ///   by every later call rather than resynchronising onto attacker-chosen bytes.
    public func nextMessage() throws -> WireMessage? {
        switch try take(room: Self.scratchArena) {
        case let .message(message): return message
        case .pending: return nil
        case let .needsRoom(room):
            // Not an error and not a guess: an arena that did not fit reports the size that would
            // have, and the frame waits inside the decoder until it is asked for again.
            guard case let .message(message) = try take(room: room) else {
                throw SlopDeskError.truncated
            }
            return message
        }
    }

    /// A title, a cwd or a label fits this, and nothing else reaches the arena at all — an
    /// `.output` payload under a flood is not text and never enters it.
    private static let scratchArena = 512

    /// What one attempt at the next frame produced.
    private enum Taken {
        /// A whole frame, rebuilt.
        case message(WireMessage)
        /// No whole frame is buffered yet — append more bytes. Not an error.
        case pending
        /// A frame is waiting but its text needs this many arena bytes.
        case needsRoom(Int)
    }

    /// One frame taken into an arena of `room` bytes.
    private func take(room: Int) throws -> Taken {
        var flat = SlopDeskWireMessage()
        var verdict = UInt32(SLOPDESK_WIRE_DECODE_OK)
        var built: WireMessage?
        var reported = 0
        withUnsafeTemporaryAllocation(byteCount: max(room, 1), alignment: 1) { arena in
            verdict = slopdesk_frame_decoder_next(
                handle, &flat, arena.baseAddress, arena.count, &reported,
            )
            guard verdict == UInt32(SLOPDESK_WIRE_DECODE_OK) else { return }
            // The run is fetched INSIDE the arena's scope so the message is built once, from both
            // halves at their final addresses — and handed on as its own buffer, never re-sliced.
            built = WireMessage.build(
                flat, UnsafeRawBufferPointer(arena), fetchRun(byteCount: Int(flat.blob_length)),
            )
        }
        switch verdict {
        case UInt32(SLOPDESK_FRAME_PENDING):
            return .pending
        case UInt32(SLOPDESK_WIRE_DECODE_AGAIN):
            return .needsRoom(reported)
        case UInt32(SLOPDESK_FRAME_TOO_LARGE):
            throw SlopDeskError.frameTooLarge(reported)
        case UInt32(SLOPDESK_WIRE_DECODE_TRUNCATED):
            throw SlopDeskError.truncated
        case UInt32(SLOPDESK_WIRE_DECODE_UNKNOWN_TYPE):
            throw SlopDeskError.unknownMessageType(UInt8(truncatingIfNeeded: reported))
        case UInt32(SLOPDESK_WIRE_DECODE_MALFORMED):
            throw SlopDeskError.malformedBody("a frame's body is not what its type declares")
        default:
            break
        }
        guard let built else { throw SlopDeskError.truncated }
        return .message(built)
    }

    /// Copies the opaque byte run the last frame parked. Valid only until the next frame is taken,
    /// which is why it is fetched immediately and never held.
    private func fetchRun(byteCount: Int) -> Data {
        WireBuffer.filled(byteCount) { out in
            let copied = slopdesk_frame_decoder_run(handle, out, byteCount)
            precondition(copied == byteCount, "the decoder parked a run of a different length")
        }
    }
}
