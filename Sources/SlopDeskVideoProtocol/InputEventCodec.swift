import Foundation

/// Modifier-key bitmask carried by input events (matches the CGEventFlags the host
/// will apply, but kept platform-free here).
public struct InputModifiers: OptionSet, Sendable, Equatable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let shift = Self(rawValue: 1 << 0)
    public static let control = Self(rawValue: 1 << 1)
    public static let option = Self(rawValue: 1 << 2)
    public static let command = Self(rawValue: 1 << 3)
    public static let capsLock = Self(rawValue: 1 << 4)
    public static let function = Self(rawValue: 1 << 5)
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
    case mouseDown(
        button: MouseButton,
        normalized: VideoPoint,
        clickCount: UInt8,
        modifiers: InputModifiers,
        tag: UInt32,
    )
    /// Mouse button up at a normalised window position.
    case mouseUp(button: MouseButton, normalized: VideoPoint, clickCount: UInt8, modifiers: InputModifiers, tag: UInt32)
    /// Mouse drag (a button is HELD) to a normalised window position. The CLIENT sends
    /// this explicitly when its view reports a `mouseDragged` (vs a `mouseMoved`), so the
    /// host posts the matching `*MouseDragged` STATELESSLY — it never infers "is a button
    /// held?" from host-side state. This is what makes drag-select ("bôi đen") correct: it
    /// is wire-reorder-safe over UDP (a drag that arrives before its `mouseDown` is simply
    /// ignored by the target app until the down anchors the selection) and it removes the
    /// phantom-drag-after-a-lost-`mouseUp` class of bug (a `.mouseMove` is now ALWAYS a pure
    /// hover). `clickCount` carries the originating click count so the dragged event's
    /// clickState matches the down — selection engines key off it.
    case mouseDrag(
        button: MouseButton,
        normalized: VideoPoint,
        clickCount: UInt8,
        modifiers: InputModifiers,
        tag: UInt32,
    )
    /// Scroll wheel (pixel units). `dy`/`dx` are signed scroll deltas.
    ///
    /// `scrollPhase` / `momentumPhase` carry the trackpad gesture state so the host can replay a
    /// native continuous/inertial scroll instead of a phase-less wheel tick. They use the CoreGraphics
    /// integer encodings verbatim — `scrollPhase` ∈ `CGScrollPhase` (0=none, 1=began, 2=changed,
    /// 4=ended, 8=cancelled, 128=mayBegin); `momentumPhase` ∈ `CGMomentumScrollPhase` (0=none,
    /// 1=begin, 2=continue, 3=end) — and are mutually exclusive (at most one is non-zero per event).
    /// `continuous` mirrors `hasPreciseScrollingDeltas` (true = pixel-precise trackpad gesture).
    case scroll(
        dx: Double,
        dy: Double,
        normalized: VideoPoint,
        scrollPhase: UInt8,
        momentumPhase: UInt8,
        continuous: Bool,
        tag: UInt32,
    )
    /// Key down/up by host virtual keycode (for navigation / shortcuts; doc 05 §3).
    case key(keyCode: UInt16, down: Bool, modifiers: InputModifiers, tag: UInt32)
    /// Unicode text insertion (layout-independent; the robust text path, doc 05 §3).
    case text(String, tag: UInt32)

    public var messageType: UInt8 {
        switch self {
        case .mouseMove: 1
        case .mouseDown: 2
        case .mouseUp: 3
        case .scroll: 4
        case .key: 5
        case .text: 6
        case .mouseDrag: 7
        }
    }

    /// The self-inject filter tag.
    public var tag: UInt32 {
        switch self {
        case let .mouseMove(_, tag),
             let .mouseDown(_, _, _, _, tag),
             let .mouseUp(_, _, _, _, tag),
             let .mouseDrag(_, _, _, _, tag),
             let .scroll(_, _, _, _, _, _, tag),
             let .key(_, _, _, tag),
             let .text(_, tag):
            tag
        }
    }

    /// Serialises the event. Native Swift is the single source of truth for the wire format
    /// (pinned by the `inputEvent` golden vectors). All multi-byte ints are big-endian; the
    /// `text` payload is appended as raw UTF-8 to the end of the datagram.
    public func encode() -> Data {
        var out = Data()
        out.append(messageType)
        switch self {
        case let .mouseMove(n, tag):
            out.appendBE(tag)
            out.appendBE(n.x)
            out.appendBE(n.y)
        case let .mouseDown(button, n, clickCount, mods, tag),
             let .mouseUp(button, n, clickCount, mods, tag),
             let .mouseDrag(button, n, clickCount, mods, tag):
            out.appendBE(tag)
            out.append(button.rawValue)
            out.append(clickCount)
            out.append(mods.rawValue)
            out.appendBE(n.x)
            out.appendBE(n.y)
        case let .scroll(dx, dy, n, scrollPhase, momentumPhase, continuous, tag):
            out.appendBE(tag)
            out.appendBE(dx)
            out.appendBE(dy)
            out.appendBE(n.x)
            out.appendBE(n.y)
            out.append(scrollPhase)
            out.append(momentumPhase)
            out.append(continuous ? 1 : 0)
        case let .key(keyCode, down, mods, tag):
            out.appendBE(tag)
            out.appendBE(keyCode)
            out.append(down ? 1 : 0)
            out.append(mods.rawValue)
        case let .text(string, tag):
            out.appendBE(tag)
            out.append(Data(string.utf8))
        }
        return out
    }

    /// Decodes a client→host input event (native Swift, the single source of truth; the wire
    /// format is pinned by golden vectors). Non-finite coordinates, an unknown button/type, or
    /// non-UTF-8 text are rejected as `.malformed`; a short body is `.truncated`.
    public static func decode(_ data: Data) throws -> Self {
        var reader = VideoByteReader(data)
        let type = try reader.readUInt8()
        switch type {
        case 1:
            let tag = try reader.readUInt32()
            let x = try reader.readFiniteFloat64("mouseMove.x")
            let y = try reader.readFiniteFloat64("mouseMove.y")
            return .mouseMove(normalized: VideoPoint(x: x, y: y), tag: tag)
        case 2,
             3,
             7:
            let tag = try reader.readUInt32()
            guard let button = try MouseButton(rawValue: reader.readUInt8()) else {
                throw VideoProtocolError.malformed("unknown mouse button")
            }
            let clickCount = try reader.readUInt8()
            let mods = try InputModifiers(rawValue: reader.readUInt8())
            let x = try reader.readFiniteFloat64("mouseButton.x")
            let y = try reader.readFiniteFloat64("mouseButton.y")
            let n = VideoPoint(x: x, y: y)
            switch type {
            case 2: return .mouseDown(button: button, normalized: n, clickCount: clickCount, modifiers: mods, tag: tag)
            case 3: return .mouseUp(button: button, normalized: n, clickCount: clickCount, modifiers: mods, tag: tag)
            default: return .mouseDrag(button: button, normalized: n, clickCount: clickCount, modifiers: mods, tag: tag)
            }
        case 4:
            let tag = try reader.readUInt32()
            let dx = try reader.readFiniteFloat64("scroll.dx")
            let dy = try reader.readFiniteFloat64("scroll.dy")
            let x = try reader.readFiniteFloat64("scroll.x")
            let y = try reader.readFiniteFloat64("scroll.y")
            let scrollPhase = try reader.readUInt8()
            let momentumPhase = try reader.readUInt8()
            let continuous = try reader.readUInt8() != 0
            return .scroll(
                dx: dx,
                dy: dy,
                normalized: VideoPoint(x: x, y: y),
                scrollPhase: scrollPhase,
                momentumPhase: momentumPhase,
                continuous: continuous,
                tag: tag,
            )
        case 5:
            let tag = try reader.readUInt32()
            let keyCode = try reader.readUInt16()
            let down = try reader.readUInt8() != 0
            let mods = try InputModifiers(rawValue: reader.readUInt8())
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
