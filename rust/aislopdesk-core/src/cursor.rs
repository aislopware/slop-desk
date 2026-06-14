//! Cursor side-channel codecs — a port of Swift `CursorCodec` / `CursorShapeCodec`.
//!
//! The host strips the cursor from the video and streams its position + shape over a
//! separate small UDP socket so pointer latency = RTT. The hot [`CursorUpdate`] is tiny
//! (36 bytes, ~120 Hz); the [`CursorShapeMessage`] bitmap is sent rarely. Both share the
//! socket and are told apart by a leading type byte ([`CursorChannelMessage`]).

use crate::bytes::{ByteReader, ByteWriter};
use crate::error::{Result, VideoProtocolError};
use crate::geometry::{VideoPoint, VideoSize};

/// Hot cursor position/visibility update (36 bytes, big-endian).
///
/// Wire: `u8 type(=1) · u16 shape_id · u8 visible · f64 x · f64 y · f64 hotspot_x · f64 hotspot_y`.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct CursorUpdate {
    /// Host-window-space position of the cursor (points).
    pub position: VideoPoint,
    /// Identifier of the cursor shape (client caches the bitmap by this id).
    pub shape_id: u16,
    /// The shape's hotspot offset (points).
    pub hotspot: VideoPoint,
    /// Whether the cursor is currently visible over the window.
    pub visible: bool,
}

impl CursorUpdate {
    /// On-wire message type byte for a cursor update.
    pub const MESSAGE_TYPE: u8 = 1;
    /// Encoded size in bytes (fixed).
    pub const ENCODED_SIZE: usize = 36;

    /// Serialises the update (fixed 36 bytes).
    #[must_use]
    pub fn encode(&self) -> Vec<u8> {
        let mut w = ByteWriter::with_capacity(Self::ENCODED_SIZE);
        w.put_u8(Self::MESSAGE_TYPE);
        w.put_u16(self.shape_id);
        w.put_u8(u8::from(self.visible));
        w.put_f64(self.position.x);
        w.put_f64(self.position.y);
        w.put_f64(self.hotspot.x);
        w.put_f64(self.hotspot.y);
        w.into_vec()
    }

    /// Parses a cursor update. Rejects a wrong type byte or a non-finite coordinate
    /// (which would propagate `NaN` into client layer geometry and crash).
    pub fn decode(data: &[u8]) -> Result<Self> {
        let mut r = ByteReader::new(data);
        let kind = r.read_u8()?;
        if kind != Self::MESSAGE_TYPE {
            return Err(VideoProtocolError::malformed(format!(
                "not a cursor update (type {kind})"
            )));
        }
        let shape_id = r.read_u16()?;
        let visible = r.read_u8()? != 0;
        let x = r.read_finite_f64("cursor.x")?;
        let y = r.read_finite_f64("cursor.y")?;
        let hx = r.read_finite_f64("cursor.hotspot.x")?;
        let hy = r.read_finite_f64("cursor.hotspot.y")?;
        Ok(Self {
            position: VideoPoint::new(x, y),
            shape_id,
            hotspot: VideoPoint::new(hx, hy),
            visible,
        })
    }
}

/// Out-of-band cursor shape (PNG bitmap) message.
///
/// Wire: `u8 type(=2) · u16 shape_id · u16 width · u16 height · f64 hotspot_x · f64
/// hotspot_y · u32 bitmap_len · [bitmap_len] PNG bytes`.
#[derive(Debug, Clone, PartialEq)]
pub struct CursorShapeMessage {
    /// Identifier the matching [`CursorUpdate`] messages reference.
    pub shape_id: u16,
    /// Shape dimensions in points (informational; the bitmap is self-describing).
    pub size: VideoSize,
    /// The shape's hotspot offset (points).
    pub hotspot: VideoPoint,
    /// The shape bitmap, PNG-encoded.
    pub bitmap: Vec<u8>,
}

impl CursorShapeMessage {
    /// On-wire message type byte for a cursor shape (distinct from [`CursorUpdate`]).
    pub const MESSAGE_TYPE: u8 = 2;
    /// Fixed-header size (everything before the bitmap payload).
    pub const HEADER_SIZE: usize = 27;

    /// Serialises the shape message (header then bitmap). The on-wire width/height are
    /// the rounded dimensions truncated to 16 bits (matching Swift's
    /// `UInt16(truncatingIfNeeded: Int(size.width.rounded()))`).
    #[must_use]
    pub fn encode(&self) -> Vec<u8> {
        let mut w = ByteWriter::with_capacity(Self::HEADER_SIZE + self.bitmap.len());
        w.put_u8(Self::MESSAGE_TYPE);
        w.put_u16(self.shape_id);
        w.put_u16(round_to_u16(self.size.width));
        w.put_u16(round_to_u16(self.size.height));
        w.put_f64(self.hotspot.x);
        w.put_f64(self.hotspot.y);
        w.put_u32(self.bitmap.len() as u32);
        w.put_bytes(&self.bitmap);
        w.into_vec()
    }

    /// Parses a cursor shape message.
    pub fn decode(data: &[u8]) -> Result<Self> {
        let mut r = ByteReader::new(data);
        let kind = r.read_u8()?;
        if kind != Self::MESSAGE_TYPE {
            return Err(VideoProtocolError::malformed(format!(
                "not a cursor shape (type {kind})"
            )));
        }
        let shape_id = r.read_u16()?;
        let width = r.read_u16()?;
        let height = r.read_u16()?;
        let hx = r.read_finite_f64("cursorShape.hotspot.x")?;
        let hy = r.read_finite_f64("cursorShape.hotspot.y")?;
        let bitmap_len = r.read_u32()?;
        let bitmap = r.read_bytes(bitmap_len as usize)?.to_vec();
        Ok(Self {
            shape_id,
            size: VideoSize::new(f64::from(width), f64::from(height)),
            hotspot: VideoPoint::new(hx, hy),
            bitmap,
        })
    }
}

/// `UInt16(truncatingIfNeeded: Int(value.rounded()))`: round half-away-from-zero, take
/// the low 16 bits. For the small positive cursor dimensions this is exact. (Swift's
/// `Int(_:)` traps on non-finite; cursor sizes are always finite, asserted in debug.)
fn round_to_u16(value: f64) -> u16 {
    debug_assert!(value.is_finite(), "cursor dimension must be finite");
    (value.round() as i64) as u16
}

/// Either message that can arrive on the cursor side-channel UDP socket.
#[derive(Debug, Clone, PartialEq)]
pub enum CursorChannelMessage {
    /// The hot position/visibility update.
    Update(CursorUpdate),
    /// The rare shape bitmap.
    Shape(CursorShapeMessage),
}

impl CursorChannelMessage {
    /// Serialises whichever message this is.
    #[must_use]
    pub fn encode(&self) -> Vec<u8> {
        match self {
            Self::Update(u) => u.encode(),
            Self::Shape(s) => s.encode(),
        }
    }

    /// Routes a received cursor datagram by its leading type byte.
    pub fn decode(data: &[u8]) -> Result<Self> {
        match data.first() {
            None => Err(VideoProtocolError::Truncated),
            Some(&CursorUpdate::MESSAGE_TYPE) => Ok(Self::Update(CursorUpdate::decode(data)?)),
            Some(&CursorShapeMessage::MESSAGE_TYPE) => {
                Ok(Self::Shape(CursorShapeMessage::decode(data)?))
            }
            Some(&other) => Err(VideoProtocolError::malformed(format!(
                "unknown cursor channel type {other}"
            ))),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cursor_update_round_trip_and_size() {
        let u = CursorUpdate {
            position: VideoPoint::new(12.5, -3.25),
            shape_id: 0xBEEF,
            hotspot: VideoPoint::new(1.0, 2.0),
            visible: false,
        };
        let bytes = u.encode();
        assert_eq!(bytes.len(), CursorUpdate::ENCODED_SIZE);
        assert_eq!(CursorUpdate::decode(&bytes).unwrap(), u);
    }

    #[test]
    fn cursor_update_rejects_wrong_type() {
        let mut bytes = CursorUpdate {
            position: VideoPoint::new(0.0, 0.0),
            shape_id: 1,
            hotspot: VideoPoint::new(0.0, 0.0),
            visible: true,
        }
        .encode();
        bytes[0] = 9;
        assert!(matches!(
            CursorUpdate::decode(&bytes),
            Err(VideoProtocolError::Malformed(_))
        ));
    }

    #[test]
    fn cursor_update_rejects_nan_position() {
        let u = CursorUpdate {
            position: VideoPoint::new(f64::NAN, 0.0),
            shape_id: 1,
            hotspot: VideoPoint::new(0.0, 0.0),
            visible: true,
        };
        let bytes = u.encode();
        assert!(matches!(
            CursorUpdate::decode(&bytes),
            Err(VideoProtocolError::Malformed(_))
        ));
    }

    #[test]
    fn cursor_shape_round_trip() {
        let s = CursorShapeMessage {
            shape_id: 7,
            size: VideoSize::new(32.4, 32.6),
            hotspot: VideoPoint::new(4.0, 4.0),
            bitmap: vec![0x89, 0x50, 0x4E, 0x47, 1, 2, 3],
        };
        let bytes = s.encode();
        let back = CursorShapeMessage::decode(&bytes).unwrap();
        // width 32.4 → 32, height 32.6 → 33 (round half away from zero).
        assert_eq!(back.size, VideoSize::new(32.0, 33.0));
        assert_eq!(back.shape_id, s.shape_id);
        assert_eq!(back.hotspot, s.hotspot);
        assert_eq!(back.bitmap, s.bitmap);
    }

    #[test]
    fn channel_routes_by_first_byte() {
        let u = CursorChannelMessage::Update(CursorUpdate {
            position: VideoPoint::new(1.0, 1.0),
            shape_id: 2,
            hotspot: VideoPoint::new(0.0, 0.0),
            visible: true,
        });
        assert_eq!(CursorChannelMessage::decode(&u.encode()).unwrap(), u);
        assert!(matches!(
            CursorChannelMessage::decode(&[]),
            Err(VideoProtocolError::Truncated)
        ));
        assert!(matches!(
            CursorChannelMessage::decode(&[99]),
            Err(VideoProtocolError::Malformed(_))
        ));
    }
}
