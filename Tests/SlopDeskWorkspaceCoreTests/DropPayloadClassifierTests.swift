import XCTest
@testable import SlopDeskWorkspaceCore

/// The SEAM under ``DropPayloadClassifier`` — the arena, the records that name spans into it, and
/// the four content codes coming back as four cases.
///
/// What a pasteboard classifies TO is `slopdesk_workspace::drop_payload`'s and is asserted there:
/// the file → url → text precedence, the blank gate, the folder/file split, and the empty-drag
/// refusal (`docs/67` §3). Restating them here would be the second implementation moving the rules
/// was meant to end. What no crate test can reach is the marshalling — several Swift strings lent
/// as one contiguous buffer, and a length that is bytes rather than characters — so that is all
/// this asks about, once per shape the arena can take.
final class DropPayloadClassifierTests: XCTestCase {
    private typealias File = DropPayloadClassifier.FileEntry
    private typealias Payload = DropPayloadClassifier.Payload

    /// Every code the door can answer with maps back onto its own case. A drifted arm here would
    /// silently turn a dropped folder into a pasted string.
    func testEachContentCodeCrossesBackAsItsOwnCase() {
        XCTAssertEqual(
            DropPayloadClassifier.classify(Payload(files: [File(path: "/proj", isDirectory: true)])),
            .folder("/proj"),
        )
        XCTAssertEqual(
            DropPayloadClassifier.classify(Payload(files: [File(path: "/proj/a.md", isDirectory: false)])),
            .file("/proj/a.md"),
        )
        XCTAssertEqual(
            DropPayloadClassifier.classify(Payload(urls: ["https://example.com/path"])),
            .url("https://example.com/path"),
        )
        XCTAssertEqual(DropPayloadClassifier.classify(Payload(text: "echo hello")), .text("echo hello"))
    }

    /// The arena is one buffer holding every run, so a payload with items in all three groups is the
    /// case where a mis-computed span would surface — as a neighbour's bytes, not as a crash.
    func testAFullPasteboardLendsEveryRunFromOneBuffer() {
        let payload = Payload(
            files: [
                File(path: "   ", isDirectory: true),
                File(path: "/real/dir", isDirectory: true),
                File(path: "/never/reached", isDirectory: false),
            ],
            urls: ["https://decoy.example", "https://second.example"],
            text: "/real/dir",
        )
        XCTAssertEqual(DropPayloadClassifier.classify(payload), .folder("/real/dir"))
    }

    /// A length in BYTES, not characters: a path with multi-byte scalars in it is the one input that
    /// tells a `count` mistake from a correct one.
    func testANonASCIIPathCrossesWholeAndUnmangled() {
        let path = "/Users/tôi/dự án/README—final.md"
        XCTAssertEqual(
            DropPayloadClassifier.classify(Payload(files: [File(path: path, isDirectory: false)])),
            .file(path),
        )
        XCTAssertEqual(DropPayloadClassifier.classify(Payload(text: "echo 'xin chào' 🌈")), .text("echo 'xin chào' 🌈"))
    }

    /// The presence flag, read from the near side: a refusal is `nil` rather than a case carrying an
    /// empty string, and an empty group is not a null pointer the door may not dereference.
    func testARefusalIsNilRatherThanAnEmptyCase() {
        XCTAssertNil(DropPayloadClassifier.classify(Payload()))
        XCTAssertNil(DropPayloadClassifier.classify(Payload(files: [File(path: "", isDirectory: false)])))
        XCTAssertNil(DropPayloadClassifier.classify(Payload(urls: ["  "], text: " \n\t ")))
    }

    /// `text: nil` and `text: ""` reach the door as different facts — the flag, not the length —
    /// and neither may be read as a classified empty snippet.
    func testAnAbsentTextAndAnEmptyOneAreBothNoAnswer() {
        XCTAssertNil(DropPayloadClassifier.classify(Payload(text: nil)))
        XCTAssertNil(DropPayloadClassifier.classify(Payload(text: "")))
    }
}
