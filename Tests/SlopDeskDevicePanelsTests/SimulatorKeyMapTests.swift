// SimulatorKeyMapTests — the two halves of the simulator's key path: the short no-character table,
// and the modifier names.
//
// The first suite is a PIN, not a restatement. ``SimulatorKeyMap/code(for:)`` spells its virtual key
// codes as literals so the table compiles for the iOS triple too (`Carbon.HIToolbox` is macOS-only),
// and a literal table is exactly the kind that rots silently. So each row is asserted against the
// SDK's own `kVK_` constant here, where Carbon IS available — a typo in the shared floor fails a
// build rather than swallowing an arrow key on a device someone is typing into.

import SlopDeskVideoProtocol
import Testing
@testable import SlopDeskDevicePanels

#if canImport(Carbon)
import Carbon.HIToolbox

@Suite("SimulatorKeyMap virtual key codes")
struct SimulatorKeyMapCodeTests {
    /// Every mapped key, as (the SDK's constant, the `KeyboardEvent.code` the server expects).
    private static let rows: [(Int, String)] = [
        (kVK_Return, "Enter"),
        (kVK_ANSI_KeypadEnter, "Enter"),
        (kVK_Delete, "Backspace"),
        (kVK_ForwardDelete, "Delete"),
        (kVK_Tab, "Tab"),
        (kVK_Escape, "Escape"),
        (kVK_LeftArrow, "ArrowLeft"),
        (kVK_RightArrow, "ArrowRight"),
        (kVK_UpArrow, "ArrowUp"),
        (kVK_DownArrow, "ArrowDown"),
        (kVK_Home, "Home"),
        (kVK_End, "End"),
        (kVK_PageUp, "PageUp"),
        (kVK_PageDown, "PageDown"),
        (kVK_Space, "Space"),
    ]

    @Test
    func `every literal in the table is the SDK's own virtual key code`() {
        for (keyCode, name) in Self.rows {
            #expect(SimulatorKeyMap.code(for: UInt16(keyCode)) == name)
        }
    }

    /// The table is a whitelist: a printable key must fall through so the caller sends it as TEXT,
    /// which is what keeps every non-US layout working without this file knowing a layout exists.
    @Test
    func `a printable key has no code and rides the type path`() {
        #expect(SimulatorKeyMap.code(for: UInt16(kVK_ANSI_A)) == nil)
        #expect(SimulatorKeyMap.code(for: UInt16(kVK_ANSI_1)) == nil)
        #expect(SimulatorKeyMap.code(for: UInt16(kVK_ANSI_Period)) == nil)
    }

    /// A bare modifier produces no key and no text — it is held state, reported alongside the next
    /// press.
    @Test
    func `a bare modifier is not a key`() {
        #expect(SimulatorKeyMap.code(for: UInt16(kVK_Shift)) == nil)
        #expect(SimulatorKeyMap.code(for: UInt16(kVK_Command)) == nil)
    }

    /// The two Enters are one name. The server's HID table has no keypad variant, and a text field
    /// that treated them differently would be wrong on every keyboard that has a numeric pad.
    @Test
    func `the keypad Enter is the same name as Return`() {
        #expect(SimulatorKeyMap.code(for: UInt16(kVK_ANSI_KeypadEnter)) == "Enter")
        #expect(SimulatorKeyMap.code(for: UInt16(kVK_Return)) == "Enter")
    }
}
#endif

@Suite("SimulatorKeyMap modifiers")
struct SimulatorKeyMapModifierTests {
    @Test
    func `the four named modifiers travel, in the server's order`() {
        let held: InputModifiers = [.shift, .control, .option, .command]
        #expect(SimulatorKeyMap.modifiers(for: held) == [.shift, .control, .option, .command])
    }

    /// `.capsLock` and `.function` have no name on this wire. Sending one would be an unknown token
    /// rather than a no-op, so they are dropped rather than translated.
    @Test
    func `caps lock and function are dropped, not translated`() {
        #expect(SimulatorKeyMap.modifiers(for: [.capsLock, .function]).isEmpty)
        #expect(SimulatorKeyMap.modifiers(for: [.capsLock, .shift]) == [.shift])
    }

    @Test
    func `nothing held sends nothing`() {
        #expect(SimulatorKeyMap.modifiers(for: []).isEmpty)
    }
}
