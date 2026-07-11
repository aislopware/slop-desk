import Foundation

/// PURE client-side assembler for `blobChunk` sequences (docs/45 Phase 3/4): app icons (kind 0,
/// PNG) and window previews (kind 1, JPEG). One shared reassembler for every blob kind — chunks
/// key on (kind, blobID), duplicates overwrite idempotently, and untrusted input is capped by the
/// per-kind byte limits (an over-cap assembly is discarded, never delivered).
public struct BlobAssembler: Sendable {
    /// One fully assembled blob.
    public struct CompleteBlob: Equatable, Sendable {
        public var blobKind: UInt8
        public var blobID: UInt64
        public var metaA: UInt16
        public var metaB: UInt16
        public var bytes: Data

        public init(blobKind: UInt8, blobID: UInt64, metaA: UInt16, metaB: UInt16, bytes: Data) {
            self.blobKind = blobKind
            self.blobID = blobID
            self.metaA = metaA
            self.metaB = metaB
            self.bytes = bytes
        }
    }

    public static let iconKind: UInt8 = 0
    public static let previewKind: UInt8 = 1

    /// Per-kind assembled-size caps (validate-then-drop; anything else is hostile padding).
    public static func maxBytes(forKind kind: UInt8) -> Int {
        switch kind {
        case iconKind: VideoControlMessage.iconBlobMaxBytes
        case previewKind: VideoControlMessage.previewBlobMaxBytes
        default: 0 // unknown kinds assemble to nothing (future kinds bump the codec first)
        }
    }

    private struct Key: Hashable {
        let kind: UInt8
        let id: UInt64
    }

    private struct Partial {
        var chunkCount: UInt8
        var metaA: UInt16
        var metaB: UInt16
        var received: [UInt8: Data] = [:]
    }

    /// Concurrent partial blobs kept (icons fetch one-at-a-time; previews are single-flight — 4 is
    /// generous headroom, and the bound stops a hostile sender growing the map).
    public static let maxPartialBlobs = 4

    private var partials: [Key: Partial] = [:]
    private var insertionOrder: [Key] = []

    public init() {}

    /// Folds one decoded chunk. Returns the completed blob when this chunk finishes it, else `nil`.
    public mutating func fold(
        blobKind: UInt8,
        blobID: UInt64,
        metaA: UInt16,
        metaB: UInt16,
        chunkIndex: UInt8,
        chunkCount: UInt8,
        bytes: Data,
    ) -> CompleteBlob? {
        let cap = Self.maxBytes(forKind: blobKind)
        guard cap > 0 else { return nil }
        let key = Key(kind: blobKind, id: blobID)
        var partial: Partial
        if let existing = partials[key] {
            guard existing.chunkCount == chunkCount else {
                // Disagreeing chunkCount = corruption/hostile — the whole blob is discarded (the
                // requester's re-request fetches it whole; the host caches encoded bytes).
                discard(key)
                return nil
            }
            partial = existing
        } else {
            if partials.count >= Self.maxPartialBlobs, let oldest = insertionOrder.first {
                discard(oldest)
            }
            partial = Partial(chunkCount: chunkCount, metaA: metaA, metaB: metaB)
            insertionOrder.append(key)
        }
        partial.received[chunkIndex] = bytes
        guard partial.received.count == Int(chunkCount) else {
            partials[key] = partial
            return nil
        }
        discard(key)
        var assembled = Data()
        for index in 0..<chunkCount {
            assembled += partial.received[index] ?? Data()
            guard assembled.count <= cap else { return nil } // hostile padding — cap the accumulator
        }
        return CompleteBlob(
            blobKind: blobKind, blobID: blobID, metaA: partial.metaA, metaB: partial.metaB,
            bytes: assembled,
        )
    }

    private mutating func discard(_ key: Key) {
        partials[key] = nil
        insertionOrder.removeAll { $0 == key }
    }

    /// Drops all partial state (round teardown).
    public mutating func reset() {
        partials.removeAll()
        insertionOrder.removeAll()
    }
}

/// Image-magic validation for assembled blobs (docs/45: "PNG/JPEG magic validated on reassembly;
/// malformed blobs discarded and never poison the disk cache"). Pure byte checks — decoding stays
/// with the consumer.
public enum BlobImageValidator {
    /// The 8-byte PNG signature.
    public static func looksLikePNG(_ data: Data) -> Bool {
        data.count > 8 && data.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    }

    /// The JPEG SOI marker (FF D8 FF).
    public static func looksLikeJPEG(_ data: Data) -> Bool {
        data.count > 3 && data.prefix(3) == Data([0xFF, 0xD8, 0xFF])
    }

    /// The expected magic per blob kind.
    public static func validates(_ data: Data, forKind kind: UInt8) -> Bool {
        switch kind {
        case BlobAssembler.iconKind: looksLikePNG(data)
        case BlobAssembler.previewKind: looksLikeJPEG(data)
        default: false
        }
    }
}

/// The HOST-side counterpart: splits an encoded image into ready-to-send `blobChunk` payloads, each
/// fitting one mux datagram (``VideoControlMessage/blobBytesPerChunk``).
public enum BlobChunker {
    /// `nil` when the blob exceeds its kind's cap or needs more than 255 chunks (never legitimate —
    /// callers cap at encode time; this is the defensive bound).
    public static func encodedChunks(
        blobKind: UInt8,
        blobID: UInt64,
        metaA: UInt16,
        metaB: UInt16,
        bytes: Data,
    ) -> [Data]? {
        guard !bytes.isEmpty, bytes.count <= BlobAssembler.maxBytes(forKind: blobKind) else { return nil }
        let per = VideoControlMessage.blobBytesPerChunk
        let count = (bytes.count + per - 1) / per
        guard count <= Int(UInt8.max) else { return nil }
        return (0..<count).map { index in
            let start = bytes.index(bytes.startIndex, offsetBy: index * per)
            let end = bytes.index(start, offsetBy: min(per, bytes.distance(from: start, to: bytes.endIndex)))
            return VideoControlMessage.blobChunk(
                blobKind: blobKind, blobID: blobID, metaA: metaA, metaB: metaB,
                chunkIndex: UInt8(index), chunkCount: UInt8(count), bytes: Data(bytes[start..<end]),
            ).encode()
        }
    }

    /// FNV-1a 64 over the bundleID's UTF-8 — the icon blobID (stable, no string on the reply wire).
    public static func fnv1a64(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }
}
