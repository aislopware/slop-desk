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
    private func makeRegistry() -> (ConnectionRegistry, created: @Sendable () -> Int) {
        let counter = Counter()
        let registry = ConnectionRegistry { _, _ in
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

    /// [2] Two panes first-connecting to the SAME new host CONCURRENTLY must net `pendingAcquires` to
    /// zero, so closing both later tears the shared connection down. Before the fix, a coalesced
    /// first-acquire that resumed before the build creator stored the entry silently skipped its
    /// `pendingAcquires += 1` (optional-chained no-op) but still ran the matching `-= 1`, driving the
    /// count NEGATIVE so the last-channel teardown guard never held → the connection leaked forever.
    /// Looped to make the resume-order race likely to surface a regression.
    func testConcurrentFirstAcquireDoesNotLeakSharedConnection() async throws {
        for _ in 0..<25 {
            let (registry, _) = makeRegistry()
            let id = UUID()
            async let a = registry.acquire(host: "h", port: 1, sessionID: id, lastReceivedSeq: 0)
            async let b = registry.acquire(host: "h", port: 1, sessionID: id, lastReceivedSeq: 0)
            let (ra, rb) = try await (a, b)
            XCTAssertEqual(registry.sharedConnectionCount, 1, "both concurrent first-acquires share ONE connection")

            await registry.release(host: "h", port: 1, channelID: ra.channelID)
            await registry.release(host: "h", port: 1, channelID: rb.channelID)
            XCTAssertEqual(registry.sharedConnectionCount, 0,
                           "after both panes close, the shared connection tears down (no pendingAcquires under-count leak)")
        }
    }

    /// [5] After a HARD link drop (TCP RST / NetBird flap), a reconnecting pane must NOT re-acquire the
    /// dead pooled connection — the registry evicts the corpse and builds a FRESH one. Before the fix,
    /// `finishLink` did not mark the connection dead, so the still-pooled entry was handed back and the
    /// reconnecting pane opened onto a dead link forever.
    func testReconnectAfterHardLinkDropEvictsDeadConnectionAndBuildsFresh() async throws {
        let made = MadeConnections()
        let registry = ConnectionRegistry { _, _ in
            let (cc, hc) = InMemoryMuxLink.pair()
            let (cd, hd) = InMemoryMuxLink.pair()
            let client = MuxNWConnection(role: .client, controlLink: cc, dataLink: cd)
            let host = MuxNWConnection(role: .host, controlLink: hc, dataLink: hd)
            await host.setHostOpenHandler { open in Task { await host.sendOpenAck(open.channelID, accepted: true) } }
            await client.start()
            await host.start()
            made.record(client: client, clientData: cd)
            return client
        }

        _ = try await registry.acquire(host: "h", port: 1, sessionID: UUID(), lastReceivedSeq: 0)
        XCTAssertEqual(registry.sharedConnectionCount, 1)
        XCTAssertEqual(made.count, 1)

        // Hard link drop on the live shared connection.
        made.lastClientData?.fail()
        // Poll until the connection's receive loop has processed the failure (finishLink → isDead).
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if await (made.lastClient?.isDead ?? false) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let dead = await (made.lastClient?.isDead ?? false)
        XCTAssertTrue(dead, "the link drop must mark the pooled connection dead")

        // A reconnecting pane re-acquires: the dead entry is evicted and a FRESH connection is built.
        _ = try await registry.acquire(host: "h", port: 1, sessionID: UUID(), lastReceivedSeq: 0)
        XCTAssertEqual(made.count, 2, "the dead pooled connection was evicted and a fresh one built")
        XCTAssertEqual(registry.sharedConnectionCount, 1, "exactly one live shared connection after the rebuild")
    }
}

/// Captures the connections + their client-side DATA link a test factory builds, so a test can drive a
/// hard link failure on the live one. `@MainActor` (the registry factory is `@MainActor`).
@MainActor
private final class MadeConnections {
    private(set) var count = 0
    private(set) var lastClient: MuxNWConnection?
    private(set) var lastClientData: InMemoryMuxLink?
    func record(client: MuxNWConnection, clientData: InMemoryMuxLink) {
        count += 1
        lastClient = client
        lastClientData = clientData
    }
}

/// A trivial thread-safe counter for the factory-invocation assertion.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}
