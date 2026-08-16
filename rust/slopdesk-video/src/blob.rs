//! Blob transfer: app icons (kind 0, PNG) and window previews (kind 1, JPEG), split into mux-sized
//! chunks on the host and reassembled on the client.
//!
//! One reassembler serves every blob kind. Chunks key on `(kind, id)`, a duplicate overwrites
//! idempotently — the host dup-sends — and everything untrusted is bounded: the number of partial
//! blobs, and the assembled size against the kind's own cap. An assembly that runs over its cap is
//! DISCARDED rather than truncated and delivered, because a truncated PNG is a decoder's problem
//! and a dropped one is just a re-request.

use std::collections::BTreeMap;

use crate::video_control::VideoControlMessage;

/// The blob kind for an app icon: a PNG.
pub const ICON_KIND: u8 = 0;
/// The blob kind for a window preview: a JPEG.
pub const PREVIEW_KIND: u8 = 1;

/// The assembled-size cap for a blob kind, or `0` for a kind this build does not know.
///
/// An unknown kind assembling to nothing is deliberate: a future kind bumps the codec first, so a
/// kind byte we do not recognise is a sender we should not be allocating for.
#[must_use]
pub const fn max_bytes(kind: u8) -> usize {
    match kind {
        ICON_KIND => VideoControlMessage::ICON_BLOB_MAX_BYTES,
        PREVIEW_KIND => VideoControlMessage::PREVIEW_BLOB_MAX_BYTES,
        _ => 0,
    }
}

/// One chunk as it arrived off the wire.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BlobChunk {
    /// Which kind of blob this is a piece of.
    pub kind: u8,
    /// The blob's id, unique per kind.
    pub id: u64,
    /// The first kind-specific metadata word — for a preview, its width.
    pub meta_a: u16,
    /// The second kind-specific metadata word — for a preview, its height.
    pub meta_b: u16,
    /// This chunk's index, below `chunk_count`.
    pub chunk_index: u8,
    /// How many chunks the whole blob was split into.
    pub chunk_count: u8,
    /// This chunk's bytes.
    pub bytes: Vec<u8>,
}

/// One fully assembled blob.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CompleteBlob {
    /// The kind it was sent as.
    pub kind: u8,
    /// The id it was sent under.
    pub id: u64,
    /// The first metadata word, taken from the chunk that opened the assembly.
    pub meta_a: u16,
    /// The second metadata word, taken from the chunk that opened the assembly.
    pub meta_b: u16,
    /// Every chunk's bytes, concatenated in chunk order.
    pub bytes: Vec<u8>,
}

/// A partly-received blob.
#[derive(Debug, Clone)]
struct Partial {
    /// The chunk count every chunk of this blob must agree on.
    chunk_count: u8,
    /// The metadata from the chunk that opened the assembly.
    meta_a: u16,
    /// The second metadata word from that same chunk.
    meta_b: u16,
    /// The chunks received so far, by index.
    received: BTreeMap<u8, Vec<u8>>,
}

/// The client-side reassembler for chunked blobs.
#[derive(Debug, Clone, Default)]
pub struct BlobAssembler {
    /// The partly-received blobs, keyed by `(kind, id)`.
    partials: BTreeMap<(u8, u64), Partial>,
    /// The keys in arrival order, so the oldest partial is the one evicted.
    insertion_order: Vec<(u8, u64)>,
}

impl BlobAssembler {
    /// How many partial blobs are kept at once.
    ///
    /// Icons fetch one at a time and previews are single-flight, so four is generous headroom; the
    /// bound is there to stop a hostile sender growing the map one id at a time.
    pub const MAX_PARTIAL_BLOBS: usize = 4;

    /// A reassembler with nothing in flight.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Folds one decoded chunk in, returning the blob when this chunk is the one that finishes it.
    pub fn fold(&mut self, chunk: BlobChunk) -> Option<CompleteBlob> {
        let cap = max_bytes(chunk.kind);
        if cap == 0 {
            return None;
        }
        let key = (chunk.kind, chunk.id);
        let mut partial = if let Some(existing) = self.partials.get(&key) {
            if existing.chunk_count != chunk.chunk_count {
                // Chunks of one blob disagreeing about how many there are is corruption or a
                // hostile sender: the whole blob goes, and the requester's re-request fetches it
                // whole from the host's cache of encoded bytes.
                self.discard(key);
                return None;
            }
            existing.clone()
        } else {
            if self.partials.len() >= Self::MAX_PARTIAL_BLOBS
                && let Some(&oldest) = self.insertion_order.first()
            {
                self.discard(oldest);
            }
            self.insertion_order.push(key);
            Partial {
                chunk_count: chunk.chunk_count,
                meta_a: chunk.meta_a,
                meta_b: chunk.meta_b,
                received: BTreeMap::new(),
            }
        };

        partial.received.insert(chunk.chunk_index, chunk.bytes);
        if partial.received.len() != usize::from(chunk.chunk_count) {
            self.partials.insert(key, partial);
            return None;
        }
        self.discard(key);

        let mut assembled = Vec::new();
        for index in 0..chunk.chunk_count {
            if let Some(piece) = partial.received.get(&index) {
                assembled.extend_from_slice(piece);
            }
            if assembled.len() > cap {
                return None; // hostile padding: cap the accumulator, deliver nothing
            }
        }
        Some(CompleteBlob {
            kind: chunk.kind,
            id: chunk.id,
            meta_a: partial.meta_a,
            meta_b: partial.meta_b,
            bytes: assembled,
        })
    }

    /// Drops one blob's partial state, whether it was corrupt, evicted, or just completed.
    fn discard(&mut self, key: (u8, u64)) {
        self.partials.remove(&key);
        self.insertion_order.retain(|&held| held != key);
    }

    /// Drops every partial, at a round teardown.
    pub fn reset(&mut self) {
        self.partials.clear();
        self.insertion_order.clear();
    }
}

/// Whether the bytes open with the 8-byte PNG signature.
#[must_use]
pub fn looks_like_png(data: &[u8]) -> bool {
    data.len() > 8 && data.starts_with(&[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
}

/// Whether the bytes open with the JPEG start-of-image marker.
#[must_use]
pub fn looks_like_jpeg(data: &[u8]) -> bool {
    data.len() > 3 && data.starts_with(&[0xFF, 0xD8, 0xFF])
}

/// Whether an assembled blob carries the magic its kind is supposed to.
///
/// A pure byte check: decoding stays with the consumer. This is what keeps a malformed blob from
/// reaching — and poisoning — the on-disk cache.
#[must_use]
pub fn validates(data: &[u8], kind: u8) -> bool {
    match kind {
        ICON_KIND => looks_like_png(data),
        PREVIEW_KIND => looks_like_jpeg(data),
        _ => false,
    }
}

/// Splits an encoded image into ready-to-send `blobChunk` payloads, each fitting one mux datagram.
///
/// `None` when the blob is empty, exceeds its kind's cap, or would need more than 255 chunks. None
/// of those is legitimate — callers cap at encode time — so this is the defensive bound rather than
/// a path the host is expected to take.
#[must_use]
pub fn encoded_chunks(kind: u8, id: u64, meta_a: u16, meta_b: u16, bytes: &[u8]) -> Option<Vec<Vec<u8>>> {
    let count = chunk_count(kind, bytes.len())?;
    (0..count)
        .map(|index| encoded_chunk(kind, id, meta_a, meta_b, bytes, index))
        .collect()
}

/// How many chunks a blob of this size splits into, or `None` when it may not be sent at all.
///
/// Empty, over its kind's cap, or past 255 chunks — none of which is legitimate, since callers cap
/// at encode time.
#[must_use]
pub fn chunk_count(kind: u8, byte_count: usize) -> Option<u8> {
    if byte_count == 0 || byte_count > max_bytes(kind) {
        return None;
    }
    u8::try_from(byte_count.div_ceil(VideoControlMessage::BLOB_BYTES_PER_CHUNK)).ok()
}

/// One chunk of a split blob, encoded ready to send, or `None` when the blob may not be sent or the
/// index is past its last chunk.
///
/// The whole-list [`encoded_chunks`] is written in terms of this, so a caller that wants the chunks
/// one at a time is running the same split rather than a second one.
#[must_use]
pub fn encoded_chunk(
    kind: u8,
    id: u64,
    meta_a: u16,
    meta_b: u16,
    bytes: &[u8],
    index: u8,
) -> Option<Vec<u8>> {
    let count = chunk_count(kind, bytes.len())?;
    if index >= count {
        return None;
    }
    let per = VideoControlMessage::BLOB_BYTES_PER_CHUNK;
    let piece = bytes.chunks(per).nth(usize::from(index))?;
    Some(
        VideoControlMessage::BlobChunk {
            blob_kind: kind,
            blob_id: id,
            meta_a,
            meta_b,
            chunk_index: index,
            chunk_count: count,
            bytes: piece.to_vec(),
        }
        .encode(),
    )
}

/// FNV-1a 64 over a string's UTF-8 — how a bundle id becomes an icon's blob id, so the reply wire
/// never has to carry the string.
#[must_use]
pub fn fnv1a64(value: &str) -> u64 {
    let mut hash = 0xCBF2_9CE4_8422_2325_u64;
    for byte in value.bytes() {
        hash ^= u64::from(byte);
        hash = hash.wrapping_mul(0x0000_0100_0000_01B3);
    }
    hash
}

/// A one-shot fetch of ONE expected blob: the icon and preview rounds' shared shape.
///
/// The caller acquires a transient lane, retransmits its request until this resolves, and lets go.
/// Every retransmit makes the host re-send the WHOLE blob from its cache — the whole-blob
/// re-request discipline — so chunks from an earlier attempt and a later one interleave freely on
/// the lane, and the gate has to be indifferent to which attempt a chunk came from.
///
/// Two rules do all the work. A chunk for a kind or id the fetch did not ask for is dropped before
/// it reaches the assembler, so a sibling fetch sharing the flow cannot corrupt this one. And the
/// FIRST complete blob wins: once it lands, later chunks are ignored rather than reopening the
/// assembly, which is what makes a mid-flight retransmit harmless.
///
/// The magic check is applied at completion, so a malformed blob resolves the fetch as EMPTY rather
/// than poisoning the caller's on-disk cache — and the caller's negative entry stops it re-asking.
#[derive(Debug, Clone)]
pub struct OneShotBlobFetch {
    expected_kind: u8,
    expected_id: u64,
    assembler: BlobAssembler,
    blob: Option<CompleteBlob>,
}

impl OneShotBlobFetch {
    /// A fetch waiting for one blob of one kind.
    #[must_use]
    pub fn new(expected_kind: u8, expected_id: u64) -> Self {
        Self {
            expected_kind,
            expected_id,
            assembler: BlobAssembler::new(),
            blob: None,
        }
    }

    /// Whether the blob has landed, which is the caller's cue to stop retransmitting.
    #[must_use]
    pub const fn has_blob(&self) -> bool {
        self.blob.is_some()
    }

    /// The completed blob, if it has landed and carried the magic its kind requires.
    #[must_use]
    pub fn resolved(&self) -> Option<&CompleteBlob> {
        self.blob
            .as_ref()
            .filter(|complete| validates(&complete.bytes, complete.kind))
    }

    /// Folds one chunk off the lane, returning the blob on the fold that completes it.
    pub fn fold(&mut self, chunk: BlobChunk) -> Option<&CompleteBlob> {
        if self.blob.is_some() || chunk.kind != self.expected_kind || chunk.id != self.expected_id {
            return None;
        }
        self.blob = self.assembler.fold(chunk);
        self.resolved()
    }
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        clippy::panic,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use super::{
        BlobAssembler, BlobChunk, CompleteBlob, ICON_KIND, OneShotBlobFetch, PREVIEW_KIND, encoded_chunks,
        fnv1a64, looks_like_jpeg, looks_like_png, max_bytes, validates,
    };
    use crate::video_control::VideoControlMessage;

    /// One chunk of a two-chunk icon.
    fn chunk(index: u8, count: u8, bytes: &[u8]) -> BlobChunk {
        BlobChunk {
            kind: ICON_KIND,
            id: 7,
            meta_a: 64,
            meta_b: 64,
            chunk_index: index,
            chunk_count: count,
            bytes: bytes.to_vec(),
        }
    }

    /// A one-chunk PNG the magic check accepts.
    fn png_chunk(kind: u8, id: u64) -> BlobChunk {
        BlobChunk {
            kind,
            id,
            meta_a: 64,
            meta_b: 64,
            chunk_index: 0,
            chunk_count: 1,
            bytes: vec![0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00],
        }
    }

    #[test]
    fn the_one_shot_fetch_resolves_on_the_blob_it_asked_for() {
        let mut fetch = OneShotBlobFetch::new(ICON_KIND, 7);
        assert!(!fetch.has_blob());
        assert!(fetch.fold(png_chunk(ICON_KIND, 7)).is_some());
        assert!(
            fetch.has_blob(),
            "which is the caller's cue to stop retransmitting"
        );
        assert_eq!(fetch.resolved().map(|blob| blob.id), Some(7));
    }

    #[test]
    fn a_siblings_blob_on_the_shared_lane_cannot_corrupt_this_fetch() {
        let mut fetch = OneShotBlobFetch::new(ICON_KIND, 7);
        assert!(fetch.fold(png_chunk(ICON_KIND, 8)).is_none(), "another id");
        assert!(fetch.fold(png_chunk(PREVIEW_KIND, 7)).is_none(), "another kind");
        assert!(!fetch.has_blob());
        assert!(fetch.fold(png_chunk(ICON_KIND, 7)).is_some());
    }

    #[test]
    fn a_retransmit_that_lands_after_the_blob_is_ignored_rather_than_reopening_it() {
        let mut fetch = OneShotBlobFetch::new(ICON_KIND, 7);
        fetch.fold(png_chunk(ICON_KIND, 7));
        let mut late = png_chunk(ICON_KIND, 7);
        late.chunk_count = 2;
        assert!(fetch.fold(late).is_none());
        assert!(
            fetch.has_blob(),
            "the first complete blob wins, so the retransmit is harmless"
        );
    }

    #[test]
    fn a_malformed_blob_resolves_empty_rather_than_poisoning_the_cache() {
        let mut fetch = OneShotBlobFetch::new(ICON_KIND, 7);
        let mut junk = png_chunk(ICON_KIND, 7);
        junk.bytes = b"not an image".to_vec();
        assert!(fetch.fold(junk).is_none());
        assert!(fetch.has_blob(), "it assembled — it just is not a PNG");
        assert!(fetch.resolved().is_none());
    }

    #[test]
    fn a_blob_completes_on_its_last_chunk_and_in_chunk_order() {
        let mut assembler = BlobAssembler::new();
        assert_eq!(assembler.fold(chunk(1, 2, b"world")), None);
        let complete = assembler.fold(chunk(0, 2, b"hello "));
        assert_eq!(
            complete,
            Some(CompleteBlob {
                kind: ICON_KIND,
                id: 7,
                meta_a: 64,
                meta_b: 64,
                bytes: b"hello world".to_vec(),
            }),
            "the pieces assemble in chunk order, not arrival order",
        );
        // The state went with it: the same chunks again start a fresh assembly.
        assert_eq!(assembler.fold(chunk(0, 2, b"hello ")), None);
    }

    #[test]
    fn a_duplicate_chunk_overwrites_rather_than_counting_twice() {
        let mut assembler = BlobAssembler::new();
        assert_eq!(assembler.fold(chunk(0, 2, b"a")), None);
        assert_eq!(assembler.fold(chunk(0, 2, b"a")), None, "still one of two");
        assert!(assembler.fold(chunk(1, 2, b"b")).is_some());
    }

    /// The pinned decode rule: chunks that disagree about the count are corruption, and the whole
    /// blob goes rather than being patched into something plausible.
    #[test]
    fn a_disagreeing_chunk_count_discards_the_whole_blob() {
        let mut assembler = BlobAssembler::new();
        assert_eq!(assembler.fold(chunk(0, 2, b"a")), None);
        assert_eq!(assembler.fold(chunk(1, 3, b"b")), None, "discarded, not patched");
        // The earlier chunk went too, so the original pair no longer completes anything.
        assert_eq!(assembler.fold(chunk(1, 2, b"b")), None);
    }

    #[test]
    fn an_unknown_kind_assembles_to_nothing() {
        let mut assembler = BlobAssembler::new();
        let mut alien = chunk(0, 1, b"whatever");
        alien.kind = 9;
        assert_eq!(assembler.fold(alien), None);
        assert_eq!(max_bytes(9), 0);
    }

    /// The bound that stops a hostile sender growing the map one id at a time.
    #[test]
    fn the_oldest_partial_is_evicted_once_the_map_is_full() {
        let mut assembler = BlobAssembler::new();
        for id in 0..u64::try_from(BlobAssembler::MAX_PARTIAL_BLOBS).unwrap_or(4) {
            let mut opening = chunk(0, 2, b"x");
            opening.id = id;
            assert_eq!(assembler.fold(opening), None);
        }
        // A fifth blob evicts the first…
        let mut fifth = chunk(0, 2, b"x");
        fifth.id = 99;
        assert_eq!(assembler.fold(fifth), None);
        // …so the first blob's second chunk no longer completes it.
        let mut orphan = chunk(1, 2, b"y");
        orphan.id = 0;
        assert_eq!(assembler.fold(orphan), None);
        // …while the fifth still completes.
        let mut fifth_tail = chunk(1, 2, b"y");
        fifth_tail.id = 99;
        assert!(assembler.fold(fifth_tail).is_some());
    }

    /// An over-cap assembly is dropped whole: a truncated PNG would be worse than a re-request.
    #[test]
    fn an_over_cap_assembly_is_discarded_rather_than_truncated() {
        let mut assembler = BlobAssembler::new();
        let cap = max_bytes(ICON_KIND);
        let big = vec![0_u8; cap];
        assert_eq!(assembler.fold(chunk(0, 2, &big)), None);
        assert_eq!(assembler.fold(chunk(1, 2, b"one byte too many")), None);
    }

    #[test]
    fn a_reset_drops_everything_in_flight() {
        let mut assembler = BlobAssembler::new();
        assert_eq!(assembler.fold(chunk(0, 2, b"a")), None);
        assembler.reset();
        assert_eq!(assembler.fold(chunk(1, 2, b"b")), None);
    }

    #[test]
    fn the_magic_check_is_per_kind_and_needs_more_than_the_magic() {
        let png = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00];
        let jpeg = [0xFF, 0xD8, 0xFF, 0xE0];
        assert!(looks_like_png(&png));
        assert!(looks_like_jpeg(&jpeg));
        assert!(!looks_like_png(&png[..8]), "the signature alone is not an image");
        assert!(!looks_like_jpeg(&jpeg[..3]));
        assert!(validates(&png, ICON_KIND));
        assert!(validates(&jpeg, PREVIEW_KIND));
        assert!(
            !validates(&png, PREVIEW_KIND),
            "an icon's magic is not a preview's"
        );
        assert!(!validates(&jpeg, ICON_KIND));
        assert!(!validates(&png, 9), "an unknown kind validates nothing");
    }

    /// The host and client halves have to meet: chunking then assembling is the identity.
    #[test]
    fn every_chunking_round_trips_through_the_assembler() {
        let blob: Vec<u8> = (0..3000_u32).map(|value| (value % 251) as u8).collect();
        let chunks = encoded_chunks(PREVIEW_KIND, 42, 320, 200, &blob).expect("within the cap");
        assert_eq!(chunks.len(), 3, "1177 bytes per chunk");

        let mut assembler = BlobAssembler::new();
        let mut completed = None;
        for encoded in &chunks {
            let VideoControlMessage::BlobChunk {
                blob_kind,
                blob_id,
                meta_a,
                meta_b,
                chunk_index,
                chunk_count,
                bytes,
            } = VideoControlMessage::decode(encoded).expect("the chunker emits decodable messages")
            else {
                panic!("a chunk decodes as a chunk");
            };
            completed = assembler.fold(BlobChunk {
                kind: blob_kind,
                id: blob_id,
                meta_a,
                meta_b,
                chunk_index,
                chunk_count,
                bytes,
            });
        }
        assert_eq!(
            completed,
            Some(CompleteBlob {
                kind: PREVIEW_KIND,
                id: 42,
                meta_a: 320,
                meta_b: 200,
                bytes: blob,
            }),
        );
    }

    #[test]
    fn a_blob_that_cannot_be_sent_is_not_chunked() {
        assert_eq!(encoded_chunks(ICON_KIND, 1, 0, 0, &[]), None, "an empty blob");
        let too_big = vec![0_u8; max_bytes(ICON_KIND) + 1];
        assert_eq!(encoded_chunks(ICON_KIND, 1, 0, 0, &too_big), None);
        assert_eq!(encoded_chunks(9, 1, 0, 0, b"anything"), None, "an unknown kind");
        // The cap and the chunk size together stay under the 255-chunk ceiling, so the defensive
        // bound is unreachable through a legitimate call — which is the point of checking it.
        let biggest = vec![0_u8; max_bytes(PREVIEW_KIND)];
        let chunks = encoded_chunks(PREVIEW_KIND, 1, 0, 0, &biggest).expect("at the cap exactly");
        assert!(u8::try_from(chunks.len()).is_ok());
    }

    /// The icon id is derived, not carried, so both ends must derive it the same way.
    #[test]
    fn the_bundle_id_hash_is_the_published_fnv_1a() {
        assert_eq!(fnv1a64(""), 0xCBF2_9CE4_8422_2325, "the offset basis, unmixed");
        assert_eq!(fnv1a64("a"), 0xAF63_DC4C_8601_EC8C);
        assert_eq!(fnv1a64("foobar"), 0x8594_4171_F739_67E8);
        assert_ne!(fnv1a64("com.apple.Safari"), fnv1a64("com.apple.Terminal"));
    }
}
