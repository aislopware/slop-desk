#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation

/// Puts the LOCAL terminal into raw mode and **guarantees restore** on every exit path:
/// `defer`, normal return, and asynchronous signals (Ctrl-C / SIGTERM / SIGHUP / crash).
///
/// The user's terminal must NEVER be left corrupted (no echo, no line discipline). To
/// honor that even when a signal fires mid-session, the saved `termios` is stashed in a
/// process-global the signal handler can read, and restore is done with the
/// async-signal-safe `tcsetattr`. We register handlers for SIGINT/SIGTERM/SIGQUIT/SIGHUP
/// that restore the terminal and then re-raise the default disposition so the process
/// dies with the right status (or, for SIGINT in raw mode, we let the byte through —
/// see `aislopdesk-client` main).
///
/// Not an actor: termios is process-global TTY state, manipulated by synchronous libc
/// calls and (necessarily) from a signal handler. The non-signal API (`enableRaw` /
/// `restore`) is guarded by an `os_unfair_lock`, but the SIGNAL handler never touches
/// that lock (`os_unfair_lock` is not async-signal-safe and would self-deadlock if a
/// signal landed while the lock was held). Instead the handler reads lock-free plain
/// process-global scalars and calls only the async-signal-safe `tcsetattr`; the handled
/// signals are blocked around the lock critical sections so the two paths cannot race.
public enum TerminalRawMode {
    /// Process-global saved attributes + the fd they belong to, so a signal handler can
    /// restore without capturing context. Written once before entering raw mode.
    ///
    /// The lock guards the *non-signal* API (`enableRaw`/`restore`/`isActive`). The signal
    /// handler must NOT touch this lock — `os_unfair_lock` is not async-signal-safe and a
    /// signal delivered while the main thread holds it would self-deadlock the handler,
    /// hanging the process with the terminal still in raw mode. The handler therefore reads
    /// the async-signal-safe plain scalars below (``signalSavedTermios`` / ``signalFD`` /
    /// ``signalActive``) and calls only the async-signal-safe `tcsetattr`.
    private final class SavedState: @unchecked Sendable {
        var lock = os_unfair_lock()
        var saved: termios?
        var fd: Int32 = -1
        var active = false
    }
    private static let state = SavedState()

    // MARK: - Async-signal-safe globals for the signal handler (NO lock)

    /// Plain process-global mirror of the saved attributes, written under the lock+signal
    /// mask in `enableRaw` and read WITHOUT any lock by the signal handler. `tcsetattr` is
    /// async-signal-safe; reading these scalars is a benign racy read (the handler runs
    /// once, just before the process dies, and only ever restores the cooked attrs).
    ///
    /// `nonisolated(unsafe)` is the deliberate escape hatch: these MUST be plain mutable
    /// memory a signal handler can touch — a lock or actor would be async-signal-unsafe
    /// (the whole point of this fix). The external synchronization is the signal mask
    /// fencing the writes in `enableRaw`/`restore` plus the single-shot handler.
    private nonisolated(unsafe) static var signalSavedTermios = termios()
    private nonisolated(unsafe) static var signalFD: Int32 = -1
    /// 1 while raw mode is engaged (so the handler is a no-op otherwise). `sig_atomic_t`
    /// is the async-signal-safe flag type.
    private nonisolated(unsafe) static var signalActive: sig_atomic_t = 0

    /// Whether raw mode is currently engaged (for diagnostics / idempotency).
    public static var isActive: Bool {
        os_unfair_lock_lock(&state.lock)
        defer { os_unfair_lock_unlock(&state.lock) }
        return state.active
    }

    // MARK: - Pure, testable termios primitives (no process-global state)

    /// Reads the current `termios` of `fd`. Throws on failure / non-tty.
    /// Pure helper (no global side effects) — unit-testable against an openpty fd.
    public static func currentAttributes(fd: Int32) throws -> termios {
        guard isatty(fd) != 0 else { throw RawModeError.notATTY }
        var t = termios()
        guard tcgetattr(fd, &t) == 0 else { throw RawModeError.tcgetattrFailed(errno) }
        return t
    }

    /// Returns a raw-mode copy of `original`: `cfmakeraw` + VMIN=1 / VTIME=0. Pure.
    public static func rawAttributes(from original: termios) -> termios {
        var raw = original
        cfmakeraw(&raw)
        withUnsafeMutableBytes(of: &raw.c_cc) { buf in
            buf[Int(VMIN)] = 1
            buf[Int(VTIME)] = 0
        }
        return raw
    }

    /// Applies `attrs` to `fd` with `TCSAFLUSH`. Pure (no global state). Throws on failure.
    public static func applyAttributes(_ attrs: termios, fd: Int32) throws {
        var copy = attrs
        guard tcsetattr(fd, TCSAFLUSH, &copy) == 0 else { throw RawModeError.tcsetattrFailed(errno) }
    }

    /// Sets the window size of `fd` via `TIOCSWINSZ` (the host-side / SIGWINCH mapping).
    /// Pure helper, unit-testable against an openpty master fd.
    @discardableResult
    public static func setWindowSize(fd: Int32, cols: UInt16, rows: UInt16, pxWidth: UInt16 = 0, pxHeight: UInt16 = 0) -> Bool {
        var ws = winsize(ws_row: rows, ws_col: cols, ws_xpixel: pxWidth, ws_ypixel: pxHeight)
        return ioctl(fd, UInt(TIOCSWINSZ), &ws) == 0
    }

    // MARK: - Process-global raw mode (used by the aislopdesk-client executable)

    /// Enters raw mode on `fd` (default stdin). Saves the current attributes first.
    /// Throws if `fd` is not a tty or `tcgetattr`/`tcsetattr` fail.
    /// - Returns: the original `termios`, so the caller can `defer { restore() }`.
    @discardableResult
    public static func enableRaw(fd: Int32 = STDIN_FILENO) throws -> termios {
        let original = try currentAttributes(fd: fd)

        // Block the handled signals across the whole enable critical section so a signal
        // delivered mid-update cannot run the handler against a half-written
        // `signalSavedTermios`/`signalActive` (and so it cannot race the lock either).
        let previousMask = blockHandledSignals()
        defer { restoreSignalMask(previousMask) }

        os_unfair_lock_lock(&state.lock)
        state.saved = original
        state.fd = fd
        state.active = true
        // Mirror into the lock-free globals the signal handler reads. Order matters: write
        // the attrs + fd BEFORE flipping `signalActive` to 1 so the handler never sees
        // active==1 with a stale fd/attrs.
        signalSavedTermios = original
        signalFD = fd
        signalActive = 1
        os_unfair_lock_unlock(&state.lock)

        // Keep ISIG OFF (cfmakeraw clears it): we deliver Ctrl-C as a raw byte to the
        // remote PTY (the remote shell's line discipline raises SIGINT there). The local
        // disconnect key is Ctrl-] (handled in the read loop), not a signal.
        let raw = rawAttributes(from: original)
        do {
            try applyAttributes(raw, fd: fd)
        } catch {
            // Roll back the active flag if we could not actually enter raw mode.
            os_unfair_lock_lock(&state.lock)
            state.active = false
            signalActive = 0
            os_unfair_lock_unlock(&state.lock)
            throw error
        }
        return original
    }

    /// Restores the saved attributes from the **non-signal** (locked) path. Idempotent and
    /// safe to call multiple times. No-op if never enabled.
    ///
    /// This is NOT the signal-handler path — the handler uses
    /// ``restoreFromSignalHandler()`` which is lock-free and async-signal-safe. The
    /// handled signals are blocked across this critical section so a signal cannot run the
    /// handler (which reads `signalActive`/`signalSavedTermios`) while this is mutating
    /// them under the lock.
    public static func restore() {
        let previousMask = blockHandledSignals()
        defer { restoreSignalMask(previousMask) }

        os_unfair_lock_lock(&state.lock)
        guard state.active, var saved = state.saved, state.fd >= 0 else {
            os_unfair_lock_unlock(&state.lock)
            return
        }
        let fd = state.fd
        state.active = false
        signalActive = 0
        os_unfair_lock_unlock(&state.lock)
        _ = tcsetattr(fd, TCSAFLUSH, &saved)
    }

    /// The async-signal-safe restore the signal handler calls: reads the lock-free plain
    /// globals and calls only `tcsetattr` (async-signal-safe). NO lock — so a signal
    /// delivered while the non-signal path holds `state.lock` cannot self-deadlock.
    private static func restoreFromSignalHandler() {
        guard signalActive != 0, signalFD >= 0 else { return }
        signalActive = 0
        _ = tcsetattr(signalFD, TCSAFLUSH, &signalSavedTermios)
    }

    /// The signals we install restoring handlers for.
    private static let handledSignals: [Int32] = [SIGINT, SIGTERM, SIGQUIT, SIGHUP]

    /// Installs signal handlers that restore the terminal then perform the default
    /// disposition (re-raise) so the process exits cleanly with the right status.
    /// Safe to call BEFORE `enableRaw` (the handler is a no-op while `signalActive == 0`),
    /// which closes the enable-time window where a signal could land after raw attrs are
    /// applied but before a handler exists. Uses `sigaction` (not `signal`) for portable
    /// semantics.
    ///
    /// The handler is fully async-signal-safe: it calls ``restoreFromSignalHandler()``
    /// (lock-free `tcsetattr` only — never `os_unfair_lock`). `sa_mask` blocks all four
    /// handled signals while the handler runs, so a second handled signal cannot pre-empt
    /// the first handler mid-restore.
    public static func installRestoreOnSignals() {
        for sig in handledSignals {
            var action = sigaction()
            action.__sigaction_u.__sa_handler = { signo in
                TerminalRawMode.restoreFromSignalHandler()
                // Re-raise with the default disposition so we die with the right status.
                signal(signo, SIG_DFL)
                raise(signo)
            }
            // Block every handled signal while this handler runs (not just sigemptyset),
            // so a second SIGTERM/SIGHUP cannot interrupt the restore in progress.
            var mask = sigset_t()
            sigemptyset(&mask)
            for blocked in handledSignals { sigaddset(&mask, blocked) }
            action.sa_mask = mask
            action.sa_flags = 0
            sigaction(sig, &action, nil)
        }
    }

    // MARK: - Signal-mask helpers (block the handled signals around lock critical sections)

    /// Blocks the handled signals on the calling thread and returns the previous mask so
    /// the caller can restore it. Used to fence the lock critical sections so the signal
    /// handler cannot run while the non-signal path mutates the shared globals.
    private static func blockHandledSignals() -> sigset_t {
        var toBlock = sigset_t()
        sigemptyset(&toBlock)
        for sig in handledSignals { sigaddset(&toBlock, sig) }
        var previous = sigset_t()
        pthread_sigmask(SIG_BLOCK, &toBlock, &previous)
        return previous
    }

    /// Restores a previously-saved signal mask.
    private static func restoreSignalMask(_ previous: sigset_t) {
        var mask = previous
        pthread_sigmask(SIG_SETMASK, &mask, nil)
    }

    /// Reads the local terminal window size via `TIOCGWINSZ`. Returns `nil` if `fd`
    /// is not a tty or the ioctl fails.
    public static func windowSize(fd: Int32 = STDIN_FILENO) -> (cols: UInt16, rows: UInt16, pxWidth: UInt16, pxHeight: UInt16)? {
        var ws = winsize()
        guard ioctl(fd, UInt(TIOCGWINSZ), &ws) == 0 else { return nil }
        return (cols: ws.ws_col, rows: ws.ws_row, pxWidth: ws.ws_xpixel, pxHeight: ws.ws_ypixel)
    }
}

public enum RawModeError: Error, CustomStringConvertible {
    case notATTY
    case tcgetattrFailed(Int32)
    case tcsetattrFailed(Int32)

    public var description: String {
        switch self {
        case .notATTY: return "stdin is not a TTY"
        case let .tcgetattrFailed(e): return "tcgetattr failed (errno \(e))"
        case let .tcsetattrFailed(e): return "tcsetattr failed (errno \(e))"
        }
    }
}
