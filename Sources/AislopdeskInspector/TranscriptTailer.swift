import Foundation

/// Follows a Claude Code JSONL transcript file as it grows and emits each complete
/// line exactly once, in order, as a parsed ``TranscriptLine``.
///
/// **Approach (documented choice).** Poll the file size and read only the delta from
/// the last known offset (`poll size + read delta`), feeding bytes through a
/// ``LineAccumulator`` so a partial last line is never emitted until its newline
/// arrives. This is chosen over a `DispatchSource` vnode watch because:
/// - it is **portable + deterministic** (the same code path on macOS and iOS, no
///   `kqueue`/FSEvents difference) and trivially unit-testable with a temp file;
/// - JSONL flushes happen per-turn (doc 16), so sub-second poll latency is fine — the
///   low-latency card path is the PostToolUse hook, not the tail;
/// - it cannot miss a write (a vnode event coalesces multiple writes into one signal
///   anyway, and we'd still have to read the delta) and cannot double-emit (the offset
///   only ever advances past bytes we've turned into complete lines).
///
/// **Truncation / rotation** is handled defensively in two ways: (1) if the file's
/// size is *smaller* than our last offset, it was truncated/rotated-to-smaller, so we
/// reset the offset to 0 and the accumulator (dropping any stale half-line) and re-read
/// from the top; (2) we remember the file's identity (device + inode) the first time we
/// see it and, on every poll, compare it — if the identity changes (the path now names
/// a *different* file, e.g. `mv old old.1` then a fresh file is created at `old`), we
/// reset too, *regardless of size*. Identity-based detection catches same-or-larger
/// rotation that a size-only check silently mis-reads as an append (reading from the
/// stale offset into the new file and losing its prefix).
///
/// **Path discovery.** Production discovers the path from a `SessionStart` hook's
/// `transcript_path` (doc 16 — we never reconstruct it from `cwd`). For the model we
/// accept an explicit path; `TranscriptTailer(sessionStart:)` documents the hook seam.
public actor TranscriptTailer {
    /// The file being followed.
    private let url: URL
    /// Poll interval. Small enough to feel live, large enough to be cheap.
    private let pollInterval: Duration
    /// Maximum bytes to read per poll (cap, doc 16 "re-read tail cap ~1MB"). A larger
    /// backlog is drained over successive polls.
    private let maxReadPerPoll: Int

    /// Byte offset already consumed into complete-or-pending lines.
    private var offset: UInt64 = 0
    private var accumulator = LineAccumulator()
    private var stopped = false
    /// The (device, inode) of the file behind `url` the last time we read it. `nil`
    /// until the file first exists. A change means the path now names a different file
    /// (rotation), so we must reset even if the new file is the same size or larger.
    private var identity: FileIdentity?

    /// A file's on-disk identity: same path can point at different files over time
    /// (rotation), and the same file can be reached by different paths — `(dev, ino)`
    /// is the stable identity.
    private struct FileIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
    }

    public init(
        path: String,
        pollInterval: Duration = .milliseconds(100),
        maxReadPerPoll: Int = 1 * 1024 * 1024
    ) {
        self.url = URL(fileURLWithPath: path)
        self.pollInterval = pollInterval
        self.maxReadPerPoll = maxReadPerPoll
    }

    /// Documents the production discovery seam: build a tailer from a SessionStart
    /// hook payload (whose `transcript_path` names the file to follow).
    public init?(sessionStart info: SessionInfo, pollInterval: Duration = .milliseconds(100)) {
        guard let path = info.transcriptPath else { return nil }
        self.init(path: path, pollInterval: pollInterval)
    }

    /// Emits every complete line of the file, then follows appends until ``stop()``.
    ///
    /// The stream finishes when ``stop()`` is called. It tolerates the file not
    /// existing yet (doc 16 pitfall 5: SessionStart can fire before the file is
    /// created) by polling until it appears.
    ///
    /// `nonisolated` so the driving `Task` runs off the actor and each
    /// `await self.poll()` is a genuine actor hop (one delta-read per poll, serialised
    /// on the actor — no concurrent read of the offset/accumulator).
    public nonisolated func lines() -> AsyncStream<TranscriptLine> {
        AsyncStream { continuation in
            let task = Task {
                while !Task.isCancelled {
                    guard let batch = await self.poll() else { break }
                    for parsed in batch { continuation.yield(parsed) }
                    try? await Task.sleep(for: self.pollInterval)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// One poll step: returns the parsed lines produced since the last poll, or `nil`
    /// once ``stop()`` has been called (so the driver finishes the stream).
    private func poll() -> [TranscriptLine]? {
        guard !stopped else { return nil }
        return readDelta().compactMap { TranscriptParser.parse(line: $0) }
    }

    /// Stops following; the ``lines()`` stream finishes on its next poll.
    public func stop() {
        stopped = true
    }

    // MARK: - Delta read

    /// Reads bytes appended since the last call and returns the complete lines they
    /// produced. Handles truncation/rotation by resetting when the file shrinks.
    private func readDelta() -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            // File not created yet (race) — try again next poll.
            return []
        }
        defer { try? handle.close() }

        // Read identity from the open descriptor so size + identity refer to the same
        // file even if it is rotated mid-poll.
        let currentIdentity = fileIdentity(of: handle)
        if let currentIdentity, let identity, currentIdentity != identity {
            // The path now names a *different* file (rotation): restart from the top,
            // drop the stale half-line — even if the new file is the same size or larger.
            offset = 0
            accumulator.reset()
        }
        if let currentIdentity { identity = currentIdentity }

        let size = (try? handle.seekToEnd()) ?? 0

        if size < offset {
            // Truncated or rotated-to-smaller: restart from the top, drop the half-line.
            offset = 0
            accumulator.reset()
        }

        guard size > offset else { return [] }

        do {
            try handle.seek(toOffset: offset)
        } catch {
            return []
        }

        let want = Int(min(size - offset, UInt64(maxReadPerPoll)))
        let data = (try? handle.read(upToCount: want)) ?? Data()
        guard !data.isEmpty else { return [] }
        offset += UInt64(data.count)
        return accumulator.append(data)
    }

    /// The `(device, inode)` of an open file descriptor via `fstat`, or `nil` on error.
    private func fileIdentity(of handle: FileHandle) -> FileIdentity? {
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0 else { return nil }
        return FileIdentity(device: UInt64(bitPattern: Int64(info.st_dev)),
                            inode: UInt64(info.st_ino))
    }
}
