#if os(macOS)
import AislopdeskVideoProtocol
import Foundation

/// Pure core of the **virtual-HID keyboard** path — the solution to "type into a macOS SecurityAgent
/// login/password dialog from the remote client".
///
/// **Why this exists (HW-researched 2026-06-12):** Secure Event Input (`IsSecureEventInputEnabled()` is
/// `true` while a password prompt is up) blocks the synthetic-`CGEvent`/event-tap injection path that
/// ``InputInjector`` normally uses — that is exactly the anti-keylogger filter — but it does NOT block
/// input INGESTED from a HID device driver. A DriverKit **virtual HID keyboard**
/// (Karabiner-DriverKit-VirtualHIDDevice) delivers reports at the HID layer, so the system treats them
/// like a real USB keyboard and they reach the secure field. Apple's own Screen Sharing uses a private
/// `com.apple.private.hid.*` entitlement no third party can get; the virtual-HID dext is the legitimate
/// equivalent (and it still requires the machine owner to APPROVE the system extension once — the consent
/// gate is preserved).
///
/// This type is the device-independent half: it maps macOS virtual keycodes (`kVK_*`, the codes the
/// client already forwards) → USB HID **Keyboard/Keypad** usage codes (usage page `0x07`) and folds a
/// stream of key down/up events into the 8-byte **boot-protocol** keyboard reports the dext consumes. It
/// is pure + unit-tested off-device; the socket transport to the Karabiner daemon is a separate (gated)
/// piece.
public enum VirtualHIDKeyboard {
    // MARK: macOS virtual keycode → HID usage (page 0x07)

    /// USB HID Keyboard/Keypad usage for a macOS virtual keycode (`kVK_*`), or `nil` if unmapped. Covers
    /// the full ANSI set + the keys a password entry needs (letters, digits, symbols, return, delete, tab,
    /// space, escape, arrows, function keys). The modifier keys map too (so a held modifier can be
    /// recognised), but ``HIDKeyboardState`` reflects modifiers via the report's modifier BYTE, not the
    /// key array — see ``isModifierKey(_:)``.
    public static func hidUsage(forVirtualKey vk: UInt16) -> UInt8? { keyMap[vk] }

    /// Whether a macOS virtual keycode is a modifier key (shift/control/option/command/fn/capsLock). Such
    /// a key is carried in the report's modifier byte (derived from ``InputModifiers``), NOT the key array.
    public static func isModifierKey(_ vk: UInt16) -> Bool { modifierKeys.contains(vk) }

    /// The HID boot-keyboard MODIFIER byte (report byte 0) for our ``InputModifiers``. Bits (left
    /// variants): ctrl `0x01`, shift `0x02`, alt/option `0x04`, GUI/command `0x08`. CapsLock + Fn are not
    /// HID modifier-byte bits (CapsLock is a lock key; the client uses Shift for case), so they are
    /// omitted — uppercase comes through Shift exactly as a physical keyboard would send it.
    public static func modifierByte(_ m: InputModifiers) -> UInt8 {
        var b: UInt8 = 0
        if m.contains(.control) { b |= 0x01 }
        if m.contains(.shift) { b |= 0x02 }
        if m.contains(.option) { b |= 0x04 }
        if m.contains(.command) { b |= 0x08 }
        return b
    }

    /// Build an 8-byte boot-protocol keyboard report: `[modifiers, 0x00, k1, k2, k3, k4, k5, k6]`. The HID
    /// boot keyboard reports at most 6 concurrent non-modifier keys; if more than 6 are held the spec says
    /// fill all six key slots with `0x01` (ErrorRollOver). Keys are emitted in ascending usage order for a
    /// deterministic report (the order is irrelevant to the host).
    public static func bootReport(modifiers: UInt8, keys: [UInt8]) -> [UInt8] {
        var report: [UInt8] = [modifiers, 0x00, 0, 0, 0, 0, 0, 0]
        let sorted = keys.sorted()
        if sorted.count > 6 {
            for i in 2..<8 { report[i] = 0x01 } // ErrorRollOver
        } else {
            for (i, k) in sorted.enumerated() { report[2 + i] = k }
        }
        return report
    }

    // MARK: tables

    /// macOS virtual keycodes that are modifier keys (don't enter the key array).
    static let modifierKeys: Set<UInt16> = [
        0x37, // kVK_Command
        0x36, // kVK_RightCommand
        0x38, // kVK_Shift
        0x3C, // kVK_RightShift
        0x3A, // kVK_Option
        0x3D, // kVK_RightOption
        0x3B, // kVK_Control
        0x3E, // kVK_RightControl
        0x39, // kVK_CapsLock
        0x3F, // kVK_Function
    ]

    /// macOS virtual keycode → HID usage (page 0x07). Source: the kVK_* constants ⟷ the USB HID Usage
    /// Tables §10 Keyboard/Keypad. ANSI layout.
    static let keyMap: [UInt16: UInt8] = [
        // Letters (kVK_ANSI_A=0x00 … the famously non-alphabetical Apple order).
        0x00: 0x04, // a
        0x0B: 0x05, // b
        0x08: 0x06, // c
        0x02: 0x07, // d
        0x0E: 0x08, // e
        0x03: 0x09, // f
        0x05: 0x0A, // g
        0x04: 0x0B, // h
        0x22: 0x0C, // i
        0x26: 0x0D, // j
        0x28: 0x0E, // k
        0x25: 0x0F, // l
        0x2E: 0x10, // m
        0x2D: 0x11, // n
        0x1F: 0x12, // o
        0x23: 0x13, // p
        0x0C: 0x14, // q
        0x0F: 0x15, // r
        0x01: 0x16, // s
        0x11: 0x17, // t
        0x20: 0x18, // u
        0x09: 0x19, // v
        0x0D: 0x1A, // w
        0x07: 0x1B, // x
        0x10: 0x1C, // y
        0x06: 0x1D, // z
        // Digit row (1..9,0).
        0x12: 0x1E, // 1
        0x13: 0x1F, // 2
        0x14: 0x20, // 3
        0x15: 0x21, // 4
        0x17: 0x22, // 5
        0x16: 0x23, // 6
        0x1A: 0x24, // 7
        0x1C: 0x25, // 8
        0x19: 0x26, // 9
        0x1D: 0x27, // 0
        // Whitespace + edit.
        0x24: 0x28, // Return
        0x35: 0x29, // Escape
        0x33: 0x2A, // Delete (Backspace)
        0x30: 0x2B, // Tab
        0x31: 0x2C, // Space
        0x75: 0x4C, // Forward Delete
        // Symbols.
        0x1B: 0x2D, // - _
        0x18: 0x2E, // = +
        0x21: 0x2F, // [ {
        0x1E: 0x30, // ] }
        0x2A: 0x31, // \ |
        0x29: 0x33, // ; :
        0x27: 0x34, // ' "
        0x32: 0x35, // ` ~
        0x2B: 0x36, // , <
        0x2F: 0x37, // . >
        0x2C: 0x38, // / ?
        // Navigation.
        0x7E: 0x52, // Up
        0x7D: 0x51, // Down
        0x7B: 0x50, // Left
        0x7C: 0x4F, // Right
        0x73: 0x4A, // Home
        0x77: 0x4D, // End
        0x74: 0x4B, // Page Up
        0x79: 0x4E, // Page Down
        // Function row.
        0x7A: 0x3A, // F1
        0x78: 0x3B, // F2
        0x63: 0x3C, // F3
        0x76: 0x3D, // F4
        0x60: 0x3E, // F5
        0x61: 0x3F, // F6
        0x62: 0x40, // F7
        0x64: 0x41, // F8
        0x65: 0x42, // F9
        0x6D: 0x43, // F10
        0x67: 0x44, // F11
        0x6F: 0x45, // F12
    ]
}

/// Folds a stream of key down/up events into HID boot-keyboard reports — the stateful half that
/// ``InputInjector``'s virtual-HID backend drives. HID keyboard reports carry the FULL set of currently
/// pressed keys + the modifier byte, so this tracks pressed non-modifier usages and rebuilds the report on
/// each change. Pure value type (no I/O) so it is unit-tested directly.
public struct HIDKeyboardState: Equatable, Sendable {
    /// Currently-pressed non-modifier HID usages (insertion-independent; the report sorts them).
    private(set) var pressed: Set<UInt8> = []

    public init() {}

    /// Apply one key event and return the report to send, or `nil` if the event maps to nothing (an
    /// unmapped key, no state change). Modifiers come from the authoritative ``InputModifiers`` carried on
    /// every event — a held Shift is reflected in the report's modifier byte, not the key array, so a
    /// modifier key never enters ``pressed``.
    public mutating func apply(virtualKey vk: UInt16, down: Bool, modifiers: InputModifiers) -> [UInt8]? {
        let modByte = VirtualHIDKeyboard.modifierByte(modifiers)
        if VirtualHIDKeyboard.isModifierKey(vk) {
            // The modifier byte already reflects the new state — emit a report so the change lands even
            // when no regular key is involved (e.g. a lone Shift press/release).
            return VirtualHIDKeyboard.bootReport(modifiers: modByte, keys: Array(pressed))
        }
        guard let usage = VirtualHIDKeyboard.hidUsage(forVirtualKey: vk) else { return nil }
        let changed: Bool =
            if down { pressed.insert(usage).inserted } else { pressed.remove(usage) != nil }
        // Always emit when a regular key toggles; also re-emit if only the modifier byte differs is
        // handled by the caller sending the modifier event. A no-op repeat (autorepeat down on an
        // already-pressed key) still re-emits so the host sees the key held.
        _ = changed
        return VirtualHIDKeyboard.bootReport(modifiers: modByte, keys: Array(pressed))
    }

    /// The all-zero report (no keys, no modifiers). Pure — does NOT clear the folded press state; a
    /// caller that is actually RELEASING the keyboard must use ``releaseAll()`` so the in-memory model
    /// matches the zero report it sends.
    public func releaseAllReport() -> [UInt8] { VirtualHIDKeyboard.bootReport(modifiers: 0, keys: []) }

    /// Releases every key/modifier: CLEARS the folded press state AND returns the all-zero report to send
    /// (teardown, or the virtual-HID→CGEvent backend switch). Without clearing ``pressed``, a later key
    /// event would fold into the STALE set via ``apply(virtualKey:down:modifiers:)`` and re-assert the
    /// previously-held key(s) as phantom presses into the NEXT secure field — a key the user never pressed.
    public mutating func releaseAll() -> [UInt8] {
        pressed.removeAll()
        return releaseAllReport()
    }
}
#endif
