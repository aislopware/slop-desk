import CSlopDeskFFI
import Foundation

/// Window-geometry metadata channel (doc 17 §3.8): a SEPARATE channel carrying a
/// remote GUI window's move / resize / title so the client `NSWindow`/view can
/// reposition *before* the next video frame. Every per-window remoting solution
/// (RDP RemoteApp/RAIL, X11, Xpra) has this.
///
/// Host-side production: AX `kAXWindowMovedNotification` fires at the END of a move;
/// during a drag the host polls `CGWindowListCopyWindowInfo` per frame so the client
/// window never lags (doc 18 §B). This codec is the pure wire form.
///
/// Wire: a `UInt8` type byte (move=1, resize=2, bounds=3, title=4) followed by the
/// type-specific payload (big-endian `Float64`s; title is raw UTF-8 to the end of the
/// datagram, decoded **strictly**). Pinned by the `windowGeometry` golden vectors.
public enum WindowGeometryMessage: Equatable, Sendable {
    /// Window moved to a new top-left origin (host CG space, points).
    case move(VideoPoint)
    /// Window resized to a new size (points).
    case resize(VideoSize)
    /// Window moved AND resized in one frame (the common drag-resize case).
    case bounds(VideoRect)
    /// Window title changed (UTF-8).
    case title(String)

    public var messageType: UInt8 {
        switch self {
        case .move: 1
        case .resize: 2
        case .bounds: 3
        case .title: 4
        }
    }

    /// Serialises the message: a type byte then the variant payload as big-endian `Float64`s
    /// (title trails as raw UTF-8 to the end of the datagram). `rust/slopdesk-video`'s
    /// `window_geometry` lays the bytes down; this side only says which message it is.
    public func encode() -> Data {
        let title = if case let .title(text) = self { Data(text.utf8) } else { Data() }
        return title.withUnsafeBytes { bytes in
            withUnsafeTemporaryAllocation(of: UInt8.self, capacity: Self.scratchBytes) { scratch in
                let needed = slopdesk_window_geometry_encode(
                    wire, bytes.baseAddress, bytes.count, scratch.baseAddress, scratch.count,
                )
                precondition(needed > 0, "the geometry codec refused a message this type can express")
                guard needed > scratch.count else {
                    return Data(UnsafeBufferPointer(start: scratch.baseAddress, count: needed))
                }
                // Only a long title outgrows the scratch; the four-Double arms are already written
                // by the call that sized them.
                var out = Data(count: needed)
                let written = out.withUnsafeMutableBytes { buffer in
                    slopdesk_window_geometry_encode(
                        wire, bytes.baseAddress, bytes.count, buffer.baseAddress, buffer.count,
                    )
                }
                precondition(written == needed, "the geometry codec sized a message differently than it wrote it")
                return out
            }
        }
    }

    /// Stack the fixed-size arms are written into on the first try. Comfortably above the widest of
    /// them (bounds); too small would only ever be slower, never wrong.
    private static let scratchBytes = 64

    /// Parses a window-geometry message. Every guard is the Rust codec's: a non-finite coordinate,
    /// a title that is not strictly UTF-8, and an unknown type byte are all `.malformed`; a short
    /// body is `.truncated`. The reason stays on that side — the datagram is dropped either way.
    public static func decode(_ data: Data) throws -> Self {
        var flat = SlopDeskWindowGeometry()
        let verdict = data.withUnsafeBytes { bytes in
            slopdesk_window_geometry_decode(bytes.baseAddress, bytes.count, &flat)
        }
        switch verdict {
        case UInt32(SLOPDESK_METADATA_DECODE_TRUNCATED): throw VideoProtocolError.truncated
        case UInt32(SLOPDESK_METADATA_DECODE_MALFORMED):
            throw VideoProtocolError.malformed("unacceptable window-geometry message")
        default: break
        }
        switch flat.message_type {
        case 1: return .move(VideoPoint(x: flat.x, y: flat.y))
        case 2: return .resize(VideoSize(width: flat.width, height: flat.height))
        case 3: return .bounds(VideoRect(x: flat.x, y: flat.y, width: flat.width, height: flat.height))
        default:
            // The title arm: its bytes stay in the caller's datagram, and the decode above proved
            // every one of them is UTF-8 before it reported where they start.
            return .title(String(decoding: data.dropFirst(Int(flat.title_offset)), as: UTF8.self))
        }
    }

    /// The message flattened for the boundary: one value with `messageType` saying which fields of
    /// it carry meaning.
    private var wire: SlopDeskWindowGeometry {
        var flat = SlopDeskWindowGeometry()
        flat.message_type = messageType
        switch self {
        case let .move(p):
            flat.x = p.x
            flat.y = p.y
        case let .resize(s):
            flat.width = s.width
            flat.height = s.height
        case let .bounds(r):
            flat.x = r.origin.x
            flat.y = r.origin.y
            flat.width = r.size.width
            flat.height = r.size.height
        case .title:
            flat.title_offset = slopdesk_window_geometry_constant(0)
        }
        return flat
    }
}
