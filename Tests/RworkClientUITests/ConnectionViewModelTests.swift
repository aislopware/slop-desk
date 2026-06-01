import XCTest
import Foundation
import RworkClient
import RworkHost
@testable import RworkClientUI

/// Drives the `@MainActor @Observable` ``ConnectionViewModel`` against a REAL in-process
/// PATH 1 stack — a ``HostServer`` (RworkHost, `/bin/sh` in a PTY) + a ``RworkClient`` over a
/// 127.0.0.1 ephemeral port — so the connect → connected → live-output → disconnect state
/// transitions are exercised end-to-end (not against a mock). The same pattern as
/// `RworkClientTests`.
@MainActor
final class ConnectionViewModelTests: XCTestCase {

    private func startHost(shell: String = "/bin/sh") async throws -> (server: HostServer, port: UInt16) {
        let server = HostServer(port: 0, shellPath: shell)
        try await server.start()
        guard let port = await server.boundPort() else {
            await server.stop()
            throw XCTSkip("host did not bind a port")
        }
        return (server, port)
    }

    /// Polls a `@MainActor` predicate until true or the deadline passes (avoids fixed sleeps).
    private func waitUntil(
        timeout: Duration = .seconds(10),
        _ predicate: @MainActor () -> Bool
    ) async -> Bool {
        let start = ContinuousClock.now
        while ContinuousClock.now - start < timeout {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return predicate()
    }

    func testConnectReachesConnectedAndReceivesOutput() async throws {
        let (server, port) = try await startHost()
        defer { Task { await server.stop() } }

        let terminal = TerminalViewModel()
        let vm = ConnectionViewModel(terminal: terminal, host: "127.0.0.1", port: port)
        XCTAssertEqual(vm.status, .disconnected)
        XCTAssertTrue(vm.canConnect)

        await vm.connect()
        XCTAssertEqual(vm.status, .connected, "connect() resolves to connected on a successful handshake")
        XCTAssertNotNil(vm.sessionID)
        XCTAssertNotNil(vm.activeClient)

        // Drive a shell echo; the terminal model should flip to .connected and count bytes.
        try await vm.activeClient?.sendInput(Data("echo RWORK_UI_OK\n".utf8))
        let sawOutput = await waitUntil { terminal.bytesReceived > 0 && terminal.connectionStatus == .connected }
        XCTAssertTrue(sawOutput, "terminal model received output and is connected; bytes=\(terminal.bytesReceived)")

        await vm.disconnect()
        XCTAssertEqual(vm.status, .disconnected, "deliberate disconnect → disconnected (no reconnect)")
    }

    func testInvalidPortFails() async {
        let terminal = TerminalViewModel()
        let vm = ConnectionViewModel(terminal: terminal, host: "127.0.0.1", port: 7420)
        vm.port = "not-a-port"
        XCTAssertFalse(vm.canConnect)
        await vm.connect()
        if case .failed = vm.status {} else {
            XCTFail("expected .failed for an unparseable port, got \(vm.status)")
        }
    }

    func testConnectToDeadPortFails() async {
        let terminal = TerminalViewModel()
        // Port 1 on loopback: nothing listening → handshake times out / refuses.
        let vm = ConnectionViewModel(
            terminal: terminal,
            host: "127.0.0.1",
            port: 1,
            backoff: .init(initial: .milliseconds(10), maximum: .milliseconds(20), multiplier: 2)
        )
        // Shorten the wait: connect() awaits the first handshake which will fail.
        await vm.connect()
        if case .failed = vm.status {} else {
            XCTFail("expected .failed connecting to a dead port, got \(vm.status)")
        }
    }

    func testDeliberateDisconnectDoesNotReconnect() async throws {
        let (server, port) = try await startHost()
        defer { Task { await server.stop() } }

        let terminal = TerminalViewModel()
        let vm = ConnectionViewModel(terminal: terminal, host: "127.0.0.1", port: port)
        await vm.connect()
        XCTAssertEqual(vm.status, .connected)

        await vm.disconnect()
        XCTAssertEqual(vm.status, .disconnected)
        XCTAssertNil(vm.activeClient, "client is torn down on deliberate disconnect")

        // Give any (incorrect) reconnect a window to fire; status must stay disconnected.
        let stayedDisconnected = await waitUntil(timeout: .milliseconds(300)) {
            vm.status != .disconnected
        }
        XCTAssertFalse(stayedDisconnected, "no reconnect after a deliberate disconnect")
    }
}
