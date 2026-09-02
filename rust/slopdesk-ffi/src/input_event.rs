//! Client→host input events — `Sources/SlopDeskVideoProtocol/InputEventCodec.swift`.
//!
//! Every pointer move, click, drag, scroll tick and keystroke the user aims at a remote window
//! arrives here first. The host decodes it off an unauthenticated UDP socket and then POSTS it into
//! the window server, which makes this the shortest path in the system from a hostile datagram to a
//! system call — a NaN coordinate reaching the injector is a trapping `Int32(Double)` and a dead
//! host, and that is why the finite check is a decode guard rather than a caller's manners.
//!
//! ## One flat struct, not a tagged union
//!
//! Seven wire types share one `#[repr(C)]` value with `message_type` saying which fields mean
//! anything. A C union would have to be kept in step with the Rust enum by hand on both sides,
//! which is the drift this port removes; a struct with unread fields costs a few bytes of stack per
//! event and nothing else.
//!
//! ## The text arm answers an OFFSET
//!
//! Typed text is the rest of the datagram, and the caller is holding the datagram. Its bytes are
//! validated as UTF-8 here — a `.text` that is not valid UTF-8 is malformed, not lossy — so the
//! caller may build its string from the span without checking again.

use core::ffi::c_uchar;

use slopdesk_video::error::VideoProtocolError;
use slopdesk_video::geometry::VideoPoint;
use slopdesk_video::input_event::{
    InputEvent, InputModifiers, KeyEvent, MouseButton, MouseButtonEvent, ScrollEvent, modifier_keys,
};

use crate::{borrow, deliver};

/// The datagram parsed.
pub const INPUT_DECODE_OK: u32 = 0;
/// The datagram ended mid-field.
pub const INPUT_DECODE_TRUNCATED: u32 = 1;
/// The datagram was well-sized and unacceptable: an unknown type or button, a non-finite
/// coordinate, or text that is not UTF-8.
pub const INPUT_DECODE_MALFORMED: u32 = 2;

/// One input event, flat, in the layout Swift reads straight through.
///
/// Which fields carry meaning follows from `message_type`: 1 move, 2 down, 3 up, 4 scroll, 5 key,
/// 6 text, 7 drag. The rest are left at zero rather than undefined, so an arm that reads one it
/// should not gets a zero and not a stale event's value.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct SlopDeskInputEvent {
    /// Normalised window x, in 0..1 — moves, buttons, drags and scrolls.
    pub x: f64,
    /// Normalised window y, in 0..1.
    pub y: f64,
    /// Scroll delta x, in pixel units.
    pub dx: f64,
    /// Scroll delta y, in pixel units.
    pub dy: f64,
    /// The value the host stamps on `eventSourceUserData` to filter its own injections back out.
    pub tag: u32,
    /// The virtual key code, for the key arm.
    pub key_code: u16,
    /// Which wire type this is.
    pub message_type: u8,
    /// 0 left, 1 right, 2 other.
    pub button: u8,
    /// The originating click count, carried on drags so selection engines see the down's state.
    pub click_count: u8,
    /// The modifier bitmask.
    pub modifiers: u8,
    /// Trackpad gesture phase.
    pub scroll_phase: u8,
    /// Trackpad momentum phase.
    pub momentum_phase: u8,
    /// Whether the scroll is continuous (a trackpad) rather than a wheel's detents.
    pub continuous: bool,
    /// Whether the key went down.
    pub down: bool,
    /// Whether the key edge is a held-key autorepeat.
    pub autorepeat: bool,
    /// Where the UTF-8 text starts in the datagram, for the text arm. 0 everywhere else.
    pub text_offset: u8,
}

/// Parses one input-event datagram.
///
/// Answers a VERDICT rather than a bool: the caller has two failure cases and collapsing a short
/// datagram into a hostile one would lose the distinction its own error type keeps.
///
/// # Safety
/// `bytes` must be null or point to `len` readable bytes, and `out` must be null or point to one
/// writable, aligned [`SlopDeskInputEvent`], both for the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_input_event_decode(
    bytes: *const c_uchar,
    len: usize,
    out: *mut SlopDeskInputEvent,
) -> u32 {
    // SAFETY: the caller's obligation, discharged by Swift's `withUnsafeBytes`.
    let datagram = unsafe { borrow(bytes, len) };
    let parsed = match InputEvent::decode(datagram) {
        Ok(event) => event,
        Err(VideoProtocolError::Truncated) => return INPUT_DECODE_TRUNCATED,
        Err(_) => return INPUT_DECODE_MALFORMED,
    };
    if out.is_null() {
        return INPUT_DECODE_OK;
    }
    // SAFETY: non-null and, by the caller's obligation, one writable, aligned event.
    unsafe { out.write(flatten(&parsed)) };
    INPUT_DECODE_OK
}

/// The event flattened into the record it crosses as — the exact inverse of [`rebuild`], but for
/// the text arm, whose bytes stay in the caller's datagram and are named by an OFFSET instead.
pub(crate) fn flatten(event: &InputEvent) -> SlopDeskInputEvent {
    let mut flat = SlopDeskInputEvent {
        message_type: event.message_type(),
        tag: event.tag(),
        ..SlopDeskInputEvent::default()
    };
    match *event {
        InputEvent::MouseMove { normalized, .. } => {
            flat.x = normalized.x;
            flat.y = normalized.y;
        },
        InputEvent::MouseDown(event, _) | InputEvent::MouseUp(event, _) | InputEvent::MouseDrag(event, _) => {
            flat.x = event.normalized.x;
            flat.y = event.normalized.y;
            flat.button = event.button.raw_value();
            flat.click_count = event.click_count;
            flat.modifiers = event.modifiers.bits();
        },
        InputEvent::Scroll(event, _) => {
            flat.x = event.normalized.x;
            flat.y = event.normalized.y;
            flat.dx = event.dx;
            flat.dy = event.dy;
            flat.scroll_phase = event.scroll_phase;
            flat.momentum_phase = event.momentum_phase;
            flat.continuous = event.continuous;
            flat.modifiers = event.modifiers.bits();
        },
        InputEvent::Key(event, _) => {
            flat.key_code = event.key_code;
            flat.down = event.down;
            flat.autorepeat = event.repeat;
            flat.modifiers = event.modifiers.bits();
        },
        // The text stays in the caller's datagram: it starts after the type byte and the tag, and
        // decode already proved every byte of it is UTF-8.
        InputEvent::Text(..) => flat.text_offset = TEXT_OFFSET,
    }
    flat
}

/// Serialises one input event. The text arm takes its bytes through `text`; every other arm ignores
/// them. Returns bytes NEEDED, under §4's convention.
///
/// A `message_type` no arm answers to, or a `button` outside 0..2, writes nothing and returns 0 —
/// the same answer an empty encode would give, and there is no such thing as an empty event.
///
/// # Safety
/// `text` must be null or point to `text_len` readable bytes, and `out` must be null or point to
/// `cap` writable bytes, both for the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_input_event_encode(
    event: SlopDeskInputEvent,
    text: *const c_uchar,
    text_len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, discharged by Swift's `withUnsafeBytes`.
    let text_bytes = unsafe { borrow(text, text_len) };
    let Some(rebuilt) = rebuild(event, text_bytes) else {
        return 0;
    };
    let datagram = rebuilt.encode();
    // SAFETY: the caller's obligation on `out`, discharged by Swift's `withUnsafeMutableBytes`.
    unsafe { deliver(&datagram, out, cap) }
}

/// Where the text arm's bytes begin: the type byte plus the tag.
const TEXT_OFFSET: u8 = 5;

/// The flat value back into the event it describes, or `None` for a shape no arm answers to.
pub(crate) fn rebuild(event: SlopDeskInputEvent, text: &[u8]) -> Option<InputEvent> {
    let normalized = VideoPoint::new(event.x, event.y);
    let modifiers = InputModifiers::from_bits(event.modifiers);
    let button = || {
        MouseButton::from_raw(event.button).map(|button| {
            MouseButtonEvent {
                button,
                normalized,
                click_count: event.click_count,
                modifiers,
            }
        })
    };
    match event.message_type {
        1 => {
            Some(InputEvent::MouseMove {
                normalized,
                tag: event.tag,
            })
        },
        2 => Some(InputEvent::MouseDown(button()?, event.tag)),
        3 => Some(InputEvent::MouseUp(button()?, event.tag)),
        7 => Some(InputEvent::MouseDrag(button()?, event.tag)),
        4 => {
            Some(InputEvent::Scroll(
                ScrollEvent {
                    dx: event.dx,
                    dy: event.dy,
                    normalized,
                    scroll_phase: event.scroll_phase,
                    momentum_phase: event.momentum_phase,
                    continuous: event.continuous,
                    modifiers,
                },
                event.tag,
            ))
        },
        5 => {
            Some(InputEvent::Key(
                KeyEvent {
                    key_code: event.key_code,
                    down: event.down,
                    repeat: event.autorepeat,
                    modifiers,
                },
                event.tag,
            ))
        },
        6 => {
            Some(InputEvent::Text(
                String::from_utf8(text.to_vec()).ok()?,
                event.tag,
            ))
        },
        _ => None,
    }
}

/// The one number a caller would otherwise spell twice: where the text arm's payload starts.
///
/// `index` selects — 0 that offset. An index with no constant behind it answers 0.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub const extern "C" fn slopdesk_input_event_constant(index: u8) -> u8 {
    match index {
        0 => TEXT_OFFSET,
        _ => 0,
    }
}

/// The held-modifier keycodes, in table order — the bit order the balance masks use.
///
/// Left and right are DISTINCT keys with distinct latched flags, so a policy keys on the exact
/// code. Caps lock is deliberately absent: it is a toggle whose state would desync from the host's
/// actual one if it were tracked by edge, so it is never held and never deduplicated.
///
/// Returns the count NEEDED under §4; nothing is written when that exceeds `cap`.
///
/// # Safety
/// `out` must be null or point to `cap` writable `u16`s for the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub const unsafe extern "C" fn slopdesk_input_modifier_key_codes(out: *mut u16, cap: usize) -> usize {
    let codes = modifier_keys::HELD_MODIFIER_KEY_CODES;
    if out.is_null() || codes.len() > cap {
        return codes.len();
    }
    // SAFETY: `codes.len() <= cap` was just checked, `out` is non-null and writable for `cap`
    // entries by the caller's obligation, and `codes` is a static that cannot overlap it.
    unsafe { core::ptr::copy_nonoverlapping(codes.as_ptr(), out, codes.len()) };
    codes.len()
}

/// The caps-lock keycode — the one key every held-modifier policy must skip.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub const extern "C" fn slopdesk_input_caps_lock_key_code() -> u16 {
    modifier_keys::CAPS_LOCK_KEY_CODE
}

#[cfg(test)]
#[expect(
    unsafe_code,
    clippy::indexing_slicing,
    reason = "the tests call the C entry points, and these floats are exact wire constants"
)]
mod tests {
    use super::{
        INPUT_DECODE_MALFORMED, INPUT_DECODE_OK, INPUT_DECODE_TRUNCATED, SlopDeskInputEvent,
        slopdesk_input_event_constant, slopdesk_input_event_decode, slopdesk_input_event_encode,
    };

    fn round_trip(event: SlopDeskInputEvent, text: &[u8]) -> (SlopDeskInputEvent, Vec<u8>) {
        let needed = unsafe {
            slopdesk_input_event_encode(event, text.as_ptr(), text.len(), core::ptr::null_mut(), 0)
        };
        let mut wire = vec![0_u8; needed];
        let written = unsafe {
            slopdesk_input_event_encode(event, text.as_ptr(), text.len(), wire.as_mut_ptr(), wire.len())
        };
        assert_eq!(written, needed);
        let mut back = SlopDeskInputEvent::default();
        let verdict = unsafe { slopdesk_input_event_decode(wire.as_ptr(), wire.len(), &raw mut back) };
        assert_eq!(verdict, INPUT_DECODE_OK);
        (back, wire)
    }

    #[test]
    fn a_drag_carries_its_button_click_count_and_position_back() {
        let event = SlopDeskInputEvent {
            x: 0.25,
            y: 0.75,
            tag: 99,
            message_type: 7,
            button: 1,
            click_count: 2,
            modifiers: 0b1010,
            ..SlopDeskInputEvent::default()
        };
        let (back, _wire) = round_trip(event, &[]);
        assert_eq!(back, event);
    }

    #[test]
    fn a_scroll_carries_both_deltas_and_both_phases() {
        let event = SlopDeskInputEvent {
            x: 0.5,
            y: 0.5,
            dx: -3.5,
            dy: 12.25,
            tag: 7,
            message_type: 4,
            scroll_phase: 2,
            momentum_phase: 1,
            continuous: true,
            modifiers: 0b1000,
            ..SlopDeskInputEvent::default()
        };
        let (back, _wire) = round_trip(event, &[]);
        assert_eq!(back, event);
    }

    #[test]
    fn a_key_carries_its_autorepeat_bit() {
        let event = SlopDeskInputEvent {
            tag: 3,
            message_type: 5,
            key_code: 0x35,
            down: true,
            autorepeat: true,
            modifiers: 0b0100,
            ..SlopDeskInputEvent::default()
        };
        let (back, wire) = round_trip(event, &[]);
        assert_eq!(back, event);
        assert_eq!(wire.get(7), Some(&0b11), "bit 0 down, bit 1 repeat");
    }

    #[test]
    fn text_is_left_in_the_datagram_at_the_offset_the_codec_reports() {
        let event = SlopDeskInputEvent {
            tag: 5,
            message_type: 6,
            ..SlopDeskInputEvent::default()
        };
        let (back, wire) = round_trip(event, "hé".as_bytes());
        assert_eq!(back.text_offset, slopdesk_input_event_constant(0));
        assert_eq!(&wire[usize::from(back.text_offset)..], "hé".as_bytes());
    }

    #[test]
    fn a_non_finite_coordinate_is_malformed_and_a_short_body_is_truncated() {
        let event = SlopDeskInputEvent {
            x: f64::NAN,
            message_type: 1,
            ..SlopDeskInputEvent::default()
        };
        let mut wire = vec![0_u8; 21];
        let written = unsafe {
            slopdesk_input_event_encode(event, core::ptr::null(), 0, wire.as_mut_ptr(), wire.len())
        };
        assert_eq!(written, 21);
        let mut back = SlopDeskInputEvent::default();
        let hostile = unsafe { slopdesk_input_event_decode(wire.as_ptr(), written, &raw mut back) };
        assert_eq!(hostile, INPUT_DECODE_MALFORMED);
        assert_eq!(back, SlopDeskInputEvent::default());
        let short = unsafe { slopdesk_input_event_decode(wire.as_ptr(), 3, &raw mut back) };
        assert_eq!(short, INPUT_DECODE_TRUNCATED);
    }

    #[test]
    fn a_type_no_arm_answers_to_encodes_to_nothing() {
        let event = SlopDeskInputEvent {
            message_type: 9,
            ..SlopDeskInputEvent::default()
        };
        let written =
            unsafe { slopdesk_input_event_encode(event, core::ptr::null(), 0, core::ptr::null_mut(), 0) };
        assert_eq!(written, 0);
        let bad_button = SlopDeskInputEvent {
            message_type: 2,
            button: 9,
            ..SlopDeskInputEvent::default()
        };
        let refused = unsafe {
            slopdesk_input_event_encode(bad_button, core::ptr::null(), 0, core::ptr::null_mut(), 0)
        };
        assert_eq!(refused, 0);
    }
}
