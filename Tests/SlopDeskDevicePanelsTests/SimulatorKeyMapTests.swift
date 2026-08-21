// SimulatorKeyMapTests — the simulator's key path from THIS side of the boundary: the numbers a Mac
// reports, the names that come back, and the modifiers that ride along.
//
// The table moved to `slopdesk_devicepanel::panel_key`, so what these tests are for moved with it.
// The rule — which keys have no character, and what each server calls them — is proved there. What
// only this side can check is that the numbers reach the door and the names come back, which is why
// every assertion below now goes through `code(for:)`/`code(hidUsage:)` rather than reading a map.
//
// The first suite is still a PIN, and it is the reason this file is worth its length. `panel_key`
// spells its macOS virtual key codes as literals, because `kVK_*` lives in `Carbon.HIToolbox` and
// the iOS triple has no such framework — and a literal table is exactly the kind that rots silently.
// So each row is asserted against the SDK's own constant HERE, on the half where Carbon exists. A
// typo in the shared floor fails a build rather than swallowing an arrow key on a device someone is
// typing into.

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

    /// The pin only holds while it covers the whole table — a key added to the far side and not to
    /// the list above would be unpinned and nothing would say so. Swept rather than counted, now
    /// that the table is Rust's: every keycode a Mac can report is asked, and every one that answers
    /// must be a row here.
    @Test
    func `the pin covers every key the door answers for`() {
        let answered = (UInt16(0)...255).compactMap { keyCode in
            SimulatorKeyMap.code(for: keyCode).map { (Int(keyCode), $0) }
        }
        #expect(answered.count == Self.rows.count)
        for (keyCode, name) in answered {
            #expect(Self.rows.contains { $0 == keyCode && $1 == name }, "kVK \(keyCode) is unpinned")
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
}
#endif

@Suite("SimulatorKeyMap key numbering")
struct SimulatorKeyMapDomainTests {
    /// The load-bearing invariant of the two-domain split: a Mac and an iPad must never disagree
    /// about WHICH keys have no character of their own. Only the numbering may differ.
    ///
    /// Swept through the two doors, because there is only one table now and the HID side is derived
    /// from it — so what this can still catch is a MARSHALLING fault, which is the half this suite
    /// owns. That the tables agree is `slopdesk_devicepanel::panel_key`'s to prove, and it does.
    @Test
    func `both numberings reach the same set of names`() {
        let fromKeyCode = Set((UInt16(0)...255).compactMap { SimulatorKeyMap.code(for: $0) })
        let fromHID = Set((UInt16(0)...255).compactMap { SimulatorKeyMap.code(hidUsage: $0) })
        #expect(fromKeyCode == fromHID)
        #expect(fromKeyCode.count == 14, "the whole run that has no character of its own")
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

    /// The names the server expects, arriving as bytes rather than as a Swift enum's raw value.
    /// `Delete` for forward-delete is the one that looks like a typo and is not — it is the server's
    /// own spelling, and `Backspace` is what macOS calls Delete.
    @Test
    func `the vocabulary is the wire's own names`() {
        #expect(SimulatorKeyMap.code(for: 123) == "ArrowLeft")
        #expect(SimulatorKeyMap.code(for: 51) == "Backspace")
        #expect(SimulatorKeyMap.code(for: 117) == "Delete")
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
