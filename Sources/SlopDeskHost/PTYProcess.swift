import Darwin
import Foundation
import SlopDeskProtocol

/// A child process attached to a pseudo-terminal (PTY) on the macOS host.
///
/// ## Spawn strategy (`DECISIONS.md` / [12] Part B §1.1)
/// `openpty()` allocates the master/slave pair with an initial cooked-mode `termios`
/// (+ `IUTF8`) and `winsize`. The child is launched with **`fork()` + `login_tty(slave)` +
/// `execve`** (NOT `posix_spawn`, NOT `forkpty`). The child runs ONLY raw libc/syscalls
/// before `execve` — `login_tty`, `close`, `execve`, `_exit` — with NO Swift/ObjC runtime
/// work (no allocation/ARC), honouring the `DECISIONS.md` caveat that ruled out `forkpty`
/// (running the Swift runtime in a forked child is the unsafe part; bare pre-exec syscalls
/// are not). In the child:
///
/// - `login_tty(slave)` = `setsid()` + `ioctl(slave, TIOCSCTTY, 0)` (claim ctty) +
///   `dup2(slave → 0/1/2)` + `close(slave)` — this gives the shell job control + `SIGWINCH`;
/// - `close(master)` — the child must never hold the master, or its EOF never reaches the
///   parent's read;
/// - `execve(path, argv, envp)` — argv/envp are materialised in the PARENT before `fork`.
///
/// ### Controlling terminal (the load-bearing part — `fork`+`login_tty`, not `posix_spawn`)
/// A session leader acquires its ctty only by `open()`ing a tty WITHOUT `O_NOCTTY` *after*
/// `setsid`. A `posix_spawn(POSIX_SPAWN_SETSID)` child only `dup2`s the already-open slave
/// onto fd 0/1/2 — never `open()`s the tty — so for some programs the slave never becomes the
/// ctty. Empirically, on macOS 26.5.1 a `posix_spawn`ed **interactive zsh** ends up ctty-less
/// (`ps` shows `TTY=??`, `TPGID=0`): job control and `SIGWINCH` delivery are both broken, so a
/// `TIOCSWINSZ` on the master delivers no resize signal and the post-resize prompt blanks with
/// zero reprint bytes. (`/bin/sh -c …` acquires a ctty on its own, so testing only over `/bin/sh`
/// would pass even with the interactive-shell path broken — it doesn't exercise the failure.)
/// `login_tty` claims the ctty explicitly, fixing this. Verified by
/// `SlopDeskHostTests.testControllingTTY` over **interactive zsh** (`tty </dev/tty` resolves;
/// `stty size` reflects the openpty winsize; `TIOCSWINSZ` + `SIGWINCH` reflow works).
///
/// `setBlocking(true)` clears `O_NONBLOCK` on the master FD around spawn — a
/// non-blocking master breaks the blocking read relay (Happy #301).
///
/// The relay (PTY ⇄ transport) is no-buffer with a `USER_INTERACTIVE` QoS read loop
/// (no intermediate ring buffer — the NoMachine NX lesson); that lives in
/// ``MuxChannelSession`` (the ``PTYReadLoop`` it owns).
///
/// `masterFD` / `pid` are immutable-after-spawn and safe to share; the only mutable state
/// is the one-shot exit plumbing, guarded by an `NSLock`.
public final class PTYProcess: @unchecked Sendable {
    /// Master side of the PTY (host reads child output / writes child input here).
    /// `-1` until ``spawn(_:arguments:environment:)`` succeeds.
    public private(set) var masterFD: Int32 = -1

    /// PID of the spawned child, or `-1` before spawn.
    public private(set) var pid: pid_t = -1

    /// One-shot exit plumbing: the reaped exit code and any continuation awaiting it.
    private let exitLock = NSLock()
    private var exitCode: Int32?
    private var exitWaiters: [CheckedContinuation<Int32, Never>] = []
    private var reaped = false

    public init() {}

    // MARK: Spawn

    /// Allocates a PTY and spawns `executable` as a session leader attached to it.
    ///
    /// - Parameters:
    ///   - executable: absolute path to the program (e.g. the user's `$SHELL`).
    ///   - arguments: argv (excluding argv[0]; pass `argv0` to override argv[0],
    ///     e.g. `-zsh` for a login shell).
    ///   - environment: full environment for the child. Pass a curated env (the caller owns
    ///     `TERM=xterm-ghostty`, `CLAUDE_CODE_NO_FLICKER=1`, etc.).
    ///   - argv0: the value for `argv[0]`. Defaults to `executable`. A login shell uses
    ///     a leading `-` (e.g. `-zsh`).
    ///   - cols/rows: initial winsize in character cells.
    public func spawn(
        _ executable: String,
        arguments: [String] = [],
        environment: [String: String],
        argv0: String? = nil,
        cwd: String? = nil,
        cols: UInt16 = 80,
        rows: UInt16 = 24,
    ) throws {
        precondition(masterFD == -1, "PTYProcess.spawn called twice")

        var master: Int32 = -1
        var slave: Int32 = -1

        // Sane cooked-mode termios: echo on, canonical mode, signals, CR/NL mapping,
        // plus IUTF8 (correct backspace-over-multibyte; [12] §1.4). The shell flips to
        // raw mode itself when it needs to (readline / TUIs).
        var term = termios()
        term.c_iflag = tcflag_t(ICRNL | IXON | IXANY | IMAXBEL | BRKINT | IUTF8)
        term.c_oflag = tcflag_t(OPOST | ONLCR)
        term.c_cflag = tcflag_t(CREAD | CS8 | HUPCL)
        term.c_lflag = tcflag_t(ICANON | ISIG | IEXTEN | ECHO | ECHOE | ECHOK | ECHOKE | ECHOCTL)
        term.c_ispeed = speed_t(B38400)
        term.c_ospeed = speed_t(B38400)
        setControlChars(&term)

        var ws = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)

        guard openpty(&master, &slave, nil, &term, &ws) == 0 else {
            throw HostError.posix(errno)
        }

        // setBlocking(true): clear O_NONBLOCK on the master before spawn (Happy #301).
        // The slave is already open (openpty opened it), so this never hits the
        // posix_openpt EINVAL caveat from [12] §1.1.
        Self.setBlocking(master)

        // --- Build ALL C strings in the PARENT, before fork() ---
        // The forked child must do NO Swift-runtime work (no allocation/ARC) before execve,
        // so path/argv/envp are fully materialised here. `path` is held by `pathDup`; argv/envp
        // are NULL-terminated arrays of strdup'd C strings. All freed in the parent's defer.
        let argv0Value = argv0 ?? executable
        let argvStrings = [argv0Value] + arguments
        var argv: [UnsafeMutablePointer<CChar>?] = argvStrings.map { strdup($0) }
        argv.append(nil)

        // envp: "KEY=VALUE" entries.
        let envStrings = environment.map { "\($0.key)=\($0.value)" }
        var envp: [UnsafeMutablePointer<CChar>?] = envStrings.map { strdup($0) }
        envp.append(nil)

        let pathDup = strdup(executable)
        // Validate the requested cwd HOST-SIDE before fork: a stale/deleted/foreign/`~`-style path
        // must not reach the child's `chdir` and abort it pre-`execve` (`_exit 127` = dead pane). An
        // invalid request falls back to the user's HOME; an unusable HOME resolves to nil (no chdir).
        let resolvedCwd = Self.resolveCwd(cwd, home: environment["HOME"])
        let cwdDup: UnsafeMutablePointer<CChar>? = resolvedCwd.flatMap { strdup($0) }

        defer {
            for p in argv where p != nil { free(p) }
            for p in envp where p != nil { free(p) }
            free(pathDup)
            if let cwdDup { free(cwdDup) }
        }

        // fork(), NOT posix_spawn: posix_spawn cannot run TIOCSCTTY in the child, and a
        // POSIX_SPAWN_SETSID child that only dup2s the slave does not reliably acquire the ctty
        // (interactive zsh ends up ctty-less → no SIGWINCH; see the type doc). The child below
        // claims the ctty explicitly via login_tty.
        //
        // Swift's Darwin overlay marks `fork()` unavailable, so we resolve the raw libc symbol
        // via `dlsym` and call it through a C function pointer — the literal `fork(2)`, same
        // single-threaded-child semantics. Safe here because the child does NO Swift-runtime work
        // before `execve` (only `login_tty`/`close`/`execve`/`_exit`); the `DECISIONS.md` forkpty
        // caveat is about running the Swift/ObjC runtime in the child, which we do not.
        let childPID = Self.rawFork()
        if childPID == 0 {
            // ===== CHILD: raw syscalls only, no Swift runtime. =====
            // login_tty(slave) atomically: setsid(); ioctl(slave, TIOCSCTTY, 0);
            // dup2(slave → 0,1,2); close(slave) if >2. This is what makes the slave the
            // controlling terminal (so SIGWINCH / job control reach the shell).
            if login_tty(slave) != 0 { _exit(127) }
            // Best-effort chdir: `resolveCwd` already validated the dir in the parent, so this
            // normally succeeds. A TOCTOU (dir deleted between validate and chdir) must NOT kill the
            // pane — leave the child in the inherited cwd rather than `_exit 127` (dead pane).
            if let cwdDup { _ = chdir(cwdDup) }
            // The child must never hold the master, or its EOF would never arrive on read.
            close(master)
            _ = execve(pathDup, argv, envp)
            // execve only returns on failure.
            _exit(127)
        }

        // Capture fork()'s errno IMMEDIATELY, before any other syscall can overwrite it. The
        // `close(slave)` below sets errno on ITS OWN failure (EINTR/EBADF), which would clobber the
        // fork() errno we report on a fork() failure — so read it here, at the first opportunity.
        let forkErrno = errno

        // ===== PARENT =====
        // Parent uses only the master; close the slave unconditionally.
        close(slave)

        guard childPID > 0 else {
            // fork() failed: reclaim the master and report fork()'s errno (captured pre-close above).
            close(master)
            throw HostError.posix(forkErrno)
        }

        masterFD = master
        pid = childPID
        startReaper(pid: childPID)
    }

    /// Sets the standard control characters (VINTR, VEOF, VERASE, …) to sane defaults
    /// so cooked-mode editing behaves like a normal login terminal.
    private func setControlChars(_ term: inout termios) {
        withUnsafeMutableBytes(of: &term.c_cc) { raw in
            let cc = raw.bindMemory(to: cc_t.self)
            func set(_ index: Int32, _ value: Int32) { cc[Int(index)] = cc_t(value) }
            set(VEOF, 4) // ^D
            set(VEOL, 0xFF)
            set(VEOL2, 0xFF)
            set(VERASE, 0x7F) // DEL
            set(VWERASE, 23) // ^W
            set(VKILL, 21) // ^U
            set(VREPRINT, 18) // ^R
            set(VINTR, 3) // ^C
            set(VQUIT, 28) // ^\
            set(VSUSP, 26) // ^Z
            set(VDSUSP, 25) // ^Y
            set(VSTART, 17) // ^Q
            set(VSTOP, 19) // ^S
            set(VLNEXT, 22) // ^V
            set(VDISCARD, 15) // ^O
            set(VMIN, 1)
            set(VTIME, 0)
        }
    }

    // MARK: resolveCwd

    /// Resolves the initial working directory for a fresh shell, HOST-SIDE, before the fork.
    ///
    /// The child's `chdir` runs pre-`execve` with no Swift runtime, so it cannot validate or fall
    /// back — a failed `chdir` there aborts the child (`_exit 127`) and the client gets a
    /// dead-on-arrival pane. So we validate here instead: a `~`/`~/…` path is tilde-expanded against
    /// `home`; the resolved path is accepted only when it is an existing, SEARCHABLE directory;
    /// otherwise we fall back to `home` (when it is itself a usable dir), else `nil` (no chdir — the
    /// child inherits the daemon cwd, still a LIVE shell). `nil` requested ⇒ `nil` (unchanged).
    ///
    /// Pure + injectable (`fileManager`) so it is unit-tested without a spawn.
    static func resolveCwd(_ requested: String?, home: String?, fileManager: FileManager = .default) -> String? {
        func usableDir(_ path: String) -> Bool {
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return false }
            // Searchable (execute bit) — a non-searchable dir would fail chdir too.
            return access(path, X_OK) == 0
        }
        func expandTilde(_ path: String) -> String? {
            guard path.hasPrefix("~") else { return path }
            guard let home, !home.isEmpty else { return nil } // no HOME to expand against
            if path == "~" { return home }
            if path.hasPrefix("~/") { return home + String(path.dropFirst(1)) }
            // `~user` form — we cannot resolve another user's home here; reject (fall back to HOME).
            return nil
        }
        // Fallback candidate: the user's HOME, only when it is a usable dir.
        let homeFallback: String? = home.flatMap { !$0.isEmpty && usableDir($0) ? $0 : nil }

        guard let requested, !requested.isEmpty else { return nil }
        guard let expanded = expandTilde(requested), usableDir(expanded) else { return homeFallback }
        return expanded
    }

    // MARK: setBlocking

    /// Clears `O_NONBLOCK` on `fd` so reads/writes block (Happy #301).
    /// Exposed for wiring and tests.
    public static func setBlocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK)
        }
    }

    // MARK: rawFork

    /// `fork(2)` resolved at runtime, because Swift's Darwin overlay marks `fork()` *unavailable*
    /// (it discourages forking from the Swift runtime in general). We need the real syscall for the
    /// `login_tty` controlling-terminal acquisition (see ``spawn(_:arguments:environment:argv0:cols:rows:)``);
    /// the child does no Swift-runtime work before `execve`, so this specific use is safe. Resolved once
    /// via `dlsym(RTLD_DEFAULT, "fork")` and cached.
    private typealias ForkFn = @convention(c) () -> pid_t
    private static let rawForkFn: ForkFn = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2 /* RTLD_DEFAULT */ ), "fork") else {
            fatalError("PTYProcess: could not resolve fork(2)")
        }
        return unsafeBitCast(sym, to: ForkFn.self)
    }()

    private static func rawFork() -> pid_t { rawForkFn() }

    // MARK: Resize

    /// Applies a terminal size to the PTY via `TIOCSWINSZ` (driven by `resize`). The
    /// kernel then delivers `SIGWINCH` to the child's foreground process group.
    public func setWindowSize(cols: UInt16, rows: UInt16, pxWidth: UInt16 = 0, pxHeight: UInt16 = 0) {
        // Hold `exitLock` across the guard AND the ioctl so `closeMaster` (which nils `masterFD` under the
        // same lock, then closes the fd) cannot null + recycle the fd between this read and the syscall —
        // otherwise the TIOCSWINSZ could land on an unrelated, just-reopened fd with the same number (a
        // TOCTOU). Safe/non-deadlocking: TIOCSWINSZ is a microsecond non-blocking syscall that never
        // re-enters PTYProcess.
        exitLock.lock()
        defer { exitLock.unlock() }
        guard masterFD >= 0 else { return }
        var ws = winsize(ws_row: rows, ws_col: cols, ws_xpixel: pxWidth, ws_ypixel: pxHeight)
        _ = ioctl(masterFD, TIOCSWINSZ, &ws)
    }

    /// The PTY's current window size via `TIOCGWINSZ`, or `nil` on a closed/unspawned master.
    /// Same `exitLock` TOCTOU discipline as ``setWindowSize(cols:rows:pxWidth:pxHeight:)``.
    /// Surfaced by the agent-control `list-panes` verb (`rows`/`cols`).
    public func currentWindowSize() -> (rows: UInt16, cols: UInt16)? {
        exitLock.lock()
        defer { exitLock.unlock() }
        guard masterFD >= 0 else { return nil }
        var ws = winsize()
        guard ioctl(masterFD, TIOCGWINSZ, &ws) == 0 else { return nil }
        return (rows: ws.ws_row, cols: ws.ws_col)
    }

    // MARK: Redraw nudge

    /// Delivers `SIGWINCH` to the PTY's foreground process group so shells and full-screen
    /// apps (vim, top, …) repaint immediately after a client reattach.
    ///
    /// On reattach the client terminal is fresh and holds no buffered output, so the pane is
    /// blank until a keypress makes zsh/bash redraw the prompt. `SIGWINCH` is the safe repaint
    /// signal — it asks the foreground process to re-query size and redraw; it cannot corrupt a
    /// running app.
    ///
    /// ## Delivery strategy
    /// 1. `tcgetpgrp(masterFD)` resolves the **foreground** group (may be a child `vim`/`make`
    ///    rather than the shell). Preferred over `killpg(childPid's pgrp)` because it honours
    ///    job-control (the shell may have suspended itself with a child in the foreground).
    /// 2. `killpg(fgPgrp, SIGWINCH)` — signal the whole foreground group.
    /// 3. Fallback: `tcgetpgrp ≤ 0` (no foreground group yet, or master already closed) ⇒
    ///    `kill(childPid, SIGWINCH)` to catch the shell itself.
    ///
    /// Guards checked under `exitLock` (same TOCTOU discipline as
    /// ``setWindowSize(cols:rows:pxWidth:pxHeight:)``); a closed/invalid fd or non-positive
    /// pgrp is a safe no-op, never traps.
    ///
    /// - Important: reattach path ONLY, not fresh-shell spawn (the shell prints its first prompt
    ///   naturally; a redundant `SIGWINCH` is harmless but noisy for apps that re-clear the screen).
    public func nudgeRedraw() {
        exitLock.lock()
        let fd = masterFD
        let childPid = pid
        exitLock.unlock()

        guard fd >= 0, childPid > 0 else { return }

        let fgPgrp = tcgetpgrp(fd)
        if fgPgrp > 0 {
            killpg(fgPgrp, SIGWINCH)
        } else {
            // No foreground pgrp yet (terminal quiescent) — nudge the child directly.
            kill(childPid, SIGWINCH)
        }
    }

    // MARK: Lifecycle

    /// Sends `SIGTERM` to the child (it is a session leader, so this reaches the group
    /// via the controlling tty's hangup machinery once the master closes too).
    public func terminate() {
        guard pid > 0 else { return }
        kill(pid, SIGTERM)
    }

    /// Sends `SIGKILL` to the child — the un-ignorable escalation when a `SIGTERM` did not
    /// take (a child that blocks/ignores `SIGTERM`, or a foreground job holding the slave
    /// open). Used by ``MuxChannelSession/shutdown()`` as the fallback so the parked
    /// `read()` on the master is GUARANTEED to return (slave closes on the child's death →
    /// master EOFs/EIOs) and a subsequent ``closeMaster()`` cannot block. A no-op once the
    /// child is reaped (`pid` is immutable-after-spawn, but the kernel just drops a signal
    /// to a dead-and-reaped pid).
    public func forceTerminate() {
        guard pid > 0 else { return }
        kill(pid, SIGKILL)
    }

    /// Blocks the CALLER until the child has been reaped (the detached reaper observed its
    /// exit and recorded a code) or `timeout` elapses, whichever comes first. Synchronous,
    /// poll-based — ``MuxChannelSession/shutdown()`` is not `async` and so cannot
    /// `await waitForExit()` inline, but it must still let the parked `read()` drain before
    /// closing the master. This does NOT itself call `waitpid` (the detached reaper from
    /// ``startReaper(pid:)`` owns that); it only WAITS for that reaper's result to land,
    /// polling the one-shot ``waitExitCode()`` peek.
    ///
    /// - Returns: `true` if the child was observed exited within the window, `false` on
    ///   timeout (caller then escalates to ``forceTerminate()``).
    @discardableResult
    public func waitUntilExited(timeout: TimeInterval, step: TimeInterval = 0.005) -> Bool {
        if waitExitCode() != nil { return true }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if waitExitCode() != nil { return true }
            Thread.sleep(forTimeInterval: step)
        }
        return waitExitCode() != nil
    }

    /// Closes the PTY master fd exactly once and marks it `-1`.
    ///
    /// On a successful ``spawn(_:arguments:environment:argv0:cols:rows:)`` the master fd
    /// is held open for the life of the session (the host reads child output / writes
    /// input through it). It is **not** closed by ``terminate()`` (which only signals the
    /// child) so the relay can still drain the child's final output before EOF. The owner
    /// (``MuxChannelSession/shutdown()``) calls this **after stopping the read loop** so no
    /// concurrent `read()` can race the close; a `deinit` safety net catches any path
    /// that forgot. Idempotent.
    ///
    /// Without this the master fd leaked once per spawn — a long-running daemon exhausted
    /// the default 256-fd soft limit after ~250 sessions and `openpty` began returning
    /// `EMFILE`.
    public func closeMaster() {
        exitLock.lock()
        let fd = masterFD
        masterFD = -1
        exitLock.unlock()
        if fd >= 0 { close(fd) }
    }

    deinit {
        // Safety net: if an owner forgot to closeMaster(), don't leak the fd. By the time
        // deinit runs nothing else references this object, so no read can race the close.
        if masterFD >= 0 { close(masterFD) }
    }

    /// The child's exit code. Suspends until the child has been reaped. Multiple
    /// awaiters are all resumed with the same code.
    public func waitForExit() async -> Int32 {
        await withCheckedContinuation { (continuation: CheckedContinuation<Int32, Never>) in
            exitLock.lock()
            if let code = exitCode {
                exitLock.unlock()
                continuation.resume(returning: code)
            } else {
                exitWaiters.append(continuation)
                exitLock.unlock()
            }
        }
    }

    /// Non-blocking peek at the exit code, or `nil` if the child is still running /
    /// not yet reaped. (Retained for diagnostics / the seam contract.)
    public func waitExitCode() -> Int32? {
        exitLock.lock()
        defer { exitLock.unlock() }
        return exitCode
    }

    /// Spawns a dedicated blocking `waitpid` thread that reaps the child and surfaces
    /// the exit status (used as `WireMessage.exit(code:)` by the relay). A dedicated
    /// thread (not SIGCHLD) keeps reaping local to this process object and avoids
    /// global signal-handler coordination.
    private func startReaper(pid: pid_t) {
        Thread.detachNewThread { [weak self] in
            var status: Int32 = 0
            var reapedOK = false
            while true {
                let r = waitpid(pid, &status, 0)
                if r == pid { reapedOK = true
                    break
                } // success: `status` is a real wait status
                if r == -1, errno != EINTR { break } // failure (e.g. ECHILD: child already reaped)
            }
            let code: Int32 =
                if !reapedOK {
                    // waitpid FAILED — `status` was never written (still 0), so the prior code decoded it
                    // as a clean `exit 0`, masking the abnormal condition (the wire `exit(code:0)` would
                    // lie that a vanished/double-reaped child exited gracefully). Report a sentinel instead
                    // so the client sees an abnormal termination. (128+SIGKILL=137, the "killed" convention.)
                    128 + SIGKILL
                } else if (status & 0o177) == 0 {
                    // WIFEXITED: high byte is the exit status.
                    (status >> 8) & 0xFF
                } else {
                    // WIFSIGNALED: report 128 + signal (shell convention).
                    128 + (status & 0o177)
                }
            self?.completeExit(code: code)
        }
    }

    /// Test seam: records an exit code exactly as the reaper thread would (``completeExit``),
    /// so hang-safe unit tests can drive child-exited branches (`isChildExited() == true`)
    /// on an UNSPAWNED process — no real child is ever forked or killed in a unit test.
    func completeExitForTesting(code: Int32) { completeExit(code: code) }

    private func completeExit(code: Int32) {
        exitLock.lock()
        guard !reaped else { exitLock.unlock()
            return
        }
        reaped = true
        exitCode = code
        let waiters = exitWaiters
        exitWaiters.removeAll()
        exitLock.unlock()
        for w in waiters { w.resume(returning: code) }
    }
}

/// Host-side errors. Distinct from ``SlopDeskError`` (which is wire-decode only).
public enum HostError: Error, Equatable, Sendable {
    /// A POSIX syscall failed; associated value is `errno`.
    case posix(Int32)
}
