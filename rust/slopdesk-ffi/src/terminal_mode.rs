//! The terminal-mode tracker: which screen the host is presenting, and where the command
//! boundaries are.
//!
//! [`slopdesk_terminal::TerminalModeTracker`] parses the host→client OUTPUT stream a byte at a time
//! and answers two things the input surface cannot work without: alt-screen versus shell prompt,
//! and the OSC 133 marks that bracket a command.
//!
//! ## Why a handle
//! Because an escape sequence arrives in pieces. TCP gives no alignment, so `ESC` can land at the
//! end of one chunk and `[` at the start of the next; a parser that could not remember would have
//! to be handed its own partial state back on every call, which is the handle convention written
//! out the long way. [`crate::replay`] documents the obligation: one free per new, and no two calls
//! on one handle overlapping.
//!
//! ## Why the events are a SLOT rather than a return value
//! One chunk can produce several marks — a prompt start, a command start and a finish all inside
//! one `read`. Returning them would mean either allocating across the boundary (which this crate
//! never does) or sizing a buffer for a count the caller cannot know in advance. So
//! [`slopdesk_mode_tracker_consume`] parks the run on the handle and answers how many there are,
//! and the caller reads them out one at a time. The slot holds until the next `consume`.
//!
//! ## What is NOT here
//! The grammar. Every state, every cap, the DCS-body opacity that stops a spoofed `ESC[?1049h`
//! from flipping the mode, and the lossy decode both parameter paths depend on are
//! `slopdesk-terminal`'s, in a crate that forbids `unsafe`.

use core::ffi::c_uchar;

use slopdesk_terminal::mode::{TerminalMode, TerminalModeEvent};
use slopdesk_terminal::tracker::TerminalModeTracker;

use crate::borrow;

/// Main screen — a shell prompt or inline content.
pub const SLOPDESK_TERMINAL_MODE_SHELL_PROMPT: u32 = 0;
/// Alternate screen — a fullscreen TUI.
pub const SLOPDESK_TERMINAL_MODE_ALT_SCREEN: u32 = 1;

/// The terminal entered the alternate screen.
pub const SLOPDESK_MODE_EVENT_ENTERED_ALT_SCREEN: u32 = 0;
/// The terminal left the alternate screen.
pub const SLOPDESK_MODE_EVENT_EXITED_ALT_SCREEN: u32 = 1;
/// OSC 133;A — prompt start.
pub const SLOPDESK_MODE_EVENT_PROMPT_START: u32 = 2;
/// OSC 133;B — command start.
pub const SLOPDESK_MODE_EVENT_COMMAND_START: u32 = 3;
/// OSC 133;C — command output begins.
pub const SLOPDESK_MODE_EVENT_COMMAND_STARTED: u32 = 4;
/// OSC 133;D — command finished, with an optional exit code.
pub const SLOPDESK_MODE_EVENT_COMMAND_FINISHED: u32 = 5;
/// There is no event at that index — the answer to an out-of-range read.
pub const SLOPDESK_MODE_EVENT_NONE: u32 = 6;

/// One marker the tracker produced.
///
/// The exit code carries its own presence flag rather than a sentinel, because a command that
/// finished with status 0 and a `;D` mark that carried no parsable code are different facts, and
/// only one of them means success.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SlopDeskModeEvent {
    /// One of the `SLOPDESK_MODE_EVENT_*` values.
    pub kind: u32,
    /// Whether `exit_code` means anything. Only ever true for a command-finished mark.
    pub has_exit_code: bool,
    /// The decoded exit code; read only when `has_exit_code`.
    pub exit_code: i64,
}

impl SlopDeskModeEvent {
    /// The answer to an index past the end of the slot, or to a null handle.
    pub(crate) const NONE: Self = Self {
        kind: SLOPDESK_MODE_EVENT_NONE,
        has_exit_code: false,
        exit_code: 0,
    };

    /// Flattens one event into the C record.
    pub(crate) const fn pack(event: TerminalModeEvent) -> Self {
        let (kind, has_exit_code, exit_code) = match event {
            TerminalModeEvent::EnteredAltScreen => (SLOPDESK_MODE_EVENT_ENTERED_ALT_SCREEN, false, 0),
            TerminalModeEvent::ExitedAltScreen => (SLOPDESK_MODE_EVENT_EXITED_ALT_SCREEN, false, 0),
            TerminalModeEvent::PromptStart => (SLOPDESK_MODE_EVENT_PROMPT_START, false, 0),
            TerminalModeEvent::CommandStart => (SLOPDESK_MODE_EVENT_COMMAND_START, false, 0),
            TerminalModeEvent::CommandStarted => (SLOPDESK_MODE_EVENT_COMMAND_STARTED, false, 0),
            TerminalModeEvent::CommandFinished { exit_code } => {
                match exit_code {
                    Some(code) => (SLOPDESK_MODE_EVENT_COMMAND_FINISHED, true, code),
                    None => (SLOPDESK_MODE_EVENT_COMMAND_FINISHED, false, 0),
                }
            },
        };
        Self {
            kind,
            has_exit_code,
            exit_code,
        }
    }
}

/// The opaque handle: the parser, and the run of events its last `consume` produced.
#[derive(Debug, Default)]
pub struct SlopDeskModeTracker {
    tracker: TerminalModeTracker,
    events: Vec<TerminalModeEvent>,
}

/// Turns a caller's handle pointer into a reference for the duration of one call.
///
/// # Safety
/// `handle` must be a live pointer from [`slopdesk_mode_tracker_new`] that has not been freed, and
/// no other call on it may overlap this one.
#[expect(
    unsafe_code,
    reason = "reconstituting the handle IS the boundary this module documents"
)]
unsafe fn held<'a>(handle: *mut SlopDeskModeTracker) -> Option<&'a mut SlopDeskModeTracker> {
    if handle.is_null() {
        return None;
    }
    // SAFETY: non-null and, by the caller's obligation, live and unaliased for this call — the
    // Swift owner is one object per pane, driven by one output-ingest path.
    Some(unsafe { &mut *handle })
}

/// Builds a tracker at a shell prompt, in ground state, with an empty event slot.
///
/// # Safety
/// Nothing is borrowed. The function is `unsafe` only because an exported C entry point is, in
/// edition 2024.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_mode_tracker_new() -> *mut SlopDeskModeTracker {
    Box::into_raw(Box::new(SlopDeskModeTracker::default()))
}

/// Frees a handle. Null is a no-op; anything else must come from exactly one
/// [`slopdesk_mode_tracker_new`] and be freed exactly once.
///
/// # Safety
/// `handle` must be null, or a live pointer from [`slopdesk_mode_tracker_new`] not yet freed, with
/// no other call on it in flight.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_mode_tracker_free(handle: *mut SlopDeskModeTracker) {
    if handle.is_null() {
        return;
    }
    // SAFETY: by the caller's obligation this pointer came from one `new` and is freed once.
    drop(unsafe { Box::from_raw(handle) });
}

/// Returns the tracker to its initial state and empties the slot, emitting nothing.
///
/// Called at a SESSION boundary: a reconnect brings a fresh host shell, so a mode carried over from
/// the dead session is a lie.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_mode_tracker_reset(handle: *mut SlopDeskModeTracker) {
    // SAFETY: the caller's obligation, discharged by the Swift owner holding one handle per pane.
    if let Some(state) = unsafe { held(handle) } {
        state.tracker.reset();
        state.events.clear();
    }
}

/// Feeds a chunk of output bytes, parks the events it produced on the handle, and answers how many
/// there are. Read them with [`slopdesk_mode_tracker_event`]; the slot holds until the next call.
///
/// Safe to call with chunks split at any byte boundary: feeding a stream one byte at a time
/// produces the same events, in the same order, as feeding it whole.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation and `(bytes, len)` must describe live memory for the
/// whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_mode_tracker_consume(
    handle: *mut SlopDeskModeTracker,
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
    state.events = state.tracker.consume(chunk);
    state.events.len()
}

/// Reads one parked event. An index past the end — or a null handle — answers
/// [`SLOPDESK_MODE_EVENT_NONE`], so a caller that miscounts gets a defined non-event rather than a
/// fault.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_mode_tracker_event(
    handle: *mut SlopDeskModeTracker,
    index: usize,
) -> SlopDeskModeEvent {
    // SAFETY: the caller's obligation, as above.
    let Some(state) = (unsafe { held(handle) }) else {
        return SlopDeskModeEvent::NONE;
    };
    state
        .events
        .get(index)
        .map_or(SlopDeskModeEvent::NONE, |event| SlopDeskModeEvent::pack(*event))
}

/// The mode the tracker currently believes the host is presenting. A null handle answers the shell
/// prompt, which is the state a fresh tracker starts in.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_mode_tracker_mode(handle: *mut SlopDeskModeTracker) -> u32 {
    // SAFETY: the caller's obligation, as above.
    let Some(state) = (unsafe { held(handle) }) else {
        return SLOPDESK_TERMINAL_MODE_SHELL_PROMPT;
    };
    match state.tracker.mode() {
        TerminalMode::ShellPrompt => SLOPDESK_TERMINAL_MODE_SHELL_PROMPT,
        TerminalMode::AltScreen => SLOPDESK_TERMINAL_MODE_ALT_SCREEN,
    }
}

/// Whether the foreground program has bracketed-paste mode enabled. A passive flag: it emits no
/// event, and the paste-protection pre-check reads it to skip the confirmation sheet.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_mode_tracker_bracketed_paste_active(
    handle: *mut SlopDeskModeTracker,
) -> bool {
    // SAFETY: the caller's obligation, as above.
    unsafe { held(handle) }.is_some_and(|state| state.tracker.bracketed_paste_active())
}

/// Whether the foreground program has DECCKM (application cursor keys) enabled. The iOS key encoder
/// reads it to pick SS3 over CSI arrows.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_mode_tracker_cursor_keys_application(
    handle: *mut SlopDeskModeTracker,
) -> bool {
    // SAFETY: the caller's obligation, as above.
    unsafe { held(handle) }.is_some_and(|state| state.tracker.cursor_keys_application())
}

#[cfg(test)]
#[expect(unsafe_code, reason = "calling the boundary IS what these tests are for")]
#[expect(clippy::indexing_slicing, reason = "a fixed-length assertion IS the test")]
mod tests {
    use super::{
        SLOPDESK_MODE_EVENT_COMMAND_FINISHED, SLOPDESK_MODE_EVENT_ENTERED_ALT_SCREEN,
        SLOPDESK_MODE_EVENT_EXITED_ALT_SCREEN, SLOPDESK_MODE_EVENT_NONE, SLOPDESK_MODE_EVENT_PROMPT_START,
        SLOPDESK_TERMINAL_MODE_ALT_SCREEN, SLOPDESK_TERMINAL_MODE_SHELL_PROMPT, SlopDeskModeTracker,
        slopdesk_mode_tracker_bracketed_paste_active, slopdesk_mode_tracker_consume,
        slopdesk_mode_tracker_event, slopdesk_mode_tracker_free, slopdesk_mode_tracker_mode,
        slopdesk_mode_tracker_new, slopdesk_mode_tracker_reset,
    };

    /// Feeds one chunk through the door and collects the parked events as `(kind, code)` pairs.
    fn feed(handle: *mut SlopDeskModeTracker, bytes: &[u8]) -> Vec<(u32, Option<i64>)> {
        let count = unsafe { slopdesk_mode_tracker_consume(handle, bytes.as_ptr(), bytes.len()) };
        (0..count)
            .map(|index| {
                let event = unsafe { slopdesk_mode_tracker_event(handle, index) };
                (event.kind, event.has_exit_code.then_some(event.exit_code))
            })
            .collect()
    }

    #[test]
    fn a_chunk_can_park_several_marks_and_they_read_out_in_order() {
        let handle = unsafe { slopdesk_mode_tracker_new() };
        let marks = feed(handle, b"\x1B]133;A\x07\x1B]133;C\x07\x1B]133;D;130\x07");
        assert_eq!(marks.len(), 3);
        assert_eq!(marks[0].0, SLOPDESK_MODE_EVENT_PROMPT_START);
        assert_eq!(marks[2], (SLOPDESK_MODE_EVENT_COMMAND_FINISHED, Some(130)));
        // Past the end is a defined non-event, not a fault.
        assert_eq!(
            unsafe { slopdesk_mode_tracker_event(handle, 3) }.kind,
            SLOPDESK_MODE_EVENT_NONE
        );
        unsafe { slopdesk_mode_tracker_free(handle) };
    }

    #[test]
    fn a_finish_with_no_parsable_code_is_not_a_zero() {
        let handle = unsafe { slopdesk_mode_tracker_new() };
        assert_eq!(feed(handle, b"\x1B]133;D\x07"), [(
            SLOPDESK_MODE_EVENT_COMMAND_FINISHED,
            None
        )]);
        assert_eq!(feed(handle, b"\x1B]133;D;0\x07"), [(
            SLOPDESK_MODE_EVENT_COMMAND_FINISHED,
            Some(0)
        )]);
        unsafe { slopdesk_mode_tracker_free(handle) };
    }

    #[test]
    fn a_sequence_split_across_two_calls_still_fires_once() {
        let handle = unsafe { slopdesk_mode_tracker_new() };
        assert!(
            feed(handle, b"\x1B[?10").is_empty(),
            "half a mode set is not a mode set"
        );
        assert_eq!(feed(handle, b"49h"), [(
            SLOPDESK_MODE_EVENT_ENTERED_ALT_SCREEN,
            None
        )]);
        assert_eq!(
            unsafe { slopdesk_mode_tracker_mode(handle) },
            SLOPDESK_TERMINAL_MODE_ALT_SCREEN
        );
        unsafe { slopdesk_mode_tracker_free(handle) };
    }

    #[test]
    fn reset_drops_a_latched_alt_screen_and_the_parked_run() {
        let handle = unsafe { slopdesk_mode_tracker_new() };
        assert_eq!(feed(handle, b"\x1B[?1049h"), [(
            SLOPDESK_MODE_EVENT_ENTERED_ALT_SCREEN,
            None
        )]);
        unsafe { slopdesk_mode_tracker_reset(handle) };
        assert_eq!(
            unsafe { slopdesk_mode_tracker_mode(handle) },
            SLOPDESK_TERMINAL_MODE_SHELL_PROMPT,
            "a fresh shell never emits DECRST 1049, so the latch must not survive"
        );
        assert_eq!(
            unsafe { slopdesk_mode_tracker_event(handle, 0) }.kind,
            SLOPDESK_MODE_EVENT_NONE
        );
        // And the tracker still works afterwards: a real exit now has something to exit from.
        assert_eq!(feed(handle, b"\x1B[?1049h\x1B[?1049l"), [
            (SLOPDESK_MODE_EVENT_ENTERED_ALT_SCREEN, None),
            (SLOPDESK_MODE_EVENT_EXITED_ALT_SCREEN, None)
        ]);
        unsafe { slopdesk_mode_tracker_free(handle) };
    }

    #[test]
    fn the_passive_flags_cross_without_producing_events() {
        let handle = unsafe { slopdesk_mode_tracker_new() };
        assert!(feed(handle, b"\x1B[?2004h").is_empty());
        assert!(unsafe { slopdesk_mode_tracker_bracketed_paste_active(handle) });
        assert!(feed(handle, b"\x1B[?2004l").is_empty());
        assert!(!unsafe { slopdesk_mode_tracker_bracketed_paste_active(handle) });
        unsafe { slopdesk_mode_tracker_free(handle) };
    }

    #[test]
    fn a_null_handle_answers_defined_nothings() {
        assert_eq!(
            unsafe { slopdesk_mode_tracker_consume(core::ptr::null_mut(), b"x".as_ptr(), 1) },
            0
        );
        assert_eq!(
            unsafe { slopdesk_mode_tracker_mode(core::ptr::null_mut()) },
            SLOPDESK_TERMINAL_MODE_SHELL_PROMPT
        );
        assert_eq!(
            unsafe { slopdesk_mode_tracker_event(core::ptr::null_mut(), 0) }.kind,
            SLOPDESK_MODE_EVENT_NONE
        );
        unsafe { slopdesk_mode_tracker_free(core::ptr::null_mut()) };
    }
}
