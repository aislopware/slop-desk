//! What a gesture does to a detected link: `slopdesk_terminal::link_action` reached from Swift.
//!
//! The answer has two halves — WHAT to do and WITH WHAT — so [`slopdesk_link_action`] returns the
//! verb as a discriminant and writes the payload through the usual `(out, cap)` pair, with `needed`
//! carrying §4's retry number. A verb whose payload is empty is a real answer (`NOTHING` carries
//! none), which is why the length cannot double as the verb.
//!
//! The link itself crosses as the three fields the table reads rather than as a whole
//! `SlopDeskDetectedLink`: the row and columns a detector reports are geometry the policy never
//! looks at, and a struct carrying them would imply it did.

use core::ffi::c_uchar;

use slopdesk_terminal::link::DetectedLinkKind;
use slopdesk_terminal::link_action::{
    self, CmdClick, CmdShiftClick, LinkAction, LinkConfig, LinkTarget, LinkTrigger,
};

use crate::link_detect::{
    SLOPDESK_LINK_KIND_FILE_URL, SLOPDESK_LINK_KIND_PATH_LINE_COL, SLOPDESK_LINK_KIND_RELATIVE_PATH,
    SLOPDESK_LINK_KIND_TILDE_PATH, SLOPDESK_LINK_KIND_URL,
};
use crate::{borrow, deliver};

/// A bare left-click.
pub const SLOPDESK_LINK_TRIGGER_PLAIN_CLICK: u8 = 0;
/// `⌘`click.
pub const SLOPDESK_LINK_TRIGGER_COMMAND_CLICK: u8 = 1;
/// `⌘⇧`click.
pub const SLOPDESK_LINK_TRIGGER_COMMAND_SHIFT_CLICK: u8 = 2;
/// An explicit open — the menu item, hint-to-open, the jump row's `↩`.
pub const SLOPDESK_LINK_TRIGGER_OPEN: u8 = 3;
/// The menu's copy.
pub const SLOPDESK_LINK_TRIGGER_COPY_PATH: u8 = 4;
/// The menu's reveal.
pub const SLOPDESK_LINK_TRIGGER_REVEAL_IN_FINDER: u8 = 5;
/// The menu's change-directory.
pub const SLOPDESK_LINK_TRIGGER_CHANGE_DIRECTORY: u8 = 6;

/// `link-cmd-click = open`.
pub const SLOPDESK_LINK_CMD_CLICK_OPEN: u8 = 0;
/// `link-cmd-click = copy`.
pub const SLOPDESK_LINK_CMD_CLICK_COPY: u8 = 1;
/// `link-cmd-click = nothing`.
pub const SLOPDESK_LINK_CMD_CLICK_NOTHING: u8 = 2;

/// `link-cmd-shift-click = reveal-finder`.
pub const SLOPDESK_LINK_CMD_SHIFT_CLICK_REVEAL_FINDER: u8 = 0;
/// `link-cmd-shift-click = open-system-default`.
pub const SLOPDESK_LINK_CMD_SHIFT_CLICK_OPEN_SYSTEM_DEFAULT: u8 = 1;

/// Nothing happens; no payload.
pub const SLOPDESK_LINK_ACTION_NOTHING: u8 = 0;
/// Write the payload to the CLIENT pasteboard.
pub const SLOPDESK_LINK_ACTION_COPY_PATH_CLIENT: u8 = 1;
/// Type the payload's `cd` line into the pane's PTY.
pub const SLOPDESK_LINK_ACTION_CHANGE_DIRECTORY_PTY: u8 = 2;
/// Ask the HOST to open the payload in the embedded workbench.
pub const SLOPDESK_LINK_ACTION_OPEN_CODE_HOST: u8 = 3;
/// Ask the HOST to open the payload with its default handler.
pub const SLOPDESK_LINK_ACTION_OPEN_HOST: u8 = 4;
/// Ask the HOST to reveal the payload in Finder.
pub const SLOPDESK_LINK_ACTION_REVEAL_HOST: u8 = 5;
/// Open the payload as a URL on the CLIENT.
pub const SLOPDESK_LINK_ACTION_OPEN_URL_CLIENT: u8 = 6;

/// The trigger a byte names. Anything unknown is the bare click, which does nothing — the only safe
/// reading of a gesture this build does not have.
const fn trigger_of(code: u8) -> LinkTrigger {
    match code {
        SLOPDESK_LINK_TRIGGER_COMMAND_CLICK => LinkTrigger::CommandClick,
        SLOPDESK_LINK_TRIGGER_COMMAND_SHIFT_CLICK => LinkTrigger::CommandShiftClick,
        SLOPDESK_LINK_TRIGGER_OPEN => LinkTrigger::Open,
        SLOPDESK_LINK_TRIGGER_COPY_PATH => LinkTrigger::CopyPath,
        SLOPDESK_LINK_TRIGGER_REVEAL_IN_FINDER => LinkTrigger::RevealInFinder,
        SLOPDESK_LINK_TRIGGER_CHANGE_DIRECTORY => LinkTrigger::ChangeDirectory,
        _ => LinkTrigger::PlainClick,
    }
}

/// The config a pair of bytes names, each defaulting the way the setting does.
const fn config_of(cmd_click: u8, cmd_shift_click: u8) -> LinkConfig {
    LinkConfig {
        cmd_click: match cmd_click {
            SLOPDESK_LINK_CMD_CLICK_COPY => CmdClick::Copy,
            SLOPDESK_LINK_CMD_CLICK_NOTHING => CmdClick::Nothing,
            _ => CmdClick::Open,
        },
        cmd_shift_click: match cmd_shift_click {
            SLOPDESK_LINK_CMD_SHIFT_CLICK_OPEN_SYSTEM_DEFAULT => CmdShiftClick::OpenSystemDefault,
            _ => CmdShiftClick::RevealFinder,
        },
    }
}

/// The link kind a `SLOPDESK_LINK_KIND_*` code names, in the same encoding the detector reports.
///
/// An unknown code reads as an absolute path: every path kind resolves through the same arms, so
/// the fallback can only be wrong about a URL — and a URL that a build does not know is not one.
const fn kind_of(code: u32) -> DetectedLinkKind {
    match code {
        SLOPDESK_LINK_KIND_TILDE_PATH => DetectedLinkKind::TildePath,
        SLOPDESK_LINK_KIND_RELATIVE_PATH => DetectedLinkKind::RelativePath,
        SLOPDESK_LINK_KIND_PATH_LINE_COL => DetectedLinkKind::PathLineCol,
        SLOPDESK_LINK_KIND_URL => DetectedLinkKind::Url,
        SLOPDESK_LINK_KIND_FILE_URL => DetectedLinkKind::FileUrl,
        _ => DetectedLinkKind::AbsolutePath,
    }
}

/// The verb and payload of an action.
const fn parts(action: &LinkAction) -> (u8, &str) {
    match action {
        LinkAction::Nothing => (SLOPDESK_LINK_ACTION_NOTHING, ""),
        LinkAction::CopyPathClient(text) => (SLOPDESK_LINK_ACTION_COPY_PATH_CLIENT, text.as_str()),
        LinkAction::ChangeDirectoryPty(text) => (SLOPDESK_LINK_ACTION_CHANGE_DIRECTORY_PTY, text.as_str()),
        LinkAction::OpenCodeHost(text) => (SLOPDESK_LINK_ACTION_OPEN_CODE_HOST, text.as_str()),
        LinkAction::OpenHost(text) => (SLOPDESK_LINK_ACTION_OPEN_HOST, text.as_str()),
        LinkAction::RevealHost(text) => (SLOPDESK_LINK_ACTION_REVEAL_HOST, text.as_str()),
        LinkAction::OpenUrlClient(text) => (SLOPDESK_LINK_ACTION_OPEN_URL_CLIENT, text.as_str()),
    }
}

/// What `trigger` does to the link, as a `SLOPDESK_LINK_ACTION_*` verb plus its payload.
///
/// `needed` takes §4's number for the payload, so a caller sizes its buffer without asking the verb
/// twice. A payload that does not fit leaves `out` untouched; the VERB is still correct.
///
/// # Safety
/// `raw` must be null or point to `raw_len` initialised bytes; `resolved` to `resolved_len` when
/// `resolved_present`; `out` null or writable for `cap` bytes; `needed` null or one writable
/// `usize`. All live for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_link_action(
    trigger: u8,
    cmd_click: u8,
    cmd_shift_click: u8,
    kind: u32,
    raw: *const c_uchar,
    raw_len: usize,
    resolved: *const c_uchar,
    resolved_len: usize,
    resolved_present: bool,
    out: *mut c_uchar,
    cap: usize,
    needed: *mut usize,
) -> u8 {
    // SAFETY: the caller's obligations, restated above; the helpers state their own.
    unsafe {
        let target = LinkTarget {
            kind: kind_of(kind),
            raw: core::str::from_utf8(borrow(raw, raw_len)).unwrap_or_default(),
            resolved_absolute: resolved_present
                .then(|| core::str::from_utf8(borrow(resolved, resolved_len)).ok())
                .flatten(),
        };
        let action = link_action::action(trigger_of(trigger), target, config_of(cmd_click, cmd_shift_click));
        let (verb, payload) = parts(&action);
        let written = deliver(payload.as_bytes(), out, cap);
        if !needed.is_null() {
            needed.write(written);
        }
        verb
    }
}

/// The target an embedded-editor open carries: the resolved path with the match's `:line[:col]` put
/// back. `0` is the empty answer, which only an empty link can produce.
///
/// # Safety
/// As [`slopdesk_link_action`], without the `needed` pointer.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_link_code_open_target(
    raw: *const c_uchar,
    raw_len: usize,
    resolved: *const c_uchar,
    resolved_len: usize,
    resolved_present: bool,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; the helpers state their own.
    unsafe {
        let target = LinkTarget {
            // The kind does not reach this answer — only a PATH is ever opened in the workbench.
            kind: DetectedLinkKind::AbsolutePath,
            raw: core::str::from_utf8(borrow(raw, raw_len)).unwrap_or_default(),
            resolved_absolute: resolved_present
                .then(|| core::str::from_utf8(borrow(resolved, resolved_len)).ok())
                .flatten(),
        };
        deliver(target.code_open_target().as_bytes(), out, cap)
    }
}

/// The trailing `:line[:col]` of a match, leading colon included. `0` is "there is none".
///
/// # Safety
/// `text` must be null or point to `len` initialised bytes; `out` null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_link_line_col_suffix(
    text: *const c_uchar,
    len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; the helpers state their own.
    unsafe {
        let raw = core::str::from_utf8(borrow(text, len)).unwrap_or_default();
        deliver(link_action::line_col_suffix(raw).as_bytes(), out, cap)
    }
}

/// The POSIX parent of a path, as a fact about the string.
///
/// # Safety
/// As [`slopdesk_link_line_col_suffix`].
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_link_posix_parent(
    text: *const c_uchar,
    len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; the helpers state their own.
    unsafe {
        let raw = core::str::from_utf8(borrow(text, len)).unwrap_or_default();
        deliver(link_action::posix_parent(raw).as_bytes(), out, cap)
    }
}

/// The verbatim shell line that points a PTY at a path, or at its parent when the path is a file.
///
/// # Safety
/// As [`slopdesk_link_line_col_suffix`].
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_link_cd_command_line(
    text: *const c_uchar,
    len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; the helpers state their own.
    unsafe {
        let raw = core::str::from_utf8(borrow(text, len)).unwrap_or_default();
        deliver(
            link_action::change_directory_command_line(raw).as_bytes(),
            out,
            cap,
        )
    }
}

#[cfg(test)]
#[expect(unsafe_code, reason = "calling the door is the only way to test the door")]
mod tests {
    use super::*;
    use crate::link_detect::SLOPDESK_LINK_KIND_ABSOLUTE_PATH;

    /// Calls the door the way Swift does and reads both halves back.
    fn ask(
        trigger: u8,
        cmd_click: u8,
        cmd_shift: u8,
        kind: u32,
        raw: &str,
        resolved: Option<&str>,
    ) -> (u8, String) {
        let mut out = [0u8; 256];
        let mut needed = 0usize;
        let (pointer, length, present) = resolved.map_or((core::ptr::null(), 0, false), |text| {
            (text.as_ptr(), text.len(), true)
        });
        // SAFETY: every pointer is to a live local for the duration of the call.
        let verb = unsafe {
            slopdesk_link_action(
                trigger,
                cmd_click,
                cmd_shift,
                kind,
                raw.as_ptr(),
                raw.len(),
                pointer,
                length,
                present,
                out.as_mut_ptr(),
                out.len(),
                &raw mut needed,
            )
        };
        (
            verb,
            String::from_utf8_lossy(out.get(..needed).unwrap_or_default()).into_owned(),
        )
    }

    #[test]
    fn the_verb_and_the_payload_cross_together() {
        assert_eq!(
            ask(
                SLOPDESK_LINK_TRIGGER_COMMAND_CLICK,
                SLOPDESK_LINK_CMD_CLICK_OPEN,
                SLOPDESK_LINK_CMD_SHIFT_CLICK_REVEAL_FINDER,
                SLOPDESK_LINK_KIND_PATH_LINE_COL,
                "src/main.rs:12",
                Some("/repo/src/main.rs"),
            ),
            (
                SLOPDESK_LINK_ACTION_OPEN_CODE_HOST,
                "/repo/src/main.rs:12".to_owned()
            ),
        );
        assert_eq!(
            ask(
                SLOPDESK_LINK_TRIGGER_COMMAND_CLICK,
                SLOPDESK_LINK_CMD_CLICK_OPEN,
                SLOPDESK_LINK_CMD_SHIFT_CLICK_REVEAL_FINDER,
                SLOPDESK_LINK_KIND_URL,
                "https://example.com",
                None,
            ),
            (
                SLOPDESK_LINK_ACTION_OPEN_URL_CLIENT,
                "https://example.com".to_owned()
            ),
        );
    }

    #[test]
    fn a_verb_with_no_payload_is_not_a_missing_answer() {
        let (verb, payload) = ask(
            SLOPDESK_LINK_TRIGGER_PLAIN_CLICK,
            SLOPDESK_LINK_CMD_CLICK_OPEN,
            SLOPDESK_LINK_CMD_SHIFT_CLICK_REVEAL_FINDER,
            SLOPDESK_LINK_KIND_ABSOLUTE_PATH,
            "/a/b",
            Some("/a/b"),
        );
        assert_eq!(verb, SLOPDESK_LINK_ACTION_NOTHING);
        assert!(payload.is_empty());
    }

    #[test]
    fn an_unknown_trigger_is_the_bare_click_rather_than_a_guess() {
        let (verb, _) = ask(
            200,
            SLOPDESK_LINK_CMD_CLICK_OPEN,
            SLOPDESK_LINK_CMD_SHIFT_CLICK_REVEAL_FINDER,
            SLOPDESK_LINK_KIND_ABSOLUTE_PATH,
            "/a/b",
            Some("/a/b"),
        );
        assert_eq!(verb, SLOPDESK_LINK_ACTION_NOTHING);
    }
}
