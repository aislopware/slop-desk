// ToastPresentationTests — pins what a notification card SAYS, below both platforms.
//
// These pins used to live in `ToastStackViewTests`, on a SwiftUI view. They are here now because the
// rules they pin are no longer a view's: the Mac's corner is an `NSPanel` and the phone's a SwiftUI
// column (docs/56 stage D), and every one of these answers has to be the same in both. The two
// halves keep only their own layout and their own view of the ink ladder, and those are pinned where
// they are drawn.
//
// The headline itself is `slopdesk_ws_notify_toast_headline`; what these tests prove is that the
// Swift marshalling reaches it with the right two case bytes, which is the half of the contract Rust
// cannot check.

import XCTest
@testable import SlopDeskClientCore

@MainActor
final class ToastPresentationTests: XCTestCase {
    private func headline(
        _ source: Toast.Source, _ flavor: Toast.Flavor, _ title: String = "t",
    ) -> String {
        ToastPresentation.headline(for: Toast(id: "x", flavor: flavor, source: source, title: title))
    }

    // MARK: - Headline (WHO is speaking, said as a sentence-case phrase)

    /// The headline is resolved from ``Toast/source`` and ``Toast/flavor`` TOGETHER, and this pins why: a
    /// `.success` toast says "is done" when an agent finished its turn but "finished" when a command
    /// exited 0. Flavour alone cannot tell those apart, so a resolver that keyed on it would announce a
    /// finished `make` as an agent turn — the same fusion bug `TabBadgeResolver` had (round 21).
    func testHeadlineSplitsAgentFromCommand() {
        XCTAssertEqual(headline(.agent, .success, "Claude"), "Claude is done")
        XCTAssertEqual(headline(.command, .success, "make check"), "make check finished")
        XCTAssertNotEqual(
            headline(.agent, .success), headline(.command, .success),
            "an agent's finished turn and a command's clean exit must not read as the same event",
        )
        XCTAssertEqual(headline(.agent, .attention, "Claude"), "Claude needs input")
        XCTAssertEqual(headline(.agent, .error, "Claude"), "Claude failed")
        XCTAssertEqual(headline(.agent, .default, "Claude"), "Claude is working")
        XCTAssertEqual(headline(.command, .error, "make check"), "make check failed")
    }

    /// A notice/advisory speaks its own words — the title IS the message (an OSC 9 program line, a cwd
    /// advisory) — and prefixing an event verb onto someone else's sentence garbles it.
    func testACommandsOwnWordsPassThroughUntouched() {
        XCTAssertEqual(headline(.command, .default, "npm run dev"), "npm run dev")
        XCTAssertEqual(headline(.command, .attention, "cd'd on host"), "cd'd on host")
    }

    /// Every derived headline is a PHRASE, never the caps-mono register the old eyebrow spoke.
    func testEveryPairNamesAnEventInSentenceCase() {
        for source in [Toast.Source.agent, .command] {
            for flavor in [Toast.Flavor.default, .success, .error, .attention] {
                let label = headline(source, flavor, "subject")
                XCTAssertFalse(label.isEmpty, "every (source, flavour) pair must name an event")
                XCTAssertNotEqual(
                    label, label.uppercased(),
                    "\(label) must stay sentence-case — the caps register left the floating family",
                )
            }
        }
    }

    /// A toast may carry its OWN headline when it knows a truer phrase than the derivation can reach — the
    /// reconnect verdict is "Session reattached", which no flavour+title suffix encodes. An explicit
    /// headline must WIN over the derived one, and an empty one must fall back rather than render a blank.
    func testExplicitHeadlineOverridesTheDerivedOne() {
        let explicit = Toast(
            id: "x", flavor: .success, source: .command, title: "t", headline: "Session reattached",
        )
        XCTAssertEqual(ToastPresentation.headline(for: explicit), "Session reattached")
        let blank = Toast(id: "x", flavor: .success, source: .command, title: "t", headline: "")
        XCTAssertEqual(ToastPresentation.headline(for: blank), "t finished", "an empty headline falls back")
    }

    /// A pane that never set a title still has to read as a sentence rather than opening with a verb.
    func testANamelessSubjectFallsBackToASpeakerNoun() {
        XCTAssertEqual(headline(.agent, .success, "  "), "The agent is done")
        XCTAssertEqual(headline(.command, .error, ""), "The command failed")
        XCTAssertEqual(
            headline(.command, .default, "   "), "",
            "the one flavour with nothing of its own to say says nothing — no noun can be invented",
        )
    }

    // MARK: - Stack spine (which cards speak in full)

    /// Only the NEWEST `expandedCount` cards carry a detail line; older ones collapse to the one-line
    /// spine. Newest is LAST, so the expanded ones are at the END of the array.
    func testOnlyTheNewestCardsExpand() {
        XCTAssertTrue(ToastPresentation.isExpanded(index: 3, count: 4), "the newest card speaks in full")
        XCTAssertTrue(ToastPresentation.isExpanded(index: 2, count: 4), "so does the one before it")
        XCTAssertFalse(ToastPresentation.isExpanded(index: 1, count: 4), "older cards collapse to the spine")
        XCTAssertFalse(ToastPresentation.isExpanded(index: 0, count: 4), "the oldest most of all")
        // A stack shallower than the budget expands everything — no lone card is ever collapsed.
        XCTAssertTrue(ToastPresentation.isExpanded(index: 0, count: 1))
        XCTAssertTrue(ToastPresentation.isExpanded(index: 0, count: 2))
    }

    // MARK: - The mark

    /// All FOUR flavours must be pairwise distinct — in RUNG and in GLYPH. This is the real invariant
    /// behind a flavour (one that cannot be told apart from another conveys nothing) and it is the
    /// assertion the previous pin deliberately WITHHELD: `.attention` used to resolve to the theme
    /// accent, and every seed sets `info == accent`, so needs-input and a routine notice rendered in
    /// the same hue. Routing `.attention` to the status quartet's unused amber rung is what makes this
    /// hold — and pinning it HERE is what makes it hold on both platforms at once.
    func testEveryFlavorTakesItsOwnRungAndGlyph() {
        let flavors: [Toast.Flavor] = [.default, .success, .error, .attention]
        for (index, a) in flavors.enumerated() {
            for b in flavors.dropFirst(index + 1) {
                XCTAssertNotEqual(
                    ToastPresentation.mark(for: a).rung, ToastPresentation.mark(for: b).rung,
                    "\(a.rawValue) and \(b.rawValue) must read as different inks",
                )
                XCTAssertNotEqual(
                    ToastPresentation.mark(for: a).symbolName,
                    ToastPresentation.mark(for: b).symbolName,
                    "\(a.rawValue) and \(b.rawValue) must read as different glyphs",
                )
            }
        }
        XCTAssertEqual(ToastPresentation.mark(for: .attention).rung, .warn, "a question waiting is AMBER")
        XCTAssertEqual(
            ToastPresentation.mark(for: .default).rung, .neutral,
            "a routine notice carries no hue — cyan on every OSC line was chrome pretending to be signal",
        )
    }

    /// The glyphs are BARE — the disc each half draws under them is the enclosure, so an enclosed
    /// symbol here would nest one inside another.
    func testTheGlyphsAreUnenclosed() {
        for flavor in [Toast.Flavor.default, .success, .error, .attention] {
            XCTAssertFalse(
                ToastPresentation.mark(for: flavor).symbolName.contains("circle"),
                "the disc is the drawing half's; the glyph on it must not carry its own enclosure",
            )
        }
    }

    // MARK: - The dwell

    /// A sticky card has NO timer at all, which is also why its ✕ is unconditional on both platforms.
    func testAStickyCardHasNoDwell() {
        let sticky = Toast(id: "x", title: "t", autoDismiss: nil)
        XCTAssertEqual(ToastPresentation.dwellSeconds(sticky), 0)
        let timed = Toast(id: "x", title: "t", autoDismiss: .milliseconds(4500))
        XCTAssertEqual(ToastPresentation.dwellSeconds(timed), 4.5, accuracy: 0.001)
    }
}
