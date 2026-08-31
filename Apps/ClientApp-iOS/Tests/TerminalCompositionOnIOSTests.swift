import Foundation
import XCTest
@testable import SlopDeskPhoneUI

/// The offset arithmetic behind the phone's `UITextInput` conformance (`docs/68` §5.1).
///
/// Here rather than in the SwiftPM suite for the reason every file in this bundle is here:
/// `SlopDeskPhoneUI` is `#if os(iOS)` end to end, so a macOS `swift test` compiles it to an EMPTY
/// module and a suite that lived there would assert nothing at all.
///
/// What is pinned HERE is the CLAMPING, and only that: every position UIKit asks about is derived
/// from these four answers, and a UTF-16 offset that walks off either end is met with a crash rather
/// than a complaint. The conformance's other half — that a marked run actually crosses the renderer
/// seam, and that the caret is converted out of whichever view owns it — is
/// `TerminalCompositionSeamOnIOSTests`, which drives it through a probe rather than a live pane.
/// This header used to claim that half "cannot be driven headlessly". It can.
final class TerminalCompositionOnIOSTests: XCTestCase {
    private func composing(_ text: String, caret: Int) -> TerminalComposition {
        TerminalComposition(text: text, selection: NSRange(location: caret, length: 0))
    }

    /// The document is the composition, counted the way `UITextInput` counts — UTF-16 units, so an
    /// emoji is TWO positions and a Vietnamese vowel with its tone mark is one.
    func testTheDocumentIsMeasuredInTheUnitsUIKitAsks() {
        XCTAssertEqual(composing("", caret: 0).length, 0)
        XCTAssertEqual(composing("tieengs", caret: 7).length, 7)
        XCTAssertEqual(composing("Tiếng", caret: 5).length, 5)
        XCTAssertEqual(composing("👍", caret: 2).length, 2, "one scalar, two UTF-16 positions")
    }

    /// Every offset UIKit hands back is brought inside the document. It derives them itself — a word
    /// boundary past the end, an offset from a position withdrawn since — and expects an answer.
    func testAnOffsetOutsideTheDocumentIsAnsweredAtItsEdge() {
        let held = composing("nihao", caret: 5)
        XCTAssertEqual(held.offset(clamping: -9), 0)
        XCTAssertEqual(held.offset(clamping: 0), 0)
        XCTAssertEqual(held.offset(clamping: 3), 3)
        XCTAssertEqual(held.offset(clamping: 5), 5)
        XCTAssertEqual(held.offset(clamping: 99), 5)
        XCTAssertEqual(composing("", caret: 0).offset(clamping: 4), 0, "an empty document has one position")
    }

    /// A substring reads the same either way round, and clamps both ends.
    func testASubstringIsOrderIndependentAndClamped() {
        let held = composing("nihao", caret: 5)
        XCTAssertEqual(held.substring(from: 0, to: 2), "ni")
        XCTAssertEqual(held.substring(from: 2, to: 0), "ni", "UIKit asks in either order")
        XCTAssertEqual(held.substring(from: 2, to: 2), "")
        XCTAssertEqual(held.substring(from: -4, to: 99), "nihao")
        XCTAssertEqual(composing("", caret: 0).substring(from: 0, to: 1), "")
    }

    /// The caret an input method reports past its own run is answered at the end rather than dropping
    /// the composition: it happens whenever a candidate SHORTENS the text and the caret report lags
    /// it by one call, which is a normal beat of a Pinyin session and not a violation.
    func testACaretPastTheRunLandsAtItsEnd() {
        XCTAssertEqual(composing("ni", caret: 9).caret, NSRange(location: 2, length: 0))
        XCTAssertEqual(composing("nihao", caret: 3).caret, NSRange(location: 3, length: 0))
        XCTAssertEqual(
            TerminalComposition(text: "nihao", selection: NSRange(location: 1, length: 99)).caret,
            NSRange(location: 1, length: 4),
            "a selection running off the end stops at it, keeping its start",
        )
        XCTAssertEqual(
            TerminalComposition(text: "nihao", selection: NSRange(location: 2, length: -1)).caret,
            NSRange(location: 2, length: 0),
            "a negative length is no selection at all, not a backwards one",
        )
    }
}
