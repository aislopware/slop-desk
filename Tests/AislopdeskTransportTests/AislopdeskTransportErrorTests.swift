import XCTest
@testable import AislopdeskTransport

/// Pins the `LocalizedError` conformance added so the UI failure surface shows a human line instead of
/// a raw enum dump (`timedOut("host handshake")`). `error.localizedDescription` must resolve to the
/// clean `errorDescription`, and the per-case detail string must NOT leak into the user-facing text.
final class AislopdeskTransportErrorTests: XCTestCase {
    func testErrorDescriptionIsCleanAndOmitsDetailPayload() {
        // (error, expected user-facing line, a UNIQUE token from the detail payload that must NOT leak)
        let cases: [(AislopdeskTransportError, String, String)] = [
            (
                .timedOut("connect to 10.0.0.1:7777 exceeded 10s"),
                "Connection timed out — host unreachable?",
                "10.0.0.1",
            ),
            (.handshakeFailed("bad preamble"), "Handshake failed — is this an aislopdesk host?", "preamble"),
            (.connectionFailed("posix err 61"), "Connection failed", "posix"),
            (.receiveFailed("ECONNRESET"), "Connection lost", "ECONNRESET"),
            (.listenerFailed("EADDRINUSE"), "Could not start the listener (port in use?)", "EADDRINUSE"),
            (.notConnected("cancelled-token"), "Not connected", "cancelled-token"),
            (.sendFailed("EPIPE"), "Failed to send data", "EPIPE"),
            (.invalidState("openChannel on host"), "Connection is in an invalid state", "openChannel"),
        ]
        for (error, expected, payloadToken) in cases {
            XCTAssertEqual(error.errorDescription, expected)
            // `localizedDescription` routes through `errorDescription` for a LocalizedError, so the UI
            // (which uses `error.localizedDescription`) shows the clean line, not the enum case syntax.
            XCTAssertEqual(error.localizedDescription, expected)
            XCTAssertFalse(
                error.localizedDescription.contains(payloadToken),
                "the developer detail payload (\(payloadToken)) must not leak into the user-facing message",
            )
        }
    }
}
