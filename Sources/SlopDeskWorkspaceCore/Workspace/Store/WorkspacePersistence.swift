import Foundation
import SlopDeskWorkspaceModel

// MARK: - Workspace persistence (the tree of intent ↔ disk)

/// Loads + saves the pure ``Workspace`` value tree to disk (docs/22 §6).
///
/// The value tree IS the format — already `Codable` (each tab's flat ``Canvas`` has a defensive
/// `Canvas.init(from:)` enforcing invariants on decode). Deliberately **IO-thin**: owns only the file
/// URL and the encode/decode, so it is unit-testable against a temp dir with no store/UI/client.
///
/// ### The RESTORED-vs-RECONNECTED discipline (docs/22 §6)
/// Persistence restores SHAPE and INTENT only — never live connections, byte buffers, or sessionIDs.
/// On launch the store decodes the tree and starts the registry empty; `reconcile()` materializes
/// **idle** sessions; the view connects lazily on appear. A relaunch is a fresh session.
///
/// ### Failure policy
/// Any read/decode failure (missing file, corrupt JSON, unknown `schemaVersion`) falls back to
/// ``Workspace/defaultWorkspace()`` — a corrupt store must never brick launch.
/// `@unchecked Sendable`: the only stored properties are a `URL` (Sendable value) and a read-only,
/// thread-safe `FileManager`, so a value can cross actor boundaries for the store's off-main-actor
/// debounced write (docs/22 §6) without data-race risk.
public struct WorkspacePersistence: @unchecked Sendable {
    /// Cap on loaded-file collection sizes. An enormous `items` array would make the store eagerly
    /// allocate one session PER item on the main actor (UI freeze / OOM). Real workspaces are dozens of
    /// panes — this cap is far above any genuine use.
    public static let maxItems = 1024

    /// The file the workspace is written to / read from. Defaults to
    /// `Application Support/SlopDesk/workspace.json` (the app container on iOS).
    public let fileURL: URL
    private let fileManager: FileManager

    /// - Parameters:
    ///   - fileURL: where to persist. Defaults to ``defaultFileURL(using:)``.
    ///   - fileManager: injected for tests (point at a temp dir). Defaults to `.default`.
    public init(fileURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.fileURL = fileURL ?? Self.defaultFileURL(using: fileManager)
    }

    /// Default persistence location: `<Application Support>/SlopDesk/workspace.json`. Falls back to a
    /// temporary directory if Application Support can't resolve (sandboxed edge cases) — the data is
    /// non-critical (a fresh default workspace is always recoverable).
    public static func defaultFileURL(using fileManager: FileManager = .default) -> URL {
        let base = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true,
        )) ?? fileManager.temporaryDirectory
        return base
            .appendingPathComponent("SlopDesk", isDirectory: true)
            .appendingPathComponent("workspace.json", isDirectory: false)
    }

    // MARK: Encoding (deterministic, reviewable)

    /// JSON encoder for a stable, reviewable on-disk shape — ``SidecarJSON/encoder()``, which every
    /// sidecar this target writes is built from (sorted keys are the byte-stable round-trip contract,
    /// docs/22 §8).
    private static func makeEncoder() -> JSONEncoder { SidecarJSON.encoder() }

    // MARK: Save

    /// Encodes the retained-but-dead canvas ``Workspace`` atomically to ``fileURL``. Reachable only
    /// from a `.canvas`-model store; the tree overload below is the live path.
    public func save(_ workspace: Workspace) throws {
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try Self.makeEncoder().encode(workspace)
        try data.write(to: fileURL, options: [.atomic])
    }

    /// Encodes the ``TreeWorkspace`` atomically to ``fileURL`` — the live save path, since the tree is
    /// the persisted source of truth. Creates the parent dir if needed; a thrown error keeps the
    /// previous good file.
    public func save(_ tree: TreeWorkspace) throws {
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try Self.makeEncoder().encode(tree)
        try data.write(to: fileURL, options: [.atomic])
    }

    // MARK: Load (canvas — the retained-but-dead path)

    /// Reads + decodes the retained-but-dead canvas ``Workspace``. Never throws — launch must always
    /// get a usable workspace:
    /// - Read failure (missing file) → ``Workspace/defaultWorkspace()``.
    /// - Decode failure, or a `schemaVersion` this build does not speak → ``Workspace/defaultWorkspace()``,
    ///   with the old file preserved aside as a `.corrupt` sidecar.
    ///
    /// The version is a GATE, not a migration seam: there are no upgrade steps (single-user, no
    /// backward compatibility — docs/DECISIONS.md).
    public func load() -> Workspace {
        guard let data = try? Data(contentsOf: fileURL) else {
            return .defaultWorkspace() // missing file = first launch; nothing to back up
        }
        guard let decoded = try? JSONDecoder().decode(Workspace.self, from: data),
              decoded.schemaVersion == Workspace.currentSchemaVersion
        else {
            // Hard-corrupt JSON, or a version this build does not speak. There is no upgrade step to
            // take (single-user, no backward compatibility): reset, keeping the file aside.
            return resetToDefault()
        }
        // Repair DUPLICATE item PaneIDs (the liveness registry is keyed 1:1 by PaneID, so duplicates
        // would collapse two panes onto one session) by RE-MINTING in place — lossless, since restored
        // sessions start idle. Then repair a dangling/nil focusedPane + maximizedPane (focus never
        // pinned to a ghost pane) and any item pointing at a vanished group. An absurd item count would
        // make the store eagerly allocate a session per item on the main actor — fall back to default
        // rather than freeze on launch.
        guard decoded.canvas.items.count <= Self.maxItems,
              decoded.groups.count <= Self.maxItems,
              decoded.layoutPresets.count <= Self.maxItems else { return resetToDefault() }
        var seen = Set<PaneID>()
        var repaired = decoded
        repaired.canvas = repaired.canvas.dedupingItemIDs(seen: &seen)
        // Repair the side collections (duplicate group ids / preset names) too.
        return repaired.normalizingCollections().normalizingFocus().normalizingGroups()
    }

    /// Best-effort copy the unrestorable file aside BEFORE the next `save()` overwrites it, so a
    /// merely-unreadable-by-THIS-build file or a hard-corrupt one is recoverable, not silently
    /// destroyed. Bounded to a single fixed-name `.corrupt` sidecar (overwrites any prior backup).
    private func resetToDefault() -> Workspace {
        let backup = fileURL.appendingPathExtension("corrupt")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.copyItem(at: fileURL, to: backup)
        return .defaultWorkspace()
    }

    // MARK: Load (tree — LIVE path)

    /// The LIVE load path for the IDE-shell tree: reads the file and typed-decodes a
    /// ``TreeWorkspace``. There is no migration step — a shape or a `schemaVersion` this build does not
    /// understand resets aside (single-user, no backward compatibility).
    /// - missing file → ``TreeWorkspace/defaultWorkspace()`` (first launch).
    /// - un-decodable / a foreign version → reset aside (`.corrupt` sidecar) + the default.
    ///
    /// Never throws. The result is `normalized()` so the `Set(specs.keys) == Set(leafIDs)` invariant
    /// holds even for a hand-edited / partial file (validate-then-repair), and the per-collection
    /// ``maxItems`` bound guards against a corrupt file allocating a session per leaf on launch.
    public func loadTree() -> TreeWorkspace {
        guard let data = try? Data(contentsOf: fileURL) else {
            return .defaultWorkspace() // missing file = first launch; nothing to back up
        }
        guard let tree = try? JSONDecoder().decode(TreeWorkspace.self, from: data),
              tree.schemaVersion == TreeWorkspace.currentSchemaVersion
        else {
            return resetTreeToDefault() // un-decodable, or a version this build does not speak
        }
        // Bound the leaf count so a corrupt file can't make the store allocate unboundedly on launch.
        guard tree.allPaneIDs().count <= Self.maxItems else { return resetTreeToDefault() }
        return tree.normalized()
    }

    // MARK: On-Launch behaviour (the `On Launch` general setting → actual launch behaviour)

    /// Resolves the tree the store seeds on launch, honouring the `On Launch` general setting
    /// (``OnLaunchBehavior``, persisted under ``SettingsKey/onLaunchKey``) — the wiring that makes the
    /// General → On Launch picker a LIVE control, not a dead accessor:
    ///
    /// - ``OnLaunchBehavior/restoreLastSession`` (default) → return the persisted tree (``loadTree()``).
    ///   With no persistence handle (automation builds omit one so a throwaway shape can't clobber the
    ///   real `workspace.json`) this is `nil` and the store's bootstrap seeds the tree.
    /// - ``OnLaunchBehavior/newWindow`` → return `nil`, so the store seeds ``TreeWorkspace/defaultWorkspace()``
    ///   (one fresh "Local" session, single terminal pane) instead of restoring. **DATA-LOSS GUARD:** the
    ///   store keeps the LIVE persistence handle, so its first debounced `save()` would atomically
    ///   overwrite `workspace.json` with the fresh default tree — permanently destroying the last saved
    ///   session with no recovery copy. So before returning `nil` we snapshot the existing `workspace.json`
    ///   aside to the fixed-name ``previousSessionURL`` sidecar (``snapshotPreviousSession()``) — the same
    ///   non-destructive discipline as the `.corrupt` reset path.
    ///
    /// Aside from the read and the `.newWindow` sidecar copy this is pure, so the launch branch is
    /// unit-testable against a temp-file persistence seam — no window / store / UI constructed (the
    /// hang-safety rule).
    public static func launchTree(
        behavior: OnLaunchBehavior, persistence: Self?,
    ) -> TreeWorkspace? {
        switch behavior {
        case .restoreLastSession:
            // Restore the persisted shape (nil under automation ⇒ the store's bootstrap replaces it anyway).
            return persistence?.loadTree()
        case .newWindow:
            // Snapshot the saved session aside FIRST so the store's first autosave (which overwrites
            // `workspace.json` with the default tree) can't destroy it — then return nil, so the store
            // seeds `TreeWorkspace.defaultWorkspace()` (a fresh single pane).
            persistence?.snapshotPreviousSession()
            return nil
        }
    }

    /// Fixed-name sidecar holding the LAST saved session, written by ``snapshotPreviousSession()`` just
    /// before an `On Launch = New Window` launch lets the store autosave a default tree over
    /// `workspace.json`. Sibling `workspace.previous.json` — one fixed-name copy overwritten each time (no
    /// unbounded accumulation), prior session always recoverable.
    public var previousSessionURL: URL {
        fileURL.deletingPathExtension().appendingPathExtension("previous.json")
    }

    /// Non-destructive `On Launch = New Window` guard: best-effort copy the current `workspace.json` aside
    /// to the fixed-name ``previousSessionURL`` sidecar so a fresh-window launch — which keeps the live
    /// persistence handle and autosaves the default tree over `workspace.json` — can't PERMANENTLY destroy
    /// the last saved session. Bounded to one fixed-name sidecar (overwrites any prior copy). A missing
    /// file (genuine first launch) is a no-op.
    ///
    /// **Idempotent across repeated new-window launches.** A PERSISTENT `New Window` setting fires this on
    /// EVERY launch, so a naive always-overwrite would lose data: launch 1 snapshots the REAL session into
    /// `.previous`, the store autosaves a DEFAULT over `workspace.json`; launch 2 would snapshot that
    /// throwaway default over `.previous`, clobbering the backup with no recovery.
    ///
    /// So the skip needs TWO facts, not one, and the second is what makes it safe. Shape alone cannot tell
    /// a throwaway default from a real single never-renamed terminal — the tree carries layout and nothing
    /// else, so the two are structurally identical — and skipping on shape alone destroys the real one:
    /// `workspace.json` is overwritten by the autosave, and with it the pane ids the host has PTYs filed
    /// under, which can then never be reattached. The second fact is that a sidecar ALREADY EXISTS: a
    /// default-shaped file with a `.previous` beside it is the throwaway from a prior new-window launch,
    /// and there is a preserved session to protect. With no sidecar there is nothing to lose by writing
    /// one, so the snapshot is taken.
    public func snapshotPreviousSession() {
        guard fileManager.fileExists(atPath: fileURL.path) else { return } // first launch: nothing to back up
        // Validate-then-drop: an unreadable/corrupt file is NOT default-shaped, so it is preserved aside.
        if fileManager.fileExists(atPath: previousSessionURL.path),
           let data = try? Data(contentsOf: fileURL),
           let tree = try? JSONDecoder().decode(TreeWorkspace.self, from: data),
           Self.isDefaultTreeShape(tree)
        {
            return
        }
        let sidecar = previousSessionURL
        try? fileManager.removeItem(at: sidecar)
        try? fileManager.copyItem(at: fileURL, to: sidecar)
    }

    /// Whether `tree` is SHAPED like the fresh-default tree the store autosaves over a real session on a
    /// `.newWindow` launch — one "Local" session, one tab, one terminal leaf titled "Terminal", no video —
    /// ignoring only the random ids ``TreeWorkspace/defaultWorkspace()`` mints per call (so a value `==` is
    /// impossible). Only session content distinguishes real from default, so app-config presets are
    /// intentionally NOT tested.
    ///
    /// It is a SHAPE test and nothing more: a real session the user never grew past one un-renamed
    /// terminal answers `true` too. ``snapshotPreviousSession()`` is where that ambiguity is resolved, and
    /// it resolves it by asking whether a preserved session already exists.
    ///
    static func isDefaultTreeShape(_ tree: TreeWorkspace) -> Bool {
        guard tree.sessions.count == 1,
              let session = tree.sessions.first,
              session.name == "Local",
              session.tabs.count == 1,
              tree.allPaneIDs().count == 1,
              let leaf = tree.allPaneIDs().first,
              let spec = tree.spec(for: leaf),
              spec.kind == .terminal,
              spec.title == "Terminal",
              spec.video == nil else { return false }
        return true
    }

    /// Best-effort copy the unrestorable file aside BEFORE the next `save()` overwrites it, so a
    /// merely-unreadable-by-THIS-build file or a hard-corrupt one is recoverable, not silently
    /// destroyed. Bounded to a single fixed-name `.corrupt` sidecar (overwrites any prior backup).
    private func resetTreeToDefault() -> TreeWorkspace {
        let backup = fileURL.appendingPathExtension("corrupt")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.copyItem(at: fileURL, to: backup)
        return .defaultWorkspace()
    }
}
