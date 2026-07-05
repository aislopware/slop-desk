import Foundation

// MARK: - Workspace schema migration (single-user: NO backward-compat path)

/// The version-aware seam between a decoded ``Workspace`` value and the shape this build understands
/// (docs/22 §6). `WorkspacePersistence.load()` decodes the raw JSON into a `Workspace` and asks this
/// enum to bring it up to ``Workspace/currentSchemaVersion``.
///
/// ### Single-user → no migration path (docs/31)
/// SlopDesk has exactly one user and no released persisted format, so there is deliberately NO
/// backward-compatibility migration: an older on-disk shape simply fails to decode (or migrates to
/// `nil` here) and `load()` resets to ``Workspace/defaultWorkspace()`` (preserving the old file aside
/// as a `.corrupt` sidecar). The function is kept as a thin, total seam so the load path stays
/// uniform and a *future* version is detected (not crashed on).
///
/// ### Contract
/// `migrate(_:from:to:)` is a TOTAL, pure function — no IO, no force-unwrap, no throw:
/// - `from == to` → identity (the current-version fast path).
/// - `from != to` → `nil` (there are no upgrade steps; the caller resets to default). This covers both
///   an older shape (no step to climb) and a future version this build cannot interpret.
enum WorkspaceSchemaMigration {
    /// Brings `workspace` from schema version `from` up to `to`, or returns `nil` when it cannot be
    /// understood. Pure and total — see the type doc.
    static func migrate(
        _ workspace: Workspace,
        from: Int,
        to: Int = Workspace.currentSchemaVersion,
    ) -> Workspace? {
        // Same version: identity (preserves every field bit-for-bit). Any other version has no upgrade
        // step (single-user, no backward-compat) → nil so the caller falls back to the default.
        from == to ? workspace : nil
    }

    // MARK: - Tree-rooted migration registration (W3 — additive, off the live load path)

    /// The registered upgrade step into the tree-rooted ``TreeWorkspace`` shape (docs/42 §Migration):
    /// - `from ∈ 5...9` — migrates through the frozen ``WorkspaceV9`` mirror (all v5–v9 canvas files
    ///   decode through the v9 shadow, which carries a superset of all older fields).
    /// - `from == 10` — identity re-decode: v10 is structurally identical to v11; the four new optional
    ///   ``PaneSpec`` fields resolve to `nil` via `decodeIfPresent`. No data is lost.
    /// - `from == 11` (current) — the caller decodes directly; this returns `nil` (nothing to upgrade).
    /// - Any other version → `nil` → the caller resets to the default workspace.
    ///
    /// **Additive (W3): the live `WorkspacePersistence.load()` still returns the v9 ``Workspace`` and does
    /// NOT call this.** It is the registered seam W4 wires in behind the version peek when the store cuts
    /// over to ``TreeWorkspace``. Forward-tolerant on `5...9` (those older shapes all decode through the v9
    /// mirror — the v9 fields are a superset).
    ///
    /// **v10 → v11 is an identity step** (schema v11 only adds optional fields to ``PaneSpec`` — all four
    /// decode via `decodeIfPresent` → `nil` when absent, so a v10 file decodes cleanly as a v11 tree with
    /// no data loss and no structural changes). A `from == 10` raw JSON string is therefore re-decoded as a
    /// ``TreeWorkspace`` directly (the typed decode already handles the new-field absence) and the result's
    /// `schemaVersion` is left at the decoded value; `loadTree()` normalizes + upgrades the version in the
    /// next `save()`. `from == 11` is already the current shape (caller decodes directly → returns `nil`
    /// here so the caller's direct decode takes effect).
    static func migrateToTree(_ data: Data, from: Int) -> TreeWorkspace? {
        switch from {
        // L0 / D2: the canvas-era v5–v9 migration (frozen `WorkspaceV9` shadow) is DELETED per the
        // "No backcompat / single-user" directive — a stale v5–v9 canvas file now decode-fails to the
        // default workspace rather than migrating.
        case 10:
            // A v10 file only lacks the four new optional PaneSpec fields, which `decodeIfPresent` resolves
            // to nil. Re-decode the raw bytes as TreeWorkspace (identical schema, additive fields absent)
            // so the caller gets a valid tree. loadTree() will write it back at schemaVersion 11 on the
            // next save.
            try? JSONDecoder().decode(TreeWorkspace.self, from: data)
        default:
            // 11 = already the current shape (caller decodes directly); anything else is uninterpretable.
            nil
        }
    }
}
