import Foundation

// MARK: - Workspace persistence (the tree of intent ↔ disk)

/// Loads + saves the pure ``Workspace`` value tree to disk (docs/22 §6).
///
/// The value tree IS the format — it is already `Codable` (each tab's flat ``Canvas`` synthesizes a
/// stable shape, with a thin defensive `Canvas.init(from:)` enforcing the invariants on decode). This
/// type is deliberately **IO-thin**: it owns only the file URL and the encode/decode, so it is
/// unit-testable against a temp directory with no store, no UI, no client.
///
/// ### The RESTORED-vs-RECONNECTED discipline (docs/22 §6)
/// Persistence restores SHAPE and INTENT only — never live connections, byte buffers, or sessionIDs.
/// On launch the store decodes the tree and starts the registry empty; `reconcile()` materializes
/// **idle** sessions; the view connects lazily on appear. A relaunch is a fresh session.
///
/// ### Failure policy
/// Any failure to read OR decode (missing file, corrupt JSON, unknown `schemaVersion`) falls back to
/// ``Workspace/defaultWorkspace()`` rather than crashing — a corrupt store must never brick launch.
/// `@unchecked Sendable`: the only stored properties are a `URL` (value type, Sendable) and a
/// `FileManager` that is read-only here and documented thread-safe for these file operations, so a
/// `WorkspacePersistence` value can cross actor boundaries for the store's off-main-actor debounced
/// write (docs/22 §6) without data-race risk.
public struct WorkspacePersistence: @unchecked Sendable {
    /// The file the workspace is written to / read from. Defaults to
    /// `Application Support/Aislopdesk/workspace.json` (the app container on iOS).
    public let fileURL: URL
    private let fileManager: FileManager

    /// - Parameters:
    ///   - fileURL: where to persist. Defaults to ``defaultFileURL(using:)``.
    ///   - fileManager: injected for tests (point at a temp dir). Defaults to `.default`.
    public init(fileURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.fileURL = fileURL ?? Self.defaultFileURL(using: fileManager)
    }

    /// The default persistence location: `<Application Support>/Aislopdesk/workspace.json`. Falls back to a
    /// temporary directory if Application Support cannot be resolved (sandboxed edge cases) — the data
    /// is non-critical (a fresh default workspace is always recoverable).
    public static func defaultFileURL(using fileManager: FileManager = .default) -> URL {
        let base = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true,
        )) ?? fileManager.temporaryDirectory
        return base
            .appendingPathComponent("Aislopdesk", isDirectory: true)
            .appendingPathComponent("workspace.json", isDirectory: false)
    }

    // MARK: Encoding (deterministic, reviewable)

    /// A JSON encoder configured for a stable, reviewable on-disk shape (sorted keys, pretty-printed).
    /// Sorted keys keep the byte-stable round-trip tests meaningful (docs/22 §8).
    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    // MARK: Save

    /// Encodes `workspace` and writes it atomically to ``fileURL``, creating the parent directory if
    /// needed. Throws on an IO/encode failure (the store debounces + best-effort calls this; a thrown
    /// error is logged, not fatal — a failed save just means the previous good file is kept).
    public func save(_ workspace: Workspace) throws {
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try Self.makeEncoder().encode(workspace)
        try data.write(to: fileURL, options: [.atomic])
    }

    /// W5: encodes the v10 ``TreeWorkspace`` and writes it atomically to ``fileURL`` — the live save path
    /// after the cutover (the tree IS the persisted source of truth now). Same atomic / sorted-keys
    /// discipline as the canvas ``save(_:)`` so the on-disk shape stays reviewable and byte-stable. The
    /// store debounces + best-effort-calls this; a thrown error keeps the previous good file.
    public func save(_ tree: TreeWorkspace) throws {
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try Self.makeEncoder().encode(tree)
        try data.write(to: fileURL, options: [.atomic])
    }

    // MARK: Load

    /// Reads + decodes the workspace, then forward-migrates it to this build's schema (docs/22 §6).
    /// Never throws — launch must always get a usable workspace:
    /// - A read failure (missing file) → ``Workspace/defaultWorkspace()``.
    /// - A decode failure (corrupt JSON, an unknown discriminator) → ``Workspace/defaultWorkspace()``.
    /// - An *older* payload → upgraded in place by ``WorkspaceSchemaMigration`` (an older store is
    ///   migrated forward, no longer discarded on the first schema bump).
    /// - A *future* / un-migratable version → ``WorkspaceSchemaMigration/migrate(_:from:to:)`` returns
    ///   `nil` and we fall back to the default (a build cannot interpret a newer shape).
    ///
    /// Because migration runs on the *already-decoded* value, it only covers schema changes that are
    /// still parseable by today's `Codable`. A future **v2 that reshapes the wire format** (so the v1
    /// decoder can no longer parse it) would fail the `decode` above and fall back to default; handling
    /// it would need a pre-decode raw-JSON branch here (peek `schemaVersion` off the raw object, run a
    /// JSON→JSON upgrade, then decode). That is out of scope — see ``WorkspaceSchemaMigration``.
    public func load() -> Workspace {
        guard let data = try? Data(contentsOf: fileURL) else {
            return .defaultWorkspace() // missing file = first launch; nothing to back up
        }
        guard let decoded = try? JSONDecoder().decode(Workspace.self, from: data) else {
            return resetToDefault() // hard-corrupt JSON (or an older incompatible shape) — preserve aside
        }
        // Forward-migrate the decoded value to this build's schema. A future/un-migratable version
        // (migrate → nil) falls back to the default; the current version is an identity passthrough.
        guard let migrated = WorkspaceSchemaMigration.migrate(decoded, from: decoded.schemaVersion) else {
            return resetToDefault() // e.g. a newer build wrote it, this older build can't read it
        }
        // Repair a corrupt / copy-pasted canvas with DUPLICATE item PaneIDs (the liveness registry is
        // keyed 1:1 by PaneID, so duplicates would collapse two panes onto one session) by RE-MINTING the
        // duplicates in place — lossless, since restored sessions always start idle (UI/UX pass-3 #5).
        // Then repair a dangling/nil focusedPane + maximizedPane (focus never pinned to a ghost pane) and
        // any item pointing at a group that no longer exists (R13, ported to the single canvas).
        // A corrupt / hand-edited file with an absurd item count would make the store eagerly allocate a
        // session per item on the main actor — fall back to default rather than freeze on launch (the same
        // bound the portable import enforces).
        guard migrated.canvas.items.count <= WorkspaceTransfer.maxItems,
              migrated.groups.count <= WorkspaceTransfer.maxItems,
              migrated.snippets.count <= WorkspaceTransfer.maxItems,
              migrated.layoutPresets.count <= WorkspaceTransfer.maxItems else { return resetToDefault() }
        var seen = Set<PaneID>()
        var repaired = migrated
        repaired.canvas = repaired.canvas.dedupingItemIDs(seen: &seen)
        // Repair the side collections (duplicate group ids / snippet ids / preset names) too — shared with
        // the portable import path so a corrupt persisted file gets the same defensive treatment.
        return repaired.normalizingCollections().normalizingFocus().normalizingGroups()
    }

    // MARK: Load (tree — W5 LIVE path)

    /// W5 — the LIVE load path after the IDE-shell cutover: reads the file, peeks its `schemaVersion`
    /// off the raw bytes (a v10/v11 ``TreeWorkspace`` file has no `canvas`/`groups` and would fail the
    /// typed v9 decode), and branches:
    /// - `== 11` → typed-decode the ``TreeWorkspace`` directly (the steady-state).
    /// - `== 10` → identity-decode through ``WorkspaceSchemaMigration/migrateToTree(_:from:)`` (v10 is
    ///   structurally identical to v11; the four new optional ``PaneSpec`` fields decode as `nil` via
    ///   `decodeIfPresent`, so no data is lost). The result's `schemaVersion` will be upgraded to 11 on
    ///   the next `save()`.
    /// - `5…9` → run the frozen-mirror v9→v10 migration (``migrateV9toV10``) so an existing canvas
    ///   workspace upgrades in place, preserving every `PaneID` + `PaneSpec`.
    /// - missing file → ``TreeWorkspace/defaultWorkspace()`` (first launch).
    /// - unknown / future / un-decodable → reset aside (`.corrupt` sidecar) + the default.
    ///
    /// Never throws — launch must always get a usable tree. The result is `normalized()` so the
    /// `Set(specs.keys) == Set(leafIDs)` invariant holds even for a hand-edited / partial file
    /// (validate-then-repair), and the per-collection ``WorkspaceTransfer/maxItems`` bound guards against
    /// a corrupt file that would make the store eagerly allocate a session per leaf on launch.
    ///
    /// After normalization, a **last-known-title promotion** runs over each session's specs: if a pane's
    /// ``PaneSpec/lastKnownTitle`` is non-nil AND its ``PaneSpec/title`` is still the default `"Terminal"`
    /// (meaning the user has never manually renamed it), the title is promoted to `lastKnownTitle` so the
    /// pane chrome shows the last-seen shell title on restore. User-renamed panes (title ≠ `"Terminal"`)
    /// are left untouched.
    public func loadTree() -> TreeWorkspace {
        guard let data = try? Data(contentsOf: fileURL) else {
            return .defaultWorkspace() // missing file = first launch; nothing to back up
        }
        guard let version = Self.peekSchemaVersion(in: data) else {
            return resetTreeToDefault() // not JSON / no schemaVersion — preserve aside
        }
        let tree: TreeWorkspace? =
            if version == TreeWorkspace.currentSchemaVersion {
                try? JSONDecoder().decode(TreeWorkspace.self, from: data)
            } else {
                // v5…9: frozen-mirror migration; v10: additive identity re-decode; others: nil → reset.
                WorkspaceSchemaMigration.migrateToTree(data, from: version)
            }
        guard let tree else {
            return resetTreeToDefault() // un-decodable / un-migratable version — preserve aside
        }
        // Bound the leaf/collection counts so a corrupt file cannot make the store allocate unboundedly
        // on launch (the same ceiling the canvas load + portable import enforce).
        guard tree.allPaneIDs().count <= WorkspaceTransfer.maxItems,
              tree.snippets.count <= WorkspaceTransfer.maxItems,
              tree.layoutPresets.count <= WorkspaceTransfer.maxItems,
              tree.launchPresets.count <= WorkspaceTransfer.maxItems,
              tree.sessionTemplates.count <= WorkspaceTransfer.maxItems else { return resetTreeToDefault() }
        let normalized = tree.normalized()
        return Self.promotingLastKnownTitles(in: normalized)
    }

    /// Pure value transform: for each pane whose ``PaneSpec/title`` is still the default `"Terminal"` AND
    /// whose ``PaneSpec/lastKnownTitle`` is non-nil, promote `lastKnownTitle` into `title`. A user-renamed
    /// pane (title ≠ `"Terminal"`) is left untouched. Called once on the loaded + normalized tree.
    static func promotingLastKnownTitles(in tree: TreeWorkspace) -> TreeWorkspace {
        var result = tree
        result.sessions = tree.sessions.map { session in
            var s = session
            for (paneID, spec) in s.specs {
                guard let knownTitle = spec.lastKnownTitle, spec.title == "Terminal" else { continue }
                var updated = spec
                updated.title = knownTitle
                s.specs[paneID] = updated
            }
            return s
        }
        return result
    }

    // MARK: On-Launch behaviour (O1 — the otty `On Launch` general setting → actual launch behaviour)

    /// Resolves the tree the store should seed on launch, honouring the otty `On Launch` general setting
    /// (``OnLaunchBehavior``, persisted under ``SettingsKey/onLaunchKey``). This is the wiring that makes the
    /// General → On Launch picker a LIVE control instead of a dead accessor:
    ///
    /// - ``OnLaunchBehavior/restoreLastSession`` (the default) → return the persisted tree (``loadTree()``),
    ///   so a relaunch restores the last workspace shape exactly as before. With no persistence handle
    ///   (automation builds construct the store WITHOUT one so a throwaway shape can't clobber the real
    ///   `workspace.json`) this is `nil` and the store's bootstrap seeds the tree.
    /// - ``OnLaunchBehavior/newWindow`` → return `nil`, so the store seeds ``TreeWorkspace/defaultWorkspace()``
    ///   (one fresh "Local" session with a single terminal pane) instead of restoring — picking "New Window"
    ///   genuinely opens a fresh window rather than being a silent no-op. **DATA-LOSS GUARD:** the store keeps
    ///   the LIVE persistence handle, so its first debounced `save()` would atomically overwrite
    ///   `workspace.json` with the fresh default tree — permanently destroying the user's last saved session
    ///   with no recovery copy. Before returning `nil` we therefore snapshot the existing `workspace.json`
    ///   aside to the fixed-name ``previousSessionURL`` sidecar (``snapshotPreviousSession()``), so the prior
    ///   session stays recoverable — the same non-destructive discipline as the `.corrupt` reset path.
    ///
    /// Aside from the read (`loadTree` is a non-mutating decode) and the `.newWindow` sidecar copy, this is
    /// pure, so the launch branch is unit-testable against a temp-file persistence seam — no window / store /
    /// UI is constructed (the hang-safety rule).
    public static func launchTree(
        behavior: OnLaunchBehavior, persistence: Self?,
    ) -> TreeWorkspace? {
        switch behavior {
        case .restoreLastSession:
            // Restore the persisted shape (nil under automation ⇒ the store's bootstrap replaces it anyway).
            return persistence?.loadTree()
        case .newWindow:
            // Snapshot the saved session aside FIRST so the store's first autosave (which will overwrite
            // `workspace.json` with the fresh default tree) cannot permanently destroy it — then do NOT
            // restore: nil ⇒ the store seeds `TreeWorkspace.defaultWorkspace()` (a fresh single pane).
            persistence?.snapshotPreviousSession()
            return nil
        }
    }

    /// The fixed-name sidecar holding the LAST saved session, written by ``snapshotPreviousSession()`` just
    /// before an `On Launch = New Window` launch lets the store autosave a fresh default tree over
    /// `workspace.json`. Sibling of `workspace.json` (`workspace.previous.json`) so a single fixed-name copy
    /// is overwritten each time — no unbounded accumulation — and the prior session is always recoverable.
    public var previousSessionURL: URL {
        fileURL.deletingPathExtension().appendingPathExtension("previous.json")
    }

    /// Non-destructive `On Launch = New Window` guard: best-effort copy the current `workspace.json` aside to
    /// the fixed-name ``previousSessionURL`` sidecar so a fresh-window launch — which keeps the live
    /// persistence handle and will autosave the default tree over `workspace.json` — cannot PERMANENTLY
    /// destroy the user's last saved session. Bounded to one fixed-name sidecar (overwrites any prior copy).
    /// A missing file (a genuine first launch) is a no-op — there is nothing to preserve.
    ///
    /// **Idempotent across repeated new-window launches.** A PERSISTENT `On Launch = New Window` setting fires
    /// this on EVERY launch, so a naive always-overwrite would lose data permanently: launch 1 snapshots the
    /// REAL session into `.previous`, the store then autosaves a fresh DEFAULT over `workspace.json`; launch 2
    /// would snapshot that throwaway default over `.previous`, clobbering the real-session backup with no
    /// recovery. The guard therefore SKIPS the snapshot when `workspace.json` is already a fresh
    /// ``TreeWorkspace/defaultWorkspace()``-shaped tree (the throwaway the store just autosaved) — and ONLY then,
    /// because ``isDefaultTreeShape(_:)`` matches the re-seedable default down to its empty additive ``PaneSpec``
    /// fields, so a real single-un-renamed-terminal session (which carries a `lastKnownCwd` / `resumeSessionID`
    /// hint worth preserving) is NOT mistaken for the throwaway. The sidecar therefore always preserves the
    /// most-recent session that has anything worth recovering, never being overwritten by a default a later
    /// launch re-seeds anyway.
    public func snapshotPreviousSession() {
        guard fileManager.fileExists(atPath: fileURL.path) else { return } // first launch: nothing to back up
        // Idempotency guard: a default-shaped `workspace.json` is the throwaway tree the store autosaved over
        // the real session on a PRIOR new-window launch — re-snapshotting it would overwrite the real session
        // already preserved in `.previous` with a useless default. A default is always re-seedable, so skip
        // (validate-then-drop: an unreadable/corrupt file is NOT default-shaped → it is preserved aside).
        if let data = try? Data(contentsOf: fileURL),
           let tree = try? JSONDecoder().decode(TreeWorkspace.self, from: data),
           Self.isDefaultTreeShape(tree)
        {
            return
        }
        let sidecar = previousSessionURL
        try? fileManager.removeItem(at: sidecar)
        try? fileManager.copyItem(at: fileURL, to: sidecar)
    }

    /// Whether `tree` is the EXACT fresh-default tree the store autosaves over a real session on a `.newWindow`
    /// launch — one "Local" session, one tab, one terminal leaf titled "Terminal", AND that leaf's spec carrying
    /// none of the additive persistence fields — ignoring only the random ids ``TreeWorkspace/defaultWorkspace()``
    /// mints on every call (so a value `==` is impossible). The idempotency guard in ``snapshotPreviousSession()``
    /// uses it to AVOID clobbering a real session already in the sidecar with a throwaway default on a repeated
    /// new-window launch. Only the session content distinguishes a real session from the default, so app-config
    /// presets/snippets are intentionally NOT part of the test.
    ///
    /// **The additive-field check is load-bearing, not decorative.** Structural shape ALONE is the single most
    /// common REAL workspace — one un-renamed terminal in a project dir — and that session is NOT throwaway: it
    /// carries a `lastKnownCwd` (its subtitle hint) and, for a detached host session, a `resumeSessionID` /
    /// `resumeLastReceivedSeq` (its Stage-2 reattach handle). The raw-decode guard runs BEFORE the load-time
    /// `lastKnownTitle → title` promotion, so its `title` is still "Terminal" even when the user has seen a real
    /// shell title. Matching on shape alone would mis-classify that session as the default and SKIP its snapshot,
    /// letting the store's first `.newWindow` autosave overwrite `workspace.json` with the throwaway default —
    /// the precise permanent loss the sidecar exists to prevent. Requiring every additive field to be empty keeps
    /// the repeated-launch idempotency win (the store's autosaved default is all-nil, so it still matches) while
    /// only ever skipping a genuinely re-seedable default.
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
              // Additive PaneSpec fields must ALL be empty — a real un-renamed terminal that has been connected
              // (cwd subtitle hint, detach/reattach handle, floated, or a video binding) is NOT the throwaway
              // default and must still be snapshotted aside before the autosave clobbers it.
              spec.video == nil,
              spec.resumeSessionID == nil,
              spec.resumeLastReceivedSeq == nil,
              spec.lastKnownCwd == nil,
              spec.lastKnownTitle == nil,
              spec.floatingFrame == nil else { return false }
        return true
    }

    /// The tree counterpart of ``resetToDefault()``: copy the unrestorable file aside to the single
    /// fixed-name `.corrupt` sidecar before the next `save()` overwrites it, then return the default tree.
    private func resetTreeToDefault() -> TreeWorkspace {
        let backup = fileURL.appendingPathExtension("corrupt")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.copyItem(at: fileURL, to: backup)
        return .defaultWorkspace()
    }

    // MARK: Version peek + v9→v10 step (W3 — exposed, wired into loadTree() in W5)

    /// Peeks ONLY the `schemaVersion` off raw persisted bytes WITHOUT a full typed decode (docs/42
    /// §Migration: "a pre-decode raw-JSON version peek"). A v10 ``TreeWorkspace`` file has no
    /// `canvas`/`groups`, so it would FAIL the typed v9 ``Workspace`` decode — the load path needs to
    /// branch on the version *before* choosing a decoder. Returns `nil` for non-JSON / a missing
    /// `schemaVersion` (a corrupt file the caller resets aside). **Additive (W3): the live `load()` does
    /// not yet call this** — the cutover that branches the decoder on the peeked version is W4.
    public static func peekSchemaVersion(in data: Data) -> Int? {
        struct VersionPeek: Decodable { let schemaVersion: Int }
        return (try? JSONDecoder().decode(VersionPeek.self, from: data))?.schemaVersion
    }

    // L0 / D2: `migrateV9toV10` (canvas-era v5–v9 → tree migration through the frozen `WorkspaceV9`
    // shadow) is DELETED per the "No backcompat / single-user" directive — a stale v5–v9 file now
    // decode-fails to the default workspace instead.

    /// Best-effort copy the unrestorable file aside BEFORE the next `save()` atomically overwrites it, so a
    /// merely-unreadable-by-THIS-build file (a future schemaVersion after a downgrade) or a hard-corrupt
    /// one is recoverable instead of silently destroyed (UI/UX pass-3 #2). Bounded to a single fixed-name
    /// `.corrupt` sidecar (overwrites any prior backup — no unbounded accumulation). Only the decode /
    /// migrate failure paths reach here; the missing-file path has nothing to copy.
    private func resetToDefault() -> Workspace {
        let backup = fileURL.appendingPathExtension("corrupt")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.copyItem(at: fileURL, to: backup)
        return .defaultWorkspace()
    }
}
