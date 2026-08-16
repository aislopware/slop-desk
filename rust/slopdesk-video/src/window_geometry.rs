//! Window-geometry metadata channel — `Sources/SlopDeskVideoProtocol/WindowGeometryCodec.swift`
//! (doc 17 §3.8).
//!
//! A SEPARATE channel carrying a remote GUI window's move / resize / title, so the client's window
//! and view can reposition *before* the next video frame lands rather than a frame behind it. Every
//! per-window remoting solution — RDP RemoteApp/RAIL, X11, Xpra — grows this channel eventually.
//!
//! Host-side production is two-sourced: AX `kAXWindowMovedNotification` fires at the END of a move,
//! so during a drag the host polls `CGWindowListCopyWindowInfo` per frame instead (doc 18 §B). This
//! module is the pure wire form of what that watcher emits.
//!
//! ## Wire
//!
//! ```text
//! off 0: u8  type — move=1, resize=2, bounds=3, title=4
//! then:      the variant payload as big-endian f64s, or (title) raw UTF-8 to the datagram end
//! ```
//!
//! Pinned by the `windowGeometry` golden vectors.
//!
//! ## The title is STRICT UTF-8, and that is not an accident
//!
//! [`WindowGeometryMessage::decode`] rejects invalid UTF-8 rather than replacing it with U+FFFD.
//! The video path is split on this deliberately and the split must survive the port: this codec and
//! `input_event` are strict, while `video_control` is lossy. The reason is what a mangled string
//! COSTS. A window title is display-only, so dropping the datagram loses one title update that the
//! next poll re-sends; silently substituting replacement characters would instead paint mojibake
//! that never self-heals. A control message, by contrast, carries a decision — dropping it loses
//! the decision.

use crate::bytes::{ByteReader, ByteWriter};
use crate::error::{Result, VideoProtocolError};
use crate::geometry::{VideoPoint, VideoRect, VideoSize};

/// A window-geometry message: move, resize, combined bounds, or a title change.
#[derive(Debug, Clone, PartialEq)]
pub enum WindowGeometryMessage {
    /// Window moved to a new top-left origin (host CG space, points).
    Move(VideoPoint),
    /// Window resized to a new size (points).
    Resize(VideoSize),
    /// Window moved AND resized in one frame — the common drag-resize case, sent as one message so
    /// the client never renders a half-applied geometry.
    Bounds(VideoRect),
    /// Window title changed (UTF-8).
    Title(String),
}

impl WindowGeometryMessage {
    /// The on-wire type byte.
    #[must_use]
    pub const fn message_type(&self) -> u8 {
        match *self {
            Self::Move(_) => 1,
            Self::Resize(_) => 2,
            Self::Bounds(_) => 3,
            Self::Title(_) => 4,
        }
    }

    /// Serialises the message: a type byte, then the variant payload as big-endian `f64`s (a title
    /// trails as raw UTF-8 to the end of the datagram).
    #[must_use]
    pub fn encode(&self) -> Vec<u8> {
        let mut out = ByteWriter::new();
        out.put_u8(self.message_type());
        match *self {
            Self::Move(point) => {
                out.put_f64(point.x);
                out.put_f64(point.y);
            },
            Self::Resize(size) => {
                out.put_f64(size.width);
                out.put_f64(size.height);
            },
            Self::Bounds(rect) => {
                out.put_f64(rect.origin.x);
                out.put_f64(rect.origin.y);
                out.put_f64(rect.size.width);
                out.put_f64(rect.size.height);
            },
            Self::Title(ref title) => out.put_bytes(title.as_bytes()),
        }
        out.into_vec()
    }

    /// Parses a window-geometry message.
    ///
    /// # Errors
    /// [`VideoProtocolError::Truncated`] for a short body;
    /// [`VideoProtocolError::Malformed`] for an unknown type byte, a non-finite coordinate, or a
    /// title that is not valid UTF-8 (strict — never lossy; see the module docs).
    pub fn decode(data: &[u8]) -> Result<Self> {
        let mut reader = ByteReader::new(data);
        let kind = reader.read_u8()?;
        match kind {
            1 => {
                let x = reader.read_finite_f64("geometry.move.x")?;
                let y = reader.read_finite_f64("geometry.move.y")?;
                Ok(Self::Move(VideoPoint::new(x, y)))
            },
            2 => {
                let width = reader.read_finite_f64("geometry.resize.w")?;
                let height = reader.read_finite_f64("geometry.resize.h")?;
                Ok(Self::Resize(VideoSize::new(width, height)))
            },
            3 => {
                let x = reader.read_finite_f64("geometry.bounds.x")?;
                let y = reader.read_finite_f64("geometry.bounds.y")?;
                let width = reader.read_finite_f64("geometry.bounds.w")?;
                let height = reader.read_finite_f64("geometry.bounds.h")?;
                Ok(Self::Bounds(VideoRect::xywh(x, y, width, height)))
            },
            4 => {
                let title = core::str::from_utf8(reader.remaining())
                    .map_err(|_| VideoProtocolError::malformed("window title not valid UTF-8"))?;
                Ok(Self::Title(title.to_owned()))
            },
            other => {
                Err(VideoProtocolError::malformed(format!(
                    "unknown window-geometry message type {other}"
                )))
            },
        }
    }
}

#[cfg(test)]
mod tests {
    use super::WindowGeometryMessage;
    use crate::error::VideoProtocolError;
    use crate::geometry::{VideoPoint, VideoRect, VideoSize};

    #[test]
    fn every_variant_round_trips() {
        let cases = [
            WindowGeometryMessage::Move(VideoPoint::new(10.0, 20.0)),
            WindowGeometryMessage::Resize(VideoSize::new(640.0, 480.0)),
            WindowGeometryMessage::Bounds(VideoRect::xywh(1.0, 2.0, 3.0, 4.0)),
            WindowGeometryMessage::Title("héllo · 窗口".to_owned()),
        ];
        for case in cases {
            assert_eq!(WindowGeometryMessage::decode(&case.encode()), Ok(case));
        }
    }

    #[test]
    fn an_invalid_utf8_title_is_dropped_rather_than_replaced() {
        // The whole point of the strict decode: no U+FFFD ever reaches a titlebar.
        let bytes = [4, 0xFF, 0xFE];
        assert!(matches!(
            WindowGeometryMessage::decode(&bytes),
            Err(VideoProtocolError::Malformed(_))
        ));
    }

    #[test]
    fn an_empty_title_is_legal_and_is_not_truncation() {
        assert_eq!(
            WindowGeometryMessage::decode(&[4]),
            Ok(WindowGeometryMessage::Title(String::new()))
        );
    }

    #[test]
    fn an_unknown_type_a_nonfinite_coordinate_and_a_short_body_all_fail_distinctly() {
        assert!(matches!(
            WindowGeometryMessage::decode(&[9]),
            Err(VideoProtocolError::Malformed(_))
        ));
        let mut infinite = WindowGeometryMessage::Move(VideoPoint::new(f64::INFINITY, 0.0)).encode();
        assert!(matches!(
            WindowGeometryMessage::decode(&infinite),
            Err(VideoProtocolError::Malformed(_))
        ));
        infinite.truncate(2);
        assert_eq!(
            WindowGeometryMessage::decode(&infinite),
            Err(VideoProtocolError::Truncated)
        );
    }
}
