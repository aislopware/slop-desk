import XCTest
@testable import SlopDeskWorkspaceCore

/// Pins the CROSSING behind the clipboard-write "Ask" gate: the payload reaches the door as bytes, and the
/// three case indexes come back as the three cases the callback switches on. The rule — and why a callback
/// that ignored `confirm` would make "Ask" behave as "Allow" — is
/// `slopdesk_terminal::surface::clipboard_write`'s, and is tested there.
final class ClipboardWritePolicyTests: XCTestCase {
    /// All three answers, each distinguishable from the others: an Ask gate must never come back as
    /// ``ClipboardWriteDecision/write``, and an empty payload must never come back as a question.
    func testEachCaseIndexDecodesToItsOwnDecision() {
        XCTAssertEqual(ClipboardWritePolicy.decide(confirmRequested: true, text: "secret"), .confirm)
        XCTAssertEqual(ClipboardWritePolicy.decide(confirmRequested: false, text: "secret"), .write)
        XCTAssertEqual(ClipboardWritePolicy.decide(confirmRequested: true, text: ""), .drop)
    }

    /// The payload crosses as UTF-8 bytes, so a multi-byte one is still a payload — an emptiness test that
    /// looked at the byte count of something mis-encoded would drop this write.
    func testANonASCIIPayloadIsNotMistakenForAnEmptyOne() {
        XCTAssertEqual(ClipboardWritePolicy.decide(confirmRequested: false, text: "việt 🇻🇳"), .write)
    }
}
