//! The scrcpy control channel's CLIENT end — everything the panel sends upstream.
//!
//! `scrcpy` publishes no wire specification; its own documentation says the control protocol is
//! defined by the unit tests on both sides. So this is a transcription of `app/src/control_msg.c`
//! at v4.1, and the tests below are our half of that agreement: a version bump that silently
//! reorders a field fails here rather than as a device that responds to taps in the wrong place.
//!
//! [`crate::stream`]'s sibling. Same wire, same crate, opposite direction.
//!
//! ## The one-way invariant, enforced by the TYPE rather than by a comment
//!
//! The host bridge gives the client ONE full-duplex connection — video down, control up — which is
//! only sound while the control channel is strictly one-way. `scrcpy`'s server has exactly three
//! device→client messages and every one is a REPLY: to a `GET_CLIPBOARD`, to a `SET_CLIPBOARD`
//! carrying a non-zero sequence, or to UHID. Send one of those and the device writes a clipboard
//! message into a stream the client is parsing as H.264.
//!
//! `GET_CLIPBOARD` and the three `UHID_*` messages therefore have no variant in [`Message`] and no
//! member in [`Bodiless`]. They are not omitted, they are UNREPRESENTABLE — the Swift original
//! could only say so in prose, and prose is not what stops the next encoder being added. The
//! sequence on [`Message::SetClipboard`] is likewise not a parameter: it is the constant zero.
//!
//! ## Nothing here waits
//!
//! `docs/47` records that the SIMULATOR server's upstream verbs differ by three orders of
//! magnitude, and that a scroll built on the expensive one accrued seconds of lag per second of
//! use. That hazard is structurally absent here: `scrcpy` has no compound gesture verbs — a gesture
//! is down/move/up and nothing else — and no message is acknowledged, so the client never blocks.
//! Measured 2026-08-04, 202 touch messages left the client in 1.0 ms total. The lesson survives as
//! a rule: nothing upstream may ever be written as a request that expects a reply.

/// `enum sc_control_msg_type`, in declaration order, for the types this end may send.
mod kind {
    pub(super) const INJECT_KEYCODE: u8 = 0;
    pub(super) const INJECT_TEXT: u8 = 1;
    pub(super) const INJECT_TOUCH_EVENT: u8 = 2;
    pub(super) const INJECT_SCROLL_EVENT: u8 = 3;
    pub(super) const BACK_OR_SCREEN_ON: u8 = 4;
    // 5 = EXPAND_NOTIFICATION_PANEL, 6 = EXPAND_SETTINGS_PANEL — never sent; the panel reaches the
    // shade through the notification KEYCODE instead, which needs no control channel round trip.
    pub(super) const COLLAPSE_PANELS: u8 = 7;
    // 8 = GET_CLIPBOARD — never sent; see the module comment.
    pub(super) const SET_CLIPBOARD: u8 = 9;
    pub(super) const SET_DISPLAY_POWER: u8 = 10;
    pub(super) const ROTATE_DEVICE: u8 = 11;
    // 12..=14 = UHID_* — never sent; see the module comment.
    pub(super) const OPEN_HARD_KEYBOARD_SETTINGS: u8 = 15;
    pub(super) const START_APP: u8 = 16;
    pub(super) const RESET_VIDEO: u8 = 17;
}

/// `SC_POINTER_ID_GENERIC_FINGER`.
///
/// The panel injects FINGERS, not a mouse: Android's gesture recognisers, its scrollers and its
/// fling physics are all built for touch, and a mouse pointer id makes a drag arrive as a hover in
/// views that distinguish them.
pub const FINGER_POINTER_ID: u64 = u64::MAX - 1;
/// `SC_POINTER_ID_VIRTUAL_FINGER` — the second contact of a pinch.
pub const VIRTUAL_FINGER_POINTER_ID: u64 = u64::MAX - 2;

/// The server's own ceiling on an `INJECT_TEXT` body.
pub const MAX_TEXT: usize = 300;
/// The ceiling on a `SET_CLIPBOARD` body.
pub const MAX_CLIPBOARD: usize = 200_000;
/// `START_APP` carries a ONE-byte length prefix, so the name cannot exceed what it can count.
pub const MAX_PACKAGE: usize = 255;

/// Android's `MotionEvent` actions, as the server passes them to `InputManager`.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
#[repr(u8)]
pub enum MotionAction {
    /// `ACTION_DOWN`.
    Down = 0,
    /// `ACTION_UP`.
    Up = 1,
    /// `ACTION_MOVE`.
    Move = 2,
    /// `ACTION_CANCEL`.
    Cancel = 3,
    // 4 is `ACTION_OUTSIDE`, which the panel never sends.
    /// `ACTION_POINTER_DOWN` — the pinch's second contact.
    PointerDown = 5,
    /// `ACTION_POINTER_UP`.
    PointerUp = 6,
    /// `ACTION_HOVER_MOVE`.
    HoverMove = 7,
    /// `ACTION_SCROLL`.
    Scroll = 8,
}

impl MotionAction {
    /// The action a byte names, or `None` for one the panel does not send.
    #[must_use]
    pub const fn from_byte(byte: u8) -> Option<Self> {
        match byte {
            0 => Some(Self::Down),
            1 => Some(Self::Up),
            2 => Some(Self::Move),
            3 => Some(Self::Cancel),
            5 => Some(Self::PointerDown),
            6 => Some(Self::PointerUp),
            7 => Some(Self::HoverMove),
            8 => Some(Self::Scroll),
            _ => None,
        }
    }
}

/// Android's `KeyEvent` actions.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
#[repr(u8)]
pub enum KeyAction {
    /// `ACTION_DOWN`.
    Down = 0,
    /// `ACTION_UP`.
    Up = 1,
}

impl KeyAction {
    /// The action a byte names.
    #[must_use]
    pub const fn from_byte(byte: u8) -> Option<Self> {
        match byte {
            0 => Some(Self::Down),
            1 => Some(Self::Up),
            _ => None,
        }
    }
}

/// The messages that are their type byte and nothing else.
///
/// A closed set on purpose: `GET_CLIPBOARD` and `UHID_*` are bodiless too, and this is where they
/// would otherwise be easiest to add without noticing what that costs.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Bodiless {
    /// Collapses the notification shade and the quick settings.
    CollapsePanels,
    /// Asks the device to rotate.
    RotateDevice,
    /// Opens the system's hardware-keyboard settings.
    OpenHardKeyboardSettings,
    /// Asks the server to send a fresh keyframe and configuration.
    ResetVideo,
}

impl Bodiless {
    const fn type_byte(self) -> u8 {
        match self {
            Self::CollapsePanels => kind::COLLAPSE_PANELS,
            Self::RotateDevice => kind::ROTATE_DEVICE,
            Self::OpenHardKeyboardSettings => kind::OPEN_HARD_KEYBOARD_SETTINGS,
            Self::ResetVideo => kind::RESET_VIDEO,
        }
    }

    /// The bodiless message a type byte names, or `None` — which is what every reply-bearing type
    /// gets, by having no member here to name.
    #[must_use]
    pub const fn from_type_byte(byte: u8) -> Option<Self> {
        match byte {
            kind::COLLAPSE_PANELS => Some(Self::CollapsePanels),
            kind::ROTATE_DEVICE => Some(Self::RotateDevice),
            kind::OPEN_HARD_KEYBOARD_SETTINGS => Some(Self::OpenHardKeyboardSettings),
            kind::RESET_VIDEO => Some(Self::ResetVideo),
            _ => None,
        }
    }
}

/// One thing the panel sends upstream.
#[derive(Clone, Copy, PartialEq, Debug)]
pub enum Message<'a> {
    /// `INJECT_TOUCH_EVENT` — 32 bytes, the panel's whole pointer path.
    ///
    /// The coordinates are in the SCREEN SIZE reported alongside them and the server rescales, so
    /// the panel never needs the device's true resolution to place a touch — it reports the size of
    /// the frame it measured the gesture against.
    Touch {
        /// The `MotionEvent` action.
        action: MotionAction,
        /// Which contact; see [`FINGER_POINTER_ID`].
        pointer_id: u64,
        /// Signed, because a drag legitimately leaves the frame.
        x: i32,
        /// Likewise signed.
        y: i32,
        /// The width the point was measured against.
        width: u16,
        /// The height the point was measured against.
        height: u16,
        /// `[0, 1]`, saturating.
        pressure: f32,
        /// The button this action concerns.
        action_button: u32,
        /// Every button currently held.
        buttons: u32,
    },
    /// `INJECT_SCROLL_EVENT` — 21 bytes.
    ///
    /// Present but NOT what the panel's trackpad scrolling uses: Android delivers this as a
    /// `MotionEvent` with `ACTION_SCROLL`, which a `RecyclerView` handles as a discrete wheel notch
    /// — no kinetics, no over-scroll — while a dragged finger gets the real thing. Kept for a
    /// genuine wheel with no phase information.
    Scroll {
        /// Where the wheel turned.
        x: i32,
        /// Likewise.
        y: i32,
        /// The width it was measured against.
        width: u16,
        /// The height it was measured against.
        height: u16,
        /// Notches across; the wire's own scale is `[-16, 16]`.
        horizontal: f32,
        /// Notches down.
        vertical: f32,
        /// Every button currently held.
        buttons: u32,
    },
    /// `INJECT_KEYCODE` — 14 bytes.
    Key {
        /// Down or up; a bare press is both.
        action: KeyAction,
        /// Android's `KEYCODE_*`.
        keycode: u32,
        /// Auto-repeat count.
        repeat_count: u32,
        /// Android's `META_*` bits.
        meta_state: u32,
    },
    /// `INJECT_TEXT` — a four-byte length prefix and UTF-8, cut at [`MAX_TEXT`].
    Text(&'a str),
    /// `SET_CLIPBOARD`, cut at [`MAX_CLIPBOARD`].
    ///
    /// The sequence is not a field here because it is always zero: a non-zero sequence asks the
    /// device to acknowledge, and an acknowledgement is a device message on a channel that must
    /// stay one-way.
    SetClipboard {
        /// What to put on the device's clipboard.
        text: &'a str,
        /// Whether to paste it immediately afterwards.
        paste: bool,
    },
    /// `BACK_OR_SCREEN_ON` — Back when the screen is on, wake when it is not, which is what the
    /// hardware key does and what anyone pressing the toolbar's Back means.
    BackOrScreenOn(KeyAction),
    /// `SET_DISPLAY_POWER` — the DEVICE's backlight, not the stream. The mirror keeps running.
    DisplayPower(bool),
    /// `START_APP` — a ONE-byte length prefix, not four. A `+` prefix on the name asks the server
    /// to force-stop it first.
    StartApp(&'a str),
    /// A message that is its type byte alone.
    Bodiless(Bodiless),
}

impl Message<'_> {
    /// The bytes this message is on the wire.
    ///
    /// `None` where there is nothing to send: an empty text, clipboard or package name. Truncation
    /// is not a refusal — the server has its own ceilings and a cut string is still a message —
    /// but an EMPTY one would ask the device to type nothing, which is a message worth not sending.
    #[must_use]
    pub fn encode(&self) -> Option<Vec<u8>> {
        match *self {
            Self::Touch {
                action,
                pointer_id,
                x,
                y,
                width,
                height,
                pressure,
                action_button,
                buttons,
            } => {
                let mut out = Vec::with_capacity(32);
                out.push(kind::INJECT_TOUCH_EVENT);
                out.push(action as u8);
                out.extend_from_slice(&pointer_id.to_be_bytes());
                write_position(&mut out, x, y, width, height);
                out.extend_from_slice(&unsigned_fixed_point(pressure).to_be_bytes());
                out.extend_from_slice(&action_button.to_be_bytes());
                out.extend_from_slice(&buttons.to_be_bytes());
                Some(out)
            },
            Self::Scroll {
                x,
                y,
                width,
                height,
                horizontal,
                vertical,
                buttons,
            } => {
                let mut out = Vec::with_capacity(21);
                out.push(kind::INJECT_SCROLL_EVENT);
                write_position(&mut out, x, y, width, height);
                // The wire carries [-1, 1]; the protocol's own scale is [-16, 16] notches, so a
                // value that skipped this division would saturate on a single click.
                out.extend_from_slice(&signed_fixed_point(horizontal / 16.0).to_be_bytes());
                out.extend_from_slice(&signed_fixed_point(vertical / 16.0).to_be_bytes());
                out.extend_from_slice(&buttons.to_be_bytes());
                Some(out)
            },
            Self::Key {
                action,
                keycode,
                repeat_count,
                meta_state,
            } => {
                let mut out = Vec::with_capacity(14);
                out.push(kind::INJECT_KEYCODE);
                out.push(action as u8);
                out.extend_from_slice(&keycode.to_be_bytes());
                out.extend_from_slice(&repeat_count.to_be_bytes());
                out.extend_from_slice(&meta_state.to_be_bytes());
                Some(out)
            },
            Self::Text(text) => {
                let body = truncate_utf8(text, MAX_TEXT);
                if body.is_empty() {
                    return None;
                }
                let mut out = Vec::with_capacity(5 + body.len());
                out.push(kind::INJECT_TEXT);
                // `body` was just cut to `MAX_TEXT`, so the conversion cannot narrow. No helper: a
                // `truncating_u32` here would be a FIFTEENTH copy of a name that has meant two
                // different things, and `slopdesk-invariants` bans it for exactly that.
                out.extend_from_slice(&u32::try_from(body.len()).unwrap_or(u32::MAX).to_be_bytes());
                out.extend_from_slice(body.as_bytes());
                Some(out)
            },
            Self::SetClipboard { text, paste } => {
                let body = truncate_utf8(text, MAX_CLIPBOARD);
                if body.is_empty() {
                    return None;
                }
                let mut out = Vec::with_capacity(14 + body.len());
                out.push(kind::SET_CLIPBOARD);
                // The sequence, and it is zero. Not a parameter: see the module comment.
                out.extend_from_slice(&0_u64.to_be_bytes());
                out.push(u8::from(paste));
                out.extend_from_slice(&u32::try_from(body.len()).unwrap_or(u32::MAX).to_be_bytes());
                out.extend_from_slice(body.as_bytes());
                Some(out)
            },
            Self::BackOrScreenOn(action) => Some(vec![kind::BACK_OR_SCREEN_ON, action as u8]),
            Self::DisplayPower(on) => Some(vec![kind::SET_DISPLAY_POWER, u8::from(on)]),
            Self::StartApp(package) => {
                let body = truncate_utf8(package, MAX_PACKAGE);
                if body.is_empty() {
                    return None;
                }
                let mut out = Vec::with_capacity(2 + body.len());
                out.push(kind::START_APP);
                // A one-byte prefix, which `MAX_PACKAGE` is exactly what keeps in range.
                out.push(u8::try_from(body.len()).unwrap_or(u8::MAX));
                out.extend_from_slice(body.as_bytes());
                Some(out)
            },
            Self::Bodiless(message) => Some(vec![message.type_byte()]),
        }
    }
}

/// `write_position` — a signed 32-bit point followed by the UNSIGNED 16-bit size it was measured
/// against. The point is signed because a drag legitimately leaves the frame.
fn write_position(out: &mut Vec<u8>, x: i32, y: i32, width: u16, height: u16) {
    out.extend_from_slice(&x.to_be_bytes());
    out.extend_from_slice(&y.to_be_bytes());
    out.extend_from_slice(&width.to_be_bytes());
    out.extend_from_slice(&height.to_be_bytes());
}

/// `sc_float_to_u16fp` — `[0, 1]` over 16 bits.
///
/// NaN is answered as the NEUTRAL value rather than as a bound. `f32::max`/`min` return the non-NaN
/// operand, so a plain clamp would silently resolve a NaN to whichever bound it met first — full
/// pressure, or a full-scale scroll in one direction. The Swift original instead let NaN reach an
/// integer conversion that TRAPS, which is a crash on a value a gesture recogniser can genuinely
/// produce, so neither reading was worth keeping.
#[must_use]
#[expect(
    clippy::cast_possible_truncation,
    clippy::cast_sign_loss,
    reason = "the clamp above puts `scaled` in [0, 65536] and the branch below takes everything at or over \
              65535, so the cast sees a non-negative value under u16::MAX — and a float `as` cast saturates \
              rather than wrapping in any case"
)]
pub fn unsigned_fixed_point(value: f32) -> u16 {
    if value.is_nan() {
        return 0;
    }
    let clamped = value.clamp(0.0, 1.0);
    // Kept as one multiply on purpose — `mul_add` would round once where this rounds twice, and the
    // wire's bit patterns are what the tests pin.
    let scaled = clamped * 65_536.0;
    if scaled >= 65_535.0 { 0xFFFF } else { scaled as u16 }
}

/// `sc_float_to_i16fp` — `[-1, 1]` over 16 signed bits.
///
/// NaN answers `0` — no scroll — for [`unsigned_fixed_point`]'s reason.
#[must_use]
#[expect(
    clippy::cast_possible_truncation,
    reason = "the clamp puts `scaled` in [-32768, 32768] and both saturating branches fire before the cast, \
              so it sees a value inside i16 — and a float `as` cast saturates regardless"
)]
pub fn signed_fixed_point(value: f32) -> i16 {
    if value.is_nan() {
        return 0;
    }
    let clamped = value.clamp(-1.0, 1.0);
    let scaled = clamped * 32_768.0;
    if scaled >= 32_767.0 {
        return 0x7FFF;
    }
    if scaled <= -32_768.0 {
        return -0x8000;
    }
    scaled as i16
}

/// The longest prefix of `text` that fits in `limit` bytes without splitting a scalar.
///
/// Cutting a multi-byte scalar in half sends the device a byte sequence it decodes as a replacement
/// character, so typing an emoji would silently corrupt the field.
///
/// One pass over the char boundaries and a single slice. The Swift original re-encoded EVERY
/// character into a fresh `String` and a fresh `Data` to measure it — two allocations per
/// character, over a clipboard whose ceiling is 200 KiB.
#[must_use]
pub fn truncate_utf8(text: &str, limit: usize) -> &str {
    if text.len() <= limit {
        return text;
    }
    let end = text
        .char_indices()
        .map(|(offset, _)| offset)
        .take_while(|offset| *offset <= limit)
        .last()
        .unwrap_or(0);
    // `end` is a char boundary by construction, so the slice cannot split a scalar.
    text.get(..end).unwrap_or("")
}

#[cfg(test)]
mod tests {
    use super::{
        Bodiless, FINGER_POINTER_ID, KeyAction, Message, MotionAction, VIRTUAL_FINGER_POINTER_ID,
        signed_fixed_point, truncate_utf8, unsigned_fixed_point,
    };

    fn encoded(message: Message<'_>) -> Vec<u8> {
        message.encode().unwrap_or_default()
    }

    // MARK: Touch — the panel's whole pointer path

    #[test]
    fn a_touch_is_thirty_two_bytes_in_the_servers_order() {
        let bytes = encoded(Message::Touch {
            action: MotionAction::Down,
            pointer_id: FINGER_POINTER_ID,
            x: 0x0102_0304,
            y: -2,
            width: 0x0506,
            height: 0x0708,
            pressure: 1.0,
            action_button: 1,
            buttons: 1,
        });
        assert_eq!(bytes.len(), 32);
        assert_eq!(bytes, vec![
            2, // INJECT_TOUCH_EVENT
            0, // ACTION_DOWN
            0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFE, // SC_POINTER_ID_GENERIC_FINGER
            0x01, 0x02, 0x03, 0x04, // x
            0xFF, 0xFF, 0xFF, 0xFE, // y — signed, because a drag legitimately leaves the frame
            0x05, 0x06, // width
            0x07, 0x08, // height
            0xFF, 0xFF, // pressure 1.0 as u16fp
            0x00, 0x00, 0x00, 0x01, // action button
            0x00, 0x00, 0x00, 0x01, // buttons
        ]);
    }

    #[test]
    fn the_panel_injects_fingers_rather_than_a_mouse() {
        assert_eq!(FINGER_POINTER_ID, u64::MAX - 1);
        assert_eq!(VIRTUAL_FINGER_POINTER_ID, u64::MAX - 2);
    }

    #[test]
    fn every_motion_action_keeps_the_platforms_number() {
        assert_eq!(MotionAction::Down as u8, 0);
        assert_eq!(MotionAction::Up as u8, 1);
        assert_eq!(MotionAction::Move as u8, 2);
        assert_eq!(MotionAction::Cancel as u8, 3);
        // 4 is OUTSIDE, which the panel never sends — 5 and 6 are the pinch's second contact.
        assert_eq!(MotionAction::from_byte(4), None);
        assert_eq!(MotionAction::PointerDown as u8, 5);
        assert_eq!(MotionAction::PointerUp as u8, 6);
    }

    // MARK: Keys

    #[test]
    fn a_keycode_is_fourteen_bytes() {
        let bytes = encoded(Message::Key {
            action: KeyAction::Up,
            keycode: 187, // KEYCODE_APP_SWITCH
            repeat_count: 1,
            meta_state: 0x0001_0002, // META_ALT_ON | META_META_ON
        });
        assert_eq!(bytes.len(), 14);
        assert_eq!(bytes, vec![
            0, // INJECT_KEYCODE
            1, // ACTION_UP
            0x00, 0x00, 0x00, 0xBB, // KEYCODE_APP_SWITCH = 187
            0x00, 0x00, 0x00, 0x01, // repeat
            0x00, 0x01, 0x00, 0x02, // META_ALT_ON | META_META_ON
        ]);
    }

    #[test]
    fn back_travels_as_back_or_screen_on_rather_than_as_a_keycode() {
        // On a sleeping device the same press wakes it, which is what the hardware key does.
        assert_eq!(encoded(Message::BackOrScreenOn(KeyAction::Down)), vec![4, 0]);
        assert_eq!(encoded(Message::BackOrScreenOn(KeyAction::Up)), vec![4, 1]);
    }

    // MARK: Text

    #[test]
    fn text_is_length_prefixed_utf8() {
        assert_eq!(encoded(Message::Text("hi")), vec![1, 0, 0, 0, 2, b'h', b'i']);
    }

    #[test]
    fn an_empty_string_produces_no_message_at_all() {
        assert_eq!(Message::Text("").encode(), None);
        assert_eq!(
            Message::SetClipboard {
                text: "",
                paste: true
            }
            .encode(),
            None
        );
        assert_eq!(Message::StartApp("").encode(), None);
    }

    #[test]
    fn truncation_never_splits_a_character() {
        let emoji = "😀".repeat(4); // 4 bytes each
        assert_eq!(truncate_utf8(&emoji, 10), "😀😀");
        assert_eq!(truncate_utf8(&emoji, 16), emoji, "an exact fit is not cut");
        assert_eq!(truncate_utf8(&emoji, 3), "", "no whole character fits");
    }

    #[test]
    fn text_is_cut_at_the_servers_own_ceiling() {
        let long = "a".repeat(400);
        assert_eq!(encoded(Message::Text(&long)).len(), 5 + 300);
    }

    // MARK: The one-way invariant

    #[test]
    fn set_clipboard_always_asks_for_no_acknowledgement() {
        // THE load-bearing assertion here. A non-zero sequence asks the device to reply, and a
        // device→client message on this connection lands in the middle of the video stream.
        let bytes = encoded(Message::SetClipboard {
            text: "x",
            paste: true,
        });
        assert_eq!(bytes.get(..9), Some(&[9, 0, 0, 0, 0, 0, 0, 0, 0][..]));
        assert_eq!(bytes.get(9..), Some(&[1, 0, 0, 0, 1, b'x'][..]));
    }

    #[test]
    fn no_reply_bearing_type_has_a_name_here() {
        // Not a gap: the types between SET_CLIPBOARD and OPEN_HARD_KEYBOARD_SETTINGS are the ones
        // with device replies, and having no variant for them is what keeps one full-duplex
        // connection sound. This pins the numbering that makes the omission visible.
        assert_eq!(Bodiless::from_type_byte(8), None, "type 8, the clipboard READ");
        for uhid in 12..=14 {
            assert_eq!(
                Bodiless::from_type_byte(uhid),
                None,
                "type {uhid}, a keyboard device"
            );
        }
        assert_eq!(encoded(Message::Bodiless(Bodiless::CollapsePanels)), vec![7]);
        assert_eq!(encoded(Message::Bodiless(Bodiless::RotateDevice)), vec![11]);
        assert_eq!(
            encoded(Message::Bodiless(Bodiless::OpenHardKeyboardSettings)),
            vec![15]
        );
        assert_eq!(encoded(Message::Bodiless(Bodiless::ResetVideo)), vec![17]);
    }

    // MARK: The small messages

    #[test]
    fn display_power_is_two_bytes() {
        assert_eq!(encoded(Message::DisplayPower(false)), vec![10, 0]);
        assert_eq!(encoded(Message::DisplayPower(true)), vec![10, 1]);
    }

    #[test]
    fn start_app_takes_a_one_byte_length_and_not_four() {
        let bytes = encoded(Message::StartApp("com.x"));
        assert_eq!(bytes.get(..2), Some(&[16, 5][..]));
    }

    // MARK: Fixed point (`sc_float_to_*fp`)

    #[test]
    fn unsigned_fixed_point_saturates_rather_than_wrapping() {
        assert_eq!(unsigned_fixed_point(0.0), 0);
        assert_eq!(unsigned_fixed_point(0.5), 0x8000);
        assert_eq!(unsigned_fixed_point(1.0), 0xFFFF);
        assert_eq!(unsigned_fixed_point(4.0), 0xFFFF);
        assert_eq!(unsigned_fixed_point(-1.0), 0);
    }

    #[test]
    fn signed_fixed_point_saturates_at_both_ends() {
        assert_eq!(signed_fixed_point(0.0), 0);
        assert_eq!(signed_fixed_point(0.5), 0x4000);
        assert_eq!(signed_fixed_point(1.0), 0x7FFF);
        assert_eq!(signed_fixed_point(-1.0), -0x8000);
        assert_eq!(signed_fixed_point(-9.0), -0x8000);
    }

    /// A NaN clamps to a real number rather than reaching the integer conversion. The Swift
    /// original's comparison-based clamp let it through, and `UInt32(Float.nan)` TRAPS.
    #[test]
    fn a_not_a_number_clamps_rather_than_crashing() {
        assert_eq!(unsigned_fixed_point(f32::NAN), 0);
        assert_eq!(signed_fixed_point(f32::NAN), 0);
    }

    #[test]
    fn a_scroll_event_is_twenty_one_bytes_and_carries_notches_over_sixteen() {
        // The wire field is [-1, 1]; the protocol's own scale is [-16, 16] notches, so a value that
        // skipped the division would saturate on a single click.
        let bytes = encoded(Message::Scroll {
            x: 1,
            y: 2,
            width: 3,
            height: 4,
            horizontal: 0.0,
            vertical: 1.0,
            buttons: 0,
        });
        assert_eq!(bytes.len(), 21);
        assert_eq!(
            bytes.get(13..),
            Some(
                &[
                    0x00, 0x00, // horizontal
                    0x08, 0x00, // vertical: 1/16 of full scale
                    0x00, 0x00, 0x00, 0x00, // buttons
                ][..]
            )
        );
    }
}
