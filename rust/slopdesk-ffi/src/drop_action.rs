//! What a drop DOES, once the pasteboard has been classified and a zone is under the pointer.
//!
//! The same two-part answer as the link table — a verb and the one string it acts on — for the same
//! reason: an action with an empty payload is a real answer, so the length cannot double as the
//! verb. The split zones are two verbs rather than a verb plus a side flag, because a C ABI that
//! answers one number is read correctly more often than one that answers a number and a bool.

use core::ffi::c_uchar;

use slopdesk_workspace::drop_action::{self, DropAction, DropZone, Dropped, DroppedKind};

use crate::{borrow, deliver};

/// Top-centre: a new terminal tab rooted at the dropped folder.
pub const SLOPDESK_DROP_ZONE_NEW_TAB: u8 = 0;
/// Centre: paste into the focused terminal.
pub const SLOPDESK_DROP_ZONE_INSERT_PATH: u8 = 1;
/// Lower centre: open the path where it lives.
pub const SLOPDESK_DROP_ZONE_OPEN_IN_PLACE: u8 = 2;
/// Left edge: split leading.
pub const SLOPDESK_DROP_ZONE_SPLIT_LEFT: u8 = 3;
/// Right edge: split trailing.
pub const SLOPDESK_DROP_ZONE_SPLIT_RIGHT: u8 = 4;

/// A directory path.
pub const SLOPDESK_DROP_CONTENT_FOLDER: u8 = 0;
/// A regular file path.
pub const SLOPDESK_DROP_CONTENT_FILE: u8 = 1;
/// A non-file URL.
pub const SLOPDESK_DROP_CONTENT_URL: u8 = 2;
/// A plain-text snippet.
pub const SLOPDESK_DROP_CONTENT_TEXT: u8 = 3;

/// The cell is disabled: this drop would do nothing here.
pub const SLOPDESK_DROP_ACTION_NOTHING: u8 = 0;
/// Paste the payload verbatim into the focused terminal.
pub const SLOPDESK_DROP_ACTION_INJECT_TEXT: u8 = 1;
/// Open a new terminal tab rooted at the payload.
pub const SLOPDESK_DROP_ACTION_NEW_TAB_CD: u8 = 2;
/// Open the payload in place, on the host.
pub const SLOPDESK_DROP_ACTION_HOST_OPEN: u8 = 3;
/// Split the active pane, the new one LEADING, aimed at the payload.
pub const SLOPDESK_DROP_ACTION_SPLIT_LEADING: u8 = 4;
/// The same, the new pane TRAILING.
pub const SLOPDESK_DROP_ACTION_SPLIT_TRAILING: u8 = 5;

/// The zone a `SLOPDESK_DROP_ZONE_*` code names. An unknown one reads as the centre, which pastes —
/// the least destructive cell in the table.
const fn zone_of(code: u8) -> DropZone {
    match code {
        SLOPDESK_DROP_ZONE_NEW_TAB => DropZone::NewTab,
        SLOPDESK_DROP_ZONE_OPEN_IN_PLACE => DropZone::OpenInPlace,
        SLOPDESK_DROP_ZONE_SPLIT_LEFT => DropZone::SplitLeft,
        SLOPDESK_DROP_ZONE_SPLIT_RIGHT => DropZone::SplitRight,
        _ => DropZone::InsertPath,
    }
}

/// The content a `SLOPDESK_DROP_CONTENT_*` code names. An unknown one reads as text, which pastes
/// wherever it lands and can open nothing.
const fn kind_of(code: u8) -> DroppedKind {
    match code {
        SLOPDESK_DROP_CONTENT_FOLDER => DroppedKind::Folder,
        SLOPDESK_DROP_CONTENT_FILE => DroppedKind::File,
        SLOPDESK_DROP_CONTENT_URL => DroppedKind::Url,
        _ => DroppedKind::Text,
    }
}

/// The action as a verb and the payload it acts on.
const fn parts(action: Option<&DropAction>) -> (u8, &str) {
    match action {
        None => (SLOPDESK_DROP_ACTION_NOTHING, ""),
        Some(DropAction::InjectText(text)) => (SLOPDESK_DROP_ACTION_INJECT_TEXT, text.as_str()),
        Some(DropAction::NewTabCd(path)) => (SLOPDESK_DROP_ACTION_NEW_TAB_CD, path.as_str()),
        Some(DropAction::HostOpen(path)) => (SLOPDESK_DROP_ACTION_HOST_OPEN, path.as_str()),
        Some(DropAction::SplitInjectPath { path, leading }) => {
            (
                if *leading {
                    SLOPDESK_DROP_ACTION_SPLIT_LEADING
                } else {
                    SLOPDESK_DROP_ACTION_SPLIT_TRAILING
                },
                path.as_str(),
            )
        },
    }
}

/// What a drop of `content` into `zone` does, as a `SLOPDESK_DROP_ACTION_*` verb plus its payload.
///
/// `needed` takes §4's number for the payload. A payload that does not fit leaves `out` untouched;
/// the VERB is still correct, so a caller that only wants to know whether the cell is live never
/// has to size a buffer at all.
///
/// # Safety
/// `value` must be null or point to `value_len` initialised bytes; `out` null or writable for `cap`
/// bytes; `needed` null or one writable `usize`. All live for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_drop_action(
    zone: u8,
    content_kind: u8,
    value: *const c_uchar,
    value_len: usize,
    out: *mut c_uchar,
    cap: usize,
    needed: *mut usize,
) -> u8 {
    // SAFETY: the caller's obligations, restated above; the helpers state their own.
    unsafe {
        let content = Dropped {
            kind: kind_of(content_kind),
            value: core::str::from_utf8(borrow(value, value_len)).unwrap_or_default(),
        };
        let action = drop_action::resolve(zone_of(zone), content);
        let (verb, payload) = parts(action.as_ref());
        let written = deliver(payload.as_bytes(), out, cap);
        if !needed.is_null() {
            needed.write(written);
        }
        verb
    }
}

#[cfg(test)]
mod tests {
    #![expect(unsafe_code, reason = "calling the door is the only way to test the door")]

    use super::{
        SLOPDESK_DROP_ACTION_INJECT_TEXT, SLOPDESK_DROP_ACTION_NEW_TAB_CD, SLOPDESK_DROP_ACTION_NOTHING,
        SLOPDESK_DROP_ACTION_SPLIT_TRAILING, SLOPDESK_DROP_CONTENT_FOLDER, SLOPDESK_DROP_CONTENT_URL,
        SLOPDESK_DROP_ZONE_INSERT_PATH, SLOPDESK_DROP_ZONE_NEW_TAB, SLOPDESK_DROP_ZONE_SPLIT_RIGHT,
        slopdesk_drop_action,
    };

    fn action(zone: u8, kind: u8, value: &str) -> (u8, String) {
        let bytes = value.as_bytes();
        let mut out = [0_u8; 128];
        let mut needed = 0;
        // SAFETY: two live local buffers, borrowed for the duration of the call.
        let verb = unsafe {
            slopdesk_drop_action(
                zone,
                kind,
                bytes.as_ptr(),
                bytes.len(),
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
    fn a_folder_over_the_new_tab_zone_opens_a_tab_there() {
        assert_eq!(
            action(SLOPDESK_DROP_ZONE_NEW_TAB, SLOPDESK_DROP_CONTENT_FOLDER, "/repo"),
            (SLOPDESK_DROP_ACTION_NEW_TAB_CD, "/repo".to_owned())
        );
    }

    #[test]
    fn a_url_pastes_and_does_nothing_else() {
        assert_eq!(
            action(
                SLOPDESK_DROP_ZONE_INSERT_PATH,
                SLOPDESK_DROP_CONTENT_URL,
                "https://x.dev"
            ),
            (SLOPDESK_DROP_ACTION_INJECT_TEXT, "https://x.dev".to_owned())
        );
        let (verb, payload) = action(
            SLOPDESK_DROP_ZONE_SPLIT_RIGHT,
            SLOPDESK_DROP_CONTENT_URL,
            "https://x.dev",
        );
        assert_eq!(verb, SLOPDESK_DROP_ACTION_NOTHING);
        assert!(payload.is_empty(), "a dead cell carries nothing");
    }

    #[test]
    fn the_split_side_rides_the_verb_rather_than_a_flag() {
        let (verb, payload) = action(
            SLOPDESK_DROP_ZONE_SPLIT_RIGHT,
            SLOPDESK_DROP_CONTENT_FOLDER,
            "/repo",
        );
        assert_eq!(
            (verb, payload.as_str()),
            (SLOPDESK_DROP_ACTION_SPLIT_TRAILING, "/repo")
        );
    }
}
