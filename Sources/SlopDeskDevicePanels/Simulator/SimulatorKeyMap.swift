// SimulatorKeyMap — a key press → the `KeyboardEvent.code` names the server's HID table is keyed on.
//
// Only the keys that have no CHARACTER are mapped. Everything printable goes through the `type`
// envelope instead, using the event's own characters: that path costs nothing to maintain, respects
// whatever layout the user actually has (a Vietnamese, French or Dvorak layout produces the right
// letter without this file knowing the layout exists), and cannot drift out of date.
//
// The table itself is `slopdesk_devicepanel::panel_key`, shared with the Android panel because both
// ask the same question — does this key have a character of its own? — and differ only in what they
// call the answer. This file is the FACE: two doors and no table.
//
// ONE VOCABULARY, TWO DOMAINS, and now one table for both. What differs by platform is only how a
// keyboard NUMBERS its keys — a Mac reports a virtual key code and an iPad a USB HID usage — so the
// numbering rides as the door's `hid` flag rather than as a second table. The HID side is DERIVED
// from the remote-desktop path's own usage → keycode map, which is what makes the two impossible to
// drift apart: there is no second spelling left to correct.

import CSlopDeskFFI
import SlopDeskVideoProtocol

package enum SimulatorKeyMap {
    /// The `KeyboardEvent.code` for a macOS virtual key code, or `nil` when the key produces text and
    /// belongs on the `type` path instead.
    package static func code(for keyCode: UInt16) -> String? {
        code(keyCode, hid: false)
    }

    /// The `KeyboardEvent.code` for a USB HID keyboard usage — the iPad's half of the same question.
    package static func code(hidUsage: UInt16) -> String? {
        code(hidUsage, hid: true)
    }

    /// The measure-then-fill retry, with `0` meaning the key types something.
    ///
    /// An empty answer is safe as "no code" here: every name this vocabulary holds is non-empty, so
    /// zero bytes is outside the answer's range rather than colliding with a real code.
    private static func code(_ code: UInt16, hid: Bool) -> String? {
        let needed = slopdesk_panel_simulator_key_code(code, hid, nil, 0)
        guard needed > 0 else { return nil }
        var out = [UInt8](repeating: 0, count: needed)
        let written = out.withUnsafeMutableBufferPointer { room in
            slopdesk_panel_simulator_key_code(code, hid, room.baseAddress, room.count)
        }
        guard written == needed else { return nil }
        // The producer is `slopdesk_devicepanel::panel_key`, so these bytes are a Rust `&'static
        // str`'s and cannot be invalid UTF-8. A failable init would add a `nil` branch that means
        // "types text" here, which is a wrong answer rather than a cautious one.
        // swiftlint:disable:next optional_data_string_conversion
        return String(decoding: out, as: UTF8.self)
    }

    /// The modifier names the server expects. `.function` and `.capsLock` are deliberately absent:
    /// neither has a name on this wire, and sending one would be an unknown token rather than a
    /// no-op.
    ///
    /// Takes `InputModifiers` — the wire's own held-modifier vocabulary, which the GUI-video input
    /// path already sends host-ward — rather than an `NSEvent.ModifierFlags`, so the panel's key
    /// mapping is one implementation and the reading of a key EVENT is the platform's half
    /// (`DeviceKeyEvent` on each side).
    ///
    /// Stays Swift where the table did not: it is a filter that ORDERS its output into this module's
    /// own `Modifier` case list, so a door would have to invent a second vocabulary to answer in and
    /// the near side would map it straight back. There is no table here to be written twice.
    package static func modifiers(for held: InputModifiers) -> [SimulatorInputEnvelope.Modifier] {
        var modifiers: [SimulatorInputEnvelope.Modifier] = []
        if held.contains(.shift) { modifiers.append(.shift) }
        if held.contains(.control) { modifiers.append(.control) }
        if held.contains(.option) { modifiers.append(.option) }
        if held.contains(.command) { modifiers.append(.command) }
        return modifiers
    }
}
