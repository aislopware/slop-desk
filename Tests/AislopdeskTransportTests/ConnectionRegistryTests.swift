import AislopdeskProtocol
import XCTest
@testable import AislopdeskTransport

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
            XCTAssertEqual(
                registry.sharedConnectionCount,
                0,
                "after both panes close, the shared connection tears down (no pendingAcquires under-count leak)",
            )
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

    /// Two panes reconnecting CONCURRENTLY after a hard link drop (the iOS background→resume /
    /// NetBird-flap storm) must evict the dead corpse exactly ONCE and SHARE one fresh connection
    /// (`made.count == 2`: the original + ONE rebuild), never each evict+rebuild (which would orphan a
    /// 3rd connection `release` can never find AND collide both panes' first channel on id 1 → a later
    /// release tears down the WRONG pane). This asserts the no-over-build / no-leak invariant the
    /// `sharedConnection` identity-gated-eviction fix guarantees.
    ///
    /// This DOES catch the over-eviction: the dominant racing interleaving is the 1st acquirer
    /// suspending in `await close()` (after `removeValue`) long enough that the 2nd builds+stores a
    /// fresh connection and clears `building`, so the 1st then builds a SECOND fresh one — orphaning it
    /// (`made.count == 3`, one channel stranded on the orphan → `channelCount == 1`). The full fix
    /// needs BOTH the identity-gated eviction AND a re-check of `entries[key]` AFTER `close()` before
    /// building; an incomplete fix (identity check only) fails this reliably (~2 in 5 runs). Looped to
    /// surface the interleaving.
    func testConcurrentReconnectStormSharesOneFreshConnection() async throws {
        for _ in 0..<30 {
            let made = MadeConnections()
            let registry = ConnectionRegistry { _, _ in
                let (cc, hc) = InMemoryMuxLink.pair()
                let (cd, hd) = InMemoryMuxLink.pair()
                let client = MuxNWConnection(role: .client, controlLink: cc, dataLink: cd)
                let host = MuxNWConnection(role: .host, controlLink: hc, dataLink: hd)
                await host
                    .setHostOpenHandler { open in Task { await host.sendOpenAck(open.channelID, accepted: true) } }
                await client.start()
                await host.start()
                made.record(client: client, clientData: cd)
                return client
            }

            // One live channel keeps the entry pooled; then a hard drop makes the pooled connection dead.
            _ = try await registry.acquire(host: "h", port: 1, sessionID: UUID(), lastReceivedSeq: 0)
            made.lastClientData?.fail()
            let deadline = Date().addingTimeInterval(2)
            while Date() < deadline {
                if await (made.lastClient?.isDead ?? false) { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            let isDead = await (made.lastClient?.isDead ?? false)
            XCTAssertTrue(isDead, "the drop must mark the pooled connection dead")

            // Two panes reconnect concurrently against the SAME dead pooled entry.
            async let a = registry.acquire(host: "h", port: 1, sessionID: UUID(), lastReceivedSeq: 0)
            async let b = registry.acquire(host: "h", port: 1, sessionID: UUID(), lastReceivedSeq: 0)
            _ = try await (a, b)

            XCTAssertEqual(
                made.count,
                2,
                "both concurrent reconnectors evict the corpse ONCE and share ONE fresh connection (no orphaned 3rd)",
            )
            XCTAssertEqual(
                registry.sharedConnectionCount,
                1,
                "exactly one live shared connection after the concurrent rebuild",
            )
            XCTAssertEqual(
                registry.channelCount(host: "h", port: 1),
                2,
                "both reconnectors' channels land on the SAME fresh connection",
            )
        }
    }

    /// R8 #1: `acquire()`'s post-`openChannel` refcount mutations must be IDENTITY-GATED. If a concurrent
    /// dead-eviction rebuilds the pooled connection while THIS acquire is suspended inside `openChannel`'s
    /// `dataLink.send`, the resuming acquire must NOT decrement/insert into the FRESH entry — that
    /// underflows its `pendingAcquires` (→ a permanent connection leak: the last-channel teardown guard
    /// `pendingAcquires == 0` never holds). It must throw instead. We hold C1's `openChannel` mid-send via
    /// a gated link, kill+evict C1 with a concurrent acquire (building C2), release the gate, then assert
    /// A throws and — the load-bearing part — releasing B's only channel actually tears C2 down.
    func testAcquireInFlightDuringDeadEvictionThrowsAndDoesNotLeak() async throws {
        let state = GatedFactoryState()
        let registry = ConnectionRegistry { _, _ in
            let (cc, hc) = InMemoryMuxLink.pair()
            let (cdInner, hd) = InMemoryMuxLink.pair()
            let isFirst = state.takeFirst()
            let cd: any MuxByteLink
            if isFirst { let g = GatedMuxLink(cdInner)
                state.gated = g
                cd = g
            } else { cd = cdInner }
            let client = MuxNWConnection(role: .client, controlLink: cc, dataLink: cd)
            let host = MuxNWConnection(role: .host, controlLink: hc, dataLink: hd)
            await host.setHostOpenHandler { open in Task { await host.sendOpenAck(open.channelID, accepted: true) } }
            await client.start()
            await host.start()
            if isFirst { state.c1 = client
                state.c1HostData = hd
            }
            return client
        }

        // A acquires on the GATED C1 → suspends inside openChannel's dataLink.send.
        async let a: MuxAcquisition = registry.acquire(host: "h", port: 1, sessionID: UUID(), lastReceivedSeq: 0)
        try await pollUntil { state.gated?.hasWaiter == true } // A is parked in the gated send

        // Kill C1 (link RST) and wait until it is observably dead.
        state.c1HostData?.fail()
        try await pollUntil { await (state.c1?.isDead ?? false) }

        // B: a concurrent acquire evicts the dead C1 and builds a FRESH C2 (its channel opens normally).
        let b = try await registry.acquire(host: "h", port: 1, sessionID: UUID(), lastReceivedSeq: 0)

        // Release A's gate → A's openChannel completes on the (now-closed) C1 → A resumes → the identity
        // guard throws instead of corrupting C2's entry.
        state.gated?.openGate()
        var aThrew = false
        do { _ = try await a } catch { aThrew = true }
        XCTAssertTrue(aThrew, "an acquire whose connection was evicted+rebuilt mid-openChannel must throw")

        XCTAssertEqual(registry.sharedConnectionCount, 1, "exactly the fresh C2 remains")
        XCTAssertEqual(registry.channelCount(host: "h", port: 1), 1, "only B's channel is on C2 (A did not corrupt it)")

        // Load-bearing leak assertion: releasing B's only channel must tear C2 down. Without the identity
        // gate, A's stale `pendingAcquires -= 1` underflowed C2 to -1, so teardown never fired → C2 leaked.
        await registry.release(host: "h", port: 1, channelID: b.channelID)
        XCTAssertEqual(
            registry.sharedConnectionCount,
            0,
            "C2 tears down on its last release (no pendingAcquires-underflow leak)",
        )
    }

    // MARK: - App-global pin (docs/31 connect-gate)

    /// `pin` establishes the shared connection with ZERO channels and keeps it alive — the connect-gate
    /// is "connected" before any pane opens a channel.
    func testPinEstablishesConnectionWithNoChannels() async throws {
        let (registry, created) = makeRegistry()
        try await registry.pin(host: "h", port: 1)
        XCTAssertEqual(registry.sharedConnectionCount, 1, "pin builds the shared connection")
        XCTAssertEqual(registry.channelCount(host: "h", port: 1), 0, "no channels yet — just the pinned mux")
        XCTAssertEqual(created(), 1)
        let alive = await registry.isConnectionAlive(host: "h", port: 1)
        XCTAssertTrue(alive, "the pinned connection reports alive")
    }

    /// A pinned connection SURVIVES the last channel release (the app stays connected when you close the
    /// last pane); `unpin` then tears it down.
    func testPinnedConnectionSurvivesLastChannelReleaseThenUnpinTearsDown() async throws {
        let (registry, created) = makeRegistry()
        try await registry.pin(host: "h", port: 1)
        let ch = try await registry.acquire(host: "h", port: 1, sessionID: UUID(), lastReceivedSeq: 0)
        XCTAssertEqual(registry.channelCount(host: "h", port: 1), 1)
        XCTAssertEqual(created(), 1, "the channel rides the already-pinned connection (no rebuild)")

        // Closing the ONLY channel must NOT tear the pinned connection down.
        await registry.release(host: "h", port: 1, channelID: ch.channelID)
        XCTAssertEqual(registry.sharedConnectionCount, 1, "pinned connection survives the last channel close")
        XCTAssertEqual(registry.channelCount(host: "h", port: 1), 0)

        // Unpin (deliberate disconnect) with no channels → torn down.
        await registry.unpin(host: "h", port: 1)
        XCTAssertEqual(
            registry.sharedConnectionCount,
            0,
            "unpin tears the pinned connection down when no channel rides it",
        )
    }

    /// `unpin` with channels still live leaves the connection up (the refcount path still owns it); only
    /// the LAST channel release then tears it down.
    func testUnpinWithLiveChannelKeepsConnectionUntilLastRelease() async throws {
        let (registry, _) = makeRegistry()
        try await registry.pin(host: "h", port: 1)
        let ch = try await registry.acquire(host: "h", port: 1, sessionID: UUID(), lastReceivedSeq: 0)

        await registry.unpin(host: "h", port: 1)
        XCTAssertEqual(registry.sharedConnectionCount, 1, "a live channel keeps the connection up after unpin")

        await registry.release(host: "h", port: 1, channelID: ch.channelID)
        XCTAssertEqual(registry.sharedConnectionCount, 0, "the last channel release tears it down once unpinned")
    }

    /// REGRESSION (docs/31 review): an `unpin()` that races `pin()`'s in-flight build must NOT orphan the
    /// just-built shared connection. Before the fix, unpin removed the optimistic pin while the build's
    /// `entries[key]` was still nil (so unpin found nothing to tear down), then the build completed and
    /// stored a LIVE zero-channel connection that no path ever reclaimed (a permanent socket leak —
    /// reachable by tapping the gate's Cancel during `.connecting`/`.reconnecting`).
    func testPinRacingConcurrentUnpinDoesNotOrphanConnection() async throws {
        let gate = BuildGate()
        let registry = ConnectionRegistry { _, _ in
            await gate.wait() // suspend the build until the test releases it
            let (cc, hc) = InMemoryMuxLink.pair()
            let (cd, hd) = InMemoryMuxLink.pair()
            let client = MuxNWConnection(role: .client, controlLink: cc, dataLink: cd)
            let host = MuxNWConnection(role: .host, controlLink: hc, dataLink: hd)
            await host.setHostOpenHandler { open in Task { await host.sendOpenAck(open.channelID, accepted: true) } }
            await client.start()
            await host.start()
            return client
        }

        async let pinTask: Void = registry.pin(host: "h", port: 1)
        try await pollUntil { gate.isWaiting } // pin is suspended inside the build
        await registry.unpin(host: "h", port: 1) // concurrent unpin removes the optimistic pin
        gate.release() // let the build complete
        try await pinTask

        XCTAssertEqual(
            registry.sharedConnectionCount,
            0,
            "a pin whose unpin raced its build must tear the just-built connection down, not orphan it",
        )
    }

    private func pollUntil(timeout: Duration = .seconds(3), _ cond: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await cond() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        if await !cond() { throw RegistryTestError.timedOut }
    }
}

private enum RegistryTestError: Error { case timedOut }

/// Suspends a `makeConnection` build until the test releases it — so a test can hold `pin()` mid-build
/// and inject a concurrent `unpin()`. `@MainActor` (the factory is `@MainActor`).
@MainActor
private final class BuildGate {
    private var cont: CheckedContinuation<Void, Never>?
    private(set) var isWaiting = false
    func wait() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            isWaiting = true
            cont = c
        }
    }

    func release() { isWaiting = false
        cont?.resume()
        cont = nil
    }
}

/// Holds the FIRST connection's gated link + corpse handles so the test can park `openChannel` mid-send,
/// kill C1, and drive the eviction race deterministically. `@MainActor` (the factory is `@MainActor`).
@MainActor
private final class GatedFactoryState {
    private var firstTaken = false
    var gated: GatedMuxLink?
    var c1: MuxNWConnection?
    var c1HostData: InMemoryMuxLink?
    func takeFirst() -> Bool { let f = !firstTaken
        firstTaken = true
        return f
    }
}

/// A ``MuxByteLink`` that SUSPENDS `send()` until the test opens its gate — so a test can hold
/// `MuxNWConnection.openChannel` mid-flight (it suspends in `dataLink.send`) and inject a concurrent
/// dead-eviction before letting it resume. Everything else delegates to a real in-memory link.
private final class GatedMuxLink: MuxByteLink, @unchecked Sendable {
    private let inner: InMemoryMuxLink
    private let lock = NSLock()
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(_ inner: InMemoryMuxLink) { self.inner = inner }
    var receiveChunks: AsyncThrowingStream<Data, Error> { inner.receiveChunks }
    func send(_ data: Data) async throws {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock()
            if opened { lock.unlock()
                c.resume()
                return
            }
            waiters.append(c)
            lock.unlock()
        }
        try await inner.send(data)
    }

    /// Pipelined sends bypass the gate (it exists to hold the AWAITED `openChannel` send
    /// mid-flight; pipelined frames are not what this fixture gates).
    func sendPipelined(_ data: Data) { inner.sendPipelined(data) }
    func openGate() {
        lock.lock()
        opened = true
        let w = waiters
        waiters.removeAll()
        lock.unlock()
        for c in w { c.resume() }
    }

    var hasWaiter: Bool { lock.lock()
        defer { lock.unlock() }
        return !waiters.isEmpty
    }

    func close() async { await inner.close() }
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
    func bump() { lock.lock()
        n += 1
        lock.unlock()
    }

    var value: Int { lock.lock()
        defer { lock.unlock() }
        return n
    }
}
