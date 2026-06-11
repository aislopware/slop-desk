import XCTest
import Foundation
import AislopdeskProtocol
import AislopdeskTransport
@testable import AislopdeskClient

/// Regression suite for the **zombie-transport reconnect races** (deep-hunt R5, rank 1 — merges the
/// close()/pause()/resume()/concurrent-connect variants). `AislopdeskClient` is an `actor`, so it is
/// reentrant at every `await`. `connect()` suspends inside `await transport.connect(...)` AFTER it has
/// already torn the old transport down to nil and BEFORE it adopts the new one. A `close()`/`pause()`
/// landing in that window — or a SECOND `connect()` superseding the first (the reconnect supervisor
/// racing iOS `resume()`) — used to leave a fully-live transport adopted-but-untracked: 2 sockets +
/// the inbound pump + the ack ticker + a never-released ``ConnectionRegistry`` channel refcount, all
/// orphaned on a dead/paused client.
///
/// The fix is a monotonic `connectGeneration` claimed before the first suspension plus a
/// post-handshake `closed`/`paused`/`Task.isCancelled`/stale-generation re-check that `close()`s and
/// DISCARDS the just-built transport instead of adopting it.
///
/// Every test LOOPS (200×) to shake the interleaving — a single green run masked a 2/5 flake on the
/// sibling ``ConnectionRegistry`` dead-eviction race last round, so concurrency fixes get a stress loop.
final class AislopdeskClientReconnectRaceTests: XCTestCase {

    /// `close()` while a `connect()` is suspended mid-handshake must tear the freshly-built transport
    /// down (releasing its channel), never adopt it.
    func testCloseDuringInflightConnectTearsDownNewTransportNoZombie() async throws {
        for _ in 0..<200 {
            let rec = TransportRecorder()
            let client = AislopdeskClient(makeTransport: { rec.make() })

            let connectTask = Task { try? await client.connect(host: "h", port: 1) }
            await rec.waitForStarted(1)          // connect() is now suspended at the handshake gate
            await client.close()                  // reentrant close while the connect is in flight
            await rec.releaseAll()                // let the handshake complete and resume connect()
            _ = await connectTask.value

            let live = await client._hasLiveTransportForTesting
            XCTAssertFalse(live, "a connect superseded by close() must NOT adopt its transport (zombie)")
            let closes = await rec.totalCloseCount()
            XCTAssertEqual(closes, rec.builtCount,
                           "every transport built during the doomed connect must be closed (channel released)")
            XCTAssertGreaterThanOrEqual(rec.builtCount, 1)
        }
    }

    /// `pause()` while a `connect()` is in flight must discard the new transport; a later `resume()`
    /// then cleanly rebuilds and adopts one.
    func testPauseDuringInflightConnectDiscardsTransportAndResumeRebuilds() async throws {
        for _ in 0..<200 {
            let rec = TransportRecorder()
            let client = AislopdeskClient(makeTransport: { rec.make() })

            let connectTask = Task { try? await client.connect(host: "h", port: 1) }
            await rec.waitForStarted(1)
            await client.pause()
            await rec.releaseAll()
            _ = await connectTask.value

            let liveAfterPause = await client._hasLiveTransportForTesting
            XCTAssertFalse(liveAfterPause, "a connect superseded by pause() must NOT adopt its transport")
            let closesAfterPause = await rec.totalCloseCount()
            XCTAssertEqual(closesAfterPause, 1, "the transport built during the paused connect is closed")

            // resume() must rebuild a fresh transport and adopt it.
            let resumeTask = Task { try? await client.resume() }
            await rec.waitForStarted(2)            // the resume's NEW transport reached the gate
            await rec.releaseAll()
            _ = await resumeTask.value
            let liveAfterResume = await client._hasLiveTransportForTesting
            XCTAssertTrue(liveAfterResume, "resume() after a paused-mid-connect adopts a live transport")
            await client.close()
        }
    }

    /// Two `connect()` calls overlapping in flight (the reconnect-supervisor-vs-`resume()` hazard):
    /// exactly ONE transport is adopted; the superseded one is torn down. Never two live, never a leak.
    func testConcurrentConnectsAdoptExactlyOneAndTearDownTheOther() async throws {
        for _ in 0..<200 {
            let rec = TransportRecorder()
            let client = AislopdeskClient(makeTransport: { rec.make() })

            let c1 = Task { try? await client.connect(host: "h", port: 1) }
            await rec.waitForStarted(1)            // c1 claimed generation 1, suspended at its gate
            let c2 = Task { try? await client.connect(host: "h", port: 1) }
            await rec.waitForStarted(2)            // c2 claimed generation 2 (supersedes c1)
            await rec.releaseAll()
            _ = await c1.value
            _ = await c2.value

            let live = await client._hasLiveTransportForTesting
            XCTAssertTrue(live, "the winning (latest-generation) connect adopts its transport")
            let closes = await rec.totalCloseCount()
            XCTAssertEqual(closes, 1, "exactly the superseded transport is torn down (no zombie, no double-live)")
            XCTAssertEqual(rec.builtCount, 2)
            await client.close()
        }
    }

    // MARK: - Gated controllable transport

    /// A ``ClientTransporting`` whose `connect()` SUSPENDS at a gate until the test releases it, so the
    /// test can inject a reentrant close()/pause()/second-connect precisely while a handshake is in
    /// flight. Counts `close()` calls so the suite can assert a doomed transport was torn down.
    private actor GatedTransport: ClientTransporting {
        private let onStarted: @Sendable () -> Void
        private var gate: CheckedContinuation<Void, Error>?
        private var released = false
        private var _closeCount = 0
        var closeCount: Int { _closeCount }

        private var _sessionID: UUID?
        private var _resumeFromSeq: Int64 = 0
        private var _returningClient = false
        var sessionID: UUID? { _sessionID }
        var resumeFromSeq: Int64 { _resumeFromSeq }
        var returningClient: Bool { _returningClient }

        private let continuation: AsyncThrowingStream<WireMessage, Error>.Continuation
        nonisolated let inbound: AsyncThrowingStream<WireMessage, Error>

        init(onStarted: @escaping @Sendable () -> Void) {
            self.onStarted = onStarted
            var c: AsyncThrowingStream<WireMessage, Error>.Continuation!
            inbound = AsyncThrowingStream { c = $0 }
            continuation = c
        }

        func connect(host: String, port: UInt16, resume: UUID, lastReceivedSeq: Int64, handshakeTimeout: Duration) async throws {
            if released { applyIdentity(resume: resume, lastReceivedSeq: lastReceivedSeq); return }
            // Install the gate FIRST, then signal "started" — so the test's waitForStarted→releaseAll
            // can never observe the start before the continuation it needs to resume exists.
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                self.gate = c
                onStarted()
            }
            applyIdentity(resume: resume, lastReceivedSeq: lastReceivedSeq)
        }

        private func applyIdentity(resume: UUID, lastReceivedSeq: Int64) {
            _sessionID = (resume == WireMessage.newSessionID) ? UUID() : resume
            _resumeFromSeq = lastReceivedSeq
            _returningClient = (resume != WireMessage.newSessionID)
        }

        func release() {
            released = true
            if let c = gate { gate = nil; c.resume() }
        }

        func sendInput(_ bytes: Data) async throws {}
        func sendResize(cols: UInt16, rows: UInt16, pxWidth: UInt16, pxHeight: UInt16) async throws {}
        func sendAck(seq: Int64) async throws {}
        func sendBye() async throws {}
        func close() async { _closeCount += 1; continuation.finish() }
    }

    /// Collects the transports the client builds and counts handshake starts, so the test can release
    /// gates and tally close() calls.
    private final class TransportRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var transports: [GatedTransport] = []
        private var startedCount = 0

        func make() -> GatedTransport {
            let t = GatedTransport(onStarted: { [weak self] in
                guard let self else { return }
                self.lock.lock(); self.startedCount += 1; self.lock.unlock()
            })
            lock.lock(); transports.append(t); lock.unlock()
            return t
        }

        var builtCount: Int { lock.lock(); defer { lock.unlock() }; return transports.count }
        private var snapshot: [GatedTransport] { lock.lock(); defer { lock.unlock() }; return transports }
        // Sync reader — NSLock.lock()/unlock() are unavailable from async contexts, so the async
        // poll loop reads the counter through this non-async helper.
        private func readStarted() -> Int { lock.lock(); defer { lock.unlock() }; return startedCount }

        func waitForStarted(_ n: Int) async {
            while true {
                if readStarted() >= n { return }
                try? await Task.sleep(for: .milliseconds(2))
            }
        }

        func releaseAll() async {
            for t in snapshot { await t.release() }
        }

        func totalCloseCount() async -> Int {
            var total = 0
            for t in snapshot { total += await t.closeCount }
            return total
        }
    }
}
