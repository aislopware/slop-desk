import XCTest
@testable import AislopdeskClientUI

/// Pins ``KeystrokeReplay`` (clipboard text → US-QWERTY key strokes) and ``RemoteWindowModel``'s
/// paste-as-keystrokes sequencing:
///
/// - lower/upper letters share a key with Shift carrying case; digits, punctuation and their shifted
///   symbols map to the right key + Shift; whitespace maps to space/tab/return.
/// - unmappable characters (accents, emoji, other scripts) are SKIPPED and counted, never mis-typed.
/// - the payload is capped at ``KeystrokeReplay/maxLength`` (overflow counts as skipped).
/// - `pasteAsKeystrokes` emits a balanced down/up per stroke through the live sink, in order, with
///   Shift folded into both edges, and is a no-op when no sink is wired.
@MainActor
final class KeystrokeReplayTests: XCTestCase {
    // MARK: - Encoding

    func testLowerAndUpperLettersShareKeyWithShift() {
        let lower = KeystrokeReplay.encode("a")
        XCTAssertEqual(lower.strokes, [ReplayStroke(keyCode: 0, shift: false)])
        let upper = KeystrokeReplay.encode("A")
        XCTAssertEqual(upper.strokes, [ReplayStroke(keyCode: 0, shift: true)])
        // Different letters, distinct keys.
        XCTAssertEqual(KeystrokeReplay.encode("z").strokes, [ReplayStroke(keyCode: 6, shift: false)])
    }

    func testDigitsAndShiftedSymbols() {
        XCTAssertEqual(KeystrokeReplay.encode("1").strokes, [ReplayStroke(keyCode: 18, shift: false)])
        XCTAssertEqual(
            KeystrokeReplay.encode("!").strokes,
            [ReplayStroke(keyCode: 18, shift: true)],
            "! is Shift+1 — same key",
        )
        XCTAssertEqual(KeystrokeReplay.encode("0").strokes, [ReplayStroke(keyCode: 29, shift: false)])
        XCTAssertEqual(KeystrokeReplay.encode(")").strokes, [ReplayStroke(keyCode: 29, shift: true)])
    }

    func testCRLFLineEndingsTypeAsReturnNotSkipped() {
        // Swift segments "\r\n" as ONE grapheme with no US-QWERTY mapping, so without CRLF normalization a
        // Windows/web/Git clipboard newline would silently fall through to `skipped` (no Return sent),
        // collapsing multi-line text onto one line. Normalization turns each CRLF into a single Return.
        let crlf = KeystrokeReplay.encode("ab\r\ncd")
        XCTAssertEqual(crlf.strokes, [
            ReplayStroke(keyCode: 0, shift: false), // a
            ReplayStroke(keyCode: 11, shift: false), // b
            ReplayStroke(keyCode: 36, shift: false), // Return (from \r\n)
            ReplayStroke(keyCode: 8, shift: false), // c
            ReplayStroke(keyCode: 2, shift: false), // d
        ])
        XCTAssertEqual(crlf.skipped, 0, "the CRLF newline is typed as Return, not dropped")
        // A bare LF and a bare CR each still map to Return (unchanged).
        XCTAssertEqual(KeystrokeReplay.encode("a\nb").strokes.count, 3)
        XCTAssertEqual(KeystrokeReplay.encode("a\rb").strokes.count, 3)
    }

    func testPunctuationAndWhitespace() {
        XCTAssertEqual(KeystrokeReplay.encode("-").strokes, [ReplayStroke(keyCode: 27, shift: false)])
        XCTAssertEqual(KeystrokeReplay.encode("_").strokes, [ReplayStroke(keyCode: 27, shift: true)])
        XCTAssertEqual(KeystrokeReplay.encode("/").strokes, [ReplayStroke(keyCode: 44, shift: false)])
        XCTAssertEqual(KeystrokeReplay.encode("?").strokes, [ReplayStroke(keyCode: 44, shift: true)])
        XCTAssertEqual(KeystrokeReplay.encode(" ").strokes, [ReplayStroke(keyCode: 49, shift: false)])
        XCTAssertEqual(KeystrokeReplay.encode("\t").strokes, [ReplayStroke(keyCode: 48, shift: false)])
        XCTAssertEqual(KeystrokeReplay.encode("\n").strokes, [ReplayStroke(keyCode: 36, shift: false)])
    }

    func testRealisticPasswordEncodesFully() {
        // A typical password — every character must map (no skips), in order.
        let encoded = KeystrokeReplay.encode("Tr0ub4dor&3")
        XCTAssertEqual(encoded.skipped, 0)
        XCTAssertEqual(encoded.strokes.count, 11)
        XCTAssertEqual(encoded.strokes.first, ReplayStroke(keyCode: 17, shift: true)) // 'T'
        XCTAssertEqual(encoded.strokes.last, ReplayStroke(keyCode: 20, shift: false)) // '3'
    }

    func testUnmappableCharactersAreSkippedNotMistyped() {
        let encoded = KeystrokeReplay.encode("aé😀b")
        XCTAssertEqual(encoded.skipped, 2, "é and 😀 have no US-QWERTY key")
        XCTAssertEqual(encoded.strokes, [
            ReplayStroke(keyCode: 0, shift: false), // a
            ReplayStroke(keyCode: 11, shift: false), // b
        ])
    }

    func testPayloadCapCountsOverflowAsSkipped() {
        let big = String(repeating: "a", count: KeystrokeReplay.maxLength + 17)
        let encoded = KeystrokeReplay.encode(big)
        XCTAssertEqual(encoded.strokes.count, KeystrokeReplay.maxLength)
        XCTAssertEqual(encoded.skipped, 17)
    }

    func testEmptyStringEncodesToNothing() {
        let encoded = KeystrokeReplay.encode("")
        XCTAssertTrue(encoded.strokes.isEmpty)
        XCTAssertEqual(encoded.skipped, 0)
    }

    // MARK: - RemoteWindowModel paste sequencing

    func testPasteEmitsBalancedDownUpPerStrokeInOrder() async {
        let model = RemoteWindowModel(pasteInterval: .zero)
        // Drive `active` by picking + opening a window so canPasteKeystrokes can be true.
        model.pick(RemoteWindowSummary(windowID: 1, appName: "Term", title: "t", width: 10, height: 10))
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
        model.pick(RemoteWindowSummary(windowID: 1, appName: "Term", title: "t", width: 10, height: 10))
        model.open()
        XCTAssertFalse(model.canPasteKeystrokes, "no injector wired → cannot paste")
        let encoded = model.pasteAsKeystrokes("abc") // must not trap
        XCTAssertEqual(encoded.strokes.count, 3, "still reports what WOULD be typed")
    }

    func testCanPasteRequiresStreamingAndSink() {
        let model = RemoteWindowModel(pasteInterval: .zero)
        model.keyInjector = { _, _, _ in }
        XCTAssertFalse(model.canPasteKeystrokes, "a sink but no active stream → cannot paste")
        model.pick(RemoteWindowSummary(windowID: 1, appName: "Term", title: "t", width: 10, height: 10))
        model.open()
        XCTAssertTrue(model.canPasteKeystrokes)
    }

    // MARK: - "typed N, skipped M" feedback (dropped characters never silent)

    private func streamingModel() -> RemoteWindowModel {
        let model = RemoteWindowModel(pasteInterval: .zero)
        model.pick(RemoteWindowSummary(windowID: 1, appName: "Term", title: "t", width: 10, height: 10))
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
        model.pick(RemoteWindowSummary(windowID: 1, appName: "Term", title: "t", width: 10, height: 10))
        model.open()
        _ = model.pasteAsKeystrokes("aé😀b")
        XCTAssertNil(model.pasteFeedback)
    }
}
