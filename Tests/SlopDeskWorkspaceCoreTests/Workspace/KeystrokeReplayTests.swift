import XCTest
@testable import SlopDeskWorkspaceCore

/// Pins the CROSSING for ``KeystrokeReplay`` and ``RemoteWindowModel``'s paste-as-keystrokes sequencing.
///
/// The US-QWERTY table, the skip rule, the grapheme-cluster unit and the payload cap are
/// `slopdesk_workspace::keystroke_replay`'s, and asserted there — restating them here would be the
/// second implementation the port exists to delete. What is left is what only this side can be wrong
/// about:
///
/// - the door's `[skipped][count][records]` blob decodes back into ordered ``ReplayStroke``s, with the
///   key code read big-endian and Shift read as its own byte;
/// - ``KeystrokeReplay/maxLength`` agrees with the cap the door enforces, which is what makes the
///   arithmetic bound on the answer buffer safe;
/// - `pasteAsKeystrokes` emits a balanced down/up per stroke through the live sink, in order, with
///   Shift folded into both edges, and is a no-op when no sink is wired.
@MainActor
final class KeystrokeReplayTests: XCTestCase {
    // MARK: - The crossing

    /// One mixed payload through the door: order kept, Shift carried, and the unmappable clusters
    /// counted rather than typed as something else.
    func testTheDoorAnswersOrderedStrokesAndASkipCount() {
        let encoded = KeystrokeReplay.encode("Hi!\u{65}\u{301}\u{1f600}")
        XCTAssertEqual(encoded.strokes, [
            ReplayStroke(keyCode: 4, shift: true), // H — Shift+h
            ReplayStroke(keyCode: 34, shift: false), // i
            ReplayStroke(keyCode: 18, shift: true), // ! — Shift+1
        ])
        XCTAssertEqual(encoded.skipped, 2, "the decomposed é and the emoji crossed as skips")
    }

    /// The cap the Swift side sizes its buffer from is the one the door enforces. A drift here would
    /// not fail loudly — it would truncate a password.
    func testTheCapCrossesAsTheSameNumberBothSidesUse() {
        let big = String(repeating: "a", count: KeystrokeReplay.maxLength + 17)
        let encoded = KeystrokeReplay.encode(big)
        XCTAssertEqual(encoded.strokes.count, KeystrokeReplay.maxLength)
        XCTAssertEqual(encoded.skipped, 17)
    }

    /// An empty clipboard is a real answer (both counts zero), not the §4 refusal.
    func testEmptyStringCrossesAsNothingRatherThanAFailure() {
        let encoded = KeystrokeReplay.encode("")
        XCTAssertTrue(encoded.strokes.isEmpty)
        XCTAssertEqual(encoded.skipped, 0)
    }

    // MARK: - RemoteWindowModel paste sequencing

    func testPasteEmitsBalancedDownUpPerStrokeInOrder() async {
        let model = RemoteWindowModel(pasteInterval: .zero)
        // Drive `active` by dialing a window id + opening so canPasteKeystrokes can be true.
        model.windowID = "1"
        model.open()

        var events: [(UInt16, Bool, Bool)] = []
        model.keyInjector = { kc, down, shift in events.append((kc, down, shift)) }
        XCTAssertTrue(model.canPasteKeystrokes)

        let encoded = model.pasteAsKeystrokes("Hi!")
        XCTAssertEqual(encoded.skipped, 0)
        // Let the paced Task drain (interval is .zero, so a couple of yields suffice).
        for _ in 0..<10 { await Task.yield() }

        // H (Shift), i (no Shift), ! (Shift+1) — each a down then an up, Shift folded into both edges.
        XCTAssertEqual(events.count, 6)
        XCTAssertEqual(events[0].0, 4)
        XCTAssertEqual(events[0].1, true)
        XCTAssertEqual(events[0].2, true) // H down
        XCTAssertEqual(events[1].0, 4)
        XCTAssertEqual(events[1].1, false)
        XCTAssertEqual(events[1].2, true) // H up
        XCTAssertEqual(events[2].0, 34)
        XCTAssertEqual(events[2].2, false) // i, no shift
        XCTAssertEqual(events[4].0, 18)
        XCTAssertEqual(events[4].2, true) // ! → Shift+1
    }

    func testPasteIsNoopWithoutSink() {
        let model = RemoteWindowModel(pasteInterval: .zero)
        model.windowID = "1"
        model.open()
        XCTAssertFalse(model.canPasteKeystrokes, "no injector wired → cannot paste")
        let encoded = model.pasteAsKeystrokes("abc") // must not trap
        XCTAssertEqual(encoded.strokes.count, 3, "still reports what WOULD be typed")
    }

    func testCanPasteRequiresStreamingAndSink() {
        let model = RemoteWindowModel(pasteInterval: .zero)
        model.keyInjector = { _, _, _ in }
        XCTAssertFalse(model.canPasteKeystrokes, "a sink but no active stream → cannot paste")
        model.windowID = "1"
        model.open()
        XCTAssertTrue(model.canPasteKeystrokes)
    }

    // MARK: - "typed N, skipped M" feedback (dropped characters never silent)

    private func streamingModel() -> RemoteWindowModel {
        let model = RemoteWindowModel(pasteInterval: .zero)
        model.windowID = "1"
        model.open()
        model.keyInjector = { _, _, _ in }
        return model
    }

    func testPasteFeedbackSetWhenCharactersAreSkipped() {
        let model = streamingModel()
        XCTAssertNil(model.pasteFeedback)
        _ = model.pasteAsKeystrokes("aé😀b") // é + 😀 unmappable
        XCTAssertEqual(
            model.pasteFeedback,
            RemoteWindowModel.PasteFeedback(typed: 2, skipped: 2),
            "feedback names what was typed and what was dropped",
        )
    }

    func testNoPasteFeedbackWhenEverythingMaps() {
        let model = streamingModel()
        _ = model.pasteAsKeystrokes("Tr0ub4dor&3") // a clean password — no skips
        XCTAssertNil(model.pasteFeedback, "a clean paste shows no interruption")
    }

    func testCleanPasteClearsAStaleSkipBanner() {
        // A skipped paste shows the banner; a SUBSEQUENT clean paste must clear it (not leave it timing out).
        let model = streamingModel()
        _ = model.pasteAsKeystrokes("aé😀b")
        XCTAssertNotNil(model.pasteFeedback)
        _ = model.pasteAsKeystrokes("clean")
        XCTAssertNil(model.pasteFeedback, "the prior skip warning is cleared by a clean paste")
    }

    func testDismissPasteFeedbackClearsIt() {
        let model = streamingModel()
        _ = model.pasteAsKeystrokes("é") // all skipped
        XCTAssertNotNil(model.pasteFeedback)
        model.dismissPasteFeedback()
        XCTAssertNil(model.pasteFeedback)
    }

    func testNoFeedbackWithoutASink() {
        // Nothing is typed without an injector, so there is nothing to report.
        let model = RemoteWindowModel(pasteInterval: .zero)
        model.windowID = "1"
        model.open()
        _ = model.pasteAsKeystrokes("aé😀b")
        XCTAssertNil(model.pasteFeedback)
    }
}
