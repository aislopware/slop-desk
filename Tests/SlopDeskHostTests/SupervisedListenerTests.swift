import Darwin
import Foundation
import SlopDeskSupervisor
import XCTest
@testable import SlopDeskHost

/// The child-facing listeners, end to end through a real `slopdesk-superd`.
///
/// These are the tests that could not be written before `docs/51` §7. hostd used to bind the hook
/// socket at `$TMPDIR/slopdesk-agent-<pid>.sock`, so "the address outlives hostd" was not a property
/// anything could assert — it was false by construction, and the symptom was silent: a running
/// `claude` kept POSTing to a socket nobody was listening on and detection quietly fell back to the
/// screen engine.
///
/// Now superd binds, hostd claims, and each accepted connection arrives as an `SCM_RIGHTS`
/// descriptor. Every test below drives a real daemon and a real socket; they skip, by name, when
/// superd is not built (`make superd`).
final class SupervisedListenerTests: XCTestCase {
    /// A record posted to superd's hook socket reaches the pane's sink in hostd.
    ///
    /// The whole path in one assertion: superd accepts, frames a `connection` push with the
    /// descriptor, hostd's supervisor client hands it to the ``AgentHookListener``, the drain reads
    /// it, and the router finds the pane by its `pane=` header.
    func testAHookRecordPostedToSuperdReachesThePanesSink() throws {
        let superd = try SuperdFixture()
        let listener = AgentHookListener()
        defer { listener.stop() }

        let arrived = expectation(description: "the record reached the pane's sink")
        let received = Payload()
        listener.register(paneID: "pane-1") { json in
            received.store(json)
            arrived.fulfill()
        }
        try claim(hookOn: superd.client, servedBy: listener)

        let address = try XCTUnwrap(superd.client.hookSocketPath, "hello must carry the hook path")
        try post(Data("pane=pane-1\n{\"hook_event_name\":\"Stop\"}\n".utf8), to: address)

        wait(for: [arrived], timeout: 5)
        XCTAssertEqual(
            received.text,
            "{\"hook_event_name\":\"Stop\"}",
            "the header line is stripped and the JSON arrives byte-for-byte",
        )
    }

    /// **The product promise.** The hostd that claimed the listener dies; the address does not, and
    /// the next hostd picks up records at the same one.
    ///
    /// A running agent holds that path in an environment taken at `execve` which nothing can ever
    /// rewrite — so this is not a convenience, it is the only way a `claude` mid-task keeps its
    /// authoritative feed across a hostd rebuild.
    func testTheHookAddressOutlivesTheHostdThatClaimedIt() throws {
        let superd = try SuperdFixture()
        let address = try XCTUnwrap(superd.client.hookSocketPath)

        // Life one claims, then goes away exactly as a rebuilt hostd does — connection closed, panes
        // untouched.
        let first = SupervisorClient(socketPath: superd.socketPath)
        try first.connect(clientName: "hostd-life-1")
        let firstListener = AgentHookListener()
        try claim(hookOn: first, servedBy: firstListener)
        XCTAssertTrue(firstListener.isListening)
        first.disconnect()
        firstListener.stop()

        // Life two comes up at the same address and claims it back.
        let second = SupervisorClient(socketPath: superd.socketPath)
        try second.connect(clientName: "hostd-life-2")
        defer { second.disconnect() }
        let secondListener = AgentHookListener()
        defer { secondListener.stop() }

        let arrived = expectation(description: "life two received the record")
        secondListener.register(paneID: "pane-1") { _ in arrived.fulfill() }
        try claim(hookOn: second, servedBy: secondListener)

        XCTAssertEqual(
            second.hookSocketPath,
            address,
            "the address a live agent remembers must be the one the new hostd serves",
        )
        try post(Data("pane=pane-1\n{}\n".utf8), to: address)
        // The assertion is that the record ARRIVES, not how fast — the listener's accept loop is a
        // thread competing with the whole suite. A short wait here measures machine load and fails
        // on it; this bounds a hang instead.
        wait(for: [arrived], timeout: 30)
    }

    /// With no hostd claiming, a connection is accepted and closed AT ONCE.
    ///
    /// Not queued, and not held for the hostd that is coming back. The peer is Claude Code's hook
    /// binary, which blocks its agent until its write completes, so a fast EOF is kinder than a wait
    /// — and the record it loses is recoverable by design, because detection revokes coverage on a
    /// stale authoritative feed and the screen engine takes over (`docs/50`).
    ///
    /// The assertion is the timing: the peer's read returns EOF well inside a window that a queue
    /// would blow through.
    func testAnUnclaimedConnectionIsClosedAtOnceRatherThanQueued() throws {
        let superd = try SuperdFixture()
        let address = try XCTUnwrap(superd.client.hookSocketPath)
        // Nobody has sent `listen`, so the fixture's own client is not serving anything.

        let closed = expectation(description: "the peer saw EOF")
        let socketAddress = address
        DispatchQueue.global().async { [self] in
            try? post(Data("pane=nobody\n{}\n".utf8), to: socketAddress, awaitClose: true)
            closed.fulfill()
        }
        wait(for: [closed], timeout: 2)
    }

    /// A claim for a listener superd does not have is REFUSED, not silently ignored.
    ///
    /// Rule 3 of the skew contract cuts the other way here: hostd must be able to tell "superd is
    /// serving this for me" from "superd shrugged", because the difference decides whether it may
    /// let superd advertise the address to a child.
    func testAnUnknownListenerKindIsRefused() throws {
        let superd = try SuperdFixture()
        XCTAssertThrowsError(try superd.client.listen(kinds: ["inspector"])) { error in
            guard case SupervisorClient.ClientError.refused = error else {
                XCTFail("an unknown kind must be refused, not \(error)")
                return
            }
        }
    }

    // MARK: Helpers

    /// Claims the hook listener on `client` and routes its connections into `listener`.
    private func claim(hookOn client: SupervisorClient, servedBy listener: AgentHookListener) throws {
        client.onConnection = { kind, descriptor in
            guard kind == SupervisorProtocol.ListenerKind.hook else {
                close(descriptor)
                return
            }
            listener.serve(connection: descriptor)
        }
        try client.listen(kinds: [SupervisorProtocol.ListenerKind.hook])
        listener.markServing(true)
    }

    /// Connects to `path`, writes `record`, and half-closes — the installed hook's exact shape.
    ///
    /// - Parameter awaitClose: also block until the far end closes, which is what the hook binary
    ///   does and therefore what its agent is waiting on.
    private func post(_ record: Data, to path: String, awaitClose: Bool = false) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        try XCTSkipIf(fd < 0, "socket() failed: \(errno)")
        defer { close(fd) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let maxPath = MemoryLayout.size(ofValue: address.sun_path) - 1
        _ = withUnsafeMutablePointer(to: &address.sun_path) { raw in
            path.withCString { text in
                strncpy(UnsafeMutableRawPointer(raw).assumingMemoryBound(to: CChar.self), text, maxPath)
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let joined = withUnsafePointer(to: &address) { raw in
            raw.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, size) }
        }
        XCTAssertEqual(joined, 0, "connect to \(path) failed: \(errno)")

        _ = record.withUnsafeBytes { buffer in write(fd, buffer.baseAddress, buffer.count) }
        shutdown(fd, SHUT_WR) // EOF for hostd's drain
        guard awaitClose else { return }
        var sink = [UInt8](repeating: 0, count: 64)
        while read(fd, &sink, sink.count) > 0 {}
    }

    /// What the sink saw. The sink runs off the test's thread, so this is lock-guarded.
    private final class Payload: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes = Data()

        func store(_ value: Data) {
            lock.lock()
            bytes = value
            lock.unlock()
        }

        var text: String {
            lock.lock()
            defer { lock.unlock() }
            return String(bytes: bytes, encoding: .utf8) ?? ""
        }
    }
}
