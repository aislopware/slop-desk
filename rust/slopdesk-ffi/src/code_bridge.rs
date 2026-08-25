//! Which pane a command from the embedded editor lands in — the doors over
//! [`slopdesk_muxsession::bridge_router`].
//!
//! ## What replaced what
//! `Sources/SlopDeskHost/CodeBridgeTerminalRouter.swift`: the three-filter ladder, the ranking, the
//! `cd` line and the two refusal sentences. Containment and shell quoting were already doors this
//! side of the boundary ([`crate::path_confine`], [`crate::workspace`]) and the router called them
//! through Swift; now it calls them directly, in the crate where the ranking is.
//!
//! ## The pane list crosses as records into one text blob
//! `docs/55` §4's array shape, for the module doc's reason in [`crate::agent`]: a pane carries
//! three strings, and three `(ptr, len)` pairs per pane would mean that many nested
//! `withUnsafeBytes` on the Swift side per call. One blob, one lifetime, one scope — and every
//! offset is bounds-checked here, because this is untrusted input like everything else in the
//! crate.
//!
//! ## The answer is an INDEX, not a pane
//! The caller already holds the panes; handing one back would mean re-encoding a string it is
//! looking at. A non-negative answer indexes `panes`; a negative one is a refusal, and
//! [`slopdesk_code_bridge_message`] turns it into the sentence the editor shows.

use core::ffi::c_uchar;

use slopdesk_muxsession::bridge_router::{self, BridgePane, Refusal};

use crate::{borrow, deliver, records_of};

/// [`slopdesk_code_bridge_choose`]: no pane of this project is open anywhere.
pub const SLOPDESK_CODE_BRIDGE_NO_PANE_IN_PROJECT: i32 = -1;
/// [`slopdesk_code_bridge_choose`]: panes exist, but every one is busy or has an agent in it.
pub const SLOPDESK_CODE_BRIDGE_NO_IDLE_PANE: i32 = -2;
/// [`slopdesk_code_bridge_choose`]: a record pointed outside the blob, or a string was not UTF-8.
pub const SLOPDESK_CODE_BRIDGE_MALFORMED: i32 = -3;

/// One candidate pane, as offsets into the caller's text blob.
///
/// A cwd is optional — `has_cwd == false` means the host has not observed one yet, and such a pane
/// is never chosen, because containment is what keeps a command inside its own project.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct BridgePaneRecord {
    /// Where this pane's id begins in the blob, and how long it is.
    pub pane_id_offset: usize,
    /// How many bytes of the blob the pane id occupies.
    pub pane_id_len: usize,
    /// Where this pane's observed cwd begins in the blob.
    pub cwd_offset: usize,
    /// How many bytes of the blob the cwd occupies.
    pub cwd_len: usize,
    /// Whether a cwd has been observed at all.
    pub has_cwd: bool,
    /// Where this pane's foreground process basename begins in the blob.
    pub foreground_offset: usize,
    /// How many bytes of the blob the basename occupies.
    pub foreground_len: usize,
    /// Whether an agent was detected in this pane.
    pub has_agent: bool,
}

/// A record's field as a `&str`, or `None` when it points outside the blob or is not UTF-8.
fn field(blob: &[u8], offset: usize, len: usize) -> Option<&str> {
    let end = offset.checked_add(len)?;
    core::str::from_utf8(blob.get(offset..end)?).ok()
}

/// The pane that should receive a command issued from the workbench rooted at `root`.
///
/// Answers the index into `panes`, or one of the three negative constants above. `directory` is
/// where the command is ABOUT — used only to RANK, never to filter — and `has_directory == false`
/// means the caller had none, which is not an error.
///
/// # Safety
/// `panes` must be null or describe `count` live records for the call; `blob`, `root` and
/// `directory` must be null or point to their stated lengths of initialised bytes live for the
/// call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_code_bridge_choose(
    panes: *const BridgePaneRecord,
    count: usize,
    blob: *const c_uchar,
    blob_len: usize,
    root: *const c_uchar,
    root_len: usize,
    directory: *const c_uchar,
    directory_len: usize,
    has_directory: bool,
) -> i32 {
    // SAFETY: the caller's obligations, restated above; `borrow` and `records_of` state their own.
    let (records, blob, root, acting) = unsafe {
        (
            records_of(panes, count),
            borrow(blob, blob_len),
            core::str::from_utf8(borrow(root, root_len)),
            has_directory
                .then(|| core::str::from_utf8(borrow(directory, directory_len)).ok())
                .flatten(),
        )
    };
    let Ok(root) = root else {
        return SLOPDESK_CODE_BRIDGE_MALFORMED;
    };
    let mut flattened: Vec<BridgePane> = Vec::with_capacity(records.len());
    for record in records {
        let (Some(pane_id), Some(foreground)) = (
            field(blob, record.pane_id_offset, record.pane_id_len),
            field(blob, record.foreground_offset, record.foreground_len),
        ) else {
            return SLOPDESK_CODE_BRIDGE_MALFORMED;
        };
        let cwd = if record.has_cwd {
            let Some(cwd) = field(blob, record.cwd_offset, record.cwd_len) else {
                return SLOPDESK_CODE_BRIDGE_MALFORMED;
            };
            Some(cwd.to_owned())
        } else {
            None
        };
        flattened.push(BridgePane {
            pane_id: pane_id.to_owned(),
            cwd,
            has_agent: record.has_agent,
            foreground: foreground.to_owned(),
        });
    }
    match bridge_router::choose(&flattened, root, acting) {
        // The router answers a borrow of `flattened`, whose order is the caller's — so the index of
        // the winner in it IS the index the caller asked about.
        Ok(chosen) => {
            flattened
                .iter()
                .position(|pane| core::ptr::eq(pane, chosen))
                .and_then(|index| i32::try_from(index).ok())
                .unwrap_or(SLOPDESK_CODE_BRIDGE_MALFORMED)
        },
        Err(Refusal::NoPaneInProject) => SLOPDESK_CODE_BRIDGE_NO_PANE_IN_PROJECT,
        Err(Refusal::NoIdlePane) => SLOPDESK_CODE_BRIDGE_NO_IDLE_PANE,
    }
}

/// The sentence the editor shows for one of the refusal constants. An unknown code answers nothing,
/// which is the honest reading of "this was not a refusal".
///
/// # Safety
/// `out` must be null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub const unsafe extern "C" fn slopdesk_code_bridge_message(
    code: i32,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    let message = match code {
        SLOPDESK_CODE_BRIDGE_NO_PANE_IN_PROJECT => Refusal::NoPaneInProject.message(),
        SLOPDESK_CODE_BRIDGE_NO_IDLE_PANE => Refusal::NoIdlePane.message(),
        _ => "",
    };
    // SAFETY: the caller's obligation, restated above; `deliver` states its own.
    unsafe { deliver(message.as_bytes(), out, cap) }
}

/// The `cd <dir>` line for a pane, with `dir` quoted as one shell word.
///
/// # Safety
/// `directory` must be null or point to `len` initialised bytes live for the call; `out` must be
/// null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_code_bridge_cd_line(
    directory: *const c_uchar,
    len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; `borrow` and `deliver` state their own.
    unsafe {
        let Ok(text) = core::str::from_utf8(borrow(directory, len)) else {
            return 0;
        };
        deliver(
            bridge_router::change_directory_command_line(text).as_bytes(),
            out,
            cap,
        )
    }
}

/// The bytes a command line becomes on the PTY — the text, then the carriage RETURN a real Return
/// key sends.
///
/// # Safety
/// `text` must be null or point to `len` initialised bytes live for the call; `out` must be null or
/// writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_code_bridge_keystrokes(
    text: *const c_uchar,
    len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; `borrow` and `deliver` state their own.
    unsafe {
        let Ok(text) = core::str::from_utf8(borrow(text, len)) else {
            return 0;
        };
        deliver(&bridge_router::keystrokes(text), out, cap)
    }
}

#[cfg(test)]
#[expect(
    unsafe_code,
    clippy::indexing_slicing,
    reason = "calling the boundary IS what these tests are for, and a panic in a test is the report"
)]
mod tests {
    use super::{
        BridgePaneRecord, SLOPDESK_CODE_BRIDGE_MALFORMED, SLOPDESK_CODE_BRIDGE_NO_IDLE_PANE,
        SLOPDESK_CODE_BRIDGE_NO_PANE_IN_PROJECT, slopdesk_code_bridge_cd_line, slopdesk_code_bridge_choose,
        slopdesk_code_bridge_keystrokes, slopdesk_code_bridge_message,
    };

    /// Builds the blob + records the door reads, the way the Swift face does.
    fn encode(panes: &[(&str, Option<&str>, bool, &str)]) -> (Vec<u8>, Vec<BridgePaneRecord>) {
        let mut blob: Vec<u8> = Vec::new();
        let mut records: Vec<BridgePaneRecord> = Vec::new();
        for (pane_id, cwd, has_agent, foreground) in panes {
            let pane_id_offset = blob.len();
            blob.extend_from_slice(pane_id.as_bytes());
            let cwd_offset = blob.len();
            blob.extend_from_slice(cwd.unwrap_or_default().as_bytes());
            let foreground_offset = blob.len();
            blob.extend_from_slice(foreground.as_bytes());
            records.push(BridgePaneRecord {
                pane_id_offset,
                pane_id_len: pane_id.len(),
                cwd_offset,
                cwd_len: cwd.unwrap_or_default().len(),
                has_cwd: cwd.is_some(),
                foreground_offset,
                foreground_len: foreground.len(),
                has_agent: *has_agent,
            });
        }
        (blob, records)
    }

    fn choose(panes: &[(&str, Option<&str>, bool, &str)], root: &str) -> i32 {
        let (blob, records) = encode(panes);
        unsafe {
            slopdesk_code_bridge_choose(
                records.as_ptr(),
                records.len(),
                blob.as_ptr(),
                blob.len(),
                root.as_ptr(),
                root.len(),
                core::ptr::null(),
                0,
                false,
            )
        }
    }

    #[test]
    fn the_index_of_the_chosen_pane_comes_back() {
        let panes = [
            ("a", Some("/work/repo"), false, "vim"),
            ("b", Some("/work/repo/src"), false, "zsh"),
        ];
        assert_eq!(choose(&panes, "/work/repo"), 1);
    }

    #[test]
    fn each_refusal_has_its_own_code_and_its_own_sentence() {
        assert_eq!(
            choose(&[("a", Some("/elsewhere"), false, "zsh")], "/work/repo"),
            SLOPDESK_CODE_BRIDGE_NO_PANE_IN_PROJECT
        );
        assert_eq!(
            choose(&[("a", Some("/work/repo"), true, "zsh")], "/work/repo"),
            SLOPDESK_CODE_BRIDGE_NO_IDLE_PANE
        );
        for code in [
            SLOPDESK_CODE_BRIDGE_NO_PANE_IN_PROJECT,
            SLOPDESK_CODE_BRIDGE_NO_IDLE_PANE,
        ] {
            let mut out = [0_u8; 128];
            let written = unsafe { slopdesk_code_bridge_message(code, out.as_mut_ptr(), out.len()) };
            assert!(written > 0, "a refusal explains itself");
        }
        assert_eq!(
            unsafe { slopdesk_code_bridge_message(0, core::ptr::null_mut(), 0) },
            0,
            "a non-refusal has nothing to say"
        );
    }

    /// A record reaching past the blob is a caller this door does not understand — refuse rather
    /// than read whatever is next in memory.
    #[test]
    fn a_record_pointing_outside_the_blob_is_refused() {
        let (blob, mut records) = encode(&[("a", Some("/work/repo"), false, "zsh")]);
        records[0].pane_id_len = blob.len() + 32;
        let root = "/work/repo";
        let answer = unsafe {
            slopdesk_code_bridge_choose(
                records.as_ptr(),
                records.len(),
                blob.as_ptr(),
                blob.len(),
                root.as_ptr(),
                root.len(),
                core::ptr::null(),
                0,
                false,
            )
        };
        assert_eq!(answer, SLOPDESK_CODE_BRIDGE_MALFORMED);
    }

    #[test]
    fn an_empty_pane_list_is_a_project_with_nothing_open() {
        assert_eq!(choose(&[], "/work/repo"), SLOPDESK_CODE_BRIDGE_NO_PANE_IN_PROJECT);
    }

    #[test]
    fn the_cd_line_quotes_and_enter_is_a_carriage_return() {
        let directory = "/Users/x/My Project";
        let mut out = [0_u8; 64];
        let written = unsafe {
            slopdesk_code_bridge_cd_line(directory.as_ptr(), directory.len(), out.as_mut_ptr(), out.len())
        };
        assert_eq!(&out[..written], b"cd '/Users/x/My Project'");

        let text = "ls";
        let written = unsafe {
            slopdesk_code_bridge_keystrokes(text.as_ptr(), text.len(), out.as_mut_ptr(), out.len())
        };
        assert_eq!(&out[..written], b"ls\r");
    }
}
