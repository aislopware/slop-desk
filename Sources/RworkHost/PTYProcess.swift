#if canImport(Darwin)
import Darwin
#endif
import Foundation
import RworkProtocol

/// A child process attached to a pseudo-terminal (PTY) on the macOS host.
///
/// ## Spawn strategy (`DECISIONS.md` / [12] Part B §1.1)
/// `openpty()` allocates the master/slave pair with an initial `termios` (sane
/// cooked-mode defaults + `IUTF8`) and an initial `winsize`. The child is then
/// launched with **`posix_spawn`** (never `forkpty` — running the Swift/ObjC runtime
/// in a forked child before `exec` is unsafe; `DECISIONS.md` Host PTY):
///
/// - `posix_spawn_file_actions_adddup2` redirects the SLAVE fd onto child
///   stdin(0)/stdout(1)/stderr(2);
/// - `posix_spawn_file_actions_addclose` closes the MASTER fd in the child (the child
///   must never hold the master, or its EOF would never arrive on read);
/// - `posix_spawnattr_setflags(POSIX_SPAWN_SETSID)` makes the child a new **session
///   leader** (`createSession = true`).
///
/// ### Controlling terminal (the load-bearing, silently-broken part)
/// On macOS, a session leader acquires its controlling terminal the first time it
/// `open()`s a tty that is not already some session's controlling terminal **without
/// `O_NOCTTY`**. Because `POSIX_SPAWN_SETSID` makes the child a fresh session leader
/// *and* the very first fd the spawned program opens is the slave (it is dup2'd onto
/// fd 0/1/2 before any user code runs), the slave becomes the controlling terminal
/// automatically — no explicit `TIOCSCTTY` ioctl is needed. This is verified
/// empirically by `RworkHostTests.testControllingTTY` (`tty` prints `/dev/ttys*`, not
/// "not a tty"; `stty size` reflects the openpty winsize; `TIOCSWINSZ` + `SIGWINCH`
/// reflow works). See the WF-3 build-log note for the empirical finding.
///
/// `setBlocking(true)` clears `O_NONBLOCK` on the master FD around spawn — a
/// non-blocking master breaks the blocking read relay (Happy #301).
///
/// The relay (PTY ⇄ transport) is no-buffer with a `USER_INTERACTIVE` QoS read loop
/// (no intermediate ring buffer — the NoMachine NX lesson); that lives in
/// ``HostSession`` (the ``PTYReadLoop`` it owns).
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
        rows: UInt16 = 24
    ) throws {
        #if canImport(Darwin)
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
        PTYProcess.setBlocking(master)

        // Build file actions: child gets the slave on 0/1/2 and never holds the master.
        var actions = posix_spawn_file_actions_t(nil as OpaquePointer?)
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, slave, 0)
        posix_spawn_file_actions_adddup2(&actions, slave, 1)
        posix_spawn_file_actions_adddup2(&actions, slave, 2)
        // Close the original slave fd in the child once it has been dup2'd (it may be
        // >2). Then close the master in the child — the child must not hold it.
        if slave > 2 {
            posix_spawn_file_actions_addclose(&actions, slave)
        }
        posix_spawn_file_actions_addclose(&actions, master)

        // POSIX_SPAWN_SETSID: new session leader. The first uncontrolled tty the child
        // opens without O_NOCTTY (the dup2'd slave) becomes its controlling terminal —
        // so job control + SIGWINCH work. Verified empirically (testControllingTTY).
        var attr = posix_spawnattr_t(nil as OpaquePointer?)
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))

        // argv: argv[0] then the rest. All C strings are built here in the PARENT
        // (no Swift runtime work in the child — posix_spawn execs immediately).
        let argv0Value = argv0 ?? executable
        let argvStrings = [argv0Value] + arguments
        var argv: [UnsafeMutablePointer<CChar>?] = argvStrings.map { strdup($0) }
        argv.append(nil)

        // envp: "KEY=VALUE" entries.
        let envStrings = environment.map { "\($0.key)=\($0.value)" }
        var envp: [UnsafeMutablePointer<CChar>?] = envStrings.map { strdup($0) }
        envp.append(nil)

        defer {
            for p in argv where p != nil { free(p) }
            for p in envp where p != nil { free(p) }
        }

        var childPID: pid_t = 0
        let rc = executable.withCString { path in
            posix_spawn(&childPID, path, &actions, &attr, argv, envp)
        }

        // Parent closes the slave unconditionally — the parent only uses the master.
        close(slave)

        guard rc == 0 else {
            close(master)
            throw HostError.posix(rc)
        }

        self.masterFD = master
        self.pid = childPID
        startReaper(pid: childPID)
        #else
        throw HostError.notImplemented("PTYProcess.spawn — Darwin only")
        #endif
    }

    #if canImport(Darwin)
    /// Sets the standard control characters (VINTR, VEOF, VERASE, …) to sane defaults
    /// so cooked-mode editing behaves like a normal login terminal.
    private func setControlChars(_ term: inout termios) {
        withUnsafeMutableBytes(of: &term.c_cc) { raw in
            let cc = raw.bindMemory(to: cc_t.self)
            func set(_ index: Int32, _ value: Int32) { cc[Int(index)] = cc_t(value) }
            set(VEOF, 4)       // ^D
            set(VEOL, 0xFF)
            set(VEOL2, 0xFF)
            set(VERASE, 0x7F)  // DEL
            set(VWERASE, 23)   // ^W
            set(VKILL, 21)     // ^U
            set(VREPRINT, 18)  // ^R
            set(VINTR, 3)      // ^C
            set(VQUIT, 28)     // ^\
            set(VSUSP, 26)     // ^Z
            set(VDSUSP, 25)    // ^Y
            set(VSTART, 17)    // ^Q
            set(VSTOP, 19)     // ^S
            set(VLNEXT, 22)    // ^V
            set(VDISCARD, 15)  // ^O
            set(VMIN, 1)
            set(VTIME, 0)
        }
    }
    #endif

    // MARK: setBlocking

    /// Clears `O_NONBLOCK` on `fd` so reads/writes block (Happy #301).
    /// Exposed for WF-3 wiring and tests.
    public static func setBlocking(_ fd: Int32) {
        #if canImport(Darwin)
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK)
        }
        #endif
    }

    // MARK: Resize

    /// Applies a terminal size to the PTY via `TIOCSWINSZ` (driven by `resize`). The
    /// kernel then delivers `SIGWINCH` to the child's foreground process group.
    public func setWindowSize(cols: UInt16, rows: UInt16, pxWidth: UInt16 = 0, pxHeight: UInt16 = 0) {
        #if canImport(Darwin)
        guard masterFD >= 0 else { return }
        var ws = winsize(ws_row: rows, ws_col: cols, ws_xpixel: pxWidth, ws_ypixel: pxHeight)
        _ = ioctl(masterFD, TIOCSWINSZ, &ws)
        #endif
    }

    // MARK: Lifecycle

    /// Sends `SIGTERM` to the child (it is a session leader, so this reaches the group
    /// via the controlling tty's hangup machinery once the master closes too).
    public func terminate() {
        #if canImport(Darwin)
        guard pid > 0 else { return }
        kill(pid, SIGTERM)
        #endif
    }

    /// Closes the PTY master fd exactly once and marks it `-1`.
    ///
    /// On a successful ``spawn(_:arguments:environment:argv0:cols:rows:)`` the master fd
    /// is held open for the life of the session (the host reads child output / writes
    /// input through it). It is **not** closed by ``terminate()`` (which only signals the
    /// child) so the relay can still drain the child's final output before EOF. The owner
    /// (``HostSession/shutdown()``) calls this **after stopping the read loop** so no
    /// concurrent `read()` can race the close; a `deinit` safety net catches any path
    /// that forgot. Idempotent.
    ///
    /// Without this the master fd leaked once per spawn — a long-running daemon exhausted
    /// the default 256-fd soft limit after ~250 sessions and `openpty` began returning
    /// `EMFILE`.
    public func closeMaster() {
        #if canImport(Darwin)
        exitLock.lock()
        let fd = masterFD
        masterFD = -1
        exitLock.unlock()
        if fd >= 0 { close(fd) }
        #endif
    }

    deinit {
        #if canImport(Darwin)
        // Safety net: if an owner forgot to closeMaster(), don't leak the fd. By the time
        // deinit runs nothing else references this object, so no read can race the close.
        if masterFD >= 0 { close(masterFD) }
        #endif
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
        exitLock.lock(); defer { exitLock.unlock() }
        return exitCode
    }

    #if canImport(Darwin)
    /// Spawns a dedicated blocking `waitpid` thread that reaps the child and surfaces
    /// the exit status (used as `WireMessage.exit(code:)` by the relay). A dedicated
    /// thread (not SIGCHLD) keeps reaping local to this process object and avoids
    /// global signal-handler coordination.
    private func startReaper(pid: pid_t) {
        Thread.detachNewThread { [weak self] in
            var status: Int32 = 0
            while true {
                let r = waitpid(pid, &status, 0)
                if r == pid { break }
                if r == -1 && errno != EINTR { break }
            }
            let code: Int32
            if (status & 0o177) == 0 {
                // WIFEXITED: high byte is the exit status.
                code = (status >> 8) & 0xFF
            } else {
                // WIFSIGNALED: report 128 + signal (shell convention).
                code = 128 + (status & 0o177)
            }
            self?.completeExit(code: code)
        }
    }
    #endif

    private func completeExit(code: Int32) {
        exitLock.lock()
        guard !reaped else { exitLock.unlock(); return }
        reaped = true
        exitCode = code
        let waiters = exitWaiters
        exitWaiters.removeAll()
        exitLock.unlock()
        for w in waiters { w.resume(returning: code) }
    }
}

/// Host-side errors. Distinct from ``RworkError`` (which is wire-decode only).
public enum HostError: Error, Equatable, Sendable {
    /// A seam that WF-3 has not implemented yet (or a non-Darwin platform).
    case notImplemented(String)
    /// A POSIX syscall failed; associated value is `errno`.
    case posix(Int32)
}
