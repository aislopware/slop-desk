#if canImport(Darwin)
import Darwin
#endif
import SlopDeskProtocol
import XCTest
@testable import SlopDeskHost
@testable import SlopDeskTransport // reach `MuxSubChannel.deliver(payload:)` (the demux inbound seam)

/// PTY-level tests: deterministic, headless, no client networking — drive the
/// `PTYProcess` master fd directly and assert on the shell's output bytes.
final class PTYProcessTests: XCTestCase {
    // MARK: read helpers

    /// Reads `fd` until `needle` appears or `timeout` passes; returns all output so far.
    ///
    /// `poll()`-gated on the CALLING thread — `read()` only runs after `POLLIN`, so it can never block
    /// past the deadline and the helper leaves NO thread behind. A naive background-dispatch-thread
    /// blocking `read()` + semaphore timeout abandons that thread inside `read()` on a missed needle —
    /// a PTY master never EOFs on child exit, so the read stays pending forever and the test-end
    /// `close(masterFD)` (PTYProcess.deinit) deadlocks against it in the kernel: the "unkillable 40-min
    /// hang" the resize-burst test's doc describes, surfaced reliably by `swift test --parallel` load.
    private func readUntil(
        fd: Int32,
        needle: String,
        timeout: TimeInterval = 5.0,
    ) -> String {
        let sink = ByteSink()
        let needleData = Data(needle.utf8)
        let deadline = Date().addingTimeInterval(timeout)
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let remainingMs = Int32((deadline.timeIntervalSinceNow * 1000).rounded(.up))
            if remainingMs <= 0 { break }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, min(remainingMs, 100))
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            if ready == 0 { continue } // tick: re-check the deadline
            // Readable (or HUP/ERR — read() then returns <= 0 without blocking and we stop).
            let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                if sink.append(buf[0..<n], contains: needleData) { break }
            } else {
                break
            }
        }
        return sink.string()
    }

    private func curatedEnv() -> [String: String] {
        // Force a deterministic TERM and locale for the tests.
        var env = HostEnvironment.curated()
        env["TERM"] = "xterm-256color"
        return env
    }

    // MARK: Tests

    func testPTYRoundTripPrintf() throws {
        let pty = PTYProcess()
        try pty.spawn("/bin/sh", arguments: ["-c", "printf slopdesk-ok"], environment: curatedEnv())
        XCTAssertGreaterThanOrEqual(pty.masterFD, 0)
        XCTAssertGreaterThan(pty.pid, 0)

        let output = readUntil(fd: pty.masterFD, needle: "slopdesk-ok")
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

        let pty = PTYProcess()
        try pty.spawn(
            "/bin/sh",
            arguments: ["-c", "pwd"],
            environment: curatedEnv(),
            cwd: dir.path,
        )

        let output = readUntil(fd: pty.masterFD, needle: dir.path)
        XCTAssertTrue(output.contains(dir.path), "expected child cwd \(dir.path), got: \(output)")
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
        // A nil request stays nil (child inherits the daemon cwd — unchanged behaviour).
        XCTAssertNil(PTYProcess.resolveCwd(nil, home: home.path))
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
        let pty = PTYProcess()
        try pty.spawn(
            "/bin/sh",
            arguments: ["-c", "pwd"],
            environment: env,
            cwd: "/nonexistent-slopdesk-\(UUID().uuidString)",
        )
        let output = readUntil(fd: pty.masterFD, needle: home.lastPathComponent)
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
        let pty = PTYProcess()
        try pty.spawn("/bin/sh", environment: curatedEnv())

        // Cooked-mode line discipline echoes and the shell evaluates the command.
        let cmd = "echo HELLO_$((1+1))\n"
        Self.write(pty.masterFD, cmd)

        let output = readUntil(fd: pty.masterFD, needle: "HELLO_2")
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
        let pty = PTYProcess()
        try pty.spawn(
            "/bin/sh",
            arguments: ["-c", "tty </dev/tty; stty size </dev/tty"],
            environment: curatedEnv(),
            cols: 132, rows: 40,
        )

        let output = readUntil(fd: pty.masterFD, needle: "40 132")
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
        let pty = PTYProcess()
        // Interactive zsh with NO rc files (-f) so the test is independent of the user's environment.
        var env = curatedEnv()
        env["ZDOTDIR"] = "/nonexistent-slopdesk-test" // belt-and-suspenders: no stray rc.
        try pty.spawn(
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
        let ttyOut = readUntil(fd: pty.masterFD, needle: "/dev/tty", timeout: 5.0)
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
        let colsOut = readUntil(fd: pty.masterFD, needle: "SLOPDESK_COLS=132", timeout: 5.0)
        XCTAssertTrue(
            colsOut.contains("SLOPDESK_COLS=132"),
            "zsh did NOT update $COLUMNS after TIOCSWINSZ — SIGWINCH was not delivered to the "
                + "interactive shell (no controlling terminal / not foreground pgroup): \(colsOut)",
        )
    }

    func testResizeAfterSpawn() throws {
        let pty = PTYProcess()
        try pty.spawn("/bin/sh", environment: curatedEnv(), cols: 80, rows: 24)

        pty.setWindowSize(cols: 80, rows: 24)
        Self.write(pty.masterFD, "stty size\n")
        let first = readUntil(fd: pty.masterFD, needle: "24 80")
        XCTAssertTrue(first.contains("24 80"), "expected '24 80', got: \(first)")

        pty.setWindowSize(cols: 120, rows: 40)
        Self.write(pty.masterFD, "stty size\n")
        let second = readUntil(fd: pty.masterFD, needle: "40 120")
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
        let pty = PTYProcess()
        try pty.spawn("/bin/sh", environment: curatedEnv(), cols: 80, rows: 24)

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
        let pty = PTYProcess()
        try pty.spawn("/bin/sh", environment: curatedEnv(), cols: 80, rows: 24)

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

    func testExitCode() throws {
        let pty = PTYProcess()
        try pty.spawn("/bin/sh", arguments: ["-c", "exit 7"], environment: curatedEnv())

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
        let pty = PTYProcess()
        try pty.spawn("/bin/sh", arguments: ["-c", "kill -TERM $$"], environment: curatedEnv())

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
            let pty = PTYProcess()
            try pty.spawn("/bin/sh", arguments: ["-c", "printf hi; exit 0"], environment: curatedEnv())
            // Inert in-memory sub-channels (muxSend is a no-op) — we exercise only the PTY spawn →
            // relay → shutdown fd hygiene, not the wire.
            // ⚠️ Keep the PTY output well UNDER MuxFlowControl.initialWindowBytes (256 KiB): the DATA
            // sub-channel arms a send window and there is NO grant source here, so a >window workload
            // would park the relay's send forever (hang). `printf hi` (2 bytes) is safe.
            let data = MuxSubChannel(channelID: 1, channel: .data) { _, _ in }
            let control = MuxSubChannel(channelID: 1, channel: .control) { _, _ in }
            let session = MuxChannelSession(channelID: 1, pty: pty, data: data, control: control)
            session.startRelay()
            _ = readUntil(fd: pty.masterFD, needle: "\u{04}", timeout: 1) // drain to EOF
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
        let pty = PTYProcess()
        // No args ⇒ an interactive login-style shell that blocks on its tty awaiting input and never
        // exits on its own — exactly the production case (a pane's shell when the client disconnects).
        try pty.spawn("/bin/sh", environment: curatedEnv())
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
        let pty = PTYProcess()
        try pty.spawn("/bin/sh", environment: curatedEnv())
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
            let pty = PTYProcess()
            try pty.spawn("/bin/sh", arguments: ["-c", "exit 0"], environment: curatedEnv())
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
        let pty = PTYProcess()
        try pty.spawn("/bin/sh", arguments: ["-c", "exit 0"], environment: curatedEnv())
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
        let pty = PTYProcess()
        // Guard path: masterFD == -1 → returns immediately without calling tcgetpgrp/killpg.
        pty.nudgeRedraw() // must not crash or trap
    }

    /// After `closeMaster()` marks `masterFD` as `-1`, the guard short-circuits and `nudgeRedraw()`
    /// is a safe no-op. Verifies the TOCTOU discipline — the method reads `masterFD` under `exitLock`,
    /// so a concurrent close cannot race the subsequent `tcgetpgrp` call.
    func testNudgeRedrawIsNoOpAfterCloseMaster() throws {
        let pty = PTYProcess()
        try pty.spawn("/bin/sh", arguments: ["-c", "exit 0"], environment: curatedEnv())
        XCTAssertGreaterThanOrEqual(pty.masterFD, 0)
        _ = readUntil(fd: pty.masterFD, needle: "\u{04}", timeout: 1) // drain to EOF
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
        let pty = PTYProcess()
        var env = curatedEnv()
        env["ZDOTDIR"] = "/nonexistent-slopdesk-test"
        try pty.spawn(zsh, arguments: ["-f", "-i"], environment: env, argv0: "-zsh", cols: 80, rows: 24)

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
        let out = readUntil(fd: pty.masterFD, needle: "NUDGE_COLS=", timeout: 5.0)
        XCTAssertTrue(
            out.contains("NUDGE_COLS="),
            "nudgeRedraw() must deliver SIGWINCH to the interactive zsh foreground pgrp "
                + "(TRAPWINCH never fired): \(out)",
        )
    }

    func testMasterFDIsBlockingAfterSpawn() throws {
        let pty = PTYProcess()
        try pty.spawn("/bin/sh", arguments: ["-c", "exit 0"], environment: curatedEnv())
        let flags = fcntl(pty.masterFD, F_GETFL)
        XCTAssertGreaterThanOrEqual(flags, 0)
        XCTAssertEqual(flags & O_NONBLOCK, 0, "O_NONBLOCK must be cleared on the master fd")
        _ = readUntil(fd: pty.masterFD, needle: "\u{04}", timeout: 1) // drain until EOF
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

/// Thread-safe accumulator for the background PTY read in tests.
final class ByteSink: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    /// Appends `bytes` and returns whether `needle` now appears in the accumulation.
    func append(_ bytes: ArraySlice<UInt8>, contains needle: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        data.append(contentsOf: bytes)
        return data.contains(needle)
    }

    func string() -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(bytes: data, encoding: .utf8) ?? ""
    }
}
