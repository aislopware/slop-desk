// ClipboardConfirmPresentationTests — the three clipboard questions, and the mailbox that carries them
// to a renderer that cannot be called.
//
// The gap these pin is a PARITY gap rather than a crash: the phone's half of the libghostty embedder used
// to auto-approve an unsafe paste and an OSC-52 clipboard READ, and to drop an OSC-52 WRITE it had been
// told to ask about — so the same Settings ▸ Controls row meant Ask on a Mac, Allow on a phone (read) and
// Deny on a phone (write). Nothing was red; the setting was simply inert on one of the two halves.
//
// Two things are pinned. The SHAPE both renderers read — bullets or the ask's reason, never both, and the
// preview only where there is one — because that branch is the whole of what a second renderer would
// otherwise decide again slightly differently. And the mailbox's two disciplines, which are memory-safety
// rather than taste: a libghostty clipboard request is completed EXACTLY ONCE, and a question is never
// dropped to make room for a newer one.

import XCTest
@testable import SlopDeskClientCore
@testable import SlopDeskWorkspaceCore

final class ClipboardConfirmPresentationTests: XCTestCase {
    // MARK: - The shape both renderers read

    func testAnUnsafePasteListsItsDangersAndPrintsNoReason() {
        let reading = ClipboardConfirmPresentation.reading(
            ask: .unsafePaste,
            preview: "sudo rm -rf /\n",
            dangers: [.trailingNewline, .sudoOrSu],
        )
        XCTAssertEqual(reading.ask, .unsafePaste)
        XCTAssertEqual(reading.dangers.count, 2, "one line per flagged bit, in the mask's own order")
        XCTAssertTrue(
            reading.reason.isEmpty,
            "a reason and a danger list are alternatives — a renderer must never draw both",
        )
        XCTAssertFalse(reading.title.isEmpty)
        XCTAssertFalse(reading.affirmative.isEmpty)
    }

    func testAnOSC52AskCarriesItsReasonBecauseItHasNoPayloadToClassify() {
        for ask in [PasteSafetyAnalyzer.Ask.clipboardRead, .clipboardWrite] {
            let reading = ClipboardConfirmPresentation.reading(ask: ask, preview: "hello", dangers: [])
            XCTAssertTrue(reading.dangers.isEmpty, "an OSC-52 ask classifies nothing")
            XCTAssertFalse(
                reading.reason.isEmpty,
                "the REQUEST is the reason here — without it the card's body would be empty",
            )
        }
    }

    func testTheWordsAreThePasteCratesAndNotThisTypesOwn() {
        let reading = ClipboardConfirmPresentation.reading(ask: .clipboardRead, preview: "", dangers: [])
        XCTAssertEqual(reading.title, PasteSafetyAnalyzer.Ask.clipboardRead.title)
        XCTAssertEqual(reading.affirmative, PasteSafetyAnalyzer.Ask.clipboardRead.affirmative)
        XCTAssertEqual(reading.reason, PasteSafetyAnalyzer.Ask.clipboardRead.reason)
    }

    func testThePreviewIsTheDefusedPayloadNotTheRawOne() {
        let reading = ClipboardConfirmPresentation.reading(
            ask: .unsafePaste,
            preview: "a\u{1B}[31mb",
            dangers: [.controlChars],
        )
        XCTAssertFalse(
            reading.preview.contains("\u{1B}"),
            "the escape being warned about must not run inside the warning",
        )
    }

    // MARK: - The one-string join, for the renderer whose dialog takes one

    func testTheJoinBulletsTheDangersAndCaptionsThePreview() {
        let reading = ClipboardConfirmPresentation(
            ask: .unsafePaste,
            title: "Paste this?",
            affirmative: "Paste",
            dangers: ["First danger", "Second danger"],
            reason: "",
            preview: "echo hi",
        )
        XCTAssertEqual(
            reading.informativeText,
            """
            \(ClipboardConfirmPresentation.bullet)  First danger
            \(ClipboardConfirmPresentation.bullet)  Second danger

            \(ClipboardConfirmPresentation.previewCaption):
            echo hi
            """,
        )
    }

    func testTheJoinFallsBackToTheReasonAndOmitsAnAbsentPreview() {
        let reading = ClipboardConfirmPresentation(
            ask: .clipboardRead,
            title: "Allow?",
            affirmative: "Allow",
            dangers: [],
            reason: "A program asked to read the clipboard.",
            preview: "",
        )
        XCTAssertEqual(reading.informativeText, "A program asked to read the clipboard.")
    }

    // MARK: - The mailbox

    @MainActor
    func testTheOldestQuestionIsTheOneOnScreenAndANewerOneWaits() throws {
        let mailbox = ClipboardConfirmRequests()
        var answered: [String] = []
        mailbox.ask(Self.stub("first")) { _ in answered.append("first") }
        mailbox.ask(Self.stub("second")) { _ in answered.append("second") }

        XCTAssertEqual(mailbox.pending.count, 2, "a second ask QUEUES — replacing would decide the first")
        XCTAssertEqual(mailbox.current?.reading.title, "first")

        try mailbox.answer(XCTUnwrap(mailbox.current).id, allow: true)
        XCTAssertEqual(answered, ["first"])
        XCTAssertEqual(mailbox.current?.reading.title, "second", "the next question arrives, none is lost")
    }

    @MainActor
    func testAnsweringTwiceCompletesTheRequestOnlyOnce() throws {
        let mailbox = ClipboardConfirmRequests()
        var completions = 0
        mailbox.ask(Self.stub("only")) { _ in completions += 1 }
        let id = try XCTUnwrap(mailbox.current).id

        mailbox.answer(id, allow: true)
        mailbox.answer(id, allow: false)

        XCTAssertEqual(
            completions, 1,
            "libghostty holds state per request — a second completion is against freed state",
        )
        XCTAssertEqual(mailbox.pending.count, 0)
    }

    @MainActor
    func testTheVerdictIsCarriedThroughUnchanged() throws {
        let mailbox = ClipboardConfirmRequests()
        var verdict: Bool?
        mailbox.ask(Self.stub("deny me")) { verdict = $0 }
        try mailbox.answer(XCTUnwrap(mailbox.current).id, allow: false)
        XCTAssertFalse(try XCTUnwrap(verdict))
    }

    private static func stub(_ title: String) -> ClipboardConfirmPresentation {
        ClipboardConfirmPresentation(
            ask: .clipboardWrite,
            title: title,
            affirmative: "Allow",
            dangers: [],
            reason: "reason",
            preview: "",
        )
    }
}
