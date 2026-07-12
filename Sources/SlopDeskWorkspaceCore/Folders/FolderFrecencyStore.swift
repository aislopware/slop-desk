import Foundation
import Observation

// MARK: - Folders frecency store (client-side, persisted)

/// The in-process, **client-side** persisted frecency store for visited working directories — the backing
/// of the Open-Quickly **Folders** filter (`⌘Z`). `record(cwd:)` is called from the client when a pane's
/// known cwd changes (wired via `WorkspaceStore.onCwdVisited`); `ranked(now:)` feeds the picker;
/// `forget(path:)` backs the per-row "Forget This Folder" action.
///
/// ### Discipline (CLAUDE.md)
/// - **Bounded.** A ``maxEntries`` entry cap (evicting the least-frecent / oldest on overflow) and a
///   ``maxPathLength`` path-length cap keep the sidecar from growing without limit on hostile/runaway input.
/// - **Validate-then-store.** `record` rejects an empty / whitespace-only / over-long path rather than
///   storing it; `load` drops any such entry a hand-edited file might contain. No force-unwrap anywhere.
/// - **Schema-versioned, decode-fail-to-default.** The JSON sidecar (`folders-frecency.json` in Application
///   Support) carries a ``currentSchemaVersion``; a missing file, corrupt JSON, or an unreadable
///   (future / mismatched) version all fall back to an empty default — a corrupt store never bricks launch
///   and there is no migration (single-user "no backcompat" directive).
/// - **IO-thin + injectable.** Like ``WorkspacePersistence``, it owns only a file URL + a `now` clock + a
///   `FileManager`, all injectable, so the record/rank/persist behaviour is unit-testable against a temp dir
///   with no UI and no real clock.
///
/// `@MainActor @Observable` (mirroring the other client stores): the Folders list re-renders when a visit
/// is recorded or a folder is forgotten. The cwd-visit hook fires on the main actor, so main-actor isolation
/// is a natural fit and keeps the store free of locking.
@preconcurrency
@MainActor
@Observable
public final class FolderFrecencyStore {
    // MARK: Caps + schema

    /// The persisted sidecar schema version. Bumping it makes any older/newer file decode-fail to empty.
    public static let currentSchemaVersion = 1
    /// Default ceiling on stored folder entries (the least-frecent are evicted past this). Injectable for tests.
    public static let defaultMaxEntries = 200
    /// The maximum accepted path length (chars) — a longer cwd is rejected by `record` and dropped by `load`.
    public static let maxPathLength = 4096

    // MARK: Observed state

    /// The current folder entries (unordered). Use ``ranked(now:limit:)`` for the frecency-ordered view.
    public private(set) var entries: [FolderEntry]

    // MARK: Injected collaborators (not observed)

    private let fileURL: URL
    private let clock: () -> Date
    private let fileManager: FileManager
    private let maxEntries: Int

    /// - Parameters:
    ///   - fileURL: where to persist. Defaults to ``defaultFileURL(using:)`` (`folders-frecency.json`).
    ///   - now: the clock used to timestamp visits + score ranking. Inject a fixed clock in tests.
    ///   - fileManager: injected for tests (point at a temp dir). Defaults to `.default`.
    ///   - maxEntries: the entry cap. Defaults to ``defaultMaxEntries`` (lowered in tests to keep IO small).
    public init(
        fileURL: URL? = nil,
        now: @escaping () -> Date = Date.init,
        fileManager: FileManager = .default,
        maxEntries: Int = FolderFrecencyStore.defaultMaxEntries,
    ) {
        self.fileManager = fileManager
        clock = now
        self.maxEntries = max(0, maxEntries)
        let resolvedURL = fileURL ?? Self.defaultFileURL(using: fileManager)
        self.fileURL = resolvedURL
        entries = Self.load(from: resolvedURL, maxEntries: max(0, maxEntries))
    }

    // MARK: Recording

    /// Records a visit to `cwd`: increments an existing entry's count + advances its `lastAccess`, or inserts
    /// a fresh entry (`count = 1`). Validate-then-store — an empty / whitespace-only / over-long path is
    /// dropped. Enforces the entry cap and persists best-effort. Safe to call on every cwd change.
    public func record(cwd: String) {
        guard Self.isValidPath(cwd) else { return } // validate-then-store
        let timestamp = clock()
        if let index = entries.firstIndex(where: { $0.path == cwd }) {
            entries[index].accessCount += 1
            entries[index].lastAccess = timestamp
        } else {
            entries.append(FolderEntry(path: cwd, accessCount: 1, lastAccess: timestamp))
        }
        enforceCap(now: timestamp)
        persist()
    }

    /// Frecency-ordered entries (descending). `now` defaults to the injected clock; `limit` (clamped `≥ 0`)
    /// keeps only the top-N.
    public func ranked(now: Date? = nil, limit: Int? = nil) -> [FolderEntry] {
        FolderFrecency.ranked(entries: entries, now: now ?? clock(), limit: limit)
    }

    /// Removes every entry for `path` (the "Forget This Folder" action) and persists if anything changed.
    public func forget(path: String) {
        let countBefore = entries.count
        entries.removeAll { $0.path == path }
        if entries.count != countBefore { persist() }
    }

    // MARK: Cap

    /// Past the cap, keep only the ``maxEntries`` most-frecent (the freshest survive ties), dropping the
    /// least-frecent / oldest. Scored at `now` (the just-recorded timestamp) so a brand-new visit is retained.
    private func enforceCap(now: Date) {
        guard entries.count > maxEntries else { return }
        entries = FolderFrecency.ranked(entries: entries, now: now, limit: maxEntries)
    }

    // MARK: Validation

    /// A path is storable iff it is non-empty after trimming surrounding whitespace/newlines AND within the
    /// length cap. Keeps the cwd verbatim otherwise (no normalization — the store keys on the path as given).
    static func isValidPath(_ path: String) -> Bool {
        guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard path.count <= maxPathLength else { return false }
        return true
    }

    // MARK: Persistence

    /// The on-disk shape: a schema version + the flat entry list.
    private struct Persisted: Codable {
        var schemaVersion: Int
        var entries: [FolderEntry]
    }

    /// `<Application Support>/SlopDesk/folders-frecency.json` (sibling of `workspace.json`). Falls back to a
    /// temp directory if Application Support cannot be resolved — the data is non-critical (re-learned on use).
    public static func defaultFileURL(using fileManager: FileManager = .default) -> URL {
        let base = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true,
        )) ?? fileManager.temporaryDirectory
        return base
            .appendingPathComponent("SlopDesk", isDirectory: true)
            .appendingPathComponent("folders-frecency.json", isDirectory: false)
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys] // reviewable, byte-stable round-trip
        return encoder
    }

    /// Reads + decodes the sidecar, returning an empty default on ANY failure (missing file, corrupt JSON, a
    /// mismatched/future `schemaVersion`). A structurally-valid file is sanitized: invalid (empty / over-long
    /// path, negative count) entries are dropped, and an over-cap file is trimmed to the ``maxEntries`` most
    /// recently accessed — so even a hand-edited file can never push the live store past its bounds.
    private static func load(from url: URL, maxEntries: Int) -> [FolderEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] } // missing file = first launch
        guard let decoded = try? JSONDecoder().decode(Persisted.self, from: data) else { return [] } // corrupt
        guard decoded.schemaVersion == currentSchemaVersion else { return [] } // unreadable version → empty
        let valid = decoded.entries.filter { isValidPath($0.path) && $0.accessCount >= 0 }
        guard valid.count > maxEntries else { return valid }
        // Over-cap hand-edited file: keep the most-recently-accessed `maxEntries` (a now-independent bound).
        return Array(valid.sorted { $0.lastAccess > $1.lastAccess }.prefix(maxEntries))
    }

    /// Encodes the current entries and writes them atomically, creating the parent directory if needed.
    /// Best-effort: a write/encode failure is swallowed (the previous good file is kept) — the frecency DB is
    /// a convenience, never load-bearing, so it must never throw into the UI.
    private func persist() {
        let payload = Persisted(schemaVersion: Self.currentSchemaVersion, entries: entries)
        guard let data = try? Self.makeEncoder().encode(payload) else { return }
        try? fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: [.atomic])
    }
}
