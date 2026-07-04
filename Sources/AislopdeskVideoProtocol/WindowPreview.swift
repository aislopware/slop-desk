import Foundation

/// Pure chunking/reassembly for the one-shot window-snapshot preview (MERIDIAN C4 — control
/// types 16/17). The control channel is plain UDP with no packetizer/FEC, so a JPEG snapshot is
/// split into ≤ ``VideoControlMessage/previewChunkPayloadMax``-byte chunks host-side and stitched
/// back client-side. Both halves are PURE (no sockets, no images) so the whole wire path is
/// headless-tested; the host/client only encode/decode and shuttle datagrams.
///
/// Loss model: a preview is decorative (the picker/sidebar falls back to the monogram plate), so a
/// lost chunk simply abandons the image — no retransmit protocol. The client-minted `token` is
/// echoed on every chunk so a straggler reply from an EARLIER request can never be stitched into
/// the current image (validate-then-drop, not crash).
public enum WindowPreviewChunker {
    /// Split one encoded image into `windowPreviewChunk` messages. Returns `nil` when the image
    /// cannot fit ``VideoControlMessage/previewChunkCountMax`` chunks (the caller re-encodes at a
    /// lower quality/scale and tries again) or is empty.
    public static func chunks(
        token: UInt32,
        windowID: UInt32,
        imageWidth: UInt16,
        imageHeight: UInt16,
        jpeg: Data,
    ) -> [VideoControlMessage]? {
        let payloadMax = VideoControlMessage.previewChunkPayloadMax
        guard !jpeg.isEmpty else { return nil }
        let count = (jpeg.count + payloadMax - 1) / payloadMax
        guard count <= VideoControlMessage.previewChunkCountMax else { return nil }
        // Re-base to a zero-indexed buffer: `jpeg` may be a slice with a non-zero startIndex, and
        // the chunk math below indexes from 0.
        let bytes = Data(jpeg)
        return (0..<count).map { index in
            let start = index * payloadMax
            let end = Swift.min(start + payloadMax, bytes.count)
            return .windowPreviewChunk(
                token: token,
                windowID: windowID,
                imageWidth: imageWidth,
                imageHeight: imageHeight,
                chunkIndex: UInt16(index),
                chunkCount: UInt16(count),
                payload: bytes.subdata(in: start..<end),
            )
        }
    }
}

/// Reassembles ``VideoControlMessage/windowPreviewChunk(token:windowID:imageWidth:imageHeight:chunkIndex:chunkCount:payload:)``
/// datagrams for ONE outstanding request. Every field of an incoming chunk is validated against the
/// request (token) and against the first accepted chunk (count/dimensions) — a mismatching or
/// out-of-range chunk is DROPPED, never trapped on (untrusted UDP). Duplicate chunks (host
/// retransmit / network dup) are idempotent.
public struct WindowPreviewAssembler {
    /// A fully reassembled preview: the encoded image bytes plus the decoded pixel dimensions the
    /// host declared (so the client can reserve layout before decoding).
    public struct Image: Equatable, Sendable {
        public let data: Data
        public let width: UInt16
        public let height: UInt16
    }

    private let token: UInt32
    private var expectedCount: Int?
    private var width: UInt16 = 0
    private var height: UInt16 = 0
    private var parts: [Int: Data] = [:]

    public init(token: UInt32) {
        self.token = token
    }

    /// Feed one control message; non-chunk messages and chunks that fail validation are ignored.
    /// Returns the assembled image once ALL chunks are present, else `nil`.
    public mutating func feed(_ message: VideoControlMessage) -> Image? {
        guard case let .windowPreviewChunk(token, _, iw, ih, chunkIndex, chunkCount, payload) = message,
              token == self.token
        else { return nil }
        let count = Int(chunkCount)
        // Structural validation FIRST, so a malformed chunk can never pin the geometry below:
        // count in budget, index in range, payload within the per-datagram cap, and every
        // non-final chunk FULL — the chunker emits payloadMax-sized chunks with only the last one
        // short, so a short middle chunk is a corrupt datagram (accepting it would silently splice
        // a truncated image).
        guard count >= 1, count <= VideoControlMessage.previewChunkCountMax,
              Int(chunkIndex) < count,
              payload.count <= VideoControlMessage.previewChunkPayloadMax
        else { return nil }
        if Int(chunkIndex) < count - 1, payload.count != VideoControlMessage.previewChunkPayloadMax {
            return nil
        }
        // First structurally-valid chunk pins the geometry; every later chunk must agree (a host
        // never changes its answer mid-image — disagreement means a stale/corrupt datagram).
        if let expected = expectedCount {
            guard count == expected, iw == width, ih == height else { return nil }
        } else {
            expectedCount = count
            width = iw
            height = ih
        }
        parts[Int(chunkIndex)] = payload
        guard parts.count == count else { return nil }
        var data = Data()
        for index in 0..<count {
            guard let part = parts[index] else { return nil }
            data.append(part)
        }
        return Image(data: data, width: width, height: height)
    }
}
