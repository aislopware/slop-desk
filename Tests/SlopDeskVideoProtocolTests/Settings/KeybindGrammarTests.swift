import XCTest
@testable import SlopDeskVideoProtocol

/// Pins for the config-binding parser as it crosses — `KeybindGrammar` is the face over
/// `slopdesk-terminal`'s `keybind`, and what this suite checks is the CROSSING: that a chord's
/// modifiers, a literal payload's bytes, a named action's id and argument, and every malformed-drop
/// verdict survive the arena round trip intact.
///
/// The grammar's own cases — each escape, each modifier spelling, each refused base key — are unit
/// tests in the crate. Restating them here would be the cross-language mirror fixture CLAUDE.md
/// forbids: two suites that must be edited together, where only one of them is the implementation.
/// What is NOT restated there and IS here: the whole line, because the whole line is what the app
/// hands over, and ``KeybindingPreferences/KeyChord``'s canonicalisation, which stays on this side.
///
/// Every malformed assertion is a revert-to-confirm-fail guard: it FAILS if a malformed line starts
/// coming back as a binding rather than as `nil`.
final class KeybindGrammarTests: XCTestCase {
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

    /// The literal forms arrive with their lead bytes already resolved: `csi:17~` → `ESC [ 1 7 ~`
    /// (F6, per the spec), `esc:O` → `ESC O`. A multi-byte payload keeps its UTF-8, and the escape
    /// vocabulary decodes on the way.
    func testLiteralActionsCrossWithTheirBytesResolved() {
        XCTAssertEqual(KeybindGrammar.parseLine("cmd+h:csi:17~")?.action, .csi([0x1B, 0x5B, 0x31, 0x37, 0x7E]))
        XCTAssertEqual(KeybindGrammar.parseLine("cmd+h:esc:O")?.action, .esc([0x1B, 0x4F]))
        XCTAssertEqual(KeybindGrammar.parseLine("cmd+h:text:é")?.action, .text(Array("é".utf8)))
        XCTAssertEqual(KeybindGrammar.parseLine(#"cmd+h:text:a\x09b"#)?.action, .text([0x61, 0x09, 0x62]))
    }

    /// `cmd+1:goto_tab:1` — the chord is everything before the FIRST colon; the action keeps its own
    /// colon. An absent argument crosses as `nil`, not as an empty string.
    func testParseLineParameterisedAction() {
        let parsed = KeybindGrammar.parseLine("cmd+1:goto_tab:1")
        XCTAssertEqual(parsed?.chord, .init(key: "1", command: true))
        XCTAssertEqual(parsed?.action, .named(id: "goto_tab", arg: "1"))
        XCTAssertEqual(KeybindGrammar.parseLine("cmd+t:new_tab")?.action, .named(id: "new_tab", arg: nil))
    }

    /// `unbind:cmd+q` — the directive is the whole left side; the chord is the remainder.
    func testParseLineUnbind() {
        let parsed = KeybindGrammar.parseLine("unbind:cmd+q")
        XCTAssertEqual(parsed?.chord, .init(key: "q", command: true))
        XCTAssertEqual(parsed?.action, .unbind)
    }

    // MARK: The half that stays on this side

    /// A parsed chord feeds straight into `KeyChord`, whose canonicalisation is Swift's: the far side
    /// answers the key as the user lowercased it, and the alias fold (`leftarrow` → `left`) and the
    /// canonical modifier ORDER happen here — the same fold a dispatched chord goes through, which is
    /// what makes a parsed chord and a dispatched one key the same map entry.
    func testParsedChordCanonicalisesOnThisSide() {
        XCTAssertEqual(KeybindGrammar.parseLine("cmd+home:new_tab")?.chord.key, "home")
        XCTAssertEqual(KeybindGrammar.parseLine("cmd+home:new_tab")?.chord.canonical, "cmd+home")
        XCTAssertEqual(
            KeybindGrammar.parseLine("ctrl+shift+pageup:new_tab")?.chord.canonical,
            "ctrl+shift+pageup",
        )
        XCTAssertEqual(
            KeybindGrammar.parseLine("cmd+leftarrow:new_tab")?.chord,
            KeybindGrammar.parseLine("cmd+left:new_tab")?.chord,
            "the alias fold is KeyChord's, and it still happens",
        )
        // `alt` and `opt` are the same modifier, and a modifier-only difference is a different chord.
        XCTAssertEqual(
            KeybindGrammar.parseLine("alt+d:new_tab")?.chord,
            KeybindGrammar.parseLine("opt+d:new_tab")?.chord,
        )
        XCTAssertEqual(KeybindGrammar.parseLine("ctrl+a:new_tab")?.chord, .init(key: "a", control: true))
    }

    // MARK: Malformed → drop (validate-then-drop; revert-to-confirm-fail)

    func testMalformedLinesReturnNil() {
        XCTAssertNil(KeybindGrammar.parseLine(""), "empty line")
        XCTAssertNil(KeybindGrammar.parseLine("cmd+h"), "no colon ⇒ no action")
        XCTAssertNil(KeybindGrammar.parseLine("badmod+h:text:hi"), "malformed chord ⇒ whole line drops")
        XCTAssertNil(KeybindGrammar.parseLine("cmd+h:text:"), "malformed action ⇒ whole line drops")
        XCTAssertNil(KeybindGrammar.parseLine("cmd+h:goto_tab:abc"), "a non-numeric goto_tab arg")
        XCTAssertNil(KeybindGrammar.parseLine(#"cmd+h:text:\x1"#), "a truncated hex escape")
        XCTAssertNil(KeybindGrammar.parseLine("unbind:"), "unbind with no chord")
        XCTAssertNil(KeybindGrammar.parseLine("unbind:badmod+q"), "unbind with malformed chord")
    }

    /// `escape`/`esc`, `delete`, `backspace` and `forwarddelete` are refused as base keys: neither
    /// `mapKey` nor the registry's `KeyChord.Key` can resolve them, so such a binding would parse,
    /// store, and then never fire. The drop is the whole LINE, not a partial parse.
    ///
    /// `space` used to be on that list and did not belong there — `mapKey` maps it to `.space` and
    /// the dispatcher names it (⌃⇧Space enters Vi mode), so refusing it withheld a chord the app
    /// can actually deliver.
    func testAKeyTheDispatcherCannotResolveDropsTheWholeLine() {
        for key in ["escape", "esc", "delete", "backspace", "forwarddelete"] {
            XCTAssertNil(KeybindGrammar.parseLine("cmd+\(key):text:hi"), "cmd+\(key) never fires, so it drops")
            XCTAssertNil(KeybindGrammar.parseLine("unbind:\(key)"), "and neither does an unbind of it")
        }
        // Guards against that drop over-reaching: every key `mapKey` DOES accept stays bindable.
        for key in [
            "return", "enter", "tab", "space", "left", "leftarrow", "right", "rightarrow", "up",
            "uparrow", "down", "downarrow", "pageup", "pgup", "pagedown", "pgdn", "home", "end",
        ] {
            XCTAssertNotNil(KeybindGrammar.parseLine("cmd+\(key):new_tab"), "cmd+\(key) stays bindable")
        }
        XCTAssertNotNil(KeybindGrammar.parseLine("cmd+a:new_tab"), "and so does a single printable char")
    }

    /// The question the CLI's `config validate` asks of every line, answered without building the
    /// binding — the same verdict, one call instead of a parse the caller then throws away.
    func testIsValidLineAgreesWithParseLine() {
        for line in ["cmd+t:new_tab", "cmd+1:goto_tab:1", "unbind:cmd+q", "", "font-size = 14", "cmd+h"] {
            XCTAssertEqual(
                KeybindGrammar.isValidLine(line), KeybindGrammar.parseLine(line) != nil,
                "the cheap answer and the full one disagree about \(line)",
            )
        }
    }
}
