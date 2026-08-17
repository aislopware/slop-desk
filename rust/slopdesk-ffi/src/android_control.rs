//! The scrcpy control channel's client end — everything the panel sends upstream.
//!
//! `slopdesk_androidd::control` owns every layout. This is the door.
//!
//! ## Why one door and not nine
//!
//! The nine encoders differ only in which fields they read, and every field is a scalar or one
//! string. Nine entry points would be nine §4 retries to write on the Swift side for a set of
//! messages that are all under 40 bytes — so the request crosses as ONE record with a `kind` tag,
//! and the tag is what selects the encoder. `crate::screen`'s door takes the same shape for the
//! same reason: the verb is a parameter, not a symbol.
//!
//! ## The one-way invariant crosses as a missing case, not as a comment
//!
//! `GET_CLIPBOARD` and the three `UHID_*` types have no `kind` here, exactly as they have no
//! variant in `slopdesk_androidd::control::Message`. A `kind` this build does not serve answers
//! `0`, and so does an unknown bodiless type byte — the refusal is the same one the type system
//! makes on the other side of the call.

use core::ffi::c_uchar;

use slopdesk_androidd::control::{Bodiless, KeyAction, Message, MotionAction};

use crate::{borrow, deliver};

/// [`SlopDeskAndroidControl::kind`] — `INJECT_TOUCH_EVENT`.
pub const ANDROID_CONTROL_TOUCH: u8 = 0;
/// `INJECT_SCROLL_EVENT`.
pub const ANDROID_CONTROL_SCROLL: u8 = 1;
/// `INJECT_KEYCODE`.
pub const ANDROID_CONTROL_KEY: u8 = 2;
/// `INJECT_TEXT`; the body is the `text` argument.
pub const ANDROID_CONTROL_TEXT: u8 = 3;
/// `SET_CLIPBOARD`, always with sequence zero; the body is the `text` argument.
pub const ANDROID_CONTROL_SET_CLIPBOARD: u8 = 4;
/// `BACK_OR_SCREEN_ON`.
pub const ANDROID_CONTROL_BACK_OR_SCREEN_ON: u8 = 5;
/// `SET_DISPLAY_POWER`.
pub const ANDROID_CONTROL_DISPLAY_POWER: u8 = 6;
/// `START_APP`; the body is the `text` argument.
pub const ANDROID_CONTROL_START_APP: u8 = 7;
/// A message that is its type byte alone; `bodiless_type` says which.
pub const ANDROID_CONTROL_BODILESS: u8 = 8;

/// Every field any encoder reads. Which ones are live is [`SlopDeskAndroidControl::kind`]'s answer.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct SlopDeskAndroidControl {
    /// One of the `ANDROID_CONTROL_*` constants.
    pub kind: u8,
    /// A `MotionEvent` action for a touch, a `KeyEvent` action for a key or a back press.
    pub action: u8,
    /// The type byte, for a bodiless message.
    pub bodiless_type: u8,
    /// `SET_CLIPBOARD`'s paste flag, or `SET_DISPLAY_POWER`'s on flag.
    pub flag: bool,
    /// Which contact a touch concerns.
    pub pointer_id: u64,
    /// Signed, because a drag legitimately leaves the frame.
    pub x: i32,
    /// Likewise signed.
    pub y: i32,
    /// The width the point was measured against.
    pub width: u16,
    /// The height the point was measured against.
    pub height: u16,
    /// A touch's pressure, `[0, 1]`.
    pub pressure: f32,
    /// A scroll's notches across.
    pub horizontal: f32,
    /// A scroll's notches down.
    pub vertical: f32,
    /// The button an action concerns.
    pub action_button: u32,
    /// Every button currently held.
    pub buttons: u32,
    /// Android's `KEYCODE_*`.
    pub keycode: u32,
    /// A key's auto-repeat count.
    pub repeat_count: u32,
    /// Android's `META_*` bits.
    pub meta_state: u32,
}

/// The bytes of one control message, under §4's convention.
///
/// `0` means REFUSED, which a real message's length can never be: every one is at least its type
/// byte. Four things are refused, and each is a message that must not reach the device — a `kind`
/// this build does not serve, an action byte naming no action, a bodiless type byte that is one of
/// the REPLY-BEARING types, and an empty text, clipboard or package name.
///
/// # Safety
/// `request` must point to one live record; `text` must be null or point to `text_len` live bytes;
/// `out` null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_android_control_encode(
    request: *const SlopDeskAndroidControl,
    text: *const c_uchar,
    text_len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    if request.is_null() {
        return 0;
    }
    // SAFETY: non-null and, by the caller's obligation, live and aligned for one record.
    let request = unsafe { *request };
    // SAFETY: the caller's obligation, restated above; `borrow` states its own.
    let body = unsafe { borrow(text, text_len) };
    // A body that is not UTF-8 cannot be a body — every one of the three is a length-prefixed
    // string the device decodes back.
    let Ok(body) = core::str::from_utf8(body) else {
        return 0;
    };
    let Some(message) = compose(&request, body) else {
        return 0;
    };
    let Some(bytes) = message.encode() else {
        return 0;
    };
    // SAFETY: the caller's obligation, restated above; `deliver` states its own.
    unsafe { deliver(&bytes, out, cap) }
}

/// The record and its body as the message they name, or `None` for one that must not be sent.
fn compose<'a>(request: &SlopDeskAndroidControl, body: &'a str) -> Option<Message<'a>> {
    Some(match request.kind {
        ANDROID_CONTROL_TOUCH => {
            Message::Touch {
                action: MotionAction::from_byte(request.action)?,
                pointer_id: request.pointer_id,
                x: request.x,
                y: request.y,
                width: request.width,
                height: request.height,
                pressure: request.pressure,
                action_button: request.action_button,
                buttons: request.buttons,
            }
        },
        ANDROID_CONTROL_SCROLL => {
            Message::Scroll {
                x: request.x,
                y: request.y,
                width: request.width,
                height: request.height,
                horizontal: request.horizontal,
                vertical: request.vertical,
                buttons: request.buttons,
            }
        },
        ANDROID_CONTROL_KEY => {
            Message::Key {
                action: KeyAction::from_byte(request.action)?,
                keycode: request.keycode,
                repeat_count: request.repeat_count,
                meta_state: request.meta_state,
            }
        },
        ANDROID_CONTROL_TEXT => Message::Text(body),
        ANDROID_CONTROL_SET_CLIPBOARD => {
            Message::SetClipboard {
                text: body,
                paste: request.flag,
            }
        },
        ANDROID_CONTROL_BACK_OR_SCREEN_ON => Message::BackOrScreenOn(KeyAction::from_byte(request.action)?),
        ANDROID_CONTROL_DISPLAY_POWER => Message::DisplayPower(request.flag),
        ANDROID_CONTROL_START_APP => Message::StartApp(body),
        // A reply-bearing type has no member to name, so this is where GET_CLIPBOARD and UHID_*
        // are refused rather than encoded.
        ANDROID_CONTROL_BODILESS => Message::Bodiless(Bodiless::from_type_byte(request.bodiless_type)?),
        _unknown => return None,
    })
}

#[cfg(test)]
#[expect(
    unsafe_code,
    clippy::indexing_slicing,
    reason = "calling the boundary IS what these tests are for, and a fixed offset into a message the test \
              just built is the assertion"
)]
mod tests {
    use super::{
        ANDROID_CONTROL_BODILESS, ANDROID_CONTROL_SET_CLIPBOARD, ANDROID_CONTROL_TEXT, ANDROID_CONTROL_TOUCH,
        SlopDeskAndroidControl, slopdesk_android_control_encode,
    };

    /// Measures, then fills, and hands back the bytes.
    fn encode(request: &SlopDeskAndroidControl, text: &str) -> Vec<u8> {
        let body = text.as_bytes();
        // SAFETY: the record and the body are live locals; a null `out` with `cap` 0 measures.
        let needed = unsafe {
            slopdesk_android_control_encode(request, body.as_ptr(), body.len(), core::ptr::null_mut(), 0)
        };
        if needed == 0 {
            return Vec::new();
        }
        let mut out = vec![0_u8; needed];
        // SAFETY: every buffer is a live local.
        let written = unsafe {
            slopdesk_android_control_encode(request, body.as_ptr(), body.len(), out.as_mut_ptr(), out.len())
        };
        assert_eq!(
            written, needed,
            "the second call fills exactly what the first measured"
        );
        out
    }

    /// Every scalar reaches its field in the right order — the one thing a mis-laid `repr(C)`
    /// record or a swapped assignment would break, and the daemon's own suite cannot see.
    #[test]
    fn a_touch_records_fields_reach_the_wire_in_order() {
        let request = SlopDeskAndroidControl {
            kind: ANDROID_CONTROL_TOUCH,
            action: 0,
            pointer_id: u64::MAX - 1,
            x: 0x0102_0304,
            y: -2,
            width: 0x0506,
            height: 0x0708,
            pressure: 1.0,
            action_button: 1,
            buttons: 1,
            ..SlopDeskAndroidControl::default()
        };
        assert_eq!(encode(&request, ""), vec![
            2, 0, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFE, 0x01, 0x02, 0x03, 0x04, 0xFF, 0xFF, 0xFF,
            0xFE, 0x05, 0x06, 0x07, 0x08, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        ]);
    }

    /// The body argument reaches the encoder, and an empty one is refused rather than sent.
    #[test]
    fn a_body_crosses_and_an_empty_one_is_refused() {
        let request = SlopDeskAndroidControl {
            kind: ANDROID_CONTROL_TEXT,
            ..SlopDeskAndroidControl::default()
        };
        assert_eq!(encode(&request, "hi"), vec![1, 0, 0, 0, 2, b'h', b'i']);
        assert_eq!(encode(&request, ""), Vec::<u8>::new());
    }

    /// The clipboard's sequence is zero across the door too, which is the invariant that keeps one
    /// full-duplex connection sound.
    #[test]
    fn a_clipboard_message_still_asks_for_no_acknowledgement() {
        let request = SlopDeskAndroidControl {
            kind: ANDROID_CONTROL_SET_CLIPBOARD,
            flag: true,
            ..SlopDeskAndroidControl::default()
        };
        let bytes = encode(&request, "x");
        assert_eq!(&bytes[..9], &[9, 0, 0, 0, 0, 0, 0, 0, 0]);
    }

    /// Every reply-bearing type is refused at the door, not merely absent from the Swift API.
    #[test]
    fn a_reply_bearing_type_cannot_be_asked_for() {
        for reply_bearing in [8_u8, 12, 13, 14] {
            let request = SlopDeskAndroidControl {
                kind: ANDROID_CONTROL_BODILESS,
                bodiless_type: reply_bearing,
                ..SlopDeskAndroidControl::default()
            };
            assert_eq!(encode(&request, ""), Vec::<u8>::new(), "type {reply_bearing}");
        }
        let rotate = SlopDeskAndroidControl {
            kind: ANDROID_CONTROL_BODILESS,
            bodiless_type: 11,
            ..SlopDeskAndroidControl::default()
        };
        assert_eq!(encode(&rotate, ""), vec![11], "and a safe one still encodes");
    }

    /// A kind this build does not serve, and an action byte naming no action, are both `0`.
    #[test]
    fn an_unknown_kind_or_action_is_refused() {
        let unknown = SlopDeskAndroidControl {
            kind: 99,
            ..SlopDeskAndroidControl::default()
        };
        assert_eq!(encode(&unknown, ""), Vec::<u8>::new());

        let outside = SlopDeskAndroidControl {
            kind: ANDROID_CONTROL_TOUCH,
            action: 4, // ACTION_OUTSIDE, which the panel never sends
            ..SlopDeskAndroidControl::default()
        };
        assert_eq!(encode(&outside, ""), Vec::<u8>::new());
    }

    /// Null is refused rather than dereferenced.
    #[test]
    fn a_null_request_is_refused() {
        // SAFETY: null is the documented refusal.
        let answer = unsafe {
            slopdesk_android_control_encode(core::ptr::null(), core::ptr::null(), 0, core::ptr::null_mut(), 0)
        };
        assert_eq!(answer, 0);
    }
}
