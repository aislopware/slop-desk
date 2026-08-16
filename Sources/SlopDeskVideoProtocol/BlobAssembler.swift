import CSlopDeskFFI
import Foundation

/// The Swift face of `rust/slopdesk-video`'s `blob`, reached through the door of the same name.
///
/// PURE client-side assembler for `blobChunk` sequences (docs/45 Phase 3/4): app icons (kind 0,
/// PNG) and window previews (kind 1, JPEG). One shared reassembler for every blob kind — chunks
/// key on (kind, blobID), duplicates overwrite idempotently, and untrusted input is capped by the
/// per-kind byte limits (an over-cap assembly is discarded, never delivered).
///
/// A HANDLE, and therefore a CLASS, for the reason the audio stage is one: the assembly's whole
/// product IS the bytes, and they accumulate across many calls — up to four partial blobs, each up
/// to its kind's cap. Folding that through a by-value record would copy the accumulator on every
/// chunk of every blob. The completed bytes come back in two steps because this side cannot know
/// their length until the chunk that finishes them arrives.
public final class BlobAssembler: @unchecked Sendable {
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

    /// The kinds and the partial bound, from the door, so neither language writes them down twice.
    private static let kinds = slopdesk_blob_kinds()
    public static var iconKind: UInt8 { kinds.icon }
    public static var previewKind: UInt8 { kinds.preview }
    /// Concurrent partial blobs kept (icons fetch one-at-a-time; previews are single-flight — 4 is
    /// generous headroom, and the bound stops a hostile sender growing the map).
    public static var maxPartialBlobs: Int { kinds.max_partial_blobs }

    /// Per-kind assembled-size caps (validate-then-drop; anything else is hostile padding).
    public static func maxBytes(forKind kind: UInt8) -> Int {
        slopdesk_blob_max_bytes(kind)
    }

    /// The partial assemblies, and any blob a fold completed and no take has claimed yet.
    private let handle: OpaquePointer?

    public init() {
        handle = slopdesk_blob_assembler_new()
    }

    deinit {
        slopdesk_blob_assembler_free(handle)
    }

    /// Folds one decoded chunk. Returns the completed blob when this chunk finishes it, else `nil`.
    public func fold(
        blobKind: UInt8,
        blobID: UInt64,
        metaA: UInt16,
        metaB: UInt16,
        chunkIndex: UInt8,
        chunkCount: UInt8,
        bytes: Data,
    ) -> CompleteBlob? {
        let folded = bytes.withUnsafeBytes { chunk in
            slopdesk_blob_assembler_fold(
                handle, blobKind, blobID, metaA, metaB, chunkIndex, chunkCount,
                chunk.baseAddress, chunk.count,
            )
        }
        guard folded.complete else { return nil }
        var assembled = Data(count: folded.len)
        let taken = assembled.withUnsafeMutableBytes { out in
            slopdesk_blob_assembler_take(handle, out.baseAddress, out.count)
        }
        guard taken == folded.len else { return nil }
        return CompleteBlob(
            blobKind: folded.kind, blobID: folded.id, metaA: folded.meta_a, metaB: folded.meta_b,
            bytes: assembled,
        )
    }

    /// Drops all partial state (round teardown).
    public func reset() {
        slopdesk_blob_assembler_reset(handle)
    }
}

/// Image-magic validation for assembled blobs (docs/45: "PNG/JPEG magic validated on reassembly;
/// malformed blobs discarded and never poison the disk cache"). Pure byte checks — decoding stays
/// with the consumer, on the far side of the door either way.
public enum BlobImageValidator {
    /// The 8-byte PNG signature. No Swift caller today — ``validates(_:forKind:)`` is what the two
    /// fetch paths ask. Kept because `check-supervisor` pins it: the face IS the door, and without one
    /// the next `data.prefix(8) == …` gets written in Swift instead of asked of the crate.
    public static func looksLikePNG(_ data: Data) -> Bool {
        data.withUnsafeBytes { bytes in
            slopdesk_blob_looks_like_png(bytes.baseAddress, bytes.count)
        }
    }

    /// The JPEG SOI marker (FF D8 FF). Uncalled and pinned, for the reason above.
    public static func looksLikeJPEG(_ data: Data) -> Bool {
        data.withUnsafeBytes { bytes in
            slopdesk_blob_looks_like_jpeg(bytes.baseAddress, bytes.count)
        }
    }

    /// The expected magic per blob kind.
    public static func validates(_ data: Data, forKind kind: UInt8) -> Bool {
        data.withUnsafeBytes { bytes in
            slopdesk_blob_validates(bytes.baseAddress, bytes.count, kind)
        }
    }
}

/// The HOST-side counterpart: splits an encoded image into ready-to-send `blobChunk` payloads, each
/// fitting one mux datagram (``VideoControlMessage/blobBytesPerChunk``).
public enum BlobChunker {
    /// `nil` when the blob exceeds its kind's cap or needs more than 255 chunks (never legitimate —
    /// callers cap at encode time; this is the defensive bound).
    ///
    /// The door answers one chunk at a time so the list never has to cross as a list of lists; the
    /// split it runs is the crate's own, the same one its whole-list form is written in terms of.
    public static func encodedChunks(
        blobKind: UInt8,
        blobID: UInt64,
        metaA: UInt16,
        metaB: UInt16,
        bytes: Data,
    ) -> [Data]? {
        let count = slopdesk_blob_chunk_count(blobKind, bytes.count)
        guard count > 0 else { return nil }
        return bytes.withUnsafeBytes { blob -> [Data]? in
            var chunks: [Data] = []
            chunks.reserveCapacity(Int(count))
            for index in 0..<count {
                let needed = slopdesk_blob_encoded_chunk(
                    blobKind, blobID, metaA, metaB, blob.baseAddress, blob.count, index, nil, 0,
                )
                guard needed > 0 else { return nil }
                var encoded = Data(count: needed)
                let written = encoded.withUnsafeMutableBytes { out in
                    slopdesk_blob_encoded_chunk(
                        blobKind, blobID, metaA, metaB, blob.baseAddress, blob.count, index,
                        out.baseAddress, out.count,
                    )
                }
                guard written == needed else { return nil }
                chunks.append(encoded)
            }
            return chunks
        }
    }

    /// FNV-1a 64 over the bundleID's UTF-8 — the icon blobID (stable, no string on the reply wire).
    public static func fnv1a64(_ string: String) -> UInt64 {
        Array(string.utf8).withUnsafeBufferPointer { bytes in
            slopdesk_blob_id_of(bytes.baseAddress, bytes.count)
        }
    }
}
