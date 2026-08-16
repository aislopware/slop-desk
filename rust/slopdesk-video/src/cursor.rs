//! The cursor side-channel — `Sources/SlopDeskVideoProtocol/CursorCodec.swift` and
//! `CursorShapeCodec.swift` (doc 17 §3.3).
//!
//! The host captures with `showsCursor = false` and streams the pointer separately over a small UDP
//! socket, so pointer latency is RTT and not "RTT plus one encode plus one decode". Three message
//! kinds share the socket, told apart by their leading type byte:
//!
//! | type | message | rate | size |
//! | --- | --- | --- | --- |
//! | 1 | [`CursorUpdate`] — position + `shape_id` + hotspot | ~120 Hz | 36 bytes, fixed |
//! | 2 | [`CursorShapeMessage`] — the shape bitmap | once per new shape | 27 + bitmap |
//! | 3 | [`SwipeNavStatusMessage`] — host swipe eligibility | on change + heartbeat | 6 bytes, fixed |
//!
//! The hot message is deliberately position-ONLY-sized: the spec budget is < 64 bytes and it holds
//! at 36, because a shape id costs two bytes where a bitmap would cost kilobytes at 120 Hz. The
//! client caches bitmaps by `shape_id`, so a shape crosses the wire once per distinct cursor.
//!
//! [`CursorChannelMessage`] is the router: it peeks the first byte and dispatches. An unknown type
//! is a malformed DROP, which is what lets a newer host add a message kind without breaking an
//! older client — it simply ignores what it does not know.

use crate::bytes::{ByteReader, ByteWriter, truncating_u32};
use crate::error::{Result, VideoProtocolError};
use crate::geometry::{VideoPoint, VideoSize};
use crate::swipe_nav::SwipeNavStatusMessage;

/// The hot cursor message: where the pointer is, which cached shape it wears, and whether it shows.
///
/// ```text
/// off 0: u8   type (= 1)
/// off 1: u16  shape_id
/// off 3: u8   visible (0/1)
/// off 4: f64  x         (host-window space, points)
/// off12: f64  y
/// off20: f64  hotspot x
/// off28: f64  hotspot y
/// ```
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct CursorUpdate {
    /// Host-window-space position of the cursor (points).
    pub position: VideoPoint,
    /// Identifier of the cursor shape; the client caches the bitmap under it.
    pub shape_id: u16,
    /// The shape's hotspot offset (points), so the client composites it correctly.
    pub hotspot: VideoPoint,
    /// Whether the cursor is currently visible over the window.
    pub visible: bool,
}

impl CursorUpdate {
    /// The on-wire message type byte for a cursor update.
    pub const MESSAGE_TYPE: u8 = 1;
    /// Encoded size in bytes — fixed, and the reason this message fits the < 64-byte budget.
    pub const ENCODED_SIZE: usize = 36;

    /// Builds an update.
    #[must_use]
    pub const fn new(position: VideoPoint, shape_id: u16, hotspot: VideoPoint, visible: bool) -> Self {
        Self {
            position,
            shape_id,
            hotspot,
            visible,
        }
    }

    /// Encodes the fixed 36-byte big-endian message.
    #[must_use]
    pub fn encode(&self) -> Vec<u8> {
        let mut out = ByteWriter::with_capacity(Self::ENCODED_SIZE);
        out.put_u8(Self::MESSAGE_TYPE);
        out.put_u16(self.shape_id);
        out.put_u8(u8::from(self.visible));
        out.put_f64(self.position.x);
        out.put_f64(self.position.y);
        out.put_f64(self.hotspot.x);
        out.put_f64(self.hotspot.y);
        out.into_vec()
    }

    /// Decodes a cursor update.
    ///
    /// # Errors
    /// [`VideoProtocolError::Truncated`] for a short datagram;
    /// [`VideoProtocolError::Malformed`] for the wrong type byte or a non-finite coordinate. The
    /// finite check is load-bearing: a NaN off the wire would otherwise ride the client's
    /// aspect-fit math into a `CALayer` frame and raise an uncatchable
    /// `CALayerInvalidGeometry`. A corrupt datagram must be DROPPED, never fatal.
    pub fn decode(data: &[u8]) -> Result<Self> {
        let mut reader = ByteReader::new(data);
        let kind = reader.read_u8()?;
        if kind != Self::MESSAGE_TYPE {
            return Err(VideoProtocolError::malformed(format!(
                "not a cursor update (type {kind})"
            )));
        }
        let shape_id = reader.read_u16()?;
        let visible = reader.read_u8()? != 0;
        let x = reader.read_finite_f64("cursor.x")?;
        let y = reader.read_finite_f64("cursor.y")?;
        let hotspot_x = reader.read_finite_f64("cursor.hotspot.x")?;
        let hotspot_y = reader.read_finite_f64("cursor.hotspot.y")?;
        Ok(Self::new(
            VideoPoint::new(x, y),
            shape_id,
            VideoPoint::new(hotspot_x, hotspot_y),
            visible,
        ))
    }
}

/// The rare cursor message: the shape bitmap a [`CursorUpdate`]'s `shape_id` refers to.
///
/// ```text
/// off 0: u8   type (= 2)
/// off 1: u16  shape_id
/// off 3: u16  width   (points; informational — the bitmap is self-describing)
/// off 5: u16  height  (points)
/// off 7: f64  hotspot x
/// off15: f64  hotspot y
/// off23: u32  bitmap length
/// off27: bitmap — PNG bytes
/// ```
///
/// Not size-bounded like the update, but a single cursor PNG fits one 1200-byte datagram, so the
/// shape channel needs no fragmentation.
#[derive(Debug, Clone, PartialEq)]
pub struct CursorShapeMessage {
    /// Identifier the matching [`CursorUpdate`]s reference.
    pub shape_id: u16,
    /// Shape dimensions in points (informational; the bitmap is self-describing).
    pub size: VideoSize,
    /// The shape's hotspot offset (points).
    pub hotspot: VideoPoint,
    /// The shape bitmap, PNG-encoded.
    pub bitmap: Vec<u8>,
}

impl CursorShapeMessage {
    /// The on-wire message type byte for a cursor shape.
    pub const MESSAGE_TYPE: u8 = 2;
    /// Fixed-header size — everything before the bitmap payload.
    pub const HEADER_SIZE: usize = 27;

    /// Builds a shape message.
    #[must_use]
    pub const fn new(shape_id: u16, size: VideoSize, hotspot: VideoPoint, bitmap: Vec<u8>) -> Self {
        Self {
            shape_id,
            size,
            hotspot,
            bitmap,
        }
    }

    /// Encodes the fixed header then the bitmap.
    ///
    /// The on-wire width/height are the ROUND-HALF-AWAY-FROM-ZERO dimensions truncated to 16 bits,
    /// matching Swift's `UInt16(truncatingIfNeeded: Int(size.width.rounded()))` — `f64::round` is
    /// the same rounding rule, and the two-step `as` cast reproduces the same truncation.
    #[must_use]
    pub fn encode(&self) -> Vec<u8> {
        let mut out = ByteWriter::with_capacity(Self::HEADER_SIZE + self.bitmap.len());
        out.put_u8(Self::MESSAGE_TYPE);
        out.put_u16(self.shape_id);
        out.put_u16(rounded_truncating_u16(self.size.width));
        out.put_u16(rounded_truncating_u16(self.size.height));
        out.put_f64(self.hotspot.x);
        out.put_f64(self.hotspot.y);
        out.put_u32(truncating_u32(self.bitmap.len()));
        out.put_bytes(&self.bitmap);
        out.into_vec()
    }

    /// Decodes a shape message.
    ///
    /// # Errors
    /// Whatever [`Self::decode_parts`] answers.
    pub fn decode(data: &[u8]) -> Result<Self> {
        let (shape_id, size, hotspot, bitmap) = Self::decode_parts(data)?;
        Ok(Self::new(shape_id, size, hotspot, bitmap.to_vec()))
    }

    /// Reads a shape message BORROWING its bitmap out of `data` — the same parse as
    /// [`Self::decode`] without the copy, for a caller that is going to keep the datagram
    /// anyway.
    ///
    /// # Errors
    /// [`VideoProtocolError::Truncated`] for a short body or a bitmap length that runs past the
    /// datagram; [`VideoProtocolError::Malformed`] for the wrong type byte or a non-finite hotspot.
    /// The length is bounds-checked BEFORE the read, so a corrupt count drops the datagram rather
    /// than provoking a large allocation.
    pub fn decode_parts(data: &[u8]) -> Result<(u16, VideoSize, VideoPoint, &[u8])> {
        let mut reader = ByteReader::new(data);
        let kind = reader.read_u8()?;
        if kind != Self::MESSAGE_TYPE {
            return Err(VideoProtocolError::malformed(format!(
                "not a cursor shape (type {kind})"
            )));
        }
        let shape_id = reader.read_u16()?;
        let width = reader.read_u16()?;
        let height = reader.read_u16()?;
        let hotspot_x = reader.read_finite_f64("cursorShape.hotspot.x")?;
        let hotspot_y = reader.read_finite_f64("cursorShape.hotspot.y")?;
        let bitmap_length = usize::try_from(reader.read_u32()?)
            .map_err(|_| VideoProtocolError::malformed("cursor shape bitmap length overflows"))?;
        let bitmap = reader.read_bytes(bitmap_length)?;
        Ok((
            shape_id,
            VideoSize::new(f64::from(width), f64::from(height)),
            VideoPoint::new(hotspot_x, hotspot_y),
            bitmap,
        ))
    }
}

/// Anything that can arrive on the cursor side-channel socket.
#[derive(Debug, Clone, PartialEq)]
pub enum CursorChannelMessage {
    /// The hot position update (type 1).
    Update(CursorUpdate),
    /// The rare shape bitmap (type 2).
    Shape(CursorShapeMessage),
    /// The swipe-nav eligibility push (type 3).
    SwipeNavStatus(SwipeNavStatusMessage),
}

impl CursorChannelMessage {
    /// Encodes whichever message this is.
    #[must_use]
    pub fn encode(&self) -> Vec<u8> {
        match *self {
            Self::Update(update) => update.encode(),
            Self::Shape(ref shape) => shape.encode(),
            Self::SwipeNavStatus(status) => status.encode(),
        }
    }

    /// Routes a received cursor datagram by its leading type byte.
    ///
    /// # Errors
    /// [`VideoProtocolError::Truncated`] for an empty datagram, [`VideoProtocolError::Malformed`]
    /// for an unknown leading byte, or whatever the selected decoder answers.
    pub fn decode(data: &[u8]) -> Result<Self> {
        let first = data.first().copied().ok_or(VideoProtocolError::Truncated)?;
        match first {
            CursorUpdate::MESSAGE_TYPE => CursorUpdate::decode(data).map(Self::Update),
            CursorShapeMessage::MESSAGE_TYPE => CursorShapeMessage::decode(data).map(Self::Shape),
            SwipeNavStatusMessage::MESSAGE_TYPE => {
                SwipeNavStatusMessage::decode(data).map(Self::SwipeNavStatus)
            },
            other => {
                Err(VideoProtocolError::malformed(format!(
                    "unknown cursor channel type {other}"
                )))
            },
        }
    }
}

/// Swift's `UInt16(truncatingIfNeeded: Int(value.rounded()))`, spelled out: round half away from
/// zero, take the low 16 bits.
///
/// Not [`crate::bytes::truncating_u16`], and named apart from it on purpose: that one narrows a
/// COUNT, this one carries a coordinate through a rounding the wire format specifies.
const fn rounded_truncating_u16(value: f64) -> u16 {
    #[expect(
        clippy::cast_possible_truncation,
        clippy::cast_sign_loss,
        reason = "reproducing Swift's `truncatingIfNeeded`, where wrapping is the specified behaviour"
    )]
    {
        value.round() as i64 as u16
    }
}

#[cfg(test)]
mod tests {
    use super::{CursorChannelMessage, CursorShapeMessage, CursorUpdate, rounded_truncating_u16};
    use crate::error::VideoProtocolError;
    use crate::geometry::{VideoPoint, VideoSize};
    use crate::swipe_nav::SwipeNavStatusMessage;

    fn sample_update() -> CursorUpdate {
        CursorUpdate::new(
            VideoPoint::new(12.5, -3.25),
            0xBEEF,
            VideoPoint::new(1.0, 2.0),
            false,
        )
    }

    fn sample_shape() -> CursorShapeMessage {
        CursorShapeMessage::new(7, VideoSize::new(32.0, 32.0), VideoPoint::new(4.0, 4.0), vec![
            0x89, 0x50, 0x4E, 0x47, 1, 2, 3,
        ])
    }

    #[test]
    fn the_hot_update_round_trips_and_stays_inside_its_budget() {
        let update = sample_update();
        let bytes = update.encode();
        assert_eq!(bytes.len(), CursorUpdate::ENCODED_SIZE);
        assert!(bytes.len() < 64, "the spec budget for the hot message");
        assert_eq!(CursorUpdate::decode(&bytes), Ok(update));
    }

    #[test]
    fn the_shape_round_trips_including_an_empty_bitmap() {
        for shape in [
            sample_shape(),
            CursorShapeMessage::new(
                1,
                VideoSize::new(16.0, 16.0),
                VideoPoint::new(0.0, 0.0),
                Vec::new(),
            ),
        ] {
            let bytes = shape.encode();
            assert_eq!(bytes.len(), CursorShapeMessage::HEADER_SIZE + shape.bitmap.len());
            assert_eq!(CursorShapeMessage::decode(&bytes), Ok(shape));
        }
    }

    #[test]
    fn the_channel_routes_all_three_kinds_by_the_leading_byte() {
        let status = SwipeNavStatusMessage::new(true, true, 80, false, false, false);
        let cases = [
            CursorChannelMessage::Update(sample_update()),
            CursorChannelMessage::Shape(sample_shape()),
            CursorChannelMessage::SwipeNavStatus(status),
        ];
        for case in cases {
            assert_eq!(CursorChannelMessage::decode(&case.encode()), Ok(case));
        }
    }

    #[test]
    fn an_unknown_type_is_a_drop_which_is_what_lets_a_newer_host_add_messages() {
        assert!(matches!(
            CursorChannelMessage::decode(&[99, 0, 0]),
            Err(VideoProtocolError::Malformed(_))
        ));
        assert_eq!(
            CursorChannelMessage::decode(&[]),
            Err(VideoProtocolError::Truncated)
        );
    }

    #[test]
    fn a_nan_position_is_rejected_because_it_would_crash_the_client_layer() {
        let poisoned = CursorUpdate::new(VideoPoint::new(f64::NAN, 0.0), 0, VideoPoint::new(0.0, 0.0), true);
        assert!(matches!(
            CursorUpdate::decode(&poisoned.encode()),
            Err(VideoProtocolError::Malformed(_))
        ));
    }

    #[test]
    fn a_bitmap_length_past_the_datagram_is_truncation_not_a_giant_allocation() {
        let mut bytes = sample_shape().encode();
        // Rewrite the u32 length at offset 23 to something absurd.
        bytes.splice(23..27, [0xFF, 0xFF, 0xFF, 0xFF]);
        assert_eq!(
            CursorShapeMessage::decode(&bytes),
            Err(VideoProtocolError::Truncated)
        );
    }

    #[test]
    fn the_shape_dimensions_round_half_away_from_zero_then_wrap() {
        assert_eq!(rounded_truncating_u16(31.5), 32);
        assert_eq!(rounded_truncating_u16(32.4), 32);
        assert_eq!(
            rounded_truncating_u16(65536.0),
            0,
            "the low 16 bits, like `truncatingIfNeeded`"
        );
    }
}
