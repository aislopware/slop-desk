//! Client→host input event codec — a port of Swift `InputEventCodec`.
//!
//! Positions are in normalised window space (0..1); the client never sends raw pixels.
//! Every event carries a `tag` the host stamps on its synthetic event so it can filter
//! its own self-injected events out (avoids feedback loops). Text/title are decoded as
//! strict UTF-8.

use crate::bytes::{ByteReader, ByteWriter};
use crate::error::{Result, VideoProtocolError};
use crate::geometry::VideoPoint;

/// Modifier-key bitmask carried by input events (mirrors the host's `CGEventFlags`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct InputModifiers(pub u8);

impl InputModifiers {
    /// Shift key.
    pub const SHIFT: Self = Self(1 << 0);
    /// Control key.
    pub const CONTROL: Self = Self(1 << 1);
    /// Option / Alt key.
    pub const OPTION: Self = Self(1 << 2);
    /// Command key.
    pub const COMMAND: Self = Self(1 << 3);
    /// Caps Lock.
    pub const CAPS_LOCK: Self = Self(1 << 4);
    /// Function key.
    pub const FUNCTION: Self = Self(1 << 5);

    /// The raw bitmask.
    #[must_use]
    pub const fn raw(self) -> u8 {
        self.0
    }

    /// Whether every bit of `other` is set.
    #[must_use]
    pub const fn contains(self, other: Self) -> bool {
        self.0 & other.0 == other.0
    }

    /// The union of two modifier sets.
    #[must_use]
    pub const fn union(self, other: Self) -> Self {
        Self(self.0 | other.0)
    }
}

/// Which mouse button an event concerns.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MouseButton {
    /// Primary (left) button.
    Left,
    /// Secondary (right) button.
    Right,
    /// Any other button.
    Other,
}

impl MouseButton {
    /// The on-wire raw value (left=0, right=1, other=2).
    #[must_use]
    pub const fn raw(self) -> u8 {
        match self {
            Self::Left => 0,
            Self::Right => 1,
            Self::Other => 2,
        }
    }

    /// Parses a raw value; `None` for anything outside 0..=2.
    #[must_use]
    pub const fn from_u8(value: u8) -> Option<Self> {
        match value {
            0 => Some(Self::Left),
            1 => Some(Self::Right),
            2 => Some(Self::Other),
            _ => None,
        }
    }
}

/// A client→host input event.
#[derive(Debug, Clone, PartialEq)]
pub enum InputEvent {
    /// Absolute pointer move to a normalised window position.
    MouseMove {
        /// Normalised (0..1) window position.
        normalized: VideoPoint,
        /// Self-inject filter tag.
        tag: u32,
    },
    /// Mouse button down.
    MouseDown {
        /// Which button.
        button: MouseButton,
        /// Normalised position.
        normalized: VideoPoint,
        /// Originating click count.
        click_count: u8,
        /// Active modifiers.
        modifiers: InputModifiers,
        /// Self-inject filter tag.
        tag: u32,
    },
    /// Mouse button up.
    MouseUp {
        /// Which button.
        button: MouseButton,
        /// Normalised position.
        normalized: VideoPoint,
        /// Originating click count.
        click_count: u8,
        /// Active modifiers.
        modifiers: InputModifiers,
        /// Self-inject filter tag.
        tag: u32,
    },
    /// Mouse drag (a button is held) to a normalised window position.
    MouseDrag {
        /// Which button.
        button: MouseButton,
        /// Normalised position.
        normalized: VideoPoint,
        /// Originating click count (matches the down's click state).
        click_count: u8,
        /// Active modifiers.
        modifiers: InputModifiers,
        /// Self-inject filter tag.
        tag: u32,
    },
    /// Scroll wheel (pixel units); `dx`/`dy` are signed deltas.
    Scroll {
        /// Horizontal scroll delta.
        dx: f64,
        /// Vertical scroll delta.
        dy: f64,
        /// Normalised position.
        normalized: VideoPoint,
        /// Self-inject filter tag.
        tag: u32,
    },
    /// Key down/up by host virtual keycode.
    Key {
        /// Host virtual keycode.
        key_code: u16,
        /// True for key-down, false for key-up.
        down: bool,
        /// Active modifiers.
        modifiers: InputModifiers,
        /// Self-inject filter tag.
        tag: u32,
    },
    /// Unicode text insertion (layout-independent).
    Text {
        /// The text to insert.
        text: String,
        /// Self-inject filter tag.
        tag: u32,
    },
}

impl InputEvent {
    /// The on-wire type byte.
    #[must_use]
    pub const fn message_type(&self) -> u8 {
        match self {
            Self::MouseMove { .. } => 1,
            Self::MouseDown { .. } => 2,
            Self::MouseUp { .. } => 3,
            Self::Scroll { .. } => 4,
            Self::Key { .. } => 5,
            Self::Text { .. } => 6,
            Self::MouseDrag { .. } => 7,
        }
    }

    /// The self-inject filter tag.
    #[must_use]
    pub const fn tag(&self) -> u32 {
        match *self {
            Self::MouseMove { tag, .. }
            | Self::MouseDown { tag, .. }
            | Self::MouseUp { tag, .. }
            | Self::MouseDrag { tag, .. }
            | Self::Scroll { tag, .. }
            | Self::Key { tag, .. }
            | Self::Text { tag, .. } => tag,
        }
    }

    /// Serialises the event.
    #[must_use]
    pub fn encode(&self) -> Vec<u8> {
        let mut w = ByteWriter::new();
        w.put_u8(self.message_type());
        match self {
            Self::MouseMove { normalized, tag } => {
                w.put_u32(*tag);
                w.put_f64(normalized.x);
                w.put_f64(normalized.y);
            }
            Self::MouseDown {
                button,
                normalized,
                click_count,
                modifiers,
                tag,
            }
            | Self::MouseUp {
                button,
                normalized,
                click_count,
                modifiers,
                tag,
            }
            | Self::MouseDrag {
                button,
                normalized,
                click_count,
                modifiers,
                tag,
            } => {
                w.put_u32(*tag);
                w.put_u8(button.raw());
                w.put_u8(*click_count);
                w.put_u8(modifiers.raw());
                w.put_f64(normalized.x);
                w.put_f64(normalized.y);
            }
            Self::Scroll {
                dx,
                dy,
                normalized,
                tag,
            } => {
                w.put_u32(*tag);
                w.put_f64(*dx);
                w.put_f64(*dy);
                w.put_f64(normalized.x);
                w.put_f64(normalized.y);
            }
            Self::Key {
                key_code,
                down,
                modifiers,
                tag,
            } => {
                w.put_u32(*tag);
                w.put_u16(*key_code);
                w.put_u8(u8::from(*down));
                w.put_u8(modifiers.raw());
            }
            Self::Text { text, tag } => {
                w.put_u32(*tag);
                w.put_bytes(text.as_bytes());
            }
        }
        w.into_vec()
    }

    /// Parses an input event. Positions are finite-checked; an unknown button or type, or
    /// invalid UTF-8 text, is rejected as malformed.
    pub fn decode(data: &[u8]) -> Result<Self> {
        let mut r = ByteReader::new(data);
        let kind = r.read_u8()?;
        match kind {
            1 => {
                let tag = r.read_u32()?;
                let x = r.read_finite_f64("mouseMove.x")?;
                let y = r.read_finite_f64("mouseMove.y")?;
                Ok(Self::MouseMove {
                    normalized: VideoPoint::new(x, y),
                    tag,
                })
            }
            2 | 3 | 7 => {
                let tag = r.read_u32()?;
                let button = MouseButton::from_u8(r.read_u8()?)
                    .ok_or_else(|| VideoProtocolError::malformed("unknown mouse button"))?;
                let click_count = r.read_u8()?;
                let modifiers = InputModifiers(r.read_u8()?);
                let x = r.read_finite_f64("mouseButton.x")?;
                let y = r.read_finite_f64("mouseButton.y")?;
                let normalized = VideoPoint::new(x, y);
                Ok(match kind {
                    2 => Self::MouseDown {
                        button,
                        normalized,
                        click_count,
                        modifiers,
                        tag,
                    },
                    3 => Self::MouseUp {
                        button,
                        normalized,
                        click_count,
                        modifiers,
                        tag,
                    },
                    _ => Self::MouseDrag {
                        button,
                        normalized,
                        click_count,
                        modifiers,
                        tag,
                    },
                })
            }
            4 => {
                let tag = r.read_u32()?;
                let dx = r.read_finite_f64("scroll.dx")?;
                let dy = r.read_finite_f64("scroll.dy")?;
                let x = r.read_finite_f64("scroll.x")?;
                let y = r.read_finite_f64("scroll.y")?;
                Ok(Self::Scroll {
                    dx,
                    dy,
                    normalized: VideoPoint::new(x, y),
                    tag,
                })
            }
            5 => {
                let tag = r.read_u32()?;
                let key_code = r.read_u16()?;
                let down = r.read_u8()? != 0;
                let modifiers = InputModifiers(r.read_u8()?);
                Ok(Self::Key {
                    key_code,
                    down,
                    modifiers,
                    tag,
                })
            }
            6 => {
                let tag = r.read_u32()?;
                let bytes = r.remaining();
                let text = std::str::from_utf8(bytes)
                    .map_err(|_| VideoProtocolError::malformed("input text not valid UTF-8"))?;
                Ok(Self::Text {
                    text: text.to_owned(),
                    tag,
                })
            }
            other => Err(VideoProtocolError::malformed(format!(
                "unknown input event type {other}"
            ))),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn round_trip(e: &InputEvent) {
        assert_eq!(&InputEvent::decode(&e.encode()).unwrap(), e);
    }

    #[test]
    fn round_trips_every_variant() {
        let mods = InputModifiers::SHIFT.union(InputModifiers::COMMAND);
        round_trip(&InputEvent::MouseMove {
            normalized: VideoPoint::new(0.25, 0.75),
            tag: 42,
        });
        round_trip(&InputEvent::MouseDown {
            button: MouseButton::Right,
            normalized: VideoPoint::new(0.1, 0.2),
            click_count: 2,
            modifiers: mods,
            tag: 7,
        });
        round_trip(&InputEvent::MouseUp {
            button: MouseButton::Left,
            normalized: VideoPoint::new(0.3, 0.4),
            click_count: 1,
            modifiers: InputModifiers::default(),
            tag: 8,
        });
        round_trip(&InputEvent::MouseDrag {
            button: MouseButton::Other,
            normalized: VideoPoint::new(0.5, 0.6),
            click_count: 1,
            modifiers: InputModifiers::CONTROL,
            tag: 9,
        });
        round_trip(&InputEvent::Scroll {
            dx: -3.5,
            dy: 12.0,
            normalized: VideoPoint::new(0.0, 1.0),
            tag: 10,
        });
        round_trip(&InputEvent::Key {
            key_code: 0x35,
            down: true,
            modifiers: InputModifiers::OPTION,
            tag: 11,
        });
        round_trip(&InputEvent::Text {
            text: "gõ được 文字".to_owned(),
            tag: 12,
        });
    }

    #[test]
    fn tag_and_type_accessors() {
        let e = InputEvent::Scroll {
            dx: 0.0,
            dy: 0.0,
            normalized: VideoPoint::new(0.0, 0.0),
            tag: 99,
        };
        assert_eq!(e.tag(), 99);
        assert_eq!(e.message_type(), 4);
        assert_eq!(
            InputEvent::MouseDrag {
                button: MouseButton::Left,
                normalized: VideoPoint::new(0.0, 0.0),
                click_count: 1,
                modifiers: InputModifiers::default(),
                tag: 0,
            }
            .message_type(),
            7
        );
    }

    #[test]
    fn rejects_unknown_button_type_and_bad_utf8() {
        // unknown button
        let mut down = InputEvent::MouseDown {
            button: MouseButton::Left,
            normalized: VideoPoint::new(0.0, 0.0),
            click_count: 1,
            modifiers: InputModifiers::default(),
            tag: 0,
        }
        .encode();
        down[5] = 9; // button byte (after type + 4-byte tag)
        assert!(matches!(
            InputEvent::decode(&down),
            Err(VideoProtocolError::Malformed(_))
        ));

        // unknown type
        assert!(matches!(
            InputEvent::decode(&[200]),
            Err(VideoProtocolError::Malformed(_))
        ));

        // invalid UTF-8 text
        let mut text = vec![6u8];
        text.extend_from_slice(&0u32.to_be_bytes());
        text.extend_from_slice(&[0xFF, 0xFF]);
        assert!(matches!(
            InputEvent::decode(&text),
            Err(VideoProtocolError::Malformed(_))
        ));
    }

    #[test]
    fn rejects_nan_scroll() {
        let e = InputEvent::Scroll {
            dx: f64::NAN,
            dy: 0.0,
            normalized: VideoPoint::new(0.0, 0.0),
            tag: 0,
        };
        assert!(matches!(
            InputEvent::decode(&e.encode()),
            Err(VideoProtocolError::Malformed(_))
        ));
    }
}
