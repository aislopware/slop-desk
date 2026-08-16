//! The HOST video session's lifecycle — `Sources/SlopDeskVideoHost/VideoSessionLogic.swift`.
//!
//! The client's half of this negotiation already crosses here (`client_session`); this is the other
//! end of the same handshake, and it crosses the same way, for the same reasons.
//!
//! ## The machine crosses by value
//! Nine scalars: the state, the negotiated size, the target and its kind, the stream-id counter and
//! the last one minted, the range flag, the last applied resize epoch. The near side reads most of
//! them, its owner is an actor field that Swift copies on every `mutating` call, and there is
//! nothing to own — `docs/55` §4b, the same reading that made the client machine a value.
//!
//! ## A transition commits only when its answer fits
//! A transition MUTATES, so the measure-then-fill shape would apply it twice. Each door steps a
//! COPY, measures, and writes the machine back only once every lent buffer is big enough. A caller
//! that lent too little gets the shape it should have lent and a machine that has not moved.
//!
//! ## The resolvers are ANSWERS, not callbacks
//! The law asks three questions of the actor — what capture size this window settles on, what a
//! resize clamps to, what a display target sizes to — and exactly ONE of them can be asked per
//! message, decided by the message's own variant. So they cross as pre-resolved answers, each a
//! size plus a presence flag, where ABSENT is the REJECT the closure spelled as `None`. The actor
//! already decodes the datagram before this call, so it has the requested id and viewport a
//! resolver would have been handed.
//!
//! ## A control message crosses as its bytes
//! The only thing the actor does with a `SendControl` is put it on the control channel, so the
//! encoded datagram is what crosses — the acknowledgement is minted by the same crate that parses
//! the hello it answers.

use slopdesk_video::geometry::{VideoRect, VideoSize};
use slopdesk_video::session_state::{
    SessionEffect, VideoSessionState, VideoSessionStateMachine, bitrate_ceiling_from_wire,
    clamp_capture_size, effective_fps, fps_cap_from_wire, is_stale_epoch,
};
use slopdesk_video::video_control::VideoControlMessage;

use crate::borrow;
use crate::host_state::SlopDeskByteSpan;
use crate::video_policy::{SlopDeskVideoRect, SlopDeskVideoSize};

/// Sockets not yet bound; nothing flowing.
pub const SLOPDESK_VIDEO_SESSION_IDLE: u32 = 0;
/// Sockets bound, awaiting the client hello.
pub const SLOPDESK_VIDEO_SESSION_LISTENING: u32 = 1;
/// The hello was accepted; capture and encode are running.
pub const SLOPDESK_VIDEO_SESSION_STREAMING: u32 = 2;
/// A local stop ran. Terminal.
pub const SLOPDESK_VIDEO_SESSION_STOPPED: u32 = 3;

/// Send the effect's `control` bytes to the client on the control channel.
pub const SLOPDESK_SESSION_EFFECT_SEND_CONTROL: u32 = 0;
/// Bring up capture and encode for `window_id` at the effect's size.
pub const SLOPDESK_SESSION_EFFECT_START_CAPTURE: u32 = 1;
/// Tear down capture and encode.
pub const SLOPDESK_SESSION_EFFECT_STOP_CAPTURE: u32 = 2;
/// Re-size the LIVE capture and encode, answering `epoch`.
pub const SLOPDESK_SESSION_EFFECT_RESIZE_CAPTURE: u32 = 3;
/// Apply the client's live stream overrides — `first` is the fps cap, `second` the bitrate ceiling.
pub const SLOPDESK_SESSION_EFFECT_APPLY_STREAM_SETTINGS: u32 = 4;
/// Apply the client's audio wish, in `enabled`.
pub const SLOPDESK_SESSION_EFFECT_APPLY_AUDIO_CONTROL: u32 = 5;
/// Apply the client's privacy-blank wish, in `enabled`. Display targets only.
pub const SLOPDESK_SESSION_EFFECT_APPLY_PRIVACY_MODE: u32 = 6;

/// The host session machine, whole.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct SlopDeskVideoSessionMachine {
    /// One of the `SLOPDESK_VIDEO_SESSION_*` states.
    pub state: u32,
    /// The window — or, for a full-desktop session, the display — being remoted.
    pub window_id: u32,
    /// The next stream id to mint, monotonic so a reconnecting client can tell a fresh session.
    pub next_stream_id: u32,
    /// The id handed out on the most recent accept, echoed by a duplicate re-acknowledgement.
    pub last_stream_id: u32,
    /// The highest resize epoch already applied, so a reordered or duplicated request is dropped.
    pub last_resize_epoch: u32,
    /// The negotiated capture width.
    pub capture_width: u16,
    /// The negotiated capture height.
    pub capture_height: u16,
    /// Whether the accepted session targets a whole DISPLAY rather than a window.
    pub is_display_target: bool,
    /// Whether this host encodes FULL-RANGE luma, stamped into every accepted acknowledgement.
    pub full_range: bool,
}

/// One resolver's ANSWER: the size the actor settled on, or absent for a REJECT.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct SlopDeskResolvedSize {
    /// The resolved width.
    pub width: u16,
    /// The resolved height.
    pub height: u16,
    /// Whether the actor resolved one at all. False is the rejection the law reads as `None`.
    pub resolved: bool,
}

/// One effect the actor must perform.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct SlopDeskVideoSessionEffect {
    /// One of the `SLOPDESK_SESSION_EFFECT_*` kinds.
    pub kind: u32,
    /// The encoded control datagram, as a run of the answer arena.
    pub control: SlopDeskByteSpan,
    /// The window or display to capture.
    pub window_id: u32,
    /// The resize epoch this answers.
    pub epoch: u32,
    /// The fps cap, on a stream-settings effect.
    pub first: u32,
    /// The bitrate ceiling, on a stream-settings effect.
    pub second: u32,
    /// The capture width.
    pub width: u16,
    /// The capture height.
    pub height: u16,
    /// The audio or privacy wish.
    pub enabled: bool,
}

/// What one transition's answer needs, so the caller knows what to lend.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct SlopDeskVideoSessionShape {
    /// How many effects the transition produced.
    pub effects: usize,
    /// How many arena bytes their control datagrams need.
    pub arena: usize,
}

impl SlopDeskVideoSessionShape {
    /// Whether both lent buffers are big enough for this answer.
    const fn fits(self, effects: usize, arena: usize) -> bool {
        self.effects <= effects && self.arena <= arena
    }
}

/// An idle machine for a host that encodes at the given luma range.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_video_session_new(
    next_stream_id: u32,
    full_range: bool,
) -> SlopDeskVideoSessionMachine {
    SlopDeskVideoSessionMachine {
        state: SLOPDESK_VIDEO_SESSION_IDLE,
        window_id: 0,
        next_stream_id,
        last_stream_id: 0,
        last_resize_epoch: 0,
        capture_width: 0,
        capture_height: 0,
        is_display_target: false,
        full_range,
    }
}

/// Whether media — video, geometry, cursor — may flow right now.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_video_session_media_flowing(machine: SlopDeskVideoSessionMachine) -> bool {
    machine.state == SLOPDESK_VIDEO_SESSION_STREAMING
}

/// Starts the session: bind the sockets and wait for the client hello. Produces no effects, so it
/// needs no lent buffers.
///
/// # Safety
/// `machine` must point to one live record for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_video_session_start(machine: *mut SlopDeskVideoSessionMachine) {
    // SAFETY: the caller's obligation, discharged on the near side by an in-out parameter.
    unsafe {
        step(
            machine,
            VideoSessionStateMachine::start,
            core::ptr::null_mut(),
            0,
            core::ptr::null_mut(),
            0,
        );
    }
}

/// Stops the session LOCALLY, which is terminal — unlike a client goodbye, a later hello finds a
/// stopped machine.
///
/// # Safety
/// `machine` must point to one live record; the two lent buffers must be null or writable for the
/// capacities given.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_video_session_stop(
    machine: *mut SlopDeskVideoSessionMachine,
    effects: *mut SlopDeskVideoSessionEffect,
    effects_cap: usize,
    arena: *mut u8,
    arena_cap: usize,
) -> SlopDeskVideoSessionShape {
    // SAFETY: the caller's obligation on all three, discharged by one scoped access per buffer.
    unsafe {
        step(
            machine,
            VideoSessionStateMachine::stop,
            effects,
            effects_cap,
            arena,
            arena_cap,
        )
    }
}

/// Feeds one control datagram, in its wire form, and answers the effects to perform.
///
/// A datagram that does not decode is a no-op, the way a malformed one already is at the actor.
/// Each resolver answer is consumed only by the arm that would have called its closure, so passing
/// an unresolved one for the other two is exactly what a window session's always-refusing display
/// resolver did.
///
/// # Safety
/// `machine` must point to one live record; `control` must be null or point to `control_len`
/// readable bytes; the two lent buffers must be null or writable for the capacities given.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_video_session_control(
    machine: *mut SlopDeskVideoSessionMachine,
    control: *const u8,
    control_len: usize,
    window_bounds_cg: SlopDeskVideoRect,
    capture: SlopDeskResolvedSize,
    resize: SlopDeskResolvedSize,
    display: SlopDeskResolvedSize,
    effects: *mut SlopDeskVideoSessionEffect,
    effects_cap: usize,
    arena: *mut u8,
    arena_cap: usize,
) -> SlopDeskVideoSessionShape {
    // SAFETY: the caller's obligation on the control span.
    let Ok(message) = VideoControlMessage::decode(unsafe { borrow(control, control_len) }) else {
        return SlopDeskVideoSessionShape::default();
    };
    let bounds = VideoRect::xywh(
        window_bounds_cg.x,
        window_bounds_cg.y,
        window_bounds_cg.width,
        window_bounds_cg.height,
    );
    // SAFETY: the caller's obligation on the machine and both lent buffers.
    unsafe {
        step(
            machine,
            |law| {
                law.handle_control(
                    &message,
                    bounds,
                    |_, _| answer(capture),
                    |_, _| answer(resize),
                    |_, _| answer(display),
                )
            },
            effects,
            effects_cap,
            arena,
            arena_cap,
        )
    }
}

/// Clamps a desired size into the host's policy bounds per axis, rounding to a non-zero integer.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_video_session_clamp_capture(
    desired: SlopDeskVideoSize,
    min: SlopDeskVideoSize,
    max: SlopDeskVideoSize,
) -> SlopDeskResolvedSize {
    let (width, height) =
        clamp_capture_size(size_of_record(desired), size_of_record(min), size_of_record(max));
    SlopDeskResolvedSize {
        width,
        height,
        resolved: true,
    }
}

/// Whether a resize epoch is STALE against the last one applied — a duplicate or an out-of-order
/// older request, which must be ignored so a datagram reorder cannot un-settle the coalesced size.
///
/// The machine already applies this rule inside `_control`; the door exists because the actor asks
/// the same question of a resize it is about to actuate, and one rule answers both.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_video_session_stale_epoch(epoch: u32, last_applied: u32) -> bool {
    is_stale_epoch(epoch, last_applied)
}

/// The applied frame-rate cap for a wire byte, where zero is AUTO.
///
/// An absent override crosses as a presence flag rather than a sentinel: zero is the wire's own
/// spelling of AUTO, and reusing it as the answer would make a clamped-to-zero cap unreadable.
///
/// # Safety
/// `cap` must be null or point to one writable `i64` for the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_video_fps_cap_from_wire(raw: u8, cap: *mut i64) -> bool {
    // SAFETY: the caller's obligation on `cap` is exactly what `write_override` needs.
    unsafe { write_override(fps_cap_from_wire(raw), cap) }
}

/// The applied bitrate ceiling for a wire field, where zero is AUTO. The frame-rate cap's twin.
///
/// # Safety
/// `ceiling` must be null or point to one writable `i64` for the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_video_bitrate_ceiling_from_wire(raw: u32, ceiling: *mut i64) -> bool {
    // SAFETY: the caller's obligation on `ceiling` is exactly what `write_override` needs.
    unsafe { write_override(bitrate_ceiling_from_wire(raw), ceiling) }
}

/// The encode cadence in force: the governed rate, capped by the user's override when there is one.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_video_effective_fps(governed: i64, has_cap: bool, cap: i64) -> i64 {
    effective_fps(governed, has_cap.then_some(cap))
}

/// Writes an optional override out and answers whether there was one.
///
/// # Safety
/// `out` must be null or point to one writable `i64` for the whole call.
#[expect(
    unsafe_code,
    reason = "the caller lends one writable scalar for the duration of the call"
)]
const unsafe fn write_override(value: Option<i64>, out: *mut i64) -> bool {
    let Some(value) = value else { return false };
    if !out.is_null() {
        // SAFETY: the caller's obligation is a writable `i64`, and the null case returned above.
        unsafe { out.write(value) };
    }
    true
}

/// One resolver answer as the law reads it.
const fn answer(resolved: SlopDeskResolvedSize) -> Option<(u16, u16)> {
    if resolved.resolved {
        Some((resolved.width, resolved.height))
    } else {
        None
    }
}

/// A size record as the law holds it.
const fn size_of_record(record: SlopDeskVideoSize) -> VideoSize {
    VideoSize::new(record.width, record.height)
}

/// The machine as the law holds it.
const fn law_of(record: SlopDeskVideoSessionMachine) -> VideoSessionStateMachine {
    let mut law = VideoSessionStateMachine::new(record.next_stream_id, record.full_range);
    law.restore(
        match record.state {
            SLOPDESK_VIDEO_SESSION_LISTENING => VideoSessionState::Listening,
            SLOPDESK_VIDEO_SESSION_STREAMING => VideoSessionState::Streaming,
            SLOPDESK_VIDEO_SESSION_STOPPED => VideoSessionState::Stopped,
            _ => VideoSessionState::Idle,
        },
        (record.capture_width, record.capture_height),
        record.window_id,
        record.is_display_target,
        record.last_stream_id,
        record.last_resize_epoch,
    );
    law
}

/// The machine as it crosses.
const fn record_of(law: &VideoSessionStateMachine) -> SlopDeskVideoSessionMachine {
    let (capture_width, capture_height) = law.capture_size();
    SlopDeskVideoSessionMachine {
        state: match law.state() {
            VideoSessionState::Idle => SLOPDESK_VIDEO_SESSION_IDLE,
            VideoSessionState::Listening => SLOPDESK_VIDEO_SESSION_LISTENING,
            VideoSessionState::Streaming => SLOPDESK_VIDEO_SESSION_STREAMING,
            VideoSessionState::Stopped => SLOPDESK_VIDEO_SESSION_STOPPED,
        },
        window_id: law.window_id(),
        next_stream_id: law.next_stream_id(),
        last_stream_id: law.last_stream_id(),
        last_resize_epoch: law.last_resize_epoch(),
        capture_width,
        capture_height,
        is_display_target: law.is_display_target(),
        full_range: law.full_range(),
    }
}

/// One effect, with its control datagram appended to the arena.
fn effect_of(effect: &SessionEffect, pool: &mut Vec<u8>) -> SlopDeskVideoSessionEffect {
    let mut record = SlopDeskVideoSessionEffect::default();
    match *effect {
        SessionEffect::SendControl(ref message) => {
            record.kind = SLOPDESK_SESSION_EFFECT_SEND_CONTROL;
            let encoded = message.encode();
            let offset = u32::try_from(pool.len()).unwrap_or(u32::MAX);
            pool.extend_from_slice(&encoded);
            record.control = SlopDeskByteSpan {
                offset,
                length: u32::try_from(encoded.len()).unwrap_or(u32::MAX),
            };
        },
        SessionEffect::StartCapture {
            window_id,
            width,
            height,
        } => {
            record.kind = SLOPDESK_SESSION_EFFECT_START_CAPTURE;
            record.window_id = window_id;
            record.width = width;
            record.height = height;
        },
        SessionEffect::StopCapture => record.kind = SLOPDESK_SESSION_EFFECT_STOP_CAPTURE,
        SessionEffect::ResizeCapture { width, height, epoch } => {
            record.kind = SLOPDESK_SESSION_EFFECT_RESIZE_CAPTURE;
            record.width = width;
            record.height = height;
            record.epoch = epoch;
        },
        SessionEffect::ApplyStreamSettings {
            fps_cap,
            bitrate_ceiling_bps,
        } => {
            record.kind = SLOPDESK_SESSION_EFFECT_APPLY_STREAM_SETTINGS;
            record.first = u32::from(fps_cap);
            record.second = bitrate_ceiling_bps;
        },
        SessionEffect::ApplyAudioControl { enabled } => {
            record.kind = SLOPDESK_SESSION_EFFECT_APPLY_AUDIO_CONTROL;
            record.enabled = enabled;
        },
        SessionEffect::ApplyPrivacyMode { enabled } => {
            record.kind = SLOPDESK_SESSION_EFFECT_APPLY_PRIVACY_MODE;
            record.enabled = enabled;
        },
    }
    record
}

/// Steps a COPY of the machine, and writes it back only once the answer fits.
///
/// # Safety
/// `machine` must be null or point to one live record; the lent buffers must be null or writable
/// for the capacities given.
#[expect(
    unsafe_code,
    reason = "reconstituting the caller's record and buffers IS the boundary this module documents"
)]
unsafe fn step(
    machine: *mut SlopDeskVideoSessionMachine,
    transition: impl FnOnce(&mut VideoSessionStateMachine) -> Vec<SessionEffect>,
    effects: *mut SlopDeskVideoSessionEffect,
    effects_cap: usize,
    arena: *mut u8,
    arena_cap: usize,
) -> SlopDeskVideoSessionShape {
    if machine.is_null() {
        return SlopDeskVideoSessionShape::default();
    }
    // SAFETY: non-null and, by the caller's obligation, live for this call.
    let mut working = law_of(unsafe { core::ptr::read(machine) });
    let produced = transition(&mut working);
    let mut pool = Vec::new();
    let records: Vec<_> = produced
        .iter()
        .map(|effect| effect_of(effect, &mut pool))
        .collect();
    let shape = SlopDeskVideoSessionShape {
        effects: records.len(),
        arena: pool.len(),
    };
    if !shape.fits(effects_cap, arena_cap) {
        return shape;
    }
    if !records.is_empty() && !effects.is_null() {
        // SAFETY: the capacity check above, and the caller's obligation that the buffer is writable.
        unsafe { core::ptr::copy_nonoverlapping(records.as_ptr(), effects, records.len()) };
    }
    if !pool.is_empty() && !arena.is_null() {
        // SAFETY: as above.
        unsafe { core::ptr::copy_nonoverlapping(pool.as_ptr(), arena, pool.len()) };
    }
    // SAFETY: as above; the answer fit, so this transition is the one the caller keeps.
    unsafe { core::ptr::write(machine, record_of(&working)) };
    shape
}

#[cfg(test)]
mod tests {
    #![expect(
        unsafe_code,
        reason = "calling the doors as the near side does IS what these tests pin"
    )]
    #![expect(
        clippy::indexing_slicing,
        reason = "an out-of-range index in a test is the failure report, not a runtime fault"
    )]
    #![expect(
        clippy::expect_used,
        reason = "a datagram the law itself just minted must decode; a panic here IS the report"
    )]

    use core::ptr;

    use slopdesk_video::geometry::VideoSize;
    use slopdesk_video::session_state::PROTOCOL_VERSION;
    use slopdesk_video::video_control::VideoControlMessage;

    use super::{
        SLOPDESK_SESSION_EFFECT_RESIZE_CAPTURE, SLOPDESK_SESSION_EFFECT_SEND_CONTROL,
        SLOPDESK_SESSION_EFFECT_START_CAPTURE, SLOPDESK_SESSION_EFFECT_STOP_CAPTURE,
        SLOPDESK_VIDEO_SESSION_LISTENING, SLOPDESK_VIDEO_SESSION_STREAMING, SlopDeskResolvedSize,
        SlopDeskVideoSessionEffect, SlopDeskVideoSessionMachine, slopdesk_video_bitrate_ceiling_from_wire,
        slopdesk_video_effective_fps, slopdesk_video_fps_cap_from_wire, slopdesk_video_session_control,
        slopdesk_video_session_media_flowing, slopdesk_video_session_new, slopdesk_video_session_stale_epoch,
        slopdesk_video_session_start, slopdesk_video_session_stop,
    };
    use crate::video_policy::SlopDeskVideoRect;

    /// A size the actor resolved.
    const fn resolved(width: u16, height: u16) -> SlopDeskResolvedSize {
        SlopDeskResolvedSize {
            width,
            height,
            resolved: true,
        }
    }

    /// The rejection a resolver spells as `None`.
    const REFUSED: SlopDeskResolvedSize = SlopDeskResolvedSize {
        width: 0,
        height: 0,
        resolved: false,
    };

    const BOUNDS: SlopDeskVideoRect = SlopDeskVideoRect {
        x: 10.0,
        y: 20.0,
        width: 800.0,
        height: 600.0,
    };

    /// One transition, measured and then filled exactly as the near side does it.
    fn control(
        machine: &mut SlopDeskVideoSessionMachine,
        message: &VideoControlMessage,
        capture: SlopDeskResolvedSize,
        resize: SlopDeskResolvedSize,
    ) -> (Vec<SlopDeskVideoSessionEffect>, Vec<u8>) {
        let bytes = message.encode();
        let shape = unsafe {
            slopdesk_video_session_control(
                machine,
                bytes.as_ptr(),
                bytes.len(),
                BOUNDS,
                capture,
                resize,
                REFUSED,
                ptr::null_mut(),
                0,
                ptr::null_mut(),
                0,
            )
        };
        let mut room = vec![SlopDeskVideoSessionEffect::default(); shape.effects];
        let mut arena = vec![0u8; shape.arena];
        let written = unsafe {
            slopdesk_video_session_control(
                machine,
                bytes.as_ptr(),
                bytes.len(),
                BOUNDS,
                capture,
                resize,
                REFUSED,
                room.as_mut_ptr(),
                room.len(),
                arena.as_mut_ptr(),
                arena.len(),
            )
        };
        assert_eq!(written, shape, "the measure and the fill agree");
        (room, arena)
    }

    /// A machine that accepted a hello for one window.
    fn streaming() -> SlopDeskVideoSessionMachine {
        let mut machine = slopdesk_video_session_new(7, true);
        unsafe { slopdesk_video_session_start(&raw mut machine) };
        assert_eq!(machine.state, SLOPDESK_VIDEO_SESSION_LISTENING);
        let hello = VideoControlMessage::Hello {
            protocol_version: PROTOCOL_VERSION,
            requested_window_id: 42,
            viewport: VideoSize {
                width: 1280.0,
                height: 720.0,
            },
        };
        let (effects, arena) = control(&mut machine, &hello, resolved(800, 600), REFUSED);
        assert_eq!(effects.len(), 2, "an acknowledgement and a capture start");
        assert_eq!(effects[0].kind, SLOPDESK_SESSION_EFFECT_SEND_CONTROL);
        assert_eq!(effects[1].kind, SLOPDESK_SESSION_EFFECT_START_CAPTURE);
        assert_eq!((effects[1].width, effects[1].height), (800, 600));
        let span = effects[0].control;
        let start = span.offset as usize;
        let acked = VideoControlMessage::decode(&arena[start..start + span.length as usize])
            .expect("the acknowledgement decodes");
        assert!(
            matches!(acked, VideoControlMessage::HelloAck {
                accepted: true,
                stream_id: 7,
                full_range: true,
                ..
            }),
            "{acked:?}"
        );
        assert!(slopdesk_video_session_media_flowing(machine));
        machine
    }

    #[test]
    fn an_accepted_hello_starts_capture_at_the_size_the_actor_resolved() {
        let machine = streaming();
        assert_eq!(machine.window_id, 42);
        assert_eq!(
            machine.next_stream_id, 8,
            "the counter advanced past the minted id"
        );
    }

    #[test]
    fn an_unresolved_capture_size_is_the_rejection_the_closure_spelled() {
        let mut machine = slopdesk_video_session_new(1, false);
        unsafe { slopdesk_video_session_start(&raw mut machine) };
        let hello = VideoControlMessage::Hello {
            protocol_version: PROTOCOL_VERSION,
            requested_window_id: 9,
            viewport: VideoSize {
                width: 640.0,
                height: 480.0,
            },
        };
        let (effects, arena) = control(&mut machine, &hello, REFUSED, REFUSED);
        assert_eq!(effects.len(), 1, "a rejection and nothing else");
        let span = effects[0].control;
        let start = span.offset as usize;
        let acked = VideoControlMessage::decode(&arena[start..start + span.length as usize])
            .expect("the rejection decodes");
        assert!(
            matches!(acked, VideoControlMessage::HelloAck { accepted: false, .. }),
            "{acked:?}"
        );
        assert!(!slopdesk_video_session_media_flowing(machine));
    }

    #[test]
    fn a_resize_answers_its_epoch_and_a_stale_one_is_dropped() {
        let mut machine = streaming();
        let resize = VideoControlMessage::ResizeRequest {
            desired: VideoSize {
                width: 640.0,
                height: 400.0,
            },
            epoch: 3,
        };
        let (effects, _) = control(&mut machine, &resize, REFUSED, resolved(640, 400));
        assert_eq!(effects.len(), 1);
        assert_eq!(effects[0].kind, SLOPDESK_SESSION_EFFECT_RESIZE_CAPTURE);
        assert_eq!(effects[0].epoch, 3);
        assert_eq!((machine.capture_width, machine.capture_height), (640, 400));

        let stale = VideoControlMessage::ResizeRequest {
            desired: VideoSize {
                width: 100.0,
                height: 100.0,
            },
            epoch: 2,
        };
        let (dropped, _) = control(&mut machine, &stale, REFUSED, resolved(100, 100));
        assert!(dropped.is_empty(), "a reorder cannot un-settle the size");
        assert_eq!((machine.capture_width, machine.capture_height), (640, 400));
    }

    #[test]
    fn a_short_lend_leaves_the_machine_where_it_was() {
        let mut machine = streaming();
        let before = machine;
        let bye = VideoControlMessage::Bye.encode();
        let shape = unsafe {
            slopdesk_video_session_control(
                &raw mut machine,
                bye.as_ptr(),
                bye.len(),
                BOUNDS,
                REFUSED,
                REFUSED,
                REFUSED,
                ptr::null_mut(),
                0,
                ptr::null_mut(),
                0,
            )
        };
        assert_eq!(shape.effects, 1, "the goodbye stops capture");
        assert_eq!(machine, before, "measuring is not a transition");
    }

    #[test]
    fn a_local_stop_is_terminal_and_tears_capture_down() {
        let mut machine = streaming();
        let mut room = [SlopDeskVideoSessionEffect::default(); 4];
        let shape = unsafe {
            slopdesk_video_session_stop(
                &raw mut machine,
                room.as_mut_ptr(),
                room.len(),
                ptr::null_mut(),
                0,
            )
        };
        assert_eq!(shape.effects, 1);
        assert_eq!(room[0].kind, SLOPDESK_SESSION_EFFECT_STOP_CAPTURE);
        assert!(!slopdesk_video_session_media_flowing(machine));
        assert_ne!(machine.state, SLOPDESK_VIDEO_SESSION_STREAMING);
    }

    #[test]
    fn a_datagram_that_does_not_decode_is_a_no_op() {
        let mut machine = streaming();
        let before = machine;
        let shape = unsafe {
            slopdesk_video_session_control(
                &raw mut machine,
                [0xFFu8; 3].as_ptr(),
                3,
                BOUNDS,
                REFUSED,
                REFUSED,
                REFUSED,
                ptr::null_mut(),
                0,
                ptr::null_mut(),
                0,
            )
        };
        assert_eq!(shape.effects, 0);
        assert_eq!(machine, before);
    }
    #[test]
    fn the_actor_asks_the_same_epoch_rule_the_transition_applies() {
        assert!(
            !slopdesk_video_session_stale_epoch(1, 0),
            "the first of a session wins"
        );
        assert!(slopdesk_video_session_stale_epoch(5, 5), "a duplicate is stale");
        assert!(
            slopdesk_video_session_stale_epoch(3, 5),
            "and so is a reordered older one"
        );
        assert!(!slopdesk_video_session_stale_epoch(u32::MAX, 5));
    }

    #[test]
    fn an_absent_override_crosses_as_a_flag_and_a_present_one_is_clamped() {
        let mut cap = 0_i64;
        assert!(
            !unsafe { slopdesk_video_fps_cap_from_wire(0, &raw mut cap) },
            "zero is AUTO"
        );
        assert!(unsafe { slopdesk_video_fps_cap_from_wire(1, &raw mut cap) });
        assert_eq!(cap, 5, "a slideshow request clamps up to the floor");
        assert!(unsafe { slopdesk_video_fps_cap_from_wire(255, &raw mut cap) });
        assert_eq!(cap, 120, "and an impossible one down to the ceiling");

        let mut ceiling = 0_i64;
        assert!(!unsafe { slopdesk_video_bitrate_ceiling_from_wire(0, &raw mut ceiling) });
        assert!(unsafe { slopdesk_video_bitrate_ceiling_from_wire(1, &raw mut ceiling) });
        assert_eq!(ceiling, 500_000);
        assert!(unsafe { slopdesk_video_bitrate_ceiling_from_wire(u32::MAX, &raw mut ceiling) });
        assert_eq!(ceiling, 200_000_000);

        assert!(
            unsafe { slopdesk_video_fps_cap_from_wire(30, ptr::null_mut()) },
            "a caller that only wants the presence lends nothing"
        );
    }

    #[test]
    fn no_cap_leaves_the_governed_cadence_exactly_as_it_was() {
        assert_eq!(slopdesk_video_effective_fps(60, false, 0), 60);
        assert_eq!(slopdesk_video_effective_fps(60, true, 30), 30);
        assert_eq!(
            slopdesk_video_effective_fps(24, true, 120),
            24,
            "the cap is a ceiling, not a floor"
        );
    }
}
