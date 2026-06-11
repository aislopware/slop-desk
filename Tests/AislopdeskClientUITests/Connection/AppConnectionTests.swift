import XCTest
import AislopdeskTransport
@testable import AislopdeskClientUI

/// Unit tests for ``AppConnection`` — the app-global connection model (docs/31): form validation, the
/// committed target, and the connect/disconnect status transitions + deliberate-close guard. The pin
/// SUCCESS path is proven by `ConnectionRegistryTests` (the registry's `pin`/`unpin`/`isConnectionAlive`)
/// + HW; here a throwing `makeConnection` drives the FAILURE/transition logic deterministically with no
/// socket.
@MainActor
final class AppConnectionTests: XCTestCase {

    /// A registry whose `makeConnection` always throws — so `pin` fails immediately and `connect()` lands
    /// in `.failed` without any real network.
    private func failingRegistry() -> ConnectionRegistry {
        ConnectionRegistry { _, _ in throw AislopdeskTransportError.timedOut("test: connect refused") }
    }

    // MARK: - Form validation

    /// `validationHint == nil` exactly when `canConnect` is true, and otherwise names WHY Connect is
    /// disabled (moved here from the per-pane view-model — validation is app-global now).
    func testValidationHintMatchesCanConnect() {
        let c = AppConnection(registry: failingRegistry())

        c.host = ""; c.port = "7777"
        XCTAssertFalse(c.canConnect)
        XCTAssertEqual(c.validationHint, "Enter a host")

        c.host = "example.com"; c.port = "abc"
        XCTAssertFalse(c.canConnect)
        XCTAssertEqual(c.validationHint, "Port must be a number from 1–65535")

        c.host = "example.com"; c.port = "0"   // parseable UInt16 but not a connectable port
        XCTAssertFalse(c.canConnect)
        XCTAssertEqual(c.validationHint, "Port must be a number from 1–65535")

        c.host = "example.com"; c.port = "7420"; c.mediaPort = "9000"; c.cursorPort = "9000"
        XCTAssertFalse(c.canConnect, "media and cursor ports must differ")
        XCTAssertEqual(c.validationHint, "Media and cursor ports must differ")

        c.cursorPort = "9001"
        XCTAssertTrue(c.canConnect)
        XCTAssertNil(c.validationHint, "a valid form has no hint")
    }

    // MARK: - Lifecycle transitions

    /// A failed pin surfaces `.failed` AND commits the parsed target (so the gate prefills it + the panes
    /// read it) and fires `onTargetCommitted` (persistence hook).
    func testConnectFailureSurfacesFailedAndCommitsTarget() async {
        let c = AppConnection(registry: failingRegistry())
        var committed: ConnectionTarget?
        c.onTargetCommitted = { committed = $0 }
        c.host = "10.0.0.5"; c.port = "7420"; c.mediaPort = "9000"; c.cursorPort = "9001"

        await c.connect()

        guard case .failed = c.status else { return XCTFail("expected .failed, got \(c.status)") }
        XCTAssertEqual(c.target, ConnectionTarget(host: "10.0.0.5", port: 7420, mediaPort: 9000, cursorPort: 9001),
                       "the parsed target is committed even on a failed connect")
        XCTAssertEqual(committed, c.target, "onTargetCommitted fires with the committed target")
    }

    /// An invalid form short-circuits to `.failed("invalid host/port")` without touching the registry.
    func testConnectWithInvalidFormIsFailed() async {
        let c = AppConnection(registry: failingRegistry())
        c.host = ""   // invalid
        await c.connect()
        XCTAssertEqual(c.status, .failed("invalid host/port"))
    }

    /// `disconnect()` always lands `.disconnected` and marks the connection deliberately closed.
    func testDisconnectSurfacesDisconnected() async {
        let c = AppConnection(registry: failingRegistry())
        c.host = "h"; c.port = "7420"; c.mediaPort = "9000"; c.cursorPort = "9001"
        await c.connect()            // → .failed (throwing registry)
        await c.disconnect()
        XCTAssertEqual(c.status, .disconnected)
    }

    /// The seed target prefills the editable form fields (the connect-gate shows the last-used host).
    func testSeedPrefillsFormFields() {
        let seed = ConnectionTarget(host: "studio.local", port: 7421, mediaPort: 9100, cursorPort: 9101)
        let c = AppConnection(registry: failingRegistry(), seed: seed)
        XCTAssertEqual(c.host, "studio.local")
        XCTAssertEqual(c.port, "7421")
        XCTAssertEqual(c.mediaPort, "9100")
        XCTAssertEqual(c.cursorPort, "9101")
        XCTAssertEqual(c.target, seed)
    }
}
