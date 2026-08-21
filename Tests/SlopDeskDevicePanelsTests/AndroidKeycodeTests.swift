// AndroidKeycodeTests — the Android panel's key path: the two key-numbering tables, and the one rule
// they both feed.
//
// The rule is what matters and it is written once (`AndroidKeyMap.resolve(functional:…)`): a key with
// no character travels as a keycode, a chord with ⌘ or ⌃ is dropped rather than typed as a stray
// letter, and everything else goes as text with the control characters filtered out. Each platform
// only supplies its own numbering — macOS a virtual key code, iPadOS a USB HID usage — so the suite
// below pins the numbering tables against each other and then drives the shared rule through both
// entry points.

import SlopDeskVideoProtocol
import Testing
@testable import SlopDeskDevicePanels

private typealias Resolution = AndroidKeyMap.Resolution

@Suite("AndroidKeyMap key numbering")
struct AndroidKeyMapDomainTests {
    /// The load-bearing invariant of the two-domain split: a Mac and an iPad must never disagree
    /// about WHICH keys have no character of their own. Only the numbering may differ.
    ///
    /// Asserted through the two ENTRY POINTS rather than over two tables, because there is only one
    /// table now — the HID side is derived from it, so a pair that disagreed here would be a
    /// marshalling fault, which is the half this suite still owns. The tables' own agreement is
    /// `slopdesk_devicepanel::panel_key`'s to prove, and it does.
    @Test
    func `both numberings reach the same keycode for every functional key`() {
        // (macOS virtual key code, USB HID usage) for the whole run that has no character.
        let pairs: [(UInt16, UInt16)] = [
            (36, 40), (76, 88), (48, 43), (51, 42), (117, 76), (53, 41),
            (126, 82), (125, 81), (123, 80), (124, 79),
            (115, 74), (119, 77), (116, 75), (121, 78),
        ]
        for (keyCode, hidUsage) in pairs {
            let fromMac = AndroidKeyMap.resolve(
                keyCode: keyCode, characters: nil, charactersIgnoringModifiers: nil, modifiers: [],
            )
            let fromPhone = AndroidKeyMap.resolve(
                hidUsage: hidUsage, characters: nil, charactersIgnoringModifiers: nil, modifiers: [],
            )
            #expect(fromMac == fromPhone, "kVK \(keyCode) and HID \(hidUsage) are one key")
            #expect(fromMac != .none, "kVK \(keyCode) has no character, so it must travel")
        }
    }

    /// Both Returns are one keycode in both numberings — Android has no keypad-Enter of its own.
    @Test
    func `the keypad Enter is the same keycode as Return on both`() {
        let expected = Resolution.keycode(.enter, [])
        #expect(AndroidKeyMap.resolve(
            keyCode: 36, characters: nil, charactersIgnoringModifiers: nil, modifiers: [],
        ) == expected)
        #expect(AndroidKeyMap.resolve(
            keyCode: 76, characters: nil, charactersIgnoringModifiers: nil, modifiers: [],
        ) == expected)
        #expect(AndroidKeyMap.resolve(
            hidUsage: 40, characters: nil, charactersIgnoringModifiers: nil, modifiers: [],
        ) == expected)
        #expect(AndroidKeyMap.resolve(
            hidUsage: 88, characters: nil, charactersIgnoringModifiers: nil, modifiers: [],
        ) == expected)
    }

    /// A space is the one key in the shared run that Android wants as TEXT — it has a character, and
    /// taking it off the text path would take it away from the layout that produced it.
    @Test
    func `a space stays on the text path Android wants it on`() {
        #expect(AndroidKeyMap.resolve(
            keyCode: 49, characters: " ", charactersIgnoringModifiers: " ", modifiers: [],
        ) == .text(" "))
    }

    /// An absent `characters` falls back to the stripped spelling; an EMPTY one does not. The two
    /// cross the boundary as a flag beside the buffer for exactly this reason.
    @Test
    func `an absent character is not an empty one across the door`() {
        #expect(AndroidKeyMap.resolve(
            keyCode: 0, characters: nil, charactersIgnoringModifiers: "e", modifiers: [],
        ) == .text("e"))
        #expect(AndroidKeyMap.resolve(
            keyCode: 0, characters: "", charactersIgnoringModifiers: "e", modifiers: [],
        ) == .none)
    }

    /// A backspace has a character (`\u{8}`) and must NOT ride the text path — it would insert a
    /// control character into the field instead of deleting. Asserted through both entry points,
    /// because the whole point of the split is that they answer alike.
    @Test
    func `backspace travels as a keycode from either numbering`() {
        let fromMac = AndroidKeyMap.resolve(
            keyCode: 51, characters: "\u{8}", charactersIgnoringModifiers: "\u{8}", modifiers: [],
        )
        let fromPhone = AndroidKeyMap.resolve(
            hidUsage: 42, characters: "\u{8}", charactersIgnoringModifiers: "\u{8}", modifiers: [],
        )
        #expect(fromMac == .keycode(.del, []))
        #expect(fromPhone == .keycode(.del, []))
    }

    /// A printable key falls through to the text path on both, which is what keeps every non-US
    /// layout working without either table knowing a layout exists.
    @Test
    func `a printable key is text from either numbering`() {
        // 0 is not in either table; `ê` is what a Vietnamese layout produced.
        #expect(AndroidKeyMap.resolve(
            keyCode: 0, characters: "ê", charactersIgnoringModifiers: "e", modifiers: [],
        ) == .text("ê"))
        #expect(AndroidKeyMap.resolve(
            hidUsage: 8, characters: "ê", charactersIgnoringModifiers: "e", modifiers: [],
        ) == .text("ê"))
    }

    /// A ⌘/⌃ chord on a key with no unambiguous keycode is DROPPED, not typed — the panel cannot know
    /// the device's layout, so forwarding it as a letter would send the wrong one.
    @Test
    func `a command chord on a printable key is dropped`() {
        #expect(AndroidKeyMap.resolve(
            hidUsage: 6, characters: "c", charactersIgnoringModifiers: "c", modifiers: [.command],
        ) == .none)
    }

    /// Shift is NOT folded into the meta state: the platform has already applied it to the
    /// characters, and passing the flag along would ask the device to apply it twice.
    @Test
    func `shift is not a meta state`() {
        #expect(AndroidKeyMap.metaState(from: [.shift]).isEmpty)
        #expect(AndroidKeyMap.metaState(from: [.shift, .option]) == .alt)
        #expect(AndroidKeyMap.metaState(from: [.control, .command]) == [.control, .meta])
    }
}
