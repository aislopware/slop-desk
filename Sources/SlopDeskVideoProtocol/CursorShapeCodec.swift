import CSlopDeskFFI
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
    public static let messageType = UInt8(slopdesk_cursor_constant(2))
    /// Fixed-header size (everything before the bitmap payload).
    public static let headerSize = slopdesk_cursor_constant(3)

    /// Encodes the shape message (fixed header then bitmap, big-endian; the wire format is pinned
    /// by the `cursorShape` golden vector). Rounding the point dimensions down to the wire's
    /// `UInt16` is the Rust codec's rule, which is why the size crosses as it is written here.
    public func encode() -> Data {
        var out = Data(count: Self.headerSize + bitmap.count)
        let written = bitmap.withUnsafeBytes { png in
            out.withUnsafeMutableBytes { buffer in
                slopdesk_cursor_encode(wire, png.baseAddress, png.count, buffer.baseAddress, buffer.count)
            }
        }
        precondition(written == out.count, "the cursor-shape codec sized a bitmap differently than it wrote it")
        return out
    }

    /// Decodes a cursor shape message (the wire format is pinned by the `cursorShape` golden
    /// vector). Non-finite hotspots are `.malformed` and a short body / over-long bitmap length
    /// `.truncated`, so a corrupt datagram is DROPPED, never fatal.
    public static func decode(_ data: Data) throws -> Self {
        let flat = try CursorChannelMessage.parse(data, expecting: messageType, called: "cursor shape")
        // The bitmap stays in the caller's datagram; it is copied out here, inside the borrow that
        // already holds the pointer, rather than through a `Data` slice that would retain the whole
        // parent buffer to describe bytes about to be copied anyway.
        let bitmap = data.withUnsafeBytes { bytes -> Data in
            let start = Int(flat.bitmap_offset)
            return Data(UnsafeRawBufferPointer(rebasing: bytes[start..<start + Int(flat.bitmap_length)]))
        }
        return Self(
            shapeID: flat.shape_id,
            size: VideoSize(width: flat.width, height: flat.height),
            hotspot: VideoPoint(x: flat.hotspot_x, y: flat.hotspot_y),
            bitmap: bitmap,
        )
    }

    /// The shape flattened for the boundary. The bitmap does NOT ride inside it — it goes as its
    /// own `(ptr, len)`, so nothing kilobyte-sized is copied to describe itself.
    var wire: SlopDeskCursorMessage {
        var flat = SlopDeskCursorMessage()
        flat.message_type = Self.messageType
        flat.hotspot_x = hotspot.x
        flat.hotspot_y = hotspot.y
        flat.width = size.width
        flat.height = size.height
        flat.shape_id = shapeID
        return flat
    }
}

/// Any message that can arrive on the cursor side-channel UDP socket: the hot
/// position update, the rare shape bitmap, or the rare swipe-nav status push. All
/// share the channel but are told apart by their leading type byte
/// (``CursorUpdate/messageType`` == 1, ``CursorShapeMessage/messageType`` == 2,
/// ``SwipeNavStatusMessage/messageType`` == 3). The client peeks the first byte to
/// route a received cursor datagram; an unknown type is a malformed drop, so an
/// older client simply ignores newer message kinds.
public enum CursorChannelMessage: Equatable, Sendable {
    case update(CursorUpdate)
    case shape(CursorShapeMessage)
    case swipeNavStatus(SwipeNavStatusMessage)

    public func encode() -> Data {
        switch self {
        case let .update(u): u.encode()
        case let .shape(s): s.encode()
        case let .swipeNavStatus(s): s.encode()
        }
    }

    /// Routes a received cursor datagram by its leading type byte. The routing is the only thing
    /// this side does: each arm's bytes are read by the codec that writes them.
    public static func decode(_ data: Data) throws -> Self {
        guard let first = data.first else { throw VideoProtocolError.truncated }
        switch first {
        case CursorUpdate.messageType: return try .update(CursorUpdate.decode(data))
        case CursorShapeMessage.messageType: return try .shape(CursorShapeMessage.decode(data))
        case SwipeNavStatusMessage.messageType: return try .swipeNavStatus(SwipeNavStatusMessage.decode(data))
        default: throw VideoProtocolError.malformed("unknown cursor channel type \(first)")
        }
    }

    /// The one call both cursor grammars make: parse, translate the verdict, and refuse a datagram
    /// that answered as the other type — the socket's type byte is checked, never assumed.
    static func parse(_ data: Data, expecting type: UInt8, called name: String) throws -> SlopDeskCursorMessage {
        var flat = SlopDeskCursorMessage()
        let verdict = data.withUnsafeBytes { bytes in
            slopdesk_cursor_decode(bytes.baseAddress, bytes.count, &flat)
        }
        switch verdict {
        case UInt32(SLOPDESK_CURSOR_DECODE_TRUNCATED): throw VideoProtocolError.truncated
        case UInt32(SLOPDESK_CURSOR_DECODE_MALFORMED):
            throw VideoProtocolError.malformed("not a \(name) (type \(data.first ?? 0))")
        default: break
        }
        guard flat.message_type == type else {
            throw VideoProtocolError.malformed("not a \(name) (type \(flat.message_type))")
        }
        return flat
    }
}
