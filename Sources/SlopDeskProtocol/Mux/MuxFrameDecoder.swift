import CSlopDeskFFI
import Foundation

/// Incremental, streaming splitter that turns arbitrary chunks of TCP bytes into whole ``MuxFrame``
/// values — the DIRECT analogue of ``FrameDecoder`` one layer up (mux envelopes instead of terminal
/// ``WireMessage`` frames).
///
/// TCP is a byte stream with no message boundaries: one `recv` may deliver half a mux frame, three
/// frames, or a frame split across many reads. ``append(_:)`` takes raw bytes and ``nextFrame()``
/// yields complete frames, returning `nil` whenever no complete frame is buffered yet — a partial
/// frame is **not** an error.
///
/// The buffering, the cursor that avoids a per-frame memmove, the fail-stop on a lost byte-boundary
/// and the decode itself all live in `rust/slopdesk-wire`. This is the handle: a `final class` and
/// intentionally **not** `Sendable` — it carries mutable buffer state and belongs to a single actor
/// or task. One decoder per physical mux connection.
///
/// A `channelData` payload never crosses twice. It stays in the decoder's own buffer and is copied
/// ONCE, straight into the `Data` this hands back.
public final class MuxFrameDecoder {
    /// The Rust decoder. Owned outright: one `new` here, one `free` in `deinit`.
    private let handle: OpaquePointer

    public init() {
        guard let handle = slopdesk_mux_decoder_new() else {
            preconditionFailure("out of memory for a mux frame decoder")
        }
        self.handle = handle
    }

    deinit { slopdesk_mux_decoder_free(handle) }

    /// Appends a freshly received chunk of bytes.
    /// Safe to call with empty data, a single byte, or many frames' worth.
    /// Dropped entirely once the decoder is poisoned by a prior decode fault.
    public func append(_ data: Data) {
        guard !data.isEmpty else { return }
        data.withUnsafeBytes { bytes in
            slopdesk_mux_decoder_append(handle, bytes.baseAddress, bytes.count)
        }
    }

    /// Test-only: current buffered byte count — asserts a poisoned decoder cannot be grown by
    /// further ``append(_:)`` traffic.
    var bufferedByteCountForTesting: Int { slopdesk_mux_decoder_buffered(handle) }

    /// Returns the next complete mux frame, or `nil` if a full frame is not yet buffered (caller
    /// should `append` more bytes and retry).
    ///
    /// - Throws: ``SlopDeskError/frameTooLarge(_:)`` if a length prefix exceeds the wire's ceiling;
    ///   or any error a body decode raises (unknown mux type, malformed, truncated). Every one of
    ///   them is FAIL-STOP: the byte-boundary for the whole connection is lost, so the same fault is
    ///   thrown by every later call rather than resynchronising onto attacker-chosen bytes.
    public func nextFrame() throws -> MuxFrame? {
        switch try take(room: Self.scratchArena) {
        case let .frame(frame): return frame
        case .pending: return nil
        case let .needsRoom(room):
            // Not an error and not a guess: an arena that did not fit reports the size that would,
            // and the frame waits inside the decoder until it is asked for again.
            guard case let .frame(frame) = try take(room: room) else {
                throw SlopDeskError.truncated
            }
            return frame
        }
    }

    /// A cwd fits this, and it is the only text a mux envelope carries — a `.channelData` payload
    /// under a flood is not text and never enters the arena at all.
    private static let scratchArena = 1024

    /// What one attempt at the next frame produced.
    private enum Taken {
        /// A whole envelope, rebuilt.
        case frame(MuxFrame)
        /// No whole envelope is buffered yet — append more bytes. Not an error.
        case pending
        /// An envelope is waiting but its cwd needs this many arena bytes.
        case needsRoom(Int)
    }

    /// One envelope taken into an arena of `room` bytes.
    private func take(room: Int) throws -> Taken {
        var flat = SlopDeskMuxFrame()
        var verdict = UInt32(SLOPDESK_WIRE_DECODE_OK)
        var built: MuxFrame?
        var reported = 0
        withUnsafeTemporaryAllocation(byteCount: max(room, 1), alignment: 1) { arena in
            verdict = slopdesk_mux_decoder_next(
                handle, &flat, arena.baseAddress, arena.count, &reported,
            )
            guard verdict == UInt32(SLOPDESK_WIRE_DECODE_OK) else { return }
            // The payload is fetched INSIDE the arena's scope so the frame is built once, from both
            // halves at their final addresses — and handed on as its own buffer, never re-sliced.
            built = MuxFrame.build(
                flat, UnsafeRawBufferPointer(arena), fetchPayload(byteCount: Int(flat.payload_length)),
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
            throw SlopDeskError.malformedBody("a mux frame's body is not what its type declares")
        default:
            break
        }
        guard let built else { throw SlopDeskError.truncated }
        return .frame(built)
    }

    /// Copies the opaque payload the last frame parked. Valid only until the next frame is taken,
    /// which is why it is fetched immediately and never held.
    private func fetchPayload(byteCount: Int) -> Data {
        WireBuffer.filled(byteCount) { out in
            let copied = slopdesk_mux_decoder_payload(handle, out, byteCount)
            precondition(copied == byteCount, "the decoder parked a payload of a different length")
        }
    }
}
