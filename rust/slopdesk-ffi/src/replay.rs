//! The handle convention, and the one type that needs it: [`slopdesk_wire::replay::ReplayBuffer`].
//!
//! ## Why this is not the pure convention
//! Everything else in this crate is a function: bytes in, bytes out, nothing remembered. The replay
//! buffer is the opposite — it *is* the memory. It holds up to 256 MiB of retained PTY output, it
//! is appended to on every PTY chunk, and the answer to `should_pause_drain` after that append is
//! what stops the host reading the master. Passing that state across the boundary per call would
//! mean copying the whole history twice per chunk. So the state stays in Rust and Swift holds a
//! token.
//!
//! ## The handle convention
//! - [`slopdesk_replay_new`] returns an opaque `*mut SlopDeskReplay`, or null if it cannot
//!   allocate.
//! - Exactly one [`slopdesk_replay_free`] per `new`. Freeing twice, or using a freed handle, is the
//!   caller's bug and this crate cannot catch it — which is why exactly one Swift type owns it and
//!   frees it in `deinit`.
//! - **No two calls on one handle may overlap.** Every entry point that mutates takes `&mut` from
//!   the pointer, so a concurrent call is aliasing UB. The Swift owner serialises under the lock it
//!   already held for the value type it replaces.
//! - Still nothing is allocated on one side and freed on the other. Results are held BY THE HANDLE
//!   and read out with the same `(out, cap) -> needed` convention as everything else.
//!
//! ## The three result slots
//! A producer fills a slot on the handle and returns how many items it holds; the caller then reads
//! them one at a time. This keeps peak memory at one message rather than a second copy of the whole
//! replay, and it means no list encoding exists to get wrong.
//!
//! | slot | filled by | read with |
//! | --- | --- | --- |
//! | messages | `messages`, `replay`, `rechunk_snapshot` | `result_count` / `result_seq` / `result_len` / `result_copy` |
//! | blob | `snapshot_source`, `ring_fold_source` | `blob_len` / `blob_copy` |
//! | seqs | `snapshot_source`, `ring_fold_source`, `ring_seqs` | `seqs_count` / `seqs_copy` |
//!
//! A slot holds its contents until the next producer overwrites it. Reading a slot never mutates
//! it, so a caller may take the length, allocate, and copy without a lock in between.
//!
//! ## The distiller
//! The cold-replay scrollback cleaner is [`slopdesk_sanitize::sanitize`], called directly. It used
//! to be a C function pointer back into Swift, which then dialled screend over `AF_UNIX` — a
//! re-entrant path out of this crate and a socket round trip over the whole retained history, both
//! there only because a pure function lived behind a daemon. Linking the crate deleted the
//! callback, its two `unsafe impl` promises, and the policy where an absent engine meant replayed
//! history arrived RAW and could transiently arm a client's input reporting.

use core::ffi::c_uchar;

use slopdesk_sanitize::{Options as SanitizeOptions, sanitize};
use slopdesk_wire::WireMessage;
use slopdesk_wire::replay::ReplayBuffer;

use crate::{borrow, deliver};

/// The opaque handle: the buffer, plus the three result slots the caller reads answers out of.
#[derive(Debug)]
pub struct SlopDeskReplay {
    buffer: ReplayBuffer,
    /// Messages produced by the last `messages` / `replay` / `rechunk_snapshot`.
    results: Vec<(i64, Vec<u8>)>,
    /// Bytes produced by the last `snapshot_source` / `ring_fold_source`.
    blob: Vec<u8>,
    /// Seqs produced by the last `snapshot_source` / `ring_fold_source` / `ring_seqs`.
    seqs: Vec<i64>,
    /// Messages staged by `input_push`, consumed by `adopt_snapshot_replay`.
    staged: Vec<WireMessage>,
}

impl SlopDeskReplay {
    /// Replaces the message slot with the `Output` payloads of `messages`.
    ///
    /// Non-`Output` variants cannot occur — every producer here emits `Output` — and are dropped
    /// rather than mapped to something else, because mapping would be a decision.
    fn take_messages(&mut self, messages: Vec<WireMessage>) -> usize {
        self.results = messages
            .into_iter()
            .filter_map(|message| {
                match message {
                    WireMessage::Output { seq, bytes } => Some((seq, bytes)),
                    _ => None,
                }
            })
            .collect();
        self.results.len()
    }
}

/// Turns a caller's handle pointer into a reference for the duration of one call.
///
/// # Safety
/// `handle` must be a live pointer from [`slopdesk_replay_new`] that has not been freed, and no
/// other call on it may overlap this one.
#[expect(
    unsafe_code,
    reason = "reconstituting the handle IS the boundary this module documents"
)]
unsafe fn held<'a>(handle: *mut SlopDeskReplay) -> Option<&'a mut SlopDeskReplay> {
    if handle.is_null() {
        return None;
    }
    // SAFETY: non-null and, by the caller's obligation, live, correctly aligned, and unaliased for
    // this call — the Swift owner serialises every entry point under its replay lock.
    Some(unsafe { &mut *handle })
}

/// Copies `values` into the caller's `i64` buffer if they fit, reporting the count either way.
///
/// # Safety
/// `out` must either be null or point to `cap` writable `i64`s for the whole call.
#[expect(
    unsafe_code,
    reason = "writing into the caller's buffer is the other half of the boundary"
)]
const unsafe fn deliver_seqs(values: &[i64], out: *mut i64, cap: usize) -> usize {
    let needed = values.len();
    if needed == 0 || needed > cap || out.is_null() {
        return needed;
    }
    // SAFETY: `needed <= cap` was just checked, `out` is non-null and writable for `cap` i64s by the
    // caller's obligation, and `values` is a live Rust slice that cannot overlap it.
    unsafe { std::ptr::copy_nonoverlapping(values.as_ptr(), out, needed) };
    needed
}

// MARK: Lifecycle

/// Creates a replay buffer at the given caps and returns its handle, or null if allocation failed.
///
/// `distill` selects the line-editor collapse — the one replay pass a caller may decline
/// (`SLOPDESK_SCROLLBACK_DISTILL`). The other six always run: they are cleanup nobody has ever
/// wanted back, and six flags for "do not show garbage" is six ways to break a reattach with no way
/// to notice.
///
/// `reassert_input_modes` re-appends the stream's NET final input-mode state after the passes. The
/// live ring wants it (a session still inside a TUI keeps that TUI's modes across a cold reattach);
/// the disk journal must not (there is no TUI to serve after a daemon restart).
///
/// # Safety
/// Nothing is borrowed here — the parameters are values and the handle owns everything it needs.
/// The function is `unsafe` only because an exported C entry point is, in edition 2024.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_replay_new(
    max_backup_bytes: usize,
    offline_gate_bytes: usize,
    scrollback_bytes: usize,
    distill: bool,
    reassert_input_modes: bool,
) -> *mut SlopDeskReplay {
    let options = SanitizeOptions {
        distill,
        reassert_input_modes,
    };
    let buffer = ReplayBuffer::with_caps(max_backup_bytes, offline_gate_bytes, scrollback_bytes)
        .distilling(std::sync::Arc::new(move |input: &[u8]| sanitize(input, options)));
    Box::into_raw(Box::new(SlopDeskReplay {
        buffer,
        results: Vec::new(),
        blob: Vec::new(),
        seqs: Vec::new(),
        staged: Vec::new(),
    }))
}

/// Frees a handle. Null is a no-op; anything else must come from exactly one
/// [`slopdesk_replay_new`] and be freed exactly once.
///
/// # Safety
/// `handle` must be null, or a live pointer from [`slopdesk_replay_new`] not yet freed, with no
/// other call on it in flight.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_replay_free(handle: *mut SlopDeskReplay) {
    if handle.is_null() {
        return;
    }
    // SAFETY: by the caller's obligation this pointer came from `Box::into_raw` in
    // `slopdesk_replay_new` and has not been freed, so reclaiming the box is sound.
    drop(unsafe { Box::from_raw(handle) });
}

// MARK: Observation
//
// Each of these is one line over `held`, and each carries the same obligation, stated once on
// `held` and restated on the entry point rather than argued afresh.

/// A scalar getter: `$name` over the buffer, answering `$fallback` for a null handle.
macro_rules! observer {
    ($(#[$meta:meta])* $name:ident -> $type:ty, $fallback:expr, |$buffer:ident| $body:expr) => {
        $(#[$meta])*
        ///
        /// # Safety
        /// `handle` must be null, or a live handle from [`slopdesk_replay_new`] with no other call
        /// on it in flight.
        #[unsafe(no_mangle)]
        #[expect(
            unsafe_code,
            reason = "an exported C entry point is unsafe by definition in edition 2024"
        )]
        pub unsafe extern "C" fn $name(handle: *mut SlopDeskReplay) -> $type {
            // SAFETY: the caller's obligation, restated above.
            match unsafe { held(handle) } {
                Some(held) => {
                    let $buffer = &held.buffer;
                    $body
                },
                None => $fallback,
            }
        }
    };
}

observer!(
    /// Highest seq assigned so far. Starts at 0; the first output is seq 1.
    slopdesk_replay_highest_seq -> i64, 0, |buffer| buffer.highest_seq()
);
observer!(
    /// Highest contiguous seq the client has acked.
    slopdesk_replay_acked_seq -> i64, 0, |buffer| buffer.acked_seq()
);
observer!(
    /// Sum of the payload sizes of every un-acked entry.
    slopdesk_replay_retained_bytes -> usize, 0, |buffer| buffer.retained_bytes()
);
observer!(
    /// Whether the connection layer currently considers the client reachable.
    slopdesk_replay_is_client_online -> bool, true, |buffer| buffer.is_client_online()
);
observer!(
    /// Whether the PTY relay should pause draining right now.
    slopdesk_replay_should_pause_drain -> bool, false, |buffer| buffer.should_pause_drain()
);
observer!(
    /// Monotonic mutation counter over the acked ring, guarding a detach-time fold splice.
    slopdesk_replay_ring_generation -> u64, 0, |buffer| buffer.ring_generation()
);
observer!(
    /// Number of entries in the scrollback ring.
    slopdesk_replay_ring_len -> usize, 0, |buffer| buffer.scrollback_ring_len()
);
observer!(
    /// Total bytes in the scrollback ring.
    slopdesk_replay_ring_bytes -> usize, 0, |buffer| buffer.scrollback_ring_bytes()
);
observer!(
    /// The effective retained-byte ceiling for this buffer.
    slopdesk_replay_max_backup_cap -> usize, 0, |buffer| buffer.max_backup_bytes_cap()
);
observer!(
    /// The effective offline gate for this buffer.
    slopdesk_replay_offline_gate_cap -> usize, 0, |buffer| buffer.offline_gate_bytes_cap()
);
observer!(
    /// The effective scrollback ring cap for this buffer (0 = ring disabled).
    slopdesk_replay_scrollback_cap -> usize, 0, |buffer| buffer.scrollback_bytes_cap()
);

/// Retained un-acked bytes with `seq > seq` — how far behind the head a subscriber that has
/// confirmed up to `seq` actually is.
///
/// # Safety
/// `handle` must be null, or a live handle with no other call on it in flight.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_replay_retained_bytes_above(
    handle: *mut SlopDeskReplay,
    seq: i64,
) -> usize {
    // SAFETY: the caller's obligation, restated above.
    unsafe { held(handle) }.map_or(0, |held| held.buffer.retained_bytes_above(seq))
}

/// Sets whether the connection layer considers the client reachable, which drives the offline gate.
///
/// # Safety
/// `handle` must be null, or a live handle with no other call on it in flight.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_replay_set_client_online(handle: *mut SlopDeskReplay, online: bool) {
    // SAFETY: the caller's obligation, restated above.
    if let Some(held) = unsafe { held(handle) } {
        held.buffer.set_client_online(online);
    }
}

// MARK: Mutation

/// Appends an output payload, assigns it the next seq, and returns that seq (0 on a null handle).
///
/// # Safety
/// `bytes` must be null or point to `len` initialised bytes live for the call; `handle` must be
/// null, or a live handle with no other call on it in flight.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_replay_append(
    handle: *mut SlopDeskReplay,
    bytes: *const c_uchar,
    len: usize,
) -> i64 {
    // SAFETY: both obligations are the caller's, restated above; `borrow` states its own.
    unsafe {
        let payload = borrow(bytes, len).to_vec();
        held(handle).map_or(0, |held| held.buffer.append(payload))
    }
}

/// Records a client ack, releasing retained entries with `seq <= seq` into the ring.
///
/// # Safety
/// `handle` must be null, or a live handle with no other call on it in flight.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_replay_ack(handle: *mut SlopDeskReplay, up_to: i64) {
    // SAFETY: the caller's obligation, restated above.
    if let Some(held) = unsafe { held(handle) } {
        held.buffer.ack(up_to);
    }
}

// MARK: Producers — the message slot

/// Fills the message slot with retained payloads above `last_received_seq`, raw, and returns the
/// count. The primitive behind control-channel snapshots; never distilled.
///
/// # Safety
/// `handle` must be null, or a live handle with no other call on it in flight.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_replay_messages(
    handle: *mut SlopDeskReplay,
    last_received_seq: i64,
) -> usize {
    // SAFETY: the caller's obligation, restated above.
    let Some(held) = (unsafe { held(handle) }) else {
        return 0;
    };
    held.results = held
        .buffer
        .messages(last_received_seq)
        .into_iter()
        .map(|(seq, bytes)| (seq, bytes.to_vec()))
        .collect();
    held.results.len()
}

/// Fills the message slot with the reconnect replay above `last_received_seq` and returns the
/// count.
///
/// This is the entry point that may call the distiller.
///
/// # Safety
/// `handle` must be null, or a live handle with no other call on it in flight; the distiller
/// installed at construction must still be callable.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_replay_replay(
    handle: *mut SlopDeskReplay,
    last_received_seq: i64,
) -> usize {
    // SAFETY: the caller's obligation, restated above.
    let Some(held) = (unsafe { held(handle) }) else {
        return 0;
    };
    let produced = held.buffer.replay(last_received_seq);
    held.take_messages(produced)
}

/// Fills the message slot with `data` re-chunked across `seqs`, always covering the last seq, and
/// returns the count.
///
/// # Safety
/// `data`/`seqs` must be null or point to `data_len`/`seqs_len` initialised elements live for the
/// call; `handle` must be null, or a live handle with no other call on it in flight.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_replay_rechunk_snapshot(
    handle: *mut SlopDeskReplay,
    data: *const c_uchar,
    data_len: usize,
    seqs: *const i64,
    seqs_len: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; `borrow` and `borrow_seqs` state their own.
    unsafe {
        let payload = borrow(data, data_len);
        let labels = borrow_seqs(seqs, seqs_len);
        let produced = ReplayBuffer::rechunk_snapshot(payload, labels);
        held(handle).map_or(0, |held| held.take_messages(produced))
    }
}

/// Borrows a caller-provided `(ptr, len)` of `i64` as a slice, treating null or empty as empty.
///
/// # Safety
/// `ptr` must either be null or point to `len` initialised `i64`s live and unaliased for the call.
#[expect(
    unsafe_code,
    reason = "this IS the boundary: a C pointer/length pair becoming a slice"
)]
const unsafe fn borrow_seqs<'a>(ptr: *const i64, len: usize) -> &'a [i64] {
    if ptr.is_null() || len == 0 {
        return &[];
    }
    // SAFETY: the caller's obligation above, discharged at the call site by Swift's
    // `withUnsafeBufferPointer`, whose scope is exactly this call.
    unsafe { std::slice::from_raw_parts(ptr, len) }
}

// MARK: Producers — the blob and seq slots

/// Fills the blob slot with the complete retained history and the seq slot with the seqs a rendered
/// stream may ride, and returns the bytes behind those seqs.
///
/// # Safety
/// `handle` must be null, or a live handle with no other call on it in flight.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_replay_snapshot_source(
    handle: *mut SlopDeskReplay,
    last_received_seq: i64,
) -> usize {
    // SAFETY: the caller's obligation, restated above.
    let Some(held) = (unsafe { held(handle) }) else {
        return 0;
    };
    let source = held.buffer.snapshot_source(last_received_seq);
    held.blob = source.history;
    held.seqs = source.replay_seqs;
    source.replay_bytes
}

/// Fills the blob and seq slots with the ring's fold material and returns its generation, or
/// `u64::MAX` when the ring is empty (no fold source — both slots are cleared).
///
/// # Safety
/// `handle` must be null, or a live handle with no other call on it in flight.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_replay_ring_fold_source(handle: *mut SlopDeskReplay) -> u64 {
    // SAFETY: the caller's obligation, restated above.
    let Some(held) = (unsafe { held(handle) }) else {
        return u64::MAX;
    };
    let Some(source) = held.buffer.ring_fold_source() else {
        held.blob.clear();
        held.seqs.clear();
        return u64::MAX;
    };
    held.blob = source.bytes;
    held.seqs = source.seqs;
    source.generation
}

/// Fills the seq slot with the ring's seqs, oldest-first, and returns the count.
///
/// # Safety
/// `handle` must be null, or a live handle with no other call on it in flight.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_replay_ring_seqs(handle: *mut SlopDeskReplay) -> usize {
    // SAFETY: the caller's obligation, restated above.
    let Some(held) = (unsafe { held(handle) }) else {
        return 0;
    };
    held.seqs = held.buffer.scrollback_ring_seqs();
    held.seqs.len()
}

/// Copies the oldest ring entry's bytes out, reporting the length. A ring length of 0 is how the
/// caller distinguishes "no oldest entry" from "an empty one".
///
/// # Safety
/// `out` must be null or writable for `cap` bytes; `handle` must be null, or a live handle with no
/// other call on it in flight.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_replay_ring_oldest(
    handle: *mut SlopDeskReplay,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; `deliver` states its own.
    unsafe {
        let Some(held) = held(handle) else { return 0 };
        let Some(oldest) = held.buffer.scrollback_ring_oldest() else {
            return 0;
        };
        deliver(oldest, out, cap)
    }
}

// MARK: Adoption — the staging slot

/// Clears the staging slot.
///
/// # Safety
/// `handle` must be null, or a live handle with no other call on it in flight.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_replay_input_clear(handle: *mut SlopDeskReplay) {
    // SAFETY: the caller's obligation, restated above.
    if let Some(held) = unsafe { held(handle) } {
        held.staged.clear();
    }
}

/// Stages one `output` message for [`slopdesk_replay_adopt_snapshot_replay`].
///
/// # Safety
/// `bytes` must be null or point to `len` initialised bytes live for the call; `handle` must be
/// null, or a live handle with no other call on it in flight.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_replay_input_push(
    handle: *mut SlopDeskReplay,
    seq: i64,
    bytes: *const c_uchar,
    len: usize,
) {
    // SAFETY: both obligations are the caller's, restated above; `borrow` states its own.
    unsafe {
        let payload = borrow(bytes, len).to_vec();
        if let Some(held) = held(handle) {
            held.staged.push(WireMessage::Output { seq, bytes: payload });
        }
    }
}

/// Replaces the entire retained history with the staged messages, then clears the staging slot.
///
/// # Safety
/// `handle` must be null, or a live handle with no other call on it in flight.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_replay_adopt_snapshot_replay(handle: *mut SlopDeskReplay) {
    // SAFETY: the caller's obligation, restated above.
    if let Some(held) = unsafe { held(handle) } {
        let staged = std::mem::take(&mut held.staged);
        held.buffer.adopt_snapshot_replay(&staged);
    }
}

/// Replaces the acked ring with `rendered` re-chunked across `seqs`, unless the buffer has mutated
/// since `generation` was captured. Returns whether the splice happened.
///
/// # Safety
/// `rendered`/`seqs` must be null or point to `rendered_len`/`seqs_len` initialised elements live
/// for the call; `handle` must be null, or a live handle with no other call on it in flight.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_replay_adopt_folded_ring(
    handle: *mut SlopDeskReplay,
    rendered: *const c_uchar,
    rendered_len: usize,
    seqs: *const i64,
    seqs_len: usize,
    generation: u64,
) -> bool {
    // SAFETY: the caller's obligations, restated above; `borrow`/`borrow_seqs` state their own.
    unsafe {
        let bytes = borrow(rendered, rendered_len);
        let labels = borrow_seqs(seqs, seqs_len);
        // `bytes` is the ring as it WAS; `adopt_folded_ring` reads only `generation` and `seqs`,
        // so shipping it back across the boundary would copy the whole ring to be ignored.
        let source = slopdesk_wire::replay::RingFoldSource {
            bytes: Vec::new(),
            seqs: labels.to_vec(),
            generation,
        };
        held(handle).is_some_and(|held| held.buffer.adopt_folded_ring(bytes, &source))
    }
}

// MARK: Reading the slots

// There is no `slopdesk_replay_result_count`. The calls that FILL the slot —
// `slopdesk_replay_messages` and `slopdesk_replay_replay` — return the count they staged, so the
// caller already holds it before it can index anything. A second door answering the same question
// is a second source of truth for how many slots are live, and the two can only ever agree or be a
// bug; Swift never called it.

/// The seq of message `index`, or `-1` when out of range — a valid seq is always positive.
///
/// # Safety
/// `handle` must be null, or a live handle with no other call on it in flight.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_replay_result_seq(handle: *mut SlopDeskReplay, index: usize) -> i64 {
    // SAFETY: the caller's obligation, restated above.
    unsafe { held(handle) }
        .and_then(|held| held.results.get(index))
        .map_or(-1, |entry| entry.0)
}

/// The payload length of message `index`, or 0 when out of range.
///
/// # Safety
/// `handle` must be null, or a live handle with no other call on it in flight.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_replay_result_len(handle: *mut SlopDeskReplay, index: usize) -> usize {
    // SAFETY: the caller's obligation, restated above.
    unsafe { held(handle) }
        .and_then(|held| held.results.get(index))
        .map_or(0, |entry| entry.1.len())
}

/// Copies message `index` out, reporting its length.
///
/// # Safety
/// `out` must be null or writable for `cap` bytes; `handle` must be null, or a live handle with no
/// other call on it in flight.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_replay_result_copy(
    handle: *mut SlopDeskReplay,
    index: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; `deliver` states its own.
    unsafe {
        let Some(held) = held(handle) else { return 0 };
        let Some(entry) = held.results.get(index) else {
            return 0;
        };
        deliver(&entry.1, out, cap)
    }
}

/// How many bytes the blob slot holds.
///
/// # Safety
/// `handle` must be null, or a live handle with no other call on it in flight.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_replay_blob_len(handle: *mut SlopDeskReplay) -> usize {
    // SAFETY: the caller's obligation, restated above.
    unsafe { held(handle) }.map_or(0, |held| held.blob.len())
}

/// Copies the blob slot out, reporting its length.
///
/// # Safety
/// `out` must be null or writable for `cap` bytes; `handle` must be null, or a live handle with no
/// other call on it in flight.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_replay_blob_copy(
    handle: *mut SlopDeskReplay,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; `deliver` states its own.
    unsafe {
        let Some(held) = held(handle) else { return 0 };
        deliver(&held.blob, out, cap)
    }
}

/// How many seqs the seq slot holds.
///
/// # Safety
/// `handle` must be null, or a live handle with no other call on it in flight.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_replay_seqs_count(handle: *mut SlopDeskReplay) -> usize {
    // SAFETY: the caller's obligation, restated above.
    unsafe { held(handle) }.map_or(0, |held| held.seqs.len())
}

/// Copies the seq slot out, reporting its count.
///
/// # Safety
/// `out` must be null or writable for `cap` `i64`s; `handle` must be null, or a live handle with no
/// other call on it in flight.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_replay_seqs_copy(
    handle: *mut SlopDeskReplay,
    out: *mut i64,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; `deliver_seqs` states its own.
    unsafe {
        let Some(held) = held(handle) else { return 0 };
        deliver_seqs(&held.seqs, out, cap)
    }
}

#[cfg(test)]
// The fixtures are known-good and built inline, so `unwrap` IS the assertion, and the tests
// deliberately drive the raw handle the way Swift does.
#[expect(
    unsafe_code,
    reason = "driving the C ABI the way Swift does is the thing under test"
)]
mod tests {

    use super::{
        SlopDeskReplay, slopdesk_replay_ack, slopdesk_replay_acked_seq, slopdesk_replay_append,
        slopdesk_replay_free, slopdesk_replay_highest_seq, slopdesk_replay_messages, slopdesk_replay_new,
        slopdesk_replay_replay, slopdesk_replay_result_copy, slopdesk_replay_result_len,
        slopdesk_replay_result_seq, slopdesk_replay_retained_bytes, slopdesk_replay_ring_bytes,
        slopdesk_replay_ring_len, slopdesk_replay_set_client_online, slopdesk_replay_should_pause_drain,
    };

    /// A handle at tiny caps, so the gates are reachable without allocating 256 MiB.
    fn handle() -> *mut SlopDeskReplay {
        // SAFETY: no distiller, so there is no function pointer whose validity to promise.
        unsafe { slopdesk_replay_new(64, 32, 128, true, false) }
    }

    fn append(handle: *mut SlopDeskReplay, bytes: &[u8]) -> i64 {
        // SAFETY: the slice is a live local and the handle is this test's, unshared.
        unsafe { slopdesk_replay_append(handle, bytes.as_ptr(), bytes.len()) }
    }

    /// Reads the message slot the way the Swift wrapper does: the PRODUCER's return is the count
    /// (there is no separate count door — see the note above the reading section), then length,
    /// then copy.
    fn results(handle: *mut SlopDeskReplay, staged: usize) -> Vec<(i64, Vec<u8>)> {
        // SAFETY: the handle is this test's and every buffer below is a live local.
        unsafe {
            (0..staged)
                .map(|index| {
                    let mut payload = vec![0_u8; slopdesk_replay_result_len(handle, index)];
                    let copied =
                        slopdesk_replay_result_copy(handle, index, payload.as_mut_ptr(), payload.len());
                    assert_eq!(copied, payload.len(), "the length and the copy must agree");
                    (slopdesk_replay_result_seq(handle, index), payload)
                })
                .collect()
        }
    }

    /// The seq/ack bookkeeping crosses the boundary intact, and the ring takes the acked prefix.
    #[test]
    fn appending_acking_and_reading_back_agrees_with_the_buffer() {
        let handle = handle();
        assert_eq!(append(handle, b"one\n"), 1);
        assert_eq!(append(handle, b"two\n"), 2);
        // SAFETY: the handle is this test's, unshared.
        unsafe {
            assert_eq!(slopdesk_replay_highest_seq(handle), 2);
            assert_eq!(slopdesk_replay_retained_bytes(handle), 8);
            slopdesk_replay_ack(handle, 1);
            assert_eq!(slopdesk_replay_acked_seq(handle), 1);
            assert_eq!(slopdesk_replay_retained_bytes(handle), 4);
            assert_eq!(slopdesk_replay_ring_len(handle), 1);
            assert_eq!(slopdesk_replay_ring_bytes(handle), 4);
            assert_eq!(slopdesk_replay_messages(handle, 0), 2, "ring + tail");
        }
        assert_eq!(results(handle, 2), vec![
            (1, b"one\n".to_vec()),
            (2, b"two\n".to_vec())
        ]);
        // SAFETY: exactly one free for the one `new` above.
        unsafe { slopdesk_replay_free(handle) };
    }

    /// The offline gate is the reason the state lives in Rust at all: the answer after an append
    /// is what stops the host reading the PTY master.
    #[test]
    fn the_offline_gate_answers_through_the_boundary() {
        let handle = handle();
        append(handle, &[b'x'; 40]);
        // SAFETY: the handle is this test's, unshared.
        unsafe {
            assert!(!slopdesk_replay_should_pause_drain(handle), "40 < 64, and online");
            slopdesk_replay_set_client_online(handle, false);
            assert!(
                slopdesk_replay_should_pause_drain(handle),
                "40 >= the 32-byte offline gate"
            );
            slopdesk_replay_free(handle);
        }
    }

    /// A slot survives until the next producer overwrites it — the property that lets the caller
    /// take a length, allocate, and copy without holding anything in between.
    #[test]
    fn a_result_slot_holds_until_the_next_producer_runs() {
        let handle = handle();
        append(handle, b"one\n");
        append(handle, b"two\n");
        // SAFETY: the handle is this test's, unshared.
        unsafe {
            assert_eq!(slopdesk_replay_messages(handle, 0), 2);
            // Out-of-range reads `-1`, so the slot's extent is observable through the doors Swift
            // actually uses rather than through a second door that only says the same thing.
            assert_ne!(slopdesk_replay_result_seq(handle, 1), -1, "still there, unread");
            assert_eq!(slopdesk_replay_result_seq(handle, 2), -1, "and no further");
            assert_eq!(
                slopdesk_replay_replay(handle, 1),
                1,
                "a producer replaces the slot"
            );
            assert_ne!(slopdesk_replay_result_seq(handle, 0), -1);
            assert_eq!(
                slopdesk_replay_result_seq(handle, 1),
                -1,
                "the slot shrank to one"
            );
            slopdesk_replay_free(handle);
        }
    }

    /// An undersized copy writes nothing and reports the length, exactly like the pure convention.
    #[test]
    fn an_undersized_result_copy_writes_nothing() {
        let handle = handle();
        append(handle, b"hello");
        // SAFETY: the handle is this test's and `tiny` is a live local.
        unsafe {
            assert_eq!(slopdesk_replay_messages(handle, 0), 1);
            let mut tiny = [0xAA_u8; 2];
            let needed = slopdesk_replay_result_copy(handle, 0, tiny.as_mut_ptr(), tiny.len());
            assert_eq!(needed, 5);
            assert_eq!(
                tiny,
                [0xAA, 0xAA],
                "an undersized call must not write a partial payload"
            );
            slopdesk_replay_free(handle);
        }
    }

    /// Every entry point tolerates a null handle, so a failed `new` cannot become a crash in the
    /// caller's `deinit` path.
    #[test]
    fn a_null_handle_is_inert() {
        let null = std::ptr::null_mut();
        // SAFETY: null is explicitly permitted by every entry point.
        unsafe {
            assert_eq!(slopdesk_replay_append(null, b"x".as_ptr(), 1), 0);
            assert_eq!(slopdesk_replay_highest_seq(null), 0);
            assert_eq!(slopdesk_replay_messages(null, 0), 0);
            assert_eq!(slopdesk_replay_result_seq(null, 0), -1);
            slopdesk_replay_ack(null, 5);
            slopdesk_replay_free(null);
        }
    }

    /// The cold replay is DISTILLED by the linked crate, with no callback and no socket.
    ///
    /// A closed alt-screen segment is the clearest proof the passes ran: a TUI's whole drawing is
    /// dropped and the history either side of it survives. It used to take a function pointer back
    /// into Swift and an `AF_UNIX` round trip to get this answer.
    #[test]
    fn a_cold_replay_is_sanitized_by_the_linked_crate() {
        // SAFETY: nothing is borrowed by `new` — the handle owns everything it needs.
        let handle = unsafe { slopdesk_replay_new(1024, 512, 4096, true, false) };
        let mut raw = b"before\n".to_vec();
        raw.extend_from_slice(b"\x1b[?1049h");
        raw.extend_from_slice(b"a whole TUI redrawing itself, tens of MiB in the real case\n");
        raw.extend_from_slice(b"\x1b[?1049l");
        raw.extend_from_slice(b"after\n");
        append(handle, &raw);
        // SAFETY: the handle is this test's, unshared.
        unsafe {
            slopdesk_replay_ack(handle, 1);
            assert_eq!(slopdesk_replay_replay(handle, 0), 1);
        }
        let emitted: Vec<u8> = results(handle, 1)
            .into_iter()
            .flat_map(|(_, bytes)| bytes)
            .collect();
        let text = String::from_utf8_lossy(&emitted).into_owned();
        assert!(
            text.contains("before"),
            "history before the segment survives: {text:?}"
        );
        assert!(text.contains("after"), "and history after it: {text:?}");
        assert!(
            !text.contains("redrawing itself"),
            "the closed segment is gone: {text:?}"
        );
        // SAFETY: exactly one free.
        unsafe { slopdesk_replay_free(handle) };
    }
}
