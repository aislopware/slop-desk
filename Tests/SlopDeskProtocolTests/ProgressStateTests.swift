import XCTest
@testable import SlopDeskProtocol

/// E14 / K1 — the pure progress model `ProgressState` + the OSC 9;4 parser `ProgressOSCParser`
/// (`SlopDeskProtocol`, shared host + client). These pin:
///
/// - `ProgressState(wire:)` maps the four known discriminants (0/1/2/3) and DROPS (`nil`) every
///   unknown byte (4/5/255) — the validate-then-drop / forward-tolerant idiom.
/// - `ProgressOSCParser.parse` accepts the four canonical OSC-9 remainders, CLAMPS an out-of-range
///   percent to 0…100, and DROPS every malformed shape (unknown state, non-integer percent, empty,
///   bare/over-long forms).
///
/// REVERT-TO-CONFIRM-FAIL: before WI-1 there was no `ProgressState`/`ProgressOSCParser` at all — this
/// file does not compile against the un-fixed tree, and each assertion exercises a real branch (an
/// unknown state really must map to `nil`, a `250` percent really must clamp to `100`).
final class ProgressStateTests: XCTestCase {
    // MARK: ProgressState(wire:) — known discriminants map, unknown drop

    func testWireMapsKnownDiscriminants() {
        XCTAssertEqual(ProgressState(wire: 0), .clear)
        XCTAssertEqual(ProgressState(wire: 1), .inProgress)
        XCTAssertEqual(ProgressState(wire: 2), .error)
        XCTAssertEqual(ProgressState(wire: 3), .indeterminate)
    }

    func testWireDropsUnknownDiscriminants() {
        // 4 (paused/warning) and 5 (finished+exit) are deliberately NOT carried here; any other byte
        // is an unknown future state. All must DROP (nil), never coerce to a known case.
        XCTAssertNil(ProgressState(wire: 4))
        XCTAssertNil(ProgressState(wire: 5))
        XCTAssertNil(ProgressState(wire: 6))
        XCTAssertNil(ProgressState(wire: 255))
    }

    func testRawValuesAreStableWireDiscriminants() {
        // The raw values ARE the wire bytes (the host emits `state.rawValue`); pin them so a refactor
        // cannot silently renumber the enum and shift every progress frame.
        XCTAssertEqual(ProgressState.clear.rawValue, 0)
        XCTAssertEqual(ProgressState.inProgress.rawValue, 1)
        XCTAssertEqual(ProgressState.error.rawValue, 2)
        XCTAssertEqual(ProgressState.indeterminate.rawValue, 3)
    }

    // MARK: ProgressOSCParser.parse — the four canonical forms

    func testParseDeterminateInProgress() {
        let result = ProgressOSCParser.parse("4;1;40")
        XCTAssertEqual(result?.state, .inProgress)
        XCTAssertEqual(result?.percent, 40)
    }

    func testParseIndeterminateNoPercentDefaultsToZero() {
        let result = ProgressOSCParser.parse("4;3")
        XCTAssertEqual(result?.state, .indeterminate)
        XCTAssertEqual(result?.percent, 0)
    }

    func testParseError() {
        let result = ProgressOSCParser.parse("4;2;80")
        XCTAssertEqual(result?.state, .error)
        XCTAssertEqual(result?.percent, 80)
    }

    func testParseClearNoPercentDefaultsToZero() {
        let result = ProgressOSCParser.parse("4;0")
        XCTAssertEqual(result?.state, .clear)
        XCTAssertEqual(result?.percent, 0)
    }

    // MARK: percent clamp (out-of-range → clamp, never trust)

    func testParseClampsOverRangePercent() {
        // 250 > 100 → clamped to 100 (never forwarded raw). Exercises the ordered min/max clamp.
        let result = ProgressOSCParser.parse("4;1;250")
        XCTAssertEqual(result?.state, .inProgress)
        XCTAssertEqual(result?.percent, 100)
    }

    func testParseClampsNegativePercentToZero() {
        let result = ProgressOSCParser.parse("4;1;-5")
        XCTAssertEqual(result?.state, .inProgress)
        XCTAssertEqual(result?.percent, 0)
    }

    func testParseAcceptsBoundaryPercents() {
        XCTAssertEqual(ProgressOSCParser.parse("4;1;0")?.percent, 0)
        XCTAssertEqual(ProgressOSCParser.parse("4;1;100")?.percent, 100)
    }

    // MARK: validate-then-drop (malformed shapes → nil)

    func testParseDropsUnknownStateDigit() {
        // `9;4;9` → remainder "4;9": state 9 is not a known discriminant → drop.
        XCTAssertNil(ProgressOSCParser.parse("4;9"))
    }

    func testParseDropsEmptyStateField() {
        // `9;4;` → remainder "4;": an empty state field is not a valid digit → drop (the split keeps
        // the empty subsequence so this is caught, not coalesced into a bare "4").
        XCTAssertNil(ProgressOSCParser.parse("4;"))
    }

    func testParseDropsNonIntegerPercent() {
        // A present-but-garbled percent drops the WHOLE update (never default it to 0 and trust the rest).
        XCTAssertNil(ProgressOSCParser.parse("4;1;abc"))
    }

    func testParseDropsBarePrefixWithNoState() {
        // A bare "4" (the OSC was `ESC]9;4`) has no state field → drop.
        XCTAssertNil(ProgressOSCParser.parse("4"))
    }

    func testParseDropsEmptyBody() {
        XCTAssertNil(ProgressOSCParser.parse(""))
    }

    func testParseDropsNonProgressPrefix() {
        // A body that is not the `4;` progress subtype must not parse as progress (the sniffer only
        // routes `4`/`4;…` here, but the parser is defensive on its own).
        XCTAssertNil(ProgressOSCParser.parse("3;1;40"))
        XCTAssertNil(ProgressOSCParser.parse("42 tests passed"))
    }

    func testParseDropsTooManyFields() {
        // Canonical progress is at most "4;<state>;<pct>" (3 fields); a 4th field is non-canonical → drop.
        XCTAssertNil(ProgressOSCParser.parse("4;1;40;junk"))
    }

    // MARK: parser is Substring-callable (the host feeds a String body; the API is generic)

    func testParseAcceptsSubstring() {
        let body = "x4;1;40".dropFirst() // a Substring "4;1;40"
        XCTAssertEqual(ProgressOSCParser.parse(body)?.percent, 40)
    }
}
