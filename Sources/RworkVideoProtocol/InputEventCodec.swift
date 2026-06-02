import Foundation

/// Modifier-key bitmask carried by input events (matches the CGEventFlags the host
/// will apply, but kept platform-free here).
public struct InputModifiers: OptionSet, Sendable, Equatable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let shift = InputModifiers(rawValue: 1 << 0)
    public static let control = InputModifiers(rawValue: 1 << 1)
    public static let option = InputModifiers(rawValue: 1 << 2)
    public static let command = InputModifiers(rawValue: 1 << 3)
    public static let capsLock = InputModifiers(rawValue: 1 << 4)
    public static let function = InputModifiers(rawValue: 1 << 5)
}

/// Which mouse button an event concerns.
public enum MouseButton: UInt8, Sendable, Equatable {
    case left = 0
    case right = 1
    case other = 2
}

/// Client→host input events (doc 17 §3.9 / doc 05). Positions are in **normalised
/// window space (0..1)** — the client never sends raw pixels, which removes all
/// pixel-vs-point ambiguity (doc 05 §2); the host maps normalised→host-window-point
/// via ``CoordinateMapping``. Every event carries `tag` = the value the host will
/// stamp on `eventSourceUserData` so it can FILTER its own self-injected events out
/// of `CursorSampler`/`WindowGeometryWatcher` (doc 18 §A — avoids feedback loops).
public enum InputEvent: Equatable, Sendable {
    /// Absolute pointer move to a normalised window position.
    case mouseMove(normalized: VideoPoint, tag: UInt32)
    /// Mouse button down at a normalised window position.
    case mouseDown(button: MouseButton, normalized: VideoPoint, clickCount: UInt8, modifiers: InputModifiers, tag: UInt32)
    /// Mouse button up at a normalised window position.
    case mouseUp(button: MouseButton, normalized: VideoPoint, clickCount: UInt8, modifiers: InputModifiers, tag: UInt32)
    /// Scroll wheel (pixel units). `dy`/`dx` are signed scroll deltas.
    case scroll(dx: Double, dy: Double, normalized: VideoPoint, tag: UInt32)
    /// Key down/up by host virtual keycode (for navigation / shortcuts; doc 05 §3).
    case key(keyCode: UInt16, down: Bool, modifiers: InputModifiers, tag: UInt32)
    /// Unicode text insertion (layout-independent; the robust text path, doc 05 §3).
    case text(String, tag: UInt32)

    public var messageType: UInt8 {
        switch self {
        case .mouseMove: return 1
        case .mouseDown: return 2
        case .mouseUp: return 3
        case .scroll: return 4
        case .key: return 5
        case .text: return 6
        }
    }

    /// The self-inject filter tag.
    public var tag: UInt32 {
        switch self {
        case .mouseMove(_, let tag),
             .mouseDown(_, _, _, _, let tag),
             .mouseUp(_, _, _, _, let tag),
             .scroll(_, _, _, let tag),
             .key(_, _, _, let tag),
             .text(_, let tag):
            return tag
        }
    }

    public func encode() -> Data {
        var out = Data()
        out.append(messageType)
        switch self {
        case .mouseMove(let n, let tag):
            out.appendBE(tag); out.appendBE(n.x); out.appendBE(n.y)
        case .mouseDown(let button, let n, let clickCount, let mods, let tag),
             .mouseUp(let button, let n, let clickCount, let mods, let tag):
            out.appendBE(tag); out.append(button.rawValue); out.append(clickCount); out.append(mods.rawValue)
            out.appendBE(n.x); out.appendBE(n.y)
        case .scroll(let dx, let dy, let n, let tag):
            out.appendBE(tag); out.appendBE(dx); out.appendBE(dy); out.appendBE(n.x); out.appendBE(n.y)
        case .key(let keyCode, let down, let mods, let tag):
            out.appendBE(tag); out.appendBE(keyCode); out.append(down ? 1 : 0); out.append(mods.rawValue)
        case .text(let string, let tag):
            out.appendBE(tag); out.append(Data(string.utf8))
        }
        return out
    }

    public static func decode(_ data: Data) throws -> InputEvent {
        var reader = VideoByteReader(data)
        let type = try reader.readUInt8()
        switch type {
        case 1:
            let tag = try reader.readUInt32()
            let x = try reader.readFiniteFloat64("mouseMove.x"); let y = try reader.readFiniteFloat64("mouseMove.y")
            return .mouseMove(normalized: VideoPoint(x: x, y: y), tag: tag)
        case 2, 3:
            let tag = try reader.readUInt32()
            guard let button = MouseButton(rawValue: try reader.readUInt8()) else {
                throw VideoProtocolError.malformed("unknown mouse button")
            }
            let clickCount = try reader.readUInt8()
            let mods = InputModifiers(rawValue: try reader.readUInt8())
            let x = try reader.readFiniteFloat64("mouseButton.x"); let y = try reader.readFiniteFloat64("mouseButton.y")
            let n = VideoPoint(x: x, y: y)
            return type == 2
                ? .mouseDown(button: button, normalized: n, clickCount: clickCount, modifiers: mods, tag: tag)
                : .mouseUp(button: button, normalized: n, clickCount: clickCount, modifiers: mods, tag: tag)
        case 4:
            let tag = try reader.readUInt32()
            let dx = try reader.readFiniteFloat64("scroll.dx"); let dy = try reader.readFiniteFloat64("scroll.dy")
            let x = try reader.readFiniteFloat64("scroll.x"); let y = try reader.readFiniteFloat64("scroll.y")
            return .scroll(dx: dx, dy: dy, normalized: VideoPoint(x: x, y: y), tag: tag)
        case 5:
            let tag = try reader.readUInt32()
            let keyCode = try reader.readUInt16()
            let down = try reader.readUInt8() != 0
            let mods = InputModifiers(rawValue: try reader.readUInt8())
            return .key(keyCode: keyCode, down: down, modifiers: mods, tag: tag)
        case 6:
            let tag = try reader.readUInt32()
            let bytes = reader.remaining()
            guard let string = String(data: bytes, encoding: .utf8) else {
                throw VideoProtocolError.malformed("input text not valid UTF-8")
            }
            return .text(string, tag: tag)
        default:
            throw VideoProtocolError.malformed("unknown input event type \(type)")
        }
    }
}

private extension VideoByteReader {
    /// Reads a wire `Float64` and REJECTS non-finite values (NaN / ±infinity).
    ///
    /// Input coordinates and scroll deltas arrive as raw IEEE-754 bit patterns straight
    /// off the (WireGuard-encrypted but otherwise untrusted) UDP wire. A non-finite value
    /// here is never legitimate and is dangerous downstream: the host's scroll injector
    /// converts the delta with the trapping `Int32(Double)` initializer (which fatal-errors
    /// on NaN/±inf), and CG coordinate math propagates NaN into the cursor/geometry path. A
    /// hostile peer must not be able to smuggle one through. Treating a non-finite field as
    /// a malformed datagram lets the router DROP it — a corrupt single packet must never
    /// crash the receiver (same contract as the reassembler / `InputDatagramRouter.route`).
    mutating func readFiniteFloat64(_ field: String) throws -> Double {
        let value = try readFloat64()
        guard value.isFinite else { throw VideoProtocolError.malformed("non-finite \(field)") }
        return value
    }
}
