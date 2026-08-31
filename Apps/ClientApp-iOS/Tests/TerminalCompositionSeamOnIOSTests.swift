// TerminalCompositionSeamOnIOSTests — the phone's `UITextInput` conformance, driven.
//
// The composition arithmetic is pinned next door. What is pinned here is everything the conformance
// does that is not arithmetic, and the reason it CAN be is that `TerminalInputHostView.surface` is
// an injectable seam: a probe standing in for the renderer sees exactly what a live one would.
//
// ⚠️ THIS IS NOT A SECOND RENDERER. The probe answers the three members the seam has no default for
// and records what it was told; every band-or-grid decision stays where it lives, in
// `PhoneTerminalRendererView`, and `TerminalPreeditPixelsOnIOSTests` photographs the outcome. What
// the probe is for is the crossing itself — whether the responder tells the pixels anything at all,
// and in what units — which no pixel rig can see and no arithmetic test can reach.

import SlopDeskWorkspaceCore
import UIKit
import XCTest
@testable import SlopDeskPhoneUI

@MainActor
final class TerminalCompositionSeamOnIOSTests: XCTestCase {
    /// Every text trait is OFF, which is the difference between adopting `UITextInput` and shipping a
    /// regression as a feature.
    ///
    /// A terminal is the one text field where each of these is destructive: smart quotes rewrite `"`
    /// as `"` so a shell string never closes, smart dashes fold `--flag` into `–flag`,
    /// autocapitalisation shifts the first letter of every command, and autocorrect rewrites the words
    /// it does not know, which at a prompt is all of them. `UIKeyInput` alone offered none of them, so
    /// each is a door the conformance opened and this test is what keeps them shut.
    func testEveryTextTraitIsOffSoAShellLineIsNeverRewritten() {
        let host = TerminalInputHostView(frame: .zero)
        XCTAssertEqual(host.autocorrectionType, .no)
        XCTAssertEqual(host.autocapitalizationType, .none)
        XCTAssertEqual(host.spellCheckingType, .no)
        XCTAssertEqual(host.smartQuotesType, .no)
        XCTAssertEqual(host.smartDashesType, .no)
        XCTAssertEqual(host.smartInsertDeleteType, .no)
    }

    /// A marked run crosses the seam, and so does its withdrawal.
    ///
    /// The withdrawal is the half worth holding: an empty `text` is how the seam SAYS "nothing is
    /// composed", so a conformance that dropped its own copy and told the pixels nothing would leave
    /// an underlined run on screen with no input method behind it — visible, permanent, and invisible
    /// to any test of the document arithmetic.
    func testAMarkedRunCrossesTheSeamAndSoDoesItsWithdrawal() throws {
        let host = TerminalInputHostView(frame: .zero)
        let probe = SeamProbe()
        host.surface = probe

        host.setMarkedText("にほ", selectedRange: NSRange(location: 1, length: 0))
        let marked = try XCTUnwrap(probe.composed.last)
        XCTAssertEqual(marked.text, "にほ", "the run reaches the pixels verbatim")
        XCTAssertEqual(marked.selection, NSRange(location: 1, length: 0), "and so does its own caret")
        let range = try XCTUnwrap(host.markedTextRange, "the run is marked on this side too")
        XCTAssertEqual(
            host.offset(from: range.start, to: range.end), 2,
            "two UTF-16 units, which is what UIKit will ask every position against",
        )

        host.unmarkText()
        XCTAssertEqual(probe.composed.last?.text, "", "an empty run is how a withdrawal is spelled")
        XCTAssertNil(host.markedTextRange, "and this side dropped it too")
    }

    /// An input method that reports an empty run is withdrawing, not composing nothing.
    func testAnEmptyMarkedRunIsAWithdrawal() {
        let host = TerminalInputHostView(frame: .zero)
        let probe = SeamProbe()
        host.surface = probe

        host.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0))
        host.setMarkedText("", selectedRange: NSRange(location: 0, length: 0))
        XCTAssertNil(host.markedTextRange)
        XCTAssertEqual(probe.composed.last?.text, "")
    }

    /// A commit ENDS the composition, and the preedit goes down with it.
    ///
    /// UIKit usually unmarks around `insertText(_:)` itself — but not on every path, and a candidate
    /// accepted by a hardware Return arrives with the run still marked. What would be left is a stale
    /// underline sitting under text that is already on the line: the one artefact a user reads as the
    /// terminal being broken, and the one no arithmetic test can see, because the document is right
    /// either way.
    func testACommitEndsTheCompositionSoNoStaleUnderlineIsLeft() {
        let host = TerminalInputHostView(frame: .zero)
        let probe = SeamProbe()
        host.surface = probe

        host.setMarkedText("にほんご", selectedRange: NSRange(location: 4, length: 0))
        host.insertText("日本語")
        XCTAssertEqual(probe.composed.last?.text, "", "the preedit was withdrawn from the pixels")
        XCTAssertNil(host.markedTextRange, "and from this side of the seam")
    }

    /// A composition belongs to the responder that STARTED it, so it goes down with the keyboard.
    ///
    /// A resignation leaves no keystroke and no frame behind it, so nothing would repaint an abandoned
    /// run away — it would sit underlined over a line the input method has already forgotten.
    func testResigningTheKeyboardTakesTheCompositionWithIt() {
        let host = TerminalInputHostView(frame: .zero)
        let probe = SeamProbe()
        host.surface = probe

        host.setMarkedText("にほ", selectedRange: NSRange(location: 2, length: 0))
        host.resignFirstResponder()
        XCTAssertEqual(probe.composed.last?.text, "")
        XCTAssertNil(host.markedTextRange)
    }

    /// The caret is CONVERTED out of the view that owns it.
    ///
    /// The rect the seam answers is in the band's coordinates or the grid's, and UIKit reads
    /// `caretRect(for:)` in the text input view's. A conformance that returned the rect unconverted
    /// would place a candidate window a band's height off — right where it looks deliberate.
    func testTheCaretIsConvertedOutOfTheViewThatOwnsIt() {
        let host = TerminalInputHostView(frame: CGRect(x: 0, y: 0, width: 300, height: 400))
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 300, height: 400))
        let owner = UIView(frame: CGRect(x: 20, y: 360, width: 280, height: 40))
        container.addSubview(host)
        container.addSubview(owner)

        let probe = SeamProbe()
        probe.anchor = (owner, CGRect(x: 8, y: 6, width: 2, height: 17))
        host.surface = probe

        XCTAssertEqual(
            host.caretRect(for: TerminalTextPosition(0)),
            CGRect(x: 28, y: 366, width: 2, height: 17),
            "the band's own origin has to be added, or the bar points into the grid",
        )
    }

    /// No caret to point at is answered as `.zero`, which is UIKit's own "place it yourself".
    func testNoCaretIsAnsweredAsZeroRatherThanAGuess() {
        let host = TerminalInputHostView(frame: .zero)
        let probe = SeamProbe()
        host.surface = probe
        XCTAssertEqual(host.caretRect(for: TerminalTextPosition(0)), .zero)
    }
}

// MARK: - The probe

/// A renderer that only records. Answers the three members ``TerminalSurfaceHosting`` has no default
/// for; every other one is the seam's own default, which is the point — a host with no pixels.
@MainActor
private final class SeamProbe: UIView, TerminalSurfaceHosting {
    /// Every composition this host was handed, in order.
    var composed: [(text: String, selection: NSRange)] = []
    /// What ``caretAnchor`` answers, set by the test.
    var anchor: (view: PlatformView, rect: CGRect)?

    var surfaceView: PlatformView { self }
    var caretAnchor: (view: PlatformView, rect: CGRect)? { anchor }

    func setComposition(_ text: String, selection: NSRange) {
        composed.append((text, selection))
    }

    func setPaneFocused(_: Bool) {}
    func detachSurface() {}
}
