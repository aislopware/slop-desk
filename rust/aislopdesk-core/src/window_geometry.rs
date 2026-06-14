//! Window-geometry metadata channel codec — a port of Swift `WindowGeometryCodec`.
//!
//! A separate channel carrying a remote GUI window's move / resize / bounds / title so
//! the client window can reposition before the next video frame.

use crate::bytes::{ByteReader, ByteWriter};
use crate::error::{Result, VideoProtocolError};
use crate::geometry::{VideoPoint, VideoRect, VideoSize};

/// A window-geometry message: move, resize, combined bounds, or a title change.
///
/// Wire: a `u8` type byte (move=1, resize=2, bounds=3, title=4) followed by the
/// type-specific payload (big-endian `f64`s; title is raw UTF-8 to the end of the
/// datagram, decoded **strictly**).
#[derive(Debug, Clone, PartialEq)]
pub enum WindowGeometryMessage {
    /// Window moved to a new top-left origin (host CG space, points).
    Move(VideoPoint),
    /// Window resized to a new size (points).
    Resize(VideoSize),
    /// Window moved AND resized in one frame (the common drag-resize case).
    Bounds(VideoRect),
    /// Window title changed (UTF-8).
    Title(String),
}

impl WindowGeometryMessage {
    /// The on-wire type byte.
    #[must_use]
    pub const fn message_type(&self) -> u8 {
        match self {
            Self::Move(_) => 1,
            Self::Resize(_) => 2,
            Self::Bounds(_) => 3,
            Self::Title(_) => 4,
        }
    }

    /// Serialises the message.
    #[must_use]
    pub fn encode(&self) -> Vec<u8> {
        let mut w = ByteWriter::new();
        w.put_u8(self.message_type());
        match self {
            Self::Move(p) => {
                w.put_f64(p.x);
                w.put_f64(p.y);
            }
            Self::Resize(s) => {
                w.put_f64(s.width);
                w.put_f64(s.height);
            }
            Self::Bounds(r) => {
                w.put_f64(r.origin.x);
                w.put_f64(r.origin.y);
                w.put_f64(r.size.width);
                w.put_f64(r.size.height);
            }
            Self::Title(title) => w.put_bytes(title.as_bytes()),
        }
        w.into_vec()
    }

    /// Parses a window-geometry message. Coordinates are finite-checked; the title is
    /// decoded as **strict** UTF-8 (invalid bytes → malformed, NOT lossy).
    pub fn decode(data: &[u8]) -> Result<Self> {
        let mut r = ByteReader::new(data);
        let kind = r.read_u8()?;
        match kind {
            1 => {
                let x = r.read_finite_f64("geometry.move.x")?;
                let y = r.read_finite_f64("geometry.move.y")?;
                Ok(Self::Move(VideoPoint::new(x, y)))
            }
            2 => {
                let width = r.read_finite_f64("geometry.resize.w")?;
                let height = r.read_finite_f64("geometry.resize.h")?;
                Ok(Self::Resize(VideoSize::new(width, height)))
            }
            3 => {
                let x = r.read_finite_f64("geometry.bounds.x")?;
                let y = r.read_finite_f64("geometry.bounds.y")?;
                let width = r.read_finite_f64("geometry.bounds.w")?;
                let height = r.read_finite_f64("geometry.bounds.h")?;
                Ok(Self::Bounds(VideoRect::xywh(x, y, width, height)))
            }
            4 => {
                let bytes = r.remaining();
                let title = std::str::from_utf8(bytes)
                    .map_err(|_| VideoProtocolError::malformed("window title not valid UTF-8"))?;
                Ok(Self::Title(title.to_owned()))
            }
            other => Err(VideoProtocolError::malformed(format!(
                "unknown window-geometry message type {other}"
            ))),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trips_all_variants() {
        let cases = [
            WindowGeometryMessage::Move(VideoPoint::new(10.0, 20.0)),
            WindowGeometryMessage::Resize(VideoSize::new(640.0, 480.0)),
            WindowGeometryMessage::Bounds(VideoRect::xywh(1.0, 2.0, 3.0, 4.0)),
            WindowGeometryMessage::Title("héllo · 窗口".to_owned()),
        ];
        for c in cases {
            assert_eq!(WindowGeometryMessage::decode(&c.encode()).unwrap(), c);
        }
    }

    #[test]
    fn rejects_invalid_utf8_title_strictly() {
        let mut bytes = vec![4u8];
        bytes.extend_from_slice(&[0xFF, 0xFE]); // invalid UTF-8
        assert!(matches!(
            WindowGeometryMessage::decode(&bytes),
            Err(VideoProtocolError::Malformed(_))
        ));
    }

    #[test]
    fn rejects_unknown_type_and_nonfinite() {
        assert!(matches!(
            WindowGeometryMessage::decode(&[9]),
            Err(VideoProtocolError::Malformed(_))
        ));
        let mut m = WindowGeometryMessage::Move(VideoPoint::new(f64::INFINITY, 0.0)).encode();
        assert!(matches!(
            WindowGeometryMessage::decode(&m),
            Err(VideoProtocolError::Malformed(_))
        ));
        m.truncate(2); // also too short for the f64s
        assert!(matches!(
            WindowGeometryMessage::decode(&m),
            Err(VideoProtocolError::Truncated)
        ));
    }
}
