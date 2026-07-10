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
    func sweep(maxAge: TimeInterval = 14 * 24 * 3600, keepNewest: Int = 256) {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey],
        ) else { return }
        let now = Date()
        var dated: [(url: URL, mtime: Date)] = []
        for url in urls where url.pathExtension == "scrollback" {
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

    private func fileURL(for sessionID: UUID) -> URL {
        directory.appendingPathComponent("\(sessionID.uuidString).scrollback", isDirectory: false)
    }
}

// MARK: - ScrollbackJournal (one session's append-only file)

/// The per-session writer: appends PTY output chunks to the journal file on a private serial
/// queue (the PTY read-loop thread only ENQUEUES — no file I/O on the hot path), compacting to
/// the newest `byteCap` tail when the file doubles past the cap.
///
/// `@unchecked Sendable`: all mutable state (`handle`, `size`) is touched only on `queue`.
final class ScrollbackJournal: @unchecked Sendable {
    let fileURL: URL
    let byteCap: Int

    private let queue: DispatchQueue
    private var handle: FileHandle?
    private var size: Int = 0
    /// Set by ``closeAndDelete()``; a late `append` racing a delete must not resurrect the file.
    private var deleted = false

    init(fileURL: URL, byteCap: Int) {
        self.fileURL = fileURL
        self.byteCap = byteCap
        queue = DispatchQueue(label: "slopdesk.scrollback-journal", qos: .utility)
    }

    /// Appends one PTY output chunk. Non-blocking for the caller (read-loop thread): the write
    /// happens on the journal's serial queue.
    func append(_ bytes: Data) {
        guard !bytes.isEmpty else { return }
        queue.async { [self] in
            guard !deleted, let handle = openIfNeeded() else { return }
            do {
                try handle.write(contentsOf: bytes)
                size += bytes.count
            } catch {
                return // Disk full / revoked fd: drop the chunk; the live stream is unaffected.
            }
            if size > byteCap * 2 { compact() }
        }
    }

    /// Blocks until every append enqueued so far has hit the file (restore + tests).
    func synchronize() {
        queue.sync {
            try? handle?.synchronize()
        }
    }

    /// Closes the handle and removes the file; later appends are no-ops.
    func closeAndDelete() {
        queue.sync {
            deleted = true
            try? handle?.close()
            handle = nil
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    // MARK: On-queue helpers

    private func openIfNeeded() -> FileHandle? {
        if let handle { return handle }
        let fm = FileManager.default
        if !fm.fileExists(atPath: fileURL.path) {
            fm.createFile(atPath: fileURL.path, contents: nil)
        }
        guard let opened = try? FileHandle(forWritingTo: fileURL) else { return nil }
        size = (try? opened.seekToEnd()).map(Int.init) ?? 0
        handle = opened
        return opened
    }

    /// Keeps the newest `byteCap` bytes, advancing the cut past the next `\n` (within a bounded
    /// scan) so the surviving head starts on a line boundary rather than mid-escape-sequence.
    /// Same acceptance as the in-memory ring's head trim: a mid-sequence cut is TOLERATED (the
    /// distiller/terminal absorb it); the newline alignment just makes it rare.
    private func compact() {
        guard let current = try? Data(contentsOf: fileURL), current.count > byteCap else { return }
        var cut = current.count - byteCap
        let scanEnd = min(current.count, cut + 4096)
        if let newline = current[cut..<scanEnd].firstIndex(of: 0x0A) {
            cut = newline + 1
        }
        let tail = current[cut...]
        do {
            try handle?.close()
            handle = nil
            try tail.write(to: fileURL, options: .atomic)
            size = tail.count
        } catch {
            // Compaction failure keeps the (over-cap) file; the next append retries.
            size = current.count
        }
    }
}
