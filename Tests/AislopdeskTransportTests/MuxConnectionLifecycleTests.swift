import XCTest
import AislopdeskProtocol
@testable import AislopdeskTransport

/// Lifecycle tests for ``MuxNWConnection`` host-side teardown (deep-hunt R5, rank 3): the host
/// open/close/link-down handlers must NOT keep a connection alive forever, and a hard link drop must
/// fire the connection-death hook so the host can reap the connection (free its 2 sockets + 2 receive
/// loops). These prove the primitives the ``HostServer`` retention-map fix is built on, headlessly
/// (in-memory links, no socket / HostServer).
@MainActor
final class MuxConnectionLifecycleTests: XCTestCase {

    private func makeHost() async -> (host: MuxNWConnection, clientControl: InMemoryMuxLink, clientData: InMemoryMuxLink) {
        let (cc, hc) = InMemoryMuxLink.pair()
        let (cd, hd) = InMemoryMuxLink.pair()
        let host = MuxNWConnection(role: .host, controlLink: hc, dataLink: hd)
        await host.start()
        return (host, cc, cd)
    }

    /// `close()` must release the stored host handlers so a connection is no longer kept alive by its
    /// own handler closures (the retain cycle the menu-bar leak was built on). We capture a sentinel in
    /// the handlers and assert it deallocates once `close()` nils them.
    func testCloseReleasesHostHandlersBreakingRetainCycle() async {
        let (host, cc, cd) = await makeHost()
        weak var weakSentinel: Sentinel?
        do {
            let sentinel = Sentinel()
            weakSentinel = sentinel
            await host.setHostOpenHandler { _ in _ = sentinel }     // strong-captures the sentinel
            await host.setHostCloseHandler { _ in _ = sentinel }
            await host.setLinkDownHandler { _ = sentinel }
        }
        XCTAssertNotNil(weakSentinel, "the host handlers retain the sentinel before close()")
        await host.close()
        XCTAssertNil(weakSentinel,
                     "close() must release the host handlers → the captured sentinel deallocs (cycle broken)")
        _ = (cc, cd) // keep the client ends alive for the duration of the test
    }

    /// A HARD link failure (TCP RST / NetBird flap) must fire the connection-death hook EXACTLY ONCE,
    /// even though both links fail.
    func testHardLinkFailureFiresLinkDownHandlerExactlyOnce() async throws {
        let (host, cc, cd) = await makeHost()
        let counter = Counter()
        await host.setLinkDownHandler { counter.bump() }
        cd.fail(); cc.fail()                  // both links drop (a TCP reset kills both)
        try await pollUntil { await host.isDead }
        try await Task.sleep(for: .milliseconds(40)) // let both receive loops finish processing
        XCTAssertEqual(counter.value, 1, "link-down fires exactly once on a hard failure (one-shot across both links)")
    }

    /// A connection that DIED before the host wired the hook (the died-during-accept race) must still be
    /// reaped: installing the hook after the failure fires it immediately.
    func testLinkDownHandlerInstalledAfterFailureFiresImmediately() async throws {
        let (host, cc, cd) = await makeHost()
        cd.fail(); cc.fail()
        try await pollUntil { await host.isDead }
        let counter = Counter()
        await host.setLinkDownHandler { counter.bump() } // installed AFTER the drop
        XCTAssertEqual(counter.value, 1, "a hook installed after the link already failed fires immediately")
    }

    /// A clean `close()` (last-channel teardown) is NOT a hard drop and must NOT fire the link-down hook.
    func testCleanCloseDoesNotFireLinkDownHandler() async throws {
        let (host, cc, cd) = await makeHost()
        let counter = Counter()
        await host.setLinkDownHandler { counter.bump() }
        await host.close()
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(counter.value, 0, "a clean close() is not a connection-death drop → the hook never fires")
        _ = (cc, cd)
    }

    /// R6 self-audit regression: `close()` reached via the link-down reap (e.g. the CONTROL link fails
    /// FIRST, so its `finishLink` schedules `close()` which cancels the DATA receive loop before that
    /// loop could fire `hostCloseHandler`) must REAP every live host channel itself — otherwise the
    /// per-channel PTY + master fd + child + reaper thread leaks. We register a live channel, close the
    /// host connection, and assert the close hook fired for it.
    func testCloseReapsLiveHostChannelsSoPTYsAreNotLeaked() async throws {
        let (cc, hc) = InMemoryMuxLink.pair()
        let (cd, hd) = InMemoryMuxLink.pair()
        let client = MuxNWConnection(role: .client, controlLink: cc, dataLink: cd)
        let host = MuxNWConnection(role: .host, controlLink: hc, dataLink: hd)
        let reaped = IDRecorder()
        await host.setHostOpenHandler { open in Task { await host.sendOpenAck(open.channelID, accepted: true) } }
        await host.setHostCloseHandler { id in reaped.add(id) }
        await client.start(); await host.start()

        // Client opens a channel → the host registers a LIVE channel (data + control sub-channels).
        let (dataCh, _) = try await client.openChannel(sessionID: UUID(), lastReceivedSeq: 0)
        try await pollUntil { await host.hasLiveChannels }

        // Close the host connection (the link-down reap path): it MUST reap the live channel's session.
        await host.close()
        // The channel is reaped (its PTY torn down, not leaked). It may fire MORE than once — close()'s
        // own reap plus the cancelled data-loop's `finishLink` reap can both run — which is harmless:
        // `HostServer.removeMuxSession` is idempotent (map-removal guard), so the PTY shuts down once.
        // The load-bearing invariant is "the live channel WAS reaped, and no OTHER channel was."
        XCTAssertFalse(reaped.ids.isEmpty,
                       "close() must reap the live host channel so its PTY/fd/child is not leaked (control-first drop)")
        XCTAssertEqual(Set(reaped.ids), [dataCh.channelID], "only the live channel is reaped, nothing spurious")
        _ = (cc, cd) // keep the client ends alive for the test
    }

    /// R6 #6 regression: the host must REFUSE channelOpens past the per-connection cap so a hostile peer
    /// cannot fork an unbounded PTY+reaper-thread per peer-chosen channelID (fork-bomb DoS). The
    /// open-handler fires once per NEW channel, so it must fire exactly `maxChannelsPerConnection` times
    /// even when the client opens well past the cap.
    func testHostRefusesChannelOpensPastTheCap() async throws {
        let (cc, hc) = InMemoryMuxLink.pair()
        let (cd, hd) = InMemoryMuxLink.pair()
        let client = MuxNWConnection(role: .client, controlLink: cc, dataLink: cd)
        let host = MuxNWConnection(role: .host, controlLink: hc, dataLink: hd)
        let opens = Counter()
        await host.setHostOpenHandler { open in opens.bump(); Task { await host.sendOpenAck(open.channelID, accepted: true) } }
        await client.start(); await host.start()

        let cap = MuxFlowControl.maxChannelsPerConnection
        for _ in 0..<(cap + 25) {
            _ = try await client.openChannel(sessionID: UUID(), lastReceivedSeq: 0)
        }
        try await pollUntil(timeout: .seconds(5)) { opens.value >= cap }
        try await Task.sleep(for: .milliseconds(150)) // let any past-cap opens route (they must be refused)
        XCTAssertEqual(opens.value, cap,
                       "the host registers at most \(cap) channels and refuses opens past the cap (fork-bomb cap)")
        // R7 #6: the ROUTER TABLE must also stay bounded — a refused open must NOT grow dataTable.states
        // (the cap check now runs BEFORE the router records the id). Without the fix it would be cap+25.
        let tableCount = await host._dataTableStateCountForTesting
        XCTAssertLessThanOrEqual(tableCount, cap,
                                 "refused over-cap opens must not grow the router table (cheap memory-DoS closed)")
        _ = (cc, cd)
    }

    /// R8 #8: a `channelOpen` whose DATA-link send FAILS must UNDO its partial registration — otherwise
    /// the just-registered sub-channels (decoder + inbound continuation + window accountant) leak forever
    /// and keep `hasLiveChannels` true. We open a channel on a connection whose data link throws on send,
    /// then assert no ghost channel was left behind.
    func testOpenChannelCleansUpPartialRegistrationOnSendFailure() async throws {
        let (cc, _) = InMemoryMuxLink.pair()
        let failingData = SendFailingMuxLink()
        let client = MuxNWConnection(role: .client, controlLink: cc, dataLink: failingData)
        await client.start()
        let liveBefore = await client.hasLiveChannels
        XCTAssertFalse(liveBefore)

        do {
            _ = try await client.openChannel(sessionID: UUID(), lastReceivedSeq: 0)
            XCTFail("openChannel must throw when the data-link send fails")
        } catch { /* expected — the send threw */ }

        let liveAfter = await client.hasLiveChannels
        XCTAssertFalse(liveAfter, "a send-failed openChannel leaves NO ghost channel (cleaned up its registration)")
        await client.close()
    }

    // MARK: - Helpers

    private final class Sentinel: @unchecked Sendable {}

    /// A ``MuxByteLink`` whose `send()` always throws, but whose receive never errors — so the connection
    /// is NOT marked dead (openChannel's `guard !isDead` passes) and the send-failure cleanup path is hit.
    private final class SendFailingMuxLink: MuxByteLink, @unchecked Sendable {
        private let stream: AsyncThrowingStream<Data, Error>
        init() { stream = AsyncThrowingStream { _ in } } // never yields / never finishes → link stays "alive"
        var receiveChunks: AsyncThrowingStream<Data, Error> { stream }
        func send(_ data: Data) async throws { throw AislopdeskTransportError.notConnected("send failed (test)") }
        func close() async {}
    }

    private final class IDRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _ids: [UInt32] = []
        func add(_ id: UInt32) { lock.lock(); _ids.append(id); lock.unlock() }
        var ids: [UInt32] { lock.lock(); defer { lock.unlock() }; return _ids }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func bump() { lock.lock(); n += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    private func pollUntil(timeout: Duration = .seconds(2), _ cond: @Sendable () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await cond() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        if await !cond() { throw LifecycleTestError.timedOut }
    }

    private enum LifecycleTestError: Error { case timedOut }
}
