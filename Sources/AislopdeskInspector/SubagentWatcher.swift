import Foundation

/// Watches the `subagents/` directory for new `agent-<hash>.jsonl` files and tails
/// each one, emitting `(agentID, TranscriptLine)` pairs.
///
/// Doc 16 (refuted-correction): native `claude` does **not** interleave subagent
/// turns into the main session file — tailing only the main file loses all subagent
/// content. So we must watch the `subagents/` dir and index per file. The owning
/// subagent id is the filename hash (`agent-<hash>.jsonl` → `<hash>`), matching the
/// `SubagentStop.agent_transcript_path` signal that links a subagent into the tree.
///
/// Like ``TranscriptTailer`` this polls (directory listing diff + per-file tail) for
/// portability + testability; FSEvents would be a host-only optimisation behind the
/// same interface.
public actor SubagentWatcher {
    private let directory: URL
    private let pollInterval: Duration

    /// Tailers already started, keyed by agent id (filename hash), so a file is only
    /// followed once.
    private var tailers: [String: TranscriptTailer] = [:]
    private var stopped = false

    public init(directory: String, pollInterval: Duration = .milliseconds(100)) {
        self.directory = URL(fileURLWithPath: directory)
        self.pollInterval = pollInterval
    }

    /// Emits `(agentID, line)` for every line of every `agent-*.jsonl` file in the
    /// directory, following new files as they appear. Finishes on ``stop()``.
    ///
    /// `nonisolated` so the scan loop runs off the actor and each `await self.scan(...)`
    /// is a real actor hop (serialised directory diffs — a file is only tailed once).
    public nonisolated func lines() -> AsyncStream<(agentID: String, line: TranscriptLine)> {
        AsyncStream { continuation in
            let scanTask = Task {
                while !Task.isCancelled {
                    guard await self.scan(into: continuation) else { break }
                    try? await Task.sleep(for: self.pollInterval)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in scanTask.cancel() }
        }
    }

    /// One scan step: starts tailing any newly-appeared `agent-*.jsonl` file. Returns
    /// `false` once ``stop()`` has been called (so the driver finishes the stream).
    private func scan(
        into continuation: AsyncStream<(agentID: String, line: TranscriptLine)>.Continuation
    ) -> Bool {
        guard !stopped else { return false }
        for (agentID, path) in discoverNewFiles() {
            startTailing(agentID: agentID, path: path, into: continuation)
        }
        return true
    }

    public func stop() {
        stopped = true
        for tailer in tailers.values {
            Task { await tailer.stop() }
        }
    }

    // MARK: - Discovery

    /// Returns `(agentID, path)` for `agent-*.jsonl` files not already being tailed.
    private func discoverNewFiles() -> [(String, String)] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: directory.path) else {
            return []
        }
        var found: [(String, String)] = []
        for name in entries.sorted() where name.hasPrefix("agent-") && name.hasSuffix(".jsonl") {
            // Exclude the `agent-<hash>.meta.json` sidecar (it ends `.meta.json`, not `.jsonl`).
            let agentID = HookParser.agentHash(name)
            if tailers[agentID] == nil {
                found.append((agentID, directory.appendingPathComponent(name).path))
            }
        }
        return found
    }

    private func startTailing(
        agentID: String,
        path: String,
        into continuation: AsyncStream<(agentID: String, line: TranscriptLine)>.Continuation
    ) {
        guard tailers[agentID] == nil else { return }
        let tailer = TranscriptTailer(path: path, pollInterval: pollInterval)
        tailers[agentID] = tailer
        Task {
            for await line in tailer.lines() {
                continuation.yield((agentID, line))
            }
        }
    }
}
