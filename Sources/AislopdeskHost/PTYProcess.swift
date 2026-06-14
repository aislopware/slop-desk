import AislopdeskProtocol
import Darwin
import Foundation

/// A child process attached to a pseudo-terminal (PTY) on the macOS host.
///
/// ## Spawn strategy (`DECISIONS.md` / [12] Part B §1.1)
/// `openpty()` allocates the master/slave pair with an initial `termios` (sane
/// cooked-mode defaults + `IUTF8`) and an initial `winsize`. The child is then launched
/// with **`fork()` + `login_tty(slave)` + `execve`** (NOT `posix_spawn`, and NOT `forkpty`).
/// The forked child runs ONLY raw libc/syscalls before `execve` — `login_tty`, `close`,
/// `execve`, `_exit` — with NO Swift/ObjC runtime work (no allocation/ARC), so it honours the
/// `DECISIONS.md` Host-PTY caveat that ruled out `forkpty` (running the Swift runtime in a
/// forked child is what is unsafe — bare pre-exec syscalls are not). In the child:
///
/// - `login_tty(slave)` bundles `setsid()` + `ioctl(slave, TIOCSCTTY, 0)` (claim the
///   controlling terminal) + `dup2(slave → 0/1/2)` + `close(slave)` — this is what gives the
///   shell job control + `SIGWINCH` (see the controlling-terminal section below);
/// - `close(master)` — the child must never hold the master, or its EOF would never arrive on
///   the parent's read;
/// - `execve(path, argv, envp)` — argv/envp are materialised in the PARENT before `fork`.
///
/// (The earlier `posix_spawn(POSIX_SPAWN_SETSID)` path was replaced in WF10 — it could not run
/// `TIOCSCTTY` in the child and left interactive zsh ctty-less; see below.)
///
/// ### Controlling terminal (the load-bearing part — `fork`+`login_tty`, not `posix_spawn`)
/// On macOS a session leader acquires its controlling terminal only when it `open()`s a
/// tty WITHOUT `O_NOCTTY` *after* `setsid`. A `posix_spawn(POSIX_SPAWN_SETSID)` child only
/// **`dup2`s** the already-open slave onto fd 0/1/2 — it never `open()`s the tty itself —
/// so for some programs the slave never becomes the controlling terminal. Empirically
/// (WF10, macOS 26.5.1) a `posix_spawn`ed **interactive zsh** ends up with NO ctty
/// (`ps` shows `TTY=??`, `TPGID=0`): job control and — the visible symptom — `SIGWINCH`
/// delivery are both broken, so a `TIOCSWINSZ` on the master delivers no resize signal and
/// the post-resize prompt blanks with zero reprint bytes. (`/bin/sh -c …` happened to
/// acquire it, which is why the old `testControllingTTY` over `/bin/sh` passed while the
/// live interactive shell was broken.)
///
/// The fix: spawn via `fork()` and have the child call **`login_tty(slave)`**, which atomically
/// `setsid()`s, `ioctl(slave, TIOCSCTTY, 0)`s (explicitly claiming the controlling terminal),
/// then `dup2`s the slave onto fd 0/1/2 and closes it — then the child `close()`s the master
/// and `execve`s. The window between `fork` and `execve` runs ONLY raw libc/syscalls
/// (`login_tty`, `close`, `execve`, `_exit`) — NO Swift runtime / ARC / allocation — so it
/// honours the `DECISIONS.md` "no Swift runtime in a forked child" constraint that ruled out
/// `forkpty`. All C strings (path, argv, envp) are built in the PARENT before `fork`.
/// Verified by `AislopdeskHostTests.testControllingTTY` over **interactive zsh** (`tty </dev/tty`
/// resolves; `stty size` reflects the openpty winsize; `TIOCSWINSZ` + `SIGWINCH` reflow works).
///
/// `setBlocking(true)` clears `O_NONBLOCK` on the master FD around spawn — a
/// non-blocking master breaks the blocking read relay (Happy #301).
///
/// The relay (PTY ⇄ transport) is no-buffer with a `USER_INTERACTIVE` QoS read loop
/// (no intermediate ring buffer — the NoMachine NX lesson); that lives in
/// ``MuxChannelSession`` (the ``PTYReadLoop`` it owns).
///
/// All access to the (immutable-after-spawn) `masterFD` / `pid` is safe to share; the
/// only mutable state is the one-shot exit plumbing, guarded by an `NSLock`.
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
    ///   - environment: full environment for the child. Pass a curated env (WF-7 owns
    ///     `TERM=xterm-ghostty`, `CLAUDE_CODE_NO_FLICKER=1`, etc.).
    ///   - argv0: the value for `argv[0]`. Defaults to `executable`. A login shell uses
    ///     a leading `-` (e.g. `-zsh`).
    ///   - cols/rows: initial winsize in character cells.
    public func spawn(
        _ executable: String,
        arguments: [String] = [],
        environment: [String: String],
        argv0: String? = nil,
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

        defer {
            for p in argv where p != nil { free(p) }
            for p in envp where p != nil { free(p) }
            free(pathDup)
        }

        // fork(), NOT posix_spawn: posix_spawn cannot run TIOCSCTTY in the child, and a
        // POSIX_SPAWN_SETSID child that only dup2s the slave does not reliably acquire the
        // controlling terminal (interactive zsh ends up ctty-less → no SIGWINCH; see the
        // type doc). The child below claims the ctty explicitly via login_tty.
        //
        // Swift's Darwin overlay marks `fork()` unavailable, so we resolve the raw libc symbol
        // once via `dlsym` and call it through a C function pointer. This is the literal libc
        // `fork(2)`; it has the same single-threaded-child semantics. The child does NO
        // Swift-runtime work before `execve` (only `login_tty`/`close`/`execve`/`_exit`), so
        // running in a forked child is safe here (the `DECISIONS.md` forkpty caveat is about
        // running the Swift/ObjC runtime in the child, which we do not).
        let childPID = Self.rawFork()
        if childPID == 0 {
            // ===== CHILD: raw syscalls only, no Swift runtime. =====
            // login_tty(slave) atomically: setsid(); ioctl(slave, TIOCSCTTY, 0);
            // dup2(slave → 0,1,2); close(slave) if >2. This is what makes the slave the
            // controlling terminal (so SIGWINCH / job control reach the shell).
            if login_tty(slave) != 0 { _exit(127) }
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

    // MARK: setBlocking

    /// Clears `O_NONBLOCK` on `fd` so reads/writes block (Happy #301).
    /// Exposed for WF-3 wiring and tests.
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
        // re-enters PTYProcess (R13 #12).
        exitLock.lock()
        defer { exitLock.unlock() }
        guard masterFD >= 0 else { return }
        var ws = winsize(ws_row: rows, ws_col: cols, ws_xpixel: pxWidth, ws_ypixel: pxHeight)
        _ = ioctl(masterFD, TIOCSWINSZ, &ws)
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
    /// not yet reaped. (Retained for diagnostics / the WF-3 seam contract.)
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

/// Host-side errors. Distinct from ``AislopdeskError`` (which is wire-decode only).
public enum HostError: Error, Equatable, Sendable {
    /// A POSIX syscall failed; associated value is `errno`.
    case posix(Int32)
}
