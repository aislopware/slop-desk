import Foundation
import SlopDeskHost
import SlopDeskSupervisor
import XCTest

/// How a unit test gets a `PTYProcess` now that hostd cannot fork one.
///
/// Two shapes, and the difference between them is the whole point.
///
/// ## `unattachedPTY()` — the overwhelming majority
/// Most of this suite never wanted a child process at all. It wants the OBJECT: the exit plumbing,
/// the fan-out bookkeeping, the teardown ladder, all driven through `completeExitForTesting`. Those
/// tests are hang-safe precisely because nothing is ever spawned, and they stay that way — they get
/// a `PTYProcess` holding a `SupervisorClient` that was never connected, which is inert.
///
/// ## `SuperdFixture` — a real daemon, for the tests that need a real shell
/// `testControllingTTY` and its neighbours are checking kernel behaviour (a ctty, `SIGWINCH`
/// reflow, zsh's hangup history save). Those need an actual `fork`, and the only thing in this
/// repo that forks is `slopdesk-superd` — a Rust binary, deliberately not built by `swift build`
/// (`CLAUDE.md`: a clean checkout must build headless, never seeing cargo).
///
/// So the fixture SKIPS when the binary is absent rather than falling back to forking in Swift. A
/// fallback would be a second spawn implementation, which is the thing this whole change removed.
/// `make test` builds superd first, so the gate runs them; a bare `swift test` reports them
/// skipped, by name, with the command that fixes it.
enum SupervisedPTY {
    /// A `PTYProcess` that will never be spawned. Its client is not connected and nothing will
    /// connect it.
    static func unattached() -> PTYProcess {
        PTYProcess(supervisor: SupervisorClient(socketPath: "/nonexistent/slopdesk-superd.sock"))
    }
}

/// Convenience for the many call sites that just need the object.
func unattachedPTY() -> PTYProcess { SupervisedPTY.unattached() }

extension PTYProcess {
    /// Spawns with a throwaway pane identity.
    ///
    /// Test-only, and it exists so no production call site can be tempted to do the same:
    /// `paneID` must be something a LATER hostd can recompute from durable facts, because that is
    /// what makes adopt-on-restart possible (`docs/51` §5). A random UUID is the right answer for a
    /// pane that will not outlive the test, and the wrong answer for every other pane.
    func spawnForTest(
        _ executable: String,
        arguments: [String] = [],
        environment: [String: String],
        argv0: String? = nil,
        cwd: String? = nil,
        cols: UInt16 = 80,
        rows: UInt16 = 24,
        shellIntegration: Bool = false,
        blocks: Bool = false,
    ) throws {
        let identity = UUID().uuidString
        try spawn(
            executable,
            arguments: arguments,
            environment: environment,
            argv0: argv0,
            cwd: cwd,
            cols: cols,
            rows: rows,
            paneID: identity,
            sessionID: identity,
            shellIntegration: shellIntegration,
            blocks: blocks,
        )
    }
}

/// A private `slopdesk-superd` on a temp socket, torn down with the test.
///
/// Private on purpose: it must never touch the developer's live daemon, whose panes are real work.
/// It gets its own `SLOPDESK_SUPERD_DIR`, so its lock file, control socket and advertised hook
/// paths are all its own, and the single-instance `flock` in the real superd is untroubled by it.
final class SuperdFixture {
    /// Where a test process points when it has no private daemon. Nothing binds it, by design —
    /// see ``deinit``.
    static let absentSocketPath = "/nonexistent/slopdesk-superd-absent.sock"

    let socketPath: String
    let client: SupervisorClient
    private let directory: URL
    private let process: Process
    /// Where the daemon's own log goes — see the redirection note in ``init()``.
    private let logURL: URL

    /// Boots a daemon and completes the handshake, or throws `XCTSkip` when superd is not built.
    init() throws {
        let binary = try Self.binaryPath()
        // Short stem: `sun_path` is 104 bytes and a `$TMPDIR` already eats ~49 of them.
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sd-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        socketPath = directory.appendingPathComponent("slopdesk-superd.sock").path

        process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        var environment = ProcessInfo.processInfo.environment
        environment["SLOPDESK_SUPERD_DIR"] = directory.path
        // Stated explicitly, not merely implied by the directory: this process's own
        // `SLOPDESK_SUPERD_SOCKET` is inherited by the child, and between fixtures ``deinit`` points
        // it at ``absentSocketPath`` — which the daemon would dutifully try to BIND, in a directory
        // that does not exist. The daemon binds exactly where the client is about to connect.
        environment[SupervisorPaths.socketEnvKey] = socketPath
        process.environment = environment
        // The daemon's log goes to a FILE in its own directory, and never to the harness's stdio.
        //
        // Not a tidiness choice — it is the difference between a stray process and a hung suite. A
        // fixture that somehow outlives its test leaves a daemon holding the write end of xctest's
        // stdout pipe; `swift-test` then sits reading that pipe for an EOF that cannot arrive, long
        // after the last test has finished and the xctest process has become a zombie. There is no
        // failure message and no timeout: the run simply never ends. The log is not lost — a
        // handshake that fails prints it in the skip message, which is where it was ever read.
        // `closeOnDealloc: false`, and a descriptor of our own per channel. `Process` closes what it
        // is handed once the child has it, and a `FileHandle` that also closes on dealloc makes that
        // a DOUBLE close — which frees a descriptor another thread has since reused, and surfaces as
        // a `SIGPIPE` killing the whole test host arbitrarily far from here. (Observed, not feared:
        // one `FileHandle` object on both channels crashed this suite before the `xctest` process
        // had run a single test.) The descriptors are the child's from here on; `posix_spawn`
        // duplicates them and the parent's copies go with the `Process`.
        // BOTH channels, not just stderr. The daemon writes only to stderr today, but the hang
        // above is about the DESCRIPTOR, not about what is written to it: an inherited stdout is
        // the write end of xctest's pipe, and a fixture that outlives its test holds it open just
        // as effectively in silence. One `open` per channel, for the double-close reason spelled
        // out above.
        logURL = directory.appendingPathComponent("superd.log", isDirectory: false)
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let errors = open(logURL.path, O_WRONLY | O_APPEND)
        if errors >= 0 {
            process.standardError = FileHandle(fileDescriptor: errors, closeOnDealloc: false)
        }
        let output = open(logURL.path, O_WRONLY | O_APPEND)
        if output >= 0 {
            process.standardOutput = FileHandle(fileDescriptor: output, closeOnDealloc: false)
        }
        try process.run()

        client = SupervisorClient(socketPath: socketPath)
        try Self.connect(client, at: socketPath, log: logURL)
        // Point THIS PROCESS's default at the fixture too, so a `HostServer` built during the
        // fixture's life reaches the private daemon instead of the developer's real one — whose
        // panes are real work. Process-global on purpose: `HostServer` resolves its socket at
        // construction from `SupervisorPaths.controlSocket()`, and threading an override through
        // its initialiser would put a test-only parameter on the production type. Cleared in
        // `deinit`, and XCTest runs a class's methods serially, so the window is one test.
        setenv(SupervisorPaths.socketEnvKey, socketPath, 1)
    }

    deinit {
        // Pointed at nothing, never UNSET: unsetting restores the default path, which is the
        // developer's real daemon, and the next test in this process to build a `HostServer` would
        // adopt its live panes. An absent socket makes such a test fail honestly instead.
        setenv(SupervisorPaths.socketEnvKey, Self.absentSocketPath, 1)
        client.disconnect()
        endDaemon()
        try? FileManager.default.removeItem(at: directory)
    }

    /// SIGTERM, then — if it is still there — SIGKILL.
    ///
    /// SIGTERM first because superd's exit drops the last master fd for every pane it still holds,
    /// which is how the fixture's shells get cleaned up rather than leaked. The escalation is
    /// belt-and-braces: a daemon that outlives the suite is a stray process on the developer's
    /// machine holding live children, and this is the last code that will ever run for it.
    private func endDaemon() {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
    }

    /// Ends the daemon out from under its client, the way a crash or a `superd-install` does.
    ///
    /// Deliberately not `client.disconnect()`: a client hanging up is an orderly act it knows about,
    /// and the disconnect observers correctly stay quiet for it. What has to be tested is the other
    /// one — the socket dying while the client still believes it is attached, which is the only
    /// route by which hostd learns that superd (and therefore every pane it held) is gone.
    func killDaemon() {
        endDaemon()
    }

    /// A supervised pane, spawned through the fixture's daemon.
    func pty(
        _ executable: String,
        arguments: [String] = [],
        environment: [String: String],
        argv0: String? = nil,
        cwd: String? = nil,
        cols: UInt16 = 80,
        rows: UInt16 = 24,
        paneID: String = UUID().uuidString,
        sessionID: String? = nil,
        journal: JournalSpawnRequest? = nil,
    ) throws -> PTYProcess {
        let pty = PTYProcess(supervisor: client)
        try pty.spawn(
            executable,
            arguments: arguments,
            environment: environment,
            argv0: argv0,
            cwd: cwd,
            cols: cols,
            rows: rows,
            paneID: paneID,
            sessionID: sessionID ?? paneID,
            journal: journal,
        )
        return pty
    }

    /// `rust/slopdesk-superd/target/{release,debug}/slopdesk-superd`, or the override, or a skip.
    private static func binaryPath() throws -> String {
        if let override = ProcessInfo.processInfo.environment["SLOPDESK_SUPERD_BIN"], !override.isEmpty {
            return override
        }
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // SlopDeskHostTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // <package root>
            .appendingPathComponent("rust/slopdesk-superd/target")
        for profile in ["release", "debug"] {
            let candidate = root.appendingPathComponent("\(profile)/slopdesk-superd")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate.path }
        }
        throw XCTSkip(
            "slopdesk-superd is not built, and nothing else can fork a shell — run `make superd` "
                + "(or `make test`, which does). Set SLOPDESK_SUPERD_BIN to point elsewhere.",
        )
    }

    /// Connects, retrying while the daemon is still coming up.
    ///
    /// The daemon binds within milliseconds, but `run()` returns before it has — and **waiting for
    /// the socket FILE to appear is not the same as waiting for the daemon to be reachable.**
    /// `bind(2)` creates the node and `listen(2)` comes after it, so a `connect` landing in that
    /// window gets `ECONNREFUSED`, not `ENOENT`. The window is microseconds and it does not lose
    /// when a suite runs alone; it loses under the whole suite's load, which is exactly the kind of
    /// flake that gets blamed on whatever test happened to catch it. So the readiness test is a
    /// real connection.
    private static func connect(_ client: SupervisorClient, at path: String, log: URL) throws {
        let deadline = Date().addingTimeInterval(5)
        while true {
            do {
                try client.connect(clientName: "slopdesk-tests")
                return
            } catch {
                // A failed `SupervisorSocket.connect` closes its own fd before throwing, so the
                // client is untouched and retrying is clean.
                guard Date() < deadline else {
                    // With the daemon's own account of it, since nothing else will print it now.
                    let said = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
                    throw XCTSkip(
                        "slopdesk-superd never accepted a connection on \(path): \(error)\n"
                            + "the daemon said: \(said.isEmpty ? "nothing" : said)",
                    )
                }
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
    }
}

/// A supervised pane's output, accumulated for assertions.
///
/// ## Why a test may not just `read(pty.masterFD)` any more
/// superd runs a reader on every pane for the pane's whole life (`rust/slopdesk-superd/src/pump.rs`).
/// hostd's duplicate of the master is the SAME open file description, so a second reader here does
/// not get a second copy of the stream — it races the pump for each byte and wins some of them.
/// A test written that way is not slow or flaky in the usual sense; it is reading a torn stream,
/// and the failure it eventually produces blames whatever assertion happened to lose the coin flip.
///
/// So a test reads a pane the way hostd does: by subscribing.
///
/// ## Sequential matching, deliberately
/// ``waitFor(_:timeout:)`` searches from a cursor that advances past each match, so a suite that
/// asks for `"24 80"`, resizes, then asks for `"24 80"` again really does wait for the second one.
/// It is strictly stronger than the fd loop it replaces, which dropped whatever arrived between two
/// calls; here nothing is lost, because the subscription starts at offset 0 and superd's ring holds
/// the backlog.
final class PaneOutput: @unchecked Sendable {
    /// Separate from `PaneOutput` so the subscription's callback can be built BEFORE the object
    /// that owns the stream exists — the stream is `let`, and a `[weak self]` closure capturing a
    /// half-initialised `self` is the alternative.
    private final class Buffer: @unchecked Sendable {
        let lock = NSLock()
        var seen = Data()
        /// Where the next ``PaneOutput/waitFor(_:timeout:)`` starts looking. Advances past a match.
        var cursor = 0
        /// Whether the stream declared itself over. Either route counts — see ``PaneOutputStream``.
        var ended = false
        /// What superd's sniffer found, in stream order, as it was handed over WITH each chunk.
        var sniffed: [SniffedEvent] = []
        var blocks: [BlockEvent] = []
    }

    private let buffer = Buffer()
    private let stream: PaneOutputStream

    /// Subscribes to a pane that has already been spawned.
    init(_ pty: PTYProcess) throws {
        let buffer = buffer
        stream = try XCTUnwrap(
            pty.makeOutputStream(
                onChunk: { chunk, _, sniffed, blocks in
                    buffer.lock.lock()
                    buffer.seen.append(chunk)
                    buffer.sniffed.append(contentsOf: sniffed)
                    buffer.blocks.append(contentsOf: blocks)
                    buffer.lock.unlock()
                },
                onEOF: {
                    buffer.lock.lock()
                    buffer.ended = true
                    buffer.lock.unlock()
                },
            ),
            "a spawned pane must have a supervisor identity to subscribe with",
        )
        stream.start()
    }

    deinit { stream.stop() }

    /// Everything superd's sniffer reported so far, in stream order.
    var sniffed: [SniffedEvent] {
        buffer.lock.lock()
        defer { buffer.lock.unlock() }
        return buffer.sniffed
    }

    /// Every command-block event superd's tap reported so far, in stream order.
    var blocks: [BlockEvent] {
        buffer.lock.lock()
        defer { buffer.lock.unlock() }
        return buffer.blocks
    }

    /// Blocks until `match` holds of the block batch, or the timeout elapses. Same shape, and the
    /// same reason, as ``waitForSniffed(timeout:_:)``: an OSC 133 mark is consumed by the terminal,
    /// so there is no byte in ``text`` to wait for instead.
    @discardableResult
    func waitForBlocks(timeout: TimeInterval = 20.0, _ match: ([BlockEvent]) -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if match(blocks) { return true }
            usleep(20000)
        }
        return match(blocks)
    }

    /// Blocks until `match` holds of the sniffed batch, or the timeout elapses.
    ///
    /// - Returns: whether it did. A shell's OSC is not a byte the caller can wait for with
    ///   ``waitFor(_:timeout:)`` — the sequence is consumed by the terminal, not printed.
    @discardableResult
    func waitForSniffed(
        timeout: TimeInterval = 20.0,
        _ match: ([SniffedEvent]) -> Bool,
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if match(sniffed) { return true }
            usleep(20000)
        }
        return match(sniffed)
    }

    /// Everything received so far, as text.
    var text: String {
        buffer.lock.lock()
        defer { buffer.lock.unlock() }
        return String(bytes: buffer.seen, encoding: .utf8) ?? ""
    }

    /// Blocks until `needle` appears after the cursor, or the timeout elapses.
    ///
    /// - Returns: everything received so far, so a failing assertion can print what did arrive.
    @discardableResult
    func waitFor(_ needle: String, timeout: TimeInterval = 20.0) -> String {
        let needleData = Data(needle.utf8)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            buffer.lock.lock()
            if let found = buffer.seen[buffer.cursor...].range(of: needleData) {
                buffer.cursor = found.upperBound
                let whole = String(bytes: buffer.seen, encoding: .utf8) ?? ""
                buffer.lock.unlock()
                return whole
            }
            buffer.lock.unlock()
            Thread.sleep(forTimeInterval: 0.005)
        }
        return text
    }

    /// Blocks until the stream declares itself over. Returns whether it did.
    func waitForEnd(timeout: TimeInterval = 5.0) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            buffer.lock.lock()
            let ended = buffer.ended
            buffer.lock.unlock()
            if ended { return true }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return false
    }
}
