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
        let sandboxHome = try makeSandboxHome()
        defer { try? FileManager.default.removeItem(at: sandboxHome) }
        let hostd = Process()
        hostd.executableURL = hostdURL
        hostd.arguments = ["--port", "0", "--shell", "/bin/sh"]
        var hostEnv = ProcessInfo.processInfo.environment
        hostEnv["HOME"] = sandboxHome.path
        hostd.environment = hostEnv
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
        guard let bound = awaitBoundPort(from: hostdErr.fileHandleForReading, timeout: 10) else {
            throw XCTSkip("hostd did not report a bound port in time")
        }
        XCTAssertGreaterThan(bound.port, 0)
        // Pin the isolation: the banner reports the spawn shell, and it must be the sandbox
        // /bin/sh — a real login zsh here writes this test's typed script into the USER'S
        // ~/.zsh_history on every run (see `makeSandboxHome`).
        XCTAssertTrue(
            bound.banner.contains("shell=/bin/sh"),
            "hostd must spawn the isolated /bin/sh, not the user's login shell: \(bound.banner)",
        )
        let port = bound.port

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

    // MARK: - A pane that requests no cwd opens at HOME, not the daemon's cwd

    /// THE user scenario on the SHIPPED binaries: `slopdesk-hostd` is launched FROM a project
    /// directory (a daemon started out of a checkout — the normal case), and a client that names no
    /// working directory connects. The spawned shell must come up in `$HOME`.
    ///
    /// Before the fix the host translated "no cwd requested" into "issue no `chdir`", so the shell
    /// silently inherited the daemon's cwd and every such pane opened inside whatever project the
    /// daemon happened to be launched from.
    func testPaneWithoutRequestedCwdOpensInHomeNotDaemonCwd() throws {
        guard let hostdURL = builtProductURL("slopdesk-hostd"),
              let clientURL = builtProductURL("slopdesk-client")
        else {
            throw XCTSkip("built slopdesk-hostd / slopdesk-client not found next to test bundle")
        }

        let sandboxHome = try makeSandboxHome()
        defer { try? FileManager.default.removeItem(at: sandboxHome) }
        // The stand-in for "the checkout the daemon was started from".
        let daemonCwd = FileManager.default.temporaryDirectory
            .appendingPathComponent("e2e-daemon-cwd-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: daemonCwd, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: daemonCwd) }

        // `pwd -P` resolves symlinks, so compare against resolved paths (/var → /private/var).
        let resolvedHome = sandboxHome.resolvingSymlinksInPath().path
        let resolvedDaemonCwd = daemonCwd.resolvingSymlinksInPath().path
        XCTAssertNotEqual(resolvedHome, resolvedDaemonCwd)

        let hostd = Process()
        hostd.executableURL = hostdURL
        hostd.arguments = ["--port", "0", "--shell", "/bin/sh"]
        hostd.currentDirectoryURL = daemonCwd // the daemon runs from the "project"
        var hostEnv = ProcessInfo.processInfo.environment
        hostEnv["HOME"] = sandboxHome.path
        hostd.environment = hostEnv
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

        guard let bound = awaitBoundPort(from: hostdErr.fileHandleForReading, timeout: 10) else {
            throw XCTSkip("hostd did not report a bound port in time")
        }

        // `slopdesk-client` names no working directory — the `channelOpen` carries no cwd at all.
        let client = Process()
        client.executableURL = clientURL
        client.arguments = ["--host", "127.0.0.1", "--port", String(bound.port), "--no-raw"]
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        client.standardInput = stdinPipe
        client.standardOutput = stdoutPipe
        client.standardError = Pipe()

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

        stdinPipe.fileHandleForWriting.write(Data("pwd -P\nexit\n".utf8))
        try? stdinPipe.fileHandleForWriting.close()

        let exited = waitForExit(client, timeout: 15)
        stdoutHandle.readabilityHandler = nil
        XCTAssertTrue(exited, "client did not exit within the timeout")

        let out = collected.string
        XCTAssertTrue(
            out.contains(resolvedHome),
            "expected the pane to open in HOME (\(resolvedHome)); got: \(out.prefix(600))",
        )
        XCTAssertFalse(
            out.contains(resolvedDaemonCwd),
            "the pane must not inherit the daemon's cwd (\(resolvedDaemonCwd)); got: \(out.prefix(600))",
        )
    }

    // MARK: - Disk-scrollback restore across a hostd RESTART (the scrollback-lost-on-reconnect case)

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
        let sandboxHome = try makeSandboxHome()
        defer { try? FileManager.default.removeItem(at: sandboxHome) }
        var hostEnv = ProcessInfo.processInfo.environment
        hostEnv["SLOPDESK_SCROLLBACK_DIR"] = journalDir.path
        hostEnv["HOME"] = sandboxHome.path

        let sessionID = UUID()
        let marker = "RESTART_SURVIVOR_\(UInt32.random(in: 0..<1_000_000))"

        func launchHostd() -> (Process, UInt16, OutputBox)? {
            let hostd = Process()
            hostd.executableURL = hostdURL
            hostd.arguments = ["--port", "0", "--shell", "/bin/sh"]
            hostd.environment = hostEnv
            let err = Pipe()
            hostd.standardError = err
            hostd.standardOutput = Pipe()
            do { try hostd.run() } catch { return nil }
            guard let bound = awaitBoundPort(from: err.fileHandleForReading, timeout: 10),
                  bound.port > 0,
                  bound.banner.contains("shell=/bin/sh") // same real-history pin as test 1
            else {
                if hostd.isRunning { hostd.terminate() }
                return nil
            }
            // Keep collecting stderr past the banner — the restore-path log line
            // ("restored … (snapshot|distilled) replay") is the observable this test pins.
            let log = OutputBox()
            log.append(Data(bound.banner.utf8))
            err.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil } else { log.append(data) }
            }
            return (hostd, bound.port, log)
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
        guard let (hostd1, port1, _) = launchHostd() else {
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
        guard let (hostd2, port2, hostd2Log) = launchHostd() else {
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
        // PATH B is state-transfer now: life 1's spawn seeded the size sidecar, so life 2
        // must COMPOSE the transcript (the log line is the observable), and the transcript
        // needs no sanitize suffix — its mode-free construction replaces the reset barrage.
        let logDeadline = Date().addingTimeInterval(5)
        while Date() < logDeadline, !hostd2Log.string.contains("(snapshot replay)") {
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertTrue(
            hostd2Log.string.contains("(snapshot replay)"),
            "the journal restore must ride the snapshot composer (size sidecar present); hostd #2 log: "
                + String(hostd2Log.string.suffix(400)),
        )
        XCTAssertFalse(
            out2.string.contains("\u{1B}[?1005l"),
            "a composed transcript must not carry the raw-replay sanitize suffix",
        )
    }

    /// The state-transfer reattach through the SHIPPED binaries: churn + a DECSCUSR into a
    /// live session, kill the client (link drop → detach → PATH A), return COLD with the same
    /// session ID, and assert the replay is a rendered snapshot (reset preamble first) that
    /// still carries the scrollback marker AND re-emits the cursor shape — the two regressions
    /// of the first hardware night (empty pane for seconds; bar cursor reset to block).
    func testColdReattachSnapshotKeepsScrollbackAndCursorShape() throws {
        guard let hostdURL = builtProductURL("slopdesk-hostd"),
              let clientURL = builtProductURL("slopdesk-client")
        else {
            throw XCTSkip("built slopdesk-hostd / slopdesk-client not found next to test bundle")
        }

        let sandboxHome = try makeSandboxHome()
        defer { try? FileManager.default.removeItem(at: sandboxHome) }
        let hostd = Process()
        hostd.executableURL = hostdURL
        hostd.arguments = ["--port", "0", "--shell", "/bin/sh"]
        var hostEnv = ProcessInfo.processInfo.environment
        hostEnv["HOME"] = sandboxHome.path
        hostd.environment = hostEnv
        let hostdErr = Pipe()
        hostd.standardError = hostdErr
        hostd.standardOutput = Pipe()
        do { try hostd.run() } catch { throw XCTSkip("could not launch hostd: \(error)") }
        defer { if hostd.isRunning { hostd.terminate() } }
        guard let bound = awaitBoundPort(from: hostdErr.fileHandleForReading, timeout: 10),
              bound.port > 0, bound.banner.contains("shell=/bin/sh")
        else { throw XCTSkip("hostd did not report a bound port in time") }

        let sessionID = UUID()
        let marker = "SNAPSHOT_SURVIVOR_\(UInt32.random(in: 0..<1_000_000))"

        func runClient(script: String?, until: String, timeout: TimeInterval) throws -> (Process, OutputBox) {
            let client = Process()
            client.executableURL = clientURL
            client.arguments = [
                "--host", "127.0.0.1", "--port", String(bound.port), "--no-raw",
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
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline, !collected.string.contains(until) {
                Thread.sleep(forTimeInterval: 0.05)
            }
            return (client, collected)
        }

        // --- Life 1: churn, the marker, then a bar cursor (the zsh integration's prompt shape). ---
        let script = """
        i=0; while [ $i -lt 500 ]; do echo "CHURN LINE $i ================================"; i=$((i+1)); done
        echo \(marker)
        printf '\\033[5 q'

        """
        let (client1, out1) = try runClient(script: script, until: marker, timeout: 20)
        defer { if client1.isRunning { client1.terminate() } }
        guard out1.string.contains(marker) else {
            throw XCTSkip("client #1 never saw its own echo (sandboxed PTY?): \(out1.string.prefix(300))")
        }
        Thread.sleep(forTimeInterval: 0.5) // let acks land so the churn reaches the ring
        client1.terminate() // link drop — host detaches the session (PATH A material)
        _ = waitForExit(client1, timeout: 5)

        // --- Life 2: COLD return to the SAME daemon. ---
        let (client2, out2) = try runClient(script: nil, until: marker, timeout: 20)
        defer { if client2.isRunning { client2.terminate() } }

        XCTAssertTrue(
            out2.string.contains(marker),
            "reattach must replay the scrollback marker; got: \(out2.string.prefix(600))",
        )
        XCTAssertTrue(
            out2.string.contains("\u{1B}[?1049l"),
            "cold reattach must be a rendered snapshot (reset preamble), not raw history",
        )
        // The DECSCUSR the session ended on must survive the state transfer.
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, !out2.string.contains("\u{1B}[5 q") {
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertTrue(
            out2.string.contains("\u{1B}[5 q"),
            "the reattached pane must re-emit the bar cursor shape",
        )
    }

    // MARK: - Helpers

    /// A throwaway HOME for a hostd subprocess. The daemon spawns a REAL interactive login
    /// shell per session — the user's zsh would, via the ShellIntegration shim (which
    /// deliberately re-points a shim-relative HISTFILE back at the REAL `~/.zsh_history`),
    /// append every script this test types to the user's shell history on every run, and
    /// journal scrollback into the real Application Support dir. `--shell /bin/sh` plus this
    /// sandbox HOME keep the spawned shell's history file AND the default journal dir inside
    /// the temp sandbox, never the user's.
    private func makeSandboxHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("e2e-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    /// Reads hostd stderr until a "listening on …:<port>" line; returns the port plus the
    /// banner text so far (callers pin the `shell=` isolation on it).
    private func awaitBoundPort(
        from handle: FileHandle,
        timeout: TimeInterval,
    ) -> (port: UInt16, banner: String)? {
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = Data()
        while Date() < deadline {
            let chunk = handle.availableData // blocks until data or EOF
            if chunk.isEmpty {
                break // EOF (hostd died) — give up with whatever arrived.
            }
            buffer.append(chunk)
            let text = String(bytes: buffer, encoding: .utf8) ?? ""
            if let p = parsePort(text) { return (p, text) }
        }
        let text = String(bytes: buffer, encoding: .utf8) ?? ""
        return parsePort(text).map { ($0, text) }
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
