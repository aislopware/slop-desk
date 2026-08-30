//! What a client session says to the host, and what it does with the answers.
//!
//! `rust/slopdesk-video`'s `client_session` owns the machine, the hello-retry cadence and the
//! reconnecting-scrim latch. The runtime that performs the effects — the sockets, the decoder, the
//! renderer — stays where the sockets are.
//!
//! ## The machine crosses by value, because the near side reads all of it
//! §4b: the far side picks the convention, and a Swift `struct` copied by value cannot be a handle
//! without two owners silently aliasing one allocation. Every field here — the state, the
//! negotiated stream id, the capture size, the acked bounds — is read by the near side, so the
//! whole machine is six scalars and two rectangles that ride in and out of each call. There is
//! nothing to own.
//!
//! ## A transition commits only when its answer fits
//! A transition MUTATES, so the ordinary two-call shape — measure, then fill — would apply it
//! twice. Each entry point therefore steps a COPY, measures what the answer needs, and writes the
//! machine back only once every lent buffer is big enough. A caller that lent too little gets the
//! shape it should have lent and a machine that has not moved, so calling again is not a second
//! transition.
//!
//! ## A control message crosses as its bytes
//! `SendControl` carries a `VideoControlMessage`, and the only thing the runtime does with one is
//! encode it onto the control channel. Crossing the encoded datagram instead of the typed message
//! hands the runtime exactly what it sends, and the hello that opens every session is then minted
//! by the same crate that parses it back on the host.

use slopdesk_video::client_session::{
    ClientEffect, StallScrimLatch, VideoClientState, VideoClientStateMachine, VideoStreamTarget,
    hello_retry_delay,
};
use slopdesk_video::geometry::{VideoRect, VideoSize};
use slopdesk_video::keepalive::StallVerdict;
use slopdesk_video::video_control::{MaskRect, VideoControlMessage};

use crate::video_policy::{
    SLOPDESK_STREAM_LIVE, SLOPDESK_STREAM_NOT_CONNECTED, SLOPDESK_STREAM_STALLED, SlopDeskVideoRect,
    SlopDeskVideoSize,
};
use crate::{SlopDeskByteSpan, borrow};

/// Not yet started.
pub const SLOPDESK_VIDEO_CLIENT_IDLE: u32 = 0;
/// The hello went out; the acknowledgement has not come back.
pub const SLOPDESK_VIDEO_CLIENT_CONNECTING: u32 = 1;
/// Accepted: video and cursor are flowing.
pub const SLOPDESK_VIDEO_CLIENT_STREAMING: u32 = 2;
/// The host refused the hello.
pub const SLOPDESK_VIDEO_CLIENT_REJECTED: u32 = 3;
/// A local stop, or a received farewell. Terminal.
pub const SLOPDESK_VIDEO_CLIENT_STOPPED: u32 = 4;

/// The session streams one window, by its host window id.
pub const SLOPDESK_VIDEO_TARGET_WINDOW: u32 = 0;
/// The session streams a whole display; zero means the host's main one.
pub const SLOPDESK_VIDEO_TARGET_DISPLAY: u32 = 1;

/// Send the effect's `control` bytes to the host on the control channel.
pub const SLOPDESK_CLIENT_EFFECT_SEND_CONTROL: u32 = 0;
/// Re-send the cursor side-channel prime.
pub const SLOPDESK_CLIENT_EFFECT_PRIME_CURSOR_FLOW: u32 = 1;
/// Bring the decoder, pacer and renderer up at `size` / `bounds` / `full_range`.
pub const SLOPDESK_CLIENT_EFFECT_START_DECODE_PIPELINE: u32 = 2;
/// Tear the decode pipeline down.
pub const SLOPDESK_CLIENT_EFFECT_STOP_DECODE_PIPELINE: u32 = 3;
/// Stage `size` as the pending capture size.
pub const SLOPDESK_CLIENT_EFFECT_UPDATE_CAPTURE_SIZE: u32 = 4;
/// Rebase the content cadence on `first` frames per second.
pub const SLOPDESK_CLIENT_EFFECT_APPLY_STREAM_CADENCE: u32 = 5;
/// Warp by `dx`/`dy` within the band `first`..`second`.
pub const SLOPDESK_CLIENT_EFFECT_APPLY_SCROLL_OFFSET: u32 = 6;
/// Mask everything outside the effect's run of the lent rectangles.
pub const SLOPDESK_CLIENT_EFFECT_APPLY_CONTENT_MASK: u32 = 7;
/// Adopt `size` as the maximum resizable point size.
pub const SLOPDESK_CLIENT_EFFECT_APPLY_DISPLAY_MAX: u32 = 8;
/// Adopt the host's stats halves, `first` and `second`, in tenths of a millisecond.
pub const SLOPDESK_CLIENT_EFFECT_APPLY_HOST_STATS: u32 = 9;
/// The host ended the session: rebuild the whole pipeline on a fresh lane.
pub const SLOPDESK_CLIENT_EFFECT_SESSION_ENDED_BY_HOST: u32 = 10;
/// The host refused the session: terminal, and never retried.
pub const SLOPDESK_CLIENT_EFFECT_SESSION_REJECTED_BY_HOST: u32 = 11;

/// The scrim did not flip, so the view is not notified.
pub const SLOPDESK_SCRIM_UNCHANGED: i32 = -1;
/// The scrim came down: traffic is flowing again.
pub const SLOPDESK_SCRIM_HIDDEN: i32 = 0;
/// The scrim went up.
pub const SLOPDESK_SCRIM_SHOWN: i32 = 1;

/// A client session machine, whole, as it crosses.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct SlopDeskVideoClientMachine {
    /// One of the `SLOPDESK_VIDEO_CLIENT_*` states.
    pub state: u32,
    /// One of the `SLOPDESK_VIDEO_TARGET_*` kinds.
    pub target_kind: u32,
    /// The window or display id the session asked for.
    pub target_id: u32,
    /// The session id the host minted, zero until an accepted acknowledgement.
    pub stream_id: u32,
    /// The client viewport the host sizes capture against.
    pub viewport: SlopDeskVideoSize,
    /// The negotiated capture size.
    pub capture_size: SlopDeskVideoSize,
    /// The target's bounds as the acknowledgement reported them.
    pub window_bounds_cg: SlopDeskVideoRect,
}

/// One opaque-content rectangle, in capture pixels.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SlopDeskVideoMaskRect {
    /// Left edge.
    pub x: u16,
    /// Top edge.
    pub y: u16,
    /// Horizontal extent.
    pub width: u16,
    /// Vertical extent.
    pub height: u16,
}

/// One side effect. Which fields mean anything is decided by `kind`; the rest stay zero.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct SlopDeskVideoClientEffect {
    /// One of the `SLOPDESK_CLIENT_EFFECT_*` kinds.
    pub kind: u32,
    /// The encoded control datagram, as a run of the answer arena.
    pub control: SlopDeskByteSpan,
    /// The capture, pending or maximum size.
    pub size: SlopDeskVideoSize,
    /// The target's bounds, on a pipeline start.
    pub bounds: SlopDeskVideoRect,
    /// The signed horizontal scroll shift.
    pub dx: i32,
    /// The signed vertical scroll shift.
    pub dy: i32,
    /// The cadence, the round-trip tenths, or the band's top.
    pub first: u32,
    /// The encode tenths, or the band's bottom.
    pub second: u32,
    /// Where this effect's rectangles start in the lent mask array.
    pub mask_offset: u32,
    /// How many rectangles it has there.
    pub mask_count: u32,
    /// The stream's negotiated luma range, on a pipeline start.
    pub full_range: bool,
}

/// What one transition needs the caller to lend.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SlopDeskVideoClientShape {
    /// How many effects the transition produced.
    pub effects: usize,
    /// How many mask rectangles they reference.
    pub masks: usize,
    /// How many arena bytes their control datagrams need.
    pub arena: usize,
}

impl SlopDeskVideoClientShape {
    /// Whether every lent buffer is big enough for this answer.
    const fn fits(self, effects: usize, masks: usize, arena: usize) -> bool {
        self.effects <= effects && self.masks <= masks && self.arena <= arena
    }
}

/// A machine for one target and the client viewport the host should size capture against.
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
#[unsafe(no_mangle)]
pub const extern "C" fn slopdesk_video_client_new(
    target_kind: u32,
    target_id: u32,
    viewport: SlopDeskVideoSize,
) -> SlopDeskVideoClientMachine {
    SlopDeskVideoClientMachine {
        state: SLOPDESK_VIDEO_CLIENT_IDLE,
        target_kind,
        target_id,
        stream_id: 0,
        viewport,
        capture_size: SlopDeskVideoSize {
            width: 0.0,
            height: 0.0,
        },
        window_bounds_cg: SlopDeskVideoRect {
            x: 0.0,
            y: 0.0,
            width: 0.0,
            height: 0.0,
        },
    }
}

/// Whether received media should be processed right now.
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
#[unsafe(no_mangle)]
pub const extern "C" fn slopdesk_video_client_media_flowing(machine: SlopDeskVideoClientMachine) -> bool {
    machine.state == SLOPDESK_VIDEO_CLIENT_STREAMING
}

/// The window this session asked to remote, or zero for a display target.
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
#[unsafe(no_mangle)]
pub const extern "C" fn slopdesk_video_client_requested_window_id(
    machine: SlopDeskVideoClientMachine,
) -> u32 {
    machine_of(machine).requested_window_id()
}

/// Starts the session: prime the cursor flow, send the hello.
///
/// # Safety
/// `machine` must point to one live record for the call; the three lent buffers must be null or
/// writable for the capacities given.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_video_client_start(
    machine: *mut SlopDeskVideoClientMachine,
    effects: *mut SlopDeskVideoClientEffect,
    effects_cap: usize,
    masks: *mut SlopDeskVideoMaskRect,
    masks_cap: usize,
    arena: *mut u8,
    arena_cap: usize,
) -> SlopDeskVideoClientShape {
    // SAFETY: the caller's obligation above, discharged on the near side by one `withUnsafe…` scope
    // per buffer, which is exactly this call.
    unsafe {
        step(
            machine,
            VideoClientStateMachine::start,
            effects,
            effects_cap,
            masks,
            masks_cap,
            arena,
            arena_cap,
        )
    }
}

/// Re-emits the hello while still connecting — the other half of the reconnect-wedge fix.
///
/// # Safety
/// As [`slopdesk_video_client_start`].
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_video_client_resend_hello(
    machine: *mut SlopDeskVideoClientMachine,
    effects: *mut SlopDeskVideoClientEffect,
    effects_cap: usize,
    masks: *mut SlopDeskVideoMaskRect,
    masks_cap: usize,
    arena: *mut u8,
    arena_cap: usize,
) -> SlopDeskVideoClientShape {
    // SAFETY: as above.
    unsafe {
        step(
            machine,
            VideoClientStateMachine::resend_hello,
            effects,
            effects_cap,
            masks,
            masks_cap,
            arena,
            arena_cap,
        )
    }
}

/// A local stop: tell the host, best effort, and tear down.
///
/// # Safety
/// As [`slopdesk_video_client_start`].
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_video_client_stop(
    machine: *mut SlopDeskVideoClientMachine,
    effects: *mut SlopDeskVideoClientEffect,
    effects_cap: usize,
    masks: *mut SlopDeskVideoMaskRect,
    masks_cap: usize,
    arena: *mut u8,
    arena_cap: usize,
) -> SlopDeskVideoClientShape {
    // SAFETY: as above.
    unsafe {
        step(
            machine,
            VideoClientStateMachine::stop,
            effects,
            effects_cap,
            masks,
            masks_cap,
            arena,
            arena_cap,
        )
    }
}

/// A control datagram arrived from the host, as the bytes the transport handed over.
///
/// An undecodable datagram produces no effects and no transition, which is the same inertness the
/// router already gives a corrupt packet.
///
/// # Safety
/// As [`slopdesk_video_client_start`], plus: `data` must be null or live for `data_len` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_video_client_handle_control(
    machine: *mut SlopDeskVideoClientMachine,
    data: *const u8,
    data_len: usize,
    effects: *mut SlopDeskVideoClientEffect,
    effects_cap: usize,
    masks: *mut SlopDeskVideoMaskRect,
    masks_cap: usize,
    arena: *mut u8,
    arena_cap: usize,
) -> SlopDeskVideoClientShape {
    // SAFETY: as above, and the datagram is borrowed only for this call.
    let message = unsafe { VideoControlMessage::decode(borrow(data, data_len)) };
    let Ok(message) = message else {
        return SlopDeskVideoClientShape::default();
    };
    // SAFETY: as above.
    unsafe {
        step(
            machine,
            |working| working.handle_control(&message),
            effects,
            effects_cap,
            masks,
            masks_cap,
            arena,
            arena_cap,
        )
    }
}

/// How long to wait before re-sending the hello, for a zero-based retry number.
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
#[unsafe(no_mangle)]
pub extern "C" fn slopdesk_video_client_hello_retry_delay(attempt: u32) -> f64 {
    hello_retry_delay(attempt)
}

/// A host-ended rebuild started, so show the reconnecting scrim now.
///
/// Answers `SLOPDESK_SCRIM_SHOWN` when this raised it and `SLOPDESK_SCRIM_UNCHANGED` when it was
/// already up, because duplicate farewells should be quiet. `visible` is the latch, read and
/// written.
///
/// # Safety
/// `visible` must point to one live, writable `bool` for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_stall_scrim_note_reconnecting(visible: *mut bool) -> i32 {
    // SAFETY: the caller's obligation above, discharged by `withUnsafeMutablePointer` on the near
    // side.
    unsafe { latched(visible, StallScrimLatch::note_reconnecting) }
}

/// Folds one `SLOPDESK_STREAM_*` verdict through the latch, answering only when it FLIPPED.
///
/// # Safety
/// As [`slopdesk_stall_scrim_note_reconnecting`].
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_stall_scrim_apply(visible: *mut bool, verdict: u32) -> i32 {
    let verdict = match verdict {
        SLOPDESK_STREAM_LIVE => StallVerdict::Live,
        SLOPDESK_STREAM_STALLED => StallVerdict::Stalled,
        SLOPDESK_STREAM_NOT_CONNECTED => StallVerdict::NotConnected,
        _ => StallVerdict::Unknown,
    };
    // SAFETY: as above.
    unsafe { latched(visible, |latch| latch.apply(verdict)) }
}

/// Runs one latch operation over the caller's `bool` and reports what flipped.
///
/// # Safety
/// `visible` must be null, or point to one live, writable `bool` for the call.
#[expect(
    unsafe_code,
    reason = "reconstituting the caller's latch IS the boundary this module documents"
)]
unsafe fn latched(visible: *mut bool, fold: impl FnOnce(&mut StallScrimLatch) -> Option<bool>) -> i32 {
    if visible.is_null() {
        return SLOPDESK_SCRIM_UNCHANGED;
    }
    // SAFETY: non-null and, by the caller's obligation, live and writable for this call.
    let mut latch = StallScrimLatch::restored(unsafe { std::ptr::read(visible) });
    let flipped = fold(&mut latch);
    // SAFETY: as above.
    unsafe { std::ptr::write(visible, latch.visible()) };
    match flipped {
        None => SLOPDESK_SCRIM_UNCHANGED,
        Some(false) => SLOPDESK_SCRIM_HIDDEN,
        Some(true) => SLOPDESK_SCRIM_SHOWN,
    }
}

/// Steps a COPY of the caller's machine, and commits it only once the answer fits.
///
/// The machine is left exactly as it was when a lent buffer is too small, so the caller's second
/// call with the reported shape is the SAME transition rather than a second one.
///
/// # Safety
/// `machine` must point to one live, writable record; each lent buffer must be null or writable for
/// the capacity given.
#[expect(
    unsafe_code,
    reason = "reconstituting the caller's machine and buffers IS the boundary this module documents"
)]
#[expect(
    clippy::too_many_arguments,
    reason = "three lent buffers are three pairs; collapsing them would hide what the caller lends"
)]
unsafe fn step(
    machine: *mut SlopDeskVideoClientMachine,
    transition: impl FnOnce(&mut VideoClientStateMachine) -> Vec<ClientEffect>,
    effects: *mut SlopDeskVideoClientEffect,
    effects_cap: usize,
    masks: *mut SlopDeskVideoMaskRect,
    masks_cap: usize,
    arena: *mut u8,
    arena_cap: usize,
) -> SlopDeskVideoClientShape {
    if machine.is_null() {
        return SlopDeskVideoClientShape::default();
    }
    // SAFETY: non-null and, by the caller's obligation, live for this call.
    let mut working = machine_of(unsafe { std::ptr::read(machine) });
    let produced = transition(&mut working);
    let (records, rects, pool) = render(&produced);
    let shape = SlopDeskVideoClientShape {
        effects: records.len(),
        masks: rects.len(),
        arena: pool.len(),
    };
    if !shape.fits(effects_cap, masks_cap, arena_cap) {
        return shape;
    }
    if !records.is_empty() && !effects.is_null() {
        // SAFETY: the capacity check above, and the caller's obligation that the buffer is
        // writable.
        unsafe { std::ptr::copy_nonoverlapping(records.as_ptr(), effects, records.len()) };
    }
    if !rects.is_empty() && !masks.is_null() {
        // SAFETY: as above.
        unsafe { std::ptr::copy_nonoverlapping(rects.as_ptr(), masks, rects.len()) };
    }
    if !pool.is_empty() && !arena.is_null() {
        // SAFETY: as above.
        unsafe { std::ptr::copy_nonoverlapping(pool.as_ptr(), arena, pool.len()) };
    }
    // SAFETY: as above; the answer fit, so this transition is the one the caller keeps.
    unsafe { std::ptr::write(machine, record_of(&working)) };
    shape
}

/// Renders the effects into the three flat things they cross as.
fn render(
    produced: &[ClientEffect],
) -> (
    Vec<SlopDeskVideoClientEffect>,
    Vec<SlopDeskVideoMaskRect>,
    Vec<u8>,
) {
    let mut records = Vec::with_capacity(produced.len());
    let mut rects = Vec::new();
    let mut pool = Vec::new();
    for effect in produced {
        records.push(effect_of(effect, &mut rects, &mut pool));
    }
    (records, rects, pool)
}

/// One effect, with its variable parts appended to the mask array and the arena.
fn effect_of(
    effect: &ClientEffect,
    rects: &mut Vec<SlopDeskVideoMaskRect>,
    pool: &mut Vec<u8>,
) -> SlopDeskVideoClientEffect {
    let mut record = SlopDeskVideoClientEffect::default();
    match *effect {
        ClientEffect::SendControl(ref message) => {
            record.kind = SLOPDESK_CLIENT_EFFECT_SEND_CONTROL;
            let encoded = message.encode();
            let offset = u32::try_from(pool.len()).unwrap_or(u32::MAX);
            pool.extend_from_slice(&encoded);
            record.control = SlopDeskByteSpan {
                offset,
                length: u32::try_from(encoded.len()).unwrap_or(u32::MAX),
            };
        },
        ClientEffect::PrimeCursorFlow => record.kind = SLOPDESK_CLIENT_EFFECT_PRIME_CURSOR_FLOW,
        ClientEffect::StartDecodePipeline {
            capture_size,
            window_bounds_cg,
            full_range,
        } => {
            record.kind = SLOPDESK_CLIENT_EFFECT_START_DECODE_PIPELINE;
            record.size = size_record(capture_size);
            record.bounds = rect_record(window_bounds_cg);
            record.full_range = full_range;
        },
        ClientEffect::StopDecodePipeline => record.kind = SLOPDESK_CLIENT_EFFECT_STOP_DECODE_PIPELINE,
        ClientEffect::UpdateCaptureSize(size) => {
            record.kind = SLOPDESK_CLIENT_EFFECT_UPDATE_CAPTURE_SIZE;
            record.size = size_record(size);
        },
        ClientEffect::ApplyStreamCadence(fps) => {
            record.kind = SLOPDESK_CLIENT_EFFECT_APPLY_STREAM_CADENCE;
            record.first = u32::from(fps);
        },
        ClientEffect::ApplyScrollOffset {
            dx,
            dy,
            band_top,
            band_bottom,
        } => {
            record.kind = SLOPDESK_CLIENT_EFFECT_APPLY_SCROLL_OFFSET;
            record.dx = i32::from(dx);
            record.dy = i32::from(dy);
            record.first = u32::from(band_top);
            record.second = u32::from(band_bottom);
        },
        ClientEffect::ApplyContentMask(ref mask) => {
            record.kind = SLOPDESK_CLIENT_EFFECT_APPLY_CONTENT_MASK;
            record.mask_offset = u32::try_from(rects.len()).unwrap_or(u32::MAX);
            record.mask_count = u32::try_from(mask.len()).unwrap_or(u32::MAX);
            rects.extend(mask.iter().copied().map(mask_record));
        },
        ClientEffect::ApplyDisplayMax(size) => {
            record.kind = SLOPDESK_CLIENT_EFFECT_APPLY_DISPLAY_MAX;
            record.size = size_record(size);
        },
        ClientEffect::ApplyHostStats {
            rtt_tenths_millis,
            encode_tenths_millis,
        } => {
            record.kind = SLOPDESK_CLIENT_EFFECT_APPLY_HOST_STATS;
            record.first = u32::from(rtt_tenths_millis);
            record.second = u32::from(encode_tenths_millis);
        },
        ClientEffect::SessionEndedByHost => record.kind = SLOPDESK_CLIENT_EFFECT_SESSION_ENDED_BY_HOST,
        ClientEffect::SessionRejectedByHost => {
            record.kind = SLOPDESK_CLIENT_EFFECT_SESSION_REJECTED_BY_HOST;
        },
    }
    record
}

/// The crate's machine, rebuilt from the record that crossed.
const fn machine_of(record: SlopDeskVideoClientMachine) -> VideoClientStateMachine {
    let target = if record.target_kind == SLOPDESK_VIDEO_TARGET_DISPLAY {
        VideoStreamTarget::Display(record.target_id)
    } else {
        VideoStreamTarget::Window(record.target_id)
    };
    VideoClientStateMachine::restored(
        state_of(record.state),
        target,
        VideoSize::new(record.viewport.width, record.viewport.height),
        record.stream_id,
        VideoSize::new(record.capture_size.width, record.capture_size.height),
        VideoRect::xywh(
            record.window_bounds_cg.x,
            record.window_bounds_cg.y,
            record.window_bounds_cg.width,
            record.window_bounds_cg.height,
        ),
    )
}

/// The record for a machine that has just stepped.
const fn record_of(machine: &VideoClientStateMachine) -> SlopDeskVideoClientMachine {
    let (target_kind, target_id) = match machine.target() {
        VideoStreamTarget::Window(id) => (SLOPDESK_VIDEO_TARGET_WINDOW, id),
        VideoStreamTarget::Display(id) => (SLOPDESK_VIDEO_TARGET_DISPLAY, id),
    };
    SlopDeskVideoClientMachine {
        state: state_code(machine.state()),
        target_kind,
        target_id,
        stream_id: machine.stream_id(),
        viewport: size_record(machine.viewport()),
        capture_size: size_record(machine.capture_size()),
        window_bounds_cg: rect_record(machine.window_bounds_cg()),
    }
}

/// One lifecycle state as its code.
const fn state_code(state: VideoClientState) -> u32 {
    match state {
        VideoClientState::Idle => SLOPDESK_VIDEO_CLIENT_IDLE,
        VideoClientState::Connecting => SLOPDESK_VIDEO_CLIENT_CONNECTING,
        VideoClientState::Streaming => SLOPDESK_VIDEO_CLIENT_STREAMING,
        VideoClientState::Rejected => SLOPDESK_VIDEO_CLIENT_REJECTED,
        VideoClientState::Stopped => SLOPDESK_VIDEO_CLIENT_STOPPED,
    }
}

/// One code as its lifecycle state. An unknown code reads as idle, which is the only state from
/// which nothing has happened yet.
const fn state_of(code: u32) -> VideoClientState {
    match code {
        SLOPDESK_VIDEO_CLIENT_CONNECTING => VideoClientState::Connecting,
        SLOPDESK_VIDEO_CLIENT_STREAMING => VideoClientState::Streaming,
        SLOPDESK_VIDEO_CLIENT_REJECTED => VideoClientState::Rejected,
        SLOPDESK_VIDEO_CLIENT_STOPPED => VideoClientState::Stopped,
        _ => VideoClientState::Idle,
    }
}

/// The record for a crate size.
const fn size_record(size: VideoSize) -> SlopDeskVideoSize {
    SlopDeskVideoSize {
        width: size.width,
        height: size.height,
    }
}

/// The record for a crate rectangle.
const fn rect_record(rect: VideoRect) -> SlopDeskVideoRect {
    SlopDeskVideoRect {
        x: rect.origin.x,
        y: rect.origin.y,
        width: rect.size.width,
        height: rect.size.height,
    }
}

/// The record for one mask rectangle.
const fn mask_record(rect: MaskRect) -> SlopDeskVideoMaskRect {
    SlopDeskVideoMaskRect {
        x: rect.x,
        y: rect.y,
        width: rect.width,
        height: rect.height,
    }
}

#[cfg(test)]
#[expect(
    unsafe_code,
    clippy::indexing_slicing,
    clippy::panic,
    reason = "the tests call the C entry points, and a panic in a test is the failure report"
)]
mod tests {
    use slopdesk_video::geometry::VideoRect;
    use slopdesk_video::video_control::{MaskRect, VideoControlMessage};

    use super::{
        SLOPDESK_CLIENT_EFFECT_APPLY_CONTENT_MASK, SLOPDESK_CLIENT_EFFECT_PRIME_CURSOR_FLOW,
        SLOPDESK_CLIENT_EFFECT_SEND_CONTROL, SLOPDESK_CLIENT_EFFECT_SESSION_REJECTED_BY_HOST,
        SLOPDESK_CLIENT_EFFECT_START_DECODE_PIPELINE, SLOPDESK_SCRIM_HIDDEN, SLOPDESK_SCRIM_SHOWN,
        SLOPDESK_SCRIM_UNCHANGED, SLOPDESK_VIDEO_CLIENT_CONNECTING, SLOPDESK_VIDEO_CLIENT_REJECTED,
        SLOPDESK_VIDEO_CLIENT_STREAMING, SLOPDESK_VIDEO_TARGET_DISPLAY, SLOPDESK_VIDEO_TARGET_WINDOW,
        SlopDeskVideoClientEffect, SlopDeskVideoClientMachine, SlopDeskVideoMaskRect,
        slopdesk_stall_scrim_apply, slopdesk_stall_scrim_note_reconnecting,
        slopdesk_video_client_handle_control, slopdesk_video_client_hello_retry_delay,
        slopdesk_video_client_media_flowing, slopdesk_video_client_new,
        slopdesk_video_client_requested_window_id, slopdesk_video_client_start,
    };
    use crate::video_policy::{SLOPDESK_STREAM_LIVE, SLOPDESK_STREAM_STALLED, SlopDeskVideoSize};

    const VIEWPORT: SlopDeskVideoSize = SlopDeskVideoSize {
        width: 1440.0,
        height: 900.0,
    };

    /// Runs one transition with room for everything, answering the effects and the arena.
    fn stepped(
        machine: &mut SlopDeskVideoClientMachine,
        run: impl Fn(
            *mut SlopDeskVideoClientMachine,
            *mut SlopDeskVideoClientEffect,
            usize,
            *mut SlopDeskVideoMaskRect,
            usize,
            *mut u8,
            usize,
        ) -> super::SlopDeskVideoClientShape,
    ) -> (
        Vec<SlopDeskVideoClientEffect>,
        Vec<SlopDeskVideoMaskRect>,
        Vec<u8>,
    ) {
        let shape = run(
            machine,
            std::ptr::null_mut(),
            0,
            std::ptr::null_mut(),
            0,
            std::ptr::null_mut(),
            0,
        );
        let mut effects = vec![SlopDeskVideoClientEffect::default(); shape.effects];
        let mut masks = vec![SlopDeskVideoMaskRect::default(); shape.masks];
        let mut arena = vec![0_u8; shape.arena];
        let filled = run(
            machine,
            effects.as_mut_ptr(),
            effects.len(),
            masks.as_mut_ptr(),
            masks.len(),
            arena.as_mut_ptr(),
            arena.len(),
        );
        assert_eq!(filled, shape, "the measured shape is the one that fits");
        (effects, masks, arena)
    }

    #[test]
    fn a_measuring_call_leaves_the_machine_exactly_where_it_was() {
        let mut machine = slopdesk_video_client_new(SLOPDESK_VIDEO_TARGET_WINDOW, 42, VIEWPORT);
        let before = machine;
        let shape = unsafe {
            slopdesk_video_client_start(
                &raw mut machine,
                std::ptr::null_mut(),
                0,
                std::ptr::null_mut(),
                0,
                std::ptr::null_mut(),
                0,
            )
        };
        assert_eq!(shape.effects, 2, "the prime and the hello");
        assert_eq!(machine, before, "a call that did not fit is not a transition");
    }

    #[test]
    fn a_start_primes_the_cursor_and_sends_a_decodable_hello() {
        let mut machine = slopdesk_video_client_new(SLOPDESK_VIDEO_TARGET_WINDOW, 42, VIEWPORT);
        let (effects, _, arena) = stepped(
            &mut machine,
            |machine, out, cap, masks, mask_cap, arena, arena_cap| unsafe {
                slopdesk_video_client_start(machine, out, cap, masks, mask_cap, arena, arena_cap)
            },
        );
        assert_eq!(machine.state, SLOPDESK_VIDEO_CLIENT_CONNECTING);
        assert_eq!(effects[0].kind, SLOPDESK_CLIENT_EFFECT_PRIME_CURSOR_FLOW);
        assert_eq!(effects[1].kind, SLOPDESK_CLIENT_EFFECT_SEND_CONTROL);
        let span = effects[1].control;
        let bytes = &arena[span.offset as usize..(span.offset + span.length) as usize];
        let Ok(VideoControlMessage::Hello {
            requested_window_id, ..
        }) = VideoControlMessage::decode(bytes)
        else {
            panic!("the hello crosses as the bytes the runtime sends")
        };
        assert_eq!(requested_window_id, 42);
        assert_eq!(slopdesk_video_client_requested_window_id(machine), 42);
    }

    #[test]
    fn a_display_target_sends_the_display_hello_and_answers_no_window() {
        let mut machine = slopdesk_video_client_new(SLOPDESK_VIDEO_TARGET_DISPLAY, 7, VIEWPORT);
        let (effects, _, arena) = stepped(
            &mut machine,
            |machine, out, cap, masks, mask_cap, arena, arena_cap| unsafe {
                slopdesk_video_client_start(machine, out, cap, masks, mask_cap, arena, arena_cap)
            },
        );
        let span = effects[1].control;
        let bytes = &arena[span.offset as usize..(span.offset + span.length) as usize];
        assert!(matches!(
            VideoControlMessage::decode(bytes),
            Ok(VideoControlMessage::HelloDisplay { .. })
        ));
        assert_eq!(slopdesk_video_client_requested_window_id(machine), 0);
    }

    #[test]
    fn an_accepted_acknowledgement_starts_the_pipeline_at_the_negotiated_size() {
        let mut machine = slopdesk_video_client_new(SLOPDESK_VIDEO_TARGET_WINDOW, 42, VIEWPORT);
        stepped(
            &mut machine,
            |machine, out, cap, masks, mask_cap, arena, arena_cap| unsafe {
                slopdesk_video_client_start(machine, out, cap, masks, mask_cap, arena, arena_cap)
            },
        );
        let ack = VideoControlMessage::HelloAck {
            accepted: true,
            stream_id: 9,
            capture_width: 1280,
            capture_height: 720,
            window_bounds_cg: VideoRect::xywh(10.0, 20.0, 1280.0, 720.0),
            full_range: true,
        }
        .encode();
        let (effects, ..) = stepped(
            &mut machine,
            |machine, out, cap, masks, mask_cap, arena, arena_cap| unsafe {
                slopdesk_video_client_handle_control(
                    machine,
                    ack.as_ptr(),
                    ack.len(),
                    out,
                    cap,
                    masks,
                    mask_cap,
                    arena,
                    arena_cap,
                )
            },
        );
        assert_eq!(machine.state, SLOPDESK_VIDEO_CLIENT_STREAMING);
        assert_eq!(machine.stream_id, 9);
        assert!(slopdesk_video_client_media_flowing(machine));
        assert_eq!(effects[0].kind, SLOPDESK_CLIENT_EFFECT_START_DECODE_PIPELINE);
        assert!(effects[0].full_range);
        assert!((effects[0].size.width - 1280.0).abs() < 1e-12);
        assert!((effects[0].bounds.x - 10.0).abs() < 1e-12);
    }

    #[test]
    fn a_refusal_is_terminal_and_never_starts_a_pipeline() {
        let mut machine = slopdesk_video_client_new(SLOPDESK_VIDEO_TARGET_WINDOW, 42, VIEWPORT);
        stepped(
            &mut machine,
            |machine, out, cap, masks, mask_cap, arena, arena_cap| unsafe {
                slopdesk_video_client_start(machine, out, cap, masks, mask_cap, arena, arena_cap)
            },
        );
        let refusal = VideoControlMessage::HelloAck {
            accepted: false,
            stream_id: 0,
            capture_width: 0,
            capture_height: 0,
            window_bounds_cg: VideoRect::xywh(0.0, 0.0, 0.0, 0.0),
            full_range: false,
        }
        .encode();
        let (effects, ..) = stepped(
            &mut machine,
            |machine, out, cap, masks, mask_cap, arena, arena_cap| unsafe {
                slopdesk_video_client_handle_control(
                    machine,
                    refusal.as_ptr(),
                    refusal.len(),
                    out,
                    cap,
                    masks,
                    mask_cap,
                    arena,
                    arena_cap,
                )
            },
        );
        assert_eq!(machine.state, SLOPDESK_VIDEO_CLIENT_REJECTED);
        assert_eq!(effects[0].kind, SLOPDESK_CLIENT_EFFECT_SESSION_REJECTED_BY_HOST);
    }

    #[test]
    fn a_content_mask_crosses_as_a_run_of_the_lent_rectangles() {
        let mut machine = slopdesk_video_client_new(SLOPDESK_VIDEO_TARGET_WINDOW, 42, VIEWPORT);
        stepped(
            &mut machine,
            |machine, out, cap, masks, mask_cap, arena, arena_cap| unsafe {
                slopdesk_video_client_start(machine, out, cap, masks, mask_cap, arena, arena_cap)
            },
        );
        let ack = VideoControlMessage::HelloAck {
            accepted: true,
            stream_id: 1,
            capture_width: 640,
            capture_height: 480,
            window_bounds_cg: VideoRect::xywh(0.0, 0.0, 640.0, 480.0),
            full_range: false,
        }
        .encode();
        stepped(
            &mut machine,
            |machine, out, cap, masks, mask_cap, arena, arena_cap| unsafe {
                slopdesk_video_client_handle_control(
                    machine,
                    ack.as_ptr(),
                    ack.len(),
                    out,
                    cap,
                    masks,
                    mask_cap,
                    arena,
                    arena_cap,
                )
            },
        );
        let mask = VideoControlMessage::ContentMask(vec![
            MaskRect {
                x: 1,
                y: 2,
                width: 3,
                height: 4,
            },
            MaskRect {
                x: 5,
                y: 6,
                width: 7,
                height: 8,
            },
        ])
        .encode();
        let (effects, rects, _) = stepped(
            &mut machine,
            |machine, out, cap, masks, mask_cap, arena, arena_cap| unsafe {
                slopdesk_video_client_handle_control(
                    machine,
                    mask.as_ptr(),
                    mask.len(),
                    out,
                    cap,
                    masks,
                    mask_cap,
                    arena,
                    arena_cap,
                )
            },
        );
        assert_eq!(effects[0].kind, SLOPDESK_CLIENT_EFFECT_APPLY_CONTENT_MASK);
        assert_eq!(effects[0].mask_offset, 0);
        assert_eq!(effects[0].mask_count, 2);
        assert_eq!(rects[1].width, 7);
    }

    #[test]
    fn an_undecodable_datagram_is_inert() {
        let mut machine = slopdesk_video_client_new(SLOPDESK_VIDEO_TARGET_WINDOW, 42, VIEWPORT);
        let before = machine;
        let junk = [0xFF_u8, 0xFF, 0xFF];
        let shape = unsafe {
            slopdesk_video_client_handle_control(
                &raw mut machine,
                junk.as_ptr(),
                junk.len(),
                std::ptr::null_mut(),
                0,
                std::ptr::null_mut(),
                0,
                std::ptr::null_mut(),
                0,
            )
        };
        assert_eq!(shape.effects, 0);
        assert_eq!(machine, before);
    }

    #[test]
    fn the_retry_cadence_doubles_and_then_holds_at_the_ceiling() {
        assert!((slopdesk_video_client_hello_retry_delay(0) - 0.5).abs() < 1e-12);
        assert!((slopdesk_video_client_hello_retry_delay(2) - 2.0).abs() < 1e-12);
        assert!((slopdesk_video_client_hello_retry_delay(40) - 5.0).abs() < 1e-12);
    }

    #[test]
    fn the_scrim_is_sticky_until_a_live_verdict_takes_it_down() {
        let mut visible = false;
        assert_eq!(
            unsafe { slopdesk_stall_scrim_apply(&raw mut visible, SLOPDESK_STREAM_STALLED) },
            SLOPDESK_SCRIM_SHOWN
        );
        assert!(visible);
        assert_eq!(
            unsafe { slopdesk_stall_scrim_note_reconnecting(&raw mut visible) },
            SLOPDESK_SCRIM_UNCHANGED,
            "a duplicate farewell is quiet"
        );
        assert_eq!(
            unsafe { slopdesk_stall_scrim_apply(&raw mut visible, SLOPDESK_STREAM_LIVE) },
            SLOPDESK_SCRIM_HIDDEN
        );
        assert!(!visible);
    }
}
