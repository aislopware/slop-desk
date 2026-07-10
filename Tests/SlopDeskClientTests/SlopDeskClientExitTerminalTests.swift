import Foundation
import SlopDeskProtocol
import SlopDeskTransport
import XCTest
@testable import SlopDeskClient

/// `.exit` must be TERMINAL for a ``SlopDeskClient`` instance, exactly like ``SlopDeskClient/close()``.
///
/// The wake stream (`outputWakeups`) is created once in init and permanently `finish()`ed when the
/// remote child exits — the single consumer (`TerminalViewModel.observe`) returns on that finish and
/// is never restarted (it is started once per `performConnect`, which builds a NEW client). So any
/// connect on the SAME client after `.exit` produces a shell whose output lands in `outputInbox`
/// with NO consumer: `takeOutputBatch` never runs again, no window credit is ever re-granted, and
/// each reconnect strands up to one fresh mux window of bytes — an unbounded ratchet on a pane that
/// renders nothing while showing `.connected`. Under wifi flapping the post-exit FIN's
/// `.disconnected` used to launch a `ReconnectManager` campaign (its gates checked only
/// `isPaused`/`isClosed`), turning an instantly-exiting shell into a host respawn loop.
///
/// The pinned semantics: after `.exit` the client refuses `connect()` (and `resume()` no-ops), the
/// post-exit stream end surfaces NO `.disconnected`, and `ReconnectManager` treats `isExited` like
/// `isClosed`. A respawn is an explicit user re-dial, which builds a fresh client.
final class SlopDeskClientExitTerminalTests: XCTestCase {
    /// `connect()` after `.exit` must refuse (throw) and build no new transport — the consumer-less
    /// client must never be handed a fresh shell whose output nothing can drain. (The FIRST
    /// connect's transport stays adopted until `close()` — the refusal fires before teardown, so
    /// the pin is on "no NEW transport", not "no transport".)
    func testConnectAfterExitRefused() async throws {
        let factory = CountingFactory()
        let client = SlopDeskClient(makeTransport: { factory.make() })
        try await client.connect(host: "h", port: 1)
        await client.handleInboundForTesting(.exit(code: 0))

        var threw = false
        do {
            try await client.connect(host: "h", port: 1)
        } catch {
            threw = true
        }
        XCTAssertTrue(
            threw,
            "connect() after .exit must refuse — the wake stream is dead, so a new shell's output would strand in outputInbox forever",
        )
        XCTAssertEqual(
            factory.count, 1,
            "no new transport (fresh host shell) may be built for an exited client",
        )
        await client.close()
    }

    /// `resume()` after `.exit` must be a no-op (like resume-after-close): an iOS
    /// background/foreground cycle around an exited pane must not respawn a shell into it.
    func testResumeAfterExitDoesNotRespawn() async throws {
        let client = SlopDeskClient(makeTransport: { FakeTransport() })
        try await client.connect(host: "h", port: 1)
        await client.handleInboundForTesting(.exit(code: 0))
        await client.pause()
        try? await client.resume()
        let live = await client.hasLiveTransportForTesting
        XCTAssertFalse(live, "resume() must not re-dial an exited client")
    }

    /// The full flap sequence: `.exit` arrives on the live inbound, then the host closes the
    /// channel (the post-exit FIN). The supervisor must launch NO reconnect campaign — the old
    /// behavior built a second transport (a fresh host shell) within one immediate attempt.
    func testNoReconnectCampaignAfterExitThenFIN() async throws {
        let factory = CountingFactory()
        let client = SlopDeskClient(makeTransport: { factory.make() })
        let manager = ReconnectManager(
            client: client,
            backoff: .init(initial: .milliseconds(1), maximum: .milliseconds(2), multiplier: 2.0),
        )
        // Subscribe BEFORE connect, mirroring production order (ConnectionViewModel.performConnect).
        let supervisor = manager.start(host: "h", port: 1)
        try await client.connect(host: "h", port: 1)
        XCTAssertEqual(factory.count, 1)

        guard let transport = factory.last else {
            XCTFail("connect adopted no transport")
            return
        }
        // The remote child exits, then the host FINs the channel.
        await transport.yieldInbound(.exit(code: 0))
        await transport.finishInbound()

        // Give a (would-be) campaign ample time: the buggy path's first attempt fires immediately
        // on the .disconnected, so a stranded-respawn shows up as factory.count == 2 well inside this.
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(
            factory.count, 1,
            "the post-exit FIN must not trigger a reconnect campaign — a respawned shell would feed a consumer-less inbox",
        )
        supervisor.cancel()
        await client.close()
    }

    /// `reconnectLoop` bails IMMEDIATELY on an exited client (mirror of the closed-client guard):
    /// no connect attempt, no resume, no give-up.
    func testReconnectLoopBailsImmediatelyOnExitedClient() async throws {
        let client = SlopDeskClient(makeTransport: { FakeTransport() })
        try await client.connect(host: "h", port: 1)
        await client.handleInboundForTesting(.exit(code: 0))

        let logs = LineCollector()
        let gaveUp = FlagBox()
        await ReconnectManager.reconnectLoop(
            client: client, host: "h", port: 1,
            backoff: .init(initial: .milliseconds(1), maximum: .milliseconds(2), multiplier: 2.0),
            onLog: { logs.append($0) },
            onProgress: { _, _ in },
            onGaveUp: { gaveUp.set() },
        )

        XCTAssertFalse(
            logs.lines.contains { $0.contains("resumed") },
            "an exited client must never be reconnected by the campaign loop",
        )
        XCTAssertFalse(gaveUp.value, "an exited client must not burn a doomed campaign to give-up")
        XCTAssertFalse(
            logs.lines.contains { $0.contains("gave up") },
            "no give-up line for an exited client",
        )
    }

    /// The post-exit stream end must surface NO `.disconnected`: the `.exit` event already told the
    /// UI the session is over, and a `.disconnected` would flip the pane to a forever-"reconnecting".
    func testPostExitStreamEndYieldsNoDisconnected() async throws {
        let factory = CountingFactory()
        let client = SlopDeskClient(makeTransport: { factory.make() })
        let events = client.events
        try await client.connect(host: "h", port: 1)
        guard let transport = factory.last else {
            XCTFail("connect adopted no transport")
            return
        }
        await transport.yieldInbound(.exit(code: 0))
        await transport.finishInbound()
        // Close AFTER the FIN is processed: close() finishes the event stream so the collector
        // below terminates deterministically. teardownTransport awaits the (already-ended) pump.
        try await Task.sleep(for: .milliseconds(100))
        await client.close()

        var sawExit = false
        var sawDisconnected = false
        for await event in events {
            if case .exit = event { sawExit = true }
            if case .disconnected = event { sawDisconnected = true }
        }
        XCTAssertTrue(sawExit, "the .exit event itself must still be surfaced")
        XCTAssertFalse(
            sawDisconnected,
            "the post-exit FIN is an expected end — surfacing .disconnected re-arms reconnect supervisors",
        )
    }

    /// `isExited` is the property the ReconnectManager gates read — it must flip true exactly
    /// on the `.exit` event.
    func testIsExitedReflectsChildExit() async throws {
        let client = SlopDeskClient(makeTransport: { FakeTransport() })
        let before = await client.isExited
        XCTAssertFalse(before, "a fresh client has no exited child")
        try await client.connect(host: "h", port: 1)
        await client.handleInboundForTesting(.exit(code: 42))
        let after = await client.isExited
        XCTAssertTrue(after, "isExited is true after the child .exit")
        await client.close()
    }

    // MARK: - Helpers

    /// Counts transport builds — a second build after `.exit` IS the defect (a respawned host shell
    /// nothing can drain).
    private final class CountingFactory: @unchecked Sendable {
        private let lock = NSLock()
        private var _count = 0
        private var _last: FakeTransport?

        func make() -> FakeTransport {
            let t = FakeTransport()
            lock.lock()
            _count += 1
            _last = t
            lock.unlock()
            return t
        }

        var count: Int { lock.lock()
            defer { lock.unlock() }
            return _count
        }

        var last: FakeTransport? { lock.lock()
            defer { lock.unlock() }
            return _last
        }
    }

    /// Minimal `ClientTransporting` stub (mirrors `MuxClientTransport`'s session-identity rules) whose
    /// inbound is drivable: tests yield `.exit` and then `finishInbound()` to simulate the host FIN.
    private actor FakeTransport: ClientTransporting {
        private var _sessionID: UUID?
        private var _resumeFromSeq: Int64 = 0
        private var _returningClient = false
        var sessionID: UUID? { _sessionID }
        var resumeFromSeq: Int64 { _resumeFromSeq }
        var returningClient: Bool { _returningClient }

        private let continuation: AsyncThrowingStream<WireMessage, Error>.Continuation
        nonisolated let inbound: AsyncThrowingStream<WireMessage, Error>

        init() {
            var c: AsyncThrowingStream<WireMessage, Error>.Continuation!
            inbound = AsyncThrowingStream { c = $0 }
            continuation = c
        }

        func yieldInbound(_ message: WireMessage) {
            continuation.yield(message)
        }

        func finishInbound() {
            continuation.finish()
        }

        func connect(
            host _: String,
            port _: UInt16,
            resume: UUID,
            lastReceivedSeq _: Int64,
            handshakeTimeout _: Duration,
        ) {
            _sessionID = (resume == WireMessage.newSessionID) ? UUID() : resume
            _resumeFromSeq = 0 // Mirrors MuxClientTransport: no host-authoritative resumeFromSeq yet.
            _returningClient = (resume != WireMessage.newSessionID)
        }

        func sendInput(_: Data) {}
        func sendResize(cols _: UInt16, rows _: UInt16, pxWidth _: UInt16, pxHeight _: UInt16) {}
        func sendAck(seq _: Int64) {}
        func sendBye() {}
        func close() { continuation.finish() }
    }

    private final class LineCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var _lines: [String] = []
        func append(_ s: String) { lock.lock()
            _lines.append(s)
            lock.unlock()
        }

        var lines: [String] { lock.lock()
            defer { lock.unlock() }
            return _lines
        }
    }

    private final class FlagBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _value = false
        func set() { lock.lock()
            _value = true
            lock.unlock()
        }

        var value: Bool { lock.lock()
            defer { lock.unlock() }
            return _value
        }
    }
}
