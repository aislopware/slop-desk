import CSlopDeskFFI
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
public enum MouseButton: UInt8, CaseIterable, Sendable, Equatable {
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
    /// held?" from host-side state. This is what makes drag-select correct: it
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

    /// Serialises the event. `rust/slopdesk-video`'s `input_event` lays the bytes down — this side
    /// only says which event it is (pinned by the `inputEvent` golden vectors). All multi-byte ints
    /// are big-endian; the `text` payload is raw UTF-8 at the end of the datagram.
    public func encode() -> Data {
        let text = if case let .text(string, _) = self { Data(string.utf8) } else { Data() }
        return text.withUnsafeBytes { bytes in
            withUnsafeTemporaryAllocation(of: UInt8.self, capacity: Self.scratchBytes) { scratch in
                let needed = slopdesk_input_event_encode(
                    wire, bytes.baseAddress, bytes.count, scratch.baseAddress, scratch.count,
                )
                precondition(needed > 0, "the input codec refused an event this type can express")
                guard needed > scratch.count else {
                    return Data(UnsafeBufferPointer(start: scratch.baseAddress, count: needed))
                }
                // Only `.text` can outgrow the scratch, and only then does anyone pay for a second
                // pass: the fixed-size arms are already written by the call that sized them.
                var out = Data(count: needed)
                let written = out.withUnsafeMutableBytes { buffer in
                    slopdesk_input_event_encode(
                        wire, bytes.baseAddress, bytes.count, buffer.baseAddress, buffer.count,
                    )
                }
                precondition(written == needed, "the input codec sized an event differently than it wrote it")
                return out
            }
        }
    }

    /// Stack the fixed-size arms are written into on the first try, so the common event costs one
    /// call rather than a sizing call and a writing one. Comfortably above the widest of them (a
    /// scroll); too small would only ever be slower, never wrong, which is why this side may pick a
    /// number at all — it is not the layout.
    private static let scratchBytes = 64

    /// Decodes a client→host input event. Every guard is the Rust codec's: non-finite coordinates,
    /// an unknown button or type, and non-UTF-8 text are `.malformed`; a short body is `.truncated`.
    /// The reason a decode failed stays on that side — nothing here branches on it, and the datagram
    /// is being dropped either way.
    public static func decode(_ data: Data) throws -> Self {
        var flat = SlopDeskInputEvent()
        let verdict = data.withUnsafeBytes { bytes in
            slopdesk_input_event_decode(bytes.baseAddress, bytes.count, &flat)
        }
        switch verdict {
        case UInt32(SLOPDESK_INPUT_DECODE_TRUNCATED): throw VideoProtocolError.truncated
        case UInt32(SLOPDESK_INPUT_DECODE_MALFORMED):
            throw VideoProtocolError.malformed("unacceptable input event")
        default: break
        }
        let normalized = VideoPoint(x: flat.x, y: flat.y)
        let mods = InputModifiers(rawValue: flat.modifiers)
        switch flat.message_type {
        case 1: return .mouseMove(normalized: normalized, tag: flat.tag)
        case 2,
             3,
             7:
            // The button was already checked against the three the wire admits, so this cannot fail.
            let button = MouseButton(rawValue: flat.button) ?? .left
            let arm: (MouseButton, VideoPoint, UInt8, InputModifiers, UInt32) -> Self =
                switch flat.message_type {
                case 2: Self.mouseDown
                case 3: Self.mouseUp
                default: Self.mouseDrag
                }
            return arm(button, normalized, flat.click_count, mods, flat.tag)
        case 4:
            return .scroll(
                dx: flat.dx, dy: flat.dy, normalized: normalized,
                scrollPhase: flat.scroll_phase, momentumPhase: flat.momentum_phase,
                continuous: flat.continuous, tag: flat.tag,
            )
        case 5:
            return .key(keyCode: flat.key_code, down: flat.down, modifiers: mods, tag: flat.tag)
        default:
            // The text arm: its bytes stay in the caller's datagram, and the codec proved every one
            // of them is UTF-8 before it reported where they start.
            let span = data.dropFirst(Int(flat.text_offset))
            // Not the failable initializer: the decode above rejected non-UTF-8 text as malformed,
            // so a second check here would be a second guard with an unreachable arm.
            return .text(String(decoding: span, as: UTF8.self), tag: flat.tag)
        }
    }

    /// A scroll the far side SYNTHESISED — a summed emit the caller never sent, so there is no
    /// event of its own to name and the whole thing crosses in the record.
    ///
    /// Only the scroll arm: everything else the boundary answers is one of the caller's own events,
    /// named by index, and a record claiming to be one of those is a shape this side did not ask
    /// for and does not build.
    public init?(summedScroll flat: SlopDeskInputEvent) {
        guard flat.message_type == 4 else { return nil }
        self = .scroll(
            dx: flat.dx, dy: flat.dy, normalized: VideoPoint(x: flat.x, y: flat.y),
            scrollPhase: flat.scroll_phase, momentumPhase: flat.momentum_phase,
            continuous: flat.continuous, tag: flat.tag,
        )
    }

    /// The event flattened for the boundary: one value with `messageType` saying which fields of it
    /// carry meaning, which is what keeps a C union off the wire between the two sides.
    ///
    /// Public because encoding is no longer the only door that takes a batch of these — the motion
    /// coalescer hands the same records across and gets back a plan naming them.
    public var wire: SlopDeskInputEvent {
        var flat = SlopDeskInputEvent()
        flat.message_type = messageType
        flat.tag = tag
        switch self {
        case let .mouseMove(n, _):
            flat.x = n.x
            flat.y = n.y
        case let .mouseDown(button, n, clickCount, mods, _),
             let .mouseUp(button, n, clickCount, mods, _),
             let .mouseDrag(button, n, clickCount, mods, _):
            flat.x = n.x
            flat.y = n.y
            flat.button = button.rawValue
            flat.click_count = clickCount
            flat.modifiers = mods.rawValue
        case let .scroll(dx, dy, n, scrollPhase, momentumPhase, continuous, _):
            flat.x = n.x
            flat.y = n.y
            flat.dx = dx
            flat.dy = dy
            flat.scroll_phase = scrollPhase
            flat.momentum_phase = momentumPhase
            flat.continuous = continuous
        case let .key(keyCode, down, mods, _):
            flat.key_code = keyCode
            flat.down = down
            flat.modifiers = mods.rawValue
        case .text:
            flat.text_offset = slopdesk_input_event_constant(0)
        }
        return flat
    }
}
