//! What `slopdesk watch` and `slopdesk watch:claude` decide, and the OSC-9 vocabulary around them.
//!
//! One command's vocabulary, wrapped from the two crates that own its halves: the exit-code state
//! machine is `slopdesk-agent`'s, because every input it reads is an agent fact, and the OSC byte
//! builders are `slopdesk-wire`'s, because the host's sniffer parses those exact sequences. The
//! door puts them side by side, because the CLI asks both in the same loop.
//!
//! ## Everything crosses by value
//! A watch has no accumulator. A decision is a function of one polled observation, a spinner is a
//! constant, a finish banner is a function of the command and its exit code. So every entry point
//! is the pure convention: inputs as `(ptr, len)`, the answer written into a lent buffer.
//!
//! The progress PARSER sits here too, beside the builders whose output it reads back. The wrapper
//! prints `9;4;<state>` and the host's byte reader turns it into a control message, so the two
//! halves are one grammar — and a second copy of it inside the reader is how a spinner starts
//! surviving the command that raised it.
//!
//! ## A status crosses as its byte, the one `agent.rs` already defined
//! The near side's `ClaudeStatus` is already a face over that byte — the rollup and the urgency map
//! both speak it — so a watch reads and writes the same one rather than minting a second encoding
//! of five cases.

use std::ffi::c_uchar;

use slopdesk_agent::watch::{WatchObservation, WatchStep, block_deadline_nanos, decide, is_at_rest};
use slopdesk_wire::osc::{
    self, ProgressState, WATCH_NOTIFICATION_MARKER, finish_bytes, notification_bytes, parse_progress,
    spinner_bytes, watch_finish_message, watch_finish_notification_bytes,
};

use crate::agent::{status_byte, status_from};
use crate::host_state::SlopDeskByteSpan;
use crate::{borrow, deliver, records_of};

/// `seen:true` with a rolled-up status; the status byte is meaningful.
pub const SLOPDESK_WATCH_STATUS: u32 = 0;
/// `seen:true` with NO status token — the pane exists, its agent has not reported yet.
pub const SLOPDESK_WATCH_SEEN_NO_STATUS: u32 = 1;
/// `seen:false` — the id resolves to no pane the running app knows.
pub const SLOPDESK_WATCH_NOT_SEEN: u32 = 2;

/// Not settled yet — sleep and poll again.
pub const SLOPDESK_WATCH_KEEP_POLLING: u32 = 0;
/// Stop polling and exit with the code the call wrote out.
pub const SLOPDESK_WATCH_FINISHED: u32 = 1;

/// Whether a polled status is at rest — a state `watch:claude` returns on.
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
#[unsafe(no_mangle)]
pub const extern "C" fn slopdesk_watch_is_at_rest(status: u8) -> bool {
    is_at_rest(status_from(status))
}

/// Decodes an `agent-status` reply's `{seen, status?}` fields into an observation.
///
/// A null `token` is an ABSENT status token, which is not the same answer as an unknown one: the
/// first keeps polling, the second finishes. The status byte is written whenever the answer is
/// `SLOPDESK_WATCH_STATUS`.
///
/// # Safety
/// The token pair must be live for the call; `status` must be null or writable for one byte.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_watch_observation(
    seen: bool,
    token: *const c_uchar,
    token_len: usize,
    status: *mut u8,
) -> u32 {
    let observed = if token.is_null() {
        WatchObservation::decode(seen, None)
    } else {
        // SAFETY: non-null, and live for the call by the caller's obligation.
        let raw = String::from_utf8_lossy(unsafe { borrow(token, token_len) });
        WatchObservation::decode(seen, Some(raw.as_ref()))
    };
    match observed {
        WatchObservation::Status(polled) => {
            if !status.is_null() {
                // SAFETY: non-null and, by the caller's obligation, writable for one byte.
                unsafe { std::ptr::write(status, status_byte(polled)) };
            }
            SLOPDESK_WATCH_STATUS
        },
        WatchObservation::SeenNoStatus => SLOPDESK_WATCH_SEEN_NO_STATUS,
        WatchObservation::NotSeen => SLOPDESK_WATCH_NOT_SEEN,
    }
}

/// The block deadline in monotonic nanoseconds, or none.
///
/// A non-positive `block_timeout_ms` — which is what an absent `--block-timeout` arrives as — is
/// UNBOUNDED, never an instant timeout. Answers whether there is a deadline at all.
///
/// # Safety
/// `deadline` must be null or writable for one `uint64_t`.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub const unsafe extern "C" fn slopdesk_watch_block_deadline_nanos(
    start_nanos: u64,
    block_timeout_ms: i64,
    deadline: *mut u64,
) -> bool {
    let Some(nanos) = block_deadline_nanos(start_nanos, Some(block_timeout_ms)) else {
        return false;
    };
    if !deadline.is_null() {
        // SAFETY: non-null and, by the caller's obligation, writable for one value.
        unsafe { std::ptr::write(deadline, nanos) };
    }
    true
}

/// Decides the next step from one poll, writing the exit code when the answer is finished.
///
/// # Safety
/// `exit_code` must be null or writable for one `int32_t`.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub const unsafe extern "C" fn slopdesk_watch_decide(
    observation: u32,
    status: u8,
    has_ever_been_seen: bool,
    deadline_exceeded: bool,
    exit_code: *mut i32,
) -> u32 {
    let observed = match observation {
        SLOPDESK_WATCH_SEEN_NO_STATUS => WatchObservation::SeenNoStatus,
        SLOPDESK_WATCH_NOT_SEEN => WatchObservation::NotSeen,
        _ => WatchObservation::Status(status_from(status)),
    };
    match decide(observed, has_ever_been_seen, deadline_exceeded) {
        WatchStep::Finished(exit) => {
            if !exit_code.is_null() {
                // SAFETY: non-null and, by the caller's obligation, writable for one value.
                unsafe { std::ptr::write(exit_code, exit.code()) };
            }
            SLOPDESK_WATCH_FINISHED
        },
        WatchStep::KeepPolling => SLOPDESK_WATCH_KEEP_POLLING,
    }
}

/// The progress state a finished command's exit code calls for, as its wire discriminant.
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
#[unsafe(no_mangle)]
pub const extern "C" fn slopdesk_watch_exit_progress_state(exit_code: i32) -> u8 {
    ProgressState::for_exit_code(exit_code).to_wire()
}

/// `ESC ] 9 ; 4 ; <state> BEL` for one canonical progress state.
///
/// An unknown discriminant answers nothing rather than emitting a state the host would drop.
///
/// # Safety
/// `out` must be null, or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_watch_progress_bytes(state: u8, out: *mut c_uchar, cap: usize) -> usize {
    let Some(state) = ProgressState::from_wire(state) else {
        return 0;
    };
    // SAFETY: the caller's obligation on the output buffer.
    unsafe { deliver(&osc::progress_bytes(state), out, cap) }
}

/// Parses the OSC-9 remainder AFTER the leading `9;` into a validated `(state, percent)`.
///
/// Validate-then-drop on hostile input: a missing state, an unknown discriminant, a non-integer
/// percent or an extra field all answer false, and the host emits nothing. An out-of-range percent
/// is merely CLAMPED — an implausible number is not the same as a malformed one.
///
/// # Safety
/// The body pair must be live for the call; both output pointers must be null or writable for one
/// byte.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_osc_parse_progress(
    body: *const c_uchar,
    body_len: usize,
    state: *mut u8,
    percent: *mut u8,
) -> bool {
    // SAFETY: the caller's obligation on the input pair.
    let text = String::from_utf8_lossy(unsafe { borrow(body, body_len) });
    let Some(update) = parse_progress(text.as_ref()) else {
        return false;
    };
    if !state.is_null() {
        // SAFETY: non-null and, by the caller's obligation, writable for one byte.
        unsafe { std::ptr::write(state, update.state.to_wire()) };
    }
    if !percent.is_null() {
        // SAFETY: non-null and, by the caller's obligation, writable for one byte.
        unsafe { std::ptr::write(percent, update.percent) };
    }
    true
}

/// The indeterminate spinner a wrapped command's start emits.
///
/// # Safety
/// `out` must be null, or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_watch_spinner_bytes(out: *mut c_uchar, cap: usize) -> usize {
    // SAFETY: the caller's obligation on the output buffer.
    unsafe { deliver(&spinner_bytes(), out, cap) }
}

/// The finish badge for an exit code: clear on `0`, error otherwise.
///
/// # Safety
/// `out` must be null, or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_watch_finish_bytes(exit_code: i32, out: *mut c_uchar, cap: usize) -> usize {
    // SAFETY: the caller's obligation on the output buffer.
    unsafe { deliver(&finish_bytes(exit_code), out, cap) }
}

/// `ESC ] 9 ; <message> BEL` — the free-text desktop-notification form. An empty message answers
/// nothing, so the wrapper never writes a content-less escape.
///
/// # Safety
/// The message pair must be live for the call; `out` must be null, or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_osc_notification_bytes(
    message: *const c_uchar,
    message_len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation on the input pair.
    let text = String::from_utf8_lossy(unsafe { borrow(message, message_len) });
    // SAFETY: the caller's obligation on the output buffer.
    unsafe { deliver(&notification_bytes(text.as_ref()), out, cap) }
}

/// The watch-FINISH banner, carrying the private marker that routes it to the dedicated toggle.
///
/// # Safety
/// The message pair must be live for the call; `out` must be null, or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_watch_finish_notification_bytes(
    message: *const c_uchar,
    message_len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation on the input pair.
    let text = String::from_utf8_lossy(unsafe { borrow(message, message_len) });
    // SAFETY: the caller's obligation on the output buffer.
    unsafe { deliver(&watch_finish_notification_bytes(text.as_ref()), out, cap) }
}

/// The private sentinel a watch-finish banner carries in its title field.
///
/// # Safety
/// `out` must be null, or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub const unsafe extern "C" fn slopdesk_watch_notification_marker(out: *mut c_uchar, cap: usize) -> usize {
    // SAFETY: the caller's obligation on the output buffer.
    unsafe { deliver(WATCH_NOTIFICATION_MARKER.as_bytes(), out, cap) }
}

/// The human-readable "Notify on Watch Finish" message for a finished command.
///
/// The command crosses as spans into one arena, the way an argv already sits in memory on the near
/// side.
///
/// # Safety
/// The span array and the arena must be live for the call; `out` must be null, or writable for
/// `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_watch_finish_message(
    command: *const SlopDeskByteSpan,
    count: usize,
    arena: *const c_uchar,
    arena_len: usize,
    exit_code: i32,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation on the two input pairs.
    let (spans, pool) = unsafe { (records_of(command, count), borrow(arena, arena_len)) };
    let tokens: Vec<String> = spans
        .iter()
        .map(|span| {
            let start = span.offset as usize;
            let end = start.saturating_add(span.length as usize);
            String::from_utf8_lossy(pool.get(start..end).unwrap_or_default()).into_owned()
        })
        .collect();
    // SAFETY: the caller's obligation on the output buffer.
    unsafe { deliver(watch_finish_message(&tokens, exit_code).as_bytes(), out, cap) }
}

#[cfg(test)]
#[expect(
    unsafe_code,
    reason = "calling the C ABI the way Swift does is the thing under test"
)]
mod tests {
    use super::{
        SLOPDESK_WATCH_FINISHED, SLOPDESK_WATCH_KEEP_POLLING, SLOPDESK_WATCH_NOT_SEEN,
        SLOPDESK_WATCH_SEEN_NO_STATUS, SLOPDESK_WATCH_STATUS, slopdesk_osc_notification_bytes,
        slopdesk_osc_parse_progress, slopdesk_watch_block_deadline_nanos, slopdesk_watch_decide,
        slopdesk_watch_finish_bytes, slopdesk_watch_finish_message, slopdesk_watch_finish_notification_bytes,
        slopdesk_watch_is_at_rest, slopdesk_watch_notification_marker, slopdesk_watch_observation,
        slopdesk_watch_spinner_bytes,
    };
    use crate::host_state::SlopDeskByteSpan;

    /// The status bytes `agent.rs` defines, in its order.
    const NONE: u8 = 0;
    const IDLE: u8 = 1;
    const WORKING: u8 = 2;
    const DONE: u8 = 3;
    const NEEDS_PERMISSION: u8 = 4;

    /// One lent-buffer answer, the way the Swift face asks for it.
    fn answer(ask: impl Fn(*mut u8, usize) -> usize) -> Vec<u8> {
        let needed = ask(std::ptr::null_mut(), 0);
        let mut bytes = vec![0_u8; needed];
        let written = ask(bytes.as_mut_ptr(), bytes.len());
        assert_eq!(written, needed);
        bytes
    }

    #[test]
    fn at_rest_is_exactly_idle_done_and_none() {
        assert!(slopdesk_watch_is_at_rest(IDLE));
        assert!(slopdesk_watch_is_at_rest(DONE));
        assert!(slopdesk_watch_is_at_rest(NONE));
        assert!(!slopdesk_watch_is_at_rest(WORKING));
        // Blocked on a human is not idle, however long it stays there.
        assert!(!slopdesk_watch_is_at_rest(NEEDS_PERMISSION));
    }

    #[test]
    fn an_absent_token_is_the_startup_window_and_an_unknown_one_is_settled() {
        let mut status = 255_u8;
        let observed = unsafe { slopdesk_watch_observation(true, std::ptr::null(), 0, &raw mut status) };
        assert_eq!(observed, SLOPDESK_WATCH_SEEN_NO_STATUS);
        let token = "from-a-newer-host";
        let observed =
            unsafe { slopdesk_watch_observation(true, token.as_ptr(), token.len(), &raw mut status) };
        assert_eq!(observed, SLOPDESK_WATCH_STATUS);
        assert_eq!(status, NONE);
        // An id that resolves to no pane ignores whatever token came with it.
        let token = "working";
        let observed =
            unsafe { slopdesk_watch_observation(false, token.as_ptr(), token.len(), &raw mut status) };
        assert_eq!(observed, SLOPDESK_WATCH_NOT_SEEN);
    }

    #[test]
    fn a_settled_verdict_wins_over_an_expired_deadline() {
        let mut code = -1_i32;
        let step = unsafe { slopdesk_watch_decide(SLOPDESK_WATCH_STATUS, IDLE, true, true, &raw mut code) };
        assert_eq!(step, SLOPDESK_WATCH_FINISHED);
        assert_eq!(code, 0);
        // Still working, deadline elapsed: the timeout code.
        let step =
            unsafe { slopdesk_watch_decide(SLOPDESK_WATCH_STATUS, WORKING, true, true, &raw mut code) };
        assert_eq!(step, SLOPDESK_WATCH_FINISHED);
        assert_eq!(code, 9);
        // Still working, deadline alive: keep polling, and no code is written.
        let step =
            unsafe { slopdesk_watch_decide(SLOPDESK_WATCH_STATUS, WORKING, true, false, &raw mut code) };
        assert_eq!(step, SLOPDESK_WATCH_KEEP_POLLING);
        // Unknown on the first poll is never-seen; unknown after a sighting is closed.
        let step =
            unsafe { slopdesk_watch_decide(SLOPDESK_WATCH_NOT_SEEN, NONE, false, false, &raw mut code) };
        assert_eq!(step, SLOPDESK_WATCH_FINISHED);
        assert_eq!(code, 4);
        let step =
            unsafe { slopdesk_watch_decide(SLOPDESK_WATCH_NOT_SEEN, NONE, true, false, &raw mut code) };
        assert_eq!(step, SLOPDESK_WATCH_FINISHED);
        assert_eq!(code, 0);
        // The startup window keeps polling too, rather than reading as never-seen.
        let step = unsafe {
            slopdesk_watch_decide(SLOPDESK_WATCH_SEEN_NO_STATUS, NONE, false, false, &raw mut code)
        };
        assert_eq!(step, SLOPDESK_WATCH_KEEP_POLLING);
    }

    #[test]
    fn an_absent_block_timeout_is_unbounded_not_an_instant_timeout() {
        let mut deadline = 7_u64;
        assert!(!unsafe { slopdesk_watch_block_deadline_nanos(100, 0, &raw mut deadline) });
        assert!(!unsafe { slopdesk_watch_block_deadline_nanos(100, -5, &raw mut deadline) });
        assert_eq!(deadline, 7);
        assert!(unsafe { slopdesk_watch_block_deadline_nanos(100, 2, &raw mut deadline) });
        assert_eq!(deadline, 100 + 2_000_000);
    }

    #[test]
    fn a_progress_body_parses_back_into_the_state_the_wrapper_printed() {
        let read = |body: &str| {
            let (mut state, mut percent) = (255_u8, 255_u8);
            let known = unsafe {
                slopdesk_osc_parse_progress(body.as_ptr(), body.len(), &raw mut state, &raw mut percent)
            };
            known.then_some((state, percent))
        };
        assert_eq!(read("4;3"), Some((3, 0)));
        assert_eq!(read("4;1;40"), Some((1, 40)));
        // An implausible percent is clamped; a malformed shape is dropped whole.
        assert_eq!(read("4;1;900"), Some((1, 100)));
        assert_eq!(read("4;"), None);
        assert_eq!(read("4;5"), None);
        assert_eq!(read("4;1;40;extra"), None);
    }

    #[test]
    fn the_printed_bytes_are_the_sequences_the_host_sniffer_parses() {
        assert_eq!(
            answer(|out, cap| unsafe { slopdesk_watch_spinner_bytes(out, cap) }),
            b"\x1B]9;4;3\x07"
        );
        assert_eq!(
            answer(|out, cap| unsafe { slopdesk_watch_finish_bytes(0, out, cap) }),
            b"\x1B]9;4;0\x07"
        );
        assert_eq!(
            answer(|out, cap| unsafe { slopdesk_watch_finish_bytes(3, out, cap) }),
            b"\x1B]9;4;2\x07"
        );
        let message = "hello";
        assert_eq!(
            answer(|out, cap| unsafe {
                slopdesk_osc_notification_bytes(message.as_ptr(), message.len(), out, cap)
            }),
            b"\x1B]9;hello\x07"
        );
        // An empty message writes no escape at all.
        assert_eq!(
            unsafe { slopdesk_osc_notification_bytes(std::ptr::null(), 0, std::ptr::null_mut(), 0) },
            0
        );
    }

    #[test]
    fn the_finish_banner_carries_the_marker_in_its_title_field() {
        let marker = answer(|out, cap| unsafe { slopdesk_watch_notification_marker(out, cap) });
        let message = "watch: make finished";
        let banner = answer(|out, cap| unsafe {
            slopdesk_watch_finish_notification_bytes(message.as_ptr(), message.len(), out, cap)
        });
        let mut expected = b"\x1B]777;notify;".to_vec();
        expected.extend_from_slice(&marker);
        expected.extend_from_slice(b";");
        expected.extend_from_slice(message.as_bytes());
        expected.push(0x07);
        assert_eq!(banner, expected);
        // The marker carries no `;`, so the OSC-777 field split keeps it one whole title.
        assert!(!marker.contains(&b';'));
    }

    #[test]
    fn the_finish_message_names_the_command_and_appends_a_failing_code() {
        let arena = b"makebuild";
        let spans = [SlopDeskByteSpan { offset: 0, length: 4 }, SlopDeskByteSpan {
            offset: 4,
            length: 5,
        }];
        let said = |exit: i32| {
            String::from_utf8_lossy(&answer(|out, cap| unsafe {
                slopdesk_watch_finish_message(
                    spans.as_ptr(),
                    spans.len(),
                    arena.as_ptr(),
                    arena.len(),
                    exit,
                    out,
                    cap,
                )
            }))
            .into_owned()
        };
        assert_eq!(said(0), "watch: make build finished");
        assert_eq!(said(2), "watch: make build failed (exit 2)");
        // An empty command still reads as a sentence.
        let empty = answer(|out, cap| unsafe {
            slopdesk_watch_finish_message(std::ptr::null(), 0, std::ptr::null(), 0, 0, out, cap)
        });
        assert_eq!(String::from_utf8_lossy(&empty), "watch: command finished");
    }
}
