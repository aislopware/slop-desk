import SlopDeskVideoProtocol
import XCTest
@testable import SlopDeskWorkspaceCore

/// WS-B / B7 — the iOS substrate's `InputRouting.keyChord(for:)` maps a platform-agnostic `KeyPress` to the
/// SAME `KeyChord` the macOS path produces, so the iOS `pressesBegan` responder can feed the shared
/// ``TerminalKeyInterceptor`` (prefix engine + `resolvedChordTable`). Headless (no UIKit); pins the mapping +
/// the end-to-end "iOS press → interceptor disposition" wiring. FAILS on the un-fixed code (the mapping did
/// not exist).
@MainActor
final class InputRoutingKeyChordTests: XCTestCase {
    private func press(
        _ chars: String,
        ignoring: String? = nil,
        control: Bool = false,
        option: Bool = false,
        command: Bool = false,
        shift: Bool = false,
        special: Bool = false,
    ) -> InputRouting.KeyPress {
        InputRouting.KeyPress(
            characters: chars,
            charactersIgnoringModifiers: ignoring ?? chars,
            control: control, option: option, command: command, shift: shift, isSpecial: special,
        )
    }

    /// A printable letter with ⌘ maps to the ⌘-letter chord (the base from `charactersIgnoringModifiers`).
    func testCommandLetterMapsToChord() {
        XCTAssertEqual(InputRouting.keyChord(for: press("d", command: true)), KeyChord(character: "d", [.command]))
    }

    /// A Ctrl-letter maps to the Ctrl chord (so the default ⌃A prefix is recognised on iOS).
    func testControlLetterMapsToChord() {
        XCTAssertEqual(InputRouting.keyChord(for: press("a", control: true)), KeyChord(character: "a", [.control]))
    }

    /// A bare printable letter still maps (the interceptor then FORWARDS it — classification ≠ swallowing).
    func testBareLetterMaps() {
        XCTAssertEqual(InputRouting.keyChord(for: press("j")), KeyChord(character: "j"))
    }

    /// Whitespace / control commit (a space, a raw control byte) is NOT a workspace chord → `nil`, so normal
    /// typing falls through the iOS key/IME path untouched.
    func testWhitespaceAndControlScalarsAreNotChords() {
        XCTAssertNil(InputRouting.keyChord(for: press(" ")))
        XCTAssertNil(InputRouting.keyChord(for: press("\u{03}"))) // a bare C0 control char
    }

    /// Named special keys map to the registry `Key` cases (Return / Tab / arrows) regardless of modifiers.
    func testSpecialKeysMapToNamedChords() {
        XCTAssertEqual(InputRouting.keyChord(for: press("\r", special: true)), KeyChord(.return))
        XCTAssertEqual(InputRouting.keyChord(for: press("\t", special: true)), KeyChord(.tab))
        XCTAssertEqual(InputRouting.keyChord(for: press("\u{F702}", special: true)), KeyChord(.leftArrow))
        XCTAssertEqual(InputRouting.keyChord(for: press("\u{F703}", special: true)), KeyChord(.rightArrow))
        XCTAssertEqual(InputRouting.keyChord(for: press("\u{F700}", special: true)), KeyChord(.upArrow))
        XCTAssertEqual(InputRouting.keyChord(for: press("\u{F701}", special: true)), KeyChord(.downArrow))
    }

    /// End-to-end iOS substrate wiring: an iOS press → `keyChord` → ``TerminalKeyInterceptor`` resolves a
    /// bound chord — the exact path the `pressesBegan` responder will run. A Ctrl-letter (⌃A) is FORWARDED
    /// untouched (no prefix machine exists to claim it — DECISIONS.md 2026-07-22).
    func testIOSPressThroughInterceptorRoutesBoundChord() {
        var routed: [WorkspaceAction] = []
        let interceptor = TerminalKeyInterceptor(
            resolveChord: { $0 == KeyChord(character: "d", [.command]) ? .splitRight : nil },
            onAction: { routed.append($0) },
        )
        // ⌃A press → ordinary terminal input, forwarded.
        let ctrlA = InputRouting.keyChord(for: press("a", control: true))
        XCTAssertEqual(ctrlA.map { interceptor.intercept($0) }, ctrlA.map { .forward($0) })
        // ⌘D press → resolve + swallow.
        let dChord = InputRouting.keyChord(for: press("d", command: true))
        XCTAssertEqual(dChord.map { interceptor.intercept($0) }, .swallow)
        XCTAssertEqual(routed, [.splitRight], "the iOS bound chord routed the split")
    }
}
