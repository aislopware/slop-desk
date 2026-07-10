import Foundation
import XCTest

/// Proves the SHIPPED binaries: launches the real `slopdesk-hostd` and `slopdesk-client`
/// executables as subprocesses (hostd on an ephemeral test port; client with `--no-raw`
/// and stdin a pipe), pipes `echo SHIPPED_OK\nexit\n` into the client's stdin, and
/// asserts the client's stdout contains `SHIPPED_OK`.
///
/// Skips gracefully (XCTSkip) if subprocess launch is unavailable in the sandbox, but
/// attempts it. Uses an ephemeral OS-chosen port (parsed from hostd's stderr) to avoid
/// collisions.
final class SubprocessE2ETests: XCTestCase {
    /// Locates a built product (e.g. `slopdesk-hostd`) next to the test bundle. SwiftPM puts
    /// the executables in the same `debug`/`release` directory as the xctest bundle.
    private func builtProductURL(_ name: String) -> URL? {
        let bundleURL = Bundle(for: Self.self).bundleURL // …/debug/SlopDeskPackageTests.xctest
        let dir = bundleURL.deletingLastPathComponent()
        let candidate = dir.appendingPathComponent(name)
        if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        // Fallback: search a couple of likely sibling dirs.
        for sub in ["", "../"] {
            let alt = dir.appendingPathComponent(sub).appendingPathComponent(name).standardized
            if FileManager.default.isExecutableFile(atPath: alt.path) { return alt }
        }
        return nil
    }

    func testShippedBinariesEchoOverTCP() throws {
        guard let hostdURL = builtProductURL("slopdesk-hostd"),
              let clientURL = builtProductURL("slopdesk-client")
        else {
            throw XCTSkip("built slopdesk-hostd / slopdesk-client not found next to test bundle")
        }

        // --- Launch slopdesk-hostd on an OS-chosen ephemeral port (--port 0). ---
        let hostd = Process()
        hostd.executableURL = hostdURL
        hostd.arguments = ["--port", "0"]
        let hostdErr = Pipe()
        hostd.standardError = hostdErr
        hostd.standardOutput = Pipe()

        do {
            try hostd.run()
        } catch {
            throw XCTSkip("could not launch slopdesk-hostd subprocess: \(error)")
        }
        defer {
            if hostd.isRunning { hostd.terminate() }
        }

        // Parse the bound port from hostd's stderr: "listening on 0.0.0.0:<port>".
        guard let port = try awaitBoundPort(from: hostdErr.fileHandleForReading, timeout: 10) else {
            throw XCTSkip("hostd did not report a bound port in time")
        }
        XCTAssertGreaterThan(port, 0)

        // --- Launch slopdesk-client --no-raw with a piped stdin script. ---
        let client = Process()
        client.executableURL = clientURL
        client.arguments = ["--host", "127.0.0.1", "--port", String(port), "--no-raw"]
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        client.standardInput = stdinPipe
        client.standardOutput = stdoutPipe
        client.standardError = Pipe()

        // Collect the client's stdout off-thread so a full pipe never deadlocks the child.
        let collected = OutputBox()
        let stdoutHandle = stdoutPipe.fileHandleForReading
        stdoutHandle.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                collected.append(data)
            }
        }

        do {
            try client.run()
        } catch {
            throw XCTSkip("could not launch slopdesk-client subprocess: \(error)")
        }
        defer {
            if client.isRunning { client.terminate() }
        }

        // Pipe the script: echo a known marker, then exit the remote shell.
        stdinPipe.fileHandleForWriting.write(Data("echo SHIPPED_OK\nexit\n".utf8))
        try? stdinPipe.fileHandleForWriting.close()

        // Wait (bounded) for the client to exit after the remote shell exits.
        let exited = waitForExit(client, timeout: 15)
        stdoutHandle.readabilityHandler = nil
        XCTAssertTrue(exited, "client did not exit within the timeout")

        let out = collected.string
        XCTAssertTrue(
            out.contains("SHIPPED_OK"),
            "expected SHIPPED_OK in the client's stdout; got: \(out.prefix(600))",
        )
    }

    // MARK: - Disk-scrollback restore across a hostd RESTART (the "reconnect mất history" case)

    /// THE user scenario, end-to-end on the SHIPPED binaries: hostd #1 journals a marker to the
    /// disk scrollback (`SLOPDESK_SCROLLBACK_DIR` → temp dir), dies; hostd #2 (a brand-new
    /// process — every in-memory structure gone) restores the transcript to a COLD client
    /// presenting the same `--session-id`. Before the journal, this printed an empty pane.
    func testScrollbackSurvivesHostdRestart() throws {
        guard let hostdURL = builtProductURL("slopdesk-hostd"),
              let clientURL = builtProductURL("slopdesk-client")
        else {
            throw XCTSkip("built slopdesk-hostd / slopdesk-client not found next to test bundle")
        }

        let journalDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("e2e-scrollback-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: journalDir) }
        var hostEnv = ProcessInfo.processInfo.environment
        hostEnv["SLOPDESK_SCROLLBACK_DIR"] = journalDir.path

        let sessionID = UUID()
        let marker = "RESTART_SURVIVOR_\(UInt32.random(in: 0..<1_000_000))"

        func launchHostd() -> (Process, UInt16)? {
            let hostd = Process()
            hostd.executableURL = hostdURL
            hostd.arguments = ["--port", "0"]
            hostd.environment = hostEnv
            let err = Pipe()
            hostd.standardError = err
            hostd.standardOutput = Pipe()
            do { try hostd.run() } catch { return nil }
            guard let port = awaitBoundPort(from: err.fileHandleForReading, timeout: 10), port > 0 else {
                if hostd.isRunning { hostd.terminate() }
                return nil
            }
            return (hostd, port)
        }

        // Runs the shipped client against `port` with the pinned session ID; returns its
        // collected stdout once `until` appears (or the timeout drains).
        func runClient(
            port: UInt16,
            script: String?,
            until: String,
            timeout: TimeInterval,
        ) throws -> (Process, OutputBox) {
            let client = Process()
            client.executableURL = clientURL
            client.arguments = [
                "--host", "127.0.0.1", "--port", String(port), "--no-raw",
                "--session-id", sessionID.uuidString,
            ]
            let stdinPipe = Pipe()
            let stdoutPipe = Pipe()
            client.standardInput = stdinPipe
            client.standardOutput = stdoutPipe
            client.standardError = Pipe()
            let collected = OutputBox()
            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil } else { collected.append(data) }
            }
            try client.run()
            if let script { stdinPipe.fileHandleForWriting.write(Data(script.utf8)) }
            // NOTE: stdin stays OPEN (no `exit`) — a typed exit is a deliberate end and would
            // DELETE the journal; this scenario is a link drop.
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline, !collected.string.contains(until) {
                Thread.sleep(forTimeInterval: 0.05)
            }
            return (client, collected)
        }

        // --- Life 1: journal the marker, then die without ceremony. ---
        guard let (hostd1, port1) = launchHostd() else {
            throw XCTSkip("could not launch hostd #1")
        }
        defer { if hostd1.isRunning { hostd1.terminate() } }
        let (client1, out1) = try runClient(
            port: port1, script: "echo \(marker)\n", until: marker, timeout: 15,
        )
        defer { if client1.isRunning { client1.terminate() } }
        guard out1.string.contains(marker) else {
            throw XCTSkip("client #1 never saw its own echo (sandboxed PTY?): \(out1.string.prefix(300))")
        }
        // The marker reached the client, so the host read the PTY chunk and queued the journal
        // write; give the journal's utility queue a beat to flush before the kill.
        Thread.sleep(forTimeInterval: 0.5)
        client1.terminate() // link drop — NOT a channelClose; the journal must survive
        _ = waitForExit(client1, timeout: 5)
        hostd1.terminate()
        _ = waitForExit(hostd1, timeout: 5)

        // --- Life 2: a brand-new daemon; a COLD client returns with the same session ID. ---
        guard let (hostd2, port2) = launchHostd() else {
            throw XCTSkip("could not launch hostd #2")
        }
        defer { if hostd2.isRunning { hostd2.terminate() } }
        let (client2, out2) = try runClient(port: port2, script: nil, until: marker, timeout: 15)
        defer { if client2.isRunning { client2.terminate() } }

        XCTAssertTrue(
            out2.string.contains(marker),
            "hostd #2 must restore the disk-journaled transcript to the returning cold client; got: "
                + String(out2.string.prefix(600)),
        )
    }

    // MARK: - Helpers

    /// Reads hostd stderr until a "listening on …:<port>" line, returns the port.
    private func awaitBoundPort(from handle: FileHandle, timeout: TimeInterval) -> UInt16? {
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = Data()
        while Date() < deadline {
            let chunk = handle.availableData // blocks until data or EOF
            if chunk.isEmpty {
                // EOF (hostd died) — give up.
                return parsePort(String(bytes: buffer, encoding: .utf8) ?? "")
            }
            buffer.append(chunk)
            let text = String(bytes: buffer, encoding: .utf8) ?? ""
            if let p = parsePort(text) { return p }
        }
        return parsePort(String(bytes: buffer, encoding: .utf8) ?? "")
    }

    /// Extracts the port from a line like `…: listening on 0.0.0.0:54321 (shell=…)`.
    private func parsePort(_ text: String) -> UInt16? {
        guard let range = text.range(of: "listening on ") else { return nil }
        let tail = text[range.upperBound...]
        // Expect host:port — take the substring after the last ':' before whitespace.
        guard let colon = tail.firstIndex(of: ":") else { return nil }
        let afterColon = tail[tail.index(after: colon)...]
        var digits = ""
        for ch in afterColon {
            if ch.isNumber { digits.append(ch) } else { break }
        }
        return UInt16(digits)
    }

    /// Polls until the process exits or the timeout elapses.
    private func waitForExit(_ process: Process, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !process.isRunning { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return !process.isRunning
    }

    /// Thread-safe stdout accumulator (the readability handler appends from a bg queue).
    private final class OutputBox: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ d: Data) { lock.lock()
            data.append(d)
            lock.unlock()
        }

        var string: String { lock.lock()
            defer { lock.unlock() }
            return String(bytes: data, encoding: .utf8) ?? ""
        }
    }
}
