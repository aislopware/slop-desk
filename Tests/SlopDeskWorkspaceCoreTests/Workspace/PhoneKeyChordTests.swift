import XCTest
@testable import SlopDeskWorkspaceCore

/// The phone's press → ``KeyChord`` marshalling, and the interceptor path it feeds.
///
/// WHICH presses are chords is `slopdesk_workspace::phone_key`, tested there. What is pinned here is
/// the rebuild on this side: a named key must come back as the `KeyChord.Key` case its index names,
/// a printable one as the lower-cased character with ⇧ beside it, and the modifier word must survive
/// the crossing untranslated. Get any of those wrong and the phone resolves against a table it
/// agrees with numerically and disagrees with in meaning — a rebind that works on the Mac and does
/// nothing here.
@MainActor
final class PhoneKeyChordTests: XCTestCase {
    private func press(
        _ base: String = "",
        usage: UInt16 = 0,
        control: Bool = false,
        option: Bool = false,
        command: Bool = false,
        shift: Bool = false,
    ) -> PhoneKey.Press {
        PhoneKey.Press(
            charactersIgnoringModifiers: base, hidUsage: usage,
            control: control, option: option, command: command, shift: shift,
        )
    }

    /// The USB HID keyboard usages `UIKey.keyCode` reports, spelled as numbers because this suite
    /// runs on the macOS runner. `slopdesk_workspace::phone_key` pins each against the key it names.
    private enum HID {
        static let returnKey: UInt16 = 40
        static let tab: UInt16 = 43
        static let space: UInt16 = 44
        static let home: UInt16 = 74
        static let pageUp: UInt16 = 75
        static let pageDown: UInt16 = 78
        static let end: UInt16 = 77
        static let right: UInt16 = 79
        static let left: UInt16 = 80
        static let down: UInt16 = 81
        static let up: UInt16 = 82
    }

    /// A printable letter carries its base from `charactersIgnoringModifiers` and its modifiers beside it.
    func testPrintableBaseAndModifiersCrossTogether() {
        XCTAssertEqual(PhoneKey.keyChord(for: press("d", command: true)), KeyChord(character: "d", [.command]))
        XCTAssertEqual(PhoneKey.keyChord(for: press("a", control: true)), KeyChord(character: "a", [.control]))
        XCTAssertEqual(PhoneKey.keyChord(for: press("j")), KeyChord(character: "j"))
    }

    /// All four modifier bits survive at once, in the table's own numbering.
    func testEveryModifierBitSurvivesTheCrossing() {
        XCTAssertEqual(
            PhoneKey.keyChord(for: press("P", control: true, option: true, command: true, shift: true)),
            KeyChord(character: "p", [.shift, .control, .option, .command]),
        )
    }

    /// Whitespace / control commits are not chords, so ordinary typing falls through untouched.
    func testWhitespaceAndControlScalarsAreNotChords() {
        XCTAssertNil(PhoneKey.keyChord(for: press(" ")))
        XCTAssertNil(PhoneKey.keyChord(for: press("\u{03}")))
    }

    /// Named keys come back as the registry's `Key` cases — the index the door writes is read
    /// through `KeyChord.Key(namedIndex:)`, so a case this build does not know is a `nil` rather
    /// than a guess.
    func testSpecialKeysMapToNamedChords() {
        XCTAssertEqual(PhoneKey.keyChord(for: press(usage: HID.returnKey)), KeyChord(.return))
        XCTAssertEqual(PhoneKey.keyChord(for: press(usage: HID.tab)), KeyChord(.tab))
        XCTAssertEqual(PhoneKey.keyChord(for: press(usage: HID.left)), KeyChord(.leftArrow))
        XCTAssertEqual(PhoneKey.keyChord(for: press(usage: HID.right)), KeyChord(.rightArrow))
        XCTAssertEqual(PhoneKey.keyChord(for: press(usage: HID.up)), KeyChord(.upArrow))
        XCTAssertEqual(PhoneKey.keyChord(for: press(usage: HID.down)), KeyChord(.downArrow))
    }

    /// The four the phone could not name while a chord was keyed by what a key committed — Home,
    /// End and the page keys commit nothing at all, so they were unbindable here (`docs/29` #7).
    func testTheNavBlockIsBindableToo() {
        XCTAssertEqual(PhoneKey.keyChord(for: press(usage: HID.home)), KeyChord(.home))
        XCTAssertEqual(PhoneKey.keyChord(for: press(usage: HID.end)), KeyChord(.end))
        XCTAssertEqual(PhoneKey.keyChord(for: press(usage: HID.pageUp)), KeyChord(.pageUp))
        XCTAssertEqual(
            PhoneKey.keyChord(for: press(usage: HID.pageDown, command: true)),
            KeyChord(.pageDown, [.command]),
        )
    }

    /// Space is a chord only once a non-⇧ modifier is held — the same Vi-mode rule the Mac's
    /// dispatcher applies to its own key code, so ⌃⇧Space is bindable and a space is still a space.
    func testSpaceIsAChordOnlyWithARealModifier() {
        XCTAssertNil(PhoneKey.keyChord(for: press(" ", usage: HID.space)))
        XCTAssertNil(PhoneKey.keyChord(for: press(" ", usage: HID.space, shift: true)))
        XCTAssertEqual(
            PhoneKey.keyChord(for: press(" ", usage: HID.space, control: true, shift: true)),
            KeyChord(.space, [.shift, .control]),
        )
    }

    /// End to end: a phone press → `keyChord` → the SAME ``TerminalKeyInterceptor`` the Mac drives.
    /// A ⌃-letter is forwarded (it is terminal input), a bound ⌘D is resolved and swallowed.
    func testPhonePressThroughInterceptorRoutesBoundChord() {
        var routed: [WorkspaceAction] = []
        let interceptor = TerminalKeyInterceptor(
            resolveChord: { $0 == KeyChord(character: "d", [.command]) ? .splitRight : nil },
            onAction: { routed.append($0) },
        )
        let ctrlA = PhoneKey.keyChord(for: press("a", control: true))
        XCTAssertEqual(ctrlA.map { interceptor.intercept($0) }, ctrlA.map { .forward($0) })
        let dChord = PhoneKey.keyChord(for: press("d", command: true))
        XCTAssertEqual(dChord.map { interceptor.intercept($0) }, .swallow)
        XCTAssertEqual(routed, [.splitRight], "the phone's bound chord routed the split")
    }
}
