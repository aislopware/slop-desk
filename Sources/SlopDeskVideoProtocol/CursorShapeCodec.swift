import Foundation

/// Out-of-band cursor **shape** (bitmap) message for the cursor side-channel
/// (doc 17 §3.3). The hot ``CursorUpdate`` (position-only, ~120 Hz, < 64 bytes)
/// references a `shapeID`; the *bitmap* for a given `shapeID` is shipped RARELY —
/// only the first time the host sees a new shape — over the SAME cursor UDP socket
/// but as a distinct message type, so the client can cache it by id and composite
/// the cursor without it ever being baked into the captured video (`showsCursor`
/// stays false on the host capture, RESULTS.md "D — cursor strip").
///
/// The bitmap is carried as the raw bytes of an image container the client decodes
/// (the host ships a PNG of the `NSCursor.image`, which is small and lossless for
/// the typical 16–64 px cursor). The hotspot is included so a client that receives
/// the shape before any position update still composites correctly.
///
/// Wire layout (big-endian):
/// ```
/// off 0: UInt8   type (=2 cursorShape — distinct from CursorUpdate's type=1)
/// off 1: UInt16  shapeID
/// off 3: UInt16  width   (points; informational — the bitmap is self-describing)
/// off 5: UInt16  height  (points)
/// off 7: Float64 hotspotX
/// off15: Float64 hotspotY
/// off23: UInt32  bitmapLength
/// off27: [bitmapLength] bytes — PNG-encoded shape image
/// ```
/// Unlike ``CursorUpdate`` this message is NOT size-bounded to 64 bytes (it is the
/// rare bitmap), but a single cursor PNG is comfortably inside one 1200-byte
/// datagram, so the shape channel needs no fragmentation.
public struct CursorShapeMessage: Equatable, Sendable {
    /// Identifier the matching ``CursorUpdate`` messages reference.
    public var shapeID: UInt16
    /// Shape dimensions in points (informational; the bitmap is self-describing).
    public var size: VideoSize
    /// The shape's hotspot offset (points).
    public var hotspot: VideoPoint
    /// The shape bitmap, PNG-encoded.
    public var bitmap: Data

    public init(shapeID: UInt16, size: VideoSize, hotspot: VideoPoint, bitmap: Data) {
        self.shapeID = shapeID
        self.size = size
        self.hotspot = hotspot
        self.bitmap = bitmap
    }

    /// On-wire message type byte for a cursor shape (distinct from ``CursorUpdate``).
    public static let messageType: UInt8 = 2
    /// Fixed-header size (everything before the bitmap payload).
    public static let headerSize = 27

    /// Encodes the shape message (fixed header then bitmap, big-endian). Native Swift is the
    /// single source of truth; the wire format is pinned by the `cursorShape` golden vector.
    /// The on-wire width/height are the round-half-away-from-zero dimensions truncated to 16 bits
    /// (`UInt16(truncatingIfNeeded: Int(size.width.rounded()))`).
    public func encode() -> Data {
        var out = Data(capacity: Self.headerSize + bitmap.count)
        out.append(Self.messageType)
        out.appendBE(shapeID)
        out.appendBE(UInt16(truncatingIfNeeded: Int(size.width.rounded())))
        out.appendBE(UInt16(truncatingIfNeeded: Int(size.height.rounded())))
        out.appendBE(hotspot.x)
        out.appendBE(hotspot.y)
        out.appendBE(UInt32(bitmap.count))
        out.append(bitmap)
        return out
    }

    /// Decodes a cursor shape message (the wire format is pinned by the `cursorShape` golden
    /// vector). Non-finite hotspots are rejected as `.malformed` and a short body / over-long
    /// bitmap length as `.truncated`, so a corrupt datagram is DROPPED, never fatal.
    public static func decode(_ data: Data) throws -> Self {
        var reader = VideoByteReader(data)
        let type = try reader.readUInt8()
        guard type == messageType else {
            throw VideoProtocolError.malformed("not a cursor shape (type \(type))")
        }
        let shapeID = try reader.readUInt16()
        let width = try reader.readUInt16()
        let height = try reader.readUInt16()
        let hx = try reader.readFiniteFloat64("cursorShape.hotspot.x")
        let hy = try reader.readFiniteFloat64("cursorShape.hotspot.y")
        let bitmapLength = try reader.readUInt32()
        let bitmap = try reader.readBytes(Int(bitmapLength))
        return Self(
            shapeID: shapeID,
            size: VideoSize(width: Double(width), height: Double(height)),
            hotspot: VideoPoint(x: hx, y: hy),
            bitmap: bitmap,
        )
    }
}

/// Either message that can arrive on the cursor side-channel UDP socket: the hot
/// position update or the rare shape bitmap. Both share the channel but are told
/// apart by their leading type byte (``CursorUpdate/messageType`` == 1,
/// ``CursorShapeMessage/messageType`` == 2). The client peeks the first byte to
/// route a received cursor datagram.
public enum CursorChannelMessage: Equatable, Sendable {
    case update(CursorUpdate)
    case shape(CursorShapeMessage)

    public func encode() -> Data {
        switch self {
        case let .update(u): u.encode()
        case let .shape(s): s.encode()
        }
    }

    /// Routes a received cursor datagram by its leading type byte.
    public static func decode(_ data: Data) throws -> Self {
        guard let first = data.first else { throw VideoProtocolError.truncated }
        switch first {
        case CursorUpdate.messageType: return try .update(CursorUpdate.decode(data))
        case CursorShapeMessage.messageType: return try .shape(CursorShapeMessage.decode(data))
        default: throw VideoProtocolError.malformed("unknown cursor channel type \(first)")
        }
    }
}
