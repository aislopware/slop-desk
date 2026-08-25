//! What a live pane may do next, in C.
//!
//! The rules are `slopdesk_workspace::pane_session`; what is here is the marshalling.
//!
//! ## Nothing that is alive crosses
//!
//! A connection, an inspector client, a video window and the `Task` that drives any of them are the
//! near side's, and none of them appears here. Every door takes the FACTS a decision reads — three
//! or four booleans, a status byte, a count — and answers what to do about them: a step, an effect,
//! a route. The near side does the doing, which is the half that is not a rule.
//!
//! ## The status byte is the wire's own
//!
//! `docs/20` type 27 carries an urgency byte, not an enum, and the fold takes and answers that same
//! byte — so the five-case status is spelled once, in `slopdesk-agent`, and the client's
//! forward-tolerance for a future value is that crate's rather than a second guess here.

use core::ffi::c_uchar;

use slopdesk_workspace::pane_session::{self, InspectorFacts, InspectorGate, VideoFacts};
use slopdesk_workspace::status_pill::Pill;

use crate::borrow;

// ---------------------------------------------------------------------------------------------- //
// The agent signal fold
// ---------------------------------------------------------------------------------------------- //

/// What one type-27 frame leaves behind.
///
/// `changed` is the guard on the WRITE rather than on the record: `urgency` is always the status
/// the pane holds afterwards, so a caller that ignores the flag still reads a true status — it just
/// re-renders for a frame that said nothing.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SlopDeskWsStatusFold {
    /// The status the pane holds after the fold, as its urgency byte.
    pub urgency: c_uchar,
    /// What the fold does to the inspector's second channel: `0` nothing · `1` open · `2` close.
    pub effect: c_uchar,
    /// Whether the status actually moved.
    pub changed: bool,
}

/// The fold of one type-27 `claudeStatus` frame into a pane's display state.
///
/// `detectable` is the pane's build-time fact — only a terminal has a PTY an agent could live in.
/// An unknown or future `wire_state` degrades to no-agent rather than trapping.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_ws_session_status_fold(
    detectable: bool,
    current: c_uchar,
    wire_state: c_uchar,
) -> SlopDeskWsStatusFold {
    let fold = pane_session::fold_status(detectable, current, wire_state);
    SlopDeskWsStatusFold {
        urgency: fold.urgency,
        effect: fold.effect.code(),
        changed: fold.changed,
    }
}

/// Whether a type-26 frame NAMES a foreground process.
///
/// Bytes that are not UTF-8 name nothing: the near side's string cannot produce them, and a hint
/// that cannot be displayed is the same answer as no hint at all.
///
/// # Safety
/// `(name, len)` must be readable for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and the pointer is the caller's"
)]
pub unsafe extern "C" fn slopdesk_ws_session_names_foreground(name: *const c_uchar, len: usize) -> bool {
    // SAFETY: the caller's obligation, restated above; the borrow dies with this call.
    let bytes = unsafe { borrow(name, len) };
    core::str::from_utf8(bytes).is_ok_and(pane_session::names_foreground)
}

// ---------------------------------------------------------------------------------------------- //
// The inspector's second channel
// ---------------------------------------------------------------------------------------------- //

/// The three facts every inspector-channel gate reads.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SlopDeskWsInspectorFacts {
    /// Whether a claude is detected in this pane right now.
    pub agent_present: bool,
    /// Whether the pane has an inspector model at all.
    pub has_model: bool,
    /// Whether a live client is already subscribed.
    pub has_client: bool,
}

/// Whether gate `gate` — `0` subscribe · `1` resume · `2` reconnect — opens on these facts.
///
/// A gate code this build does not know refuses, which is the safe direction: an unrecognised
/// caller opens no socket.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_ws_session_inspector_gate(
    gate: c_uchar,
    facts: SlopDeskWsInspectorFacts,
) -> bool {
    let Some(gate) = InspectorGate::from_code(gate) else {
        return false;
    };
    gate.allows(InspectorFacts {
        agent_present: facts.agent_present,
        has_model: facts.has_model,
        has_client: facts.has_client,
    })
}

// ---------------------------------------------------------------------------------------------- //
// Video activation
// ---------------------------------------------------------------------------------------------- //

/// Everything a video activation reads about the pane it is acting on.
///
/// Four bools on purpose: four independent facts about two objects, where packing them into a
/// bitfield would spell four bit positions on both sides of the boundary. (`struct_excessive_bools`
/// does not fire on a `repr(C)` record — the C layout IS the argument list.)
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SlopDeskWsVideoFacts {
    /// Whether the pane's kind streams video at all.
    pub is_video: bool,
    /// Whether the pane holds a window model.
    pub has_model: bool,
    /// Whether that model already carries an active descriptor.
    pub is_open: bool,
    /// Whether the model is configured enough to be opened.
    pub can_open: bool,
}

/// What one activation does: `0` nothing · `1` open then mirror · `2` mirror only · `3` close.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_ws_session_video_step(facts: SlopDeskWsVideoFacts, active: bool) -> c_uchar {
    pane_session::activation_step(
        VideoFacts {
            is_video: facts.is_video,
            has_model: facts.has_model,
            is_open: facts.is_open,
            can_open: facts.can_open,
        },
        active,
    )
    .code()
}

/// Whether the foreground fan-out re-opens this pane's stream.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_ws_session_resume_reopens_video(is_video: bool, was_active: bool) -> bool {
    pane_session::resume_reopens_video(is_video, was_active)
}

/// Whether a pane closing for good must close a video window on the way out.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_ws_session_teardown_closes_video(
    is_active: bool,
    has_descriptor: bool,
) -> bool {
    pane_session::teardown_closes_video(is_active, has_descriptor)
}

/// Which model a video pane's spec mounts: `0` one host window, `1` a whole display.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_ws_session_video_mount(
    has_video_spec: bool,
    has_display_id: bool,
    window_id: u32,
) -> c_uchar {
    pane_session::video_mount(has_video_spec, has_display_id, window_id).code()
}

// ---------------------------------------------------------------------------------------------- //
// The scrollback capture tail
// ---------------------------------------------------------------------------------------------- //

/// Where a capture of the last `count` lines of `available` STARTS, or `-1` when it captures
/// nothing.
///
/// Signed, because a start offset is never negative — the sentinel is outside the answer's range by
/// construction, which is what `docs/55` §4b asks of one. A count so large it will not fit the
/// signed answer refuses for the same reason it would have started at the top: there is nothing
/// above the top.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_ws_session_capture_start(count: i64, available: usize) -> isize {
    pane_session::capture_tail_start(count, available)
        .and_then(|start| isize::try_from(start).ok())
        .unwrap_or(-1)
}

// ---------------------------------------------------------------------------------------------- //
// The status chip's dismiss
// ---------------------------------------------------------------------------------------------- //

/// Which actuator chip `pill` dismisses through: `0` the pane's read-only lock, `1` the tab's
/// synchronized input, `2` nothing.
///
/// An index no chip has answers `2`, and that is honest rather than a refusal dressed as an answer:
/// a chip nobody can name carries no `×` either.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_ws_session_dismiss_route(pill: c_uchar) -> c_uchar {
    let Some(pill) = Pill::from_index(pill) else {
        return pane_session::DismissRoute::Nothing.code();
    };
    pane_session::dismiss_route(pill).code()
}

#[cfg(test)]
mod tests {
    #![expect(unsafe_code, reason = "calling the door is the only way to test the door")]

    use slopdesk_workspace::pane_session::{DismissRoute, InspectorEffect, VideoStep, dismiss_route};
    use slopdesk_workspace::status_pill::Pill;

    use super::{
        SlopDeskWsInspectorFacts, SlopDeskWsVideoFacts, slopdesk_ws_session_capture_start,
        slopdesk_ws_session_dismiss_route, slopdesk_ws_session_inspector_gate,
        slopdesk_ws_session_names_foreground, slopdesk_ws_session_resume_reopens_video,
        slopdesk_ws_session_status_fold, slopdesk_ws_session_teardown_closes_video,
        slopdesk_ws_session_video_mount, slopdesk_ws_session_video_step,
    };

    #[test]
    fn the_open_edge_crosses_with_its_status() {
        let fold = slopdesk_ws_session_status_fold(true, 0, 3);
        assert_eq!(fold.urgency, 3);
        assert!(fold.changed);
        assert_eq!(fold.effect, InspectorEffect::Open.code());
    }

    #[test]
    fn the_close_edge_crosses_with_its_status() {
        let fold = slopdesk_ws_session_status_fold(true, 4, 0);
        assert_eq!(fold.urgency, 0);
        assert!(fold.changed);
        assert_eq!(fold.effect, InspectorEffect::Close.code());
    }

    /// A repeat and an undetectable pane cross as the same shape: no change, no effect, and the
    /// status the pane already held.
    #[test]
    fn a_frame_that_says_nothing_crosses_as_no_change() {
        let repeat = slopdesk_ws_session_status_fold(true, 3, 3);
        assert!(!repeat.changed);
        assert_eq!(repeat.effect, InspectorEffect::Nothing.code());
        assert_eq!(repeat.urgency, 3);

        let deaf = slopdesk_ws_session_status_fold(false, 0, 4);
        assert!(!deaf.changed);
        assert_eq!(deaf.urgency, 0);
    }

    #[test]
    fn an_unknown_state_byte_crosses_as_no_agent() {
        let fold = slopdesk_ws_session_status_fold(true, 3, u8::MAX);
        assert_eq!(fold.urgency, 0);
        assert_eq!(fold.effect, InspectorEffect::Close.code());
    }

    #[test]
    fn a_foreground_name_crosses_as_a_yes_or_no() {
        let named = b"claude";
        // SAFETY: the literal is `'static`.
        assert!(unsafe { slopdesk_ws_session_names_foreground(named.as_ptr(), named.len()) });
        // SAFETY: a zero-length read of a dangling-but-aligned pointer.
        let empty =
            unsafe { slopdesk_ws_session_names_foreground(core::ptr::NonNull::dangling().as_ptr(), 0) };
        assert!(!empty);
        let raw = [0xFF_u8, 0xFE];
        // SAFETY: the array is a live local for the call.
        let invalid = unsafe { slopdesk_ws_session_names_foreground(raw.as_ptr(), raw.len()) };
        assert!(!invalid, "bytes that cannot be displayed name nothing");
    }

    /// A gate this build does not know opens nothing, which is the safe direction across a
    /// boundary: an unrecognised caller gets no socket.
    #[test]
    fn every_gate_crosses_and_an_unknown_one_refuses() {
        let live = SlopDeskWsInspectorFacts {
            agent_present: true,
            has_model: true,
            has_client: false,
        };
        assert!(slopdesk_ws_session_inspector_gate(0, live));
        assert!(slopdesk_ws_session_inspector_gate(1, live));
        assert!(slopdesk_ws_session_inspector_gate(2, live));
        let stale = SlopDeskWsInspectorFacts {
            agent_present: true,
            has_model: true,
            has_client: true,
        };
        assert!(!slopdesk_ws_session_inspector_gate(0, stale));
        assert!(slopdesk_ws_session_inspector_gate(2, stale));
        assert!(!slopdesk_ws_session_inspector_gate(9, live));
        assert!(!slopdesk_ws_session_inspector_gate(
            0,
            SlopDeskWsInspectorFacts::default()
        ));
    }

    #[test]
    fn every_video_step_crosses_as_its_code() {
        let configured = SlopDeskWsVideoFacts {
            is_video: true,
            has_model: true,
            is_open: false,
            can_open: true,
        };
        assert_eq!(
            slopdesk_ws_session_video_step(configured, true),
            VideoStep::Open.code()
        );
        assert_eq!(
            slopdesk_ws_session_video_step(configured, false),
            VideoStep::Close.code()
        );
        let open = SlopDeskWsVideoFacts {
            is_open: true,
            ..configured
        };
        assert_eq!(
            slopdesk_ws_session_video_step(open, true),
            VideoStep::Mirror.code()
        );
        assert_eq!(
            slopdesk_ws_session_video_step(SlopDeskWsVideoFacts::default(), true),
            VideoStep::Ignore.code(),
        );
    }

    #[test]
    fn the_two_video_flags_cross_verbatim() {
        assert!(slopdesk_ws_session_resume_reopens_video(true, true));
        assert!(!slopdesk_ws_session_resume_reopens_video(false, true));
        assert!(slopdesk_ws_session_teardown_closes_video(false, true));
        assert!(!slopdesk_ws_session_teardown_closes_video(false, false));
    }

    #[test]
    fn a_window_spec_crosses_as_the_window_mount() {
        assert_eq!(slopdesk_ws_session_video_mount(true, false, 42), 0);
        assert_eq!(slopdesk_ws_session_video_mount(true, false, 0), 1);
        assert_eq!(slopdesk_ws_session_video_mount(true, true, 42), 1);
        assert_eq!(slopdesk_ws_session_video_mount(false, false, 42), 1);
    }

    #[test]
    fn the_capture_start_crosses_as_an_offset_or_minus_one() {
        assert_eq!(slopdesk_ws_session_capture_start(10, 100), 90);
        assert_eq!(slopdesk_ws_session_capture_start(1000, 10), 0);
        assert_eq!(slopdesk_ws_session_capture_start(0, 100), -1);
        assert_eq!(slopdesk_ws_session_capture_start(-5, 100), -1);
    }

    /// Every chip's route crosses, and an index no chip has reads as the chip with no `×`.
    #[test]
    fn every_dismiss_route_crosses_verbatim() {
        for pill in Pill::ALL {
            assert_eq!(
                slopdesk_ws_session_dismiss_route(pill.index()),
                dismiss_route(pill).code(),
                "{pill:?}",
            );
        }
        assert_eq!(slopdesk_ws_session_dismiss_route(9), DismissRoute::Nothing.code());
    }
}
