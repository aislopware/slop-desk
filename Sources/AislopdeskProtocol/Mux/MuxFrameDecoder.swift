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

    /// Reclaim the consumed prefix once the read cursor has advanced past this many bytes, so the
    /// buffer's wasted head stays bounded during a long burst. 64 KiB == the max single `recv` chunk,
    /// so in the common case compaction happens at most once per received chunk.
    private static let compactionThreshold = 64 * 1024

    /// Received bytes. Completed frames are NOT removed per-parse (that front-removal memmoves the
    /// entire tail forward — O(n) per frame, O(n²) for a chunk of many small frames). Instead a
    /// ``readOffset`` cursor advances past consumed frames and the head is compacted LAZILY (on a
    /// drain that returns `nil`, or when the cursor crosses ``compactionThreshold``), amortizing total
    /// work to O(bytes). All indexing is relative to `buffer.startIndex + readOffset`.
    private var buffer = Data()

    /// Number of leading bytes in ``buffer`` already consumed by completed frames but not yet
    /// physically removed (reclaimed by ``compactConsumed()``).
    private var readOffset = 0

    public init() {}

    /// Appends a freshly received chunk of bytes to the internal buffer.
    /// Safe to call with empty data, a single byte, or many frames' worth.
    public mutating func append(_ data: Data) {
        buffer.append(data)
    }

    /// Returns the next complete mux frame, or `nil` if a full frame is not yet
    /// buffered (caller should `append` more bytes and retry).
    ///
    /// - Throws: ``AislopdeskError/frameTooLarge(_:)`` if a length prefix exceeds
    ///   ``Aislopdesk/maxFramePayloadLength``; or any error from
    ///   ``MuxEnvelopeCodec/decode(inner:)`` (unknown mux type, malformed/truncated
    ///   body).
    public mutating func nextFrame() throws -> MuxFrame? {
        // Bytes not yet consumed by a completed frame.
        let available = buffer.count - readOffset
        // Need at least the length prefix to know how big the frame is.
        guard available >= Self.prefixLength else { compactConsumed()
            return nil
        }

        let muxFrameLength = Int(readPrefix())

        // Reject implausibly large frames before allocating / waiting for them.
        guard muxFrameLength <= Aislopdesk.maxFramePayloadLength else {
            throw AislopdeskError.frameTooLarge(muxFrameLength)
        }

        // Wait until the whole inner run has arrived (partial read — not an error).
        let frameLength = Self.prefixLength + muxFrameLength
        guard available >= frameLength else { compactConsumed()
            return nil
        }

        // Slice out the inner run (after the prefix) and ADVANCE the cursor past the frame (no
        // per-frame front-removal). `base` is the absolute index of this frame's first byte.
        let base = buffer.startIndex + readOffset
        let innerStart = base + Self.prefixLength
        let inner = Data(buffer[innerStart..<base + frameLength])
        readOffset += frameLength
        // Bound the wasted head mid-burst; a drain that returns nil reclaims the rest.
        if readOffset >= Self.compactionThreshold { compactConsumed() }

        return try MuxEnvelopeCodec.decode(inner: inner)
    }

    /// Physically drops the consumed prefix (`readOffset` bytes) from the front of the buffer ONCE,
    /// resetting the cursor — the single O(remaining) memmove that replaces the per-frame one.
    private mutating func compactConsumed() {
        guard readOffset > 0 else { return }
        buffer.removeSubrange(buffer.startIndex..<buffer.startIndex + readOffset)
        readOffset = 0
    }

    /// Reads the 4-byte big-endian length prefix at the cursor without consuming it. (The cursor
    /// advances in ``nextFrame()`` once the full frame is confirmed present, so an incomplete frame
    /// leaves the prefix in place for the next call.)
    private func readPrefix() -> UInt32 {
        let base = buffer.startIndex + readOffset
        var value: UInt32 = 0
        for i in 0..<Self.prefixLength {
            value = (value << 8) | UInt32(buffer[base + i])
        }
        return value
    }
}
