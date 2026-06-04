import XCTest
import RworkProtocol
@testable import RworkTransport

/// Refcount + teardown tests for ``ConnectionRegistry`` — the per-host shared-connection pool.
/// Headless: the shared ``MuxNWConnection`` is built from IN-MEMORY links (no socket), and an
/// auto-accepting host end keeps `openChannel` from blocking. Proves the load-bearing S1 invariant:
/// N same-host panes ride ONE shared connection, and the connection is torn down ONLY when the LAST
/// channel closes (single-pane close/reconnect never drops it).
@MainActor
final class ConnectionRegistryTests: XCTestCase {

    /// Builds a registry whose `makeConnection` returns a fresh in-memory client connection (paired
    /// with an auto-accepting host) per endpoint. Returns the registry; `created` counts how many
    /// distinct shared connections the factory actually built (to assert reuse).
    private func makeRegistry(enabled: Bool = true) -> (ConnectionRegistry, created: @Sendable () -> Int) {
        let counter = Counter()
        let registry = ConnectionRegistry(isEnabled: enabled) { _, _ in
            counter.bump()
            let (clientControl, hostControl) = InMemoryMuxLink.pair()
            let (clientData, hostData) = InMemoryMuxLink.pair()
            let client = MuxNWConnection(role: .client, controlLink: clientControl, dataLink: clientData)
            let host = MuxNWConnection(role: .host, controlLink: hostControl, dataLink: hostData)
            await host.setHostOpenHandler { open in
                Task { await host.sendOpenAck(open.channelID, accepted: true) }
            }
            await client.start()
            await host.start()
            return client
        }
        return (registry, { counter.value })
    }

    func testTwoSameHostPanesShareOneConnection() async throws {
        let (registry, created) = makeRegistry()
        let id = UUID()
        _ = try await registry.acquire(host: "h", port: 1, sessionID: id, lastReceivedSeq: 0)
        _ = try await registry.acquire(host: "h", port: 1, sessionID: id, lastReceivedSeq: 0)

        XCTAssertEqual(registry.sharedConnectionCount, 1, "both same-host panes ride ONE shared connection")
        XCTAssertEqual(registry.channelCount(host: "h", port: 1), 2, "two channels on the shared connection")
        XCTAssertEqual(created(), 1, "the factory built exactly one physical connection (reused for pane 2)")
    }

    func testDifferentHostsGetDistinctConnections() async throws {
        let (registry, created) = makeRegistry()
        _ = try await registry.acquire(host: "h1", port: 1, sessionID: UUID(), lastReceivedSeq: 0)
        _ = try await registry.acquire(host: "h2", port: 1, sessionID: UUID(), lastReceivedSeq: 0)
        XCTAssertEqual(registry.sharedConnectionCount, 2, "different hosts → different shared connections")
        XCTAssertEqual(created(), 2)
    }

    func testSinglePaneCloseDoesNotDropSharedConnection() async throws {
        let (registry, _) = makeRegistry()
        let id = UUID()
        let a = try await registry.acquire(host: "h", port: 1, sessionID: id, lastReceivedSeq: 0)
        let b = try await registry.acquire(host: "h", port: 1, sessionID: id, lastReceivedSeq: 0)
        XCTAssertEqual(registry.channelCount(host: "h", port: 1), 2)

        // Close pane A's channel: the shared connection MUST survive for pane B.
        await registry.release(host: "h", port: 1, channelID: a.channelID)
        XCTAssertEqual(registry.sharedConnectionCount, 1, "the shared connection survives a single pane close")
        XCTAssertEqual(registry.channelCount(host: "h", port: 1), 1, "only B's channel remains")

        // Close pane B (the LAST channel): now the shared connection is torn down + the entry dropped.
        await registry.release(host: "h", port: 1, channelID: b.channelID)
        XCTAssertEqual(registry.sharedConnectionCount, 0, "the LAST channel closing tears the shared connection down")
        XCTAssertEqual(registry.channelCount(host: "h", port: 1), 0)
    }

    func testGateOffStillParsesEnvironment() {
        XCTAssertFalse(ConnectionRegistry.muxEnabledFromEnvironment([:]), "unset → OFF (byte-identical today)")
        XCTAssertTrue(ConnectionRegistry.muxEnabledFromEnvironment(["RWORK_TCP_MUX": "1"]))
        XCTAssertTrue(ConnectionRegistry.muxEnabledFromEnvironment(["RWORK_TCP_MUX": "true"]))
        XCTAssertTrue(ConnectionRegistry.muxEnabledFromEnvironment(["RWORK_TCP_MUX": "ON"]))
        XCTAssertFalse(ConnectionRegistry.muxEnabledFromEnvironment(["RWORK_TCP_MUX": "0"]))
        XCTAssertFalse(ConnectionRegistry.muxEnabledFromEnvironment(["RWORK_TCP_MUX": ""]))
    }
}

/// A trivial thread-safe counter for the factory-invocation assertion.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}
