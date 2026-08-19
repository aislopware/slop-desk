// SimulatorKeyMapTests — the three halves of the simulator's key path: the two key-numbering tables,
// the vocabulary they agree on, and the modifier names.
//
// The first suite is a PIN, not a restatement. ``SimulatorKeyMap`` spells its macOS virtual key codes
// as literals so the table compiles for the iOS triple too (`Carbon.HIToolbox` is macOS-only), and a
// literal table is exactly the kind that rots silently. So each row is asserted against the SDK's own
// `kVK_` constant here, where Carbon IS available — a typo in the shared floor fails a build rather
// than swallowing an arrow key on a device someone is typing into.
//
// The HID table cannot be pinned the same way: `UIKeyboardHIDUsage` is a UIKit type, and the shared
// floor is not allowed to name it. What IS asserted is the invariant that actually matters — the two
// tables cover the same SET of functional keys, so a Mac and an iPad can never disagree about which
// keys have no character.

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

    /// The pin only holds while it covers the whole table — a row added to the map and not to the
    /// list above would be unpinned and nothing would say so.
    @Test
    func `the pin covers every row of the map`() {
        #expect(SimulatorKeyMap.byVirtualKey.count == Self.rows.count)
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
}
#endif

@Suite("SimulatorKeyMap key numbering")
struct SimulatorKeyMapDomainTests {
    /// The load-bearing invariant of the two-domain split: a Mac and an iPad must never disagree
    /// about WHICH keys have no character of their own. Only the numbering may differ.
    @Test
    func `both numberings reach the same set of keys`() {
        #expect(Set(SimulatorKeyMap.byVirtualKey.values) == Set(SimulatorKeyMap.byHIDUsage.values))
        #expect(Set(SimulatorKeyMap.byVirtualKey.values) == Set(SimulatorKeyMap.FunctionalKey.allCases))
    }

    /// The two Enters are one name in BOTH numberings. The server's HID table has no keypad variant,
    /// and a text field that told them apart would be wrong on every keyboard with a numeric pad.
    @Test
    func `the keypad Enter is the same name as Return on both`() {
        #expect(SimulatorKeyMap.code(for: 36) == "Enter")
        #expect(SimulatorKeyMap.code(for: 76) == "Enter")
        #expect(SimulatorKeyMap.code(hidUsage: 40) == "Enter")
        #expect(SimulatorKeyMap.code(hidUsage: 88) == "Enter")
    }

    /// The raw value IS the wire name — there is no second spelling for the map to drift from.
    @Test
    func `the vocabulary is the wire's own names`() {
        #expect(SimulatorKeyMap.FunctionalKey.arrowLeft.rawValue == "ArrowLeft")
        #expect(SimulatorKeyMap.FunctionalKey.backspace.rawValue == "Backspace")
        #expect(SimulatorKeyMap.FunctionalKey.forwardDelete.rawValue == "Delete")
    }

    /// A HID usage outside the table is a printable key and rides the `type` path. 4 is `a`.
    @Test
    func `a printable HID usage has no code`() {
        #expect(SimulatorKeyMap.code(hidUsage: 4) == nil)
    }
}

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
