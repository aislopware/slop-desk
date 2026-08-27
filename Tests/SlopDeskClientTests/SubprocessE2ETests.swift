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
        let hostEnv = try sandboxHostEnvironment(home: sandboxHome)
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
        let stderrPipe = Pipe()
        client.standardInput = stdinPipe
        client.standardOutput = stdoutPipe
        // Collected, not discarded. This assertion has failed with an EMPTY stdout, and an empty
        // stdout says nothing about WHY: the client's own complaint went to a pipe nobody read, so
        // the one artefact that could name the cause was thrown away on every failing run.
        client.standardError = stderrPipe

        // Collect the client's stdout off-thread so a full pipe never deadlocks the child.
        let collected = OutputBox()
        let complaints = OutputBox()
        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading
        stdoutHandle.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                collected.append(data)
            }
        }
        stderrHandle.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                complaints.append(data)
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
        XCTAssertTrue(exited, "client did not exit within the timeout")

        // A process that has exited is NOT a pipe that has been drained. The readability handler
        // runs on a background queue, so bytes written just before exit can still be sitting in the
        // pipe with no dispatch yet delivered — and clearing the handler first threw them away.
        // Give the handlers a bounded moment to catch up before reading the accumulators.
        let drainDeadline = Date().addingTimeInterval(2)
        while collected.string.isEmpty, Date() < drainDeadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        stdoutHandle.readabilityHandler = nil
        stderrHandle.readabilityHandler = nil

        let out = collected.string
        let errors = complaints.string
        XCTAssertTrue(
            out.contains("SHIPPED_OK"),
            """
            expected SHIPPED_OK in the client's stdout
            exit status: \(client.terminationStatus), reason: \(client.terminationReason.rawValue)
            stdout: \(out.prefix(600))
            stderr: \(errors.prefix(600))
            """,
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
        let hostEnv = try sandboxHostEnvironment(home: sandboxHome)
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
        var hostEnv = try sandboxHostEnvironment(home: sandboxHome)
        // This test's SUBJECT is a journal that outlives the daemon, so its two hostds share one
        // journal dir OUTSIDE either sandbox home. The per-file override wins over the container.
        hostEnv["SLOPDESK_SCROLLBACK_DIR"] = journalDir.path
        // ...and each life gets its OWN superd, which is what makes this the journal's scenario at
        // all. Sharing one custodian would mean the pane SURVIVED (`docs/51`), hostd #2 would adopt
        // it and reattach, and the disk journal would never be consulted — the feature working, but
        // not the feature under test. A dead custodian is superd's own death case: it takes every
        // pane with it, so life 2 comes up cold, which is exactly a reboot.
        var life2Env = hostEnv
        if let socket = try startPrivateSuperd() {
            life2Env[superdSocketEnvKey] = socket
        }

        let sessionID = UUID()
        let marker = "RESTART_SURVIVOR_\(UInt32.random(in: 0..<1_000_000))"

        func launchHostd(_ environment: [String: String]) -> (Process, UInt16, OutputBox)? {
            let hostd = Process()
            hostd.executableURL = hostdURL
            hostd.arguments = ["--port", "0", "--shell", "/bin/sh"]
            hostd.environment = environment
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
        guard let (hostd1, port1, _) = launchHostd(hostEnv) else {
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
        guard let (hostd2, port2, hostd2Log) = launchHostd(life2Env) else {
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
        let hostEnv = try sandboxHostEnvironment(home: sandboxHome)
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

        // --- Life 1: churn, the marker, a shell-prompt mark, then a bar cursor (the zsh
        // integration's prompt shape). `/bin/sh` ships no shell integration, so the OSC 133 `A`
        // is emitted by hand — it is the same byte sequence a real integration sends.
        let script = """
        i=0; while [ $i -lt 500 ]; do echo "CHURN LINE $i ================================"; i=$((i+1)); done
        echo \(marker)
        printf '\\033]133;A\\007'
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
        // The PROMPT MARKS must survive too, and for a harder reason than the cursor shape: they
        // paint nothing, so a snapshot that drops them looks perfect and leaves the reattached
        // terminal with zero prompt ROWS — which is what `jump_to_prompt` counts, so every
        // command-ladder / navigator / jump-to-failed jump silently lands nowhere.
        XCTAssertTrue(
            out2.string.contains("\u{1B}]133;A"),
            "the state transfer must re-emit the shell-prompt marks, not just the text",
        )
    }

    // MARK: - Two clients, one PTY (the fan-out gate)

    /// THE Phase-6 gate, on the SHIPPED binaries with a REAL PTY: two `slopdesk-client`
    /// processes present the SAME `--session-id` to one `slopdesk-hostd`, and both watch the
    /// same shell. A marker typed into client A's stdin AFTER client B joined must appear in
    /// BOTH stdouts.
    ///
    /// The in-memory loopback provably misses open-order races (CLAUDE.md), so this is the only
    /// acceptable evidence for the fan-out: B's `channelOpen` lands against a LIVE session whose
    /// drain is already running, which is exactly the window a loopback harness cannot create.
    ///
    /// The environment carries no fan-out setting of any kind: sharing a pane is what a host does,
    /// so B joining is the plain default rather than a configuration this test arranges. The
    /// companion claim — that the join forks no SECOND shell — is
    /// `testASecondClientJoinsTheLiveSessionAndForksNoSecondShell`.
    func testTwoClientsShareOneRealPTY() throws {
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
        hostd.environment = try sandboxHostEnvironment(home: sandboxHome)
        let hostdErr = Pipe()
        hostd.standardError = hostdErr
        hostd.standardOutput = Pipe()
        do { try hostd.run() } catch { throw XCTSkip("could not launch hostd: \(error)") }
        defer { if hostd.isRunning { hostd.terminate() } }
        guard let bound = awaitBoundPort(from: hostdErr.fileHandleForReading, timeout: 10),
              bound.port > 0, bound.banner.contains("shell=/bin/sh")
        else { throw XCTSkip("hostd did not report a bound port in time") }

        let sessionID = UUID()
        let joinMarker = "FANOUT_JOINED_\(UInt32.random(in: 0..<1_000_000))"
        let sharedMarker = "FANOUT_SHARED_\(UInt32.random(in: 0..<1_000_000))"

        // Launches one shipped client on the SHARED session id and keeps its stdin open — both
        // clients must stay live and keep ACKING for the whole test (credit is granted at
        // consumption, so a client that stops reading parks the host's sender).
        func launchClient() throws -> (process: Process, stdin: FileHandle, out: OutputBox) {
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
            return (client, stdinPipe.fileHandleForWriting, collected)
        }

        func wait(for text: String, in box: OutputBox, timeout: TimeInterval) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if box.string.contains(text) { return true }
                Thread.sleep(forTimeInterval: 0.05)
            }
            return box.string.contains(text)
        }

        // --- Client A takes the pane and proves the shell is live. ---
        let a = try launchClient()
        defer { if a.process.isRunning { a.process.terminate() } }
        writeToChild(a.stdin, "echo \(joinMarker)\n")
        guard wait(for: joinMarker, in: a.out, timeout: 20) else {
            throw XCTSkip("client A never saw its own echo (sandboxed PTY?): \(a.out.string.prefix(300))")
        }

        // --- Client B JOINS the live session (no detach, no reattach — A is still here). ---
        let b = try launchClient()
        defer { if b.process.isRunning { b.process.terminate() } }
        // B is cold, so the host state-transfers the screen: the rendered snapshot carries the
        // marker A already printed. Seeing it is how we know B is attached and draining.
        XCTAssertTrue(
            wait(for: joinMarker, in: b.out, timeout: 20),
            "client B must join the LIVE session and receive its state transfer; got: "
                + "\(b.out.string.prefix(600))",
        )
        XCTAssertTrue(b.process.isRunning, "client B must stay connected, not be refused")

        // --- The fan-out itself: A types, BOTH see it. ---
        writeToChild(a.stdin, "echo \(sharedMarker)\n")
        XCTAssertTrue(
            wait(for: sharedMarker, in: a.out, timeout: 20),
            "the typing client must see its own output; got: \(a.out.string.suffix(600))",
        )
        XCTAssertTrue(
            wait(for: sharedMarker, in: b.out, timeout: 20),
            "the SECOND subscriber must receive the same PTY bytes; got: \(b.out.string.suffix(600))",
        )

        // --- Leaving is refcounted: A departs, B keeps the shell AND keeps receiving. ---
        a.process.terminate()
        _ = waitForExit(a.process, timeout: 5)
        let afterLeave = "FANOUT_SURVIVES_\(UInt32.random(in: 0..<1_000_000))"
        writeToChild(b.stdin, "echo \(afterLeave)\n")
        XCTAssertTrue(
            wait(for: afterLeave, in: b.out, timeout: 20),
            "one subscriber leaving must not stop the drain for the other; got: "
                + "\(b.out.string.suffix(600))",
        )
    }

    /// The exclusivity rule this replaces said "one attachment per sessionID, ever". What is true
    /// is narrower and it is about the SHELL, not the attachment: a second client presenting a LIVE
    /// sessionID joins the pane that exists, and the host performs exactly ONE `openpty()`/`fork()`
    /// for that id — never two.
    ///
    /// Counted from the process table, not inferred from a log line or a mock. Two shells under one
    /// sessionID is the concrete disaster the old refusal existed to prevent: two writers
    /// interleaving into one journal, and `claimJournal` rotating the incumbent's writer out
    /// mid-session. A host that answered the second open by forking again would satisfy every
    /// byte-level assertion in `testTwoClientsShareOneRealPTY` — both clients would see their own
    /// shell — and would still be broken. Only the count catches it.
    func testASecondClientJoinsTheLiveSessionAndForksNoSecondShell() throws {
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
        hostd.environment = try sandboxHostEnvironment(home: sandboxHome)
        let hostdErr = Pipe()
        hostd.standardError = hostdErr
        hostd.standardOutput = Pipe()
        do { try hostd.run() } catch { throw XCTSkip("could not launch hostd: \(error)") }
        defer { if hostd.isRunning { hostd.terminate() } }
        guard let bound = awaitBoundPort(from: hostdErr.fileHandleForReading, timeout: 10),
              bound.port > 0, bound.banner.contains("shell=/bin/sh")
        else { throw XCTSkip("hostd did not report a bound port in time") }

        let sessionID = UUID()
        let marker = "ONESHELL_INCUMBENT_\(UInt32.random(in: 0..<1_000_000))"

        func launchClient() throws -> (process: Process, stdin: FileHandle, out: OutputBox) {
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
            return (client, stdinPipe.fileHandleForWriting, collected)
        }

        func wait(for text: String, in box: OutputBox, timeout: TimeInterval) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if box.string.contains(text) { return true }
                Thread.sleep(forTimeInterval: 0.05)
            }
            return box.string.contains(text)
        }

        let a = try launchClient()
        defer { if a.process.isRunning { a.process.terminate() } }
        writeToChild(a.stdin, "echo \(marker)\n")
        guard wait(for: marker, in: a.out, timeout: 20) else {
            throw XCTSkip("client A never saw its own echo (sandboxed PTY?): \(a.out.string.prefix(300))")
        }

        // The baseline the whole test turns on: A's pane IS one forked shell, so a count of 1 here
        // is measuring the thing rather than an empty table.
        //
        // Counted under the CUSTODIAN, not under hostd. hostd does not fork — superd does, so that
        // the shell outlives a hostd restart (`docs/51`) — and the shell is therefore superd's
        // child. The companion assertion below turns that into a pin: a shell parented to hostd
        // would mean the fork window had come back.
        let afterA = shellChildren(ofParent: custodianPID)
        XCTAssertEqual(
            afterA.count, 1,
            "precondition: one client on one pane is one shell; got pids \(afterA)",
        )
        XCTAssertEqual(
            shellChildren(ofParent: hostd.processIdentifier), [],
            "hostd must fork nothing — every pane's shell belongs to superd",
        )

        let b = try launchClient()
        defer { if b.process.isRunning { b.process.terminate() } }
        // B joins rather than exiting. Asserted BEFORE the count, because a B that was refused and
        // died would leave the count at 1 and pass the real assertion vacuously.
        XCTAssertTrue(
            wait(for: marker, in: b.out, timeout: 20),
            "the second client must JOIN the live session and receive its state transfer; got: "
                + "\(b.out.string.prefix(600))",
        )
        XCTAssertTrue(b.process.isRunning, "the second client stays connected")

        // THE assertion: the join forked nothing. Same shell, same pid.
        let afterB = shellChildren(ofParent: custodianPID)
        XCTAssertEqual(
            afterB, afterA,
            "a second client on a live sessionID must join the ONE shell, not fork another — "
                + "before: \(afterA), after: \(afterB)",
        )

        // The incumbent is untouched by the join.
        let after = "ONESHELL_SURVIVOR_\(UInt32.random(in: 0..<1_000_000))"
        writeToChild(a.stdin, "echo \(after)\n")
        let deadline2 = Date().addingTimeInterval(15)
        while Date() < deadline2, !a.out.string.contains(after) { Thread.sleep(forTimeInterval: 0.05) }
        XCTAssertTrue(
            a.out.string.contains(after),
            "the join must leave the incumbent's pane working; got: \(a.out.string.suffix(600))",
        )
    }

    /// The pids of `parent`'s directly-forked `sh` children, sorted — the process table's own answer
    /// to "how many shells did the host fork".
    ///
    /// Read from `ps` rather than from anything the host reports about itself, because the failure
    /// being excluded is precisely the host being wrong about how many shells it owns. Zombies are
    /// dropped: a reaped-but-unwaited shell is not a second shell.
    ///
    /// The name is matched as `-sh` as well as `sh`: a pane's shell is spawned as a LOGIN shell, so
    /// its `argv[0]` — and therefore `comm` — carries the conventional leading hyphen.
    private func shellChildren(ofParent parent: pid_t) -> [pid_t] {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-A", "-o", "pid=,ppid=,stat=,comm="]
        let out = Pipe()
        ps.standardOutput = out
        ps.standardError = Pipe()
        guard (try? ps.run()) != nil else { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()
        var pids: [pid_t] = []
        for line in (String(data: data, encoding: .utf8) ?? "").split(separator: "\n") {
            let columns = line.split(separator: " ", omittingEmptySubsequences: true)
            guard columns.count >= 4,
                  let pid = pid_t(columns[0]),
                  let ppid = pid_t(columns[1]),
                  ppid == parent,
                  !columns[2].hasPrefix("Z"),
                  let name = columns[3].split(separator: "/").last,
                  name.drop(while: { $0 == "-" }) == "sh"
            else { continue }
            pids.append(pid)
        }
        return pids.sorted()
    }

    /// Writes to a child's stdin WITHOUT taking the process down when that child is already gone.
    /// `FileHandle.write` raises on `EPIPE`, and the default `SIGPIPE` disposition kills the test
    /// runner outright — a refused/exited client is an ordinary outcome for these tests to assert
    /// on, not a reason to lose the whole suite.
    private func writeToChild(_ handle: FileHandle, _ text: String) {
        Self.ignoreSIGPIPEOnce
        let bytes = Array(text.utf8)
        bytes.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let n = write(handle.fileDescriptor, base + offset, buffer.count - offset)
                if n > 0 {
                    offset += n
                } else {
                    if n < 0, errno == EINTR { continue }
                    return // EPIPE / EBADF — the child is gone; the assertions say what that means.
                }
            }
        }
    }

    /// Process-wide, idempotent: a `static let` runs exactly once, on first touch.
    private static let ignoreSIGPIPEOnce: Void = {
        signal(SIGPIPE, SIG_IGN)
    }()

    /// A throwaway HOME for a hostd subprocess. The daemon spawns a REAL interactive login
    /// shell per session — the user's zsh would, via superd's shell-integration shim (which
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

    /// The environment EVERY `slopdesk-hostd` spawn in this file runs with: the process environment,
    /// a sandbox `HOME`, and a container of its own — placed INSIDE that home so each test's existing
    /// `defer { removeItem(at: sandboxHome) }` takes the whole thing away.
    ///
    /// `HOME` on its own was never isolation. It does not move Application Support and does not move
    /// `NSHomeDirectory()` (Core Foundation reads the account record unless `CFFIXED_USER_HOME` is
    /// set), so these spawns resolved the DEVELOPER's `~/Library/Application Support/SlopDesk/` —
    /// wrote their PTY transcripts into it, and, because the journal sweep runs on
    /// hostd's first loop iteration and keeps only the newest 256, deleted the developer's oldest
    /// journals to make room. Measured on this host: one `swift test` left 9 of its own transcripts
    /// there and removed 6 of theirs.
    ///
    /// The full set, not just the journals: the same daemon writes `workspace-state.json` and
    /// resolves `~/Downloads` as its file-drop directory.
    private func sandboxHostEnvironment(home: URL) throws -> [String: String] {
        let container = home
            .appendingPathComponent("Library/Application Support/SlopDesk", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = home.path
        env["SLOPDESK_APP_SUPPORT_DIR"] = container.path
        env["SLOPDESK_SCROLLBACK_DIR"] = container.appendingPathComponent("scrollback").path
        env["SLOPDESK_WORKSPACE_STATE_DIR"] = container.path
        env["SLOPDESK_FILE_DROP_DIR"] = container.appendingPathComponent("drop").path
        // The daemon prewarms the shared code-server at boot; a real Node child per E2E run is a
        // multi-second boot plus a stray listener this suite must never create. The bisect
        // override doubles as the off-switch: SET but not executable resolves to "no binary"
        // (documented in `HostServiceProcess.locate`), so the prewarm silently no-ops.
        env["SLOPDESK_CODE_SERVER_BIN"] = container.appendingPathComponent("code-server-absent").path
        // The spawned hostd cannot fork a shell — nothing in Swift can (`docs/51`) — so every test
        // here that opens a pane needs a `slopdesk-superd` to ask, and it must NOT be the
        // developer's live one: this suite kills and restarts daemons freely, and a stray `release`
        // against the real custodian would end somebody's running agent. Each spawn therefore gets
        // a private daemon on a private directory, torn down with the test.
        // The key is set EITHER WAY. Omitting it would let `SupervisorPaths.controlSocket()` fall
        // back to its default path — the developer's live custodian — which is the one outcome the
        // paragraph above rules out: `swift test` and `just test-touched` do not build superd, so
        // the nil branch is the ordinary case on a working machine, not a corner.
        env[superdSocketEnvKey] = try startPrivateSuperd()
            ?? container.appendingPathComponent("superd-absent.sock").path
        return env
    }

    /// The pid of the most recent ``startPrivateSuperd()``. A spawned pane's shell is a child
    /// of THAT process, not of hostd — hostd forks nothing any more — so a test counting shells has
    /// to look under the custodian.
    private var custodianPID: pid_t = -1

    /// The env var hostd reads to find its custodian. Spelled out rather than imported: this target
    /// depends on `SlopDeskHost`, not on `SlopDeskSupervisor`, and one string is not worth widening
    /// the dependency graph of the E2E suite.
    private var superdSocketEnvKey: String { "SLOPDESK_SUPERD_SOCKET" }

    /// Boots a private `slopdesk-superd` for one spawned daemon and returns its socket path, or
    /// `nil` when the binary is not built (the caller's pane assertions then fail honestly rather
    /// than this silently pointing at the real daemon).
    ///
    /// Deliberately NOT `SuperdFixture` from `SlopDeskHostTests`: this needs no client, no
    /// handshake and no skip machinery — only a running daemon and a path to put in a child's
    /// environment. It is a subprocess-sandbox detail, which is exactly what this helper is for.
    private func startPrivateSuperd() throws -> String? {
        guard let binary = superdBinaryURL() else { return nil }

        // Short stem: `sun_path` is 104 bytes and a sandbox home would eat most of them, so the
        // daemon directory goes in `$TMPDIR` — which is why this takes no home to put it under.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sd-e2e-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let socket = directory.appendingPathComponent("slopdesk-superd.sock").path

        let daemon = Process()
        daemon.executableURL = binary
        // A MINIMAL environment, not an inherited one. superd needs its directory and a `PATH` to
        // resolve nothing in particular; inheriting would also drag in this process's own
        // `SLOPDESK_*` overrides — and would trip this file's `ProcessInfo` ratchet, which exists
        // precisely to stop a spawn reaching the developer's real container.
        daemon.environment = ["SLOPDESK_SUPERD_DIR": directory.path, "PATH": "/usr/bin:/bin"]
        try daemon.run()
        custodianPID = daemon.processIdentifier
        addTeardownBlock {
            // SIGTERM, not SIGKILL: superd's exit drops the last master fd of every pane it still
            // holds, which is how this test's shells get cleaned up rather than leaked.
            if daemon.isRunning { daemon.terminate() }
            daemon.waitUntilExit()
            try? FileManager.default.removeItem(at: directory)
        }

        // Readiness is a real connection, not the socket FILE existing. `bind(2)` creates the node
        // and `listen(2)` comes after it, so a hostd connecting in that window gets `ECONNREFUSED`
        // rather than `ENOENT` — microseconds wide, and it only ever loses under the full suite's
        // load, where the flake gets blamed on whichever test caught it.
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if Self.accepts(socket) { return socket }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return nil
    }

    /// Whether something is listening on `path` right now. Connects and hangs straight up.
    private static func accepts(_ path: String) -> Bool {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return false }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.copyBytes(from: bytes)
        }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, size) == 0 }
        }
    }

    /// `rust/slopdesk-superd/target/{release,debug}/slopdesk-superd`. `just test` builds it; a bare
    /// `swift test` may not have, and then the pane assertions fail by name rather than quietly
    /// borrowing the developer's daemon.
    private func superdBinaryURL() -> URL? {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // SlopDeskClientTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // <package root>
            .appendingPathComponent("rust/slopdesk-superd/target")
        for profile in ["release", "debug"] {
            let candidate = root.appendingPathComponent("\(profile)/slopdesk-superd")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
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

/// Every real-daemon spawn in `SubprocessE2ETests` must go through `sandboxHostEnvironment`.
///
/// This is a text contract over a sibling source file, and it is deliberate: the failure it prevents
/// is INVISIBLE from inside the suite. A `slopdesk-hostd` given only a sandbox `HOME` passes every
/// assertion in this file while journaling into the developer's real
/// `~/Library/Application Support/SlopDesk/scrollback/` and sweeping it down to `keepNewest: 256` on
/// the way. Six of the seven spawns here did exactly that, and one `swift test` cost the developer
/// six transcripts — nothing went red, because nothing was looking.
final class SubprocessE2EIsolationContractTests: XCTestCase {
    /// The suite's own source, comments stripped — the prose above `sandboxHostEnvironment` explains
    /// what a bare `ProcessInfo.processInfo.environment` costs, and must not satisfy the ban on one.
    private func codeBody() throws -> String {
        try String(contentsOf: URL(fileURLWithPath: #filePath), encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("///") }
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// REVERT-TO-FAIL: build a spawn's env from `ProcessInfo` again and this names the file.
    ///
    /// Counted rather than searched, because the helper itself needs one — a rule of "the string must
    /// not appear" would have to exempt the helper, and an exemption is a hole shaped exactly like
    /// the next offender. The needle is assembled at runtime for the same reason the fixtures assemble
    /// their secrets: written out whole it would appear in this file and count itself.
    func testNoSpawnBuildsItsEnvironmentWithoutTheSandboxContainer() throws {
        let needle = ["ProcessInfo", "processInfo", "environment"].joined(separator: ".")
        let occurrences = try codeBody().components(separatedBy: needle).count - 1
        XCTAssertEqual(
            occurrences, 1,
            "SubprocessE2ETests builds a subprocess environment from `ProcessInfo` somewhere other "
                + "than `sandboxHostEnvironment(home:)`. A hostd spawned with only a sandbox HOME "
                + "writes its scrollback journals into the DEVELOPER's Application Support and sweeps "
                + "theirs to stay under keepNewest: 256 — and every assertion in this file still passes.",
        )
    }

    /// …and the helper has to still set the whole set, not just the journals.
    func testTheSandboxEnvironmentCoversEveryContainerPath() throws {
        let code = try codeBody()
        for variable in [
            "SLOPDESK_APP_SUPPORT_DIR",
            "SLOPDESK_SCROLLBACK_DIR",
            "SLOPDESK_WORKSPACE_STATE_DIR",
            "SLOPDESK_FILE_DROP_DIR",
        ] {
            XCTAssertTrue(
                code.contains("env[\"\(variable)\"]"),
                "sandboxHostEnvironment no longer sets \(variable), so a spawned daemon reaches that "
                    + "path in the developer's own container",
            )
        }
    }
}
