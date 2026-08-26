//! The LINE the embedded editor speaks — the doors over the second half of
//! [`slopdesk_muxsession::bridge_router`].
//!
//! ## What replaced what
//! `Sources/SlopDeskHost/CodeBridgeServer.swift`'s pure halves: which workbench window owns a file,
//! the whole `hello`/`run`/`cd` verb table, what may be typed at a shell prompt, and the two lines
//! the host writes back. What is left on the Swift side is the socket, the accept loop, the
//! per-connection read threads and the `(st_dev, st_ino)` rebind guard — descriptors and threads,
//! none of which decides anything.
//!
//! It is a file of its own rather than more of [`crate::code_bridge`] because the two answer
//! different questions about the same feature: that one picks a PANE out of the host's live
//! sessions, this one reads and writes the socket's own grammar. They share a rules module and
//! nothing else.
//!
//! ## Why a parsed line comes back as a blob rather than as fields
//! An inbound `run` carries four strings, two of which are attacker-chosen and unbounded up to the
//! line cap. Four `(out, cap)` pairs would mean four deliveries with four independent retries; one
//! blob of `crate::push_text` runs is one delivery with one, which is the shape `docs/55` §4
//! already uses everywhere a door answers a LIST. The leading byte is the verb, so the caller knows
//! how many runs to expect before it walks them — a count inferred from the blob's own length would
//! make a truncated delivery look like a different message rather than like a bug.

use core::ffi::c_uchar;

use slopdesk_muxsession::bridge_router::{self, BridgeWindow, Inbound, MAX_LINE_BYTES, MAX_RUN_TEXT_BYTES};

use crate::{borrow, deliver, lent, optional_of, push_text, records_of};

/// [`slopdesk_code_bridge_route`]: no connected window's workspace folder contains the target.
///
/// Negative because every real answer is a descriptor, and a descriptor is never negative. A
/// malformed record set answers this too: refusing to route is the safe direction, and the caller's
/// fallback for an unrouted open is the `code-server` CLI, which opens the file anyway.
pub const SLOPDESK_CODE_BRIDGE_NO_WINDOW: i32 = -1;

/// [`slopdesk_code_bridge_inbound`]: nothing was believed; the line is dropped.
pub const SLOPDESK_CODE_BRIDGE_INBOUND_NOTHING: u8 = 0;
/// [`slopdesk_code_bridge_inbound`]: a `hello`. One run follows — the window's workspace folder.
pub const SLOPDESK_CODE_BRIDGE_INBOUND_HELLO: u8 = 1;
/// [`slopdesk_code_bridge_inbound`]: a `run` or a `cd`.
///
/// Four runs follow, in order: the correlation id, the project root, the acting directory (EMPTY
/// when there was none — an accepted directory is always absolute, so the empty string cannot be
/// one) and the text to type.
pub const SLOPDESK_CODE_BRIDGE_INBOUND_RUN: u8 = 2;

/// One connected workbench window, as its descriptor plus offsets into the caller's text blob.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct BridgeWindowRecord {
    /// The connection's descriptor — both the answer [`slopdesk_code_bridge_route`] gives and the
    /// key it settles ties on.
    pub fd: i32,
    /// Where this window's workspace folder begins in the blob.
    pub root_offset: usize,
    /// How many bytes of the blob the folder occupies.
    pub root_len: usize,
}

/// Max bytes of one line the extension may send. The read loop that enforces it is the caller's,
/// because it is the one holding the buffer; the number is the rules module's, so there is one.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_code_bridge_max_line_bytes() -> usize {
    MAX_LINE_BYTES
}

/// Max bytes of command text a single `run` may carry.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_code_bridge_max_run_text_bytes() -> usize {
    MAX_RUN_TEXT_BYTES
}

/// The descriptor of the window that should own `target`, or [`SLOPDESK_CODE_BRIDGE_NO_WINDOW`].
///
/// # Safety
/// `windows` must be null or describe `count` live records for the call; `blob` and `target` must
/// be null or point to their stated lengths of initialised bytes live for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_code_bridge_route(
    windows: *const BridgeWindowRecord,
    count: usize,
    blob: *const c_uchar,
    blob_len: usize,
    target: *const c_uchar,
    target_len: usize,
) -> i32 {
    // SAFETY: the caller's obligations, restated above; the helpers state their own.
    let (records, blob, target) = unsafe {
        (
            records_of(windows, count),
            borrow(blob, blob_len),
            lent(target, target_len),
        )
    };
    let mut flattened: Vec<BridgeWindow> = Vec::with_capacity(records.len());
    for record in records {
        let Some(root) = field(blob, record.root_offset, record.root_len) else {
            return SLOPDESK_CODE_BRIDGE_NO_WINDOW;
        };
        flattened.push(BridgeWindow {
            fd: record.fd,
            root: root.to_owned(),
        });
    }
    bridge_router::route(target, &flattened).unwrap_or(SLOPDESK_CODE_BRIDGE_NO_WINDOW)
}

/// A record's field as a `&str`, or `None` when it points outside the blob or is not UTF-8.
fn field(blob: &[u8], offset: usize, len: usize) -> Option<&str> {
    let end = offset.checked_add(len)?;
    core::str::from_utf8(blob.get(offset..end)?).ok()
}

/// The `open` line for a target already split into its path and its `:line[:col]` suffix, newline
/// included. Zero means the value would not serialise, and the caller writes nothing.
///
/// # Safety
/// `path` and `suffix` must be null or point to their stated lengths of initialised bytes live for
/// the call; `out` must be null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_code_bridge_open_line(
    path: *const c_uchar,
    path_len: usize,
    suffix: *const c_uchar,
    suffix_len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; the helpers state their own.
    unsafe {
        let line = bridge_router::open_command(lent(path, path_len), lent(suffix, suffix_len));
        deliver(line.as_bytes(), out, cap)
    }
}

/// The result line for a finished `run`, newline included.
///
/// `has_pane` and `has_message` distinguish an ABSENT field from an empty one — `docs/55` §4b's
/// presence-flag convention — because the extension tells them apart and an empty `pane` would have
/// it announce a pane with no name.
///
/// # Safety
/// `id`, `pane` and `message` must be null or point to their stated lengths of initialised bytes
/// live for the call; `out` must be null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_code_bridge_result_line(
    id: *const c_uchar,
    id_len: usize,
    ok: bool,
    pane: *const c_uchar,
    pane_len: usize,
    has_pane: bool,
    message: *const c_uchar,
    message_len: usize,
    has_message: bool,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; the helpers state their own.
    unsafe {
        let line = bridge_router::result_line(
            lent(id, id_len),
            ok,
            optional_of(has_pane, lent(pane, pane_len)),
            optional_of(has_message, lent(message, message_len)),
        );
        deliver(line.as_bytes(), out, cap)
    }
}

/// Whether `text` may be typed at a live shell prompt.
///
/// # Safety
/// `text` must be null or point to `len` initialised bytes live for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_code_bridge_typeable(text: *const c_uchar, len: usize) -> bool {
    // SAFETY: the caller's obligation, restated above; `lent` states its own.
    bridge_router::is_typeable(unsafe { lent(text, len) })
}

/// One inbound line, believed or dropped.
///
/// The answer is the verb byte followed by that verb's runs — see
/// [`SLOPDESK_CODE_BRIDGE_INBOUND_HELLO`] and [`SLOPDESK_CODE_BRIDGE_INBOUND_RUN`] for the layouts.
/// A return of `0` is a dropped line and writes nothing, which is the same "no answer" every other
/// door in the crate spells that way.
///
/// # Safety
/// `line` must be null or point to `len` initialised bytes live for the call; `out` must be null or
/// writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_code_bridge_inbound(
    line: *const c_uchar,
    len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; the helpers state their own.
    let believed = bridge_router::inbound(unsafe { borrow(line, len) });
    let mut blob: Vec<u8> = Vec::new();
    match believed {
        None => return 0,
        Some(Inbound::Hello(root)) => {
            blob.push(SLOPDESK_CODE_BRIDGE_INBOUND_HELLO);
            push_text(&mut blob, &root);
        },
        Some(Inbound::Run(request)) => {
            blob.push(SLOPDESK_CODE_BRIDGE_INBOUND_RUN);
            push_text(&mut blob, &request.id);
            push_text(&mut blob, &request.root);
            push_text(&mut blob, request.directory.as_deref().unwrap_or_default());
            push_text(&mut blob, &request.text);
        },
    }
    // SAFETY: the caller's obligation, restated above; `deliver` states its own.
    unsafe { deliver(&blob, out, cap) }
}

#[cfg(test)]
#[expect(
    unsafe_code,
    clippy::indexing_slicing,
    reason = "calling the boundary IS what these tests are for, and a panic in a test is the report"
)]
mod tests {
    use super::{
        BridgeWindowRecord, SLOPDESK_CODE_BRIDGE_INBOUND_HELLO, SLOPDESK_CODE_BRIDGE_INBOUND_RUN,
        SLOPDESK_CODE_BRIDGE_NO_WINDOW, slopdesk_code_bridge_inbound, slopdesk_code_bridge_max_line_bytes,
        slopdesk_code_bridge_max_run_text_bytes, slopdesk_code_bridge_open_line,
        slopdesk_code_bridge_result_line, slopdesk_code_bridge_route, slopdesk_code_bridge_typeable,
    };

    /// Builds the blob + records the door reads, the way the Swift face does.
    fn encode(windows: &[(i32, &str)]) -> (Vec<u8>, Vec<BridgeWindowRecord>) {
        let mut blob: Vec<u8> = Vec::new();
        let mut records: Vec<BridgeWindowRecord> = Vec::new();
        for (fd, root) in windows {
            let root_offset = blob.len();
            blob.extend_from_slice(root.as_bytes());
            records.push(BridgeWindowRecord {
                fd: *fd,
                root_offset,
                root_len: root.len(),
            });
        }
        (blob, records)
    }

    fn route(windows: &[(i32, &str)], target: &str) -> i32 {
        let (blob, records) = encode(windows);
        unsafe {
            slopdesk_code_bridge_route(
                records.as_ptr(),
                records.len(),
                blob.as_ptr(),
                blob.len(),
                target.as_ptr(),
                target.len(),
            )
        }
    }

    /// Reads a delivery door twice the way `ffiAnswerBytes` does — guess, then grow.
    fn answer(door: impl Fn(*mut u8, usize) -> usize) -> Vec<u8> {
        let mut out = vec![0_u8; 8];
        let mut needed = door(out.as_mut_ptr(), out.len());
        if needed > out.len() {
            out = vec![0_u8; needed];
            needed = door(out.as_mut_ptr(), out.len());
        }
        if needed == 0 || needed > out.len() {
            return Vec::new();
        }
        out[..needed].to_vec()
    }

    /// The Swift `ffiRuns` walk, so the two halves of the framing are exercised together.
    fn runs(blob: &[u8], count: usize) -> Vec<String> {
        let mut walked = Vec::with_capacity(count);
        let mut cursor = 0_usize;
        for _ in 0..count {
            if cursor + 4 > blob.len() {
                break;
            }
            let length = usize::try_from(u32::from_be_bytes([
                blob[cursor],
                blob[cursor + 1],
                blob[cursor + 2],
                blob[cursor + 3],
            ]))
            .unwrap_or(usize::MAX);
            cursor += 4;
            if cursor + length > blob.len() {
                break;
            }
            walked.push(String::from_utf8_lossy(&blob[cursor..cursor + length]).into_owned());
            cursor += length;
        }
        walked
    }

    #[test]
    fn the_descriptor_of_the_owning_window_comes_back() {
        let windows = [(4, "/work"), (5, "/work/alpha")];
        assert_eq!(route(&windows, "/work/alpha/x.swift"), 5);
        assert_eq!(route(&windows, "/work/x.swift"), 4);
        assert_eq!(
            route(&windows, "/elsewhere/x.swift"),
            SLOPDESK_CODE_BRIDGE_NO_WINDOW
        );
        assert_eq!(route(&[], "/work/x.swift"), SLOPDESK_CODE_BRIDGE_NO_WINDOW);
    }

    /// A record reaching past the blob is a caller this door does not understand — refuse to route
    /// rather than read whatever is next in memory.
    #[test]
    fn a_record_pointing_outside_the_blob_routes_nowhere() {
        let (blob, mut records) = encode(&[(4, "/work")]);
        records[0].root_len = blob.len() + 32;
        let target = "/work/x.swift";
        let answer = unsafe {
            slopdesk_code_bridge_route(
                records.as_ptr(),
                records.len(),
                blob.as_ptr(),
                blob.len(),
                target.as_ptr(),
                target.len(),
            )
        };
        assert_eq!(answer, SLOPDESK_CODE_BRIDGE_NO_WINDOW);
    }

    #[test]
    fn the_open_and_result_lines_cross_whole() {
        let path = "/work/a.swift";
        let suffix = ":42:7";
        let line = answer(|out, cap| unsafe {
            slopdesk_code_bridge_open_line(path.as_ptr(), path.len(), suffix.as_ptr(), suffix.len(), out, cap)
        });
        assert_eq!(
            String::from_utf8_lossy(&line),
            "{\"col\":7,\"line\":42,\"path\":\"/work/a.swift\",\"t\":\"open\"}\n"
        );

        let id = "7";
        let pane = "zsh";
        let line = answer(|out, cap| unsafe {
            slopdesk_code_bridge_result_line(
                id.as_ptr(),
                id.len(),
                true,
                pane.as_ptr(),
                pane.len(),
                true,
                core::ptr::null(),
                0,
                false,
                out,
                cap,
            )
        });
        assert_eq!(
            String::from_utf8_lossy(&line),
            "{\"id\":\"7\",\"ok\":true,\"pane\":\"zsh\",\"t\":\"result\"}\n"
        );
    }

    #[test]
    fn a_believed_line_crosses_as_its_verb_then_its_runs() {
        let hello = br#"{"t":"hello","root":"/work/alpha"}"#;
        let blob =
            answer(|out, cap| unsafe { slopdesk_code_bridge_inbound(hello.as_ptr(), hello.len(), out, cap) });
        assert_eq!(blob[0], SLOPDESK_CODE_BRIDGE_INBOUND_HELLO);
        assert_eq!(runs(&blob[1..], 1), vec!["/work/alpha".to_owned()]);

        let run = br#"{"t":"run","id":"7","root":"/work","cwd":"/work/src","text":"ls"}"#;
        let blob =
            answer(|out, cap| unsafe { slopdesk_code_bridge_inbound(run.as_ptr(), run.len(), out, cap) });
        assert_eq!(blob[0], SLOPDESK_CODE_BRIDGE_INBOUND_RUN);
        assert_eq!(runs(&blob[1..], 4), vec![
            "7".to_owned(),
            "/work".to_owned(),
            "/work/src".to_owned(),
            "ls".to_owned(),
        ]);
    }

    /// An absent acting directory crosses as an EMPTY run rather than as a missing one, so the run
    /// count is a property of the verb and not of the message's contents.
    #[test]
    fn an_absent_working_directory_still_occupies_its_run() {
        let run = br#"{"t":"run","id":"7","root":"/work","text":"ls"}"#;
        let blob =
            answer(|out, cap| unsafe { slopdesk_code_bridge_inbound(run.as_ptr(), run.len(), out, cap) });
        assert_eq!(runs(&blob[1..], 4).len(), 4);
        assert_eq!(runs(&blob[1..], 4)[2], "");
    }

    #[test]
    fn a_dropped_line_delivers_nothing() {
        let line = b"not json at all";
        let written =
            unsafe { slopdesk_code_bridge_inbound(line.as_ptr(), line.len(), core::ptr::null_mut(), 0) };
        assert_eq!(written, 0);
    }

    #[test]
    fn the_typeable_gate_and_the_two_caps_cross() {
        let text = "ls -la";
        assert!(unsafe { slopdesk_code_bridge_typeable(text.as_ptr(), text.len()) });
        assert!(!unsafe { slopdesk_code_bridge_typeable(core::ptr::null(), 0) });
        assert_eq!(slopdesk_code_bridge_max_line_bytes(), 64 * 1024);
        assert_eq!(slopdesk_code_bridge_max_run_text_bytes(), 8 * 1024);
    }
}
