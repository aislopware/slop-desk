import XCTest
@testable import SlopDeskWorkspaceCore

/// C7 — the PURE model behind the remote-GUI pane's clipboard affordances ("Paste as Keystrokes" + the
/// "Clipboard Ring" submenu). Pins enablement, ring listing, and the classifier-aware MASKING so a secret
/// preview never renders. No view / pasteboard / session — headless.
final class ClipboardPasteMenuTests: XCTestCase {
    // MARK: preview — masking

    /// A credential-shaped clip is MASKED: the label carries only the length, never the secret bytes.
    func testPreviewMasksASecretClipAndNeverEchoesIt() {
        // Assemble at runtime (never a contiguous secret literal): a high-entropy mixed-class token the
        // SecretPasteClassifier flags as a credential.
        let secret = "aB3xK9mZ" + "2qP7wL5n" + "R8tY4vC1"
        let (label, isSecret) = ClipboardPasteMenu.preview(secret)
        XCTAssertTrue(isSecret, "a high-entropy credential-shaped clip is classified secret")
        XCTAssertTrue(label.hasPrefix("••••"), "the preview is masked")
        XCTAssertFalse(label.contains(secret), "the raw secret is NEVER echoed into the label")
        XCTAssertTrue(label.contains("\(secret.count)"), "the mask states the length so the user has a cue")
    }

    // MARK: preview — plain text

    /// Short, non-secret text passes through verbatim (not secret).
    func testPreviewPassesShortPlainTextThrough() {
        let (label, isSecret) = ClipboardPasteMenu.preview("hello world")
        XCTAssertFalse(isSecret)
        XCTAssertEqual(label, "hello world")
    }

    /// A multi-line clip collapses its newlines to single spaces so the menu row is one line.
    func testPreviewCollapsesNewlinesToOneLine() {
        let (label, isSecret) = ClipboardPasteMenu.preview("line one\nline two\n\tindented")
        XCTAssertFalse(isSecret)
        XCTAssertEqual(label, "line one line two indented")
        XCTAssertFalse(label.contains("\n"), "no raw newline survives into the label")
    }

    /// A long clip is ellipsized at the preview limit.
    func testPreviewTruncatesLongText() {
        let long = String(repeating: "x", count: ClipboardPasteMenu.previewLimit + 40)
        let (label, isSecret) = ClipboardPasteMenu.preview(long)
        XCTAssertFalse(isSecret)
        XCTAssertTrue(label.hasSuffix("…"), "over-limit text is ellipsized")
        XCTAssertEqual(label.count, ClipboardPasteMenu.previewLimit + 1, "limit chars + the ellipsis")
    }

    // MARK: rows

    /// `rows` lists most-recent-first, caps at `limit`, and indexes each row by ring position.
    func testRowsRespectLimitAndCarryIndexAndFullText() {
        let ring = (0..<20).map { "clip-\($0)" }
        let rows = ClipboardPasteMenu.rows(ring, limit: 5)
        XCTAssertEqual(rows.count, 5, "capped at the limit")
        XCTAssertEqual(rows.map(\.index), [0, 1, 2, 3, 4], "indexed by ring position (0 = most recent)")
        XCTAssertEqual(rows.first?.text, "clip-0", "row 0 is the most recent clip, full text preserved")
        XCTAssertEqual(rows.first?.label, "clip-0", "a plain short clip previews verbatim")
    }

    /// An empty ring yields no rows (the view then shows a disabled "No recent clips").
    func testRowsEmptyRingYieldsNoRows() {
        XCTAssertTrue(ClipboardPasteMenu.rows([]).isEmpty)
    }

    // MARK: canPaste enablement

    // ⚠️ `canPaste` takes a `Bool`, never the clipboard's TEXT, and the signature is the point. Enablement
    // is evaluated at RENDER time on the phone, and reading `UIPasteboard` content from a SwiftUI `body`
    // raises iOS's modal "Allow Paste?" alert — which is exactly what a `String?`-shaped enablement
    // predicate invited, and what shipped (increment 78). The two ways to obtain that `Bool` are
    // `isPastable(_:)` for a caller that already holds the content because it is about to paste (the Mac's
    // menu, rebuilt at OPEN) and `WorkspaceStore.localClipboardHasText()` for one that must decide without
    // reading (the phone's plate). There is deliberately no third.

    func testCanPasteRequiresBothALiveSinkAndNonEmptyClipboard() {
        XCTAssertTrue(ClipboardPasteMenu.canPaste(canPasteKeystrokes: true, clipboardHasText: true))
        XCTAssertFalse(
            ClipboardPasteMenu.canPaste(canPasteKeystrokes: false, clipboardHasText: true),
            "no live key sink (not streaming / read-only) ⇒ disabled",
        )
        XCTAssertFalse(
            ClipboardPasteMenu.canPaste(canPasteKeystrokes: true, clipboardHasText: false),
            "nothing on the clipboard ⇒ disabled",
        )
    }

    /// The content-in-hand reduction the Mac's open-time menu feeds `canPaste` with, and the guard the
    /// tap runs on both halves.
    func testIsPastableRejectsMissingAndWhitespaceOnlyClips() {
        XCTAssertTrue(ClipboardPasteMenu.isPastable("hi"))
        XCTAssertFalse(ClipboardPasteMenu.isPastable(nil), "no clipboard ⇒ nothing to type")
        XCTAssertFalse(ClipboardPasteMenu.isPastable(""), "an empty clipboard ⇒ nothing to type")
        XCTAssertFalse(ClipboardPasteMenu.isPastable("   \n\t "), "whitespace only ⇒ nothing to type")
    }
}
