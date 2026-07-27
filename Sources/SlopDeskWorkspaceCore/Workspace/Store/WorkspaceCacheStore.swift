import Foundation
import SlopDeskWorkspaceModel

// MARK: - WorkspaceCacheStore (the last picture this device saw of one host's document)

/// `<Application Support>/SlopDesk/workspace-cache.json` — the document facts this device saw last,
/// so a launch paints a real sidebar before a single packet moves (docs/45 §7.3).
///
/// ### Never authoritative
/// The cache is a PICTURE, not a source. It is folded in exactly two places, both of which host truth
/// overrides the instant it arrives: `pane/spawnCwd` seeds the mirror's topology (an intent replaces
/// it wholesale), and `pane/cwd` / `pane/projectKey` seed the mirror's FAST PATH, which the erasure
/// rule deletes for any key a host frame supplies. There is no promotion step, no fallback title and
/// no freshness heuristic — the three mechanisms that let a cache outlive the fact it cached.
///
/// ### The gate is `hostKey`, and only `hostKey`
/// A picture of host A must never be painted for host B, so the file records the `host:port` it was
/// taken from and a mismatch discards it to empty. The document EPOCH is deliberately not a gate: a
/// hostd restart mints a new epoch while restoring the document byte-identically, and gating on it
/// would blank the window on exactly the reboot case the cache exists for.
///
/// ### What is allowed on disk
/// The rows run through ``WorkspaceStateFile/persisting(_:)`` on the way out AND on the way back in,
/// which is what keeps `commandRunning = 1` and `liveness = attached` off the disk: a restored
/// fake-live row is the render docs/45 §6.5 exists to prevent, and the file is the one input a user
/// can edit by hand.
///
/// IO-thin and `@unchecked Sendable` on the same terms as ``WorkspacePersistence``: the only stored
/// properties are a `URL` and a thread-safe `FileManager`.
public struct WorkspaceCacheStore: @unchecked Sendable {
    /// Cap on the row count a load will accept. A file claiming a hundred thousand facts is corrupt,
    /// not a big workspace; the whole cache resets rather than being allocated.
    public static let maxEntries = 8192

    /// The file the cache is read from / written to.
    public let fileURL: URL
    private let fileManager: FileManager

    /// - Parameters:
    ///   - fileURL: where to persist. Defaults to ``defaultFileURL(using:)``.
    ///   - fileManager: injected for tests (point at a temp dir). Defaults to `.default`.
    public init(fileURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.fileURL = fileURL ?? Self.defaultFileURL(using: fileManager)
    }

    /// `<Application Support>/SlopDesk/workspace-cache.json` — sibling of `device-prefs.json`. Falls
    /// back to a temporary directory when Application Support can't resolve (sandboxed edge cases);
    /// the data is a cache, so a fresh empty one is always recoverable.
    public static func defaultFileURL(using fileManager: FileManager = .default) -> URL {
        let base = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true,
        )) ?? fileManager.temporaryDirectory
        return base
            .appendingPathComponent("SlopDesk", isDirectory: true)
            .appendingPathComponent("workspace-cache.json", isDirectory: false)
    }

    /// The on-disk shape: the host it describes, and the exact kind-0 snapshot payload BYTES.
    ///
    /// The raw payload rather than a re-encoded model, because the wire codec is the one decoder both
    /// ends already agree on — a second JSON shape for the same facts is a second place for them to
    /// drift. `epoch` / `stateNum` are deliberately absent: nothing resumes from this file (the mirror
    /// resets on every channel stop), so recording a resume position would be a claim the client
    /// cannot honour.
    private struct Document: Codable {
        var hostKey: String
        /// Base64 of ``WorkspaceStateCodec/encodeSnapshot(_:)``.
        var snapshot: String
    }

    /// The facts cached for `hostKey`, or an EMPTY state. Never throws — a launch must always get a
    /// usable value:
    /// - missing file → empty (first launch on this device)
    /// - a different `hostKey`, corrupt JSON, a failed snapshot decode, over-``maxEntries`` → empty
    ///
    /// An empty answer costs one RTT of "connecting", which is strictly better than painting host A's
    /// folders over host B's panes.
    public func load(hostKey: String) -> HostWorkspaceState {
        guard !hostKey.isEmpty,
              let data = try? Data(contentsOf: fileURL),
              let document = try? JSONDecoder().decode(Document.self, from: data),
              document.hostKey == hostKey,
              let payload = Data(base64Encoded: document.snapshot),
              let decoded = try? WorkspaceStateCodec.decodeSnapshot(payload),
              decoded.entries.count <= Self.maxEntries
        else {
            return HostWorkspaceState()
        }
        return WorkspaceStateFile.persisting(decoded)
    }

    /// Encodes the persistable half of `state` under `hostKey` and writes it atomically, creating the
    /// parent dir if needed. An EMPTY `hostKey` writes nothing at all — a cache no load can ever be
    /// gated against is a file that only grows.
    ///
    /// Throws on IO/encode failure; callers are best-effort, and a failed write keeps the previous
    /// good picture.
    public func save(_ state: HostWorkspaceState, hostKey: String) throws {
        guard !hostKey.isEmpty else { return }
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let payload = WorkspaceStateCodec.encodeSnapshot(WorkspaceStateFile.persisting(state))
        let document = Document(hostKey: hostKey, snapshot: payload.base64EncodedString())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(document).write(to: fileURL, options: [.atomic])
    }
}
