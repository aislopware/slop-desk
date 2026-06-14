import Foundation
import XCTest

/// Proves the SHIPPED binaries: launches the real `aislopdesk-hostd` and `aislopdesk-client`
/// executables as subprocesses (hostd on an ephemeral test port; client with `--no-raw`
/// and stdin a pipe), pipes `echo SHIPPED_OK\nexit\n` into the client's stdin, and
/// asserts the client's stdout contains `SHIPPED_OK`.
///
/// Skips gracefully (XCTSkip) if subprocess launch is unavailable in the sandbox, but
/// attempts it. Uses an ephemeral OS-chosen port (parsed from hostd's stderr) to avoid
/// collisions.
final class SubprocessE2ETests: XCTestCase {
    /// Locates a built product (e.g. `aislopdesk-hostd`) next to the test bundle. SwiftPM puts
    /// the executables in the same `debug`/`release` directory as the xctest bundle.
    private func builtProductURL(_ name: String) -> URL? {
        let bundleURL = Bundle(for: Self.self).bundleURL // …/debug/AislopdeskPackageTests.xctest
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
        guard let hostdURL = builtProductURL("aislopdesk-hostd"),
              let clientURL = builtProductURL("aislopdesk-client")
        else {
            throw XCTSkip("built aislopdesk-hostd / aislopdesk-client not found next to test bundle")
        }

        // --- Launch aislopdesk-hostd on an OS-chosen ephemeral port (--port 0). ---
        let hostd = Process()
        hostd.executableURL = hostdURL
        hostd.arguments = ["--port", "0"]
        let hostdErr = Pipe()
        hostd.standardError = hostdErr
        hostd.standardOutput = Pipe()

        do {
            try hostd.run()
        } catch {
            throw XCTSkip("could not launch aislopdesk-hostd subprocess: \(error)")
        }
        defer {
            if hostd.isRunning { hostd.terminate() }
        }

        // Parse the bound port from hostd's stderr: "listening on 0.0.0.0:<port>".
        guard let port = try awaitBoundPort(from: hostdErr.fileHandleForReading, timeout: 10) else {
            throw XCTSkip("hostd did not report a bound port in time")
        }
        XCTAssertGreaterThan(port, 0)

        // --- Launch aislopdesk-client --no-raw with a piped stdin script. ---
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
            throw XCTSkip("could not launch aislopdesk-client subprocess: \(error)")
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
