import Foundation
import XCTest
@testable import SlopDeskVideoProtocol

/// E1/WI-6 — pins for the PURE config-binding parser (`KeybindGrammar`). Covers every action prefix
/// (`text:` / `csi:` / `esc:`), the `unbind:<chord>` directive, the parameterised `goto_tab:N` named
/// action, modifier-permutation chord parsing, the escape vocabulary, and — load-bearing per CLAUDE.md
/// §3 — the malformed-drop cases (a hostile / malformed line returns `nil`, never traps). Every malformed
/// assertion is a revert-to-confirm-fail guard: it FAILS if the parser stops validating that token.
final class KeybindGrammarTests: XCTestCase {
    // MARK: Action prefixes

    func testTextActionIsLiteralUTF8Bytes() {
        XCTAssertEqual(KeybindGrammar.parseAction("text:hi"), .text([0x68, 0x69]))
        // A multi-byte UTF-8 string keeps its bytes.
        XCTAssertEqual(KeybindGrammar.parseAction("text:é"), .text(Array("é".utf8)))
    }

    /// `csi:17~` → `ESC [ 1 7 ~` (the F6 key sequence per the spec).
    func testCSIActionPrependsEscBracket() {
        XCTAssertEqual(
            KeybindGrammar.parseAction("csi:17~"),
            .csi([0x1B, 0x5B, 0x31, 0x37, 0x7E]),
        )
    }

    /// `esc:O` → `ESC O`.
    func testEscActionPrependsEsc() {
        XCTAssertEqual(KeybindGrammar.parseAction("esc:O"), .esc([0x1B, 0x4F]))
    }

    /// A bare named action and a parameterised one (`goto_tab:1`) — the arg is split on the FIRST colon.
    func testNamedAndParameterisedActions() {
        XCTAssertEqual(KeybindGrammar.parseAction("new_tab"), .named(id: "new_tab", arg: nil))
        XCTAssertEqual(KeybindGrammar.parseAction("goto_tab:1"), .named(id: "goto_tab", arg: "1"))
        XCTAssertEqual(
            KeybindGrammar.parseAction("copy_to_clipboard"),
            .named(id: "copy_to_clipboard", arg: nil),
        )
    }

    // MARK: Escape vocabulary inside a literal payload

    func testLiteralEscapeVocabulary() {
        XCTAssertEqual(KeybindGrammar.parseAction(#"text:\n"#), .text([0x0A]))
        XCTAssertEqual(KeybindGrammar.parseAction(#"text:\r\t"#), .text([0x0D, 0x09]))
        XCTAssertEqual(KeybindGrammar.parseAction(#"text:\e"#), .text([0x1B]))
        XCTAssertEqual(KeybindGrammar.parseAction(#"text:\\"#), .text([0x5C]))
        // `\xNN` → the raw byte.
        XCTAssertEqual(KeybindGrammar.parseAction(#"text:\x1b"#), .text([0x1B]))
        XCTAssertEqual(KeybindGrammar.parseAction(#"text:a\x09b"#), .text([0x61, 0x09, 0x62]))
    }

    // MARK: Chord parsing

    func testChordModifierPermutations() {
        XCTAssertEqual(
            KeybindGrammar.parseChord("cmd+shift+h"),
            KeybindingPreferences.KeyChord(key: "h", command: true, shift: true),
        )
        XCTAssertEqual(
            KeybindGrammar.parseChord("ctrl+a"),
            KeybindingPreferences.KeyChord(key: "a", control: true),
        )
        // `alt` and `opt` are the same modifier.
        XCTAssertEqual(KeybindGrammar.parseChord("alt+d"), KeybindGrammar.parseChord("opt+d"))
        XCTAssertEqual(
            KeybindGrammar.parseChord("opt+d"),
            KeybindingPreferences.KeyChord(key: "d", option: true),
        )
        // A digit base key and a named base key.
        XCTAssertEqual(
            KeybindGrammar.parseChord("cmd+1"),
            KeybindingPreferences.KeyChord(key: "1", command: true),
        )
        XCTAssertEqual(
            KeybindGrammar.parseChord("cmd+pageup"),
            KeybindingPreferences.KeyChord(key: "pageup", command: true),
        )
    }

    /// A parsed named-key chord preserves the (lowercased) named key and canonicalises correctly — the
    /// grammar's named-key vocabulary feeds straight into `KeyChord` (which the WorkspaceCore registry
    /// bridge then maps via its own `mapKey`; that mapping is pinned in WorkspaceCore's tests, this pins the
    /// grammar half).
    func testParsedNamedChordPreservesKeyAndCanonical() {
        let chord = KeybindGrammar.parseChord("cmd+home")
        XCTAssertEqual(chord?.key, "home")
        XCTAssertEqual(chord?.canonical, "cmd+home")
        // A modifier-stacked named key keeps its canonical modifier order.
        XCTAssertEqual(KeybindGrammar.parseChord("ctrl+shift+pageup")?.canonical, "ctrl+shift+pageup")
    }

    // MARK: Whole-line parse

    func testParseLineChordAndAction() {
        let parsed = KeybindGrammar.parseLine("cmd+shift+h:text:hi")
        XCTAssertEqual(
            parsed,
            KeybindGrammar.ParsedBinding(
                chord: .init(key: "h", command: true, shift: true),
                action: .text([0x68, 0x69]),
            ),
        )
    }

    /// `cmd+1:goto_tab:1` — the chord is everything before the FIRST colon; the action keeps its own colon.
    func testParseLineParameterisedAction() {
        let parsed = KeybindGrammar.parseLine("cmd+1:goto_tab:1")
        XCTAssertEqual(parsed?.chord, .init(key: "1", command: true))
        XCTAssertEqual(parsed?.action, .named(id: "goto_tab", arg: "1"))
    }

    /// `unbind:cmd+q` — the directive is the whole left side; the chord is the remainder.
    func testParseLineUnbind() {
        let parsed = KeybindGrammar.parseLine("unbind:cmd+q")
        XCTAssertEqual(parsed?.chord, .init(key: "q", command: true))
        XCTAssertEqual(parsed?.action, .unbind)
    }

    // MARK: Malformed → drop (validate-then-drop; revert-to-confirm-fail)

    func testMalformedActionsReturnNil() {
        XCTAssertNil(KeybindGrammar.parseAction(""), "empty action")
        XCTAssertNil(KeybindGrammar.parseAction("text:"), "empty text payload")
        XCTAssertNil(KeybindGrammar.parseAction("csi:"), "empty csi payload")
        XCTAssertNil(KeybindGrammar.parseAction("esc:"), "empty esc payload")
        XCTAssertNil(KeybindGrammar.parseAction("goto_tab:"), "empty named arg")
        XCTAssertNil(KeybindGrammar.parseAction("goto_tab:abc"), "non-numeric goto_tab arg")
        XCTAssertNil(KeybindGrammar.parseAction(":foo"), "empty named id")
        // A dangling / unknown escape in a literal payload drops the whole payload.
        XCTAssertNil(KeybindGrammar.parseAction(#"text:\"#), "dangling backslash")
        XCTAssertNil(KeybindGrammar.parseAction(#"text:\q"#), "unknown escape")
        XCTAssertNil(KeybindGrammar.parseAction(#"text:\x1"#), "truncated hex escape")
        XCTAssertNil(KeybindGrammar.parseAction(#"text:\xzz"#), "non-hex escape")
    }

    func testMalformedChordsReturnNil() {
        XCTAssertNil(KeybindGrammar.parseChord(""), "empty chord")
        XCTAssertNil(KeybindGrammar.parseChord("cmd+"), "missing base key")
        XCTAssertNil(KeybindGrammar.parseChord("+h"), "leading empty modifier")
        XCTAssertNil(KeybindGrammar.parseChord("cmd++h"), "empty middle modifier")
        XCTAssertNil(KeybindGrammar.parseChord("hyper+h"), "unknown modifier")
        XCTAssertNil(KeybindGrammar.parseChord("cmd+notakey"), "multi-char non-named base key")
        XCTAssertNil(KeybindGrammar.parseChord("cmd+b>cmd+v"), "sequences are not single chords")
    }

    /// E7/WI-6 carry-over #3 (revert-to-confirm-fail): `space`, `escape`/`esc`, `delete`, `backspace`, and
    /// `forwarddelete` are DROPPED from the base-key vocabulary — neither `mapKey` nor the registry
    /// `KeyChord.Key` enum can resolve them, so a chord binding one would parse but never fire (a silent
    /// no-op). Validate-then-drop (CLAUDE.md §3) means `parseChord` must now return `nil` for them, bare OR
    /// modifier-prefixed. This FAILS on the pre-fix code, which accepted all six as valid base keys.
    func testSpaceEscapeDeleteBaseKeysAreRejected() {
        for key in ["space", "escape", "esc", "delete", "backspace", "forwarddelete"] {
            XCTAssertNil(KeybindGrammar.parseChord(key), "bare \(key) is no longer a valid base key")
            XCTAssertNil(KeybindGrammar.parseChord("cmd+\(key)"), "cmd+\(key) is no longer a valid chord")
        }
        // And via the whole-line parser: a binding on a dropped key drops the whole line (no partial parse).
        XCTAssertNil(KeybindGrammar.parseLine("cmd+escape:text:hi"), "a dropped base key drops the whole line")
        XCTAssertNil(KeybindGrammar.parseLine("unbind:space"), "unbind on a dropped base key drops the line")
    }

    /// The still-resolvable named keys (every one `mapKey` accepts) and a single printable char STAY valid —
    /// guards against the #3 drop over-reaching and removing a key that DOES resolve.
    func testResolvableNamedAndSingleCharBaseKeysStayValid() {
        for key in [
            "return", "enter", "tab", "left", "leftarrow", "right", "rightarrow", "up", "uparrow",
            "down", "downarrow", "pageup", "pgup", "pagedown", "pgdn", "home", "end",
        ] {
            XCTAssertNotNil(KeybindGrammar.parseChord("cmd+\(key)"), "cmd+\(key) stays a valid chord")
        }
        XCTAssertNotNil(KeybindGrammar.parseChord("cmd+a"), "a single printable char stays a valid base key")
    }

    func testMalformedLinesReturnNil() {
        XCTAssertNil(KeybindGrammar.parseLine(""), "empty line")
        XCTAssertNil(KeybindGrammar.parseLine("cmd+h"), "no colon ⇒ no action")
        XCTAssertNil(KeybindGrammar.parseLine("badmod+h:text:hi"), "malformed chord ⇒ whole line drops")
        XCTAssertNil(KeybindGrammar.parseLine("cmd+h:text:"), "malformed action ⇒ whole line drops")
        XCTAssertNil(KeybindGrammar.parseLine("unbind:"), "unbind with no chord")
        XCTAssertNil(KeybindGrammar.parseLine("unbind:badmod+q"), "unbind with malformed chord")
    }
}
