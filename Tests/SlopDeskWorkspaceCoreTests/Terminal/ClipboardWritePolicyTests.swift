import XCTest
@testable import SlopDeskWorkspaceCore

/// E8 WI-2 (I11): the clipboard-write "Ask" gate decision engine. libghostty enforces `deny` / `allow`
/// itself and DELEGATES `ask` to the embedder via `write_clipboard_cb`'s `confirm` flag; the old callback
/// ignored that flag and wrote unconditionally, so "Ask" silently behaved like "Allow". These pin the pure
/// decision the callback now consults — confirm honored, empty payload dropped.
final class ClipboardWritePolicyTests: XCTestCase {
    /// `clipboard-write = ask` (libghostty `confirm == true`) on a real payload ⇒ require confirmation.
    func testConfirmRequestedWithTextAsksForConfirmation() {
        XCTAssertEqual(
            ClipboardWritePolicy.decide(confirmRequested: true, text: "secret"),
            .confirm,
            "an Ask gate must NOT silently write — it routes to the confirmation sheet",
        )
    }

    /// `clipboard-write = allow` (libghostty `confirm == false`) on a real payload ⇒ write directly.
    func testNoConfirmWithTextWritesDirectly() {
        XCTAssertEqual(
            ClipboardWritePolicy.decide(confirmRequested: false, text: "hello"),
            .write,
        )
    }

    /// An empty payload is a no-op whether or not confirmation was requested (validate-then-drop) — there
    /// is nothing to write and nothing to ask about.
    func testEmptyPayloadDrops() {
        XCTAssertEqual(ClipboardWritePolicy.decide(confirmRequested: true, text: ""), .drop)
        XCTAssertEqual(ClipboardWritePolicy.decide(confirmRequested: false, text: ""), .drop)
    }
}
