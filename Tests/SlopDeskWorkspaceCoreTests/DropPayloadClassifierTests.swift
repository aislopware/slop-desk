import XCTest
@testable import SlopDeskWorkspaceCore

/// Tests for ``DropPayloadClassifier`` (E18 WI-1) — the pure mapping of an inspected drag pasteboard
/// onto a single ``DroppedContent`` with file → url → text precedence and validate-then-drop on an
/// unsupported / empty drag. No AppKit, no disk: `isDirectory` is supplied by the caller.
final class DropPayloadClassifierTests: XCTestCase {
    private typealias File = DropPayloadClassifier.FileEntry
    private typealias Payload = DropPayloadClassifier.Payload

    // MARK: - Type routing

    func testDirectoryFileURLClassifiesAsFolder() {
        let payload = Payload(files: [File(path: "/Users/me/proj", isDirectory: true)])
        XCTAssertEqual(DropPayloadClassifier.classify(payload), .folder("/Users/me/proj"))
    }

    func testRegularFileURLClassifiesAsFile() {
        let payload = Payload(files: [File(path: "/Users/me/proj/README.md", isDirectory: false)])
        XCTAssertEqual(DropPayloadClassifier.classify(payload), .file("/Users/me/proj/README.md"))
    }

    func testWebURLClassifiesAsURL() {
        let payload = Payload(urls: ["https://example.com/path"])
        XCTAssertEqual(DropPayloadClassifier.classify(payload), .url("https://example.com/path"))
    }

    func testPlainTextClassifiesAsText() {
        let payload = Payload(text: "echo hello")
        XCTAssertEqual(DropPayloadClassifier.classify(payload), .text("echo hello"))
    }

    // MARK: - Precedence (file > url > text)

    func testFileBeatsURLandText() {
        // A Finder file drag also exposes a text/URL representation of its path; the file wins.
        let payload = Payload(
            files: [File(path: "/tmp/a.txt", isDirectory: false)],
            urls: ["https://decoy.example"],
            text: "/tmp/a.txt",
        )
        XCTAssertEqual(DropPayloadClassifier.classify(payload), .file("/tmp/a.txt"))
    }

    func testURLBeatsText() {
        let payload = Payload(urls: ["https://example.com"], text: "example.com")
        XCTAssertEqual(DropPayloadClassifier.classify(payload), .url("https://example.com"))
    }

    func testFirstNonEmptyFileWins() {
        let payload = Payload(files: [
            File(path: "   ", isDirectory: true), // blank → skipped
            File(path: "/real/dir", isDirectory: true),
        ])
        XCTAssertEqual(DropPayloadClassifier.classify(payload), .folder("/real/dir"))
    }

    // MARK: - Validate-then-drop (unsupported / empty → nil)

    func testEmptyPayloadIsNil() {
        // An unsupported UTType is simply absent → an all-empty payload classifies to nil, no crash.
        XCTAssertNil(DropPayloadClassifier.classify(Payload()))
    }

    func testWhitespaceOnlyTextIsNil() {
        XCTAssertNil(DropPayloadClassifier.classify(Payload(text: "  \n\t ")))
    }

    func testBlankPathFileIsNil() {
        XCTAssertNil(DropPayloadClassifier.classify(Payload(files: [File(path: "", isDirectory: false)])))
    }

    func testBlankURLFallsThroughToText() {
        // A blank URL is dropped; a real text item behind it still classifies.
        let payload = Payload(urls: ["   "], text: "fallback")
        XCTAssertEqual(DropPayloadClassifier.classify(payload), .text("fallback"))
    }
}
