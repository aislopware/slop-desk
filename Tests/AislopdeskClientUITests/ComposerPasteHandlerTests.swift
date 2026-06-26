// ComposerPasteHandlerTests (E12 / ES-E12-3) — the in-field `⌘V` / `⇧⌘V` paste pipeline, proven headlessly.
// The fix replaced the SwiftUI `TextField` with a hosted `ComposerTextView` whose `paste(_:)` override runs
// `ComposerPasteHandler` so `⌘V` actually converts (HTML/RTF→Markdown) and splices AT THE CARET, instead of
// the conversion being dead on macOS (the Edit ▸ Paste menu owns `⌘V` and preempts `.onKeyPress`). This pins
// that pipeline against `NSPasteboard.general` (no window, no responder, no VT/Metal — hang-safe).
//
// Revert-to-confirm-fail: change `ComposerPasteHandler.paste` to append (drop the `at: range`) and
// `testRichPasteConvertsAndLandsAtCaret` flips ("A**bold**C" → "AC**bold**"). Not a tautology — it asserts
// the converted bytes land between the existing characters, not at the end.

#if os(macOS)
import AislopdeskWorkspaceCore
import AppKit
import XCTest
@testable import AislopdeskClientUI

@MainActor
final class ComposerPasteHandlerTests: XCTestCase {
    /// `⌘V` converts the clipboard HTML to Markdown AND splices it at the caret (UTF-16 location 1, between
    /// "A" and "C"), with the model's caret advanced to just past the inserted Markdown.
    func testRichPasteConvertsAndLandsAtCaret() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString("<b>bold</b>", forType: .html)

        let composer = ComposerModel()
        composer.draft = "AC"

        let didPaste = ComposerPasteHandler.paste(rich: true, at: NSRange(location: 1, length: 0), into: composer)

        XCTAssertTrue(didPaste, "a non-empty pasteboard pastes")
        XCTAssertEqual(composer.draft, "A**bold**C", "⌘V converts HTML→Markdown and splices at the caret")
        XCTAssertEqual(
            composer.selection?.location,
            1 + "**bold**".utf16.count,
            "the caret advances to just past the inserted Markdown",
        )
    }

    /// `⇧⌘V` inserts the plain-text flavour VERBATIM (no HTML→Markdown conversion) at the caret.
    func testPlainPasteInsertsVerbatimAtCaret() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString("<b>x</b>", forType: .string)

        let composer = ComposerModel()
        composer.draft = "AC"

        _ = ComposerPasteHandler.paste(rich: false, at: NSRange(location: 1, length: 0), into: composer)

        XCTAssertEqual(composer.draft, "A<b>x</b>C", "⇧⌘V pastes plain text verbatim (no conversion) at the caret")
    }

    /// An empty pasteboard is a no-op that returns `false` (so the host can fall back to the system paste)
    /// and never touches the draft.
    func testEmptyPasteboardIsNoOpReturningFalse() {
        let pb = NSPasteboard.general
        pb.clearContents()

        let composer = ComposerModel()
        composer.draft = "keep"

        XCTAssertFalse(ComposerPasteHandler.paste(rich: true, at: nil, into: composer), "nothing to paste → false")
        XCTAssertEqual(composer.draft, "keep", "an empty paste leaves the draft untouched")
    }
}
#endif
