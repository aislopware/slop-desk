//! Chunked blob reassembly: app icons and window previews, arriving a datagram at a time.
//!
//! A HANDLE, for the reason the audio stage is one — the assembly's whole product IS the bytes, and
//! they are held across many calls: up to four partial blobs, each up to its kind's cap. Folding
//! that through a by-value record would copy the accumulator on every chunk of every blob.
//!
//! The completed bytes are answered in two steps, because the near side cannot know their length
//! before the chunk that finishes them: the fold reports the length, and one take copies them out.
//! The alternative — a fixed buffer sized to the cap — would make every caller carry a megabyte to
//! receive an icon.
//!
//! Everything else here is pure: the magic checks, the split, and the id hash a bundle id becomes.

use std::ffi::c_uchar;

use slopdesk_video::blob::{
    BlobAssembler, BlobChunk, CompleteBlob, ICON_KIND, PREVIEW_KIND, chunk_count, encoded_chunk, fnv1a64,
    looks_like_jpeg, looks_like_png, max_bytes, validates,
};

use crate::{borrow, deliver};

/// The reassembler, plus the blob its last fold completed and has not yet handed over.
#[derive(Debug)]
pub struct SlopDeskBlobAssembler {
    /// The reassembler proper.
    assembler: BlobAssembler,
    /// The completed blob awaiting its take. One at a time: a fold that completes another replaces
    /// it, which is the same rule as a caller that ignored the first one's length.
    completed: Option<CompleteBlob>,
}

/// The blob kinds this build knows, so neither language writes the numbers down twice.
#[repr(C)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct SlopDeskBlobKinds {
    /// An app icon: a PNG.
    pub icon: u8,
    /// A window preview: a JPEG.
    pub preview: u8,
    /// How many partial blobs are kept at once.
    pub max_partial_blobs: usize,
}

/// What one fold produced.
#[repr(C)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct SlopDeskBlobFold {
    /// The completed blob's id.
    pub id: u64,
    /// Its length in bytes, ready for one take.
    pub len: usize,
    /// The first metadata word, from the chunk that opened the assembly.
    pub meta_a: u16,
    /// The second metadata word.
    pub meta_b: u16,
    /// The kind it was sent as.
    pub kind: u8,
    /// Whether this chunk is the one that finished a blob.
    pub complete: bool,
}

/// The fold that finished nothing.
const NOTHING: SlopDeskBlobFold = SlopDeskBlobFold {
    id: 0,
    len: 0,
    meta_a: 0,
    meta_b: 0,
    kind: 0,
    complete: false,
};

/// Turns the caller's handle back into a reference.
///
/// # Safety
/// `handle` must be null, or a pointer returned by [`slopdesk_blob_assembler_new`] that has not
/// been freed, with no other live reference for the duration of the call.
#[expect(
    unsafe_code,
    reason = "turning the caller's handle back into a reference is this module's whole obligation"
)]
const unsafe fn held<'a>(handle: *mut SlopDeskBlobAssembler) -> Option<&'a mut SlopDeskBlobAssembler> {
    // SAFETY: by the caller's obligation this is a live, exclusively-held allocation from `new`.
    unsafe { handle.as_mut() }
}

/// The blob kinds and the partial-assembly bound.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_blob_kinds() -> SlopDeskBlobKinds {
    SlopDeskBlobKinds {
        icon: ICON_KIND,
        preview: PREVIEW_KIND,
        max_partial_blobs: BlobAssembler::MAX_PARTIAL_BLOBS,
    }
}

/// The assembled-size cap for a kind, or zero for a kind this build does not know — a future kind
/// bumps the codec first, so an unrecognised one is a sender not worth allocating for.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_blob_max_bytes(kind: u8) -> usize {
    max_bytes(kind)
}

/// A reassembler with nothing in flight. Never null unless allocation itself failed.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_blob_assembler_new() -> *mut SlopDeskBlobAssembler {
    Box::into_raw(Box::new(SlopDeskBlobAssembler {
        assembler: BlobAssembler::new(),
        completed: None,
    }))
}

/// Frees a reassembler. Null is a no-op, and the same pointer must not be freed twice.
///
/// # Safety
/// `handle` must be null or a pointer from [`slopdesk_blob_assembler_new`], freed exactly once.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_blob_assembler_free(handle: *mut SlopDeskBlobAssembler) {
    if handle.is_null() {
        return;
    }
    // SAFETY: by the caller's obligation this pointer came from one `new` and is freed once.
    drop(unsafe { Box::from_raw(handle) });
}

/// Folds one decoded chunk in, reporting the blob's length when this chunk is the one that finishes
/// it. The bytes stay here until [`slopdesk_blob_assembler_take`] copies them out.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation, and `bytes` must either be null or point to `len`
/// readable bytes for the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_blob_assembler_fold(
    handle: *mut SlopDeskBlobAssembler,
    kind: u8,
    id: u64,
    meta_a: u16,
    meta_b: u16,
    chunk_index: u8,
    chunk_count_of_blob: u8,
    bytes: *const c_uchar,
    len: usize,
) -> SlopDeskBlobFold {
    // SAFETY: the caller's obligation, discharged by the Swift owner holding one handle.
    let Some(state) = (unsafe { held(handle) }) else {
        return NOTHING;
    };
    // SAFETY: as above — the chunk is the caller's buffer for the duration of this call.
    let chunk = unsafe { borrow(bytes, len) };
    let folded = state.assembler.fold(BlobChunk {
        kind,
        id,
        meta_a,
        meta_b,
        chunk_index,
        chunk_count: chunk_count_of_blob,
        bytes: chunk.to_vec(),
    });
    let Some(blob) = folded else {
        state.completed = None;
        return NOTHING;
    };
    let answer = SlopDeskBlobFold {
        id: blob.id,
        len: blob.bytes.len(),
        meta_a: blob.meta_a,
        meta_b: blob.meta_b,
        kind: blob.kind,
        complete: true,
    };
    state.completed = Some(blob);
    answer
}

/// Copies out the blob the last fold completed, and forgets it. Answers the length either way, so a
/// caller whose buffer was too small can retry with a bigger one before the next fold.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation, and `out` must either be null or point to `cap`
/// writable bytes for the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_blob_assembler_take(
    handle: *mut SlopDeskBlobAssembler,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, discharged by the Swift owner holding one handle.
    let Some(state) = (unsafe { held(handle) }) else {
        return 0;
    };
    let Some(blob) = state.completed.as_ref() else {
        return 0;
    };
    // SAFETY: as above — `out` is the caller's buffer for the duration of this call.
    let needed = unsafe { deliver(&blob.bytes, out, cap) };
    if needed <= cap {
        state.completed = None;
    }
    needed
}

/// Drops every partial assembly, and any completed blob not taken — the round teardown.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_blob_assembler_reset(handle: *mut SlopDeskBlobAssembler) {
    // SAFETY: the caller's obligation, discharged by the Swift owner holding one handle.
    if let Some(state) = unsafe { held(handle) } {
        state.assembler.reset();
        state.completed = None;
    }
}

/// Whether these bytes carry the magic their kind requires — PNG for an icon, JPEG for a preview.
/// Decoding stays with the consumer; this only keeps a malformed blob out of the disk cache.
///
/// # Safety
/// `bytes` must either be null or point to `len` readable bytes for the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_blob_validates(bytes: *const c_uchar, len: usize, kind: u8) -> bool {
    // SAFETY: the caller's obligation, discharged at the call site by a scoped buffer access.
    validates(unsafe { borrow(bytes, len) }, kind)
}

/// Whether these bytes open with the 8-byte PNG signature.
///
/// # Safety
/// `bytes` must either be null or point to `len` readable bytes for the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_blob_looks_like_png(bytes: *const c_uchar, len: usize) -> bool {
    // SAFETY: the caller's obligation, discharged at the call site by a scoped buffer access.
    looks_like_png(unsafe { borrow(bytes, len) })
}

/// Whether these bytes open with the JPEG SOI marker.
///
/// # Safety
/// `bytes` must either be null or point to `len` readable bytes for the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_blob_looks_like_jpeg(bytes: *const c_uchar, len: usize) -> bool {
    // SAFETY: the caller's obligation, discharged at the call site by a scoped buffer access.
    looks_like_jpeg(unsafe { borrow(bytes, len) })
}

/// How many chunks a blob of this size splits into — zero when it may not be sent at all, which is
/// empty, over its kind's cap, or past 255 chunks.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_blob_chunk_count(kind: u8, byte_count: usize) -> u8 {
    chunk_count(kind, byte_count).unwrap_or(0)
}

/// One chunk of a split blob, encoded ready to send, and its length either way. Zero when the blob
/// may not be sent or the index is past its last chunk.
///
/// # Safety
/// `bytes` must either be null or point to `len` readable bytes, and `out` either null or point to
/// `cap` writable bytes, for the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_blob_encoded_chunk(
    kind: u8,
    id: u64,
    meta_a: u16,
    meta_b: u16,
    bytes: *const c_uchar,
    len: usize,
    index: u8,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, discharged at the call site by a scoped buffer access.
    let blob = unsafe { borrow(bytes, len) };
    let Some(encoded) = encoded_chunk(kind, id, meta_a, meta_b, blob, index) else {
        return 0;
    };
    // SAFETY: as above — `out` is the caller's buffer for the duration of this call.
    unsafe { deliver(&encoded, out, cap) }
}

/// FNV-1a 64 over a string's UTF-8 — how a bundle id becomes an icon's blob id, so the reply wire
/// never has to carry the string.
///
/// # Safety
/// `text` must either be null or point to `len` readable bytes for the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_blob_id_of(text: *const c_uchar, len: usize) -> u64 {
    // SAFETY: the caller's obligation, discharged at the call site by a scoped buffer access.
    let bytes = unsafe { borrow(text, len) };
    fnv1a64(core::str::from_utf8(bytes).unwrap_or_default())
}

#[cfg(test)]
mod tests {
    #![expect(
        unsafe_code,
        reason = "reaching a pointer entry from a test is what the entry is for"
    )]

    use std::ptr;

    use super::{
        SlopDeskBlobAssembler, slopdesk_blob_assembler_fold, slopdesk_blob_assembler_free,
        slopdesk_blob_assembler_new, slopdesk_blob_assembler_reset, slopdesk_blob_assembler_take,
        slopdesk_blob_chunk_count, slopdesk_blob_encoded_chunk, slopdesk_blob_id_of, slopdesk_blob_kinds,
        slopdesk_blob_looks_like_jpeg, slopdesk_blob_looks_like_png, slopdesk_blob_max_bytes,
        slopdesk_blob_validates,
    };

    /// One chunk folded in, with the chunk's own bytes.
    fn fold(
        handle: *mut SlopDeskBlobAssembler,
        kind: u8,
        id: u64,
        index: u8,
        count: u8,
        bytes: &[u8],
    ) -> super::SlopDeskBlobFold {
        unsafe {
            slopdesk_blob_assembler_fold(handle, kind, id, 7, 9, index, count, bytes.as_ptr(), bytes.len())
        }
    }

    #[test]
    fn a_split_blob_reassembles_in_order_and_is_taken_once() {
        let kinds = slopdesk_blob_kinds();
        let handle = slopdesk_blob_assembler_new();
        assert!(
            !fold(handle, kinds.icon, 1, 1, 2, b"world").complete,
            "out of order is fine"
        );
        let done = fold(handle, kinds.icon, 1, 0, 2, b"hello ");
        assert!(done.complete);
        assert_eq!(done.len, 11);
        assert_eq!(done.meta_a, 7);
        assert_eq!(done.meta_b, 9);

        let needed = unsafe { slopdesk_blob_assembler_take(handle, ptr::null_mut(), 0) };
        assert_eq!(needed, 11, "a caller sized wrong keeps its blob");
        let mut buffer = vec![0u8; needed];
        assert_eq!(
            unsafe { slopdesk_blob_assembler_take(handle, buffer.as_mut_ptr(), buffer.len()) },
            needed
        );
        assert_eq!(&buffer, b"hello world");
        assert_eq!(
            unsafe { slopdesk_blob_assembler_take(handle, buffer.as_mut_ptr(), buffer.len()) },
            0,
            "and taking it twice answers nothing"
        );
        unsafe { slopdesk_blob_assembler_free(handle) };
    }

    #[test]
    fn a_hostile_sender_is_bounded_at_every_edge() {
        let kinds = slopdesk_blob_kinds();
        let handle = slopdesk_blob_assembler_new();
        assert!(
            !fold(handle, 200, 1, 0, 1, b"x").complete,
            "an unknown kind assembles to nothing"
        );
        assert_eq!(slopdesk_blob_max_bytes(200), 0);
        assert!(slopdesk_blob_max_bytes(kinds.preview) > slopdesk_blob_max_bytes(kinds.icon));

        assert!(!fold(handle, kinds.icon, 2, 0, 2, b"a").complete);
        assert!(
            !fold(handle, kinds.icon, 2, 1, 3, b"b").complete,
            "chunks disagreeing about the count discard the whole blob"
        );
        assert!(
            !fold(handle, kinds.icon, 2, 1, 2, b"b").complete,
            "and the discarded blob does not complete from its survivors"
        );

        assert!(!fold(handle, kinds.icon, 3, 1, 2, b"b").complete);
        unsafe { slopdesk_blob_assembler_reset(handle) };
        assert!(
            !fold(handle, kinds.icon, 3, 0, 2, b"a").complete,
            "a reset drops what was in flight"
        );
        unsafe { slopdesk_blob_assembler_free(handle) };
    }

    #[test]
    fn the_split_and_the_magic_checks_answer_for_themselves() {
        let kinds = slopdesk_blob_kinds();
        let png = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00];
        assert!(unsafe { slopdesk_blob_looks_like_png(png.as_ptr(), png.len()) });
        assert!(unsafe { slopdesk_blob_validates(png.as_ptr(), png.len(), kinds.icon) });
        assert!(!unsafe { slopdesk_blob_validates(png.as_ptr(), png.len(), kinds.preview) });
        let jpeg = [0xFF, 0xD8, 0xFF, 0xE0];
        assert!(unsafe { slopdesk_blob_looks_like_jpeg(jpeg.as_ptr(), jpeg.len()) });
        assert!(!unsafe { slopdesk_blob_looks_like_png(ptr::null(), 0) });

        let blob = vec![0x41u8; 3000];
        let count = slopdesk_blob_chunk_count(kinds.icon, blob.len());
        assert!(count > 1, "3000 bytes does not fit one datagram");
        assert_eq!(slopdesk_blob_chunk_count(kinds.icon, 0), 0);
        let needed = unsafe {
            slopdesk_blob_encoded_chunk(
                kinds.icon,
                5,
                1,
                2,
                blob.as_ptr(),
                blob.len(),
                0,
                ptr::null_mut(),
                0,
            )
        };
        assert!(needed > 0);
        assert_eq!(
            unsafe {
                slopdesk_blob_encoded_chunk(
                    kinds.icon,
                    5,
                    1,
                    2,
                    blob.as_ptr(),
                    blob.len(),
                    count,
                    ptr::null_mut(),
                    0,
                )
            },
            0,
            "past the last chunk there is nothing to encode"
        );

        let bundle = "com.apple.Safari";
        assert_eq!(
            unsafe { slopdesk_blob_id_of(bundle.as_ptr(), bundle.len()) },
            unsafe { slopdesk_blob_id_of(bundle.as_ptr(), bundle.len()) },
            "the id is a function of the name and nothing else"
        );
    }
}
