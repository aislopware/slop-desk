//! A config action NAME, as the binding id it rebinds —
//! `Sources/SlopDeskWorkspaceCore/Workspace/Domain/WorkspaceActionConfigNames.swift`.
//!
//! The rules are [`slopdesk_workspace::keybind`]; what is here is the marshalling. It sits beside
//! [`crate::keybind`] rather than inside it because the two answer different halves of one config
//! line: that door parses the line's SHAPE (`slopdesk-terminal`'s grammar), this one says which
//! binding the action it found actually fires (`slopdesk-workspace`'s registry). Two crates, two
//! doors, and the near side calls them in that order.
//!
//! ## Why the argument has no presence flag
//!
//! Optional strings normally cross with a flag, because absent and empty are different answers
//! (docs/55 §4b). They are not different here: the only name that reads its argument is `goto_tab`,
//! and `goto_tab` with no argument and `goto_tab:` both name no binding — the grammar refuses the
//! second spelling outright, so it cannot even reach this door. Adding the flag would name a
//! distinction nothing downstream can act on, which is the same call the hint scanner's action
//! templates make one section over.

use core::ffi::c_uchar;

use slopdesk_workspace::keybind;

use crate::{borrow, deliver};

/// The binding id a config action name rebinds, or nothing when it names no binding.
///
/// `0` is admissible as the refusal because every id this vocabulary can answer is a non-empty
/// name, so an empty delivery is outside the answer's range by construction rather than colliding
/// with a real one — the same ground `slopdesk_panel_simulator_key_code` stands on.
///
/// A zero-length or null argument reads as NO argument. That is not a lost distinction: see the
/// module docs.
///
/// # Safety
/// `name` and `arg` must each be null or point to that many initialised bytes live for the call;
/// `out` must be null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and three of the buffers are the caller's"
)]
pub unsafe extern "C" fn slopdesk_ws_binding_id_for_config_name(
    name: *const c_uchar,
    name_len: usize,
    arg: *const c_uchar,
    arg_len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; `borrow` and `deliver` state their own.
    unsafe {
        let Ok(action) = core::str::from_utf8(borrow(name, name_len)) else {
            return 0;
        };
        let argument = core::str::from_utf8(borrow(arg, arg_len))
            .ok()
            .filter(|text| !text.is_empty());
        let Some(id) = keybind::binding_id_for_config_name(action, argument) else {
            return 0;
        };
        deliver(id.as_bytes(), out, cap)
    }
}

#[cfg(test)]
#[expect(unsafe_code, reason = "calling the boundary IS what these tests are for")]
mod tests {
    use super::slopdesk_ws_binding_id_for_config_name;

    fn resolve(name: &str, arg: Option<&str>) -> Option<String> {
        let mut buffer = [0_u8; 32];
        let (arg_ptr, arg_len) = arg.map_or((core::ptr::null(), 0), |text| (text.as_ptr(), text.len()));
        // SAFETY: every pair is a live local, and an absent argument crosses as a null with no
        // length.
        let needed = unsafe {
            slopdesk_ws_binding_id_for_config_name(
                name.as_ptr(),
                name.len(),
                arg_ptr,
                arg_len,
                buffer.as_mut_ptr(),
                buffer.len(),
            )
        };
        if needed == 0 {
            return None;
        }
        buffer
            .get(..needed)
            .map(|bytes| String::from_utf8_lossy(bytes).into_owned())
    }

    #[test]
    fn a_bare_name_and_a_parameterised_one_both_cross() {
        assert_eq!(resolve("new_tab", None).as_deref(), Some("tab.new"));
        assert_eq!(resolve("goto_tab", Some("4")).as_deref(), Some("pane.select.4"));
    }

    #[test]
    fn a_name_that_rebinds_nothing_answers_nothing() {
        assert_eq!(resolve("frobnicate", None), None);
        assert_eq!(resolve("goto_tab", Some("10")), None);
        assert_eq!(resolve("copy_to_clipboard", None), None);
    }

    #[test]
    fn an_empty_argument_reads_as_no_argument() {
        assert_eq!(
            resolve("goto_tab", Some("")),
            None,
            "the grammar refuses `goto_tab:`, so this never arrives — and if it did it is not a tab"
        );
        assert_eq!(
            resolve("new_tab", Some("")).as_deref(),
            Some("tab.new"),
            "a bare action does not read its argument either way"
        );
    }

    #[test]
    fn an_overflow_reports_the_size_it_needs_and_writes_nothing() {
        let name = "split_right";
        let mut tiny = [0xAA_u8; 2];
        // SAFETY: the buffer is a live local, and the argument crosses as an empty pair.
        let needed = unsafe {
            slopdesk_ws_binding_id_for_config_name(
                name.as_ptr(),
                name.len(),
                core::ptr::null(),
                0,
                tiny.as_mut_ptr(),
                tiny.len(),
            )
        };
        assert_eq!(needed, "pane.splitRight".len());
        assert_eq!(tiny, [0xAA; 2], "an overflow leaves the caller's buffer alone");
    }
}
