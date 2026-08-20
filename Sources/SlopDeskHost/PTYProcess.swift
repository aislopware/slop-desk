import Darwin
import Foundation
import SlopDeskSupervisor

/// A child process attached to a pseudo-terminal (PTY) on the macOS host.
///
/// ## hostd does not fork. It adopts.
/// This object used to `openpty` + `fork` + `execve` a shell itself. It no longer contains any of
/// that, and no Swift in this repo does: `slopdesk-superd` — a separate Rust daemon under launchd
/// — is the only process that forks a pane, and it stays the child's parent for the pane's whole
/// life (`docs/51`). hostd asks for a shell over an `AF_UNIX` socket and receives a **duplicate**
/// of the PTY master through `SCM_RIGHTS`.
///
/// That one indirection is the entire point of the design. The last close of a PTY master sends
/// `SIGHUP` to the foreground process group, so whoever holds the only copy holds the shell's life
/// in their hands. When that was hostd, restarting hostd killed every running `claude`. Now superd
/// keeps a copy, hostd's copy dies with hostd, and the shell never notices — a hostd rebuild costs
/// a reconnect, not a session (`DECISIONS.md` 2026-08-11).
///
/// It also means this file has no fork-window contract to keep. The pre-`execve` discipline — no
/// allocator, no runtime, no panic between `fork` and `execve` — moved to
/// `rust/slopdesk-posix/src/pty.rs`, and its disassembly pin moved with it
/// (`fork_window_contract.rs`). There is deliberately no second copy here to drift.
///
/// ### What is still hostd's
/// Everything downstream of holding an fd: the read loop, resize, the redraw dance, the teardown
/// ladder, cwd policy. Signals and the final close route through superd — not because hostd
/// *cannot* `kill(2)` a non-child (it can), but so superd's record of the pane stays true, and so
/// "hostd went away" and "the user closed the pane" never look the same.
///
/// The relay (PTY ⇄ transport) is no-buffer with a `USER_INTERACTIVE` QoS read loop (no
/// intermediate ring buffer — the NoMachine NX lesson); that lives in ``MuxChannelSession`` (the
/// ``PaneOutputStream`` it owns).
///
/// `masterFD` / `pid` are immutable-after-adopt and safe to share; the only mutable state is the
/// one-shot exit plumbing, guarded by an `NSLock`.
public final class PTYProcess: @unchecked Sendable {
    /// Master side of the PTY (host reads child output / writes child input here).
    /// `-1` until ``spawn(_:arguments:environment:argv0:cwd:cols:rows:paneID:sessionID:)`` succeeds.
    ///
    /// A duplicate of superd's, installed by the kernel out of an `SCM_RIGHTS` message. Closing it
    /// does not hang up the shell; superd still holds the original.
    public private(set) var masterFD: Int32 = -1

    /// PID of the child, or `-1` before spawn. Valid to `kill`, never to `waitpid` — this process
    /// is not its parent, and only superd can reap it.
    public private(set) var pid: pid_t = -1

    /// The pane identity superd files this child under. Every later verb quotes it.
    public private(set) var paneID: String?
    /// When superd forked this pane, in unix seconds — the identity of the pane LIFE, as opposed to
    /// of the session. `0` for a pane that was never spawned or adopted.
    ///
    /// Stamped onto the journal's resume sidecar, because an offset into a pane's output stream is
    /// only meaningful for the fork that produced it.
    public private(set) var paneSpawnedAt: Int64 = 0

    /// Whether ``spawn(_:arguments:environment:argv0:cwd:cols:rows:paneID:sessionID:)`` ended up
    /// TAKING OVER an existing pane instead of forking one.
    ///
    /// superd refuses a duplicate pane id, and that refusal is not always a mistake: it can mean the
    /// shell under that id is still running, left behind by a hostd that relinquished it and never
    /// adopted it back (adoption off, or it failed for this one pane). `spawn` adopts it rather than
    /// hand the user a permanently dead tab — and the caller has to know, because a pane with a
    /// history needs a resume offset, not the 0 that is right for a fresh fork.
    public private(set) var tookOverASurvivor = false

    /// One-shot exit plumbing: the exit code superd reported and any continuation awaiting it.
    private let exitLock = NSLock()
    private var exitCode: Int32?
    private var exitWaiters: [CheckedContinuation<Int32, Never>] = []
    private var reaped = false

    /// The supervisor this pane belongs to. Held for the pane's whole life: signals, resizes and
    /// the final release all go through it.
    private let supervisor: SupervisorClient

    public init(supervisor: SupervisorClient) {
        self.supervisor = supervisor
    }

    // MARK: Spawn

    /// Asks superd for a shell on a fresh PTY and adopts the master it sends back.
    ///
    /// - Parameters:
    ///   - executable: absolute path to the program (e.g. the user's `$SHELL`).
    ///   - arguments: argv (excluding argv[0]; pass `argv0` to override argv[0],
    ///     e.g. `-zsh` for a login shell).
    ///   - environment: full environment for the child. Pass a curated env (the caller owns
    ///     `TERM=xterm-ghostty`, `CLAUDE_CODE_NO_FLICKER=1`, etc.). superd overlays its own stable
    ///     socket paths over whatever this says about them, and passes the rest through untouched —
    ///     which is why the curated env can keep changing without superd needing a rebuild.
    ///   - argv0: the value for `argv[0]`. Defaults to `executable`. A login shell uses
    ///     a leading `-` (e.g. `-zsh`).
    ///   - cols/rows: initial winsize in character cells.
    ///   - paneID: the identity superd files this pane under, and the value the child sees as
    ///     `SLOPDESK_PANE_ID`. It must be recoverable by a *later* hostd, so it is derived from
    ///     durable things (`docs/51` §5), never from a connection's address.
    ///   - sessionID: opaque to superd; hostd's key back to the scrollback journal after a restart.
    ///   - owner: which hostd this pane belongs to (``HostServer/supervisorOwnerIdentity``). Opaque
    ///     to superd, which stores it and hands it back in `list` — it is how a second daemon on the
    ///     same machine tells its own predecessor's surviving panes from a stranger's live ones.
    ///   - shellIntegration: ask superd to install the generated `ZDOTDIR` shim (resize reprint,
    ///     OSC 133 marks, cursor shape) for this child. Only an interactive login shell wants it —
    ///     a `$SHELL -c …` pane has no prompt cycles for prompt machinery to hook. superd decides
    ///     whether it is possible and owns the generated directory for the child's whole life.
    ///
    ///     It also decides whether the pane is SNIFFED: a shell with prompt machinery is the only
    ///     thing that talks out of band, so a pane that does not ask for the shim is not scanned
    ///     and never receives a sniff frame (`docs/51` §6.4).
    ///   - blocks: ask superd to segment this pane's output into command blocks and hold each
    ///     finished command's captured bytes. `false` — the operator's `SLOPDESK_BLOCKS=0` — means
    ///     no segmenter touches the stream and no `0x05` frame ever arrives (`docs/51` §6.14).
    public func spawn(
        _ executable: String,
        arguments: [String] = [],
        environment: [String: String],
        argv0: String? = nil,
        cwd: String? = nil,
        cols: UInt16 = 80,
        rows: UInt16 = 24,
        paneID: String,
        sessionID: String,
        owner: String? = nil,
        shellIntegration: Bool = false,
        blocks: Bool = false,
        journal: JournalSpawnRequest? = nil,
    ) throws {
        precondition(masterFD == -1, "PTYProcess.spawn called twice")

        // Validate the requested cwd HOST-SIDE, before the request goes out: the child's `chdir`
        // runs pre-`execve` and is best-effort, so a stale/deleted/foreign/`~`-style path would
        // silently leave the pane in superd's cwd rather than the user's. Repairing it here is
        // policy, and policy is hostd's — superd is told a directory, not asked to choose one.
        let resolvedCwd = Self.resolveCwd(cwd, home: environment["HOME"])

        // Registered BEFORE the request: a child that dies instantly (bad executable, `exit 1`) can
        // be reaped and broadcast while this thread is still inside `spawn`, and a dropped `exited`
        // leaves a dead pane looking alive until someone types into it.
        supervisor.observeExit(ofPane: paneID) { [weak self] code in self?.completeExit(code: code) }

        let spawned: (record: PaneRecord, masterFD: Int32)
        do {
            spawned = try supervisor.spawn(SpawnRequest(
                paneID: paneID,
                sessionID: sessionID,
                executable: executable,
                argv0: argv0,
                arguments: arguments,
                environment: environment,
                cwd: resolvedCwd,
                rows: rows,
                cols: cols,
                owner: owner,
                shellIntegration: shellIntegration,
                // The bridge value crosses VERBATIM. superd owns both the parse and the built-in
                // slow-command list, so hostd resolving it here would put the second copy of that
                // list back — unset, cleared and set are three different answers and all three are
                // expressible as they stand (`AutoProgressMatcher` is gone; see `docs/DECISIONS`).
                blocks: blocks
                    ? BlocksRequest(autoProgressCommands: HostEnvironment.autoProgressCommandsRaw())
                    : nil,
                // Where superd keeps this pane's transcript, and how much of it. Present only when
                // disk scrollback is on for a re-presentable session id — superd writes nothing
                // when it is absent. hostd never writes the file itself: superd numbers the stream
                // it would have to number bytes against (`docs/51` §6.8).
                journal: journal,
            ))
        } catch {
            // superd refuses a duplicate pane id, and it is right to: two forks under one id would
            // orphan the first child. But a duplicate here does not mean a mistake — it means the
            // pane this id names is STILL RUNNING, left behind by a hostd that relinquished it and
            // never adopted it back (adoption is off, or it failed for this one pane). Refusing
            // would hand the user a dead tab per surviving shell, permanently, and the only cure
            // would be killing superd — which is killing their agents.
            //
            // So the surviving pane is taken over instead. Not blindly: a pane another live hostd
            // is ATTACHED to is that daemon's, and this rethrows rather than steal it.
            if let survivor = try? adoptSurvivor(paneID: paneID) {
                adopt(
                    masterFD: survivor.masterFD, pid: survivor.record.pid, paneID: paneID,
                    spawnedAt: survivor.record.spawnedAt,
                )
                // Said out loud, because the caller's next decision depends on it: what came back
                // is a shell with a HISTORY, not the fresh fork it asked for, and its output stream
                // must not be subscribed from offset 0 on top of a restored transcript.
                tookOverASurvivor = true
                return
            }
            supervisor.forgetExitHandler(ofPane: paneID)
            throw error
        }

        adopt(
            masterFD: spawned.masterFD, pid: spawned.record.pid, paneID: paneID,
            spawnedAt: spawned.record.spawnedAt,
        )
    }

    /// Takes over the unattached pane already filed under `paneID`, or throws.
    ///
    /// The `attached` check is what keeps this from being a second daemon's pane theft: it means
    /// some hostd holds a duplicate of that master right now, which after the rekey to a bare
    /// session UUID is the only way to tell one daemon's panes from another's.
    private func adoptSurvivor(paneID: String) throws -> (record: PaneRecord, masterFD: Int32) {
        let records = try supervisor.list()
        guard let existing = records.first(where: { $0.paneID == paneID }), !existing.attached else {
            throw ClientError.paneHeldElsewhere(paneID)
        }
        return try supervisor.adopt(paneID: paneID)
    }

    /// Why a takeover was not possible. Deliberately local: it never leaves ``spawn``, whose own
    /// error — superd's refusal — is the one a caller sees.
    private enum ClientError: Error {
        case paneHeldElsewhere(String)
    }

    /// Takes ownership of a master fd superd handed over, and of the child on the other end of it.
    ///
    /// Two callers: ``spawn(_:arguments:environment:argv0:cwd:cols:rows:paneID:sessionID:)``, and
    /// the restart path — a fresh hostd that `adopt`s a pane an earlier hostd left running. The
    /// second is why this is separate: from here down, a pane that was spawned an hour ago by a
    /// binary that no longer exists is indistinguishable from one spawned a moment ago.
    public func adopt(masterFD: Int32, pid: pid_t, paneID: String, spawnedAt: Int64 = 0) {
        precondition(self.masterFD == -1, "PTYProcess adopted twice")
        self.masterFD = masterFD
        self.pid = pid
        self.paneID = paneID
        paneSpawnedAt = spawnedAt
        // The exit route, wired here rather than only in `spawn`: an adopted pane's child can die
        // like any other, and a `PTYProcess` that never hears about it reports a corpse as running
        // forever. `spawn` registers this itself, EARLIER — before the request, so an instantly
        // dying child cannot be reaped before anyone is listening — and re-registering here simply
        // replaces that closure with an identical one.
        supervisor.observeExit(ofPane: paneID) { [weak self] code in self?.completeExit(code: code) }
    }

    /// Builds this pane's output stream.
    ///
    /// Here rather than at the call site because the pane id and the supervisor client are both
    /// private to this type, and because there is exactly one correct pairing of them: a stream
    /// built against the wrong pane id subscribes successfully and delivers another window's bytes.
    ///
    /// A pane with no identity yet — never spawned, never adopted — gets a stream that reports EOF
    /// the moment it starts, which is what the old `PTYReadLoop` did with `masterFD == -1`. That
    /// shape is load-bearing rather than lenient: most of the host suite wants the `MuxChannelSession`
    /// OBJECT and never a child, and its control and input planes are not dependents of the output
    /// path — a `ping` must still be answered by a session whose shell does not exist.
    @preconcurrency
    public func makeOutputStream(
        fromOffset: UInt64 = 0,
        onChunk: @escaping @Sendable (Data, UInt64, [SniffedEvent], [BlockEvent]) -> Void,
        onEOF: @escaping @Sendable () -> Void,
    ) -> PaneOutputStream {
        PaneOutputStream(
            supervisor: supervisor,
            paneID: paneID,
            fromOffset: fromOffset,
            onChunk: onChunk,
            onEOF: onEOF,
        )
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

        // No cwd requested ⇒ HOME, not the daemon's cwd. `chdir` is the ONLY thing standing between the
        // child and whatever directory `hostd` happens to have been launched from — inheriting that would
        // open every fresh pane inside the launcher's project (a login terminal opens at HOME).
        guard let requested, !requested.isEmpty else { return homeFallback }
        guard let expanded = expandTilde(requested), usableDir(expanded) else { return homeFallback }
        return expanded
    }

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
        guard masterFD >= 0 else {
            exitLock.unlock()
            return
        }
        var ws = winsize(ws_row: rows, ws_col: cols, ws_xpixel: pxWidth, ws_ypixel: pxHeight)
        _ = ioctl(masterFD, TIOCSWINSZ, &ws)
        let identity = paneID
        exitLock.unlock()

        // Tell superd too, so its `PaneRecord` stops being a lie.
        //
        // The ioctl above is the only write to the terminal — one writer, hostd's own duplicate, as
        // `docs/51` §6.9 requires. superd's `resize` verb RECORDS the numbers and touches no
        // `TIOCSWINSZ`, which is what makes this notification safe to fire and forget: it can land
        // after the redraw jiggle's shrink without undoing it. What it buys is the record —
        // superd's spawn-time 24×80 is what `list` reports, and a stale one there is a lie about a
        // 200×50 pane in every log and every enumeration.
        guard let identity else { return }
        supervisor.resize(paneID: identity, rows: rows, cols: cols)
    }

    /// Retires superd's sniffer title-coalescing anchor for this pane.
    ///
    /// Called when a detected agent EXITS. superd dedupes a title against the last one it emitted,
    /// and the next agent's opening title is very often byte-identical to the one just retired
    /// (`✳ Claude Code`) — deduped away, the pane simply stays untitled. Fire-and-forget: the anchor
    /// is an optimisation, so losing the race costs a stale title, not a wrong one.
    ///
    /// A no-op for a pane with no identity, which is every session in the suite that never spawns.
    public func forgetTitleCoalescing() {
        exitLock.lock()
        let identity = paneID
        exitLock.unlock()
        guard let identity else { return }
        supervisor.forgetTitleCoalescing(paneID: identity)
    }

    /// One finished command block's retained output, from superd's ring.
    ///
    /// The ring lives there rather than here because hostd's did not survive its own restart: a
    /// client that clicked a block from before a `make host-restart` got an empty body for output
    /// superd had never stopped holding (`docs/51` §6.14).
    ///
    /// - Returns: `nil` for a pane with no identity or no tap. An EMPTY array is the other answer
    ///   and a different one: the block aged out of the ring, or never existed.
    public func blockOutput(index: UInt32) -> [UInt8]? {
        guard let identity = paneIdentity() else { return nil }
        return try? supervisor.blockOutput(paneID: identity, index: index)
    }

    /// Every block superd's tap still knows about this pane, ascending — the reattach backfill.
    public func blockSnapshot() -> [BlockMetadata]? {
        guard let identity = paneIdentity() else { return nil }
        return try? supervisor.blockSnapshot(paneID: identity)
    }

    /// The agent-control read: recent blocks with their bytes, the running command, and the index
    /// the next one will close under — one round trip, because the three are only consistent with
    /// each other if superd read them together.
    public func blockControl(limit: Int) -> BlocksReply? {
        guard let identity = paneIdentity() else { return nil }
        return try? supervisor.blockControl(paneID: identity, limit: limit)
    }

    /// The pane id under ``exitLock``, which is the TOCTOU discipline every superd call here keeps.
    private func paneIdentity() -> String? {
        exitLock.lock()
        defer { exitLock.unlock() }
        return paneID
    }

    /// The PTY's current window size via `TIOCGWINSZ`, or `nil` on a closed/unspawned master.
    /// Same `exitLock` TOCTOU discipline as ``setWindowSize(cols:rows:pxWidth:pxHeight:)``.
    /// Surfaced by the agent-control `list-panes` verb (`rows`/`cols`).
    public func currentWindowSize() -> (rows: UInt16, cols: UInt16)? {
        guard let full = currentWindowSizeWithPixels() else { return nil }
        return (rows: full.rows, cols: full.cols)
    }

    /// The full `TIOCGWINSZ`, pixel fields included.
    ///
    /// The size fold compares its resolved grid against the LIVE winsize to decide whether an apply
    /// is needed, and the cell-metric pixels are part of what a client asked for: comparing only
    /// rows/cols would silently swallow a DPI change that never reaches the app.
    public func currentWindowSizeWithPixels() -> (rows: UInt16, cols: UInt16, pxWidth: UInt16, pxHeight: UInt16)? {
        exitLock.lock()
        defer { exitLock.unlock() }
        guard masterFD >= 0 else { return nil }
        var ws = winsize()
        guard ioctl(masterFD, TIOCGWINSZ, &ws) == 0 else { return nil }
        return (rows: ws.ws_row, cols: ws.ws_col, pxWidth: ws.ws_xpixel, pxHeight: ws.ws_ypixel)
    }

    // MARK: Redraw jiggle (full-repaint resize dance)

    /// Opaque token from ``beginRedrawJiggle()`` — carries the pre-jiggle size for
    /// ``endRedrawJiggle(_:)`` to restore, plus the shrunk size so the restore can detect (and
    /// yield to) an intervening client resize.
    public struct RedrawJiggle: Sendable {
        let original: winsize
        let jiggled: winsize
    }

    /// Full-repaint "resize dance", step 1: shrink the PTY by one ROW (one COLUMN for a
    /// single-row PTY) via `TIOCSWINSZ`, preserving the pixel fields.
    ///
    /// Why a real size change and not ``nudgeRedraw()``: differential renderers (Claude Code's
    /// full-screen TUI) keep an in-memory model of the screen and, on a SIGWINCH whose size is
    /// unchanged, only repaint the rows they believe changed. After a cold-reattach replay — whose
    /// transcript is transform-collapsed, so the live alt-screen frame arrives incomplete — that
    /// leaves the collapsed rows (input dividers, status line) permanently blank. Shrinking by one
    /// row is a REAL size change: the kernel delivers SIGWINCH and the app must re-layout the whole
    /// frame. The caller holds the shrunk size briefly (so the app's event loop observes it — two
    /// back-to-back ioctls would coalesce into "size unchanged"), then calls
    /// ``endRedrawJiggle(_:)`` for the second full re-layout at the true size.
    ///
    /// Returns `nil` on a closed/unspawned master or a degenerate 1×1 PTY — callers fall back to a
    /// plain ``nudgeRedraw()``. Same `exitLock` TOCTOU discipline as
    /// ``setWindowSize(cols:rows:pxWidth:pxHeight:)``.
    public func beginRedrawJiggle() -> RedrawJiggle? {
        exitLock.lock()
        defer { exitLock.unlock() }
        guard masterFD >= 0 else { return nil }
        var ws = winsize()
        guard ioctl(masterFD, TIOCGWINSZ, &ws) == 0 else { return nil }
        var jiggled = ws
        if jiggled.ws_row > 1 {
            jiggled.ws_row -= 1
        } else if jiggled.ws_col > 1 {
            jiggled.ws_col -= 1
        } else {
            return nil
        }
        var apply = jiggled
        _ = ioctl(masterFD, TIOCSWINSZ, &apply)
        return RedrawJiggle(original: ws, jiggled: jiggled)
    }

    /// Full-repaint "resize dance", step 2: restore the pre-jiggle size (second real size change →
    /// second full re-layout, now at the size the client renders).
    ///
    /// Yields to an intervening resize: if the CURRENT size no longer matches the shrunk one, a
    /// client `.resize` landed during the hold — its own SIGWINCH already forced the full repaint
    /// at the size the client actually wants, and restoring the stale pre-jiggle size would stomp
    /// it. Safe no-op on a closed master.
    public func endRedrawJiggle(_ jiggle: RedrawJiggle) {
        exitLock.lock()
        defer { exitLock.unlock() }
        guard masterFD >= 0 else { return }
        var current = winsize()
        guard ioctl(masterFD, TIOCGWINSZ, &current) == 0 else { return }
        guard current.ws_row == jiggle.jiggled.ws_row, current.ws_col == jiggle.jiggled.ws_col,
              current.ws_xpixel == jiggle.jiggled.ws_xpixel, current.ws_ypixel == jiggle.jiggled.ws_ypixel
        else { return }
        var restore = jiggle.original
        _ = ioctl(masterFD, TIOCSWINSZ, &restore)
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

    /// Sends `SIGHUP` to the child — the "terminal closed" signal a real emulator delivers
    /// when its window goes away. An interactive shell treats it as a deliberate
    /// end-of-session: zsh persists its in-memory command history to `$HISTFILE` before
    /// exiting (it IGNORES `SIGTERM`, and `SIGKILL` discards everything typed since launch),
    /// so the destroy-path ladder (``MuxChannelSession/shutdown()``) leads with this signal —
    /// without it, every pane close / daemon stop / eviction silently throws away the user's
    /// typed history. Pinned by `testDestroyPathTeardownPersistsInteractiveZshHistory`.
    public func hangup() {
        send(signal: SIGHUP)
    }

    /// Sends `SIGTERM` to the child (it is a session leader, so this reaches the group
    /// via the controlling tty's hangup machinery once the master closes too).
    public func terminate() {
        send(signal: SIGTERM)
    }

    /// Sends `SIGKILL` to the child — the un-ignorable escalation when a `SIGTERM` did not
    /// take (a child that blocks/ignores `SIGTERM`, or a foreground job holding the slave
    /// open). Used by ``MuxChannelSession/shutdown()`` as the fallback so the parked
    /// `read()` on the master is GUARANTEED to return (slave closes on the child's death →
    /// master EOFs/EIOs) and a subsequent ``closeMaster()`` cannot block. A no-op once the
    /// child is reaped (`pid` is immutable-after-spawn, but the kernel just drops a signal
    /// to a dead-and-reaped pid).
    public func forceTerminate() {
        send(signal: SIGKILL)
    }

    /// Asks superd to signal the child.
    ///
    /// hostd could `kill(2)` it directly — a same-uid process may signal a non-child — and that is
    /// exactly why this goes the long way instead. superd is the only holder of the pane's true
    /// state, and a shell that dies from a signal superd never saw is a pane superd still believes
    /// is alive: it keeps the master fd open and the record in its table until the reaper catches
    /// up. Routing through the socket keeps the two in step, and costs one `AF_UNIX` round trip
    /// (~11µs) on a path that only runs at teardown.
    ///
    /// Best-effort by design: the child may already be gone, or superd may have restarted. Neither
    /// is worth failing a teardown over — the ladder above escalates anyway.
    private func send(signal number: Int32) {
        guard pid > 0, let paneID else { return }
        do {
            try supervisor.signal(paneID: paneID, signal: number)
        } catch {
            // Nothing to escalate to: this IS the escalation path.
        }
    }

    /// Waits (bounded) for the child to be reaped, and no longer drains the master itself.
    ///
    /// ## What this used to do, and why it stopped
    /// Between `hangup()` and the `SIGKILL` escalation there used to be nobody reading the master:
    /// `PTYReadLoop.stop()` had already run. A zsh caught mid-prompt-redraw then sits BLOCKED in
    /// `tcsetattr(TCSADRAIN)` (zle's `zsetterm`, waiting for the output queue to empty), never
    /// processes the `SIGHUP`, never persists its history, and rides the `SIGKILL`. So this method
    /// opened a private `dup()` and consumed-and-discarded bytes until the exit landed, purely to
    /// keep that queue moving.
    ///
    /// superd's pump made the premise false. It drains every pane for the pane's whole life, and
    /// hostd unsubscribing does not stop it — that is the entire point of the pump. The queue keeps
    /// moving on its own, so the shell's hangup save completes without help.
    ///
    /// Keeping the drain would now be actively wrong rather than merely redundant. It was a SECOND
    /// reader on the same file description, so it would steal bytes the pump owed to whatever else
    /// was still subscribed; and it set `O_NONBLOCK` on a description shared with the pump, which
    /// `SCM_RIGHTS` makes the very same description superd reads.
    ///
    /// The name survives the change because the CONTRACT did: callers on the destroy path want a
    /// bounded wait that does not wedge a shell mid-redraw, and they still get one.
    @discardableResult
    public func waitUntilExitedDrainingMaster(timeout: TimeInterval) -> Bool {
        waitUntilExited(timeout: timeout)
    }

    /// Blocks the CALLER until superd reports the child exited, or `timeout` elapses, whichever
    /// comes first. Synchronous, poll-based — ``MuxChannelSession/shutdown()`` is not `async` and
    /// so cannot `await waitForExit()` inline, but it must still let the parked `read()` drain
    /// before closing the master. This does NOT itself call `waitpid` (it cannot — see The reaper
    /// below); it only WAITS for superd's `exited` to land, polling the one-shot
    /// ``waitExitCode()`` peek.
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
    /// The fd is held open for the life of the session (the host reads child output / writes input
    /// through it). It is **not** closed by ``terminate()`` (which only signals the child) so the
    /// relay can still drain the child's final output before EOF. The owner
    /// (``MuxChannelSession/shutdown()``) calls this **after stopping the read loop** so no
    /// concurrent `read()` can race the close; a `deinit` safety net catches any path that forgot.
    /// Idempotent.
    ///
    /// Without this the master fd leaked once per pane — a long-running daemon exhausted the
    /// default 256-fd soft limit after ~250 sessions and `openpty` began returning `EMFILE`.
    ///
    /// ## This no longer hangs up the shell
    /// The last close of a PTY master `SIGHUP`s the foreground group, and this used to BE the last
    /// close. It is not any more: superd holds the original, and the fd closed here is a duplicate
    /// the kernel installed out of an `SCM_RIGHTS` message. Ending the pane for good is
    /// ``release()`` — a separate, explicit act, which is the distinction that lets hostd exit
    /// without taking the shells with it (`docs/51` §2).
    public func closeMaster() {
        exitLock.lock()
        let fd = masterFD
        masterFD = -1
        exitLock.unlock()
        if fd >= 0 { close(fd) }
    }

    /// Ends the pane for good: superd drops its own master fd, and the shell finally gets its
    /// `SIGHUP`.
    ///
    /// The counterpart to ``closeMaster()``, and the line the whole daemon is drawn along. Closing
    /// hostd's fd means "hostd is done looking at this pane"; this means "this pane is over". Only
    /// a deliberate close — the user closing a tab, an `exited` already observed — may call it.
    /// **Never call it on hostd shutdown**: doing so would restore exactly the behaviour superd
    /// exists to remove, killing every running agent on every rebuild.
    ///
    /// - Parameter kill: `false` when the child is already known dead and this is bookkeeping.
    /// - Returns: whether superd accepted it. `false` means the pane is still out there.
    @discardableResult
    public func release(kill: Bool = true) -> Bool {
        guard let paneID else { return false }
        do {
            try supervisor.release(paneID: paneID, kill: kill)
            return true
        } catch {
            // superd unreachable. The pane outlives us either way; a restarted hostd will find it
            // in `list` and can release it then — which is why the caller reports this rather than
            // letting a tab the user closed come back, adopted, after the next restart.
            return false
        }
    }

    deinit {
        // Safety net: if an owner forgot to closeMaster(), don't leak the fd. By the time
        // deinit runs nothing else references this object, so no read can race the close.
        //
        // Note what this does NOT do: release the pane. A `PTYProcess` being deallocated is a hostd
        // event, not a user one, and the pane must survive it.
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

    // MARK: The reaper

    //
    // There is no reaper here, and there cannot be one: `waitpid` is a privilege of the PARENT, and
    // this process is not the child's parent — superd is. It reaps (one blocking thread per pane,
    // in `registry.rs`), decodes the wait status by the same `128 + signal` convention this file
    // used to, and pushes an `exited` notification. `SupervisorClient` routes that to
    // `completeExit`, so everything downstream — `waitForExit`, `waitExitCode`, the teardown
    // ladder — is unchanged.
    //
    // A hostd that is not connected to superd therefore never learns that a pane died. That is not
    // a gap to paper over with a local `waitpid` fallback: `waitpid` would return ECHILD and the
    // pane would be reported killed while its shell is in fact fine. The honest signal is the
    // dropped connection, which `onDisconnect` already reports.

    /// Records an exit code exactly as an `exited` notification would.
    ///
    /// Test seam: hang-safe unit tests drive child-exited branches (`isChildExited() == true`) on a
    /// pane that was never spawned, with no real child forked or killed anywhere.
    func completeExitForTesting(code: Int32) { completeExit(code: code) }

    /// Declares the child gone because the CUSTODIAN is gone.
    ///
    /// hostd cannot `waitpid` a pane it did not fork, so every exit it ever learns about arrives as
    /// superd's `exited` notice. When superd itself has restarted, the shells it held died with it
    /// (it was the last holder of every master) and no notice is coming from anybody — a session
    /// left waiting for one waits for ever, and its tab never closes.
    ///
    /// `128 + SIGHUP`, which is what superd reports for a hung-up child and, for that matter, what
    /// actually happened: the master's last close sent one.
    public func completeExitFromSupervisorLoss() {
        completeExit(code: 128 &+ SIGHUP)
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

// MARK: The fork-to-exec window

//
// GONE from Swift entirely (2026-08-11). It lives once, in `rust/slopdesk-posix/src/pty.rs`,
// because superd is now the only process that forks a pane — and its disassembly pin went with it
// (`fork_window_contract.rs`, which walks the child's path through `otool` and fails on any call
// that is not async-signal-safe libc).
//
// It is deliberately not ALSO kept here as a fallback. That pin finds the window by name fragment
// in a symbol table and asserts exactly one match; a second copy would make it ambiguous, so it
// would guard one implementation and silently stop guarding the other. One window, one symbol, one
// contract — and no language in which a pane can be forked twice.
