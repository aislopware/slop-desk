import CSlopDeskFFI
import Foundation

/// Cursor side-channel message (doc 17 §3.3): the host strips the cursor from the
/// video (`showsCursor=false`) and instead streams its position + shape over a
/// SEPARATE small UDP socket so pointer latency = RTT, decoupled from encode/decode.
///
/// The message is deliberately tiny (the spec requires **< 64 bytes**): it carries
/// the cursor position in **host-window space** (points), a `shapeID` referencing a
/// shape the client has cached, and the shape's hotspot. Shape *bitmaps* are sent
/// rarely (only when a new `shapeID` appears) over a side path — this hot message
/// stays position-only-sized so it can fire at ~120 Hz.
///
/// Wire layout (big-endian), `< 64` bytes:
/// ```
/// off 0: UInt8   type (=1 cursorUpdate)
/// off 1: UInt16  shapeID
/// off 3: UInt8   visible (0/1)
/// off 4: Float64 x        (host-window-space point)
/// off12: Float64 y
/// off20: Float64 hotspotX
/// off28: Float64 hotspotY
/// ```
/// = **36 bytes** — comfortably under the 64-byte budget. `rust/slopdesk-video`'s `cursor` lays
/// those bytes down and vends both numbers; this side only says which message it is.
public struct CursorUpdate: Equatable, Sendable {
    /// Host-window-space position of the cursor (points).
    public var position: VideoPoint
    /// Identifier of the cursor shape (client caches the bitmap by this id).
    public var shapeID: UInt16
    /// The shape's hotspot offset (points), so the client composites it correctly.
    public var hotspot: VideoPoint
    /// Whether the cursor is currently visible over the window.
    public var visible: Bool

    public init(position: VideoPoint, shapeID: UInt16, hotspot: VideoPoint, visible: Bool = true) {
        self.position = position
        self.shapeID = shapeID
        self.hotspot = hotspot
        self.visible = visible
    }

    /// On-wire message type byte for a cursor update.
    public static let messageType = UInt8(slopdesk_cursor_constant(0))
    /// Encoded size in bytes (fixed).
    public static let encodedSize = slopdesk_cursor_constant(1)

    /// Encodes the update (fixed 36-byte big-endian message; the wire format is pinned by the
    /// `cursorUpdate` golden vector).
    public func encode() -> Data {
        var out = Data(count: Self.encodedSize)
        let written = out.withUnsafeMutableBytes { buffer in
            slopdesk_cursor_encode(wire, nil, 0, buffer.baseAddress, buffer.count)
        }
        precondition(written == Self.encodedSize, "the cursor codec and its own fixed size disagree")
        return out
    }

    /// Decodes a cursor update (the wire format is pinned by the `cursorUpdate` golden vector).
    /// Non-finite coordinates are rejected as `.malformed` by the Rust codec: a NaN off the wire
    /// would otherwise propagate through the client's aspect-fit math into a `CALayer` frame and
    /// crash with `CALayerInvalidGeometry`. A malformed datagram must be DROPPED, not fatal.
    public static func decode(_ data: Data) throws -> Self {
        let flat = try CursorChannelMessage.parse(data, expecting: messageType, called: "cursor update")
        return Self(
            position: VideoPoint(x: flat.x, y: flat.y),
            shapeID: flat.shape_id,
            hotspot: VideoPoint(x: flat.hotspot_x, y: flat.hotspot_y),
            visible: flat.visible,
        )
    }

    /// The update flattened for the boundary — one value across, with `message_type` picking the
    /// arm that reads it.
    var wire: SlopDeskCursorMessage {
        var flat = SlopDeskCursorMessage()
        flat.message_type = Self.messageType
        flat.x = position.x
        flat.y = position.y
        flat.hotspot_x = hotspot.x
        flat.hotspot_y = hotspot.y
        flat.shape_id = shapeID
        flat.visible = visible
        return flat
    }
}
