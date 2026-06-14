import Foundation

/// Window-geometry metadata channel (doc 17 §3.8): a SEPARATE channel carrying a
/// remote GUI window's move / resize / title so the client `NSWindow`/view can
/// reposition *before* the next video frame. Every per-window remoting solution
/// (RDP RemoteApp/RAIL, X11, Xpra) has this.
///
/// Host-side production: AX `kAXWindowMovedNotification` fires at the END of a move;
/// during a drag the host polls `CGWindowListCopyWindowInfo` per frame so the client
/// window never lags (doc 18 §B). This codec is the pure wire form.
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

    public func encode() -> Data {
        var out = Data()
        out.append(messageType)
        switch self {
        case let .move(p):
            out.appendBE(p.x)
            out.appendBE(p.y)
        case let .resize(s):
            out.appendBE(s.width)
            out.appendBE(s.height)
        case let .bounds(r):
            out.appendBE(r.origin.x)
            out.appendBE(r.origin.y)
            out.appendBE(r.size.width)
            out.appendBE(r.size.height)
        case let .title(title):
            out.append(Data(title.utf8))
        }
        return out
    }

    public static func decode(_ data: Data) throws -> Self {
        var reader = VideoByteReader(data)
        let type = try reader.readUInt8()
        switch type {
        case 1:
            let x = try reader.readFiniteFloat64("geometry.move.x")
            let y = try reader.readFiniteFloat64("geometry.move.y")
            return .move(VideoPoint(x: x, y: y))
        case 2:
            let w = try reader.readFiniteFloat64("geometry.resize.w")
            let h = try reader.readFiniteFloat64("geometry.resize.h")
            return .resize(VideoSize(width: w, height: h))
        case 3:
            let x = try reader.readFiniteFloat64("geometry.bounds.x")
            let y = try reader.readFiniteFloat64("geometry.bounds.y")
            let w = try reader.readFiniteFloat64("geometry.bounds.w")
            let h = try reader.readFiniteFloat64("geometry.bounds.h")
            return .bounds(VideoRect(x: x, y: y, width: w, height: h))
        case 4:
            let bytes = reader.remaining()
            guard let title = String(data: bytes, encoding: .utf8) else {
                throw VideoProtocolError.malformed("window title not valid UTF-8")
            }
            return .title(title)
        default:
            throw VideoProtocolError.malformed("unknown window-geometry message type \(type)")
        }
    }
}
