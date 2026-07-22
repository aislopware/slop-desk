// KeyChordNormalizerTests — the PURE NSEvent→`KeyChord` mapping the live dispatcher feeds the
// prefix machine. Exercised headlessly: the normalizer is AppKit-free (takes the destructured event fields),
// so no `NSEvent` is constructed and no SCStream/VT/Metal/VideoWindowView is touched. Each test pins a fact
// the dispatcher relies on: modifier mapping, the base-key/charactersIgnoringModifiers parity with
// GhosttyTerminalView + the keybindings editor, the named-key keyCodes, the bare-key passthrough boundary,
// and the send-prefix C0 literal-byte mapping.

#if os(macOS)
import SlopDeskWorkspaceCore
import XCTest
@testable import SlopDeskClientUI

@MainActor
final class KeyChordNormalizerTests: XCTestCase {
    private func mods(
        shift: Bool = false, control: Bool = false, option: Bool = false, command: Bool = false,
    ) -> KeyChordNormalizer.Modifiers {
        .init(shift: shift, control: control, option: option, command: command)
    }

    /// A plain printable letter with ⌘ maps to the lower-cased character chord + the ⌘ modifier — the
    /// ⌘D split chord the registry binds.
    func testCommandLetterMapsToCharacterChord() {
        let chord = KeyChordNormalizer.chord(
            charactersIgnoringModifiers: "d", keyCode: 2, modifierFlags: mods(command: true),
        )
        XCTAssertEqual(chord, KeyChord(character: "d", [.command]))
    }

    /// Every modifier bit maps to its `KeyChord.Modifiers` flag (parity with `ghosttyMods`'s shift/ctrl/opt/
    /// cmd reads). ⇧⌥⌘C → the centre-all chord shape.
    func testAllModifiersMap() {
        let chord = KeyChordNormalizer.chord(
            charactersIgnoringModifiers: "c", keyCode: 8,
            modifierFlags: mods(shift: true, control: true, option: true, command: true),
        )
        XCTAssertEqual(chord, KeyChord(character: "c", [.shift, .control, .option, .command]))
    }

    /// `charactersIgnoringModifiers` still reflects ⇧ (a shifted "2" reports "@" on some layouts, but a
    /// shifted letter reports the UPPER letter) — the normalizer lower-cases it via `KeyChord.init`, so the
    /// case lives in `.shift`, not the base key. ⇧A and a (with .shift) produce the same base "a".
    func testShiftIsCarriedInModifiersNotTheCharacter() {
        let upper = KeyChordNormalizer.chord(
            charactersIgnoringModifiers: "A", keyCode: 0, modifierFlags: mods(shift: true, command: true),
        )
        XCTAssertEqual(upper, KeyChord(character: "a", [.shift, .command]))
    }

    /// A bare unmodified printable key still NORMALIZES to a chord (the dispatcher decides passthrough by a
    /// table miss, not by the normalizer rejecting it) — but it carries NO modifiers.
    func testBareKeyNormalizesWithoutModifiers() {
        let chord = KeyChordNormalizer.chord(
            charactersIgnoringModifiers: "j", keyCode: 38, modifierFlags: mods(),
        )
        XCTAssertEqual(chord, KeyChord(character: "j"))
        XCTAssertTrue(chord?.modifiers.isEmpty == true)
    }

    /// A Ctrl-letter reports its printable base ("a" for ⌃A) so the configured tmux prefix is recognised.
    func testControlLetterMapsToCharacterChord() {
        let chord = KeyChordNormalizer.chord(
            charactersIgnoringModifiers: "a", keyCode: 0, modifierFlags: mods(control: true),
        )
        XCTAssertEqual(chord, KeyChord(character: "a", [.control]))
    }

    /// Named non-printable keys map from `keyCode` (parity with KeybindingsEditorView.baseKey): Return/Tab/
    /// arrows resolve to the registry `Key` cases regardless of any `charactersIgnoringModifiers`.
    func testNamedKeyCodesMap() {
        XCTAssertEqual(
            KeyChordNormalizer.chord(charactersIgnoringModifiers: nil, keyCode: 36, modifierFlags: mods(command: true)),
            KeyChord(.return, [.command]),
        )
        XCTAssertEqual(
            KeyChordNormalizer.chord(charactersIgnoringModifiers: "\t", keyCode: 48, modifierFlags: mods()),
            KeyChord(.tab),
        )
        XCTAssertEqual(
            KeyChordNormalizer.chord(
                charactersIgnoringModifiers: nil,
                keyCode: 123,
                modifierFlags: mods(option: true, command: true),
            ),
            KeyChord(.leftArrow, [.option, .command]),
        )
        XCTAssertEqual(
            KeyChordNormalizer.chord(
                charactersIgnoringModifiers: nil,
                keyCode: 124,
                modifierFlags: mods(option: true, command: true),
            ),
            KeyChord(.rightArrow, [.option, .command]),
        )
        XCTAssertEqual(
            KeyChordNormalizer.chord(charactersIgnoringModifiers: nil, keyCode: 126, modifierFlags: mods()),
            KeyChord(.upArrow),
        )
        XCTAssertEqual(
            KeyChordNormalizer.chord(charactersIgnoringModifiers: nil, keyCode: 125, modifierFlags: mods()),
            KeyChord(.downArrow),
        )
    }

    /// A pure-modifier press (no characters, no named keyCode) yields `nil` so the dispatcher leaves it
    /// untouched. Whitespace / control scalars also yield `nil` (they are never workspace chords).
    func testUnmappableYieldsNil() {
        XCTAssertNil(KeyChordNormalizer.chord(
            charactersIgnoringModifiers: nil,
            keyCode: 56 /* shift */,
            modifierFlags: mods(shift: true),
        ))
        XCTAssertNil(KeyChordNormalizer.chord(charactersIgnoringModifiers: " ", keyCode: 49, modifierFlags: mods()))
        XCTAssertNil(KeyChordNormalizer.chord(
            charactersIgnoringModifiers: "",
            keyCode: 99,
            modifierFlags: mods(command: true),
        ))
    }

    /// ⌃⇧Space (the Vi Mode entry chord, keyCode 49) maps to the NAMED `.space` chord so
    /// the dispatcher's `resolvedChordTable` alias resolves it. A bare Space / ⇧-only Space (no ⌃/⌥/⌘) stays
    /// normal typing → `nil`, so the modified-only mapping never swallows the space bar. Without the keyCode-49
    /// case, ⌃⇧Space would fall to the whitespace rejection and yield `nil`, making the Vi Mode chord
    /// unreachable on macOS.
    func testControlShiftSpaceMapsToNamedSpaceChord() {
        XCTAssertEqual(
            KeyChordNormalizer.chord(
                charactersIgnoringModifiers: " ", keyCode: 49, modifierFlags: mods(shift: true, control: true),
            ),
            KeyChord(.space, [.shift, .control]),
            "⌃⇧Space maps to the named .space chord (Vi Mode entry)",
        )
        // ⇧-only Space (no ⌃/⌥/⌘) is still typing — it must NOT become a chord.
        XCTAssertNil(
            KeyChordNormalizer.chord(charactersIgnoringModifiers: " ", keyCode: 49, modifierFlags: mods(shift: true)),
            "a ⇧-only Space is normal typing, not a chord",
        )
    }
}
#endif
