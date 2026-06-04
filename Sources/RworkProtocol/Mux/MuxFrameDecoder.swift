import Foundation

/// Incremental, streaming splitter that turns arbitrary chunks of TCP bytes into
/// whole ``MuxFrame`` values — the DIRECT analogue of ``FrameDecoder`` one layer up
/// (mux envelopes instead of terminal ``WireMessage`` frames).
///
/// TCP is a byte stream with no message boundaries: one `recv` may deliver half a
/// mux frame, three frames, or a frame split across many reads. `MuxFrameDecoder`
/// buffers raw bytes via ``append(_:)`` and yields complete frames via
/// ``nextFrame()``, returning `nil` whenever no complete frame is buffered yet (it
/// simply waits for more bytes — a partial frame is **not** an error).
///
/// This is a value type. Like ``FrameDecoder`` it is intentionally **not** `Sendable`:
/// it carries mutable buffer state and is meant to live inside a single actor / task
/// (e.g. the per-connection receive loop). One decoder per physical mux connection.
public struct MuxFrameDecoder {
    /// Length of the big-endian `UInt32` mux-frame-length prefix.
    private static let prefixLength = 4

    /// Unconsumed received bytes. Completed frames are dropped from the front as
    /// they are parsed.
    private var buffer = Data()

    public init() {}

    /// Appends a freshly received chunk of bytes to the internal buffer.
    /// Safe to call with empty data, a single byte, or many frames' worth.
    public mutating func append(_ data: Data) {
        buffer.append(data)
    }

    /// Returns the next complete mux frame, or `nil` if a full frame is not yet
    /// buffered (caller should `append` more bytes and retry).
    ///
    /// - Throws: ``RworkError/frameTooLarge(_:)`` if a length prefix exceeds
    ///   ``Rwork/maxFramePayloadLength``; or any error from
    ///   ``MuxEnvelopeCodec/decode(inner:)`` (unknown mux type, malformed/truncated
    ///   body).
    public mutating func nextFrame() throws -> MuxFrame? {
        // Need at least the length prefix to know how big the frame is.
        guard buffer.count >= Self.prefixLength else { return nil }

        let muxFrameLength = Int(readPrefix())

        // Reject implausibly large frames before allocating / waiting for them.
        guard muxFrameLength <= Rwork.maxFramePayloadLength else {
            throw RworkError.frameTooLarge(muxFrameLength)
        }

        // Wait until the whole inner run has arrived (partial read — not an error).
        let frameLength = Self.prefixLength + muxFrameLength
        guard buffer.count >= frameLength else { return nil }

        // Slice out the inner run (after the prefix) and consume the frame bytes.
        let start = buffer.startIndex
        let innerStart = start + Self.prefixLength
        let inner = Data(buffer[innerStart ..< start + frameLength])
        buffer.removeSubrange(start ..< start + frameLength)

        return try MuxEnvelopeCodec.decode(inner: inner)
    }

    /// Reads the 4-byte big-endian length prefix at the front of the buffer without
    /// consuming it. (Consumption happens in ``nextFrame()`` once the full frame is
    /// confirmed present, so an incomplete frame leaves the prefix in place for the
    /// next call.)
    private func readPrefix() -> UInt32 {
        let start = buffer.startIndex
        var value: UInt32 = 0
        for i in 0 ..< Self.prefixLength {
            value = (value << 8) | UInt32(buffer[start + i])
        }
        return value
    }
}
