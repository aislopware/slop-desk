//! Client→host input events — `Sources/SlopDeskVideoProtocol/InputEventCodec.swift` and
//! `InputModifierKeys.swift` (doc 17 §3.9, doc 05).
//!
//! Positions travel as NORMALISED window coordinates (0..1), never raw pixels, which removes the
//! pixel-versus-point ambiguity entirely (doc 05 §2); the host maps them with
//! [`crate::coordinate_mapping`]. Every event carries `tag`, the value the host stamps on
//! `eventSourceUserData` so it can filter its own injected events back out of the cursor sampler
//! and the window-geometry watcher (doc 18 §A) — without it the two would feed each other.
//!
//! ```text
//! off 0: u8   type — move=1, down=2, up=3, scroll=4, key=5, text=6, drag=7
//! off 1: u32  tag
//! then:       the variant payload, big-endian; text trails as raw UTF-8 to the datagram end
//! ```
//!
//! Pinned by the `inputEvent` golden vectors.
//!
//! ## Drag is its own message, not an inferred state
//!
//! [`InputEvent::MouseDrag`] exists because the host must stay STATELESS about held buttons. The
//! client's view already knows whether it saw `mouseDragged` or `mouseMoved`, so it says which, and
//! the host posts the matching `*MouseDragged` verbatim. That is what makes drag-select correct
//! over UDP: a drag that arrives before its down is simply ignored by the target app until the down
//! anchors the selection, and a LOST `mouseUp` can no longer strand the host in a phantom drag,
//! because a `MouseMove` is now always a pure hover. `click_count` rides along so the dragged
//! event's click state matches the down — selection engines key off it.
//!
//! ## Text is STRICT UTF-8
//!
//! Same split as [`crate::window_geometry`]: invalid bytes are a DROP, not a lossy replacement.
//! Text insertion is the layout-independent path, and typing a U+FFFD into the user's editor is
//! worse than typing nothing — the keystroke is gone either way, but only one of them leaves a mark
//! that has to be found and deleted.

use crate::bytes::{ByteReader, ByteWriter};
use crate::error::{Result, VideoProtocolError};
use crate::geometry::VideoPoint;

/// Modifier-key bitmask carried by input events. Mirrors the `CGEventFlags` the host will apply,
/// kept platform-free here.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct InputModifiers(u8);

impl InputModifiers {
    /// ⇧.
    pub const SHIFT: Self = Self(1 << 0);
    /// ⌃.
    pub const CONTROL: Self = Self(1 << 1);
    /// ⌥.
    pub const OPTION: Self = Self(1 << 2);
    /// ⌘.
    pub const COMMAND: Self = Self(1 << 3);
    /// Caps Lock.
    pub const CAPS_LOCK: Self = Self(1 << 4);
    /// fn.
    pub const FUNCTION: Self = Self(1 << 5);

    /// Wraps a raw wire bitmask. Unknown bits are PRESERVED, not rejected: they cost nothing to
    /// carry and rejecting them would make a newer client unusable against an older host.
    #[must_use]
    pub const fn from_bits(bits: u8) -> Self {
        Self(bits)
    }

    /// The raw wire bitmask.
    #[must_use]
    pub const fn bits(self) -> u8 {
        self.0
    }

    /// Whether every modifier in `other` is set.
    #[must_use]
    pub const fn contains(self, other: Self) -> bool {
        self.0 & other.0 == other.0
    }

    /// The union of two masks.
    #[must_use]
    pub const fn union(self, other: Self) -> Self {
        Self(self.0 | other.0)
    }
}

/// Which mouse button an event concerns.
///
/// Ordered by the wire discriminant, so the host's held-button ledger can key an ordered set on it
/// and iterate deterministically.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, PartialOrd, Ord)]
pub enum MouseButton {
    /// The primary button.
    #[default]
    Left,
    /// The secondary button.
    Right,
    /// Any further button.
    Other,
}

impl MouseButton {
    /// The on-wire discriminant.
    #[must_use]
    pub const fn raw_value(self) -> u8 {
        match self {
            Self::Left => 0,
            Self::Right => 1,
            Self::Other => 2,
        }
    }

    /// Parses a wire discriminant, or `None` for an unknown one.
    #[must_use]
    pub const fn from_raw(raw: u8) -> Option<Self> {
        match raw {
            0 => Some(Self::Left),
            1 => Some(Self::Right),
            2 => Some(Self::Other),
            _ => None,
        }
    }
}

/// The mouse-button payload shared by down, up and drag — identical bytes, different verbs.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct MouseButtonEvent {
    /// Which button.
    pub button: MouseButton,
    /// Normalised window position (0..1).
    pub normalized: VideoPoint,
    /// The originating click count, so a drag's click state matches its down.
    pub click_count: u8,
    /// Held modifiers.
    pub modifiers: InputModifiers,
}

/// The scroll payload.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ScrollEvent {
    /// Signed horizontal scroll delta, pixel units.
    pub dx: f64,
    /// Signed vertical scroll delta, pixel units.
    pub dy: f64,
    /// Normalised window position (0..1).
    pub normalized: VideoPoint,
    /// `CGScrollPhase` verbatim: 0 none, 1 began, 2 changed, 4 ended, 8 cancelled, 128 may-begin.
    pub scroll_phase: u8,
    /// `CGMomentumScrollPhase` verbatim: 0 none, 1 begin, 2 continue, 3 end. Mutually exclusive
    /// with `scroll_phase` — at most one is non-zero per event.
    pub momentum_phase: u8,
    /// Mirrors `hasPreciseScrollingDeltas`: a pixel-precise trackpad gesture rather than a wheel
    /// tick.
    pub continuous: bool,
}

/// The key payload.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct KeyEvent {
    /// The host virtual keycode.
    pub key_code: u16,
    /// Down (`true`) or up.
    pub down: bool,
    /// Held modifiers.
    pub modifiers: InputModifiers,
}

/// A client→host input event.
#[derive(Debug, Clone, PartialEq)]
pub enum InputEvent {
    /// Absolute pointer move to a normalised window position — always a PURE hover.
    MouseMove {
        /// Normalised window position (0..1).
        normalized: VideoPoint,
        /// The self-inject filter tag.
        tag: u32,
    },
    /// Mouse button down.
    MouseDown(MouseButtonEvent, u32),
    /// Mouse button up.
    MouseUp(MouseButtonEvent, u32),
    /// Mouse drag — a button is HELD; see the module docs for why the client says so explicitly.
    MouseDrag(MouseButtonEvent, u32),
    /// Scroll wheel or trackpad gesture.
    Scroll(ScrollEvent, u32),
    /// Key down/up by host virtual keycode.
    Key(KeyEvent, u32),
    /// Unicode text insertion — the layout-independent path (doc 05 §3).
    Text(String, u32),
}

impl InputEvent {
    /// The on-wire type byte.
    #[must_use]
    pub const fn message_type(&self) -> u8 {
        match *self {
            Self::MouseMove { .. } => 1,
            Self::MouseDown(..) => 2,
            Self::MouseUp(..) => 3,
            Self::Scroll(..) => 4,
            Self::Key(..) => 5,
            Self::Text(..) => 6,
            Self::MouseDrag(..) => 7,
        }
    }

    /// The self-inject filter tag.
    #[must_use]
    pub const fn tag(&self) -> u32 {
        match *self {
            Self::MouseMove { tag, .. }
            | Self::MouseDown(_, tag)
            | Self::MouseUp(_, tag)
            | Self::MouseDrag(_, tag)
            | Self::Scroll(_, tag)
            | Self::Key(_, tag)
            | Self::Text(_, tag) => tag,
        }
    }

    /// Serialises the event.
    #[must_use]
    pub fn encode(&self) -> Vec<u8> {
        let mut out = ByteWriter::new();
        out.put_u8(self.message_type());
        out.put_u32(self.tag());
        match *self {
            Self::MouseMove { normalized, .. } => {
                out.put_f64(normalized.x);
                out.put_f64(normalized.y);
            },
            Self::MouseDown(event, _) | Self::MouseUp(event, _) | Self::MouseDrag(event, _) => {
                out.put_u8(event.button.raw_value());
                out.put_u8(event.click_count);
                out.put_u8(event.modifiers.bits());
                out.put_f64(event.normalized.x);
                out.put_f64(event.normalized.y);
            },
            Self::Scroll(event, _) => {
                out.put_f64(event.dx);
                out.put_f64(event.dy);
                out.put_f64(event.normalized.x);
                out.put_f64(event.normalized.y);
                out.put_u8(event.scroll_phase);
                out.put_u8(event.momentum_phase);
                out.put_u8(u8::from(event.continuous));
            },
            Self::Key(event, _) => {
                out.put_u16(event.key_code);
                out.put_u8(u8::from(event.down));
                out.put_u8(event.modifiers.bits());
            },
            Self::Text(ref text, _) => out.put_bytes(text.as_bytes()),
        }
        out.into_vec()
    }

    /// Decodes a client→host input event.
    ///
    /// # Errors
    /// [`VideoProtocolError::Truncated`] for a short body;
    /// [`VideoProtocolError::Malformed`] for an unknown type byte, an unknown mouse button, a
    /// non-finite coordinate, or text that is not valid UTF-8 (strict — see the module docs).
    pub fn decode(data: &[u8]) -> Result<Self> {
        let mut reader = ByteReader::new(data);
        let kind = reader.read_u8()?;
        let tag = reader.read_u32()?;
        match kind {
            1 => {
                let x = reader.read_finite_f64("mouseMove.x")?;
                let y = reader.read_finite_f64("mouseMove.y")?;
                Ok(Self::MouseMove {
                    normalized: VideoPoint::new(x, y),
                    tag,
                })
            },
            2 | 3 | 7 => {
                let raw = reader.read_u8()?;
                let button = MouseButton::from_raw(raw)
                    .ok_or_else(|| VideoProtocolError::malformed("unknown mouse button"))?;
                let click_count = reader.read_u8()?;
                let modifiers = InputModifiers::from_bits(reader.read_u8()?);
                let x = reader.read_finite_f64("mouseButton.x")?;
                let y = reader.read_finite_f64("mouseButton.y")?;
                let event = MouseButtonEvent {
                    button,
                    normalized: VideoPoint::new(x, y),
                    click_count,
                    modifiers,
                };
                match kind {
                    2 => Ok(Self::MouseDown(event, tag)),
                    3 => Ok(Self::MouseUp(event, tag)),
                    _ => Ok(Self::MouseDrag(event, tag)),
                }
            },
            4 => {
                let dx = reader.read_finite_f64("scroll.dx")?;
                let dy = reader.read_finite_f64("scroll.dy")?;
                let x = reader.read_finite_f64("scroll.x")?;
                let y = reader.read_finite_f64("scroll.y")?;
                let scroll_phase = reader.read_u8()?;
                let momentum_phase = reader.read_u8()?;
                let continuous = reader.read_u8()? != 0;
                Ok(Self::Scroll(
                    ScrollEvent {
                        dx,
                        dy,
                        normalized: VideoPoint::new(x, y),
                        scroll_phase,
                        momentum_phase,
                        continuous,
                    },
                    tag,
                ))
            },
            5 => {
                let key_code = reader.read_u16()?;
                let down = reader.read_u8()? != 0;
                let modifiers = InputModifiers::from_bits(reader.read_u8()?);
                Ok(Self::Key(
                    KeyEvent {
                        key_code,
                        down,
                        modifiers,
                    },
                    tag,
                ))
            },
            6 => {
                let text = core::str::from_utf8(reader.remaining())
                    .map_err(|_| VideoProtocolError::malformed("input text not valid UTF-8"))?;
                Ok(Self::Text(text.to_owned(), tag))
            },
            other => {
                Err(VideoProtocolError::malformed(format!(
                    "unknown input event type {other}"
                )))
            },
        }
    }
}

/// The macOS virtual keycodes of the HELD modifier keys.
///
/// The one shared vocabulary for every input-path policy that treats a modifier edge specially.
/// Pure data with no wire impact: keycodes ride the existing [`InputEvent::Key`] message
/// unchanged.
///
/// Used on both ends. The CLIENT sends a modifier key-up with the same N-times redundancy as a
/// `mouseUp`, because a lost release permanently latches the modifier on the host's shared
/// `CGEventSource(.hidSystemState)` — every later plain scroll becomes ⌘-scroll — until the user
/// happens to press and release that key again. The HOST then collapses that redundant burst to one
/// posted event with per-keycode duplicate suppression, mirroring the `mouseUp` idempotence.
///
/// **Caps Lock (57) is deliberately EXCLUDED.** It is a TOGGLE, not a held key: a synthesized down
/// or up on virtual key 57 FLIPS the host's Caps state, so it must never ride the
/// latch/resync/release/redundancy machinery. Its genuine `flagsChanged` edges forward 1:1.
pub mod modifier_keys {
    /// The Caps Lock virtual keycode — the toggle every held-modifier policy must skip.
    pub const CAPS_LOCK_KEY_CODE: u16 = 57;

    /// Left+right ⌘ (55/54), ⇧ (56/60), ⌃ (59/62), ⌥ (58/61), and fn (63). Left and right are
    /// DISTINCT keys with distinct latched flags, so policies key on the exact keycode.
    pub const HELD_MODIFIER_KEY_CODES: [u16; 9] = [54, 55, 56, 58, 59, 60, 61, 62, 63];

    /// Whether `key_code` is a held modifier key — never true for Caps Lock or an ordinary key.
    #[must_use]
    pub const fn is_held_modifier(key_code: u16) -> bool {
        // A linear scan over nine `u16`s beats a hash set at this size and stays `const`. Written
        // against `first_chunk`-free primitives because `const` iteration is not available here;
        // the bound is the array's own length, so no index can escape it.
        let mut index = 0;
        while index < HELD_MODIFIER_KEY_CODES.len() {
            #[expect(
                clippy::indexing_slicing,
                reason = "`index < len` is the loop condition, and `get` is not const-callable here"
            )]
            let candidate = HELD_MODIFIER_KEY_CODES[index];
            if candidate == key_code {
                return true;
            }
            index += 1;
        }
        false
    }
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        clippy::indexing_slicing,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use super::{
        InputEvent, InputModifiers, KeyEvent, MouseButton, MouseButtonEvent, ScrollEvent, modifier_keys,
    };
    use crate::error::VideoProtocolError;
    use crate::geometry::VideoPoint;

    fn button_event(button: MouseButton) -> MouseButtonEvent {
        MouseButtonEvent {
            button,
            normalized: VideoPoint::new(0.1, 0.2),
            click_count: 2,
            modifiers: InputModifiers::SHIFT.union(InputModifiers::COMMAND),
        }
    }

    #[test]
    fn every_variant_round_trips_and_keeps_its_tag() {
        let cases = [
            InputEvent::MouseMove {
                normalized: VideoPoint::new(0.25, 0.75),
                tag: 42,
            },
            InputEvent::MouseDown(button_event(MouseButton::Right), 7),
            InputEvent::MouseUp(button_event(MouseButton::Left), 8),
            InputEvent::MouseDrag(button_event(MouseButton::Other), 9),
            InputEvent::Scroll(
                ScrollEvent {
                    dx: -3.5,
                    dy: 12.0,
                    normalized: VideoPoint::new(0.0, 1.0),
                    scroll_phase: 2,
                    momentum_phase: 0,
                    continuous: true,
                },
                10,
            ),
            InputEvent::Key(
                KeyEvent {
                    key_code: 53,
                    down: true,
                    modifiers: InputModifiers::OPTION,
                },
                11,
            ),
            InputEvent::Text("gõ được 文字".to_owned(), 12),
        ];
        for case in cases {
            let tag = case.tag();
            let decoded = InputEvent::decode(&case.encode()).expect("a self-encoded event decodes");
            assert_eq!(decoded, case);
            assert_eq!(decoded.tag(), tag);
        }
    }

    #[test]
    fn down_up_and_drag_share_a_payload_but_never_a_type_byte() {
        let event = button_event(MouseButton::Left);
        let types: Vec<u8> = [
            InputEvent::MouseDown(event, 1),
            InputEvent::MouseUp(event, 1),
            InputEvent::MouseDrag(event, 1),
        ]
        .iter()
        .map(InputEvent::message_type)
        .collect();
        assert_eq!(types, vec![2, 3, 7]);
        // Identical bytes after the type byte — the verbs differ, the payload does not.
        let down = InputEvent::MouseDown(event, 1).encode();
        let drag = InputEvent::MouseDrag(event, 1).encode();
        assert_eq!(down.get(1..), drag.get(1..));
    }

    #[test]
    fn an_unknown_button_and_an_unknown_type_are_both_malformed() {
        let mut bytes = InputEvent::MouseDown(button_event(MouseButton::Left), 1).encode();
        bytes[5] = 9;
        assert!(matches!(
            InputEvent::decode(&bytes),
            Err(VideoProtocolError::Malformed(_))
        ));
        assert!(matches!(
            InputEvent::decode(&[99, 0, 0, 0, 0]),
            Err(VideoProtocolError::Malformed(_))
        ));
    }

    #[test]
    fn a_nonfinite_scroll_delta_is_dropped() {
        let poisoned = InputEvent::Scroll(
            ScrollEvent {
                dx: f64::NAN,
                dy: 0.0,
                normalized: VideoPoint::new(0.0, 0.0),
                scroll_phase: 0,
                momentum_phase: 0,
                continuous: false,
            },
            1,
        );
        assert!(matches!(
            InputEvent::decode(&poisoned.encode()),
            Err(VideoProtocolError::Malformed(_))
        ));
    }

    #[test]
    fn invalid_utf8_text_is_dropped_rather_than_typed_as_replacement_characters() {
        let mut bytes = InputEvent::Text(String::new(), 12).encode();
        bytes.extend_from_slice(&[0xC3, 0x28]);
        assert!(matches!(
            InputEvent::decode(&bytes),
            Err(VideoProtocolError::Malformed(_))
        ));
    }

    #[test]
    fn a_truncated_datagram_is_truncated_not_malformed() {
        assert_eq!(InputEvent::decode(&[1, 0, 0]), Err(VideoProtocolError::Truncated));
    }

    #[test]
    fn unknown_modifier_bits_survive_the_round_trip() {
        let exotic = InputModifiers::from_bits(0b1100_0000);
        let event = InputEvent::Key(
            KeyEvent {
                key_code: 1,
                down: false,
                modifiers: exotic,
            },
            0,
        );
        let decoded = InputEvent::decode(&event.encode()).expect("reserved bits are not fatal");
        assert_eq!(decoded, event);
    }

    #[test]
    fn caps_lock_is_not_a_held_modifier() {
        assert!(!modifier_keys::is_held_modifier(
            modifier_keys::CAPS_LOCK_KEY_CODE
        ));
        assert!(modifier_keys::is_held_modifier(55), "left command");
        assert!(modifier_keys::is_held_modifier(63), "fn");
        assert!(!modifier_keys::is_held_modifier(0), "an ordinary key");
    }
}
