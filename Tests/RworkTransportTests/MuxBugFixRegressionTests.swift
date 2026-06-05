import XCTest
import RworkProtocol
@testable import RworkTransport

/// Regression tests for the overnight bug-hunt fixes at the ``MuxNWConnection`` layer (headless,
/// in-memory links — no socket, no `HostServer`):
///   • [3] a DUPLICATE `channelOpen` for a live channel must NOT re-fire the host open hook
///     (double-spawn / orphaned-PTY leak).
///   • [4] a `channelClose` arriving BEFORE `setHostCloseHandler` must be BUFFERED + replayed
///     (else the pane's shell leaks — the open path buffered, the close path used to drop).
///   • [5] a HARD link failure must mark the connection `isDead` and make `openChannel` reject reuse
///     (so a reconnecting pane never opens onto a corpse the registry still pools).
final class MuxBugFixRegressionTests: XCTestCase {

    // MARK: - [3] duplicate channelOpen does not double-fire the host open hook

    func testDuplicateChannelOpenFiresHostOpenHandlerExactlyOnce() async throws {
        let (_, hostControl) = InMemoryMuxLink.pair()
        let (clientData, hostData) = InMemoryMuxLink.pair()
        let host = MuxNWConnection(role: .host, controlLink: hostControl, dataLink: hostData)

        let opens = AtomicCounter()
        await host.setHostOpenHandler { _ in opens.bump() }
        await host.start()

        // Drive TWO identical channelOpen frames for the SAME id straight onto the host's DATA link
        // (a retransmit / duplicate). The first registers + spawns; the second must be suppressed.
        let frame = MuxEnvelopeCodec.encode(
            .channelOpen(channelID: 1, sessionID: UUID(), lastReceivedSeq: 0, channelClass: 0))
        try await clientData.send(frame)
        try await clientData.send(frame)
        try await Task.sleep(for: .milliseconds(120))

        XCTAssertEqual(opens.value, 1, "a duplicate channelOpen must not re-invoke the host open hook (no double-spawn)")
    }

    // MARK: - [4] channelClose before setHostCloseHandler is buffered + replayed

    func testChannelCloseArrivingBeforeHandlerInstallIsBufferedAndReplayed() async throws {
        let (_, hostControl) = InMemoryMuxLink.pair()
        let (clientData, hostData) = InMemoryMuxLink.pair()
        let host = MuxNWConnection(role: .host, controlLink: hostControl, dataLink: hostData)
        await host.start()

        // An open then a close for the same id arrive in the accept→install gap (NO handler yet).
        try await clientData.send(MuxEnvelopeCodec.encode(
            .channelOpen(channelID: 1, sessionID: UUID(), lastReceivedSeq: 0, channelClass: 0)))
        try await clientData.send(MuxEnvelopeCodec.encode(.channelClose(channelID: 1)))
        try await Task.sleep(for: .milliseconds(80))   // let the receive loop route both frames

        // Install the handlers in production order (open first, then close): the buffered open replays
        // (would spawn the shell), then the buffered close replays (reaps it — no leaked PTY).
        let opened = AtomicList()
        let closed = AtomicList()
        await host.setHostOpenHandler { open in opened.append(open.channelID) }
        await host.setHostCloseHandler { id in closed.append(id) }

        XCTAssertEqual(opened.value, [1], "the buffered open replays when the open handler installs")
        XCTAssertEqual(closed.value, [1], "the buffered close replays when the close handler installs (no leaked shell)")
    }

    // MARK: - [5] hard link failure marks the connection dead and rejects reuse

    func testHardLinkFailureMarksConnectionDeadAndRejectsOpenChannel() async throws {
        let (clientControl, hostControl) = InMemoryMuxLink.pair()
        let (clientData, hostData) = InMemoryMuxLink.pair()
        let client = MuxNWConnection(role: .client, controlLink: clientControl, dataLink: clientData)
        let host = MuxNWConnection(role: .host, controlLink: hostControl, dataLink: hostData)
        await host.setHostOpenHandler { open in Task { await host.sendOpenAck(open.channelID, accepted: true) } }
        await client.start()
        await host.start()

        _ = try await client.openChannel(sessionID: UUID(), lastReceivedSeq: 0)
        let liveBefore = await client.isDead
        XCTAssertFalse(liveBefore, "a freshly-opened connection is not dead")

        // Simulate a TCP RST / NetBird flap on the DATA link → both ends' data receive loops error.
        clientData.fail()
        try await Self.waitUntil { await client.isDead }

        let dead = await client.isDead
        XCTAssertTrue(dead, "a hard link failure marks the connection dead (isDead)")

        do {
            _ = try await client.openChannel(sessionID: UUID(), lastReceivedSeq: 0)
            XCTFail("openChannel must reject a dead (link-failed) connection")
        } catch {
            // expected — a reconnecting pane must not open onto the corpse
        }
    }

    // MARK: - helpers

    /// Polls `condition` (an async predicate) until true or the timeout elapses.
    static func waitUntil(timeout: TimeInterval = 2, _ condition: @Sendable () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("waitUntil timed out")
    }
}

/// A trivial thread-safe counter usable from `@Sendable` hooks (the host open hook fires off-actor).
final class AtomicCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}

/// A thread-safe ordered list usable from `@Sendable` hooks.
final class AtomicList: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [UInt32] = []
    func append(_ x: UInt32) { lock.lock(); items.append(x); lock.unlock() }
    var value: [UInt32] { lock.lock(); defer { lock.unlock() }; return items }
}
