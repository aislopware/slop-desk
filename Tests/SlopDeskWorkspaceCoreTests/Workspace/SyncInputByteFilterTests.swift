import Foundation
import XCTest
@testable import SlopDeskWorkspaceCore

/// ``SyncInputByteFilter`` — the MARSHALLING, which is the only part of it that is Swift.
///
/// What the filter decides — which replies, reports and focus events are not keyboard bytes, and
/// where each sequence ends — is `slopdesk-sanitize`'s `syncinput`, and is tested there against the
/// scanner the replay passes share. Re-asserting that matrix here would be the cross-language mirror
/// fixture the one-implementation rule bans: two suites that can only ever agree, or be a bug.
///
/// What is left is real and lives nowhere else: the two-call size-then-fill retry, and the fact that
/// an empty answer is a legitimate one here rather than the "did not fit" signal it is for a door
/// whose caller expects output.
final class SyncInputByteFilterTests: XCTestCase {
    /// The round trip: reports out, typing through, byte-exact — the door is linked and the buffer
    /// the Swift side sized for the answer was the right one.
    func testTheDoorIsWiredAndTheAnswerIsCopiedWhole() {
        // A window report + an SGR scroll burst between two keystrokes: the field-observed shape.
        let garbage = "\u{1B}[8;33;96t\u{1B}[<65;31;18M"
        let filtered = SyncInputByteFilter.keyboardOnly(Data("cc\(garbage)\r".utf8))
        XCTAssertEqual(filtered, Data("cc\r".utf8))
    }

    /// A chunk that is ALL reports answers empty, and so does an empty chunk. Both take the
    /// `needed == 0` path, which must mean "nothing survived" and not "the call failed".
    func testAnEmptyAnswerIsAnAnswer() {
        XCTAssertEqual(SyncInputByteFilter.keyboardOnly(Data("\u{1B}[<65;31;18M".utf8)), Data())
        XCTAssertEqual(SyncInputByteFilter.keyboardOnly(Data()), Data())
    }

    /// Typing is returned byte-exact, so the identity path does not quietly re-encode a chunk that
    /// the mirror is about to type into another shell.
    func testKeystrokesComeBackByteExact() {
        let typed = Data("ls -la\r\u{1B}[A\u{1B}[200~echo hi\u{1B}[201~".utf8)
        XCTAssertEqual(SyncInputByteFilter.keyboardOnly(typed), typed)
    }
}
