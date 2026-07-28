import Foundation
import SlopDeskTransport
import SlopDeskVideoProtocol

// MARK: - ScrollbackJournalStore (per-session disk journal — history survives the daemon)

/// Disk-backed scrollback persistence: one raw-bytes file per client-owned session UUID.
///
/// The in-memory half of "lossless reconnect" (``ReplayBuffer`` un-acked tail + scrollback ring,
/// `DetachedSessionStore`) dies with the process, so every path that ends in a FRESH spawn
/// (`HostServer.spawnFreshShell`, PATH B/C — hostd restart/reboot, detach-TTL eviction, shell
/// death) would otherwise start on an empty transcript. The journal closes that gap the
/// tmux-resurrect way: the TRANSCRIPT survives on disk and is replayed above the fresh shell; the
/// live process does not (cannot) survive the daemon.
///
/// ## Shape
/// - `journal(for:)` vends a per-session ``ScrollbackJournal`` writer; appends ride the PTY
///   read-loop chunk path (`MuxChannelSession.ingestPTYChunk`) so ONLY genuine PTY output is
///   journaled — a restored preamble (which enters via the out-FIFO, not the chunk path) is never
///   re-journaled, so transcripts don't double across restarts.
/// - `restoredScrollback(for:)` produces the preamble `spawnFreshShell` hands to the new session:
///   a rendered TRANSCRIPT (``TerminalReplaySnapshot/composeTranscript``, when the snapshot
///   composer and the `.size` sidecar's prior-life geometry are both available), else the
///   distilled raw bytes + a mode-sanitize reset suffix.
/// - `delete(sessionID:)` on deliberate end (peer `channelClose` / attached child exit);
///   everything else (link-drop detach, TTL eviction, daemon stop) KEEPS the file — that is the
///   feature. Orphans are bounded by ``sweep()``.
///
/// Files are RAW bytes (no header): per the no-backcompat rule there is nothing to version —
/// any tail of a byte stream "decodes", and the distiller/terminal tolerate arbitrary input.
///
/// `@unchecked Sendable`: the store's journal map is guarded by `lock`; each journal serializes
/// its own file I/O on a private queue.
public final class ScrollbackJournalStore: @unchecked Sendable {
    /// Directory holding `<uuid>.scrollback` files.
    let directory: URL

    /// Per-file byte cap (compaction keeps the newest tail). Mirrors the in-memory ring cap.
    let byteCap: Int

    /// Applied to the raw journal bytes at RESTORE time (never at write time, so a distiller
    /// change retroactively benefits existing journals). Injected for testability.
    private let distiller: (@Sendable (Data) -> Data)?

    /// The snapshot state-transfer composer (``TerminalReplaySnapshot/composeTranscript``),
    /// `(raw, rows, cols) → transcript`. When set AND the prior life's PTY size survives in
    /// the journal's size sidecar, restore renders the transcript ONCE instead of shipping
    /// the distilled byte history — the PATH-B sibling of the reattach snapshot replay. `nil`
    /// (env-disabled / tests) keeps the distiller path exactly as before.
    private let snapshotComposer: (@Sendable (Data, Int, Int) -> Data)?

    private let lock = NSLock()
    private var journals: [UUID: ScrollbackJournal] = [:]

    /// Completed ``sweep()`` call count, guarded by `lock` (testing only — the periodic-sweep
    /// schedule pin, `HostServerJournalSweepTests`, counts passes over a tiny injected interval
    /// without any wall-clock day).
    private var sweepCallCount = 0

    /// Terminal-mode sanitize suffix appended to every restored transcript: the prior life may
    /// have ended inside an alt-screen TUI with mouse reporting / bracketed paste / app-cursor
    /// modes on and the cursor hidden. Replaying those bytes verbatim into a FRESH terminal would
    /// leave the pane wedged in that state before the new shell's first prompt. Order matters:
    /// leave alt screen FIRST (so the resets land on the main screen), then reset modes/SGR.
    /// ``TerminalInputModeStripper`` already keeps the restored bytes mode-free on the default
    /// path; this suffix stays the backstop for env-disabled raw replay and covers the full
    /// input-affecting set — every mouse encoding, focus (1004), in-band resize (2048), and a
    /// kitty-keyboard pop-all + flags reset.
    static let sanitizeSuffix = Data(
        ("\u{1B}[?1049l\u{1B}[?9l\u{1B}[?1000l\u{1B}[?1001l\u{1B}[?1002l\u{1B}[?1003l\u{1B}[?1004l"
            + "\u{1B}[?1005l\u{1B}[?1006l\u{1B}[?1015l\u{1B}[?1016l\u{1B}[?2004l\u{1B}[?2031l\u{1B}[?2048l"
            + "\u{1B}[<32u\u{1B}[=0;1u\u{1B}[?1l\u{1B}[0m\u{1B}[?25h\r\n")
            .utf8,
    )

    /// - Parameter distiller: applied at restore time; `nil` = raw bytes. Production
    ///   (``makeFromEnvironment(environment:fileManager:)``) wires ``ScrollbackDistiller`` —
    ///   an internal type, so it cannot appear in this public init's default argument.
    init(
        directory: URL,
        byteCap: Int = ReplayBuffer.defaultScrollbackBytes,
        distiller: (@Sendable (Data) -> Data)? = nil,
        snapshotComposer: (@Sendable (Data, Int, Int) -> Data)? = nil,
    ) {
        self.directory = directory
        self.byteCap = max(0, byteCap)
        self.distiller = distiller
        self.snapshotComposer = snapshotComposer
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: Environment factory (hostd wiring)

    /// Builds the production store, or `nil` when disk persistence is off.
    ///
    /// Gates (both default-ON, the `!= "0"` idiom):
    /// - `SLOPDESK_SCROLLBACK_PERSIST` — the master scrollback gate (also controls the in-memory
    ///   ring in ``MuxChannelSession/makeReplayBuffer``).
    /// - `SLOPDESK_SCROLLBACK_DISK` — disk-specific kill switch, so the journal can be disabled
    ///   without losing the warm-resume ring.
    ///
    /// Cap: `SLOPDESK_SCROLLBACK_BYTES` (same env the ring reads). Distill: `SLOPDESK_SCROLLBACK_DISTILL`.
    /// Location: `<Application Support>/SlopDesk/scrollback/`, overridable via
    /// `SLOPDESK_SCROLLBACK_DIR` (E2E/tests point it at a temp dir) — or wholesale by
    /// ``SlopDeskAppSupport/directoryEnvKey``, which moves the container this sits inside.
    ///
    /// One of the two is REQUIRED of any daemon an automation run starts, and `HOME` is neither:
    /// ``ScrollbackJournalStore/sweep(maxAge:keepNewest:)`` unlinks everything past the newest 256
    /// in whatever directory it resolves, and its live-writer exemption can only see writers held by
    /// its OWN process.
    public static func makeFromEnvironment(
        environment env: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
    ) -> ScrollbackJournalStore? {
        guard env["SLOPDESK_SCROLLBACK_PERSIST"] != "0", env["SLOPDESK_SCROLLBACK_DISK"] != "0" else {
            return nil
        }
        let dir: URL
        if let override = env["SLOPDESK_SCROLLBACK_DIR"], !override.isEmpty {
            dir = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            guard let base = SlopDeskAppSupport.directory(environment: env, fileManager: fileManager)
            else { return nil }
            dir = base.appendingPathComponent("scrollback", isDirectory: true)
        }
        let cap: Int =
            if let raw = env["SLOPDESK_SCROLLBACK_BYTES"], let parsed = Int(raw), parsed >= 0 {
                parsed
            } else {
                ReplayBuffer.defaultScrollbackBytes
            }
        guard cap > 0 else { return nil }
        // Same distill + strip pipeline as the in-memory ring's cold replay — but NO input-mode
        // re-assert: a journal restore fronts a FRESH shell, so the prior life's TUI modes must
        // stay off (the sanitize suffix enforces the same for env-disabled raw replay).
        // The snapshot composer rides the same env gate as the reattach snapshot replay
        // (`SLOPDESK_SCROLLBACK_SNAPSHOT`, default-ON) — one switch governs state-transfer
        // on every replay path.
        var snapshotComposer: (@Sendable (Data, Int, Int) -> Data)?
        if env["SLOPDESK_SCROLLBACK_SNAPSHOT"] != "0" {
            snapshotComposer = { raw, rows, cols in
                TerminalReplaySnapshot.composeTranscript(raw: raw, rows: rows, cols: cols)
            }
        }
        return ScrollbackJournalStore(
            directory: dir, byteCap: cap,
            distiller: ScrollbackReplayTransform.make(environment: env),
            snapshotComposer: snapshotComposer,
        )
    }

    // MARK: Journal handles

    /// Vends the writer for `sessionID` (one shared instance per store, so two lookups never
    /// race two FileHandles onto one file).
    func journal(for sessionID: UUID) -> ScrollbackJournal {
        lock.lock()
        defer { lock.unlock() }
        if let existing = journals[sessionID] { return existing }
        let journal = ScrollbackJournal(fileURL: fileURL(for: sessionID), byteCap: byteCap)
        journals[sessionID] = journal
        return journal
    }

    /// Vends the writer for a FRESH SPAWN (`HostServer.spawnFreshShell`) — takes exclusive
    /// ownership of the sessionID's journal. On the correct lifecycle every end of life
    /// releases/deletes the writer, so a cache HIT here means another session object (a ghost
    /// of the same UUID: a parked duplicate from the detach-window race, or a dead child
    /// reaped by `claim`) still holds the instance. Sharing it would interleave two writers
    /// into one file — and worse, the ghost's eventual teardown would `closeKeepingFile()` the
    /// shared instance, silently killing the LIVE session's journaling forever (`append` is a
    /// no-op once `closed`). Instead ROTATE: flush+close the ghost's instance (its later
    /// appends drop — the attached session is the one that must win) and vend a fresh writer
    /// that appends to the same file, keeping the transcript continuous. The close runs under
    /// `lock` so no concurrent `journal(for:)`/`delete` can interleave with the swap.
    func claimJournal(for sessionID: UUID) -> ScrollbackJournal {
        lock.lock()
        defer { lock.unlock() }
        if let ghost = journals[sessionID] { ghost.closeKeepingFile() }
        let journal = ScrollbackJournal(fileURL: fileURL(for: sessionID), byteCap: byteCap)
        journals[sessionID] = journal
        return journal
    }

    /// One restored transcript: the preamble bytes plus HOW they were produced (the caller's
    /// log line — the reattach path's "snapshot|raw replay in N ms" observability sibling).
    struct RestoredScrollback {
        let bytes: Data
        /// TRUE when the bytes are a rendered state-transfer transcript (snapshot composer +
        /// size sidecar); FALSE for the distilled raw-history path.
        let snapshotComposed: Bool
    }

    /// Loads the persisted transcript for a returning session. With the snapshot composer and
    /// the prior life's PTY size (the `.size` sidecar) both available, the raw bytes are
    /// rendered ONCE into a plain transcript — O(final state) for the client to paint, mode-
    /// free by construction. Otherwise (env-disabled, or an old journal with no sidecar):
    /// raw bytes → distill → sanitize suffix, exactly as before. `nil` when no journal exists
    /// or nothing survives the transform (nothing to restore).
    func restoredScrollback(for sessionID: UUID) -> RestoredScrollback? {
        // Flush any writer this PROCESS still holds (restore normally happens in a fresh process,
        // but a TTL-evicted session restored by the same daemon must see its own tail).
        lock.lock()
        let writer = journals[sessionID]
        lock.unlock()
        writer?.synchronize()
        guard let raw = try? Data(contentsOf: fileURL(for: sessionID)), !raw.isEmpty else { return nil }
        if let snapshotComposer, let size = recordedWindowSize(for: sessionID) {
            let transcript = snapshotComposer(raw, size.rows, size.cols)
            guard !transcript.isEmpty else { return nil }
            return RestoredScrollback(bytes: transcript, snapshotComposed: true)
        }
        var restored = distiller.map { $0(raw) } ?? raw
        restored.append(Self.sanitizeSuffix)
        return RestoredScrollback(bytes: restored, snapshotComposed: false)
    }

    /// Reads the size sidecar (`<uuid>.scrollback.size`, "rows cols") — the LAST PTY size the
    /// prior life applied, recorded by ``ScrollbackJournal/recordWindowSize(rows:cols:)``.
    /// Any decode failure is `nil` (no-backcompat: a missing/garbled sidecar just falls back
    /// to the distiller path).
    private func recordedWindowSize(for sessionID: UUID) -> (rows: Int, cols: Int)? {
        let url = ScrollbackJournal.sizeSidecarURL(for: fileURL(for: sessionID))
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let parts = text.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 2,
              let rows = Int(parts[0].trimmingCharacters(in: .whitespacesAndNewlines)),
              let cols = Int(parts[1].trimmingCharacters(in: .whitespacesAndNewlines)),
              rows > 0, cols > 0, rows <= 1000, cols <= 4000
        else { return nil }
        return (rows, cols)
    }

    /// Releases the writer for a NON-deliberate end of life — TTL eviction, overflow eviction,
    /// shell death while parked (detached exit): flushes the coalescing buffer, closes the
    /// FileHandle, and drops the map entry. The FILE STAYS — it is the scrollback-restore
    /// source for a later cold client / the next daemon life (deleting the file remains
    /// exclusive to the deliberate-close path, ``delete(sessionID:)``). Without this, every
    /// non-deliberate pane end would leak one open fd + one map entry for the daemon's lifetime —
    /// and, because ``sweep()`` exempts ids live in the map, would leave the file permanently
    /// unsweepable too. A later ``journal(for:)`` for the same id transparently vends a fresh
    /// writer whose `openIfNeeded` seeks to end (append semantics preserved across the release).
    /// - Parameter instance: the writer the CALLER owns (its session's construction-time
    ///   journal). The map entry is dropped only when it still IS that instance — a stale
    ///   teardown (a ghost session of the same UUID racing its live successor) must not evict
    ///   the successor's writer. `nil` (the caller lost its session reference, so ownership
    ///   cannot be proven) leaves the map alone: a possible bounded fd hold beats closing a
    ///   writer that may belong to the live successor.
    func release(sessionID: UUID, instance: ScrollbackJournal?) {
        guard let instance else { return }
        lock.lock()
        if journals[sessionID] === instance {
            journals.removeValue(forKey: sessionID)
        }
        // Close under `lock` (bounded: one queue.sync flush+close; the journal queue never
        // takes this lock) so a concurrent `journal(for:)`/`claimJournal` cannot observe the
        // half-released state. A stale owner's instance was already rotated out + closed —
        // this close is an idempotent no-op for it, and it never touches the successor's writer.
        instance.closeKeepingFile()
        lock.unlock()
    }

    /// Removes the journal (deliberate end-of-pane only — see the type docs for the policy).
    ///
    /// The close + unlink run UNDER `lock`: unlinking outside it raced a same-UUID re-present
    /// (`spawnFreshShell` → `claimJournal` creating + opening the file anew), and the late
    /// unlink would then tear the NEW session's file out from under its open fd — every byte
    /// it writes from then on lands in an unreachable inode. Same `instance` guard as
    /// ``release(sessionID:instance:)``: a stale owner must not delete the successor's file.
    func delete(sessionID: UUID, instance: ScrollbackJournal?) {
        lock.lock()
        defer { lock.unlock() }
        guard instance == nil || journals[sessionID] === instance || journals[sessionID] == nil else {
            // A successor already owns this sessionID's journal — the caller's instance was
            // rotated out (already closed). Nothing to delete.
            return
        }
        let writer = journals.removeValue(forKey: sessionID)
        writer?.closeAndDelete()
        // No writer in THIS process (e.g. a pane closed right after a daemon restart): remove
        // the file (and its size sidecar) directly.
        if writer == nil {
            let journalURL = fileURL(for: sessionID)
            try? FileManager.default.removeItem(at: journalURL)
            try? FileManager.default.removeItem(at: ScrollbackJournal.sizeSidecarURL(for: journalURL))
        }
    }

    /// Unguarded convenience (tests + callers with no session reference).
    func delete(sessionID: UUID) { delete(sessionID: sessionID, instance: nil) }

    // MARK: Sweep (orphan bound)

    /// Deletes journals whose pane will never return: older than `maxAge` (mtime), or beyond the
    /// `keepNewest` most-recently-written files. Runs synchronously (call it from a detached
    /// task at daemon start — `HostServer` does).
    ///
    /// LIVE writers are exempt: sweep runs concurrently with the listener coming up, so a
    /// reconnect can vend a `journal(for:)` writer for a file sweep is about to unlink. POSIX
    /// `write()` to an unlinked inode keeps succeeding silently — the pane would keep journaling
    /// into a file nobody can ever restore (the whole transcript, past AND future, silently
    /// lost). A sessionID currently vended in `journals` is skipped outright.
    func sweep(maxAge: TimeInterval = 14 * 24 * 3600, keepNewest: Int = 256) {
        lock.lock()
        sweepCallCount += 1
        lock.unlock()
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey],
        ) else { return }
        let now = Date()
        var dated: [(url: URL, mtime: Date)] = []
        for url in urls where url.pathExtension == "scrollback" {
            if let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
               hasLiveWriter(for: id)
            {
                continue // a live pane owns this file — never unlink under an open writer
            }
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if now.timeIntervalSince(mtime) > maxAge {
                try? fm.removeItem(at: url)
                try? fm.removeItem(at: ScrollbackJournal.sizeSidecarURL(for: url))
            } else {
                dated.append((url, mtime))
            }
        }
        // Size sidecars whose journal is gone (a crash between the pair of unlinks, or a
        // journal swept by an older daemon) are pure orphans — no restore can ever read them.
        for url in urls where url.pathExtension == "size" {
            let journalURL = url.deletingPathExtension()
            if journalURL.pathExtension == "scrollback", !fm.fileExists(atPath: journalURL.path) {
                try? fm.removeItem(at: url)
            }
        }
        guard dated.count > keepNewest else { return }
        dated.sort { $0.mtime > $1.mtime }
        for stale in dated.dropFirst(keepNewest) {
            try? fm.removeItem(at: stale.url)
            try? fm.removeItem(at: ScrollbackJournal.sizeSidecarURL(for: stale.url))
        }
    }

    /// Whether a `journal(for:)` writer is currently vended for `sessionID` (under `lock`).
    private func hasLiveWriter(for sessionID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return journals[sessionID] != nil
    }

    private func fileURL(for sessionID: UUID) -> URL {
        directory.appendingPathComponent("\(sessionID.uuidString).scrollback", isDirectory: false)
    }

    // MARK: Test seams

    /// Whether the store currently holds a vended writer (an open-or-openable FileHandle + map
    /// entry) for `sessionID` — the fd-leak pin for the non-deliberate end-of-life paths
    /// (testing only).
    func hasLiveWriterForTesting(_ sessionID: UUID) -> Bool {
        hasLiveWriter(for: sessionID)
    }

    /// Completed ``sweep()`` call count (testing only — the periodic-sweep schedule pin).
    func sweepCallCountForTesting() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return sweepCallCount
    }
}

// MARK: - ScrollbackJournal (one session's append-only file)

/// The per-session writer: appends PTY output chunks to the journal file on a private serial
/// queue (the PTY read-loop thread only ENQUEUES — no file I/O on the hot path), compacting to
/// the newest `byteCap` tail when the file doubles past the cap.
///
/// Appends COALESCE: chunks accumulate in an in-memory `pending` buffer and reach the file in
/// one contiguous `write(2)` when the buffer crosses ``flushThresholdBytes`` or a short idle
/// flush (``idleFlushInterval``) fires — interactive typing / line-buffered output otherwise
/// costs one syscall per PTY chunk (hundreds-thousands/sec per session, attached AND detached).
/// On-disk bytes and ordering are identical to unbuffered writes; every reader of the FILE
/// (`synchronize()` → restore, compaction) flushes `pending` first, so no path can observe a
/// file missing enqueued appends.
///
/// `@unchecked Sendable`: all mutable state (`handle`, `size`, `pending`, …) is touched only
/// on `queue`.
final class ScrollbackJournal: @unchecked Sendable {
    let fileURL: URL
    let byteCap: Int

    /// Coalescing buffer bound: pending appends flush as one write once they reach this size.
    static let flushThresholdBytes = 32 * 1024
    /// Latency bound on the crash-loss window: buffered bytes never sit unflushed longer than
    /// this once the buffer goes non-empty.
    static let idleFlushInterval: DispatchTimeInterval = .milliseconds(25)

    private let queue: DispatchQueue
    private var handle: FileHandle?
    /// ON-DISK size only. Cap accounting is `size + pending.count` (buffered bytes count too).
    private var size: Int = 0
    /// Buffered-but-unflushed appends, in arrival order (flushed as one contiguous write).
    private var pending = Data()
    /// Whether an idle flush is already scheduled (one timer per non-empty transition, not per
    /// append). The timer block captures `self` STRONGLY on purpose: while bytes are pending a
    /// flush is always scheduled, so the journal cannot deallocate with unflushed bytes — the
    /// timer is the deinit/shutdown flush path.
    private var idleFlushScheduled = false
    /// Set by ``closeAndDelete()`` and ``closeKeepingFile()``; a late `append` racing either
    /// close must not resurrect the file (delete) or reopen a handle nobody will ever close
    /// again (release — the store has already dropped this instance, so a fresh writer owns
    /// the file from here).
    private var closed = false
    /// Retry floor after a FAILED compaction (the `.atomic` rewrite transiently needs ~cap of
    /// free space that incremental appends don't): without it, every append past `byteCap * 2`
    /// re-reads the whole over-cap file and re-attempts the rewrite — an O(file) tax per PTY
    /// chunk for as long as the disk pressure lasts. One failure defers the next attempt until
    /// the file has grown another `byteCap`.
    private var compactRetryFloor = 0

    /// The last size written to the sidecar by THIS instance (dedup — resizes repeat the same
    /// size far more often than they change it). On `queue`.
    private var lastRecordedSize: (rows: Int, cols: Int)?

    init(fileURL: URL, byteCap: Int) {
        self.fileURL = fileURL
        self.byteCap = byteCap
        queue = DispatchQueue(label: "slopdesk.scrollback-journal", qos: .utility)
    }

    /// The `<journal>.size` sidecar path — where ``recordWindowSize(rows:cols:)`` persists the
    /// last applied PTY size and ``ScrollbackJournalStore/restoredScrollback(for:)`` reads it.
    static func sizeSidecarURL(for journalURL: URL) -> URL {
        journalURL.appendingPathExtension("size")
    }

    /// Persists the PTY size that was just APPLIED (`TIOCSWINSZ` / the spawn-time initial
    /// winsize) to the size sidecar — the parse-correct geometry for a later daemon life's
    /// snapshot restore of this journal's bytes. Non-blocking (journal queue), deduped, and
    /// atomic on disk; a garbled/half-written sidecar decode-fails to the distiller path.
    func recordWindowSize(rows: Int, cols: Int) {
        guard rows > 0, cols > 0 else { return }
        queue.async { [self] in
            guard !closed else { return }
            if let last = lastRecordedSize, last == (rows, cols) { return }
            lastRecordedSize = (rows, cols)
            try? Data("\(rows) \(cols)\n".utf8)
                .write(to: Self.sizeSidecarURL(for: fileURL), options: .atomic)
        }
    }

    /// Appends one PTY output chunk. Non-blocking for the caller (read-loop thread): the bytes
    /// are buffered on the journal's serial queue and flushed by size threshold / idle timer /
    /// any reader (`synchronize()`, compaction).
    func append(_ bytes: Data) {
        guard !bytes.isEmpty else { return }
        queue.async { [self] in
            guard !closed else { return }
            pending.append(bytes)
            if size + pending.count > max(byteCap * 2, compactRetryFloor) {
                // Cap accounting counts buffered bytes, not just the on-disk `size`.
                compact()
            } else if pending.count >= Self.flushThresholdBytes {
                flushPending()
            } else {
                scheduleIdleFlushIfNeeded()
            }
        }
    }

    /// Blocks until every append enqueued so far has hit the file (restore + tests).
    func synchronize() {
        queue.sync {
            flushPending()
            try? handle?.synchronize()
        }
    }

    /// Closes the handle and removes the file; later appends are no-ops. Buffered bytes are
    /// deliberately DISCARDED with the file (this is the deliberate-close path) — a stale idle
    /// flush firing afterwards must not resurrect it.
    func closeAndDelete() {
        queue.sync {
            closed = true
            pending.removeAll(keepingCapacity: false)
            try? handle?.close()
            handle = nil
            try? FileManager.default.removeItem(at: fileURL)
            try? FileManager.default.removeItem(at: Self.sizeSidecarURL(for: fileURL))
        }
    }

    /// Flushes buffered appends and closes the handle, KEEPING the file — the non-deliberate
    /// end-of-life release (TTL/overflow eviction, detached exit; see
    /// ``ScrollbackJournalStore/release(sessionID:)``). Later appends on THIS instance are
    /// dropped (`closed`): a straggling PTY chunk racing the teardown must not reopen a handle
    /// this store no longer tracks. A returning session gets a FRESH instance via
    /// `journal(for:)`, which reopens append-at-end.
    func closeKeepingFile() {
        queue.sync {
            flushPending()
            try? handle?.close()
            handle = nil
            closed = true
        }
    }

    // MARK: On-queue helpers

    /// Arms the idle flush when the buffer goes non-empty. Strong `self` capture is the
    /// guarantee that pending bytes reach disk even if every other reference is dropped before
    /// the timer fires (see `idleFlushScheduled` docs).
    private func scheduleIdleFlushIfNeeded() {
        guard !idleFlushScheduled, !pending.isEmpty else { return }
        idleFlushScheduled = true
        queue.asyncAfter(deadline: .now() + Self.idleFlushInterval) { [self] in
            idleFlushScheduled = false
            flushPending()
        }
    }

    /// Writes every buffered byte in ONE contiguous write(2), preserving arrival order. On any
    /// failure (open, seek, disk full, revoked fd) the buffer is dropped: the journal is
    /// best-effort history, and the live stream must not be held up by disk trouble. No-op once
    /// `closed` (`closeAndDelete()` / `closeKeepingFile()`).
    private func flushPending() {
        guard !pending.isEmpty else { return }
        guard !closed, let handle = openIfNeeded() else {
            pending.removeAll(keepingCapacity: false)
            return
        }
        do {
            try handle.write(contentsOf: pending)
            size += pending.count
        } catch {
            // Intentionally swallowed — the whole batch is dropped, see the note above.
        }
        pending.removeAll(keepingCapacity: true)
    }

    private func openIfNeeded() -> FileHandle? {
        if let handle { return handle }
        let fm = FileManager.default
        if !fm.fileExists(atPath: fileURL.path) {
            fm.createFile(atPath: fileURL.path, contents: nil)
        }
        guard let opened = try? FileHandle(forWritingTo: fileURL) else { return nil }
        guard let end = try? opened.seekToEnd() else {
            // A failed seek is an OPEN failure: `lseek` never moves the offset on error, so the
            // fd still sits at 0 — writing there would OVERWRITE the journal head and serve
            // silent corruption on the next restore. Dropping the chunk (append's disk-full
            // posture) is strictly safer than corrupting history.
            try? opened.close()
            return nil
        }
        size = Int(end)
        handle = opened
        return opened
    }

    /// Keeps the newest `byteCap` bytes, advancing the cut past the next `\n` (within a bounded
    /// scan) so the surviving head starts on a line boundary rather than mid-escape-sequence.
    /// Same acceptance as the in-memory ring's head trim: a mid-sequence cut is TOLERATED (the
    /// distiller/terminal absorb it); the newline alignment just makes it rare.
    private func compact() {
        // Compaction reads the FILE — flush first so the tail computation (and the surviving
        // bytes) include every buffered append, in order.
        flushPending()
        guard let current = try? Data(contentsOf: fileURL), current.count > byteCap else { return }
        var cut = current.count - byteCap
        let scanEnd = min(current.count, cut + 4096)
        if let newline = current[cut..<scanEnd].firstIndex(of: 0x0A) {
            cut = newline + 1
        }
        var tail = Data(current[cut...])
        // Alt-screen cut repair, same as the in-memory ring's eviction: a cut inside an open
        // alt segment beheads it, and the restore-time transform would replay the surviving
        // interior onto the MAIN screen. Re-opening the segment at the surviving head — ON
        // DISK — keeps the file a well-formed stream, so the repair (and the next compaction's
        // scan, this life or a later daemon's) needs no state outside the bytes.
        if let reopen = AltScreenCutScanner.reopenSequence(
            afterDropped: current.prefix(cut), keptHead: tail.prefix(64),
        ) {
            tail = reopen + tail
        }
        // Close FIRST, clearing `handle` even when close() itself throws. Wrapping the close in
        // the do/catch below would skip `handle = nil` on a throwing close, leaving a POISONED
        // FileHandle in place — openIfNeeded() would return it forever and every subsequent
        // append would silently drop for the pane's lifetime. A cleared handle forces a fresh
        // open (+ seek) on the next append, in both the success and the failure branch.
        try? handle?.close()
        handle = nil
        do {
            try tail.write(to: fileURL, options: .atomic)
            size = tail.count
            compactRetryFloor = 0
        } catch {
            // Compaction failure keeps the (over-cap) file; the next append reopens. Defer the
            // next compaction attempt (retry floor) so persistent disk pressure doesn't turn
            // every append into a full-file read + failed rewrite.
            size = current.count
            compactRetryFloor = current.count + byteCap
        }
    }
}
