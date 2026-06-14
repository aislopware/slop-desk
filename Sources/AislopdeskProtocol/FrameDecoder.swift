import Foundation

/// Incremental, streaming decoder that turns arbitrary chunks of TCP bytes into
/// whole ``WireMessage`` values.
///
/// TCP is a byte stream with no message boundaries: one `recv` may deliver half a
/// frame, three frames, or a frame split across many reads. `FrameDecoder` buffers
/// raw bytes via ``append(_:)`` and yields complete messages via ``nextMessage()``,
/// returning `nil` whenever no complete frame is buffered yet (it simply waits for
/// more bytes — a partial frame is **not** an error).
///
/// This is a value type. It is intentionally **not** `Sendable`: it carries mutable
/// buffer state and is meant to live inside a single actor / task (e.g. the
/// per-connection receive loop). One decoder per channel per connection.
public struct FrameDecoder {
    /// Length of the big-endian `UInt32` frame-length prefix.
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

    /// Returns the next complete message, or `nil` if a full frame is not yet
    /// buffered (caller should `append` more bytes and retry).
    ///
    /// - Throws: ``AislopdeskError/frameTooLarge(_:)`` if a length prefix exceeds
    ///   ``Aislopdesk/maxFramePayloadLength``; or any error from
    ///   ``WireMessage/decode(payload:)`` (unknown type, malformed/truncated body).
    public mutating func nextMessage() throws -> WireMessage? {
        // Bytes not yet consumed by a completed frame.
        let available = buffer.count - readOffset
        // Need at least the length prefix to know how big the frame is.
        guard available >= Self.prefixLength else { compactConsumed()
            return nil
        }

        let payloadLength = Int(readPrefix())

        // Reject implausibly large frames before allocating / waiting for them.
        guard payloadLength <= Aislopdesk.maxFramePayloadLength else {
            throw AislopdeskError.frameTooLarge(payloadLength)
        }

        // Wait until the whole payload has arrived (partial read — not an error).
        let frameLength = Self.prefixLength + payloadLength
        guard available >= frameLength else { compactConsumed()
            return nil
        }

        // Slice out the payload (after the prefix) and ADVANCE the cursor past the frame (no per-frame
        // front-removal). `base` is the absolute index of this frame's first byte.
        let base = buffer.startIndex + readOffset
        let payloadStart = base + Self.prefixLength
        let payload = Data(buffer[payloadStart..<base + frameLength])
        readOffset += frameLength
        // Bound the wasted head mid-burst; a drain that returns nil reclaims the rest.
        if readOffset >= Self.compactionThreshold { compactConsumed() }

        return try WireMessage.decode(payload: payload)
    }

    /// Physically drops the consumed prefix (`readOffset` bytes) from the front of the buffer ONCE,
    /// resetting the cursor — the single O(remaining) memmove that replaces the per-frame one.
    private mutating func compactConsumed() {
        guard readOffset > 0 else { return }
        buffer.removeSubrange(buffer.startIndex..<buffer.startIndex + readOffset)
        readOffset = 0
    }

    /// Reads the 4-byte big-endian length prefix at the cursor without consuming it. (The cursor
    /// advances in ``nextMessage()`` once the full frame is confirmed present, so an incomplete frame
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
