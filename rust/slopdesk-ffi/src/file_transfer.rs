//! PATH 4's CLIENT end — one door over the whole upload.
//!
//! `rust/slopdesk-dropd`'s `upload` module owns the sequence and its `client` module owns every
//! layout. This is the door, and it decides nothing.
//!
//! ## Why ONE door and not eight
//! It used to be eight — encode a request, decode a reply, feed a splitter, read a constant — with
//! a Swift driver above them holding the socket and the ORDER. Every one of those answers was right
//! on its own, and nothing could check the order they were put together in, which is exactly the
//! fault `docs/55` §4b records the audio stage earning: *a handle with a large surface is a law you
//! moved without moving its sequencing*. With the socket in Rust there is no order left on this
//! side to get wrong, so the door has one verb.
//!
//! ## The inverted convention
//! [`slopdesk_drop_upload`] BLOCKS for the whole batch and reports through a callback, which is
//! `docs/55` §4b's inversion at its simplest: nothing outlives the call, so there is no handle, no
//! `_free`, and no lifetime for a caller to get wrong. Three obligations, and they are the
//! inversion's usual ones:
//!
//! 1. `context` must stay valid until this call RETURNS. Nothing retains it.
//! 2. The callback runs on the CALLING thread, never concurrently with itself, and never after the
//!    call has returned. A caller that hops it to an actor is hopping by choice, not by rule.
//! 3. `text` is LENT for the duration of one callback. A caller that keeps it copies it.
//!
//! ## What crosses
//! The batch is one NUL-separated blob, which is what `find -print0` and `xargs -0` have always
//! used and for the same reason: a POSIX path may hold every byte except `0`, so the separator
//! cannot occur inside a field and the face needs no length prefix — no big-endian write, no
//! framing, nothing this side of the door could spell differently from that side. Progress crosses
//! as scalars plus at most one borrowed string, which is all any of the four kinds carries.

use core::ffi::{c_uchar, c_void};
use std::path::Path;
use std::time::Duration;

use slopdesk_dropd::upload::{Progress, to_host};

use crate::borrow;

/// The file was opened and offered; `total_bytes` is its size and `text` its name.
pub const DROP_PROGRESS_STARTED: u32 = 0;
/// A chunk went out; `sent_bytes` and `total_bytes` carry it and `text` is empty.
pub const DROP_PROGRESS_ADVANCED: u32 = 1;
/// The host wrote the whole body and moved it into place. Every other field is 0 or empty.
pub const DROP_PROGRESS_COMPLETED: u32 = 2;
/// This transfer is over and the file did not land; `text` says why.
pub const DROP_PROGRESS_FAILED: u32 = 3;

/// One progress report, lent for the duration of the call.
///
/// Flat scalars rather than a `#[repr(C)]` record, because there are only four of them and every
/// kind reads a different three: a record would be a struct the near side has to size and a field
/// it has to remember not to read. `text` is a name for [`DROP_PROGRESS_STARTED`] and a reason for
/// [`DROP_PROGRESS_FAILED`]; `text_len` is 0 for the other two, and the pointer is then a dangling
/// non-null Rust reads as an empty string. Check the LENGTH, never the pointer.
pub type SlopDeskDropProgressFn = Option<
    unsafe extern "C" fn(
        context: *mut c_void,
        kind: u32,
        transfer_id: u32,
        sent_bytes: u64,
        total_bytes: u64,
        text: *const c_uchar,
        text_len: usize,
    ),
>;

/// Uploads every path in `paths` to `host:port` over ONE connection, reporting as it goes.
///
/// `paths` is one NUL-separated run of UTF-8 paths. Blocks until every file has completed or failed
/// and the socket is closed. Answers how many files the batch named — `0` when it named none, or
/// when `host` or a path is not UTF-8, in which case nothing was dialled and no callback ran.
///
/// A file is offered under its INDEX in `paths`, which is the `transfer_id` every report carries.
/// The batch is never silent: a host that cannot be dialled, or that refuses the version, fails
/// every file rather than returning with nothing said.
///
/// # Safety
/// `(host, host_len)` and `(paths, paths_len)` must each be null-with-zero-length or that many
/// readable bytes for the duration of the call; `host` must be UTF-8. `on_progress` must be null or
/// a valid function pointer, and `context` must stay valid until this returns — see the module
/// header's three obligations.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_drop_upload(
    host: *const c_uchar,
    host_len: usize,
    port: u16,
    paths: *const c_uchar,
    paths_len: usize,
    connect_timeout_ms: u64,
    context: *mut c_void,
    on_progress: SlopDeskDropProgressFn,
) -> usize {
    // SAFETY: the caller's obligations, above — two borrows, neither outliving the call.
    let (host, paths) = unsafe { (borrow(host, host_len), borrow(paths, paths_len)) };
    // An empty blob has to answer before the split: splitting nothing yields ONE empty field, and
    // an empty batch offered as one nameless file is the wrong answer twice over.
    if paths.is_empty() {
        return 0;
    }
    let (Ok(host), Ok(files)) = (
        core::str::from_utf8(host),
        paths
            .split(|byte| *byte == 0)
            .map(|field| core::str::from_utf8(field).map(Path::new))
            .collect::<Result<Vec<&Path>, _>>(),
    ) else {
        return 0;
    };
    let mut report = |progress: Progress<'_>| {
        let Some(deliver) = on_progress else {
            return;
        };
        let (kind, transfer_id, sent_bytes, total_bytes, text) = flatten(progress);
        // SAFETY: the context is live by the door's documented term, and `text` borrows a string
        // owned by the frame reporting it, so it outlives this call.
        unsafe {
            deliver(
                context,
                kind,
                transfer_id,
                sent_bytes,
                total_bytes,
                text.as_ptr(),
                text.len(),
            );
        }
    };
    to_host(
        host,
        port,
        Duration::from_millis(connect_timeout_ms),
        &files,
        &mut report,
    );
    files.len()
}

/// One report as the five scalars and the one borrowed string the callback takes.
const fn flatten(progress: Progress<'_>) -> (u32, u32, u64, u64, &str) {
    match progress {
        Progress::Started {
            transfer_id,
            name,
            total_bytes,
        } => (DROP_PROGRESS_STARTED, transfer_id, 0, total_bytes, name),
        Progress::Advanced {
            transfer_id,
            sent_bytes,
            total_bytes,
        } => (DROP_PROGRESS_ADVANCED, transfer_id, sent_bytes, total_bytes, ""),
        Progress::Completed { transfer_id } => (DROP_PROGRESS_COMPLETED, transfer_id, 0, 0, ""),
        Progress::Failed { transfer_id, reason } => (DROP_PROGRESS_FAILED, transfer_id, 0, 0, reason),
    }
}

#[cfg(test)]
#[expect(unsafe_code, reason = "calling the door is the only way to test the door")]
mod tests {
    use core::ffi::c_void;
    use core::ptr;
    use std::net::TcpListener;

    use super::{DROP_PROGRESS_FAILED, slopdesk_drop_upload};

    /// A batch of paths in the separation the door splits on.
    fn batch(paths: &[&str]) -> Vec<u8> {
        paths.join("\0").into_bytes()
    }

    /// What one call reported, collected through the callback's opaque context.
    #[derive(Debug, Default)]
    struct Reports(Vec<(u32, u32, String)>);

    /// The `@convention(c)` shape, appending to a [`Reports`] the caller still owns.
    unsafe extern "C" fn record(
        context: *mut c_void,
        kind: u32,
        transfer_id: u32,
        _sent: u64,
        _total: u64,
        text: *const u8,
        text_len: usize,
    ) {
        if context.is_null() {
            return;
        }
        // SAFETY: the context is the caller's `Reports`, live for the whole call below, and the
        // text is lent for the duration of this one.
        let (reports, text) = unsafe { (&mut *context.cast::<Reports>(), crate::borrow(text, text_len)) };
        reports
            .0
            .push((kind, transfer_id, String::from_utf8_lossy(text).into_owned()));
    }

    #[test]
    fn a_path_that_is_not_utf8_dials_nothing_and_answers_zero() {
        let mut reports = Reports::default();
        // A lone continuation byte: no UTF-8 sequence starts with it.
        let ragged = [b'/', b't', 0, 0x80];
        // SAFETY: every span is a live local, and the callback context is `reports`.
        let attempted = unsafe {
            slopdesk_drop_upload(
                b"127.0.0.1".as_ptr(),
                9,
                1,
                ragged.as_ptr(),
                ragged.len(),
                50,
                ptr::from_mut(&mut reports).cast(),
                Some(record),
            )
        };
        assert_eq!(attempted, 0);
        assert!(reports.0.is_empty(), "nothing was dialled, so nothing was said");
    }

    #[test]
    fn an_empty_batch_answers_zero_without_a_socket() {
        // SAFETY: null-with-zero-length is the documented absent buffer for both spans.
        let attempted =
            unsafe { slopdesk_drop_upload(ptr::null(), 0, 1, ptr::null(), 0, 50, ptr::null_mut(), None) };
        assert_eq!(attempted, 0);
    }

    #[test]
    fn an_unreachable_host_reports_a_failure_per_file_rather_than_nothing() {
        // Bound and immediately dropped, so nothing is listening on that port any more.
        let port = TcpListener::bind("127.0.0.1:0")
            .and_then(|listener| listener.local_addr())
            .map_or(0, |address| address.port());
        let blob = batch(&["/nowhere/one.txt", "/nowhere/two.txt"]);
        let mut reports = Reports::default();

        // SAFETY: every span is a live local, and the callback context is `reports`.
        let attempted = unsafe {
            slopdesk_drop_upload(
                b"127.0.0.1".as_ptr(),
                9,
                port,
                blob.as_ptr(),
                blob.len(),
                200,
                ptr::from_mut(&mut reports).cast(),
                Some(record),
            )
        };

        assert_eq!(attempted, 2);
        assert_eq!(reports.0.len(), 2);
        assert!(
            reports
                .0
                .iter()
                .all(|(kind, _id, said)| *kind == DROP_PROGRESS_FAILED && !said.is_empty()),
            "{reports:?}"
        );
        assert_eq!(reports.0.first().map(|report| report.1), Some(0));
        assert_eq!(reports.0.last().map(|report| report.1), Some(1));
    }

    #[test]
    fn a_null_callback_still_runs_the_batch_rather_than_faulting() {
        let port = TcpListener::bind("127.0.0.1:0")
            .and_then(|listener| listener.local_addr())
            .map_or(0, |address| address.port());
        let blob = batch(&["/nowhere/one.txt"]);
        // SAFETY: every span is a live local; a null callback and context are documented as absent.
        let attempted = unsafe {
            slopdesk_drop_upload(
                b"127.0.0.1".as_ptr(),
                9,
                port,
                blob.as_ptr(),
                blob.len(),
                200,
                ptr::null_mut(),
                None,
            )
        };
        assert_eq!(attempted, 1);
    }
}
