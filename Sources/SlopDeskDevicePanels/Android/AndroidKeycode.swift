// AndroidKeycode — Android's `KeyEvent` constants, and the mapping from a macOS key press to one.
//
// ## Why keys take two different routes
//
// A key press on a mirrored device is one of two unrelated things, and conflating them is what makes
// a remote keyboard feel broken:
//
//  - **Text** — a letter, a digit, an accented character, an emoji. What the device needs is the
//    CHARACTER, not the key that produced it, because the client's layout has already resolved dead
//    keys, `option`-combinations and the input method. That goes out as `INJECT_TEXT` and reaches
//    whatever field has focus. Sending `KEYCODE_A` instead would type `a` on a QWERTY device and
//    something else on any other layout, and would type nothing at all for a character with no
//    keycode.
//  - **A key with no character** — Return, Backspace, the arrows, Escape, Tab — plus anything held
//    with a non-shift modifier, where the device has to see the CHORD. Those go out as
//    `INJECT_KEYCODE` with a meta state.
//
// The split is the same one the simulator panel makes, for the same reason. What differs is the
// ceiling: `docs/47` records the simulator server typing at ~7 characters per second with batching no
// help, because the cost is inside its HID key dispatch. `scrcpy`'s `INJECT_TEXT` hands the whole
// string to the device's input method in ONE message with no acknowledgement, so a paste is a single
// write rather than a per-character round trip.

import CSlopDeskFFI
import Foundation
import SlopDeskVideoProtocol

/// One Android `KeyEvent` keycode. A struct rather than an enum: the constant list runs past 300 and
/// the panel needs a couple of dozen, so an open type keeps a missing one from being unrepresentable.
package struct AndroidKeycode: RawRepresentable, Equatable, Hashable {
    package let rawValue: UInt32
    package init(rawValue: UInt32) { self.rawValue = rawValue }
    package init(_ rawValue: UInt32) { self.rawValue = rawValue }

    // The two hardware buttons a panel VERB presses. Every other keycode this panel sends comes back
    // from `slopdesk_devicepanel::panel_key` through the door below, so naming one here again would
    // be a second table that no input ever reaches — and therefore one that can never be caught
    // disagreeing (docs/55 §8).
    //
    // `KEYCODE_BACK` is deliberately NOT here, and its absence is the sharper half: the Back verb
    // sends `BACK_OR_SCREEN_ON`, not `KEYCODE_BACK`, because a press on a sleeping device must wake
    // it. A constant named for the obvious thing that the obvious call does not use is a trap, not
    // just dead weight.
    package static let home = Self(3)
    package static let appSwitch = Self(187)
}

/// `KeyEvent` meta-state bits.
package struct AndroidMetaState: OptionSet {
    package let rawValue: UInt32
    package init(rawValue: UInt32) { self.rawValue = rawValue }
    package static let shift = Self(rawValue: 0x1)
    package static let alt = Self(rawValue: 0x02)
    package static let control = Self(rawValue: 0x1000)
    /// The `meta` key — Android's name for what macOS calls Command.
    package static let meta = Self(rawValue: 0x10000)
}

package enum AndroidKeyMap {
    /// What a key press should become on the wire.
    package enum Resolution: Equatable {
        /// Send these characters as text.
        case text(String)
        /// Send this keycode with this meta state.
        case keycode(AndroidKeycode, AndroidMetaState)
        /// Nothing to send — a bare modifier, or a chord the client keeps for itself.
        case none
    }

    /// Resolves one key-down event, described without naming a platform's event type.
    ///
    /// `characters` is what the client's own layout produced (option-composed output, dead-key
    /// resolution, the input method's answer); `charactersIgnoringModifiers` is the same press with
    /// the layout's modifier handling stripped. Both are what a platform key event already carries —
    /// this takes them as values so the mapping is one implementation for every UI half (docs/56).
    ///
    /// **Shift is not a modifier here.** The platform has already applied it — the characters are
    /// already upper case — so folding `.shift` into the meta state as well would ask the device to
    /// apply it twice. That is the same double-application trap `docs/47` records for scroll
    /// direction, in a different channel: when the platform has already resolved something, passing
    /// the raw flag along re-resolves it.
    package static func resolve(
        keyCode: UInt16,
        characters: String?,
        charactersIgnoringModifiers: String?,
        modifiers: InputModifiers,
    ) -> Resolution {
        resolve(
            keyCode, hid: false, characters: characters,
            charactersIgnoringModifiers: charactersIgnoringModifiers, modifiers: modifiers,
        )
    }

    /// The same round for a key numbered as a USB HID usage — an iPad's `UIKey`.
    package static func resolve(
        hidUsage: UInt16,
        characters: String?,
        charactersIgnoringModifiers: String?,
        modifiers: InputModifiers,
    ) -> Resolution {
        resolve(
            hidUsage, hid: true, characters: characters,
            charactersIgnoringModifiers: charactersIgnoringModifiers, modifiers: modifiers,
        )
    }

    /// The first buffer the resolution is asked for, before any retry. Named rather than inline so
    /// that sizing it down to where the retry becomes the common path is a visible edit.
    private static let firstGuessBytes = 32

    /// The crossing. One call answers the whole question, TAGGED — the near side cannot know which
    /// of the three shapes it will get until the rule has run, so asking twice would be a window in
    /// which the two answers could disagree.
    private static func resolve(
        _ code: UInt16,
        hid: Bool,
        characters: String?,
        charactersIgnoringModifiers: String?,
        modifiers: InputModifiers,
    ) -> Resolution {
        withOptionalBytes(characters) { typed, typedPresent in
            withOptionalBytes(charactersIgnoringModifiers) { bare, barePresent in
                let call = { (out: UnsafeMutablePointer<UInt8>?, cap: Int) -> Int in
                    slopdesk_panel_android_key_resolve(
                        code, hid, typed.baseAddress, typed.count, typedPresent,
                        bare.baseAddress, bare.count, barePresent, modifiers.rawValue, out, cap,
                    )
                }
                // GUESS, then retry — never probe. A null-output call runs the whole far-side rule
                // (the modifier fold, the HID lookup, the printable test) and throws the answer
                // away, so the probe doubled the work of a door on the per-KEYSTROKE path. docs/55
                // §4 makes the retry the supported shape: a short buffer writes nothing and still
                // reports the true length. The guess covers every answer this door has — a keycode
                // is 9 bytes, `.none` is 1, and the text arm carries one keystroke's characters.
                var out = [UInt8](repeating: 0, count: firstGuessBytes)
                var needed = out.withUnsafeMutableBufferPointer { room in
                    call(room.baseAddress, room.count)
                }
                guard needed > 0 else { return .none }
                if needed > firstGuessBytes {
                    out = [UInt8](repeating: 0, count: needed)
                    needed = out.withUnsafeMutableBufferPointer { room in
                        call(room.baseAddress, room.count)
                    }
                    guard needed > 0, needed <= out.count else { return .none }
                }
                return decode(Array(out.prefix(needed)))
            }
        }
    }

    /// The tagged answer, read back. An unknown tag is `.none` — the honest reading of a byte this
    /// build does not know is "send nothing", never a guess at which of the other two it meant.
    private static func decode(_ blob: [UInt8]) -> Resolution {
        guard let tag = blob.first else { return .none }
        let payload = blob.dropFirst()
        switch UInt32(tag) {
        case UInt32(SLOPDESK_ANDROID_KEY_KEYCODE):
            guard payload.count == 8 else { return .none }
            let words = Array(payload)
            return .keycode(
                AndroidKeycode(bigEndian(words, at: 0)),
                AndroidMetaState(rawValue: bigEndian(words, at: 4)),
            )
        case UInt32(SLOPDESK_ANDROID_KEY_TEXT):
            // The producer is `slopdesk_devicepanel::panel_key`, so the payload is a Rust `String`'s
            // bytes and cannot be invalid UTF-8. A failable init would add a `nil` branch with no
            // failure mode behind it, and this side would have to invent a meaning for it.
            return .text(String(decoding: payload, as: UTF8.self))
        default:
            return .none
        }
    }

    /// Four big-endian bytes at `offset`, which the door writes and nobody else does.
    private static func bigEndian(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        var value: UInt32 = 0
        for index in offset..<(offset + 4) {
            value = value << 8 | UInt32(bytes[index])
        }
        return value
    }

    /// A `String?` as the `(pointer, length, present)` triple the door reads.
    ///
    /// The PRESENT flag is not ceremony: absent means "fall back to the stripped spelling" and empty
    /// means "this press produced nothing", and a null pointer standing in for both would silently
    /// turn the second into the first.
    private static func withOptionalBytes<T>(
        _ text: String?,
        _ body: (UnsafeBufferPointer<UInt8>, Bool) -> T,
    ) -> T {
        guard let text else { return body(UnsafeBufferPointer(start: nil, count: 0), false) }
        return Array(text.utf8).withUnsafeBufferPointer { body($0, true) }
    }

    /// The meta state for a set of held modifiers, minus shift (see ``resolve(keyCode:characters:charactersIgnoringModifiers:modifiers:)``).
    package static func metaState(from modifiers: InputModifiers) -> AndroidMetaState {
        AndroidMetaState(rawValue: slopdesk_panel_android_meta_state(modifiers.rawValue))
    }
}
