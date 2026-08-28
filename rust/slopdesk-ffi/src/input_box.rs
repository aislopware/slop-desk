//! The external input surface: which box to offer, and which of the bytes coming back are merely
//! the PTY echoing what the compose box just typed.
//!
//! [`slopdesk_terminal::InputBoxModel`] ties two things together that only mean anything together —
//! the mode tracker (alt screen versus shell prompt) and the hold-and-confirm dedup ring. An
//! alt-screen flip is what switches the box from **A** (a shell command line, where echo is
//! supposed to show) to **B1** (a compose overlay, where it must not), and the same flip is what
//! clears a half-matched echo. Splitting them across the boundary would put that coupling in Swift.
//!
//! ## Why one handle rather than two
//! The dedup ring is reachable from nowhere else. It was `public` in Swift and directly tested, but
//! its only caller was the model that owns it — so exporting it separately would be a second door
//! into one state machine, with the ordering rule (record BEFORE the echo arrives, reset on every
//! mode flip) restated on the outside. The ring crosses as the model's interior.
//!
//! ## Why the rendered bytes are a SLOT
//! [`slopdesk_input_box_ingest`] answers how many bytes survived the filter and parks them;
//! [`slopdesk_input_box_take_rendered`] copies them out. The count cannot be known before the call
//! — the ring may *add* bytes it had been holding on behalf of an earlier chunk — so a caller
//! cannot size a buffer in advance, and re-running the filter to learn the size would consume the
//! chunk twice. Same reason, and same shape, as [`crate::terminal_mode`]'s event slot.

use core::ffi::c_uchar;

use slopdesk_terminal::inputbox::{InputAffordance, InputBoxModel};
use slopdesk_terminal::mode::TerminalMode;

use crate::terminal_mode::{SLOPDESK_TERMINAL_MODE_ALT_SCREEN, SLOPDESK_TERMINAL_MODE_SHELL_PROMPT};
use crate::{borrow, deliver};

/// **A** — a shell command box. Echo flows normally in the surface above.
pub const SLOPDESK_INPUT_AFFORDANCE_SHELL_COMMAND: u32 = 0;
/// **B1** — a compose overlay above a fullscreen TUI. The PTY's echo is suppressed.
pub const SLOPDESK_INPUT_AFFORDANCE_TUI_COMPOSE: u32 = 1;

/// Everything the input surface reads between chunks, in one record.
///
/// One call rather than five getters because they are answers to the same question — "what should
/// the box look like now" — and a caller that read them one at a time could interleave a chunk
/// between two of them and render a mode from before it with an exit code from after.
///
/// The exit code carries a presence flag rather than a sentinel: no command has finished yet is a
/// different fact from one that finished with status 0.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SlopDeskInputBoxState {
    /// One of the `SLOPDESK_TERMINAL_MODE_*` values.
    pub mode: u32,
    /// One of the `SLOPDESK_INPUT_AFFORDANCE_*` values.
    pub affordance: u32,
    /// Whether a shell command is between its OSC 133 `C` and `D` marks.
    pub command_running: bool,
    /// Whether `exit_code` means anything.
    pub has_exit_code: bool,
    /// The most recently finished command's exit code; read only when `has_exit_code`.
    pub exit_code: i64,
}

impl SlopDeskInputBoxState {
    /// The state a fresh model starts in, and the answer to a null handle.
    const FRESH: Self = Self {
        mode: SLOPDESK_TERMINAL_MODE_SHELL_PROMPT,
        affordance: SLOPDESK_INPUT_AFFORDANCE_SHELL_COMMAND,
        command_running: false,
        has_exit_code: false,
        exit_code: 0,
    };

    /// Reads the model's current state out.
    const fn of(model: &InputBoxModel) -> Self {
        let (has_exit_code, exit_code) = match model.last_exit_code() {
            Some(code) => (true, code),
            None => (false, 0),
        };
        Self {
            mode: match model.mode() {
                TerminalMode::ShellPrompt => SLOPDESK_TERMINAL_MODE_SHELL_PROMPT,
                TerminalMode::AltScreen => SLOPDESK_TERMINAL_MODE_ALT_SCREEN,
            },
            affordance: match model.affordance() {
                InputAffordance::ShellCommand => SLOPDESK_INPUT_AFFORDANCE_SHELL_COMMAND,
                InputAffordance::TuiCompose => SLOPDESK_INPUT_AFFORDANCE_TUI_COMPOSE,
            },
            command_running: model.command_running(),
            has_exit_code,
            exit_code,
        }
    }
}

/// The opaque handle: the model, and the one slot its last ingest filled.
///
/// The MARKERS a chunk carried are not parked here. Every one of them has already moved the model
/// — the affordance, the running flag, the exit code — and that folded state is the whole of what a
/// view binds; `TerminalModeTracker` is the one way to ask for the events themselves.
#[derive(Debug, Default)]
pub struct SlopDeskInputBox {
    model: InputBoxModel,
    rendered: Vec<u8>,
}

/// Turns a caller's handle pointer into a reference for the duration of one call.
///
/// # Safety
/// `handle` must be a live pointer from [`slopdesk_input_box_new`] that has not been freed, and no
/// other call on it may overlap this one.
#[expect(
    unsafe_code,
    reason = "reconstituting the handle IS the boundary this module documents"
)]
unsafe fn held<'a>(handle: *mut SlopDeskInputBox) -> Option<&'a mut SlopDeskInputBox> {
    if handle.is_null() {
        return None;
    }
    // SAFETY: non-null and, by the caller's obligation, live and unaliased for this call — the
    // Swift owner is one object per input surface, driven by one main-actor path.
    Some(unsafe { &mut *handle })
}

/// Builds a model at a shell prompt, offering the command box, with empty slots and an empty ring.
///
/// # Safety
/// Nothing is borrowed. The function is `unsafe` only because an exported C entry point is, in
/// edition 2024.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_input_box_new() -> *mut SlopDeskInputBox {
    Box::into_raw(Box::new(SlopDeskInputBox::default()))
}

/// Frees a handle. Null is a no-op; anything else must come from exactly one
/// [`slopdesk_input_box_new`] and be freed exactly once.
///
/// # Safety
/// `handle` must be null, or a live pointer from [`slopdesk_input_box_new`] not yet freed, with no
/// other call on it in flight.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_input_box_free(handle: *mut SlopDeskInputBox) {
    if handle.is_null() {
        return;
    }
    // SAFETY: by the caller's obligation this pointer came from one `new` and is freed once.
    drop(unsafe { Box::from_raw(handle) });
}

/// Returns the model to a fresh session's state — shell prompt, ground parse state, empty ring —
/// and empties both slots.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_input_box_reset(handle: *mut SlopDeskInputBox) {
    // SAFETY: the caller's obligation, discharged by the Swift owner holding one handle.
    if let Some(state) = unsafe { held(handle) } {
        state.model.reset();
        state.rendered.clear();
    }
}

/// Reads the current state. A null handle answers the state a fresh model starts in.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_input_box_state(handle: *mut SlopDeskInputBox) -> SlopDeskInputBoxState {
    // SAFETY: the caller's obligation, as above.
    let Some(state) = (unsafe { held(handle) }) else {
        return SlopDeskInputBoxState::FRESH;
    };
    SlopDeskInputBoxState::of(&state.model)
}

/// Feeds one output chunk: parks the bytes to render and answers how many there are. The slot holds
/// until the next ingest.
///
/// Safe to call with chunks split at any byte boundary — the parser and the ring both carry their
/// partial state across calls.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation and `(bytes, len)` must describe live memory for the
/// whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_input_box_ingest(
    handle: *mut SlopDeskInputBox,
    bytes: *const c_uchar,
    len: usize,
) -> usize {
    // SAFETY: the caller's obligation on the handle, and on `(bytes, len)` discharged by Swift's
    // `withUnsafeBytes`, whose scope is exactly this call.
    let Some(state) = (unsafe { held(handle) }) else {
        return 0;
    };
    // SAFETY: as above — the pair is live for the call or null, which borrows as empty.
    let chunk = unsafe { borrow(bytes, len) };
    state.rendered = state.model.ingest_output(chunk).bytes;
    state.rendered.len()
}

/// Copies the parked render bytes into the caller's buffer.
///
/// Returns the number of bytes the slot holds — the same number the ingest answered — and writes
/// nothing when that exceeds `cap`, following the crate's sizing convention. The slot is NOT
/// cleared: a caller that got its size wrong retries with a bigger buffer rather than losing the
/// chunk.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation and `out` must be null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_input_box_take_rendered(
    handle: *mut SlopDeskInputBox,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, as above.
    let Some(state) = (unsafe { held(handle) }) else {
        return 0;
    };
    // SAFETY: `out` is null or writable for `cap` bytes by the caller's obligation, and the slot
    // is a live Rust vector that cannot overlap it.
    unsafe { deliver(&state.rendered, out, cap) }
}

/// Records bytes the compose box just wrote to the PTY so their echo can be suppressed.
///
/// A no-op outside compose mode, decided INSIDE: at a shell prompt the echo is what the user
/// expects to see, and a caller that had to check the affordance first could check it against a
/// mode the chunk it has not ingested yet already changed.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation and `(bytes, len)` must describe live memory for the
/// whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_input_box_record_compose_sent(
    handle: *mut SlopDeskInputBox,
    bytes: *const c_uchar,
    len: usize,
) {
    // SAFETY: the caller's obligation, as above.
    let Some(state) = (unsafe { held(handle) }) else {
        return;
    };
    // SAFETY: as above — the pair is live for the call or null, which borrows as empty.
    let sent = unsafe { borrow(bytes, len) };
    state.model.record_compose_sent(sent);
}

#[cfg(test)]
#[expect(unsafe_code, reason = "calling the door is the only way to test the door")]
mod tests {
    use super::{
        SLOPDESK_INPUT_AFFORDANCE_SHELL_COMMAND, SLOPDESK_INPUT_AFFORDANCE_TUI_COMPOSE,
        slopdesk_input_box_free, slopdesk_input_box_ingest, slopdesk_input_box_new,
        slopdesk_input_box_record_compose_sent, slopdesk_input_box_reset, slopdesk_input_box_state,
        slopdesk_input_box_take_rendered,
    };
    use crate::terminal_mode::SLOPDESK_TERMINAL_MODE_ALT_SCREEN;

    /// Ingests a chunk and reads the render slot back, the way the Swift face does.
    fn ingest(handle: *mut super::SlopDeskInputBox, chunk: &[u8]) -> Vec<u8> {
        let rendered_len = unsafe { slopdesk_input_box_ingest(handle, chunk.as_ptr(), chunk.len()) };
        let mut rendered = vec![0_u8; rendered_len];
        let written =
            unsafe { slopdesk_input_box_take_rendered(handle, rendered.as_mut_ptr(), rendered.len()) };
        assert_eq!(
            written, rendered_len,
            "the slot answered a size it then would not fill"
        );
        rendered
    }

    #[test]
    fn a_fresh_handle_offers_the_shell_command_box() {
        let handle = unsafe { slopdesk_input_box_new() };
        let state = unsafe { slopdesk_input_box_state(handle) };
        assert_eq!(state.affordance, SLOPDESK_INPUT_AFFORDANCE_SHELL_COMMAND);
        assert!(!state.command_running);
        assert!(!state.has_exit_code);
        unsafe { slopdesk_input_box_free(handle) };
    }

    #[test]
    fn the_alt_screen_flip_switches_the_affordance_and_still_renders() {
        let handle = unsafe { slopdesk_input_box_new() };
        let rendered = ingest(handle, b"\x1b[?1049h");
        assert_eq!(
            rendered, b"\x1b[?1049h",
            "the flip itself still reaches the surface"
        );
        let state = unsafe { slopdesk_input_box_state(handle) };
        assert_eq!(state.affordance, SLOPDESK_INPUT_AFFORDANCE_TUI_COMPOSE);
        assert_eq!(state.mode, SLOPDESK_TERMINAL_MODE_ALT_SCREEN);
        unsafe { slopdesk_input_box_free(handle) };
    }

    #[test]
    fn a_recorded_compose_send_has_its_echo_suppressed_in_tui_mode() {
        let handle = unsafe { slopdesk_input_box_new() };
        let _entered = ingest(handle, b"\x1b[?1049h");
        let sent = b"hi\r";
        unsafe { slopdesk_input_box_record_compose_sent(handle, sent.as_ptr(), sent.len()) };
        let rendered = ingest(handle, b"hi\r\n");
        assert!(
            rendered.is_empty(),
            "the whole echo was confirmed, so nothing renders"
        );
        unsafe { slopdesk_input_box_free(handle) };
    }

    #[test]
    fn a_shell_mode_send_is_never_recorded_so_its_echo_still_shows() {
        let handle = unsafe { slopdesk_input_box_new() };
        let sent = b"ls\r";
        unsafe { slopdesk_input_box_record_compose_sent(handle, sent.as_ptr(), sent.len()) };
        let rendered = ingest(handle, b"ls\r\n");
        assert_eq!(rendered, b"ls\r\n", "echo is what the shell box is FOR");
        unsafe { slopdesk_input_box_free(handle) };
    }

    #[test]
    fn a_command_finish_reaches_the_state_with_its_exit_code() {
        let handle = unsafe { slopdesk_input_box_new() };
        let _rendered = ingest(handle, b"\x1b]133;D;7\x07");
        let state = unsafe { slopdesk_input_box_state(handle) };
        assert!(state.has_exit_code);
        assert_eq!(state.exit_code, 7);
        assert!(!state.command_running);
        unsafe { slopdesk_input_box_free(handle) };
    }

    #[test]
    fn a_reset_returns_the_handle_to_a_fresh_session() {
        let handle = unsafe { slopdesk_input_box_new() };
        let _flipped = ingest(handle, b"\x1b[?1049h\x1b]133;D;3\x07");
        unsafe { slopdesk_input_box_reset(handle) };
        let state = unsafe { slopdesk_input_box_state(handle) };
        assert_eq!(state.affordance, SLOPDESK_INPUT_AFFORDANCE_SHELL_COMMAND);
        assert!(!state.has_exit_code);
        unsafe { slopdesk_input_box_free(handle) };
    }

    #[test]
    fn a_null_handle_answers_rather_than_faults() {
        let state = unsafe { slopdesk_input_box_state(std::ptr::null_mut()) };
        assert_eq!(state.affordance, SLOPDESK_INPUT_AFFORDANCE_SHELL_COMMAND);
        let rendered_len = unsafe { slopdesk_input_box_ingest(std::ptr::null_mut(), b"x".as_ptr(), 1) };
        assert_eq!(rendered_len, 0);
        unsafe { slopdesk_input_box_free(std::ptr::null_mut()) };
    }
}
