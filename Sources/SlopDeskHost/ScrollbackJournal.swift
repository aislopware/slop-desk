import Foundation
import SlopDeskTransport

// MARK: - ScrollbackJournalStore (per-session disk journal — history survives the daemon)

/// Disk-backed scrollback persistence: one raw-bytes file per client-owned session UUID.
///
/// The in-memory half of "lossless reconnect" (``ReplayBuffer`` un-acked tail + scrollback ring,
/// `DetachedSessionStore`) dies with the process. Every path that ends in a FRESH spawn
/// (`HostServer.spawnFreshShell`, PATH B/C — hostd restart/reboot, detach-TTL eviction, shell
/// death) therefore started an empty transcript. The journal closes that gap the tmux-resurrect
/// way: the TRANSCRIPT survives on disk and is replayed above the fresh shell; the live process
/// does not (cannot) survive the daemon.
///
/// ## Shape
/// - `journal(for:)` vends a per-session ``ScrollbackJournal`` writer; appends ride the PTY
///   read-loop chunk path (`MuxChannelSession.ingestPTYChunk`) so ONLY genuine PTY output is
///   journaled — a restored preamble (which enters via the out-FIFO, not the chunk path) is never
///   re-journaled, so transcripts don't double across restarts.
/// - `restoredScrollback(for:)` loads + distills (``ScrollbackDistiller``) + suffixes a
///   mode-sanitize reset, producing the preamble `spawnFreshShell` hands to the new session.
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

    private let lock = NSLock()
    private var journals: [UUID: ScrollbackJournal] = [:]

    /// Terminal-mode sanitize suffix appended to every restored transcript: the prior life may
    /// have ended inside an alt-screen TUI with mouse reporting / bracketed paste / app-cursor
    /// modes on and the cursor hidden. Replaying those bytes verbatim into a FRESH terminal would
    /// leave the pane wedged in that state before the new shell's first prompt. Order matters:
    /// leave alt screen FIRST (so the resets land on the main screen), then reset modes/SGR.
    static let sanitizeSuffix = Data(
        "\u{1B}[?1049l\u{1B}[?1000l\u{1B}[?1002l\u{1B}[?1003l\u{1B}[?1006l\u{1B}[?2004l\u{1B}[?1l\u{1B}[0m\u{1B}[?25h\r\n"
            .utf8,
    )

    /// - Parameter distiller: applied at restore time; `nil` = raw bytes. Production
    ///   (``makeFromEnvironment(environment:fileManager:)``) wires ``ScrollbackDistiller`` —
    ///   an internal type, so it cannot appear in this public init's default argument.
    init(
        directory: URL,
        byteCap: Int = ReplayBuffer.defaultScrollbackBytes,
        distiller: (@Sendable (Data) -> Data)? = nil,
    ) {
        self.directory = directory
        self.byteCap = max(0, byteCap)
        self.distiller = distiller
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: Environment factory (hostd wiring)

    /// Builds the production store, or `nil` when disk persistence is off.
    ///
    /// Gates (both default-ON, the `!= "0"` idiom):
    /// - `SLOPDESK_SCROLLBACK_PERSIST` — the existing master scrollback gate (also controls the
    ///   in-memory ring in ``MuxChannelSession/makeReplayBuffer``).
    /// - `SLOPDESK_SCROLLBACK_DISK` — disk-specific kill switch, so the journal can be disabled
    ///   without losing the warm-resume ring.
    ///
    /// Cap: `SLOPDESK_SCROLLBACK_BYTES` (same env the ring reads). Distill: `SLOPDESK_SCROLLBACK_DISTILL`.
    /// Location: `<Application Support>/SlopDesk/scrollback/`, overridable via
    /// `SLOPDESK_SCROLLBACK_DIR` (E2E/tests point it at a temp dir).
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
            guard let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            else { return nil }
            dir = base
                .appendingPathComponent("SlopDesk", isDirectory: true)
                .appendingPathComponent("scrollback", isDirectory: true)
        }
        let cap: Int =
            if let raw = env["SLOPDESK_SCROLLBACK_BYTES"], let parsed = Int(raw), parsed >= 0 {
                parsed
            } else {
                ReplayBuffer.defaultScrollbackBytes
            }
        guard cap > 0 else { return nil }
        // Same distill + query-strip pipeline as the in-memory ring's cold replay.
        return ScrollbackJournalStore(
            directory: dir, byteCap: cap,
            distiller: ScrollbackReplayTransform.make(environment: env),
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

    /// Loads the persisted transcript for a returning session: raw bytes → distill → sanitize
    /// suffix. `nil` when no journal exists or it is empty (nothing to restore).
    func restoredScrollback(for sessionID: UUID) -> Data? {
        // Flush any writer this PROCESS still holds (restore normally happens in a fresh process,
        // but a TTL-evicted session restored by the same daemon must see its own tail).
        lock.lock()
        let writer = journals[sessionID]
        lock.unlock()
        writer?.synchronize()
        guard let raw = try? Data(contentsOf: fileURL(for: sessionID)), !raw.isEmpty else { return nil }
        var restored = distiller.map { $0(raw) } ?? raw
        restored.append(Self.sanitizeSuffix)
        return restored
    }

    /// Releases the writer for a NON-deliberate end of life — TTL eviction, overflow eviction,
    /// shell death while parked (detached exit): flushes the coalescing buffer, closes the
    /// FileHandle, and drops the map entry. The FILE STAYS — it is the scrollback-restore
    /// source for a later cold client / the next daemon life (deleting the file remains
    /// exclusive to the deliberate-close path, ``delete(sessionID:)``). Without this, every
    /// non-deliberate pane end leaked one open fd + one map entry for the daemon's lifetime —
    /// and, because ``sweep()`` exempts ids live in the map, made the file permanently
    /// unsweepable too. A later ``journal(for:)`` for the same id transparently vends a fresh
    /// writer whose `openIfNeeded` seeks to end (append semantics preserved across the release).
    func release(sessionID: UUID) {
        lock.lock()
        let writer = journals.removeValue(forKey: sessionID)
        lock.unlock()
        writer?.closeKeepingFile()
    }

    /// Removes the journal (deliberate end-of-pane only — see the type docs for the policy).
    func delete(sessionID: UUID) {
        lock.lock()
        let writer = journals.removeValue(forKey: sessionID)
        lock.unlock()
        writer?.closeAndDelete()
        // No writer in THIS process (e.g. a pane closed right after a daemon restart): remove
        // the file directly.
        if writer == nil {
            try? FileManager.default.removeItem(at: fileURL(for: sessionID))
        }
    }

    // MARK: Sweep (orphan bound)

    /// Deletes journals whose pane will never return: older than `maxAge` (mtime), or beyond the
    /// `keepNewest` most-recently-written files. Runs synchronously (call it from a detached
    /// task at daemon start — `HostServer` does).
    ///
    /// LIVE writers are exempt (audit 2026-07-10 #10): sweep runs concurrently with the listener
    /// coming up, so a reconnect can vend a `journal(for:)` writer for a file sweep is about to
    /// unlink. POSIX `write()` to an unlinked inode keeps succeeding silently — the pane would
    /// keep journaling into a file nobody can ever restore (the whole transcript, past AND
    /// future, silently lost). A sessionID currently vended in `journals` is skipped outright.
    func sweep(maxAge: TimeInterval = 14 * 24 * 3600, keepNewest: Int = 256) {
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
            } else {
                dated.append((url, mtime))
            }
        }
        guard dated.count > keepNewest else { return }
        dated.sort { $0.mtime > $1.mtime }
        for stale in dated.dropFirst(keepNewest) {
            try? fm.removeItem(at: stale.url)
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

    init(fileURL: URL, byteCap: Int) {
        self.fileURL = fileURL
        self.byteCap = byteCap
        queue = DispatchQueue(label: "slopdesk.scrollback-journal", qos: .utility)
    }

    /// Appends one PTY output chunk. Non-blocking for the caller (read-loop thread): the bytes
    /// are buffered on the journal's serial queue and flushed by size threshold / idle timer /
    /// any reader (`synchronize()`, compaction).
    func append(_ bytes: Data) {
        guard !bytes.isEmpty else { return }
        queue.async { [self] in
            guard !closed else { return }
            pending.append(bytes)
            if size + pending.count > byteCap * 2 {
                // Cap check counts buffered bytes; compact() flushes first so it always runs
                // over a file that already holds every append.
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
    /// failure (open, seek, disk full, revoked fd) the buffer is dropped — the same posture the
    /// old per-chunk append had; the live stream is unaffected. No-op once `closed`
    /// (`closeAndDelete()` / `closeKeepingFile()`).
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
            // Dropped, as one batch instead of chunk-by-chunk.
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
            // A failed seek is an OPEN failure (audit 2026-07-10 #14): `lseek` never moves the
            // offset on error, so the fd still sits at 0 — writing there would OVERWRITE the
            // journal head and serve silent corruption on the next restore. Dropping the chunk
            // (append's existing disk-full posture) is strictly safer than corrupting history.
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
        let tail = current[cut...]
        // Close FIRST, clearing `handle` even when close() itself throws (audit 2026-07-10 #11):
        // the old single do/catch skipped `handle = nil` on a throwing close, leaving a POISONED
        // FileHandle in place — openIfNeeded() returned it forever and every subsequent append
        // silently dropped for the pane's lifetime. A cleared handle forces a fresh open (+ seek)
        // on the next append, in both the success and the failure branch.
        try? handle?.close()
        handle = nil
        do {
            try tail.write(to: fileURL, options: .atomic)
            size = tail.count
        } catch {
            // Compaction failure keeps the (over-cap) file; the next append reopens + retries.
            size = current.count
        }
    }
}
