// AndroidControlMessage — the pure encoder for everything the panel sends upstream.
//
// `scrcpy` has no wire specification; its own documentation says the control protocol is defined by
// the unit tests on both sides. So this file is a transcription of `app/src/control_msg.c` at v4.1,
// and `AndroidControlMessageTests` pins each byte layout so a version bump that silently reorders a
// field fails here rather than as a device that responds to taps in the wrong place.
//
// ## Two whole message types are deliberately unreachable
//
// `GET_CLIPBOARD` and the three `UHID_*` messages are not modelled at all, and that is a load-bearing
// omission rather than a gap. The host bridge gives the client ONE full-duplex connection — video
// down, control up — which is only sound while the control channel is strictly one-way. `scrcpy`'s
// server has exactly three device→client messages, and every one is a REPLY: to a `GET_CLIPBOARD`, to
// a `SET_CLIPBOARD` carrying a non-zero sequence, or to UHID. Send one of those and the device will
// write a clipboard message into a stream the client is parsing as H.264. `SET_CLIPBOARD` is
// therefore always encoded with sequence `0`, which asks for no acknowledgement.
//
// ## What replaces the simulator panel's cost table
//
// `docs/47` records that the simulator server's upstream verbs differ by three orders of magnitude —
// `swipe` at 275 ms against `touch1-*` at 0.03 ms — and that a scroll built on the expensive one
// accrued seconds of lag per second of use. That whole hazard is absent here for a structural
// reason: `scrcpy` has no compound gesture verbs. There is no `swipe` and no `tap`; a gesture is
// down/move/up and nothing else, and no message is acknowledged, so the client never waits. Measured
// 2026-08-04, 202 touch messages left the client in 1.0 ms total — 5 µs each, and that is the write,
// not a round trip. The lesson survives as a rule rather than a table: everything below is
// fire-and-forget, so nothing upstream may ever be written as a request that expects a reply.

#if os(macOS)
import Foundation

/// Android's `MotionEvent` actions, as the server passes them to `InputManager`.
enum AndroidMotionAction: UInt8 {
    case down = 0
    case up = 1
    case move = 2
    case cancel = 3
    case pointerDown = 5
    case pointerUp = 6
    case hoverMove = 7
    case scroll = 8
}

/// Android's `KeyEvent` actions.
enum AndroidKeyAction: UInt8 {
    case down = 0
    case up = 1
}

/// `MotionEvent` button bits, for the `buttons` field of a touch message.
struct AndroidButtons: OptionSet {
    let rawValue: UInt32
    static let primary = Self(rawValue: 1 << 0)
    static let secondary = Self(rawValue: 1 << 1)
    static let tertiary = Self(rawValue: 1 << 2)
}

enum AndroidControlMessage {
    // MARK: Message types (`enum sc_control_msg_type`, in declaration order)

    static let injectKeycode: UInt8 = 0
    static let injectText: UInt8 = 1
    static let injectTouchEvent: UInt8 = 2
    static let injectScrollEvent: UInt8 = 3
    static let backOrScreenOn: UInt8 = 4
    // 5 = EXPAND_NOTIFICATION_PANEL, 6 = EXPAND_SETTINGS_PANEL — never sent; the panel reaches the
    // shade through the notification KEYCODE instead, which needs no control channel round trip.
    static let collapsePanels: UInt8 = 7
    // 8 = GET_CLIPBOARD — never sent; see the file comment.
    static let setClipboard: UInt8 = 9
    static let setDisplayPower: UInt8 = 10
    static let rotateDevice: UInt8 = 11
    // 12…14 = UHID_* — never sent; see the file comment.
    static let openHardKeyboardSettings: UInt8 = 15
    static let startApp: UInt8 = 16
    static let resetVideo: UInt8 = 17

    // MARK: Well-known pointer ids

    /// `SC_POINTER_ID_GENERIC_FINGER`. The panel injects FINGERS, not a mouse: Android's gesture
    /// recognisers, its scrollers and its fling physics are all built for touch, and a mouse pointer
    /// id makes a drag arrive as a hover in views that distinguish them.
    static let fingerPointerID: UInt64 = .max - 1
    /// `SC_POINTER_ID_VIRTUAL_FINGER` — the second contact of a pinch.
    static let virtualFingerPointerID: UInt64 = .max - 2

    // MARK: Encoders

    /// `INJECT_TOUCH_EVENT` — 32 bytes, the panel's whole pointer path.
    ///
    /// The coordinates are in the SCREEN SIZE the client reports alongside them, and the server
    /// rescales. So the panel never needs to know the device's true resolution to place a touch — it
    /// reports the size of the frame it measured the gesture against, exactly as the simulator panel
    /// does.
    static func touch(
        action: AndroidMotionAction, pointerID: UInt64 = fingerPointerID,
        x: Int32, y: Int32, width: UInt16, height: UInt16,
        pressure: Float = 1, actionButton: AndroidButtons = [], buttons: AndroidButtons = [],
    ) -> Data {
        var data = Data(capacity: 32)
        data.append(injectTouchEvent)
        data.append(action.rawValue)
        data.appendBigEndian(pointerID)
        data.appendPosition(x: x, y: y, width: width, height: height)
        data.appendBigEndian(unsignedFixedPoint(pressure))
        data.appendBigEndian(actionButton.rawValue)
        data.appendBigEndian(buttons.rawValue)
        return data
    }

    /// `INJECT_SCROLL_EVENT` — 21 bytes.
    ///
    /// Present but NOT what the panel's trackpad scrolling uses. Android delivers this as a
    /// `MotionEvent` with `ACTION_SCROLL`, which a `RecyclerView` handles as a discrete wheel notch —
    /// no kinetics, no over-scroll, no rubber band — while a dragged finger gets the real thing. The
    /// panel keeps it for a genuine wheel with no phase information; a trackpad gesture goes through
    /// ``touch(action:pointerID:x:y:width:height:pressure:actionButton:buttons:)``.
    static func scroll(
        x: Int32, y: Int32, width: UInt16, height: UInt16,
        horizontal: Float, vertical: Float, buttons: AndroidButtons = [],
    ) -> Data {
        var data = Data(capacity: 21)
        data.append(injectScrollEvent)
        data.appendPosition(x: x, y: y, width: width, height: height)
        // The wire carries [-1, 1]; the protocol's own scale is [-16, 16] notches.
        data.appendBigEndian(UInt16(bitPattern: signedFixedPoint(horizontal / 16)))
        data.appendBigEndian(UInt16(bitPattern: signedFixedPoint(vertical / 16)))
        data.appendBigEndian(buttons.rawValue)
        return data
    }

    /// `INJECT_KEYCODE` — 14 bytes.
    static func key(
        action: AndroidKeyAction, keycode: AndroidKeycode, repeatCount: UInt32 = 0,
        metaState: AndroidMetaState = [],
    ) -> Data {
        var data = Data(capacity: 14)
        data.append(injectKeycode)
        data.append(action.rawValue)
        data.appendBigEndian(keycode.rawValue)
        data.appendBigEndian(repeatCount)
        data.appendBigEndian(metaState.rawValue)
        return data
    }

    /// A key pressed and released, which is what every hardware button on the toolbar sends.
    static func keyPress(_ keycode: AndroidKeycode, metaState: AndroidMetaState = []) -> [Data] {
        [
            key(action: .down, keycode: keycode, metaState: metaState),
            key(action: .up, keycode: keycode, metaState: metaState),
        ]
    }

    /// `INJECT_TEXT` — length-prefixed UTF-8.
    ///
    /// Truncated at the server's own 300-byte ceiling, on a CHARACTER boundary: cutting a multi-byte
    /// scalar in half sends the device a byte sequence it decodes as a replacement character, and
    /// typing an emoji would silently corrupt the field.
    static func text(_ string: String) -> Data? {
        let truncated = truncateUTF8(string, toByteCount: 300)
        guard !truncated.isEmpty else { return nil }
        var data = Data(capacity: 5 + truncated.count)
        data.append(injectText)
        data.appendBigEndian(UInt32(truncated.count))
        data.append(truncated)
        return data
    }

    /// `SET_CLIPBOARD` — sequence ALWAYS `0`. A non-zero sequence asks the device to acknowledge,
    /// and an acknowledgement is a device message on a channel that must stay one-way.
    static func setClipboard(_ string: String, paste: Bool) -> Data? {
        let bytes = truncateUTF8(string, toByteCount: 200_000)
        guard !bytes.isEmpty else { return nil }
        var data = Data(capacity: 14 + bytes.count)
        data.append(setClipboard)
        data.appendBigEndian(UInt64(0))
        data.append(paste ? 1 : 0)
        data.appendBigEndian(UInt32(bytes.count))
        data.append(bytes)
        return data
    }

    /// `BACK_OR_SCREEN_ON` — Back when the screen is on, wake when it is not. Two messages, because
    /// the server takes a key action and a bare press is down-then-up.
    static func pressBack() -> [Data] {
        [
            Data([backOrScreenOn, AndroidKeyAction.down.rawValue]),
            Data([backOrScreenOn, AndroidKeyAction.up.rawValue]),
        ]
    }

    /// `SET_DISPLAY_POWER` — turns the device's own screen off while the mirror keeps running. The
    /// mirror is unaffected; this is the device's backlight, not the stream.
    static func displayPower(on: Bool) -> Data {
        Data([setDisplayPower, on ? 1 : 0])
    }

    /// The bodiless messages.
    static func simple(_ type: UInt8) -> Data { Data([type]) }

    /// `START_APP` — a 1-byte length prefix, not 4. A `+` prefix on the name asks the server to
    /// force-stop it first.
    static func startApp(_ package: String) -> Data? {
        let bytes = truncateUTF8(package, toByteCount: 255)
        guard !bytes.isEmpty else { return nil }
        var data = Data(capacity: 2 + bytes.count)
        data.append(startApp)
        data.append(UInt8(bytes.count))
        data.append(bytes)
        return data
    }

    // MARK: Fixed point

    /// `sc_float_to_u16fp` — [0, 1] over 16 bits.
    static func unsignedFixedPoint(_ value: Float) -> UInt16 {
        let clamped = min(max(value, 0), 1)
        let scaled = UInt32(clamped * Float(0x10000))
        return scaled >= 0xFFFF ? 0xFFFF : UInt16(scaled)
    }

    /// `sc_float_to_i16fp` — [-1, 1] over 16 signed bits.
    static func signedFixedPoint(_ value: Float) -> Int16 {
        let clamped = min(max(value, -1), 1)
        let scaled = Int32(clamped * Float(0x8000))
        if scaled >= 0x7FFF { return 0x7FFF }
        if scaled <= -0x8000 { return -0x8000 }
        return Int16(scaled)
    }

    /// Truncates to at most `byteCount` UTF-8 bytes without splitting a character.
    static func truncateUTF8(_ string: String, toByteCount byteCount: Int) -> Data {
        let utf8 = Data(string.utf8)
        guard utf8.count > byteCount else { return utf8 }
        var result = Data()
        for character in string {
            let encoded = Data(String(character).utf8)
            if result.count + encoded.count > byteCount { break }
            result.append(encoded)
        }
        return result
    }
}

private extension Data {
    mutating func appendBigEndian(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }

    mutating func appendBigEndian(_ value: UInt32) {
        for shift in stride(from: 24, through: 0, by: -8) {
            append(UInt8(truncatingIfNeeded: value >> UInt32(shift)))
        }
    }

    mutating func appendBigEndian(_ value: UInt64) {
        for shift in stride(from: 56, through: 0, by: -8) {
            append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
        }
    }

    /// `write_position` — a signed 32-bit point followed by the UNSIGNED 16-bit size it was measured
    /// against. The point is signed because a drag legitimately leaves the frame.
    mutating func appendPosition(x: Int32, y: Int32, width: UInt16, height: UInt16) {
        appendBigEndian(UInt32(bitPattern: x))
        appendBigEndian(UInt32(bitPattern: y))
        appendBigEndian(width)
        appendBigEndian(height)
    }
}
#endif
