// AndroidControlMessage — the marshalling for everything the panel sends upstream.
//
// Every layout is `slopdesk_androidd::control`, transcribed there from `app/src/control_msg.c` at
// v4.1. What is left here is the hand-off: filling one record, naming the kind, and the two
// convenience pairs that are simply the encoder called twice.
//
// ## Why the layouts moved
//
// `scrcpy` publishes no wire specification — its own documentation says the control protocol is
// defined by the unit tests on both sides — and this file used to hand-lay every field with a local
// `appendBigEndian`, which is the same idiom `check-supervisor.sh` already bans for the screend
// frame. `slopdesk-androidd` owns scrcpy's dialect and now owns both directions of it:
// `stream` reads what the device sends, `control` writes what the panel sends.
//
// ## The one-way invariant is now enforced by a type, not by a comment
//
// The host bridge gives the client ONE full-duplex connection — video down, control up — which is
// only sound while the control channel is strictly one-way. `scrcpy`'s server has exactly three
// device→client messages and every one is a REPLY: to a `GET_CLIPBOARD`, to a `SET_CLIPBOARD`
// carrying a non-zero sequence, or to UHID. Send one and the device writes a clipboard message into
// a stream the client is parsing as H.264.
//
// Those four types have no variant in the Rust enum and no kind at the door, so the door REFUSES
// them — where this file could previously only decline to write an encoder for them. `SET_CLIPBOARD`
// likewise takes no sequence parameter: it is the constant zero, on the far side of the call.
//
// ## Nothing here waits
//
// `docs/47` records that the simulator server's upstream verbs differ by three orders of magnitude,
// and that a scroll built on the expensive one accrued seconds of lag per second of use. That hazard
// is structurally absent here: `scrcpy` has no compound gesture verbs, and no message is
// acknowledged. Measured 2026-08-04, 202 touch messages left the client in 1.0 ms total. The lesson
// survives as a rule — nothing upstream may ever be written as a request that expects a reply.

#if os(macOS)
import CSlopDeskFFI
import Foundation

/// Android's `MotionEvent` actions, as the server passes them to `InputManager`.
package enum AndroidMotionAction: UInt8 {
    case down = 0
    case up = 1
    case move = 2
    case cancel = 3
    // 4 is ACTION_OUTSIDE, which the panel never sends — the door refuses it.
    case pointerDown = 5
    case pointerUp = 6
    case hoverMove = 7
    case scroll = 8
}

/// Android's `KeyEvent` actions.
package enum AndroidKeyAction: UInt8 {
    case down = 0
    case up = 1
}

/// `MotionEvent` button bits, for the `buttons` field of a touch message.
package struct AndroidButtons: OptionSet {
    package let rawValue: UInt32
    package init(rawValue: UInt32) { self.rawValue = rawValue }
    package static let primary = Self(rawValue: 1 << 0)
    package static let secondary = Self(rawValue: 1 << 1)
    package static let tertiary = Self(rawValue: 1 << 2)
}

/// The messages that are their type byte and nothing else.
///
/// A closed enum rather than a set of `UInt8` constants: `GET_CLIPBOARD` and `UHID_*` are bodiless
/// too, and this is where they would otherwise be easiest to add without noticing what that costs.
/// The door refuses their type bytes even if one is handed to it.
package enum AndroidBodilessMessage: UInt8 {
    case collapsePanels = 7
    case rotateDevice = 11
    case openHardKeyboardSettings = 15
    case resetVideo = 17
}

package enum AndroidControlMessage {
    // MARK: Well-known pointer ids

    /// `SC_POINTER_ID_GENERIC_FINGER`. The panel injects FINGERS, not a mouse: Android's gesture
    /// recognisers, its scrollers and its fling physics are all built for touch, and a mouse pointer
    /// id makes a drag arrive as a hover in views that distinguish them.
    package static let fingerPointerID: UInt64 = .max - 1
    /// `SC_POINTER_ID_VIRTUAL_FINGER` — the second contact of a pinch.
    package static let virtualFingerPointerID: UInt64 = .max - 2

    // MARK: Encoders

    /// `INJECT_TOUCH_EVENT` — the panel's whole pointer path.
    ///
    /// The coordinates are in the SCREEN SIZE reported alongside them and the server rescales, so
    /// the panel never needs the device's true resolution to place a touch — it reports the size of
    /// the frame it measured the gesture against, exactly as the simulator panel does.
    package static func touch(
        action: AndroidMotionAction, pointerID: UInt64 = fingerPointerID,
        x: Int32, y: Int32, width: UInt16, height: UInt16,
        pressure: Float = 1, actionButton: AndroidButtons = [], buttons: AndroidButtons = [],
    ) -> Data {
        var request = SlopDeskAndroidControl()
        request.kind = UInt8(SLOPDESK_ANDROID_CONTROL_TOUCH)
        request.action = action.rawValue
        request.pointer_id = pointerID
        request.x = x
        request.y = y
        request.width = width
        request.height = height
        request.pressure = pressure
        request.action_button = actionButton.rawValue
        request.buttons = buttons.rawValue
        return encode(request) ?? Data()
    }

    /// `INJECT_SCROLL_EVENT`.
    ///
    /// Present but NOT what the panel's trackpad scrolling uses. Android delivers this as a
    /// `MotionEvent` with `ACTION_SCROLL`, which a `RecyclerView` handles as a discrete wheel notch —
    /// no kinetics, no over-scroll, no rubber band — while a dragged finger gets the real thing. The
    /// panel keeps it for a genuine wheel with no phase information; a trackpad gesture goes through
    /// ``touch(action:pointerID:x:y:width:height:pressure:actionButton:buttons:)``.
    package static func scroll(
        x: Int32, y: Int32, width: UInt16, height: UInt16,
        horizontal: Float, vertical: Float, buttons: AndroidButtons = [],
    ) -> Data {
        var request = SlopDeskAndroidControl()
        request.kind = UInt8(SLOPDESK_ANDROID_CONTROL_SCROLL)
        request.x = x
        request.y = y
        request.width = width
        request.height = height
        // The division by the protocol's [-16, 16] notch scale is the door's, so a caller cannot
        // skip it and saturate on a single click.
        request.horizontal = horizontal
        request.vertical = vertical
        request.buttons = buttons.rawValue
        return encode(request) ?? Data()
    }

    /// `INJECT_KEYCODE`.
    package static func key(
        action: AndroidKeyAction, keycode: AndroidKeycode, repeatCount: UInt32 = 0,
        metaState: AndroidMetaState = [],
    ) -> Data {
        var request = SlopDeskAndroidControl()
        request.kind = UInt8(SLOPDESK_ANDROID_CONTROL_KEY)
        request.action = action.rawValue
        request.keycode = keycode.rawValue
        request.repeat_count = repeatCount
        request.meta_state = metaState.rawValue
        return encode(request) ?? Data()
    }

    /// A key pressed and released, which is what every hardware button on the toolbar sends.
    package static func keyPress(_ keycode: AndroidKeycode, metaState: AndroidMetaState = []) -> [Data] {
        [
            key(action: .down, keycode: keycode, metaState: metaState),
            key(action: .up, keycode: keycode, metaState: metaState),
        ]
    }

    /// `INJECT_TEXT` — length-prefixed UTF-8, cut at the server's own ceiling on a CHARACTER
    /// boundary. `nil` for an empty string, which would ask the device to type nothing.
    package static func text(_ string: String) -> Data? {
        var request = SlopDeskAndroidControl()
        request.kind = UInt8(SLOPDESK_ANDROID_CONTROL_TEXT)
        return encode(request, body: string)
    }

    /// `SET_CLIPBOARD`. The sequence is not a parameter — it is the constant zero, on the far side
    /// of the door, because a non-zero sequence asks the device to acknowledge and an
    /// acknowledgement is a device message on a channel that must stay one-way.
    package static func setClipboard(_ string: String, paste: Bool) -> Data? {
        var request = SlopDeskAndroidControl()
        request.kind = UInt8(SLOPDESK_ANDROID_CONTROL_SET_CLIPBOARD)
        request.flag = paste
        return encode(request, body: string)
    }

    /// `BACK_OR_SCREEN_ON` — Back when the screen is on, wake when it is not. Two messages, because
    /// the server takes a key action and a bare press is down-then-up.
    package static func pressBack() -> [Data] {
        [AndroidKeyAction.down, .up].map { action in
            var request = SlopDeskAndroidControl()
            request.kind = UInt8(SLOPDESK_ANDROID_CONTROL_BACK_OR_SCREEN_ON)
            request.action = action.rawValue
            return encode(request) ?? Data()
        }
    }

    /// `SET_DISPLAY_POWER` — turns the device's own screen off while the mirror keeps running. The
    /// mirror is unaffected; this is the device's backlight, not the stream.
    package static func displayPower(on: Bool) -> Data {
        var request = SlopDeskAndroidControl()
        request.kind = UInt8(SLOPDESK_ANDROID_CONTROL_DISPLAY_POWER)
        request.flag = on
        return encode(request) ?? Data()
    }

    /// The bodiless messages. Only the four that carry no device reply can be named at all.
    package static func simple(_ message: AndroidBodilessMessage) -> Data {
        var request = SlopDeskAndroidControl()
        request.kind = UInt8(SLOPDESK_ANDROID_CONTROL_BODILESS)
        request.bodiless_type = message.rawValue
        return encode(request) ?? Data()
    }

    /// `START_APP` — a 1-byte length prefix, not 4. A `+` prefix on the name asks the server to
    /// force-stop it first.
    package static func startApp(_ package: String) -> Data? {
        var request = SlopDeskAndroidControl()
        request.kind = UInt8(SLOPDESK_ANDROID_CONTROL_START_APP)
        return encode(request, body: package)
    }

    /// The measure-then-fill retry every encoder crosses under.
    ///
    /// `nil` is REFUSED, not "did not fit": a real message is never zero bytes, since every one is
    /// at least its type byte. The refusals are an empty body and a message the door will not send.
    private static func encode(_ request: SlopDeskAndroidControl, body: String = "") -> Data? {
        var request = request
        let bytes = Array(body.utf8)
        return bytes.withUnsafeBufferPointer { text -> Data? in
            let needed = slopdesk_android_control_encode(&request, text.baseAddress, text.count, nil, 0)
            guard needed > 0 else { return nil }
            var out = [UInt8](repeating: 0, count: needed)
            let written = out.withUnsafeMutableBufferPointer { room in
                slopdesk_android_control_encode(
                    &request, text.baseAddress, text.count, room.baseAddress, room.count,
                )
            }
            guard written == needed else { return nil }
            return Data(out)
        }
    }
}
#endif
