#if canImport(Darwin)
import Darwin
#endif
import SlopDeskProtocol
import SlopDeskSupervisor
import XCTest
@testable import SlopDeskHost
@testable import SlopDeskTransport // reach `MuxSubChannel.deliver(payload:)` (the demux inbound seam)

/// PTY-level tests: deterministic, headless, no client networking — drive the
/// `PTYProcess` master fd directly and assert on the shell's output bytes.
final class PTYProcessTests: XCTestCase {
    // MARK: read helpers

    /// One ``PaneOutput`` per pane, kept for the test's life so matching stays sequential.
    ///
    /// The whole helper below used to be a `poll()`-gated `read()` on `pty.masterFD`, guarded by a
    /// long comment about never leaving a thread parked inside `read()` — a PTY master does not EOF
    /// on child exit, so an abandoned read deadlocks the test-end `close(masterFD)` in the kernel
    /// (the "unkillable 40-min hang"). None of that applies now and the hazard it warned about is
    /// gone with it: nothing here reads a master, and a subscription cannot park in the kernel.
    ///
    /// The timeout is still PATIENCE, never an assertion. Every caller asserts on the needle it got
    /// back, so a genuinely broken pane fails at any value — waiting longer only costs seconds on a
    /// real break. 20s, because at 5s `testResizeAfterSpawn` flaked once under a full `make test`
    /// with every core busy: the spawned `/bin/sh` was not scheduled to answer the second
    /// `stty size` inside the window. Under that load 5s measures the machine, not the code.
    private var collectors: [ObjectIdentifier: PaneOutput] = [:]

    /// Waits for `needle` in a pane's output.
    ///
    /// Subscribes rather than reading `pty.masterFD`. That is not a style choice: superd's pump
    /// reads the master for the pane's whole life and hostd's duplicate is the same open file
    /// description, so a `read` here does not observe the stream — it steals from it. See
    /// ``PaneOutput``.
    private func readUntil(
        pane pty: PTYProcess,
        needle: String,
        timeout: TimeInterval = 20.0,
    ) -> String {
        let key = ObjectIdentifier(pty)
        if let existing = collectors[key] { return existing.waitFor(needle, timeout: timeout) }
        do {
            let made = try PaneOutput(pty)
            collectors[key] = made
            return made.waitFor(needle, timeout: timeout)
        } catch {
            XCTFail("could not subscribe to the pane's output: \(error)")
            return ""
        }
    }

    /// A throwaway HOME shared by this test instance's spawns; removed in `tearDown`.
    private var sandboxHome: URL?

    /// A private `slopdesk-superd`, because nothing else in this repo forks a shell any more.
    ///
    /// These tests are about kernel behaviour a mock cannot have — a controlling terminal, a
    /// `SIGWINCH` that reflows a real zsh, a hangup that makes it save its history. They were the
    /// reason the fork window existed in Swift; the window is Rust now, so the daemon that owns it
    /// is part of the rig. It is private (its own `SLOPDESK_SUPERD_DIR`) and never the developer's
    /// live one, and the suite SKIPS if superd is not built rather than forking here
    /// (`SupervisedPTYSupport`).
    private var superd: SuperdFixture?

    override func setUpWithError() throws {
        superd = try SuperdFixture()
    }

    override func tearDown() {
        if let sandboxHome { try? FileManager.default.removeItem(at: sandboxHome) }
        sandboxHome = nil
        // Unsubscribe before the daemon goes: a collector outliving its superd would be asking a
        // dead socket for bytes.
        collectors.removeAll()
        // Drops the client, then SIGTERMs the daemon — which drops the last master fd of every
        // pane this test spawned, so no shell outlives the suite.
        superd = nil
        super.tearDown()
    }

    /// A pane object bound to this test's daemon. Nothing is spawned until `spawnForTest`.
    private func makePane() throws -> PTYProcess {
        try PTYProcess(supervisor: XCTUnwrap(superd).client)
    }

    private func curatedEnv() -> [String: String] {
        // Force a deterministic TERM and locale for the tests.
        var env = HostEnvironment.curated()
        env["TERM"] = "xterm-256color"
        // Sandbox HOME: several tests spawn INTERACTIVE shells (no-arg `/bin/sh`) and type real
        // commands into them. With the inherited HOME, bash-as-sh reads AND — on a typed `exit`
        // or the SIGHUP-led teardown — WRITES the developer's real `~/.bash_history` (bash's
        // 500-line HISTFILESIZE rewrite can even truncate it). A throwaway HOME keeps every
        // spawned shell's history file inside the test sandbox.
        let home = sandboxHome ?? {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("slopdesk-pty-home-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            sandboxHome = dir
            return dir
        }()
        env["HOME"] = home.path
        return env
    }

    // MARK: Tests

    func testPTYRoundTripPrintf() throws {
        let pty = try makePane()
        try pty.spawnForTest("/bin/sh", arguments: ["-c", "printf slopdesk-ok"], environment: curatedEnv())
        XCTAssertGreaterThanOrEqual(pty.masterFD, 0)
        XCTAssertGreaterThan(pty.pid, 0)

        let output = readUntil(pane: pty, needle: "slopdesk-ok")
        XCTAssertTrue(output.contains("slopdesk-ok"), "expected 'slopdesk-ok', got: \(output)")

        let exp = expectation(description: "exit")
        Task {
            let code = await pty.waitForExit()
            XCTAssertEqual(code, 0)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)
    }

    func testPTYSpawnStartsInRequestedCwd() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("slopdesk-pty-cwd-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let pty = try makePane()
        try pty.spawnForTest(
            "/bin/sh",
            arguments: ["-c", "pwd"],
            environment: curatedEnv(),
            cwd: dir.path,
        )

        let output = readUntil(pane: pty, needle: dir.path)
        XCTAssertTrue(output.contains(dir.path), "expected child cwd \(dir.path), got: \(output)")
    }

    /// A pane that requests NO cwd (the `home` working-directory policy, and the very first pane of a fresh
    /// workspace) must start in HOME — not in whatever directory the daemon happens to have been launched
    /// from. Skipping the `chdir` handed every such pane the launcher's project as its cwd.
    func testPTYSpawnWithoutRequestedCwdStartsInHome() throws {
        var env = curatedEnv()
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("slopdesk-pty-home-cwd-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        env["HOME"] = home.path
        // Prove the child MOVED: the test process's own cwd stands in for the daemon's, and the child must
        // not report it. `pwd -P` so a symlinked temp dir compares against the resolved HOME below.
        let resolvedHome = home.resolvingSymlinksInPath().path
        XCTAssertNotEqual(resolvedHome, FileManager.default.currentDirectoryPath)

        let pty = try makePane()
        try pty.spawnForTest("/bin/sh", arguments: ["-c", "pwd -P"], environment: env, cwd: nil)

        let output = readUntil(pane: pty, needle: resolvedHome)
        XCTAssertTrue(output.contains(resolvedHome), "expected child cwd \(resolvedHome), got: \(output)")
        XCTAssertFalse(
            output.contains(FileManager.default.currentDirectoryPath),
            "the child must not inherit the daemon's cwd",
        )
    }

    /// An inherited cwd that no longer exists (deleted dir, foreign ssh path, `~`-style preset)
    /// must NOT kill the freshly-spawned shell (`chdir`-fail `_exit 127` = dead pane). The host validates
    /// the requested cwd and falls back to HOME, so the pane comes up live.
    func testResolveCwdFallsBackToHomeForInvalidRequest() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("slopdesk-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        // A nonexistent requested dir resolves to HOME.
        XCTAssertEqual(
            PTYProcess.resolveCwd("/nonexistent-slopdesk-\(UUID().uuidString)", home: home.path),
            home.path,
        )
        // A valid requested dir is used verbatim.
        XCTAssertEqual(PTYProcess.resolveCwd(home.path, home: home.path), home.path)
        // A tilde path is expanded against HOME.
        XCTAssertEqual(PTYProcess.resolveCwd("~", home: home.path), home.path)
        // No request at all resolves to HOME — never the daemon cwd, which is whatever directory `hostd`
        // was launched from (the `home` working-directory policy means "the login shell's directory").
        XCTAssertEqual(PTYProcess.resolveCwd(nil, home: home.path), home.path)
        XCTAssertEqual(PTYProcess.resolveCwd("", home: home.path), home.path)
        // No request AND no usable HOME still resolves to nil (no chdir, live shell — never a dead pane).
        XCTAssertNil(PTYProcess.resolveCwd(nil, home: nil))
        // An invalid request with no usable HOME resolves to nil (no chdir, live shell — never a dead pane).
        XCTAssertNil(PTYProcess.resolveCwd("/nonexistent-slopdesk", home: nil))
    }

    /// End-to-end: spawning with a since-deleted cwd must land the shell in HOME and exit CLEANLY
    /// (code 0), not `_exit(127)`. Revert-to-confirm-fail: the un-fixed child `_exit(127)`s so the
    /// exit code is 127 and `pwd` never prints HOME.
    func testPTYSpawnWithInvalidCwdFallsBackToHomeAndStaysLive() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("slopdesk-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        var env = curatedEnv()
        env["HOME"] = home.path
        let pty = try makePane()
        try pty.spawnForTest(
            "/bin/sh",
            arguments: ["-c", "pwd"],
            environment: env,
            cwd: "/nonexistent-slopdesk-\(UUID().uuidString)",
        )
        let output = readUntil(pane: pty, needle: home.lastPathComponent)
        XCTAssertTrue(
            output.contains(home.lastPathComponent),
            "an invalid cwd must fall back to HOME (\(home.path)), got: \(output)",
        )

        let exp = expectation(description: "exit0")
        Task {
            let code = await pty.waitForExit()
            XCTAssertEqual(code, 0, "an invalid cwd must not kill the shell (_exit 127)")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)
    }

    func testPTYInteractiveEcho() throws {
        let pty = try makePane()
        try pty.spawnForTest("/bin/sh", environment: curatedEnv())

        // Cooked-mode line discipline echoes and the shell evaluates the command.
        let cmd = "echo HELLO_$((1+1))\n"
        Self.write(pty.masterFD, cmd)

        let output = readUntil(pane: pty, needle: "HELLO_2")
        XCTAssertTrue(output.contains("HELLO_2"), "expected 'HELLO_2', got: \(output)")
        pty.terminate()
    }

    func testControllingTTY() throws {
        // 40 rows x 132 cols at spawn. Exercises the CONTROLLING-TERMINAL alias `/dev/tty`
        // (NOT fd 0/1/2): `/dev/tty` opens only if the slave is genuinely the session's
        // controlling terminal, so `tty </dev/tty` / `stty size </dev/tty` prove
        // POSIX_SPAWN_SETSID acquired the ctty — WITHOUT setsid they yield "/dev/tty: Device
        // not configured", whereas plain `tty`/`stty size` on fd 0 would still pass (making
        // this the regression-meaningful form).
        let pty = try makePane()
        try pty.spawnForTest(
            "/bin/sh",
            arguments: ["-c", "tty </dev/tty; stty size </dev/tty"],
            environment: curatedEnv(),
            cols: 132, rows: 40,
        )

        let output = readUntil(pane: pty, needle: "40 132")
        // WITH setsid `/dev/tty` resolves to itself; WITHOUT it → "Device not configured".
        // Those checks are what make this regression-meaningful for POSIX_SPAWN_SETSID —
        // fd 0/1/2's path would pass even with setsid broken, but /dev/tty would not.
        XCTAssertTrue(
            output.contains("/dev/tty"),
            "expected /dev/tty to resolve (controlling terminal), got: \(output)",
        )
        XCTAssertFalse(
            output.lowercased().contains("device not configured"),
            "/dev/tty reported 'Device not configured' — slave is NOT the controlling terminal (setsid broken): \(output)",
        )
        XCTAssertFalse(
            output.lowercased().contains("not a tty"),
            "tty reported 'not a tty' — slave is NOT the controlling terminal: \(output)",
        )
        XCTAssertTrue(
            output.contains("40 132"),
            "expected 'stty size </dev/tty' = '40 132', got: \(output)",
        )
    }

    /// Controlling terminal + SIGWINCH delivery for an INTERACTIVE zsh.
    ///
    /// `testControllingTTY` spawns only `/bin/sh -c …`, which acquires its ctty even under a
    /// `posix_spawn(POSIX_SPAWN_SETSID)` path — while a LIVE interactive zsh (the real workload)
    /// has NO ctty (`TTY=??`, `TPGID=0`) under that same path. With no ctty the kernel delivers no
    /// `SIGWINCH` on `TIOCSWINSZ`: `$COLUMNS` never updates, `TRAPWINCH` never fires, the
    /// post-resize prompt blanks. This reproduces the real workload (`zsh -i`) and proves the
    /// `fork()`+`login_tty` path restores BOTH ctty AND signal-driven resize:
    ///   1. `tty` resolves to a real `/dev/ttys*` (not "not a tty") → ctty acquired;
    ///   2. after a `TIOCSWINSZ` resize, `TRAPWINCH` fires and observes the NEW `$COLUMNS` →
    ///      SIGWINCH was actually delivered to the interactive shell.
    /// If `login_tty` regressed to a dup2-only spawn, step 2 would never print.
    func testInteractiveZshControllingTTYAndSigwinch() throws {
        let zsh = "/bin/zsh"
        guard FileManager.default.isExecutableFile(atPath: zsh) else {
            throw XCTSkip("/bin/zsh not present")
        }
        let pty = try makePane()
        // Interactive zsh with NO rc files (-f) so the test is independent of the user's environment.
        var env = curatedEnv()
        env["ZDOTDIR"] = "/nonexistent-slopdesk-test" // belt-and-suspenders: no stray rc.
        try pty.spawnForTest(
            zsh,
            arguments: ["-f", "-i"],
            environment: env,
            argv0: "-zsh",
            cols: 80, rows: 24,
        )

        // GUARANTEED non-hang teardown. An interactive zsh holds its slave open forever and may
        // ignore SIGTERM, so SIGKILL + reap BEFORE closing the master: that releases any background
        // `readUntil` parked in `read()` (slave close → EOF) and makes `closeMaster()` non-blocking.
        // (Bare `terminate()`/deinit would let a parked read race `close(masterFD)` and wedge the
        // suite — the documented macOS close()-hang.) `defer` runs even on an XCTAssert early-out.
        defer {
            pty.forceTerminate()
            pty.waitUntilExited(timeout: 1.0)
            pty.closeMaster()
        }

        // (1) Controlling terminal: `tty </dev/tty` only resolves (to the alias `/dev/tty`) if the
        // slave is genuinely this session's controlling terminal — without that, `/dev/tty` reports
        // "Device not configured"/"not a tty" for interactive zsh.
        Self.write(pty.masterFD, "tty </dev/tty\n")
        let ttyOut = readUntil(pane: pty, needle: "/dev/tty")
        XCTAssertTrue(
            ttyOut.contains("/dev/tty"),
            "interactive zsh has NO controlling terminal (login_tty/TIOCSCTTY broken): \(ttyOut)",
        )
        XCTAssertFalse(
            ttyOut.lowercased().contains("not a tty") || ttyOut.lowercased().contains("device not configured"),
            "/dev/tty did not resolve — slave is NOT the controlling terminal: \(ttyOut)",
        )

        // (2) SIGWINCH delivery — the load-bearing assertion. zsh updates `$COLUMNS`/`$LINES` ONLY
        // inside its SIGWINCH handler (no re-TIOCGWINSZ per parameter expansion), so a later
        // `print -- $COLUMNS` reporting the NEW width proves SIGWINCH reached the shell — which needs
        // the slave to be the ctty and zsh the foreground pgroup (both broken under old posix_spawn,
        // restored by fork()+login_tty). With NO ctty `$COLUMNS` stays at the spawn value (80) even
        // though `TIOCSWINSZ` changed the kernel winsize. Resize, settle, then ask zsh for COLUMNS.
        Thread.sleep(forTimeInterval: 0.3)
        pty.setWindowSize(cols: 132, rows: 40)
        Thread.sleep(forTimeInterval: 0.3)
        Self.write(pty.masterFD, "print -r -- SLOPDESK_COLS=$COLUMNS\n")
        let colsOut = readUntil(pane: pty, needle: "SLOPDESK_COLS=132")
        XCTAssertTrue(
            colsOut.contains("SLOPDESK_COLS=132"),
            "zsh did NOT update $COLUMNS after TIOCSWINSZ — SIGWINCH was not delivered to the "
                + "interactive shell (no controlling terminal / not foreground pgroup): \(colsOut)",
        )
    }

    /// The destroy-path teardown must let an interactive zsh PERSIST ITS COMMAND HISTORY.
    ///
    /// zsh writes `$HISTFILE` only on a clean `exit` or on SIGHUP ("terminal closed" — what a
    /// real emulator delivers when its window goes away); it IGNORES SIGTERM entirely, and
    /// SIGKILL discards every command typed since launch. `MuxChannelSession.shutdown()` — the
    /// ONE ladder behind pane close, daemon stop, and `DetachedSessionStore` eviction — must
    /// therefore lead with `hangup()` before the SIGTERM→SIGKILL escalation, or every teardown
    /// silently throws away the user's typed history (the "commands I just typed are missing
    /// from autosuggestion and Ctrl-R" report). Exercises that exact ladder against a REAL
    /// interactive zsh with an ISOLATED ZDOTDIR/HISTFILE (never the user's real files) and pins
    /// that the typed marker survives into the history file.
    func testDestroyPathTeardownPersistsInteractiveZshHistory() throws {
        let zsh = "/bin/zsh"
        guard FileManager.default.isExecutableFile(atPath: zsh) else {
            throw XCTSkip("/bin/zsh not present")
        }
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("slopdesk-hist-\(UUID().uuidString)", isDirectory: true)
        let zdot = sandbox.appendingPathComponent("zdot", isDirectory: true)
        try FileManager.default.createDirectory(at: zdot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let histfile = sandbox.appendingPathComponent("history").path
        // Minimal rc: history persistence on, a recognisable prompt, nothing else. ZDOTDIR
        // isolation keeps the test independent of (and harmless to) the user's real zsh setup.
        try """
        HISTFILE=\(histfile)
        SAVEHIST=1000
        HISTSIZE=1000
        PS1='hist-test%% '
        """.write(to: zdot.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)

        var env = curatedEnv()
        env["ZDOTDIR"] = zdot.path
        env["HOME"] = sandbox.path // /etc/zshrc derives HISTFILE from ${ZDOTDIR:-$HOME} — sandbox both
        env.removeValue(forKey: "HISTFILE")

        let pty = try makePane()
        // NO `-f`: the rc files must run so HISTFILE/SAVEHIST are live (that is the machinery
        // under test). Login argv0 matches the real spawn path.
        try pty.spawnForTest(zsh, arguments: ["-i"], environment: env, argv0: "-zsh", cols: 80, rows: 24)
        defer { // guaranteed non-hang teardown even on assert early-out (see the SIGWINCH test)
            pty.forceTerminate()
            pty.waitUntilExited(timeout: 1.0)
            pty.closeMaster()
        }

        // Wait for the first prompt (ZLE up, history machinery live), then type a marker whose
        // OUTPUT differs from its echoed input — seeing `slopdesk_hist_41001` proves the command
        // RAN (was accepted into history), not merely that the terminal echoed the keystrokes.
        _ = readUntil(pane: pty, needle: "hist-test")
        let marker = "echo slopdesk_hist_$((41000+1))"
        Self.write(pty.masterFD, marker + "\n")
        let ran = readUntil(pane: pty, needle: "slopdesk_hist_41001")
        XCTAssertTrue(ran.contains("slopdesk_hist_41001"), "zsh never ran the marker: \(ran)")

        // THE destroy ladder from `MuxChannelSession.shutdown()` — including the master drain:
        // without it, a zsh caught mid-prompt-redraw blocks in tcsetattr(TCSADRAIN) (nobody
        // consumes its pending output once the read loop stops), never sees the SIGHUP, and
        // dies unsaved to the SIGKILL escalation. This test fires the signals the instant the
        // marker's output appears, which lands in that window reliably enough to flake without
        // the drain.
        pty.hangup()
        pty.terminate()
        let exitedOnHangup = pty.waitUntilExitedDrainingMaster(timeout: 0.25)
        if !exitedOnHangup {
            pty.forceTerminate()
            pty.waitUntilExited(timeout: 0.25)
        }

        // zsh exits on the SIGHUP and appends this session's commands to $HISTFILE.
        let saved = (try? String(contentsOfFile: histfile, encoding: .utf8)) ?? ""
        XCTAssertTrue(
            saved.contains(marker),
            "interactive zsh died without persisting its history — the teardown ladder lost the "
                + "SIGHUP (exitedOnHangup=\(exitedOnHangup)); histfile: "
                + (saved.isEmpty ? "<empty/absent>" : saved),
        )
    }

    func testResizeAfterSpawn() throws {
        let pty = try makePane()
        try pty.spawnForTest("/bin/sh", environment: curatedEnv(), cols: 80, rows: 24)

        pty.setWindowSize(cols: 80, rows: 24)
        Self.write(pty.masterFD, "stty size\n")
        let first = readUntil(pane: pty, needle: "24 80")
        XCTAssertTrue(first.contains("24 80"), "expected '24 80', got: \(first)")

        pty.setWindowSize(cols: 120, rows: 40)
        Self.write(pty.masterFD, "stty size\n")
        let second = readUntil(pane: pty, needle: "40 120")
        XCTAssertTrue(second.contains("40 120"), "expected '40 120' after resize, got: \(second)")

        pty.terminate()
    }

    /// HOST RESIZE-DEBOUNCE BACKSTOP (the terminal resize-corruption fix, host half).
    ///
    /// Drives a full `MuxChannelSession` relay and feeds a BURST of distinct `.resize` on the CONTROL
    /// sub-channel — what a fast client drag produces. The inline latest-wins micro-debounce must
    /// converge the PTY to the FINAL size (one clean SIGWINCH, not ~N intermediates that desync zsh's
    /// incremental prompt redraw), and an interleaved `.ack` must FLUSH the pending size FIRST (never
    /// strand a size at the ordering boundary). Timing is INJECTED (`resizeDebounce: .zero`) so there
    /// is no wall-clock sleep — the `.ack` flush is synchronous on the control loop, making the applied
    /// size deterministic (`StaticIDRDecider` `now`-injection discipline).
    ///
    /// Asserts the APPLIED winsize directly via `TIOCGWINSZ` on the master fd — NOT a `stty size`
    /// round-trip, which was both an UNBOUNDED blocking PTY read (missed needle → the unkillable 40-min
    /// hang) AND a CONTROL-vs-DATA race (resize rides `controlTask`, `stty size` rides `inputTask` — no
    /// ordering guarantee, so `stty` often ran before the ioctl landed and reported the OLD size).
    /// Reading the applied size removes both: hard 2s ceiling, no shell, no second sub-channel.
    func testResizeDebounceConvergesToFinalSizeAndFlushesOnAck() throws {
        let pty = try makePane()
        try pty.spawnForTest("/bin/sh", environment: curatedEnv(), cols: 80, rows: 24)

        // Inert in-memory sub-channels: muxSend is a no-op (we assert only on the PTY's applied
        // winsize via `TIOCGWINSZ`, never the wire). `.zero` debounce ⇒ the pending size applies on
        // the next runloop turn with NO wall-clock dependence; the `.ack` flush below makes the FINAL
        // applied size deterministic regardless of debounce timing.
        let data = MuxSubChannel(channelID: 1, channel: .data) { _, _ in }
        let control = MuxSubChannel(channelID: 1, channel: .control) { _, _ in }
        let session = MuxChannelSession(
            channelID: 1, pty: pty, data: data, control: control, resizeDebounce: .zero,
        )
        session.startRelay()

        // Fast-drag burst on the CONTROL channel: 80x24 → … → 120x40 (distinct each step), fed as
        // encoded `.resize` frames via `deliver(payload:)` (the same path the demuxer uses).
        let burst: [(UInt16, UInt16)] = [(80, 24), (90, 28), (100, 32), (110, 36), (120, 40)]
        let exp = expectation(description: "burst-delivered")
        Task {
            for (cols, rows) in burst {
                await control.deliver(payload: WireMessage.resize(
                    cols: cols, rows: rows, pxWidth: 0, pxHeight: 0,
                ).encode())
            }
            // An `.ack` is a non-resize control message → the loop FLUSHES the pending (latest 120x40)
            // BEFORE handling it, applying the FINAL size without waiting on the debounce timer
            // (proving both latest-wins AND flush-on-ack in one shot).
            await control.deliver(payload: WireMessage.ack(seq: 0).encode())
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)

        // The PTY's APPLIED winsize must converge to the FINAL size (120x40) — NOT any intermediate
        // (80x24 … 110x36). If the debounce dropped the trailing size, or applied an intermediate
        // last, this poll never reaches 120x40 and XCTFails at the deadline (bounded, never hangs).
        let final = Self.pollWindowSize(fd: pty.masterFD, untilCols: 120, rows: 40)
        XCTAssertEqual(
            final.cols,
            120,
            "host debounce must converge the PTY to the FINAL drag width 120, got cols=\(final.cols)",
        )
        XCTAssertEqual(
            final.rows,
            40,
            "host debounce must converge the PTY to the FINAL drag height 40, got rows=\(final.rows)",
        )
        drainExitAndShutdown(session, pty: pty)
    }

    /// The `.bye` (clean-leave) path must ALSO flush a pending size — a client that resizes then
    /// immediately leaves must not strand the final size at teardown. A LARGE debounce (`.seconds(60)`)
    /// so the timer would NOT fire in the test window — proving the apply comes from the `.bye` FLUSH,
    /// not the timer. Applied size read directly via `TIOCGWINSZ` in a bounded poll (no `stty size`
    /// round-trip → no unbounded read, no ordering race).
    func testResizeFlushedOnBye() throws {
        let pty = try makePane()
        try pty.spawnForTest("/bin/sh", environment: curatedEnv(), cols: 80, rows: 24)

        let data = MuxSubChannel(channelID: 1, channel: .data) { _, _ in }
        let control = MuxSubChannel(channelID: 1, channel: .control) { _, _ in }
        let session = MuxChannelSession(
            channelID: 1, pty: pty, data: data, control: control, resizeDebounce: .seconds(60),
        )
        session.startRelay()

        let exp = expectation(description: "bye-delivered")
        Task {
            await control.deliver(payload: WireMessage.resize(
                cols: 132, rows: 50, pxWidth: 0, pxHeight: 0,
            ).encode())
            await control.deliver(payload: WireMessage.bye.encode()) // flush-on-bye applies 132x50 now
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)

        let final = Self.pollWindowSize(fd: pty.masterFD, untilCols: 132, rows: 50)
        XCTAssertEqual(
            final.cols,
            132,
            "a `.bye` must FLUSH the pending width 132 (60s debounce would not have fired), got cols=\(final.cols)",
        )
        XCTAssertEqual(
            final.rows,
            50,
            "a `.bye` must FLUSH the pending height 50 (60s debounce would not have fired), got rows=\(final.rows)",
        )
        drainExitAndShutdown(session, pty: pty)
    }

    /// Every APPLIED winsize lands in the disk journal's size sidecar — the geometry a later
    /// daemon life's snapshot restore parses the journaled bytes at. Two record points are
    /// pinned: the SPAWN seeds it (a headless CLI client may never send a `.resize`), and a
    /// flushed client resize overwrites it (last-wins).
    ///
    /// superd writes the file, from the same `spawn`/`resize` requests that reach the kernel — so
    /// what this pins is that hostd still tells it, not that hostd still writes.
    func testAppliedResizeRecordsJournalSizeSidecar() throws {
        let journalDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("resize-sidecar-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: journalDir) }
        let sessionID = UUID()

        let pty = try XCTUnwrap(superd).pty(
            "/bin/sh",
            environment: curatedEnv(),
            cols: 80,
            rows: 24,
            sessionID: sessionID.uuidString,
            journal: JournalSpawnRequest(directory: journalDir.path, capBytes: 1 << 20),
        )
        let data = MuxSubChannel(channelID: 1, channel: .data) { _, _ in }
        let control = MuxSubChannel(channelID: 1, channel: .control) { _, _ in }
        let session = MuxChannelSession(
            channelID: 1, pty: pty, data: data, control: control, resizeDebounce: .zero,
        )
        session.startRelay()

        let sidecar = journalDir.appendingPathComponent("\(sessionID.uuidString).scrollback.size")
        func pollSidecar(until expected: String) -> String? {
            let deadline = Date().addingTimeInterval(5)
            var last: String?
            while Date() < deadline {
                last = try? String(contentsOf: sidecar, encoding: .utf8)
                if last == expected { return last }
                Thread.sleep(forTimeInterval: 0.02)
            }
            return last
        }
        XCTAssertEqual(pollSidecar(until: "24 80\n"), "24 80\n", "the spawn seeds the spawn-time size")

        let exp = expectation(description: "resize-delivered")
        Task {
            await control.deliver(payload: WireMessage.resize(
                cols: 132, rows: 50, pxWidth: 0, pxHeight: 0,
            ).encode())
            // The `.ack` flush applies the pending size synchronously (the debounce-test idiom).
            await control.deliver(payload: WireMessage.ack(seq: 0).encode())
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)
        XCTAssertEqual(pollSidecar(until: "50 132\n"), "50 132\n", "an applied resize overwrites the sidecar")
        drainExitAndShutdown(session, pty: pty)
    }

    func testExitCode() throws {
        let pty = try makePane()
        try pty.spawnForTest("/bin/sh", arguments: ["-c", "exit 7"], environment: curatedEnv())

        let exp = expectation(description: "exit7")
        Task {
            let code = await pty.waitForExit()
            XCTAssertEqual(code, 7, "expected exit code 7")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)
    }

    func testSignalExitReportsShellConvention() throws {
        // WIFSIGNALED branch of the reaper: a child that signals itself reports 128 + signal (shell
        // convention). SIGTERM (15) -> 143. Exercises the `(status & 0o177)` arithmetic that the
        // normal-exit test never touches.
        let pty = try makePane()
        try pty.spawnForTest("/bin/sh", arguments: ["-c", "kill -TERM $$"], environment: curatedEnv())

        let exp = expectation(description: "signal-exit-143")
        Task {
            let code = await pty.waitForExit()
            XCTAssertEqual(code, 143, "expected 128 + SIGTERM(15) = 143 for a self-TERM child")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)
    }

    func testMasterFDClosedOnShutdownNoFDLeak() throws {
        // FD-hygiene regression: each successful spawn opens one PTY master fd; before the fix it was
        // never closed (no deinit, terminate()/shutdown() didn't close it), so a long-running daemon
        // leaked one fd per channel and eventually hit EMFILE. Spawn + relay + shutdown N times and
        // assert the open-fd delta is ~0 (tiny slack for transient fds; a per-spawn leak shows ~N).
        let n = 40
        let before = Self.openFDCount()
        for _ in 0..<n {
            let pty = try makePane()
            try pty.spawnForTest("/bin/sh", arguments: ["-c", "printf hi; exit 0"], environment: curatedEnv())
            // Inert in-memory sub-channels (muxSend is a no-op) — we exercise only the PTY spawn →
            // relay → shutdown fd hygiene, not the wire.
            // ⚠️ Keep the PTY output well UNDER MuxFlowControl.initialWindowBytes (256 KiB): the DATA
            // sub-channel arms a send window and there is NO grant source here, so a >window workload
            // would park the relay's send forever (hang). `printf hi` (2 bytes) is safe.
            let data = MuxSubChannel(channelID: 1, channel: .data) { _, _ in }
            let control = MuxSubChannel(channelID: 1, channel: .control) { _, _ in }
            let session = MuxChannelSession(channelID: 1, pty: pty, data: data, control: control)
            session.startRelay()
            _ = readUntil(pane: pty, needle: "\u{04}", timeout: 1) // drain to EOF
            session.shutdown()
            XCTAssertEqual(pty.masterFD, -1, "closeMaster() must mark the master fd -1 after shutdown")
        }
        // Give any in-flight teardown a beat to release fds.
        Thread.sleep(forTimeInterval: 0.2)
        let after = Self.openFDCount()
        let delta = after - before
        XCTAssertLessThan(
            delta, n / 2,
            "open-fd delta \(delta) over \(n) spawn+shutdown cycles indicates a per-session fd leak",
        )
    }

    /// LATENT-HANG REGRESSION: `MuxChannelSession.shutdown()` ends with
    /// `PTYProcess.closeMaster()` → `close(masterFD)`, and on macOS `close()` of a PTY master BLOCKS
    /// while the `PTYReadLoop` is parked in an in-flight kernel `read()` on that same fd. `stop()`
    /// signals the loop's gate but cannot interrupt a `read()` already in the kernel — that read returns
    /// only when the slave closes, i.e. when the CHILD dies. A no-arg `/bin/sh` is INTERACTIVE and never
    /// exits on its own, so before the fix the reader stayed parked and `shutdown()` hung FOREVER (the
    /// unkillable multi-minute hang reachable from `HostServer.stop()` / `removeMuxSession()` on a clean
    /// client disconnect with a live shell).
    ///
    /// The fix makes `shutdown()` (the genuine-DESTROY path) terminate+reap the child BEFORE
    /// `closeMaster()` — SIGTERM, bounded reaper wait, SIGKILL fallback — so the slave closes, the
    /// parked `read()` returns EOF/EIO, and `close()` is non-blocking. This test asserts that, with NO
    /// `exit` ever written to the shell, `shutdown()` returns within a HARD 3s ceiling. It runs
    /// `shutdown()` on a background queue under an `expectation`/timeout so a regression FAILS the test
    /// instead of wedging the whole suite. (Contrast `drainExitAndShutdown`, which avoided the hang by
    /// writing `exit` so the child died first.)
    func testShutdownReturnsPromptlyWithLiveInteractiveChild() throws {
        let pty = try makePane()
        // No args ⇒ an interactive login-style shell that blocks on its tty awaiting input and never
        // exits on its own — exactly the production case (a pane's shell when the client disconnects).
        try pty.spawnForTest("/bin/sh", environment: curatedEnv())
        XCTAssertGreaterThanOrEqual(pty.masterFD, 0)
        XCTAssertGreaterThan(pty.pid, 0)

        // Inert in-memory sub-channels (muxSend is a no-op): we only drive the relay → shutdown, not
        // the wire. `startRelay()` arms the `PTYReadLoop`, which immediately parks in a blocking
        // `read()` on the master — the exact precondition for the close()-hang.
        let data = MuxSubChannel(channelID: 1, channel: .data) { _, _ in }
        let control = MuxSubChannel(channelID: 1, channel: .control) { _, _ in }
        let session = MuxChannelSession(channelID: 1, pty: pty, data: data, control: control)
        session.startRelay()

        // Let the read loop reach its parked blocking read() before we tear down (so the hang
        // precondition is genuinely established — not a race where shutdown beats the first read()).
        Thread.sleep(forTimeInterval: 0.05)

        // Run shutdown() OFF the test thread under a hard ceiling: if the fix regresses, the call hangs
        // inside close(masterFD) and `done` never fulfils → the wait times out and the test FAILS
        // (rather than hanging the suite). With the fix the child is SIGTERM/SIGKILLed, the reader
        // returns, and close() completes in well under the ceiling.
        let done = expectation(description: "shutdown-returns")
        DispatchQueue.global().async {
            session.shutdown()
            done.fulfill()
        }
        wait(for: [done], timeout: 3)

        // Post-conditions: the master fd was closed (marked -1) and the child was actually reaped — the
        // destroy path must not leave a zombie shell or an open master.
        XCTAssertEqual(pty.masterFD, -1, "shutdown() must close the master fd on the destroy path")
        XCTAssertNotNil(pty.waitExitCode(), "shutdown() must terminate+reap the live child on the destroy path")
    }

    /// `shutdownDetached()` must return to the CALLER immediately (it offloads the blocking
    /// SIGTERM→wait→SIGKILL→wait→close to a background queue), while STILL terminating + reaping the
    /// child and closing the master. The caller here stands in for the mux connection's receive loop:
    /// blocking it (as the old inline `shutdown()` from `removeMuxSession` did) stalls every sibling
    /// pane on the shared connection for ~0.25s per pane close. An interactive `/bin/sh` ignores
    /// SIGTERM, so `shutdown()` itself takes ~250ms — far longer than the caller-return ceiling.
    func testShutdownDetachedReturnsImmediatelyAndStillReapsChild() throws {
        let pty = try makePane()
        try pty.spawnForTest("/bin/sh", environment: curatedEnv())
        let data = MuxSubChannel(channelID: 1, channel: .data) { _, _ in }
        let control = MuxSubChannel(channelID: 1, channel: .control) { _, _ in }
        let session = MuxChannelSession(channelID: 1, pty: pty, data: data, control: control)
        session.startRelay()
        Thread.sleep(forTimeInterval: 0.05) // let the read loop park in a blocking read()

        // The detached call must return WELL under shutdown()'s ~250ms SIGTERM→SIGKILL escalation.
        let start = Date()
        session.shutdownDetached()
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 0.05, "shutdownDetached() must NOT block the caller (the mux receive loop)")

        // The detached teardown still completes: poll until the master is closed (its last step).
        let deadline = Date().addingTimeInterval(3)
        while pty.masterFD != -1, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertEqual(pty.masterFD, -1, "the detached shutdown still closes the master fd")
        XCTAssertNotNil(pty.waitExitCode(), "the detached shutdown still terminates + reaps the child")
    }

    /// RAPID OPEN/CLOSE CHURN — the rapid-repeated open/close path (open + close many panes fast).
    /// Drives 250 full spawn → relay → shutdown cycles through the fork+login_tty path and asserts the
    /// process's open-fd count does NOT grow — a per-cycle master-fd leak is the documented failure
    /// (a daemon hit `EMFILE` after ~250 sessions). Each cycle spawns a self-exiting shell (so
    /// `shutdown()` reaps + closes fast and deterministically) through the SAME `MuxChannelSession`
    /// relay (read loop + reaper thread + tasks) a real pane uses.
    func testRapidSpawnShutdownChurnDoesNotLeakFDs() throws {
        func openFDCount() -> Int {
            (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd"))?.count ?? -1
        }
        func runOneCycle() throws {
            let pty = try makePane()
            try pty.spawnForTest("/bin/sh", arguments: ["-c", "exit 0"], environment: curatedEnv())
            let data = MuxSubChannel(channelID: 1, channel: .data) { _, _ in }
            let control = MuxSubChannel(channelID: 1, channel: .control) { _, _ in }
            let session = MuxChannelSession(channelID: 1, pty: pty, data: data, control: control)
            session.startRelay()
            session.shutdown() // child already exited → reap + closeMaster is immediate + deterministic
        }

        // Warm up a few cycles so one-time allocations settle, THEN take the baseline.
        for _ in 0..<3 { try runOneCycle() }
        let baseline = openFDCount()
        XCTAssertGreaterThan(baseline, 0, "could not read /dev/fd")

        let cycles = 250
        for _ in 0..<cycles { try runOneCycle() }
        Thread.sleep(forTimeInterval: 0.2) // let detached reaper threads finish

        let after = openFDCount()
        XCTAssertLessThanOrEqual(
            after, baseline + 12,
            "open fds grew from \(baseline) to \(after) across \(cycles) spawn/shutdown cycles — "
                + "a master-fd (or slave-fd) leak in the fork+login_tty open/close path",
        )
    }

    func testCloseMasterIsIdempotent() throws {
        let pty = try makePane()
        try pty.spawnForTest("/bin/sh", arguments: ["-c", "exit 0"], environment: curatedEnv())
        XCTAssertGreaterThanOrEqual(pty.masterFD, 0)
        pty.closeMaster()
        XCTAssertEqual(pty.masterFD, -1)
        pty.closeMaster() // second call must be a harmless no-op (no double-close)
        XCTAssertEqual(pty.masterFD, -1)
    }

    // MARK: nudgeRedraw guard tests

    /// `nudgeRedraw()` on an unspawned `PTYProcess` (masterFD = -1, pid = -1) must be a safe no-op —
    /// the guard rejects the invalid fd/pid before any syscall. No crash, no assertion failure.
    func testNudgeRedrawIsNoOpOnUnspawnedPTY() {
        let pty = unattachedPTY()
        // Guard path: masterFD == -1 → returns immediately without calling tcgetpgrp/killpg.
        pty.nudgeRedraw() // must not crash or trap
    }

    /// After `closeMaster()` marks `masterFD` as `-1`, the guard short-circuits and `nudgeRedraw()`
    /// is a safe no-op. Verifies the TOCTOU discipline — the method reads `masterFD` under `exitLock`,
    /// so a concurrent close cannot race the subsequent `tcgetpgrp` call.
    func testNudgeRedrawIsNoOpAfterCloseMaster() throws {
        let pty = try makePane()
        try pty.spawnForTest("/bin/sh", arguments: ["-c", "exit 0"], environment: curatedEnv())
        XCTAssertGreaterThanOrEqual(pty.masterFD, 0)
        _ = readUntil(pane: pty, needle: "\u{04}", timeout: 1) // drain to EOF
        pty.closeMaster()
        XCTAssertEqual(pty.masterFD, -1)
        pty.nudgeRedraw() // must not crash: fd is -1, guard fires
    }

    /// `nudgeRedraw()` on a live interactive zsh delivers `SIGWINCH` to the foreground process group,
    /// making the shell redraw its prompt. Same `TRAPWINCH`/`$COLUMNS` technique as
    /// `testInteractiveZshControllingTTYAndSigwinch`: after `nudgeRedraw()` zsh's TRAPWINCH handler
    /// must report the current `$COLUMNS`, proving the signal was delivered. Production-equivalent of
    /// what the reattach path does after 200 ms.
    func testNudgeRedrawDeliversSigwinchToInteractiveZsh() throws {
        let zsh = "/bin/zsh"
        guard FileManager.default.isExecutableFile(atPath: zsh) else {
            throw XCTSkip("/bin/zsh not present")
        }
        let pty = try makePane()
        var env = curatedEnv()
        env["ZDOTDIR"] = "/nonexistent-slopdesk-test"
        try pty.spawnForTest(zsh, arguments: ["-f", "-i"], environment: env, argv0: "-zsh", cols: 80, rows: 24)

        defer {
            pty.forceTerminate()
            pty.waitUntilExited(timeout: 1.0)
            pty.closeMaster()
        }

        // Install a TRAPWINCH that prints a recognisable marker containing $COLUMNS.
        Self.write(pty.masterFD, "TRAPWINCH() { print -r -- NUDGE_COLS=$COLUMNS }\n")
        Thread.sleep(forTimeInterval: 0.3) // let zsh execute the function definition

        // nudgeRedraw() delivers SIGWINCH to the foreground pgrp (interactive zsh).
        pty.nudgeRedraw()

        // zsh's TRAPWINCH fires and prints NUDGE_COLS=<current columns> (80 at spawn). We only need
        // the marker to appear — its presence proves SIGWINCH was delivered.
        let out = readUntil(pane: pty, needle: "NUDGE_COLS=")
        XCTAssertTrue(
            out.contains("NUDGE_COLS="),
            "nudgeRedraw() must deliver SIGWINCH to the interactive zsh foreground pgrp "
                + "(TRAPWINCH never fired): \(out)",
        )
    }

    // MARK: Redraw jiggle (cold-reattach full-repaint resize dance)

    /// The applied winsize straight off the master fd (`TIOCGWINSZ`) — the FULL struct, pixel fields
    /// included (``PTYProcess/currentWindowSize()`` drops them, and the jiggle must preserve them).
    private func appliedWinsize(_ fd: Int32) -> winsize? {
        var ws = winsize()
        guard ioctl(fd, TIOCGWINSZ, &ws) == 0 else { return nil }
        return ws
    }

    /// `beginRedrawJiggle()` shrinks the PTY by exactly one ROW (columns + pixel fields untouched)
    /// and `endRedrawJiggle(_:)` restores the original size. The two REAL size changes are what force
    /// a differential-rendering TUI (Claude Code) to fully re-layout after a cold-reattach replay — a
    /// bare same-size SIGWINCH only repaints the rows the app believes changed, leaving the replayed
    /// frame's collapsed rows (input dividers, status line) permanently blank.
    func testRedrawJiggleShrinksOneRowThenRestores() throws {
        let pty = try makePane()
        try pty.spawnForTest("/bin/sh", environment: curatedEnv(), cols: 80, rows: 24)
        defer {
            pty.forceTerminate()
            pty.waitUntilExited(timeout: 1.0)
            pty.closeMaster()
        }
        pty.setWindowSize(cols: 80, rows: 24, pxWidth: 1280, pxHeight: 800)

        let jiggle = try XCTUnwrap(pty.beginRedrawJiggle())
        let shrunk = try XCTUnwrap(appliedWinsize(pty.masterFD))
        XCTAssertEqual(shrunk.ws_row, 23)
        XCTAssertEqual(shrunk.ws_col, 80)
        XCTAssertEqual(shrunk.ws_xpixel, 1280, "jiggle must not clobber the pixel fields")
        XCTAssertEqual(shrunk.ws_ypixel, 800)

        pty.endRedrawJiggle(jiggle)
        let restored = try XCTUnwrap(appliedWinsize(pty.masterFD))
        XCTAssertEqual(restored.ws_row, 24)
        XCTAssertEqual(restored.ws_col, 80)
        XCTAssertEqual(restored.ws_xpixel, 1280)
        XCTAssertEqual(restored.ws_ypixel, 800)
    }

    /// A client `.resize` that lands DURING the jiggle hold wins: `endRedrawJiggle(_:)` sees the
    /// current size no longer matches the shrunk one and SKIPS the restore — the client's own resize
    /// already delivered a real-size-change SIGWINCH at the size the client actually wants, and
    /// restoring the pre-jiggle size would stomp it.
    func testRedrawJiggleRestoreYieldsToInterveningResize() throws {
        let pty = try makePane()
        try pty.spawnForTest("/bin/sh", environment: curatedEnv(), cols: 80, rows: 24)
        defer {
            pty.forceTerminate()
            pty.waitUntilExited(timeout: 1.0)
            pty.closeMaster()
        }

        let jiggle = try XCTUnwrap(pty.beginRedrawJiggle())
        pty.setWindowSize(cols: 120, rows: 40) // the client's reattach resize, mid-hold
        pty.endRedrawJiggle(jiggle)

        let final = try XCTUnwrap(appliedWinsize(pty.masterFD))
        XCTAssertEqual(final.ws_row, 40, "intervening resize must win over the jiggle restore")
        XCTAssertEqual(final.ws_col, 120)
    }

    /// Degenerate single-row PTY: there is no row to give, so the jiggle shrinks a COLUMN instead.
    func testRedrawJiggleOnSingleRowShrinksColumnInstead() throws {
        let pty = try makePane()
        try pty.spawnForTest("/bin/sh", environment: curatedEnv(), cols: 80, rows: 1)
        defer {
            pty.forceTerminate()
            pty.waitUntilExited(timeout: 1.0)
            pty.closeMaster()
        }

        let jiggle = try XCTUnwrap(pty.beginRedrawJiggle())
        let shrunk = try XCTUnwrap(appliedWinsize(pty.masterFD))
        XCTAssertEqual(shrunk.ws_row, 1)
        XCTAssertEqual(shrunk.ws_col, 79)

        pty.endRedrawJiggle(jiggle)
        let restored = try XCTUnwrap(appliedWinsize(pty.masterFD))
        XCTAssertEqual(restored.ws_row, 1)
        XCTAssertEqual(restored.ws_col, 80)
    }

    /// Unspawned master (`masterFD == -1`): `beginRedrawJiggle()` refuses with `nil` so the caller
    /// falls back to a plain `nudgeRedraw()` (which is itself a guarded no-op there).
    func testRedrawJiggleIsNilOnUnspawnedPTY() {
        XCTAssertNil(unattachedPTY().beginRedrawJiggle())
    }

    func testMasterFDIsBlockingAfterSpawn() throws {
        let pty = try makePane()
        try pty.spawnForTest("/bin/sh", arguments: ["-c", "exit 0"], environment: curatedEnv())
        let flags = fcntl(pty.masterFD, F_GETFL)
        XCTAssertGreaterThanOrEqual(flags, 0)
        XCTAssertEqual(flags & O_NONBLOCK, 0, "O_NONBLOCK must be cleared on the master fd")
        _ = readUntil(pane: pty, needle: "\u{04}", timeout: 1) // drain until EOF
    }

    // MARK: util

    /// Polls the PTY master's APPLIED winsize via `TIOCGWINSZ` until it equals (`cols`,`rows`) or a
    /// HARD iteration ceiling passes (400 × 5ms ≈ 2s), then returns the last read. The deterministic,
    /// BOUNDED replacement for the old unbounded `readUntil("40 120")` round-trip: it asserts the size
    /// the HOST applied (TIOCSWINSZ) directly — no shell, no DATA sub-channel, so neither the
    /// unbounded-read hang nor the CONTROL-vs-DATA ordering race can occur. No `read()` is ever issued,
    /// so the kernel can never block us; the loop is guaranteed to return.
    private static func pollWindowSize(
        fd: Int32, untilCols cols: UInt16, rows: UInt16, maxIterations: Int = 400, step: TimeInterval = 0.005,
    ) -> (cols: UInt16, rows: UInt16) {
        var ws = winsize()
        for _ in 0..<maxIterations {
            ws = winsize()
            if ioctl(fd, TIOCGWINSZ, &ws) == 0, ws.ws_col == cols, ws.ws_row == rows {
                return (ws.ws_col, ws.ws_row)
            }
            Thread.sleep(forTimeInterval: step)
        }
        return (ws.ws_col, ws.ws_row) // last observed — the caller's XCTAssertEqual reports the mismatch.
    }

    /// Counts the process's currently-open file descriptors by listing `/dev/fd`
    /// (macOS exposes one entry per open fd). Used by the fd-leak regression test.
    private static func openFDCount() -> Int {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: "/dev/fd") else { return -1 }
        return entries.count
    }

    /// Drives an interactive child shell to EXIT and reaps it, then tears the relay down — the teardown
    /// discipline `testMasterFDClosedOnShutdownNoFDLeak` relies on: `MuxChannelSession.shutdown()` ends
    /// with `PTYProcess.closeMaster()` → `close(masterFD)`, and on macOS `close()` of a PTY master BLOCKS
    /// while the `PTYReadLoop` is parked in an in-flight blocking `read()` on that same fd (`stop()`
    /// signals its gate but cannot interrupt a `read()` already in the kernel). A no-arg `/bin/sh` is
    /// interactive and never exits on its own, so the reader stays parked and `close()` hangs forever
    /// (the unkillable multi-minute hang). Fix mirrors the fd-leak test: write `exit` → the master
    /// reaches EOF, the read loop returns, the reaper reaps the child; only THEN is `close()`
    /// non-blocking. Bounded: `waitForExit` awaited under a hard 5s `expectation` ceiling so a stuck
    /// child fails the test instead of hanging the suite.
    private func drainExitAndShutdown(_ session: MuxChannelSession, pty: PTYProcess) {
        Self.write(pty.masterFD, "exit\n")
        let exited = expectation(description: "child-exit")
        Task {
            _ = await pty.waitForExit()
            exited.fulfill()
        }
        wait(for: [exited], timeout: 5)
        session.shutdown() // now safe: reader at EOF + child reaped → close() does not block.
    }

    private static func write(_ fd: Int32, _ string: String) {
        let data = Array(string.utf8)
        var offset = 0
        while offset < data.count {
            let n = data[offset...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if n > 0 { offset += n } else { break }
        }
    }
}
