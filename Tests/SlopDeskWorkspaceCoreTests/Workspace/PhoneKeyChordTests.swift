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
        _ chars: String,
        ignoring: String? = nil,
        control: Bool = false,
        option: Bool = false,
        command: Bool = false,
        shift: Bool = false,
        special: Bool = false,
    ) -> PhoneKey.Press {
        PhoneKey.Press(
            characters: chars,
            charactersIgnoringModifiers: ignoring ?? chars,
            control: control, option: option, command: command, shift: shift, isSpecial: special,
        )
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
            PhoneKey.keyChord(for: press("P", ignoring: "P", control: true, option: true, command: true, shift: true)),
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
        XCTAssertEqual(PhoneKey.keyChord(for: press("\r", special: true)), KeyChord(.return))
        XCTAssertEqual(PhoneKey.keyChord(for: press("\t", special: true)), KeyChord(.tab))
        XCTAssertEqual(PhoneKey.keyChord(for: press("\u{F702}", special: true)), KeyChord(.leftArrow))
        XCTAssertEqual(PhoneKey.keyChord(for: press("\u{F703}", special: true)), KeyChord(.rightArrow))
        XCTAssertEqual(PhoneKey.keyChord(for: press("\u{F700}", special: true)), KeyChord(.upArrow))
        XCTAssertEqual(PhoneKey.keyChord(for: press("\u{F701}", special: true)), KeyChord(.downArrow))
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
