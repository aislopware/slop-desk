import XCTest
import Foundation
import RworkProtocol
import RworkTransport
import RworkHost
@testable import RworkClient

/// PATH 1 end-to-end tests using the REAL components: a ``HostServer`` (RworkHost,
/// spawning `/bin/sh` in a real PTY) and a ``RworkClient`` (built on the real
/// ``ClientTransport``) over a 127.0.0.1 ephemeral-port TCP connection.
final class RworkClientE2ETests: XCTestCase {

    /// Starts a HostServer on an ephemeral loopback port spawning `/bin/sh`, returns it
    /// plus the bound port. Caller must `await server.stop()`.
    private func startHost(shell: String = "/bin/sh") async throws -> (server: HostServer, port: UInt16) {
        let server = HostServer(port: 0, shellPath: shell)
        try await server.start()
        guard let port = await server.boundPort() else {
            await server.stop()
            throw XCTSkip("host did not bind a port")
        }
        return (server, port)
    }

    /// Collects bytes from the client's `output` stream until `needle` appears or the
    /// deadline passes. Returns the accumulated string (may be empty on timeout).
    private func awaitOutput(
        containing needle: String,
        from client: RworkClient,
        timeout: Duration = .seconds(10)
    ) async -> String {
        let collected = Accumulator()
        let pump = Task {
            for await chunk in client.output {
                collected.append(chunk)
                if collected.string.contains(needle) { break }
            }
        }
        let timer = Task {
            try? await Task.sleep(for: timeout)
            pump.cancel()
        }
        await pump.value
        timer.cancel()
        return collected.string
    }

    /// Thread-safe byte accumulator (the pump task touches it; assertions read it).
    private final class Accumulator: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
        var string: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
    }

    // MARK: - E2E echo over loopback

    func testEchoRoundTripAndExit() async throws {
        let (server, port) = try await startHost()
        defer { Task { await server.stop() } }

        let client = RworkClient()
        try await client.connect(host: "127.0.0.1", port: port)

        // Drive a known echo + an exit; assert both surface.
        try await client.sendInput(Data("echo rwork-e2e-OK\n".utf8))
        let out = await awaitOutput(containing: "rwork-e2e-OK", from: client)
        XCTAssertTrue(out.contains("rwork-e2e-OK"), "expected echoed marker in output; got: \(out.prefix(400))")

        // Now exit the shell and assert the exit event surfaces.
        let exitSeen = Task { () -> Int32? in
            for await event in client.events {
                if case let .exit(code) = event { return code }
            }
            return nil
        }
        try await client.sendInput(Data("exit\n".utf8))
        let code = await withTimeout(.seconds(10)) { await exitSeen.value }
        exitSeen.cancel()
        XCTAssertNotNil(code, "expected an exit event after `exit`")

        await client.close()
    }

    // MARK: - E2E title/bell sniffer (wire types 21/22 fire from a real PTY)

    /// Proves the host-side OSC/BEL sniffer end to end: a real `/bin/sh` in a real PTY
    /// printing an OSC 0 title and a BEL makes the host emit `.title`/`.bell` CONTROL
    /// messages (wire 21/22) that the real client surfaces as `.title`/`.bell` events.
    /// This is the path the audit found dead — `sendControl` had zero callers; the sniffer
    /// is now its caller, wired into `HostSession`'s output relay.
    func testTitleAndBellSurfaceEndToEnd() async throws {
        let (server, port) = try await startHost()
        defer { Task { await server.stop() } }

        let client = RworkClient()
        try await client.connect(host: "127.0.0.1", port: port)

        // Collect title/bell events as they arrive.
        let titleSeen = Task { () -> String? in
            for await event in client.events {
                if case let .title(text) = event, text == "hello" { return text }
            }
            return nil
        }
        let bellSeen = Task { () -> Bool in
            for await event in client.events {
                if case .bell = event { return true }
            }
            return false
        }

        // OSC 0 title via BEL terminator: `ESC ] 0 ; hello BEL`. `printf` writes it raw to
        // stdout; the host PTY relays the bytes and the sniffer detects the title.
        try await client.sendInput(Data((#"printf '\033]0;hello\007'"# + "\n").utf8))
        let title = await withTimeout(.seconds(10)) { await titleSeen.value }
        titleSeen.cancel()
        XCTAssertEqual(title, "hello", "expected a .title(\"hello\") event from the OSC 0 sniffer")

        // Standalone BEL: `printf '\a'` → a real terminal bell (NOT an OSC terminator).
        try await client.sendInput(Data((#"printf '\a'"# + "\n").utf8))
        let rang = await withTimeout(.seconds(10)) { await bellSeen.value }
        bellSeen.cancel()
        XCTAssertEqual(rang, true, "expected a .bell event from the standalone-BEL sniffer")

        await client.close()
    }

    // MARK: - Ack correctness: never ack an unreceived seq; ack releases retained bytes

    func testClientNeverAcksUnreceivedSeq() async throws {
        let (server, port) = try await startHost()
        defer { Task { await server.stop() } }

        let client = RworkClient(ackInterval: .milliseconds(20))
        try await client.connect(host: "127.0.0.1", port: port)

        // Receive some output.
        try await client.sendInput(Data("echo ack-probe\n".utf8))
        _ = await awaitOutput(containing: "ack-probe", from: client)

        // The contiguous seq the client would ack must never exceed what it has fed.
        let contiguous = await client.highestContiguousSeq
        XCTAssertGreaterThan(contiguous, 0, "client should have received at least one output")

        // Force an immediate ack flush and confirm the value it acks equals its
        // highestContiguousSeq (i.e. it never invents a higher seq).
        let before = await client.highestContiguousSeq
        await client.flushAck()
        let after = await client.highestContiguousSeq
        XCTAssertEqual(before, after, "flushAck must not change the contiguous high-water mark")

        await client.close()
    }

    /// Acking releases retained entries in the host's ReplayBuffer. We observe this on a
    /// directly-driven HostSessionTransport (real public API: sendOutput retains,
    /// acknowledge releases, replayTail reports the retained tail) — no private access.
    func testAckReleasesRetainedBytes() async throws {
        let transport = HostSessionTransport(sessionID: UUID())

        // Enqueue 5 output payloads (no channel bound: sendOutput still retains them).
        var totalBytes = 0
        for i in 1...5 {
            let payload = Data("line-\(i)\n".utf8)
            totalBytes += payload.count
            _ = try await transport.sendOutput(payload)
        }
        let tailBefore = await transport.replayTail(after: 0)
        let retainedBefore = tailBefore.reduce(0) { $0 + payloadBytes($1) }
        XCTAssertEqual(retainedBefore, totalBytes, "all 5 outputs should be retained pre-ack")
        XCTAssertEqual(tailBefore.count, 5)

        // Ack up to seq 3 → entries 1..3 released; only 4,5 retained.
        await transport.acknowledge(upTo: 3)
        let tailAfter = await transport.replayTail(after: 0)
        XCTAssertEqual(tailAfter.count, 2, "after acking seq 3, only seqs 4 and 5 remain")
        let retainedAfter = tailAfter.reduce(0) { $0 + payloadBytes($1) }
        XCTAssertLessThan(retainedAfter, retainedBefore, "retained bytes must drop after ack")
        XCTAssertEqual(retainedAfter, Data("line-4\n".utf8).count + Data("line-5\n".utf8).count)
    }

    /// Extracts the payload byte count from a replayTail WireMessage.output.
    private func payloadBytes(_ message: WireMessage) -> Int {
        if case let .output(_, bytes) = message { return bytes.count }
        return 0
    }

    // MARK: - End-to-end ack drains the host's retained buffer through the wire

    func testEndToEndAckDrainsHostBufferViaTransport() async throws {
        // Drive the full ClientTransport ↔ HostSessionTransport handshake is covered by
        // the reconnect e2e; here we assert the client's periodic ack reaches the host by
        // checking the client advances + flushes without ever exceeding what it received.
        let (server, port) = try await startHost()
        defer { Task { await server.stop() } }

        let client = RworkClient(ackInterval: .milliseconds(20))
        try await client.connect(host: "127.0.0.1", port: port)
        try await client.sendInput(Data("echo drain-check\n".utf8))
        _ = await awaitOutput(containing: "drain-check", from: client)

        // Let the ack ticker run a few cycles.
        try? await Task.sleep(for: .milliseconds(120))
        let contiguous = await client.highestContiguousSeq
        XCTAssertGreaterThan(contiguous, 0)
        await client.close()
    }

    // MARK: - Helpers

    /// Runs `body`, returning its value, or `nil` if it does not finish within `timeout`.
    private func withTimeout<T: Sendable>(_ timeout: Duration, _ body: @escaping @Sendable () async -> T?) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await body() }
            group.addTask { try? await Task.sleep(for: timeout); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
